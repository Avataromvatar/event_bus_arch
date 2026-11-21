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
    required this.deliveryMode,
    required this.cancelOnError,
    required this.onCancel,
    required this.onBusError,
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
  }

  ///The topic this subscription is attached to.
  final Topic topic;

  ///The listener callback. Null means this subscription is not a listener.
  final EventCallback<T>? onEvent;

  ///Delivery timing; see [DeliveryMode].
  final DeliveryMode deliveryMode;

  ///Cancel the subscription after the first listener error.
  final bool cancelOnError;

  ///Called when the subscription is cancelled explicitly.
  final void Function() onCancel;

  ///Receives errors that have no subscription-level handler.
  final void Function(Object error, StackTrace? stackTrace) onBusError;

  ///Optional subscription-level error handler.
  final void Function(Object error, StackTrace? stackTrace)? onError;

  ///Called when the node is disposed, not when the user cancels.
  final void Function()? onDone;

  final Queue<T> _buffer = Queue<T>();
  int? _bufferCapacity;
  BufferOverflow _bufferOverflow;

  bool _paused = false;
  bool _busy = false;
  bool _canceled = false;
  bool _draining = false;
  bool _scheduled = false;

  int _dropped = 0;
  int _delivered = 0;

  StreamController<T>? _view;

  ///True when [pause] was called and [resume] has not.
  bool get isPaused => _paused;

  ///True while an asynchronous [onEvent] future is pending.
  bool get isBusy => _busy;

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
    while (_buffer.length > limit) {
      if (_bufferOverflow == BufferOverflow.dropNewest) {
        _buffer.removeLast();
      } else {
        _buffer.removeFirst();
      }
      _dropped++;
    }
  }

  ///Cancels the subscription: the node stops fanning events out to it and its
  ///buffer is cleared. [onDone] is not called; node disposal calls it.
  Future<void> cancel() async {
    if (_canceled) return;
    _canceled = true;
    _buffer.clear();
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
      return _bufferOverflow != BufferOverflow.reject;
    }
    if (_buffer.length >= capacity) {
      switch (_bufferOverflow) {
        case BufferOverflow.reject:
          _dropped++;
          return false;
        case BufferOverflow.dropNewest:
          _dropped++;
          return true;
        case BufferOverflow.latest:
        case BufferOverflow.dropOldest:
          _buffer.removeFirst();
          _dropped++;
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
          _handleError(error, stackTrace);
        });
      }
      return null;
    } catch (error, stackTrace) {
      _handleError(error, stackTrace);
      return null;
    }
  }

  void _deliverToView(T event) {
    final view = _view;
    if (view != null && !view.isClosed) {
      view.add(event);
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    onError?.call(error, stackTrace);
    onBusError(error, stackTrace);
    if (cancelOnError) {
      unawaited(cancel());
    }
  }

  @override
  String toString() =>
      'EventSubscription<$T>(${topic.topic}, buffered=$buffered, '
      'dropped=$dropped, delivered=$delivered)';
}
