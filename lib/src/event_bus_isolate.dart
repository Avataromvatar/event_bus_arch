part of event_arch;

//---------------------------------------------------------------------------
// Message protocol between the main isolate and the worker.
//
// Messages are plain immutable objects, so they can be told apart by type
// (records like (int, dynamic) cannot distinguish a request from a response).
// Protocol rules:
//  * every _IsolateRequest gets exactly one reply - _IsolateResponse or
//    _IsolateErrorResponse, including the case when there is no node (then null);
//  * a reply always carries the request id, so the order of replies is irrelevant;
//  * an unknown id (a late or duplicate reply) is silently ignored;
//  * a _IsolateDelete is fire-and-forget like a _IsolateFire: no reply;
//  * the port listener never throws.
//---------------------------------------------------------------------------

///The worker has finished onInit and is ready to accept events.
class _IsolateReady {
  const _IsolateReady();
}

///onInit failed in the worker: waitInit must complete with an error, not hang.
class _IsolateInitError {
  final Object error;
  final StackTrace? stackTrace;
  const _IsolateInitError(this.error, this.stackTrace);
}

///The worker isolate has terminated (killed, crashed or exited on its own).
///
///A ReceivePort does not close when the isolate on the other side dies, so the
///death is delivered by `Isolate.addOnExitListener` instead of `onDone`. The
///exit response must be a simple sendable value, and the protocol otherwise
///never sends a bare String to this port.
const String _isolateExitMessage = 'event_bus_arch.isolate.exit';

///A failure of a layer below the receiver, forwarded up the chain.
///
///Only a message String crosses the boundary: the original error object is not
///guaranteed to be sendable, and the top only needs to know that the chain
///must be restarted.
class _IsolateFailure {
  final String message;
  const _IsolateFailure(this.message);
}

///A bus event sent to the other side. [id] is unique per sender.
class _IsolateRequest {
  final int id;
  final EventDTO dto;
  const _IsolateRequest(this.id, this.dto);
}

///A fire-and-forget event. The receiver dispatches it and does not reply.
class _IsolateFire {
  final EventDTO dto;
  const _IsolateFire(this.dto);
}

///A manual topic removal. The sender removes its own node before sending; the
///receiver removes its node and does not reply.
class _IsolateDelete {
  final Topic topic;
  const _IsolateDelete(this.topic);
}

///A change of listener or handler interest for one topic.
///
///It is fire-and-forget: the receiver updates its remote-interest registry and
///does not reply. [present] false withdraws only the flags carried by this
///message.
class _IsolateInterest {
  final Topic topic;
  final bool listener;
  final bool handler;

  ///A model bus stores the topic value even without a listener.
  final bool model;
  final bool present;

  const _IsolateInterest(this.topic,
      {required this.listener,
      required this.handler,
      this.model = false,
      required this.present});
}

///A caller-side cancellation of an in-flight request. The receiver removes the
///request from its queue if it has not been dispatched and ignores a later
///response.
class _IsolateCancel {
  final int id;
  const _IsolateCancel(this.id);
}

///A reply to a specific request. value == null means "handled without a result"
///or "there is no node for the event".
class _IsolateResponse {
  final int id;
  final dynamic value;
  const _IsolateResponse(this.id, this.value);
}

///The handler threw: the error travels back to the sender instead of becoming null.
class _IsolateErrorResponse {
  final int id;
  final Object error;
  final StackTrace? stackTrace;
  const _IsolateErrorResponse(this.id, this.error, this.stackTrace);
}

///A liveness check. It does NOT confirm readiness: messages are read by a
///listener that lives from the moment the worker bus is created, before onInit.
class _IsolatePing {
  final int id;
  const _IsolatePing(this.id);
}

class _IsolatePong {
  final int id;
  const _IsolatePong(this.id);
}

///A pending reply to a request.
class _PendingRequest {
  final Completer<dynamic> completer;

  ///The topic is only needed for the error message when the link is closed.
  final String topic;
  Timer? timer;
  _PendingRequest(this.completer, this.topic);
}

///Interest of the other side, split by kind and exact/pattern topic.
class _RemoteInterest {
  final Map<Topic, bool> _listeners = {};
  final Map<Topic, bool> _handlers = {};
  final Map<Topic, bool> _models = {};

