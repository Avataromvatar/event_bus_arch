part of event_arch;

///The callback of a listener subscription.
typedef EventCallback<T> = FutureOr<void> Function(T event);

///What a listener subscription does when its buffer is full.
enum BufferOverflow {
  ///Keep the newest [EventSubscription.bufferCapacity] events.
  latest,

  ///Drop the oldest buffered event.
  dropOldest,

  ///Drop the incoming event.
  dropNewest,

  ///Reject the incoming event; the subscription reports it as not accepted.
  reject,
}

///When a listener callback is invoked relative to the publisher.
enum DeliveryMode {
  ///Deliver in a microtask, preserving the current stream timing.
  async,

  ///Deliver inline inside [EventBus.fire]. Reentrancy-sensitive.
  sync,
}

///A consumer registration created by [EventBus.subscribeEvents].
///
///The subscription owns its delivery state: the buffer, the pause flag and the
///error routing. The node only fans events out to [offer]; it never inspects or
///drops them itself.
///
///A subscription with [onEvent] is a listener. The handler capability is added
///by a later 4.0.0 task; [EventSubscription] is the type that will carry both.
class EventSubscription<T> {
  EventSubscription._({
    required this.topic,
    required this.onEvent,
    required this.handler,
    required this.handlerConcurrency,
    required this.requestQueueCapacity,
    required this.deliveryMode,
    required this.cancelOnError,
    required this.onCancel,
    required this.onBusError,
    this.capturePayloads = false,
    this.trackMetrics = false,
    this.onError,
    this.onDone,
    int? bufferCapacity,
    BufferOverflow bufferOverflow = BufferOverflow.dropOldest,
  })  : _bufferCapacity = bufferCapacity,
        _bufferOverflow = bufferOverflow {
    if (bufferCapacity != null && bufferCapacity < 0) {
      throw ArgumentError.value(
          bufferCapacity, 'bufferCapacity', 'must be null or >= 0');
    }
    if (handlerConcurrency < 1) {
      throw ArgumentError.value(
          handlerConcurrency, 'handlerConcurrency', 'must be >= 1');
    }
    if (requestQueueCapacity < 0) {
      throw ArgumentError.value(
          requestQueueCapacity, 'requestQueueCapacity', 'must be >= 0');
    }
    if (onEvent == null && handler == null) {
      throw ArgumentError(
          'an EventSubscription needs onEvent, handler, or both');
    }
    if (trackMetrics) _queueWait = _LatencyHistogram();
  }

  ///The topic this subscription is attached to.
  final Topic topic;

  ///The listener callback. Null means this subscription is not a listener.
  final EventCallback<T>? onEvent;

  ///The request handler. Null means this subscription is not a responder.
  final Handler<T>? handler;

  ///How many handler invocations may run at the same time.
  final int handlerConcurrency;

  ///How many requests may wait in this subscription's FIFO queue.
  final int requestQueueCapacity;

  ///Delivery timing; see [DeliveryMode].
  final DeliveryMode deliveryMode;

  ///Cancel the subscription after the first listener error.
  final bool cancelOnError;

  ///Attach the event to listener errors. Off by default; set by the bus when
  ///`ObservabilityConfig.capturePayloads` is on.
  final bool capturePayloads;

  ///Track queue depth and queue-wait latency for the metrics snapshot.
  final bool trackMetrics;

  ///Called when the subscription is cancelled explicitly.
  final void Function() onCancel;

  ///Receives errors that have no subscription-level handler.
  final void Function(EventBusError error) onBusError;

  ///Optional subscription-level error handler.
  final void Function(Object error, StackTrace? stackTrace)? onError;

  ///Called when the node is disposed, not when the user cancels.
  final void Function()? onDone;

  final Queue<T> _buffer = Queue<T>();
  final Queue<_RequestEntry> _requestQueue = Queue<_RequestEntry>();
  int? _bufferCapacity;
  BufferOverflow _bufferOverflow;
  _LatencyHistogram? _queueWait;
  int _maxBufferedRequests = 0;

