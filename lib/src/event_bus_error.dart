part of event_arch;

///The category of an [EventBusError].
enum EventBusErrorKind {
  listener,
  handler,
  serialization,
  deserialization,
  transport,
  isolateInit,
  isolateDeath,
  requestTimeout,
  requestCanceled,
  bufferOverflow,
  busy,
  supervision,
  dispose,
  other,
}

///Where an [EventBusError] came from.
enum EventBusErrorSource { core, isolate, transport, supervision }

///One observable bus failure.
///
///Errors are delivered as data through [EventBus.errors], never as stream
///errors, so a listener without an `onError` does not turn every bus failure
///into an unhandled zone error. The payload is redacted by default: [event] is
///null unless payload capture is enabled.
class EventBusError {
  EventBusError({
    required this.kind,
    required this.error,
    this.source = EventBusErrorSource.core,
    this.topic,
    this.event,
    this.stackTrace,
    this.context = const <String, String>{},
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final EventBusErrorKind kind;
  final EventBusErrorSource source;

  ///The topic involved, when the error has one.
  final String? topic;

  ///The event involved; null unless payload capture is enabled.
  final EventDTO? event;

  ///The underlying error.
  final Object error;

  final StackTrace? stackTrace;
  final DateTime timestamp;

  ///Small, redaction-safe labels (capacity, count, transport name, ...).
  final Map<String, String> context;

  @override
  String toString() {
    final where = topic == null ? '' : ' on "$topic"';
    return 'EventBusError(${kind.name}$where): $error';
  }
}

///An aggregator over the error streams of several buses.
///
///It is not a static global: tests and applications keep their own monitor,
///so several applications in one process do not share state.
class EventBusErrorMonitor {
  final Map<EventBus, StreamSubscription<EventBusError>> _subscriptions = {};
  final StreamController<EventBusError> _controller =
      StreamController<EventBusError>.broadcast();
  final List<EventBusError> _recent = <EventBusError>[];
  final Map<EventBusErrorKind, int> _counts = <EventBusErrorKind, int>{};

  ///Merged errors of every registered bus.
  Stream<EventBusError> get errors => _controller.stream;

  ///The most recent errors, up to 100.
  List<EventBusError> get recentErrors => List<EventBusError>.unmodifiable(_recent);

  ///Counts by kind since [resetCounters] or construction.
  Map<EventBusErrorKind, int> get counts =>
      Map<EventBusErrorKind, int>.unmodifiable(_counts);

  ///Starts observing [bus]. Returns false when it is already observed.
  bool add(EventBus bus) {
    if (_subscriptions.containsKey(bus)) return false;
    _subscriptions[bus] = bus.errors.listen((error) {
      _counts[error.kind] = (_counts[error.kind] ?? 0) + 1;
      _recent.add(error);
      if (_recent.length > 100) _recent.removeAt(0);
      if (!_controller.isClosed) _controller.add(error);
    });
    return true;
  }

  ///Stops observing [bus]. Returns false when it was not observed.
  bool remove(EventBus bus) {
    final subscription = _subscriptions.remove(bus);
    if (subscription == null) return false;
    unawaited(subscription.cancel());
    return true;
  }

  ///Clears [counts]; [recentErrors] is kept.
  void resetCounters() => _counts.clear();

  ///Stops observing every bus and closes the merged stream.
  Future<void> dispose() async {
    final subscriptions = _subscriptions.values.toList(growable: false);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await _controller.close();
  }
}