  void apply(Topic topic,
      {required bool listener,
      required bool handler,
      bool model = false,
      required bool present}) {
    void applyOne(Map<Topic, bool> map, bool flag) {
      if (!flag) return;
      if (present) {
        map[topic] = true;
      } else {
        map.remove(topic);
      }
    }

    applyOne(_listeners, listener);
    applyOne(_handlers, handler);
    applyOne(_models, model);
  }

  bool hasListener(Topic topic) =>
      _matches(_listeners, topic) || _matches(_models, topic);
  bool hasHandler(Topic topic) => _matches(_handlers, topic);

  bool _matches(Map<Topic, bool> topics, Topic topic) {
    if (topics[topic] == true) return true;
    if (TopicPattern.isPattern(topic)) return false;
    for (final pattern in topics.keys) {
      if (TopicPattern.matches(pattern, topic)) return true;
    }
    return false;
  }

  Iterable<Topic> get listenerTopics => _listeners.keys;
  Iterable<Topic> get handlerTopics => _handlers.keys;
  Iterable<Topic> get modelTopics => _models.keys;

  void clear() {
    _listeners.clear();
    _handlers.clear();
    _models.clear();
  }
}

///Shared part of the exchange for both sides: id counter, pending replies, dispatch.
class _IsolateLink {
  _IsolateLink(this._host);

  final EventBusImpl _host;

  ///Port to the other side. On the worker side it is known from the start, on the
  ///main side it appears after the handshake.
  SendPort? sendPort;

  int _nextId = 0;
  final Map<int, _PendingRequest> _pending = {};
  final Map<int, Completer<bool>> _pings = {};
  final Map<int, CancelToken> _incomingCancellations = {};
  final _RemoteInterest remoteInterest = _RemoteInterest();
  bool _closed = false;

  bool get isClosed => _closed;

  int _newId() => _nextId++;

  ///Sends an event to the other side and waits for the handler result.
  ///
  ///[timeout] and [cancelToken] remove the pending entry and send
  ///[_IsolateCancel], so a late response is ignored and the map does not grow.
  Future<dynamic> request(EventDTO dto,
      {Duration? timeout, CancelToken? cancelToken}) {
    var port = sendPort;
    if (port == null || _closed) {
      return Future.error(EventBusException(
          'EventBusIsolate is not available (ready=${port != null}, closed=$_closed)'));
    }
    if (cancelToken?.isCancelled ?? false) {
      return Future.error(RequestCanceledException(dto.topic.topic));
    }

    var id = _newId();
    var completer = Completer<dynamic>();
    final pending = _PendingRequest(completer, dto.topic.topic);
    _pending[id] = pending;

    void cancel(Object error) {
      final entry = _takePending(id);
      if (entry == null) return;
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(error);
      }
      if (!_closed) {
        port.send(_IsolateCancel(id));
      }
    }

    if (timeout != null) {
      pending.timer = Timer(timeout, () {
        cancel(RequestTimeoutException(dto.topic.topic, timeout));
      });
    }
    final token = cancelToken;
    if (token != null) {
      token.whenCancelled.then((_) {
        cancel(RequestCanceledException(dto.topic.topic));
      });
    }