  bool _paused = false;
  bool _busy = false;
  bool _canceled = false;
  bool _draining = false;
  bool _scheduled = false;

  int _inFlight = 0;
  int _dropped = 0;
  int _delivered = 0;

  StreamController<T>? _view;

  ///True when [pause] was called and [resume] has not.
  bool get isPaused => _paused;

  ///True while an asynchronous [onEvent] future is pending.
  bool get isListenerBusy => _busy;

  ///True while the listener is busy or the handler has no free slot.
  bool get isBusy => _busy || isHandlerBusy;

  ///Whether this subscription can answer requests.
  bool get hasHandler => handler != null;

  ///Handler invocations currently running.
  int get inFlight => _inFlight;

  ///True when every handler slot is occupied.
  bool get isHandlerBusy => hasHandler && _inFlight >= handlerConcurrency;

  ///Requests waiting in this subscription's FIFO queue.
  int get bufferedRequests => _requestQueue.length;

  ///Whether a request can be accepted now: a free handler slot or queue room.
  bool get hasRequestCapacity =>
      !_canceled &&
      !_paused &&
      hasHandler &&
      (_inFlight < handlerConcurrency ||
          _requestQueue.length < requestQueueCapacity);

  ///True after [cancel] or node disposal.
  bool get isCanceled => _canceled;

  ///null means unbounded.
  int? get bufferCapacity => _bufferCapacity;

  ///The current overflow policy.
  BufferOverflow get bufferOverflow => _bufferOverflow;

  ///Events waiting in the subscription buffer.
  int get buffered => _buffer.length;

  ///Events dropped by the overflow policy so far.
  int get dropped => _dropped;

  ///Events passed to [onEvent] so far.
  int get delivered => _delivered;

  ///Whether this subscription can receive events right now.
  bool get hasListener =>
      onEvent != null || (_view != null && (_view?.hasListener ?? false));

  ///The largest request queue depth observed.
  int get maxBufferedRequests => _maxBufferedRequests;

  ///Queue-wait latency, recorded only when [trackMetrics] is on.
  LatencySnapshot? get queueWaitLatency => _queueWait?.snapshot();

  ///Whether [data] is of the handler's type.
  bool acceptsData(Object? data) => hasHandler && data is T;

  ///Invokes the handler with a typed DTO and the previous value snapshot.
  Future<dynamic> invokeRequest(EventDTO dto, Object? lastData) {
    final typed = EventDTO<T>(dto.data as T,
        topic: dto.topic,
        arguments: dto.arguments,
        correlationId: dto.correlationId);
    return handler!(typed, lastData as T?);
  }

  ///Accepts a request into a free handler slot or the queue.
  ///
  ///Returns false when the subscription is paused, cancelled, or full.
  bool _enqueueRequest(_RequestEntry entry) {
    if (entry.isFinished || !hasRequestCapacity) return false;
    entry.owner = this;
    if (_inFlight < handlerConcurrency) {
      _startRequest(entry);
    } else {
      if (trackMetrics) {
        entry._queuedAtMicros = DateTime.now().microsecondsSinceEpoch;
        if (_requestQueue.length + 1 > _maxBufferedRequests) {
          _maxBufferedRequests = _requestQueue.length + 1;
        }
      }
      _requestQueue.addLast(entry);
    }
    return true;
  }

  ///Removes a queued request, for example after its timeout or cancellation.
  bool _removeQueuedRequest(_RequestEntry entry) => _requestQueue.remove(entry);

  void _startRequest(_RequestEntry entry) {
    final queuedAt = entry._queuedAtMicros;
    if (queuedAt != null) {
      _queueWait?.record(DateTime.now().microsecondsSinceEpoch - queuedAt);
      entry._queuedAtMicros = null;
    }
    _inFlight++;
    unawaited(entry.run().whenComplete(() {
      _inFlight--;
      _drainRequests();
    }));
  }

