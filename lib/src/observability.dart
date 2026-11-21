part of event_arch;

///Builds the metrics key of a topic.
///
///The default key is the event type token only, so a dynamic path such as
///`session.<id>` cannot grow the registry without bound. An application that
///wants more detail can supply a builder and rely on [cardinalityLimit].
typedef MetricKeyBuilder = String Function(Topic topic);

///Observability switches, configured once at bus construction.
///
///The default is completely off: no counters, no timestamps and no allocation
///on the hot path. When [enabled] is true, [metrics] controls the metric
///counters; [tracing] is reserved for span exporters and does not affect
///metrics.
class ObservabilityConfig {
  const ObservabilityConfig({
    this.enabled = false,
    this.metrics = true,
    this.tracing = false,
    this.sampleRate = 1.0,
    this.cardinalityLimit = 1000,
    this.capturePayloads = false,
    this.metricKeyBuilder,
  })  : assert(sampleRate >= 0.0 && sampleRate <= 1.0),
        assert(cardinalityLimit >= 1);

  ///The default: nothing is collected.
  static const ObservabilityConfig disabled = ObservabilityConfig();

  final bool enabled;

  ///Collect counters and latency samples. Only meaningful when [enabled].
  final bool metrics;

  ///Reserved for tracing exporters; metrics never depend on it.
  final bool tracing;

  ///The fraction of latency samples to record (1.0 records every sample).
  ///Counters are always exact.
  final double sampleRate;

  ///The maximum number of distinct metric keys; the rest go to `__other__`.
  final int cardinalityLimit;

  ///Attach the event to [EventBusError.event]. Off by default: errors carry no
  ///payload unless the application asks for it.
  final bool capturePayloads;

  ///Overrides the metric key; null means the event type token.
  final MetricKeyBuilder? metricKeyBuilder;
}

const List<int> _latencyBoundsMicros = <int>[
  10,
  100,
  1000,
  10000,
  100000,
  1000000,
];

///A fixed-bucket latency histogram as seen in a metrics snapshot.
class LatencySnapshot {
  const LatencySnapshot({
    required this.count,
    required this.maxMicros,
    required this.meanMicros,
    required this.bucketCounts,
    required this.boundsMicros,
  });

  final int count;
  final int maxMicros;
  final int meanMicros;

  ///Counts per bucket; the last bucket has no upper bound.
  final List<int> bucketCounts;

  ///The upper bound (inclusive) of every bucket except the last.
  final List<int> boundsMicros;

  @override
  String toString() => 'LatencySnapshot(count: $count, '
      'max: ${maxMicros}us, mean: ${meanMicros}us)';
}

class _LatencyHistogram {
  final List<int> _buckets =
      List<int>.filled(_latencyBoundsMicros.length + 1, 0);
  int _count = 0;
  int _sum = 0;
  int _max = 0;

  void record(int micros) {
    if (micros < 0) micros = 0;
    _count++;
    _sum += micros;
    if (micros > _max) _max = micros;
    var index = 0;
    while (index < _latencyBoundsMicros.length &&
        micros >= _latencyBoundsMicros[index]) {
      index++;
    }
    _buckets[index]++;
  }

  LatencySnapshot snapshot() => LatencySnapshot(
        count: _count,
        maxMicros: _max,
        meanMicros: _count == 0 ? 0 : _sum ~/ _count,
        bucketCounts: List<int>.unmodifiable(_buckets),
        boundsMicros: List<int>.unmodifiable(_latencyBoundsMicros),
      );
}

///Counters of one metric key.
class _MetricEntry {
  _MetricEntry(this.key);

  final String key;
  int fired = 0;
  int delivered = 0;
  int dropped = 0;
  int bufferOverflow = 0;
  int requestsStarted = 0;
  int requestsCompleted = 0;
  int requestsErrored = 0;
  int requestsTimeout = 0;
  int requestsCanceled = 0;
  int requestsBusy = 0;
  final _LatencyHistogram dispatchLatency = _LatencyHistogram();
  final _LatencyHistogram requestLatency = _LatencyHistogram();

  TopicMetricsSnapshot snapshot() => TopicMetricsSnapshot(
        key: key,
        fired: fired,
        delivered: delivered,
        dropped: dropped,
        bufferOverflow: bufferOverflow,
        requestsStarted: requestsStarted,
        requestsCompleted: requestsCompleted,
        requestsErrored: requestsErrored,
        requestsTimeout: requestsTimeout,
        requestsCanceled: requestsCanceled,
        requestsBusy: requestsBusy,
        dispatchLatency: dispatchLatency.snapshot(),
        requestLatency: requestLatency.snapshot(),
      );
}