    port.send(_IsolateRequest(id, dto));
    return completer.future;
  }

  _PendingRequest? _takePending(int id) {
    final pending = _pending.remove(id);
    pending?.timer?.cancel();
    pending?.timer = null;
    return pending;
  }

  ///Publishes a listener/handler interest transition to the other side.
  bool interest(Topic topic,
      {required bool listener,
      required bool handler,
      bool model = false,
      required bool present}) {
    var port = sendPort;
    if (port == null || _closed) return false;
    port.send(_IsolateInterest(topic,
        listener: listener,
        handler: handler,
        model: model,
        present: present));
    return true;
  }

  ///Sends an event without waiting for a reply.
  bool fire(EventDTO dto) {
    var port = sendPort;
    if (port == null || _closed) {
      return false;
    }
    port.send(_IsolateFire(dto));
    return true;
  }

  ///Sends a manual topic removal without waiting for a reply. Returns false
  ///when the other side is not reachable; the local removal has already
  ///happened in that case.
  bool removeTopic(Topic topic) {
    var port = sendPort;
    if (port == null || _closed) {
      return false;
    }
    port.send(_IsolateDelete(topic));
    return true;
  }

  ///Sends a layer failure further up the chain. Fire-and-forget.
  bool sendFailure(String message) {
    var port = sendPort;
    if (port == null || _closed) return false;
    port.send(_IsolateFailure(message));
    return true;
  }

  ///Checks that the worker is alive and responds.
  Future<bool> ping(Duration timeout) {
    var port = sendPort;
    if (port == null || _closed) {
      return Future.value(false);
    }
    var id = _newId();
    var completer = Completer<bool>();
    _pings[id] = completer;
    port.send(_IsolatePing(id));
    return completer.future.timeout(timeout, onTimeout: () {
      _pings.remove(id);
      return false;
    });
  }

  ///Single entry point for incoming messages. Never throws: in the worker an
  ///exception from the port listener escapes to the zone and kills the isolate.
  void handleMessage(dynamic message) {
    if (message is _IsolateResponse) {
      _takePending(message.id)?.completer.complete(message.value);
    } else if (message is _IsolateErrorResponse) {
      _takePending(message.id)
          ?.completer
          .completeError(message.error, message.stackTrace);
    } else if (message is _IsolatePong) {
      _pings.remove(message.id)?.complete(true);
    } else if (message is _IsolatePing) {
      sendPort?.send(_IsolatePong(message.id));
    } else if (message is _IsolateRequest) {
      unawaited(_answer(message));
    } else if (message is _IsolateFire) {
      _host._dispatchIncoming(message.dto, request: false);
    } else if (message is _IsolateInterest) {
      remoteInterest.apply(message.topic,
          listener: message.listener,
          handler: message.handler,
          model: message.model,
          present: message.present);
    } else if (message is _IsolateCancel) {
      _incomingCancellations.remove(message.id)?.cancel();
    } else if (message is _IsolateFailure) {
      final host = _host;
      if (host is EventBusIsolate) {
        host._reportRemoteFailure(message.message);
      } else if (host is _EventBusForIsolate) {
        host._reportRemoteFailure(message.message);
      }
    } else if (message is _IsolateDelete) {
      // Local only: forwarding here would bounce the delete between the sides.
      _host._removeTopicLocally(message.topic);
    }
    // any other message (including late replies) is ignored
  }

  ///Runs an incoming request on the local bus and replies to the sender.
  Future<void> _answer(_IsolateRequest request) async {
    var port = sendPort;
    if (port == null || _closed) {
      return;
    }
    final token = CancelToken();
    _incomingCancellations[request.id] = token;
    try {
      var value =
          await _host._dispatchIncoming(request.dto, cancelToken: token);
      if (!_closed) {
        port.send(_IsolateResponse(request.id, value));
      }
    } catch (error, stackTrace) {
      if (!_closed) {
        port.send(_IsolateErrorResponse(request.id, error, stackTrace));
      }
    } finally {
      _incomingCancellations.remove(request.id);
    }
  }

  ///Fails every pending reply: called on dispose and when the port closes, so
  ///that `await send(...)` never hangs forever.
  void failAllPending(Object error) {
    _closed = true;
    for (var pending in _pending.values) {
      pending.timer?.cancel();
      pending.timer = null;
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
            EventBusException('$error (pending event "${pending.topic}")'));
      }
    }
    _pending.clear();
    for (var ping in _pings.values) {
      if (!ping.isCompleted) {
        ping.complete(false);
      }
    }
    _pings.clear();
    for (final token in _incomingCancellations.values) {
      token.cancel();
    }
    _incomingCancellations.clear();
    remoteInterest.clear();
  }
}

///Atention The result of calling the event can be received later than the events called in the event handler on the isolate side
///
///EventBusIsolate it consists of two Event bus, one on the side of the main isolate and the other in the working isolate.
///They exchange EventDTO and the results of the handlers' work among themselves.
///
///`waitInit` completes once the worker has run `onInit`; before that
///`send`/`listen`/`subscribe` throw StateError. Replies are correlated by
///request id, so concurrent requests of the same type never get swapped.
///
///The bridge is directional: subscriptions on this bus receive events coming
///from the worker, and [fire] sends an event to the worker only. A fired event
///is not delivered to this bus's own listeners; local pub/sub belongs to an
///ordinary [EventBus] (inside [Layers] that is [Layer.current]).
class EventBusIsolate extends EventBusImpl {
  ///Worker init function. May be async: `waitInit` waits for it to finish.
  ///Must be top-level/static - closures cannot be sent to another isolate.
  final FutureOr<void> Function(EventBus isolateBu, Object? initialData) onInit;

