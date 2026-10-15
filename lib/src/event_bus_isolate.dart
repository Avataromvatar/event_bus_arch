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

///A bus event sent to the other side. [id] is unique per sender.
class _IsolateRequest {
  final int id;
  final EventDTO dto;
  const _IsolateRequest(this.id, this.dto);
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
  _PendingRequest(this.completer, this.topic);
}

///Shared part of the exchange for both sides: id counter, pending replies, dispatch.
class _IsolateLink {
  _IsolateLink(this._host);

  final EventBusMixin _host;

  ///Port to the other side. On the worker side it is known from the start, on the
  ///main side it appears after the handshake.
  SendPort? sendPort;

  int _nextId = 0;
  final Map<int, _PendingRequest> _pending = {};
  final Map<int, Completer<bool>> _pings = {};
  bool _closed = false;

  bool get isClosed => _closed;

  int _newId() => _nextId++;

  ///Sends an event to the other side and waits for the handler result.
  Future<dynamic> request(EventDTO dto) {
    var port = sendPort;
    if (port == null || _closed) {
      return Future.error(EventBusException(
          'EventBusIsolate is not available (ready=${port != null}, closed=$_closed)'));
    }
    var id = _newId();
    var completer = Completer<dynamic>();
    _pending[id] = _PendingRequest(completer, dto.topic.topic);
    port.send(_IsolateRequest(id, dto));
    return completer.future;
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
      _pending.remove(message.id)?.completer.complete(message.value);
    } else if (message is _IsolateErrorResponse) {
      _pending.remove(message.id)?.completer.completeError(message.error, message.stackTrace);
    } else if (message is _IsolatePong) {
      _pings.remove(message.id)?.complete(true);
    } else if (message is _IsolatePing) {
      sendPort?.send(_IsolatePong(message.id));
    } else if (message is _IsolateRequest) {
      unawaited(_answer(message));
    }
    // any other message (including late replies) is ignored
  }

  ///Runs an incoming request on the local bus and replies to the sender.
  Future<void> _answer(_IsolateRequest request) async {
    var port = sendPort;
    if (port == null || _closed) {
      return;
    }
    try {
      var value = await _dispatchIncoming(_host, request.dto);
      if (!_closed) {
        port.send(_IsolateResponse(request.id, value));
      }
    } catch (error, stackTrace) {
      if (!_closed) {
        port.send(_IsolateErrorResponse(request.id, error, stackTrace));
      }
    }
  }

  ///Fails every pending reply: called on dispose and when the port closes, so
  ///that `await send(...)` never hangs forever.
  void failAllPending(Object error) {
    _closed = true;
    for (var pending in _pending.values) {
      if (!pending.completer.isCompleted) {
        pending.completer
            .completeError(EventBusException('$error (pending event "${pending.topic}")'));
      }
    }
    _pending.clear();
    for (var ping in _pings.values) {
      if (!ping.isCompleted) {
        ping.complete(false);
      }
    }
    _pings.clear();
  }
}

///Dispatches an event that came from the other isolate: hands it to the local
///nodes and returns the handler result. It always completes its completer, so a
///reply reaches the sender in any case.
Future? _dispatchIncoming(EventBusMixin bus, EventDTO dto) {
  var completer = Completer();
  var dtoCopy = EventDTOImpl(dto.topic, dto.data, completer: completer);
  var node = bus._eventsMap[dtoCopy.topic];
  if (node != null) {
    node.send(dtoCopy);
    bus._addAllEvent(dtoCopy, true);
    return completer.future;
  }
  bus._addAllEvent(dtoCopy, false);
  return null;
}

///Atention The result of calling the event can be received later than the events called in the event handler on the isolate side
///
///EventBusIsolate it consists of two Event bus, one on the side of the main isolate and the other in the working isolate.
///They exchange EventDTO and the results of the handlers' work among themselves.
///
///`waitInit` completes once the worker has run `onInit`; before that
///`send`/`listen`/`subscribe` throw StateError. Replies are correlated by
///request id, so concurrent requests of the same type never get swapped.
class EventBusIsolate extends EventBusImpl {
  ///Worker init function. May be async: `waitInit` waits for it to finish.
  ///Must be top-level/static - closures cannot be sent to another isolate.
  final FutureOr<void> Function(EventBus isolateBu, Object? initialData) onInit;