  void _drainRequests() {
    if (_canceled || _paused) return;
    while (_inFlight < handlerConcurrency && _requestQueue.isNotEmpty) {
      final entry = _requestQueue.removeFirst();
      if (entry.isFinished) continue;
      _startRequest(entry);
    }
  }

  void _failQueuedRequests() {
    final queued = List<_RequestEntry>.of(_requestQueue);
    _requestQueue.clear();
    for (final entry in queued) {
      entry.fail(NoHandlerException(topic.topic));
    }
  }

  ///A broadcast view of the events delivered to this subscription.
  ///
  ///It is a UI convenience, not a second delivery path with its own buffer:
  ///events are added when the subscription delivers them, so a view with no
  ///listeners loses them.
  Stream<T> get stream {
    if (_canceled) return const Stream.empty();
    final existing = _view;
    if (existing != null) return existing.stream;
    final controller = StreamController<T>.broadcast();
    _view = controller;
    return controller.stream;
  }

  ///Offers an event to the subscription. Returns false when the subscription
  ///rejects it (overflow with [BufferOverflow.reject]), true otherwise.
  bool offer(T event) {
    if (_canceled || !hasListener) return false;

    final idle = !_paused && !_busy && !_draining && !_scheduled;
    if (idle) {
      // The pending event occupies one slot that is not subject to the
      // capacity policy: capacity 0 means "no backlog", not "drop everything".
      _buffer.addLast(event);
      if (deliveryMode == DeliveryMode.sync) {
        _drain();
      } else {
        _scheduleDrain();
      }
      return true;
    }

    final accepted = _bufferEvent(event);
    if (!accepted) return false;

    if (deliveryMode == DeliveryMode.sync) {
      _drain();
    } else {
      _scheduleDrain();
    }
    return true;
  }

  ///Stops delivering new events. Buffered events stay until [resume] or
  ///[cancel].
  void pause() {
    _paused = true;
  }

  ///Resumes delivery from the buffer.
  void resume() {
    if (!_paused || _canceled) return;
    _paused = false;
    if (deliveryMode == DeliveryMode.sync) {
      _drain();
    } else {
      _scheduleDrain();
    }
    _drainRequests();
  }

  ///Changes the buffer size and/or policy at runtime.
  ///
  ///Shrinking the buffer drops the excess according to the current policy and
  ///counts the drops. A capacity of zero clears the buffer.
  void resize(int? capacity, {BufferOverflow? overflow}) {
    if (capacity != null && capacity < 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be null or >= 0');
    }
    _bufferCapacity = capacity;
    if (overflow != null) _bufferOverflow = overflow;

    final limit = _bufferCapacity;
    if (limit == null) return;
    final before = _dropped;
    while (_buffer.length > limit) {
      if (_bufferOverflow == BufferOverflow.dropNewest) {
        _buffer.removeLast();
      } else {
        _buffer.removeFirst();
      }
      _dropped++;
    }
    if (_dropped > before) _reportOverflow(limit);
  }

  ///Cancels the subscription: the node stops fanning events out to it and its
  ///buffer is cleared. [onDone] is not called; node disposal calls it.
  Future<void> cancel() async {
    if (_canceled) return;
    _canceled = true;
    _buffer.clear();
    _failQueuedRequests();
    final view = _view;
    _view = null;
    if (view != null && !view.isClosed) {
      await view.close();
    }
    onCancel();
  }

  ///Closes the subscription because its node is being disposed.
  Future<void> _close() async {
    if (_canceled) return;
    _canceled = true;
    _buffer.clear();
    _failQueuedRequests();
    final view = _view;
    _view = null;
    if (view != null && !view.isClosed) {
      await view.close();
    }
    onDone?.call();
  }