  late _IsolateLink _link = _IsolateLink(this);

  Isolate? _isolate;

  /// this port listen data from isolate
  ReceivePort? _receivePort;

  Completer<bool> _completerInit = Completer();

  ///Stored so [restart] can spawn an identical worker.
  final Object? _initialData;
  final bool _workerIsModelBus;

  ///Every callback of the receive port captures the generation it was created
  ///for; a callback of an older worker after a restart is ignored.
  int _generation = 0;

  ///true once the worker has run onInit
  bool _ready = false;

  ///true when the worker termination was already accounted for
  bool _workerGone = false;

  ///Completes with true once the worker has run `onInit`, or with an error when
  ///the isolate could not be spawned or onInit threw.
  Future<bool> get waitInit => _completerInit.future;

  ///true after a successful worker initialization
  bool get isInit => _ready;

  ///[isModelBus] applies to both sides of the bridge: the bus in the main
  ///isolate and the bus inside the worker. A model bus keeps the node and the
  ///current value of a topic after its last listener cancels.
  EventBusIsolate({
    required this.onInit,
    Object? initialData,
    bool isModelBus = false,
  })  : _initialData = initialData,
        _workerIsModelBus = isModelBus,
        super(isModelBus) {
    unawaited(_init());
  }

  ///Replaces the worker with a fresh one while keeping this bus object.
  ///
  ///Local nodes, listeners and model state of this side survive, so application
  ///subscriptions keep working across a restart. Pending requests fail with
  ///[EventBusException] and are not retried. The returned future is the new
  ///worker's [waitInit]; `fire`/`request` throw `StateError` until it completes.
  ///
  ///A worker that dies while this method is running is invalidated by the
  ///generation counter, so its late messages cannot affect the new worker.
  Future<bool> restart() async {
    if (isDisposed) {
      throw StateError('EventBusIsolate is disposed');
    }
    if (!_completerInit.isCompleted) {
      _completerInit.completeError(
          EventBusException('EventBusIsolate restart was superseded'));
    }
    // Invalidate every callback of the old generation before killing it.
    _generation++;
    final oldPort = _receivePort;
    _receivePort = null;
    oldPort?.close();
    final oldIsolate = _isolate;
    _isolate = null;
    _link.failAllPending('EventBusIsolate is restarting');
    _link = _IsolateLink(this);
    _ready = false;
    _workerGone = false;
    _completerInit = Completer();
    oldIsolate?.kill(priority: Isolate.immediate);
    unawaited(_init());
    return waitInit;
  }

  @override
  bool fire<T>(T data,
      {List<String>? paths,
      String? separator,
      Map<String, String>? arguments}) {
    if (isDisposed) {
      throw StateError('EventBusIsolate is disposed');
    }
    if (!_ready) {
      throw StateError(
          'EventBusIsolate is not initialized: await waitInit before fire');
    }
    _rejectWildcardPaths(paths, 'fire');
    final topic = Topic.create<T>(
        paths: paths, separator: separator ?? defaultTopicPathSeparator);
    // A bridge is a directional port: local listeners receive incoming events,
    // fire goes to the other side. Delivering the fire locally as well would
    // feed a listener that fires the same topic straight back into itself.
    // Local pub/sub belongs to an ordinary EventBus (Layer.current in Layers).
    return _link.remoteInterest.hasListener(topic) &&
        _link.fire(EventDTO<T>(data, topic: topic, arguments: arguments));
  }

  @override
  Future<dynamic> request<T>(T data,
      {List<String>? paths,
      String? separator,
      Map<String, String>? arguments,
      Duration? timeout,
      CancelToken? cancelToken}) async {
    if (isDisposed) {
      throw StateError('EventBusIsolate is disposed');
    }
    if (!_ready) {
      throw StateError(
          'EventBusIsolate is not initialized: await waitInit before request');
    }
    _rejectWildcardPaths(paths, 'request');
    final topic = Topic.create<T>(
        paths: paths, separator: separator ?? defaultTopicPathSeparator);
    if (cancelToken?.isCancelled ?? false) {
      throw RequestCanceledException(topic.topic);
    }
    if (haveHandler<T>(paths: paths, separator: separator)) {
      return super.request<T>(data,
          paths: paths,
          separator: separator,
          arguments: arguments,
          timeout: timeout,
          cancelToken: cancelToken);
    }
    if (!_link.remoteInterest.hasHandler(topic)) {
      throw NoHandlerException(topic.topic);
    }
    return _link.request(
        EventDTO<T>(data, topic: topic, arguments: arguments),
        timeout: timeout,
        cancelToken: cancelToken);
  }