///One topic in a metrics snapshot.
class TopicMetricsSnapshot {
  const TopicMetricsSnapshot({
    required this.key,
    required this.fired,
    required this.delivered,
    required this.dropped,
    required this.bufferOverflow,
    required this.requestsStarted,
    required this.requestsCompleted,
    required this.requestsErrored,
    required this.requestsTimeout,
    required this.requestsCanceled,
    required this.requestsBusy,
    required this.dispatchLatency,
    required this.requestLatency,
  });

  final String key;
  final int fired;
  final int delivered;
  final int dropped;
  final int bufferOverflow;
  final int requestsStarted;
  final int requestsCompleted;
  final int requestsErrored;
  final int requestsTimeout;
  final int requestsCanceled;
  final int requestsBusy;
  final LatencySnapshot dispatchLatency;
  final LatencySnapshot requestLatency;

  @override
  String toString() => 'TopicMetrics($key, fired: $fired, '
      'delivered: $delivered, requests: $requestsStarted)';
}

///One subscription in a metrics snapshot.
class SubscriptionMetricsSnapshot {
  const SubscriptionMetricsSnapshot({
    required this.topic,
    required this.pattern,
    required this.hasListener,
    required this.hasHandler,
    required this.isCanceled,
    required this.isBusy,
    required this.delivered,
    required this.dropped,
    required this.buffered,
    required this.bufferedRequests,
    required this.maxBufferedRequests,
    required this.queueWaitLatency,
    required this.inFlight,
    required this.handlerConcurrency,
    required this.requestQueueCapacity,
  });

  final String topic;
  final bool pattern;
  final bool hasListener;
  final bool hasHandler;
  final bool isCanceled;
  final bool isBusy;
  final int delivered;
  final int dropped;
  final int buffered;
  final int bufferedRequests;
  final int maxBufferedRequests;

  ///Queue-wait latency; null when metrics are off for this subscription.
  final LatencySnapshot? queueWaitLatency;
  final int inFlight;
  final int handlerConcurrency;
  final int requestQueueCapacity;

  @override
  String toString() => 'SubscriptionMetrics($topic, '
      'listener: $hasListener, handler: $hasHandler, inFlight: $inFlight)';
}

///An immutable point-in-time view of one bus.
class EventBusMetricsSnapshot {
  const EventBusMetricsSnapshot({
    required this.timestamp,
    required this.fired,
    required this.delivered,
    required this.dropped,
    required this.droppedMetricSeries,
    required this.topics,
    required this.subscriptions,
  });

  final DateTime timestamp;
  final int fired;
  final int delivered;
  final int dropped;

  ///Events whose metric key did not fit [ObservabilityConfig.cardinalityLimit]
  ///and were counted into `__other__`.
  final int droppedMetricSeries;

  final List<TopicMetricsSnapshot> topics;
  final List<SubscriptionMetricsSnapshot> subscriptions;

  @override
  String toString() => 'EventBusMetricsSnapshot(topics: ${topics.length}, '
      'subscriptions: ${subscriptions.length}, fired: $fired)';
}

///What happened to one request, for metrics.
enum RequestOutcome {
  completed,
  errored,
  timeout,
  canceled,
  busy,
  noHandler,
}

///The seam for an external exporter (OpenTelemetry, Prometheus, a dashboard).
///
///The core does not implement an exporter; a consumer calls
///`exporter.export(bus.metrics.snapshot())` on its own schedule or from
///[EventBusMetrics.changes].
abstract interface class EventBusMetricsExporter {
  void export(EventBusMetricsSnapshot snapshot);
}

///Metric collection for one bus.
///
///It is created lazily: while observability is off, [EventBus] never touches
///it on the hot path. [snapshot] is always safe to call and returns an empty
///view when nothing was collected.
///
///The public `record...` methods are called by the bus and by transport and
///isolate adapters; applications normally only read [snapshot] and [changes].
class EventBusMetrics {
  EventBusMetrics(this._bus);

  final EventBusMixin _bus;
  final Map<String, _MetricEntry> _topics = <String, _MetricEntry>{};
  final _MetricEntry _other = _MetricEntry('__other__');
  final StreamController<EventBusMetricsSnapshot> _changes =
      StreamController<EventBusMetricsSnapshot>.broadcast();
  int _droppedSeries = 0;
  int _sampleCounter = 0;
  bool _notifyScheduled = false;

  ///Coalesced live snapshots for dashboards. A snapshot is emitted at most
  ///once per microtask turn and only while the stream has a listener.
  Stream<EventBusMetricsSnapshot> get changes => _changes.stream;

  bool get isEnabled => _bus.observabilityConfig.enabled;

  String _keyFor(Topic topic) {
    final builder = _bus.observabilityConfig.metricKeyBuilder;
    return builder == null ? topic.type : builder(topic);
  }

