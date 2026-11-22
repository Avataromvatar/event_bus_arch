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
    String? topic,
    String? address,
    this.event,
    this.correlationId,
    this.stackTrace,
    this.context = const <String, String>{},
    DateTime? timestamp,
  })  : topic = address ?? topic,
        timestamp = timestamp ?? DateTime.now();

  final EventBusErrorKind kind;
  final EventBusErrorSource source;

  ///The event address involved, when the error has one.
  ///
  ///This is the E name for the legacy [topic] field; both hold the same string.
  String? get address => topic;

  ///The topic/address involved, when the error has one.
  final String? topic;

  ///The event involved; null unless payload capture is enabled.
  final EventDTO? event;

  ///The correlation id of the event involved, when one was known.
  final String? correlationId;

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

///A predicate that decides whether the monitor accepts an error.
typedef EventBusErrorFilter = bool Function(EventBusError error);

///A consistent view of a monitor's counters and its bounded recent buffer.
class EventBusErrorSnapshot {
  const EventBusErrorSnapshot({
    required this.total,
    required this.suppressed,
    required this.byKind,
    required this.byTopic,
    required this.recent,
  });

  final int total;

  ///Errors dropped by the monitor's own per-second limit.
  final int suppressed;

  final Map<EventBusErrorKind, int> byKind;

  ///Counts keyed by topic; errors without a topic use `__none__`.
  final Map<String, int> byTopic;

  final List<EventBusError> recent;

  @override
  String toString() =>
      'EventBusErrorSnapshot(total: $total, suppressed: $suppressed)';
}

///An aggregator over the error streams of several buses.
///
///It is not a static global: tests and applications keep their own monitor,
///so several applications in one process do not share state. [filter] runs
///before counting; the per-second [maxErrorsPerSecond] limit protects a
///dashboard from a storm coming from many buses at once, while each bus keeps
///its own per-`(kind, topic)` limit (ADR-0004).
class EventBusErrorMonitor {
  EventBusErrorMonitor({
    this.filter,
    this.recentLimit = 100,
    this.maxErrorsPerSecond = 200,
  })  : assert(recentLimit >= 0),
        assert(maxErrorsPerSecond == null || maxErrorsPerSecond > 0);

  final EventBusErrorFilter? filter;
  final int recentLimit;

  ///The monitor-wide limit; null means unlimited.
  final int? maxErrorsPerSecond;

  final Map<EventBus, StreamSubscription<EventBusError>> _subscriptions = {};
  final StreamController<EventBusError> _controller =
      StreamController<EventBusError>.broadcast();
  final List<EventBusError> _recent = <EventBusError>[];
  final Map<EventBusErrorKind, int> _counts = <EventBusErrorKind, int>{};
  final Map<String, int> _byTopic = <String, int>{};
  final List<DateTime> _window = <DateTime>[];
  int _total = 0;
  int _suppressed = 0;

  ///Merged errors of every registered bus.
  Stream<EventBusError> get errors => _controller.stream;

  ///The most recent errors, up to [recentLimit].
  List<EventBusError> get recentErrors =>
      List<EventBusError>.unmodifiable(_recent);

  ///Counts by kind since [resetCounters] or construction.
  Map<EventBusErrorKind, int> get counts =>
      Map<EventBusErrorKind, int>.unmodifiable(_counts);

  ///Errors dropped by the monitor-wide rate limit.
  int get suppressed => _suppressed;

  ///Starts observing [bus]. Returns false when it is already observed.
  bool add(EventBus bus) {
    if (_subscriptions.containsKey(bus)) return false;
    _subscriptions[bus] = bus.errors.listen(_onError);
    return true;
  }

  void _onError(EventBusError error) {
    final filter = this.filter;
    if (filter != null && !filter(error)) return;
    final limit = maxErrorsPerSecond;
    if (limit != null) {
      final now = DateTime.now();
      _window.removeWhere(
          (time) => now.difference(time) > const Duration(seconds: 1));
      if (_window.length >= limit) {
        _suppressed++;
        return;
      }
      _window.add(now);
    }

    _total++;
    _counts[error.kind] = (_counts[error.kind] ?? 0) + 1;
    final topic = error.topic ?? '__none__';
    _byTopic[topic] = (_byTopic[topic] ?? 0) + 1;
    _recent.add(error);
    while (_recent.length > recentLimit) {
      _recent.removeAt(0);
    }
    if (!_controller.isClosed) {
      _controller.add(error);
    }
  }

  ///Stops observing [bus]. Returns false when it was not observed.
  bool remove(EventBus bus) {
    final subscription = _subscriptions.remove(bus);
    if (subscription == null) return false;
    unawaited(subscription.cancel());
    return true;
  }

  ///Clears the counters (including [suppressed]); [recentErrors] is kept.
  void resetCounters() {
    _counts.clear();
    _byTopic.clear();
    _total = 0;
    _suppressed = 0;
  }

  ///An immutable view of the counters and the recent buffer.
  EventBusErrorSnapshot snapshot() => EventBusErrorSnapshot(
        total: _total,
        suppressed: _suppressed,
        byKind: Map<EventBusErrorKind, int>.unmodifiable(_counts),
        byTopic: Map<String, int>.unmodifiable(_byTopic),
        recent: List<EventBusError>.unmodifiable(_recent),
      );

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