  @override
  void _onListenerInterestChanged(Topic topic, bool present) {
    _link.interest(topic, listener: true, handler: false, present: present);
  }

  @override
  void _onHandlerInterestChanged(Topic topic, bool present) {
    _link.interest(topic, listener: false, handler: true, present: present);
  }

  @override
  void _onModelInterestChanged(Topic topic, bool present) {
    _link.interest(topic,
        listener: false, handler: false, model: true, present: present);
  }

  @override
  void _onTopicInterestRemoved(Topic topic) {
    _link.interest(topic,
        listener: true, handler: true, model: true, present: false);
  }

  void _sendInterestSnapshot() {
    for (final topic in _listenerCounts.keys) {
      _link.interest(topic, listener: true, handler: false, present: true);
    }
    for (final topic in _handlerCounts.keys) {
      _link.interest(topic, listener: false, handler: true, present: true);
    }
    for (final topic in _modelTopics) {
      _link.interest(topic,
          listener: false, handler: false, model: true, present: true);
    }
  }

  ///Removes the topic on this side and asks the worker to remove it too.
  ///
  ///The call is synchronous for the main-side bus; the worker applies the
  ///delete in message order before the next event sent to it. A handler
  ///registered in the worker for this topic stays; cancel its handler
  ///subscription on the worker bus for a full forget.
  @override
  bool removeTopic<T>({List<String>? paths, String? separator}) {
    if (isDisposed) {
      throw StateError('EventBusIsolate is disposed');
    }
    if (!_ready) {
      throw StateError(
          'EventBusIsolate is not initialized: await waitInit before removeTopic');
    }
    final topic = Topic.create<T>(
        paths: paths, separator: separator ?? defaultTopicPathSeparator);
    if (TopicPattern.isPattern(topic)) {
      TopicPattern.validate(topic);
    }
    final removed = _removeTopicLocally(topic);
    _link.removeTopic(topic);
    return removed;
  }

  ///Liveness check: true if the worker replied within [timeout].
  ///Readiness (a finished onInit) is reported by [waitInit] and [isInit].
  Future<bool> ping({Duration timeout = const Duration(seconds: 2)}) =>
      _link.ping(timeout);

  @override
  Future<void> dispose() async {
    if (isDisposed) {
      return;
    }
    // fail the pending replies first, then kill the isolate: otherwise a pending await hangs
    _generation++; // invalidate every callback of the current worker
    _completeInitResult(false);
    _link.failAllPending('EventBusIsolate is disposed');
    await super.dispose();
    _receivePort?.close();
    _receivePort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }

  void _completeInitResult(bool value) {
    if (!_completerInit.isCompleted) {
      _completerInit.complete(value);
    }
  }

  void _completeInitError(Object error, [StackTrace? stackTrace]) {
    if (!_completerInit.isCompleted) {
      _completerInit.completeError(error, stackTrace);
    }
  }