  bool _bufferEvent(T event) {
    final capacity = _bufferCapacity;
    if (capacity == null) {
      _buffer.addLast(event);
      return true;
    }
    if (capacity == 0) {
      _dropped++;
      _reportOverflow(capacity);
      return _bufferOverflow != BufferOverflow.reject;
    }
    if (_buffer.length >= capacity) {
      switch (_bufferOverflow) {
        case BufferOverflow.reject:
          _dropped++;
          _reportOverflow(capacity);
          return false;
        case BufferOverflow.dropNewest:
          _dropped++;
          _reportOverflow(capacity);
          return true;
        case BufferOverflow.latest:
        case BufferOverflow.dropOldest:
          _buffer.removeFirst();
          _dropped++;
          _reportOverflow(capacity);
      }
    }
    _buffer.addLast(event);
    return true;
  }

  void _scheduleDrain() {
    if (_scheduled || _canceled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      _drain();
    });
  }

  void _drain() {
    if (_draining || _canceled) return;
    _draining = true;
    try {
      while (!_canceled && !_paused && !_busy && _buffer.isNotEmpty) {
        final event = _buffer.removeFirst();
        final result = _invoke(event);
        if (result is Future) {
          _busy = true;
          result.whenComplete(() {
            _busy = false;
            _scheduleDrain();
          });
          return;
        }
      }
    } finally {
      _draining = false;
    }
  }

  FutureOr<void> _invoke(T event) {
    _deliverToView(event);
    final callback = onEvent;
    if (callback == null) return null;
    try {
      final result = callback(event);
      _delivered++;
      if (result is Future) {
        return result.catchError((Object error, StackTrace stackTrace) {
          _handleError(error, stackTrace, event);
        });
      }
      return null;
    } catch (error, stackTrace) {
      _handleError(error, stackTrace, event);
      return null;
    }
  }

  void _deliverToView(T event) {
    final view = _view;
    if (view != null && !view.isClosed) {
      view.add(event);
    }
  }

  void _handleError(Object error, StackTrace stackTrace, T event) {
    onError?.call(error, stackTrace);
    onBusError(EventBusError(
      kind: EventBusErrorKind.listener,
      topic: topic.topic,
      error: error,
      stackTrace: stackTrace,
      event: capturePayloads ? EventDTO<T>(event, topic: topic) : null,
    ));
    if (cancelOnError) {
      unawaited(cancel());
    }
  }

  void _reportOverflow(int capacity) {
    onBusError(EventBusError(
      kind: EventBusErrorKind.bufferOverflow,
      topic: topic.topic,
      error: EventBusException(
          'listener buffer overflow for "${topic.topic}"'),
      context: {'capacity': '$capacity', 'dropped': '$_dropped'},
    ));
  }

  @override
  String toString() =>
      'EventSubscription<$T>(${topic.topic}, buffered=$buffered, '
      'dropped=$dropped, delivered=$delivered, inFlight=$inFlight)';
}

///A cooperative cancellation signal for [EventBus.request].
class CancelToken {
  final Completer<void> _cancelled = Completer<void>();
  Object? _reason;

  ///True once [cancel] was called.
  bool get isCancelled => _cancelled.isCompleted;

  ///Completes when [cancel] is called.
  Future<void> get whenCancelled => _cancelled.future;

  ///The reason passed to [cancel], when any.
  Object? get reason => _reason;

  ///Cancels the requests that listen to this token. Repeated calls are safe.
  void cancel([Object? reason]) {
    if (_cancelled.isCompleted) return;
    _reason = reason;
    _cancelled.complete();
  }
}

///One request waiting for a handler slot or running in a handler subscription.
///
///The entry owns the caller's completer, the timeout timer and the cancellation
///hook. The subscription only manages the queue and the in-flight count.
class _RequestEntry {
  _RequestEntry({
    required this.topic,
    required this.invoke,
    this.onBusError,
  });