  _MetricEntry _entryFor(Topic topic) {
    final key = _keyFor(topic);
    final existing = _topics[key];
    if (existing != null) return existing;
    if (_topics.length >= _bus.observabilityConfig.cardinalityLimit) {
      _droppedSeries++;
      return _other;
    }
    final entry = _MetricEntry(key);
    _topics[key] = entry;
    return entry;
  }

  bool _sample() {
    final rate = _bus.observabilityConfig.sampleRate;
    if (rate >= 1.0) return true;
    if (rate <= 0.0) return false;
    final every = (1.0 / rate).round();
    _sampleCounter = (_sampleCounter + 1) % every;
    return _sampleCounter == 0;
  }

  void recordFire(Topic topic,
      {required bool accepted, required int elapsedMicros}) {
    final entry = _entryFor(topic);
    entry.fired++;
    if (accepted) {
      entry.delivered++;
    } else {
      entry.dropped++;
    }
    if (_sample()) entry.dispatchLatency.record(elapsedMicros);
    _notify();
  }

  void recordRequestStarted(Topic topic) {
    _entryFor(topic).requestsStarted++;
    _notify();
  }

  void recordRequestOutcome(
      Topic topic, RequestOutcome outcome, int elapsedMicros) {
    final entry = _entryFor(topic);
    switch (outcome) {
      case RequestOutcome.completed:
        entry.requestsCompleted++;
      case RequestOutcome.errored:
      case RequestOutcome.noHandler:
        entry.requestsErrored++;
      case RequestOutcome.timeout:
        entry.requestsTimeout++;
      case RequestOutcome.canceled:
        entry.requestsCanceled++;
      case RequestOutcome.busy:
        entry.requestsBusy++;
    }
    if (_sample()) entry.requestLatency.record(elapsedMicros);
    _notify();
  }

  ///Counts a listener buffer overflow reported on [topicString].
  void recordOverflow(String? topicString) {
    if (topicString == null) {
      _other.bufferOverflow++;
      _notify();
      return;
    }
    Topic topic;
    try {
      topic = Topic.parse(topicString);
    } catch (_) {
      _other.bufferOverflow++;
      _notify();
      return;
    }
    _entryFor(topic).bufferOverflow++;
    _notify();
  }

  ///A consistent, immutable view of the bus.
  EventBusMetricsSnapshot snapshot() {
    var fired = 0;
    var delivered = 0;
    var dropped = 0;
    final topics = <TopicMetricsSnapshot>[];
    for (final entry in _topics.values) {
      fired += entry.fired;
      delivered += entry.delivered;
      dropped += entry.dropped;
      topics.add(entry.snapshot());
    }
    if (_droppedSeries > 0) {
      topics.add(_other.snapshot());
      fired += _other.fired;
      delivered += _other.delivered;
      dropped += _other.dropped;
    }
    topics.sort((a, b) => a.key.compareTo(b.key));

    final subscriptions = <SubscriptionMetricsSnapshot>[];
    void collect(Map<Topic, EventNode> nodes) {
      for (final entry in nodes.entries) {
        final node = entry.value;
        if (node is! SubscriptionHost) continue;
        final host = node as SubscriptionHost;
        for (final subscription in host.subscriptions) {
          subscriptions.add(SubscriptionMetricsSnapshot(
            topic: entry.key.topic,
            pattern: TopicPattern.isPattern(entry.key),
            hasListener: subscription.hasListener,
            hasHandler: subscription.hasHandler,
            isCanceled: subscription.isCanceled,
            isBusy: subscription.isBusy,
            delivered: subscription.delivered,
            dropped: subscription.dropped,
            buffered: subscription.buffered,
            bufferedRequests: subscription.bufferedRequests,
            maxBufferedRequests: subscription.maxBufferedRequests,
            queueWaitLatency: subscription.queueWaitLatency,
            inFlight: subscription.inFlight,
            handlerConcurrency: subscription.handlerConcurrency,
            requestQueueCapacity: subscription.requestQueueCapacity,
          ));
        }
      }
    }

    collect(_bus._eventsMap);
    collect(_bus._patternMap);
    subscriptions.sort((a, b) => a.topic.compareTo(b.topic));

    return EventBusMetricsSnapshot(
      timestamp: DateTime.now(),
      fired: fired,
      delivered: delivered,
      dropped: dropped,
      droppedMetricSeries: _droppedSeries,
      topics: List<TopicMetricsSnapshot>.unmodifiable(topics),
      subscriptions:
          List<SubscriptionMetricsSnapshot>.unmodifiable(subscriptions),
    );
  }

  void _notify() {
    if (!_changes.hasListener || _notifyScheduled || _changes.isClosed) {
      return;
    }
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_changes.isClosed && _changes.hasListener) {
        _changes.add(snapshot());
      }
    });
  }

  Future<void> dispose() => _changes.close();
}