  Future<void> _init() async {
    if (isDisposed) return;
    final generation = ++_generation;
    final receivePort = ReceivePort();
    _receivePort = receivePort;
    try {
      final isolate = await Isolate.spawn(_worker,
          [receivePort.sendPort, onInit, _initialData, _workerIsModelBus]);
      if (generation != _generation || isDisposed) {
        // superseded by a restart or by dispose
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = isolate;
      // A ReceivePort stays open when the isolate dies: the port's onDone fires
      // only when we close it ourselves, so the death is reported explicitly.
      isolate.addOnExitListener(receivePort.sendPort,
          response: _isolateExitMessage);
    } catch (error, stackTrace) {
      if (generation != _generation) return;
      receivePort.close();
      if (identical(_receivePort, receivePort)) _receivePort = null;
      reportError(EventBusError(
        kind: EventBusErrorKind.isolateInit,
        source: EventBusErrorSource.isolate,
        error: error,
        stackTrace: stackTrace,
      ));
      _completeInitError(
          EventBusException('Isolate.spawn failed: $error'), stackTrace);
      return;
    }

    receivePort.listen(
      (message) {
        if (generation != _generation) return;
        if (message is SendPort) {
          _link.sendPort = message;
          _sendInterestSnapshot();
        } else if (message is _IsolateReady) {
          _ready = true;
          _completeInitResult(true);
        } else if (message is _IsolateInitError) {
          _ready = false;
          reportError(EventBusError(
            kind: EventBusErrorKind.isolateInit,
            source: EventBusErrorSource.isolate,
            error: message.error,
            stackTrace: message.stackTrace,
          ));
          _completeInitError(
              EventBusException('worker onInit failed: ${message.error}'),
              message.stackTrace);
          // Kill the idle worker but keep this bus usable for a restart. The
          // owner (pool, Layers supervisor, or the user) decides whether to
          // retry; a plain user should dispose the bus.
          _workerGone = true;
          final port = _receivePort;
          _receivePort = null;
          port?.close();
          final isolate = _isolate;
          _isolate = null;
          isolate?.kill(priority: Isolate.immediate);
        } else if (message == _isolateExitMessage) {
          _onWorkerGone();
          if (identical(_receivePort, receivePort)) {
            _receivePort = null;
            receivePort.close();
          }
        } else {
          _link.handleMessage(message);
        }
      },
      onDone: () {
        if (generation != _generation) return;
        _onWorkerGone();
        if (identical(_receivePort, receivePort)) _receivePort = null;
      },
    );
  }

  ///Accounts for a terminated worker exactly once, whether the death came from
  ///the exit listener or from our own explicit dispose.
  void _onWorkerGone() {
    if (_workerGone) return;
    _workerGone = true;
    _ready = false;
    _link.failAllPending('worker isolate has died');
    if (isDisposed) {
      // we closed the isolate ourselves - this is not an error
      _completeInitResult(false);
    } else {
      reportError(EventBusError(
        kind: EventBusErrorKind.isolateDeath,
        source: EventBusErrorSource.isolate,
        error: EventBusException('worker isolate has died'),
      ));
      _completeInitError(EventBusException('worker isolate has died'));
    }
  }

  ///A failure of a layer below this bridge, forwarded by the worker chain.
  void _reportRemoteFailure(String message) {
    _ready = false;
    reportError(EventBusError(
      kind: EventBusErrorKind.isolateDeath,
      source: EventBusErrorSource.isolate,
      error: EventBusException(message),
    ));
  }
}

void _worker(dynamic data) async {
  var sendPort = data[0] as SendPort;
  var onInit = data[1] as FutureOr<void> Function(EventBus, Object?);
  Object? initialData = data[2];
  bool isModelBus = data[3] as bool;
  var innerReceivePort = ReceivePort();
  var s = innerReceivePort.asBroadcastStream();

  // the bus is created before the handshake: its listener subscribes to the port
  // right away, so no message from main can be lost
  var eventBus = _EventBusForIsolate(isModelBus, s, sendPort);
  eventBus._startParentWatchdog();
  sendPort.send(innerReceivePort.sendPort);

  try {
    await onInit(eventBus, initialData);
    eventBus._sendInterestSnapshot();
    sendPort.send(const _IsolateReady());
  } catch (error, stackTrace) {
    sendPort.send(_IsolateInitError(error, stackTrace));
  }

  await for (var _ in s) {
    // keep the isolate alive; events are handled by the bus listener
  }
  eventBus._link.failAllPending('main isolate has closed the port');
  innerReceivePort.close();
}

///In Worker Isolate
///
///Directional like the main side: subscriptions receive events from the main
///isolate, [fire] sends to the main isolate only. Use `Layer.current` for
///pub/sub inside the worker.
class _EventBusForIsolate extends EventBusImpl {
  final Stream<dynamic> _receivePort;
  final SendPort _sendPort;
  late final _IsolateLink _link = _IsolateLink(this);
  Timer? _watchdog;

  _EventBusForIsolate(super._isModelBus, this._receivePort, this._sendPort) {
    _link.sendPort = _sendPort;
    _receivePort.listen(_link.handleMessage);
  }