  final String topic;
  final Future<dynamic> Function() invoke;
  final void Function(EventBusError error)? onBusError;
  final Completer<dynamic> completer = Completer<dynamic>();

  EventSubscription? owner;

  ///When the request was put into the queue; only set when metrics are on.
  int? _queuedAtMicros;

  ///The request event, available only when observability is enabled. Used for
  ///payload capture and the correlation id in error envelopes.
  EventDTO? dto;
  bool capturePayloads = false;

  ///One metric outcome per request; set by the bus only when metrics are on.
  void Function(RequestOutcome outcome)? onFinished;
  bool _outcomeReported = false;

  Timer? _timer;
  bool _finished = false;
  bool _cancelled = false;

  Future<dynamic> get future => completer.future;
  bool get isFinished => _finished;
  bool get isCancelled => _cancelled;

  void _reportOutcome(RequestOutcome outcome) {
    if (_outcomeReported) return;
    _outcomeReported = true;
    onFinished?.call(outcome);
  }

  EventBusError _errorEnvelope(EventBusErrorKind kind, Object error,
      [StackTrace? stackTrace]) {
    return EventBusError(
      kind: kind,
      topic: topic,
      error: error,
      stackTrace: stackTrace,
      event: capturePayloads ? dto : null,
      correlationId: dto?.correlationId,
    );
  }

  ///Starts the timeout and/or attaches the cancellation token.
  void arm({Duration? timeout, CancelToken? cancelToken}) {
    if (timeout != null) {
      _timer = Timer(timeout, () {
        cancel(RequestTimeoutException(topic, timeout));
      });
    }

    final token = cancelToken;
    if (token != null) {
      if (token.isCancelled) {
        cancel(RequestCanceledException(topic));
      } else {
        token.whenCancelled.then((_) {
          cancel(RequestCanceledException(topic));
        });
      }
    }
  }

  ///Completes the caller's future with [error] and removes the entry from its
  ///queue. A dispatched handler keeps running; its result is ignored.
  void cancel(Object error) {
    if (_finished) return;
    _cancelled = true;
    _finished = true;
    _timer?.cancel();
    _timer = null;
    owner?._removeQueuedRequest(this);
    if (!completer.isCompleted) completer.completeError(error);
    onBusError?.call(_errorEnvelope(
      error is RequestTimeoutException
          ? EventBusErrorKind.requestTimeout
          : error is RequestCanceledException
              ? EventBusErrorKind.requestCanceled
              : EventBusErrorKind.other,
      error,
    ));
    _reportOutcome(error is RequestTimeoutException
        ? RequestOutcome.timeout
        : error is RequestCanceledException
            ? RequestOutcome.canceled
            : RequestOutcome.errored);
  }

  ///Fails a queued entry because its subscription was cancelled or disposed.
  void fail(Object error) {
    if (_finished) return;
    _cancelled = true;
    _finished = true;
    _timer?.cancel();
    _timer = null;
    owner?._removeQueuedRequest(this);
    if (!completer.isCompleted) completer.completeError(error);
    onBusError?.call(_errorEnvelope(EventBusErrorKind.other, error));
    _reportOutcome(error is BusyException
        ? RequestOutcome.busy
        : error is NoHandlerException
            ? RequestOutcome.noHandler
            : RequestOutcome.errored);
  }

  ///Runs the handler. The future never throws: an error goes to the caller's
  ///completer, so the subscription can always release the in-flight slot.
  Future<void> run() async {
    try {
      final result = await invoke();
      if (!completer.isCompleted) completer.complete(result);
      _reportOutcome(RequestOutcome.completed);
    } catch (error, stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
      onBusError?.call(_errorEnvelope(
          EventBusErrorKind.handler, error, stackTrace));
      _reportOutcome(RequestOutcome.errored);
    } finally {
      _finished = true;
      _timer?.cancel();
      _timer = null;
    }
  }
}