  late final _IsolateLink _link = _IsolateLink(this);

  Isolate? _isolate;

  /// this port listen data from isolate
  ReceivePort? _receivePort;

  final Completer<bool> _completerInit = Completer();

  ///true once the worker has run onInit
  bool _ready = false;

  ///Completes with true once the worker has run `onInit`, or with an error when
  ///the isolate could not be spawned or onInit threw.
  Future<bool> get waitInit => _completerInit.future;

  ///true after a successful worker initialization
  bool get isInit => _ready;

  EventBusIsolate({
    required this.onInit,
    Object? initialData,
    @Deprecated('Use initialData') Object? initalData,
  }) : super(false) {
    _init(initalData: initialData ?? initalData);
  }

  @override
  Future<dynamic> send<T>(T data, {String? path, String? fragment, String? target, Map<String, String>? arguments}) async {
    if (isDisposed) {
      throw StateError('EventBusIsolate is disposed');
    }
    if (!_ready) {
      throw StateError('EventBusIsolate is not initialized: await waitInit before send');
    }
    var dto =
        EventDTO<T>(data, path: path, fragment: fragment, arguments: arguments, target: target, completer: null);
    return _link.request(dto);
  }

  ///Liveness check: true if the worker replied within [timeout].
  ///Readiness (a finished onInit) is reported by [waitInit] and [isInit].
  Future<bool> ping({Duration timeout = const Duration(seconds: 2)}) => _link.ping(timeout);

  @override
  Future<void> dispose() async {
    if (isDisposed) {
      return;
    }
    // fail the pending replies first, then kill the isolate: otherwise a pending await hangs
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

  void _init({
    Object? initalData,
  }) async {
    _receivePort = ReceivePort();
    try {
      _isolate = await Isolate.spawn(_worker, [_receivePort!.sendPort, onInit, initalData]);
    } catch (error, stackTrace) {
      _completeInitError(EventBusException('Isolate.spawn failed: $error'), stackTrace);
      return;
    }

    _receivePort!.listen(
      (message) {
        if (message is SendPort) {
          _link.sendPort = message;
        } else if (message is _IsolateReady) {
          _ready = true;
          _completeInitResult(true);
        } else if (message is _IsolateInitError) {
          _ready = false;
          _completeInitError(
              EventBusException('worker onInit failed: ${message.error}'), message.stackTrace);
          // a broken isolate is useless: release its resources
          unawaited(dispose());
        } else {
          _link.handleMessage(message);
        }
      },
      onDone: () {
        _ready = false;
        _link.failAllPending('worker isolate has died');
        if (isDisposed) {
          // we closed the isolate ourselves - this is not an error
          _completeInitResult(false);
        } else {
          _completeInitError(EventBusException('worker isolate has died'));
        }
        _receivePort = null;
      },
    );
  }
}

void _worker(dynamic data) async {
  var sendPort = data[0] as SendPort;
  var onInit = data[1] as FutureOr<void> Function(EventBus, Object?);
  Object? initalData = data[2];

  var innerReceivePort = ReceivePort();
  var s = innerReceivePort.asBroadcastStream();

  // the bus is created before the handshake: its listener subscribes to the port
  // right away, so no message from main can be lost
  var eventBus = _EventBusForIsolate(false, s, sendPort);
  sendPort.send(innerReceivePort.sendPort);

  try {
    await onInit(eventBus, initalData);
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
class _EventBusForIsolate extends EventBusImpl {
  final Stream<dynamic> _receivePort;
  final SendPort _sendPort;
  late final _IsolateLink _link = _IsolateLink(this);

  _EventBusForIsolate(super._isModelBus, this._receivePort, this._sendPort) {
    _link.sendPort = _sendPort;
    _receivePort.listen(_link.handleMessage);
  }

  @override
  Future<dynamic> send<T>(T data, {String? path, String? fragment, String? target, Map<String, String>? arguments}) async {
    if (isDisposed) {
      throw StateError('EventBus is disposed');
    }
    var dto =
        EventDTO<T>(data, path: path, fragment: fragment, arguments: arguments, target: target, completer: null);
    return _link.request(dto);
  }
}