  ///A worker cannot be notified when its parent isolate dies. It pings the
  ///parent and kills itself when no pong comes; its own child then does the
  ///same, so a dead parent tears the whole subtree down.
  void _startParentWatchdog() {
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (await _link.ping(const Duration(milliseconds: 500))) return;
      _watchdog?.cancel();
      _watchdog = null;
      Isolate.current.kill(priority: Isolate.immediate);
    });
  }

  ///Reports a failure of a lower layer locally and forwards it up the chain.
  void _reportRemoteFailure(String message) {
    reportError(EventBusError(
      kind: EventBusErrorKind.isolateDeath,
      source: EventBusErrorSource.isolate,
      error: EventBusException(message),
    ));
    _link.sendFailure(message);
  }

  ///Sends a failure of this worker's child to the parent.
  void _sendFailure(String message) {
    _link.sendFailure(message);
  }

  @override
  bool fire<T>(T data,
      {List<String>? paths,
      String? separator,
      Map<String, String>? arguments}) {
    if (isDisposed) {
      throw StateError('EventBus is disposed');
    }
    _rejectWildcardPaths(paths, 'fire');
    final topic = Topic.create<T>(
        paths: paths, separator: separator ?? defaultTopicPathSeparator);
    // A bridge is a directional port: local listeners receive incoming events,
    // fire goes to the other side. Delivering the fire locally as well would
    // feed a listener that fires the same topic straight back into itself.
    // Local pub/sub belongs to an ordinary EventBus (Layer.current in Layers).
    return _link.remoteInterest.hasListener(topic) &&
        _link.fire(EventDTO<T>(data, topic: topic, arguments: arguments));
  }

  @override
  Future<dynamic> request<T>(T data,
      {List<String>? paths,
      String? separator,
      Map<String, String>? arguments,
      Duration? timeout,
      CancelToken? cancelToken}) async {
    if (isDisposed) {
      throw StateError('EventBus is disposed');
    }
    _rejectWildcardPaths(paths, 'request');
    final topic = Topic.create<T>(
        paths: paths, separator: separator ?? defaultTopicPathSeparator);
    if (cancelToken?.isCancelled ?? false) {
      throw RequestCanceledException(topic.topic);
    }
    if (haveHandler<T>(paths: paths, separator: separator)) {
      return super.request<T>(data,
          paths: paths,
          separator: separator,
          arguments: arguments,
          timeout: timeout,
          cancelToken: cancelToken);
    }
    if (!_link.remoteInterest.hasHandler(topic)) {
      throw NoHandlerException(topic.topic);
    }
    return _link.request(
        EventDTO<T>(data, topic: topic, arguments: arguments),
        timeout: timeout,
        cancelToken: cancelToken);
  }

  @override
  void _onListenerInterestChanged(Topic topic, bool present) {
    _link.interest(topic, listener: true, handler: false, present: present);
  }

  @override
  void _onHandlerInterestChanged(Topic topic, bool present) {
    _link.interest(topic, listener: false, handler: true, present: present);
  }

  @override
  void _onModelInterestChanged(Topic topic, bool present) {
    _link.interest(topic,
        listener: false, handler: false, model: true, present: present);
  }

  @override
  void _onTopicInterestRemoved(Topic topic) {
    _link.interest(topic,
        listener: true, handler: true, model: true, present: false);
  }

  void _sendInterestSnapshot() {
    for (final topic in _listenerCounts.keys) {
      _link.interest(topic, listener: true, handler: false, present: true);
    }
    for (final topic in _handlerCounts.keys) {
      _link.interest(topic, listener: false, handler: true, present: true);
    }
    for (final topic in _modelTopics) {
      _link.interest(topic,
          listener: false, handler: false, model: true, present: true);
    }
  }

  ///Removes the topic on this side and asks the main isolate to remove it too.
  @override
  bool removeTopic<T>({List<String>? paths, String? separator}) {
    if (isDisposed) {
      throw StateError('EventBus is disposed');
    }
    final topic = Topic.create<T>(
        paths: paths, separator: separator ?? defaultTopicPathSeparator);
    if (TopicPattern.isPattern(topic)) {
      TopicPattern.validate(topic);
    }
    final removed = _removeTopicLocally(topic);
    _link.removeTopic(topic);
    return removed;
  }
}
