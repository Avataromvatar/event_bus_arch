part of event_arch;

///Handler function type for request responders.
///
///The handler receives the event and the previous value of the topic. The
///returned value is the response; an exception becomes the error of the
///request.
typedef Handler<T> = Future<dynamic> Function(EventDTO<T> dto, T? lastData);

///Alias for EventNode type
typedef Node<T> = EventNode<T>;

///A node that must survive the last listener: a transport keeps an incoming
///subscription on it.
abstract class KeepAliveNode {
  bool get keepAlive;
}

///A node that can receive an event from a transport and deliver it to local
///listeners without publishing it back to the transport.
abstract class IncomingEventNode {
  void deliverIncoming(EventDTO dto);
}

///A node holds the current value of a topic and the stream of its listeners.
///Request handlers are registered on the bus, not on the node.
abstract class EventNode<T> {
  T? currentData;
  bool get isDisposed;
  StreamController<T> get streamControllerValue;

  ///Delivers an event to the value stream. Only listeners are notified.
  ///
  ///Returns true when at least one listener accepted the event.
  bool deliver(EventDTO dto);

  EventNode<T> copy();

  ///Disposes of the node, closing all stream controllers and cancelling subscriptions.
  Future<void> dispose();

  factory EventNode.create({
    T? currentData,
  }) {
    return EventNodeImp<T>(currentData: currentData);
  }
}

///A node that can host [EventSubscription]s.
///
///Every built-in node implements it. A custom [EventNode] that wants to support
///[EventBus.subscribeEvents] must implement it too; the bus throws
///[UnsupportedError] otherwise.
abstract class SubscriptionHost<T> {
  Iterable<EventSubscription<T>> get subscriptions;

  void addSubscription(EventSubscription<T> subscription);

  void removeSubscription(EventSubscription<T> subscription);

  ///True when the node has at least one subscription that is not cancelled.
  bool get hasSubscriptions;

  ///True when at least one subscription can receive listener events.
  bool get hasListenerSubscriptions;
}

///EventNodeImp stores the current value and fans events out to listeners.
class EventNodeImp<T> implements EventNode<T>, SubscriptionHost<T> {
  @override
  T? currentData;
  @override
  bool get isDisposed => _streamControllerValue.isClosed;
  final StreamController<T> _streamControllerValue =
      StreamController<T>.broadcast();
  @override
  StreamController<T> get streamControllerValue => _streamControllerValue;

  final List<EventSubscription<T>> _subscriptions = <EventSubscription<T>>[];

  EventNodeImp({this.currentData});

  ///Stores the value and notifies listeners. Request handlers are invoked by
  ///the bus, not here, so the value is scheduled before a handler can complete
  ///the request.
  @override
  bool deliver(EventDTO dto) {
    if (dto.data is! T) return false;
    currentData = dto.data;
    var accepted = _streamControllerValue.hasListener;
    _streamControllerValue.add(dto.data);
    for (final subscription in List<EventSubscription<T>>.of(_subscriptions)) {
      if (subscription.offer(dto.data as T)) accepted = true;
    }
    return accepted;
  }

  ///Creates an independent node with the same current data.
  @override
  EventNode<T> copy() => EventNodeImp<T>(currentData: currentData);

  @override
  Iterable<EventSubscription<T>> get subscriptions => _subscriptions;

  @override
  void addSubscription(EventSubscription<T> subscription) {
    _subscriptions.add(subscription);
  }

  @override
  void removeSubscription(EventSubscription<T> subscription) {
    _subscriptions.remove(subscription);
  }

  @override
  bool get hasSubscriptions =>
      _subscriptions.any((subscription) => !subscription.isCanceled);

  @override
  bool get hasListenerSubscriptions => _subscriptions.any(
      (subscription) => !subscription.isCanceled && subscription.hasListener);

  @override
  Future<void> dispose() async {
    final subscriptions = List<EventSubscription<T>>.of(_subscriptions);
    _subscriptions.clear();
    if (!_streamControllerValue.isClosed) {
      await _streamControllerValue.close();
    }
    await Future.wait(
        subscriptions.map((subscription) => subscription._close()));
  }
}

abstract class EventBus {
  bool get isModelBus;

  /// Closes the all-events stream and every node of the bus. Safe to call twice.
  /// After dispose the bus is unusable: fire/request/listen/subscribe/subscribeEvents
  /// throw StateError.
  Future<void> dispose();

  /// true once [dispose] has been called
  bool get isDisposed;

  /// Stream for all sent events (event DTO, and whether it had a listener or not)
  Stream<(EventDTO, bool)> get allEventStream;

  ///Bus failures as data. The stream never carries stream errors.
  Stream<EventBusError> get errors;

  ///The latest errors, bounded (100 entries).
  List<EventBusError> get recentErrors;

  ///Errors suppressed by the per-kind/topic rate limit.
  int get suppressedErrors;

  ///True when observability is enabled for this bus.
  bool get isObservable;

  ///The metric collector of this bus. Safe to read when observability is off:
  ///the snapshot is empty in that case.
  EventBusMetrics get metrics;

  /// Publishes [data] on an exact typed key.
  bool fire<T>(
    EventKey<T> key,
    T data, {
    Map<String, String>? arguments,
    String? correlationId,
  });

  /// Sends a request on an exact typed key and waits for the handler result.
  Future<dynamic> request<T>(
    EventKey<T> key,
    T data, {
    Map<String, String>? arguments,
    Duration? timeout,
    CancelToken? cancelToken,
    String? correlationId,
  });

  /// Listens to a typed exact or pattern selector.
  Stream<T> listen<T>(EventSelector<T> selector);

  /// Subscribes to a typed selector as a raw stream subscription.
  StreamSubscription<T> subscribe<T>(
    EventSelector<T> selector, {
    void Function(T e)? onData,
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  });

  /// Creates a listener and/or handler subscription for a typed selector.
  EventSubscription<T> subscribeEvents<T>(
    EventSelector<T> selector, {
    EventCallback<T>? onEvent,
    Handler<T>? handler,
    T? initialData,
    int handlerConcurrency = 1,
    int? requestQueueCapacity,
    int? bufferCapacity,
    BufferOverflow bufferOverflow = BufferOverflow.dropOldest,
    DeliveryMode deliveryMode = DeliveryMode.async,
    void Function(Object error, StackTrace? stackTrace)? onError,
    void Function()? onDone,
    bool cancelOnError = false,
  });

  /// The value stored for an exact typed key.
  T? currentData<T>(EventKey<T> key);

  /// The value stored for a selector, including a pattern key.
  T? currentDataFor<T>(EventSelector<T> selector);

  /// Whether a selector has a listener.
  bool haveListener<T>(EventSelector<T> selector);

  /// Whether a selector has a handler, including paused handlers.
  bool haveHandler<T>(EventSelector<T> selector);

  /// Whether a handler for the selector could accept a request now.
  bool haveAvailableHandler<T>(EventSelector<T> selector);

  /// Removes the type node for an exact key.
  bool remove<T>(EventKey<T> key);

  /// Removes the type node for a pattern key.
  bool removePattern<T>(EventPatternKey<T> key);

  /// Removes every type node registered at an exact address.
  bool removeAddress(EventAddress address);

  /// Factory constructor for EventBus.
  /// Creates an EventBusImpl instance.
  factory EventBus(
      {bool isModelBus = false, ObservabilityConfig? observability}) {
    return EventBusImpl(
      isModelBus,
      observability: observability ?? ObservabilityConfig.disabled,
    );
  }
}

class EventBusImpl with EventBusMixin, _EventBusHandlersMixin {
  final bool _isModelBus;
  @override
  bool get isModelBus => _isModelBus;

  @override
  final ObservabilityConfig observabilityConfig;

  /// Creates an EventBusImpl instance.
  /// If isModelBus is true, the bus behaves as a model bus.
  EventBusImpl(this._isModelBus,
      {ObservabilityConfig observability = ObservabilityConfig.disabled})
      : observabilityConfig = observability;
}

mixin EventBusMixin implements EventBus {
  ///Observability switches of this bus; supplied by the concrete bus.
  ObservabilityConfig get observabilityConfig;

  EventBusMetrics? _metricsInstance;

  @override
  bool get isObservable => observabilityConfig.enabled;

  @override
  EventBusMetrics get metrics => _metricsInstance ??= EventBusMetrics(this);

  ///True when metric counters and histograms must be collected. The check is a
  ///field read, so a disabled bus pays nothing beyond it.
  bool get _metricsEnabled =>
      observabilityConfig.enabled && observabilityConfig.metrics;

  ///Default requestQueueCapacity for handler subscriptions created without an
  ///explicit override.
  int requestQueueCapacity = 64;

  /// Stream controller for all events sent through the bus
  final StreamController<(EventDTO, bool)> _allEventStream =
      StreamController<(EventDTO, bool)>.broadcast();

  final StreamController<EventBusError> _errorsController =
      StreamController<EventBusError>.broadcast();
  final List<EventBusError> _recentErrors = <EventBusError>[];
  final Map<String, List<DateTime>> _errorWindows = <String, List<DateTime>>{};
  int _suppressedErrors = 0;

  @override
  Stream<(EventDTO, bool)> get allEventStream => _allEventStream.stream;

  @override
  Stream<EventBusError> get errors => _errorsController.stream;

  @override
  List<EventBusError> get recentErrors =>
      List<EventBusError>.unmodifiable(_recentErrors);

  ///Errors suppressed by the per-kind/topic rate limit.
  @override
  int get suppressedErrors => _suppressedErrors;

  ///Publishes a bus error. Transport and isolate adapters use this seam.
  ///
  ///Errors are rate-limited per `(kind, topic)`: at most 10 per second, the
  ///rest are counted in [suppressedErrors]. The recent list is bounded.
  void reportError(EventBusError error) {
    if (_disposed) return;
    if (_metricsEnabled && error.kind == EventBusErrorKind.bufferOverflow) {
      metrics.recordOverflow(error.topic);
    }
    final key = '${error.kind.name}|${error.topic}';
    final window = _errorWindows.putIfAbsent(key, () => <DateTime>[]);
    final now = error.timestamp;
    window.removeWhere(
        (time) => now.difference(time) > const Duration(seconds: 1));
    if (window.length >= 10) {
      _suppressedErrors++;
      return;
    }
    window.add(now);
    _recentErrors.add(error);
    if (_recentErrors.length > 100) {
      _recentErrors.removeAt(0);
    }
    if (!_errorsController.isClosed) {
      _errorsController.add(error);
    }
  }

  /// Exact nodes: address -> local type -> node.
  final Map<EventAddress, Map<Type, EventNode>> _eventsMap = {};

  /// Pattern nodes: pattern -> local type -> node.
  final Map<EventPattern, Map<Type, EventNode>> _patternMap = {};

  bool _disposed = false;
  Future<void>? _disposeFuture;

  /// true once [dispose] has been called
  @override
  bool get isDisposed => _disposed;

  @override
  bool get isModelBus => false;

  /// Checks the bus state before any operation.
  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('EventBus is disposed: $this');
    }
  }

  /// Creates the node for a topic.
  ///
  /// The topic is part of the node's identity: a transport bus overrides this
  /// method and returns a node that publishes to and listens from its broker.
  /// The default node is local-only and ignores the topic.
  EventNode<T> createNode<T>({
    required Topic topic,
    T? currentData,
  }) {
    return EventNode<T>.create(currentData: currentData);
  }

  ///Creates the node for an exact E key.
  ///
  ///The default bridges to the legacy [createNode] with a `Topic` view of the
  ///address, so existing transport overrides keep working during the
  ///migration. A transport that supports the E model overrides this hook.
  EventNode<T> createNodeForKey<T>({
    required EventKey<T> key,
    T? currentData,
  }) {
    return createNode<T>(
        topic: Topic.parse(key.address.value), currentData: currentData);
  }

  ///Creates the node for a typed pattern key.
  EventNode<T> createPatternNodeForKey<T>({
    required EventPatternKey<T> key,
    T? currentData,
  }) {
    return createNode<T>(
        topic: Topic.parse(key.pattern.value), currentData: currentData);
  }

  ///Whether a send on an exact E key should create a node.
  bool shouldCreateNodeOnSendKey<T>(EventKey<T> key) =>
      shouldCreateNodeOnSend(Topic.parse(key.address.value));

  ///Round-robin cursor of the handler dispatcher, per route.
  final Map<Object, int> _handlerCursors = {};

  ///Active listener and handler subscriptions per topic, used by isolate
  ///bridges to publish interest transitions.
  final Map<Topic, int> _listenerCounts = {};
  final Map<Topic, int> _handlerCounts = {};

  ///Topics a model bus has a node for; a remote model bus accepts fire even
  ///without a listener because it stores the value.
  final Set<Topic> _modelTopics = {};

  ///Hooks for isolate bridges; no-op for local and transport buses.
  void _onListenerInterestChanged(Topic topic, bool present) {}
  void _onHandlerInterestChanged(Topic topic, bool present) {}
  void _onModelInterestChanged(Topic topic, bool present) {}
  void _onTopicInterestRemoved(Topic topic) {}

  void _markModelTopic(Topic topic, bool present) {
    if (!isModelBus) return;
    if (present) {
      if (_modelTopics.add(topic)) _onModelInterestChanged(topic, true);
    } else if (_modelTopics.remove(topic)) {
      _onModelInterestChanged(topic, false);
    }
  }

  void _subscriptionAdded(Topic topic,
      {required bool listener, required bool handler}) {
    if (listener) {
      final count = (_listenerCounts[topic] ?? 0) + 1;
      _listenerCounts[topic] = count;
      if (count == 1) _onListenerInterestChanged(topic, true);
    }
    if (handler) {
      final count = (_handlerCounts[topic] ?? 0) + 1;
      _handlerCounts[topic] = count;
      if (count == 1) _onHandlerInterestChanged(topic, true);
    }
  }

  void _subscriptionRemoved(Topic topic,
      {required bool listener, required bool handler}) {
    if (listener) {
      final count = _listenerCounts[topic] ?? 0;
      if (count == 1) {
        _listenerCounts.remove(topic);
        _onListenerInterestChanged(topic, false);
      } else if (count > 1) {
        _listenerCounts[topic] = count - 1;
      }
    }
    if (handler) {
      final count = _handlerCounts[topic] ?? 0;
      if (count == 1) {
        _handlerCounts.remove(topic);
        _onHandlerInterestChanged(topic, false);
      } else if (count > 1) {
        _handlerCounts[topic] = count - 1;
      }
    }
  }

  /// Whether [send] should create a node when the topic has none.
  ///
  /// A model bus stores every event it sends, so it creates the node. A
  /// transport bus overrides this to create a node only for topics it
  /// actually knows. With the default `false`, `send` to a topic without a
  /// node returns `null`, exactly like the local bus.
  bool shouldCreateNodeOnSend(Topic topic) => isModelBus;

  /// Adds the event to the all-events stream if the bus is still alive.
  void _addAllEvent(EventDTO dto, bool delivered) {
    if (!_allEventStream.isClosed) {
      _allEventStream.add((dto, delivered));
    }
  }

  /// The topic view of a selector, for the compatibility hooks.
  Topic _topicForSelector(EventSelector selector) {
    if (selector is EventPatternKey) return Topic.parse(selector.pattern.value);
    return Topic.parse(selector.toString());
  }

  Map<Type, EventNode> _exactBucket(EventAddress address) =>
      _eventsMap.putIfAbsent(address, () => <Type, EventNode>{});

  Map<Type, EventNode> _patternBucket(EventPattern pattern) =>
      _patternMap.putIfAbsent(pattern, () => <Type, EventNode>{});

  @override
  T? currentData<T>(EventKey<T> key) {
    final node = _eventsMap[key.address]?[key.type];
    return node is EventNode<T> ? node.currentData : null;
  }

  @override
  T? currentDataFor<T>(EventSelector<T> selector) {
    _checkNotDisposed();
    if (selector is EventPatternKey<T>) {
      final node = _patternMap[selector.pattern]?[selector.type];
      return node is EventNode<T> ? node.currentData : null;
    }
    return currentData<T>(selector as EventKey<T>);
  }

  /// Returns the typed node of a selector, creating it when needed.
  EventNode<T> _nodeFor<T>(EventSelector<T> selector) {
    if (selector is EventPatternKey<T>) {
      final bucket = _patternBucket(selector.pattern);
      final existing = bucket[selector.type];
      if (existing is EventNode<T>) return existing;
      final topic = Topic.parse(selector.pattern.value);
      final created = createPatternNodeForKey<T>(key: selector);
      bucket[selector.type] = created;
      _markModelTopic(topic, true);
      return created;
    }
    final key = selector as EventKey<T>;
    final bucket = _exactBucket(key.address);
    final existing = bucket[key.type];
    if (existing is EventNode<T>) return existing;
    final topic = Topic.parse(key.address.value);
    final created = createNodeForKey<T>(key: key);
    bucket[key.type] = created;
    _markModelTopic(topic, true);
    return created;
  }

  /// Value stream of a selector; the node may be removed when the last
  /// subscription is cancelled.
  ///
  ///The source stays an ordinary asynchronous broadcast stream. The wrapper
  ///only adds the cancellation hook (the former rxdart `doOnCancel`) and
  ///delegates pause/resume, so no extra microtask hop is introduced.
  Stream<T> _valueStream<T>(EventSelector<T> selector) {
    final node = _nodeFor<T>(selector);
    final topic = _topicForSelector(selector);
    return _NodeStream<T>(
      node.streamControllerValue.stream,
      () {
        _subscriptionRemoved(topic, listener: true, handler: false);
        _removeNode(selector, node);
      },
      onListen: () => _subscriptionAdded(topic, listener: true, handler: false),
    );
  }

  @override
  Stream<T> listen<T>(EventSelector<T> selector) {
    _checkNotDisposed();
    return _valueStream<T>(selector);
  }

  @override
  StreamSubscription<T> subscribe<T>(EventSelector<T> selector,
      {void Function(T e)? onData,
      Function? onError,
      void Function()? onDone,
      bool? cancelOnError}) {
    _checkNotDisposed();
    return _valueStream<T>(selector).listen(onData,
        cancelOnError: cancelOnError, onDone: onDone, onError: onError);
  }

  @override
  EventSubscription<T> subscribeEvents<T>(
    EventSelector<T> selector, {
    EventCallback<T>? onEvent,
    Handler<T>? handler,
    T? initialData,
    int handlerConcurrency = 1,
    int? requestQueueCapacity,
    int? bufferCapacity,
    BufferOverflow bufferOverflow = BufferOverflow.dropOldest,
    DeliveryMode deliveryMode = DeliveryMode.async,
    void Function(Object error, StackTrace? stackTrace)? onError,
    void Function()? onDone,
    bool cancelOnError = false,
  }) {
    _checkNotDisposed();
    return _subscribeEvents<T>(
      selector,
      onEvent: onEvent,
      handler: handler,
      initialData: initialData,
      handlerConcurrency: handlerConcurrency,
      requestQueueCapacity: requestQueueCapacity,
      bufferCapacity: bufferCapacity,
      bufferOverflow: bufferOverflow,
      deliveryMode: deliveryMode,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  EventSubscription<T> _subscribeEvents<T>(
    EventSelector<T> selector, {
    EventCallback<T>? onEvent,
    Handler<T>? handler,
    T? initialData,
    int handlerConcurrency = 1,
    int? requestQueueCapacity,
    int? bufferCapacity,
    BufferOverflow bufferOverflow = BufferOverflow.dropOldest,
    DeliveryMode deliveryMode = DeliveryMode.async,
    void Function(Object error, StackTrace? stackTrace)? onError,
    void Function()? onDone,
    bool cancelOnError = false,
  }) {
    if (onEvent == null && handler == null) {
      throw ArgumentError('subscribeEvents needs onEvent, handler, or both');
    }
    final node = _nodeFor<T>(selector);
    if (node is! SubscriptionHost<T>) {
      throw UnsupportedError(
          'node ${node.runtimeType} does not implement SubscriptionHost');
    }
    final host = node as SubscriptionHost<T>;
    final topic = _topicForSelector(selector);
    late final EventSubscription<T> subscription;
    subscription = EventSubscription<T>._(
      selector: selector,
      onEvent: onEvent,
      handler: handler,
      handlerConcurrency: handlerConcurrency,
      requestQueueCapacity: requestQueueCapacity ?? this.requestQueueCapacity,
      bufferCapacity: bufferCapacity,
      bufferOverflow: bufferOverflow,
      deliveryMode: deliveryMode,
      cancelOnError: cancelOnError,
      capturePayloads: isObservable && observabilityConfig.capturePayloads,
      trackMetrics: _metricsEnabled,
      onError: onError,
      onDone: onDone,
      onCancel: () {
        _subscriptionRemoved(topic,
            listener: onEvent != null, handler: handler != null);
        host.removeSubscription(subscription);
        _removeNode(selector, node);
      },
      onBusError: reportError,
    );
    host.addSubscription(subscription);
    _subscriptionAdded(topic,
        listener: onEvent != null, handler: handler != null);
    if (initialData != null) {
      node.currentData = initialData;
    }
    return subscription;
  }

  @override
  bool fire<T>(EventKey<T> key, T data,
      {Map<String, String>? arguments, String? correlationId}) {
    _checkNotDisposed();
    final observing = _metricsEnabled;
    final started = observing ? DateTime.now().microsecondsSinceEpoch : 0;
    final dto = EventDTO<T>.withKey(key, data,
        arguments: arguments, correlationId: correlationId);
    // A model or transport bus may create the exact node for this key.
    _sendNode<T>(key);
    final matched = _dispatchToListeners(dto);
    // A model bus accepted the value even when nobody is listening. A handler
    // subscription alone does not count for fire (D14).
    final accepted = matched ||
        (isModelBus && _eventsMap[key.address]?[key.type] != null);
    _addAllEvent(dto, accepted);
    if (observing) {
      metrics.recordFire(key.address.value,
          accepted: accepted,
          elapsedMicros: DateTime.now().microsecondsSinceEpoch - started);
    }
    return accepted;
  }

  ///Delivers to every typed node at the address and to every matching pattern
  ///node. Each node filters by its own type.
  ///
  ///An [incoming] event came from another process: a transport node delivers it
  ///locally without publishing it back.
  bool _dispatchToListeners(EventDTO dto, {bool incoming = false}) {
    var accepted = false;
    final address = dto.key.address;
    final exact = _eventsMap[address];
    if (exact != null) {
      for (final node in exact.values) {
        accepted = _deliverNode(node, dto, incoming) || accepted;
      }
    }
    for (final entry in _matchingPatternEntries(address)) {
      for (final node in entry.value.values) {
        accepted = _deliverNode(node, dto, incoming) || accepted;
      }
    }
    return accepted;
  }

  bool _deliverNode(EventNode node, EventDTO dto, bool incoming) {
    if (incoming && node is IncomingEventNode) {
      (node as IncomingEventNode).deliverIncoming(dto);
      return true;
    }
    return node.deliver(dto);
  }

  ///Pattern buckets matching a concrete address, most specific first.
  List<MapEntry<EventPattern, Map<Type, EventNode>>>
      _matchingPatternEntries(EventAddress address) {
    final insertion = <EventPattern, int>{};
    final matches = <MapEntry<EventPattern, Map<Type, EventNode>>>[];
    var index = 0;
    for (final entry in _patternMap.entries) {
      insertion[entry.key] = index++;
      if (entry.key.matches(address)) {
        matches.add(entry);
      }
    }
    matches.sort((a, b) {
      final byScore = b.key.specificity.compareTo(a.key.specificity);
      if (byScore != 0) return byScore;
      return insertion[a.key]!.compareTo(insertion[b.key]!);
    });
    return matches;
  }

  ///The typed node an event is sent to, created when the bus allows it.
  EventNode<T>? _sendNode<T>(EventKey<T> key) {
    final existing = _eventsMap[key.address]?[key.type];
    if (existing is EventNode<T>) return existing;
    final topic = Topic.parse(key.address.value);
    if (shouldCreateNodeOnSendKey(key)) {
      final created = createNodeForKey<T>(key: key);
      _exactBucket(key.address)[key.type] = created;
      _markModelTopic(topic, true);
      return created;
    }
    return null;
  }

  /// This method is called every time a listener closes the stream.
  /// The node is kept when it has listeners, a request handler, a pin from a
  /// transport, or when this is a model bus.
  bool _removeNode(EventSelector selector, EventNode node) {
    final pinned = node is KeepAliveNode && (node as KeepAliveNode).keepAlive;
    final hasSubscriptions =
        node is SubscriptionHost && (node as SubscriptionHost).hasSubscriptions;
    if (!node.streamControllerValue.hasListener &&
        !hasSubscriptions &&
        !isModelBus &&
        !pinned) {
      return _detachNode(selector, node);
    }
    return false;
  }

  ///Whether a node has a legacy stream listener or a listener subscription.
  bool _nodeHasListener(EventNode? node) {
    if (node == null) return false;
    if (node.streamControllerValue.hasListener) return true;
    return node is SubscriptionHost &&
        (node as SubscriptionHost).hasListenerSubscriptions;
  }

  @override
  bool remove<T>(EventKey<T> key) {
    _checkNotDisposed();
    final node = _eventsMap[key.address]?[key.type];
    if (node == null) return false;
    return _detachNode(key, node);
  }

  @override
  bool removePattern<T>(EventPatternKey<T> key) {
    _checkNotDisposed();
    final node = _patternMap[key.pattern]?[key.type];
    if (node == null) return false;
    return _detachNode(key, node);
  }

  @override
  bool removeAddress(EventAddress address) {
    _checkNotDisposed();
    final bucket = _eventsMap.remove(address);
    if (bucket == null) return false;
    final topic = Topic.parse(address.value);
    for (final node in bucket.values) {
      _handlerCursors.remove(node);
      unawaited(node.dispose());
    }
    final hadInterest = (_listenerCounts.remove(topic) ?? 0) > 0 ||
        (_handlerCounts.remove(topic) ?? 0) > 0;
    if (hadInterest) _onTopicInterestRemoved(topic);
    _markModelTopic(topic, false);
    return true;
  }

  ///Removes one typed selector without forwarding a delete. Used by the
  ///isolate link when a typed delete arrives from the other side.
  bool _removeSelectorLocally(EventSelector selector) {
    final EventNode? node;
    if (selector is EventPatternKey) {
      node = _patternMap[selector.pattern]?[selector.type];
    } else {
      final key = selector as EventKey;
      node = _eventsMap[key.address]?[key.type];
    }
    if (node == null) return false;
    return _detachNode(selector, node);
  }

  /// Removes every type node at a topic without forwarding a delete.
  /// Also used by the isolate link when a delete arrives from the other side.
  bool _removeTopicLocally(Topic topic) {
    if (TopicPattern.isPattern(topic)) {
      final pattern = EventPattern(topic.topic);
      final bucket = _patternMap.remove(pattern);
      if (bucket == null) return false;
      for (final node in bucket.values) {
        _handlerCursors.remove(node);
        unawaited(node.dispose());
      }
      final hadInterest = (_listenerCounts.remove(topic) ?? 0) > 0 ||
          (_handlerCounts.remove(topic) ?? 0) > 0;
      if (hadInterest) _onTopicInterestRemoved(topic);
      _markModelTopic(topic, false);
      return true;
    }
    return removeAddress(EventAddress(topic.topic));
  }

  /// Unlinks [node] and disposes it, but only when the map still holds this
  /// very node. A late `doOnCancel` of an already removed node must not delete
  /// a node created later for the same key.
  bool _detachNode(EventSelector selector, EventNode node) {
    var removed = false;
    if (selector is EventPatternKey) {
      final bucket = _patternMap[selector.pattern];
      if (bucket != null && identical(bucket[selector.type], node)) {
        bucket.remove(selector.type);
        if (bucket.isEmpty) _patternMap.remove(selector.pattern);
        removed = true;
      }
    } else {
      final key = selector as EventKey;
      final bucket = _eventsMap[key.address];
      if (bucket != null && identical(bucket[key.type], node)) {
        bucket.remove(key.type);
        if (bucket.isEmpty) _eventsMap.remove(key.address);
        removed = true;
      }
    }
    if (removed) {
      final topic = _topicForSelector(selector);
      final hadInterest = (_listenerCounts.remove(topic) ?? 0) > 0 ||
          (_handlerCounts.remove(topic) ?? 0) > 0;
      if (hadInterest) _onTopicInterestRemoved(topic);
      _markModelTopic(topic, false);
      _handlerCursors.remove(node);
      unawaited(node.dispose());
    }
    return removed;
  }

  @override
  bool haveListener<T>(EventSelector<T> selector) {
    _checkNotDisposed();
    if (selector is EventPatternKey<T>) {
      return _nodeHasListener(_patternMap[selector.pattern]?[selector.type]);
    }
    final key = selector as EventKey<T>;
    if (_nodeHasListener(_eventsMap[key.address]?[key.type])) return true;
    return _matchingPatternEntries(key.address)
        .any((entry) => _nodeHasListener(entry.value[key.type]));
  }

  /// Closes the all-events stream and every node of the bus.
  /// Safe to call more than once; after dispose the bus throws StateError on use.
  @override
  Future<void> dispose() => _disposeFuture ??= _disposeImpl();

  Future<void> _disposeImpl() async {
    _disposed = true;
    await _allEventStream.close();
    await _errorsController.close();
    final metricsInstance = _metricsInstance;
    _metricsInstance = null;
    if (metricsInstance != null) {
      await metricsInstance.dispose();
    }
    _errorWindows.clear();
    final nodes = <EventNode>[
      for (final bucket in _eventsMap.values) ...bucket.values,
      for (final bucket in _patternMap.values) ...bucket.values,
    ];
    _eventsMap.clear();
    _patternMap.clear();
    _handlerCursors.clear();
    _listenerCounts.clear();
    _handlerCounts.clear();
    _modelTopics.clear();
    await Future.wait(nodes.map((e) => e.dispose()));
  }
}

///Request handlers: resolution, dispatch and the request lifecycle.
///
///A handler is a capability of [EventSubscription]; this mixin only routes a
///request to the resolved tier and owns the request lifecycle.
mixin _EventBusHandlersMixin on EventBusMixin {
  @override
  bool haveHandler<T>(EventSelector<T> selector) =>
      _resolveTier(selector) != null;

  @override
  bool haveAvailableHandler<T>(EventSelector<T> selector) {
    final tier = _resolveTier(selector);
    return tier != null &&
        tier.candidates
            .any((candidate) => candidate.subscription.hasRequestCapacity);
  }

  ///The registered topic of the tier that would answer [topic], or null when
  ///no handler exists.
  ///
  ///Intended for transports: overlapping exact/pattern subscriptions must
  ///produce exactly one answer.
  Topic? handlerTopicFor(Topic topic) {
    final selector = TopicPattern.isPattern(topic)
        ? EventPatternKey<Object?>(topic.topic)
        : EventKey<Object?>(topic.topic);
    final tier = _resolveTier(selector);
    if (tier == null) return null;
    final route = tier.route;
    return Topic.parse(
        route is EventPattern ? route.value : (route as EventAddress).value);
  }

  List<EventSubscription> _handlersOn(EventNode? node) {
    if (node is! SubscriptionHost) return const [];
    final host = node as SubscriptionHost;
    return host.subscriptions
        .where((subscription) => subscription.hasHandler)
        .toList(growable: false);
  }

  List<_HandlerCandidate> _candidatesOn(Map<Type, EventNode> bucket) {
    final candidates = <_HandlerCandidate>[];
    for (final node in bucket.values) {
      for (final subscription in _handlersOn(node)) {
        candidates.add(_HandlerCandidate(node, subscription));
      }
    }
    return candidates;
  }

  _HandlerTier? _resolveTier(EventSelector selector) {
    if (selector is EventPatternKey) {
      final bucket = _patternMap[selector.pattern];
      final candidates =
          bucket == null ? const <_HandlerCandidate>[] : _candidatesOn(bucket);
      return candidates.isEmpty
          ? null
          : _HandlerTier(selector.pattern, candidates);
    }

    final key = selector as EventKey;
    final exact = _eventsMap[key.address];
    if (exact != null) {
      final candidates = _candidatesOn(exact);
      if (candidates.isNotEmpty) {
        return _HandlerTier(key.address, candidates);
      }
    }

    for (final entry in _matchingPatternEntries(key.address)) {
      final candidates = _candidatesOn(entry.value);
      if (candidates.isNotEmpty) {
        return _HandlerTier(entry.key, candidates);
      }
    }
    return null;
  }

  _HandlerCandidate _pickHandler(
      _HandlerTier tier, List<_HandlerCandidate> candidates) {
    final start = (_handlerCursors[tier.route] ?? 0) % candidates.length;
    _handlerCursors[tier.route] = start + 1;
    return candidates[start];
  }

  @override
  Future<dynamic> request<T>(EventKey<T> key, T data,
      {Map<String, String>? arguments,
      Duration? timeout,
      CancelToken? cancelToken,
      String? correlationId}) async {
    _checkNotDisposed();
    if (cancelToken?.isCancelled ?? false) {
      if (_metricsEnabled) {
        metrics.recordRequestStarted(key.address.value);
        metrics.recordRequestOutcome(
            key.address.value, RequestOutcome.canceled, 0);
      }
      throw RequestCanceledException(key.address.value);
    }
    final dto = EventDTO<T>.withKey(key, data,
        arguments: arguments, correlationId: correlationId);
    return _dispatchRequest(
      dto,
      incoming: false,
      timeout: timeout,
      cancelToken: cancelToken,
      onAccepted: () => _sendNode<T>(key),
    );
  }

  Future<dynamic> _dispatchRequest(
    EventDTO dto, {
    required bool incoming,
    Duration? timeout,
    CancelToken? cancelToken,
    void Function()? onAccepted,
  }) {
    final observing = _metricsEnabled;
    final started = observing ? DateTime.now().microsecondsSinceEpoch : 0;
    if (observing) metrics.recordRequestStarted(dto.address);
    void finish(RequestOutcome outcome) {
      if (observing) {
        metrics.recordRequestOutcome(dto.address, outcome,
            DateTime.now().microsecondsSinceEpoch - started);
      }
    }

    final tier = _resolveTier(EventKey<Object?>(dto.address));
    if (tier == null) {
      _addAllEvent(dto, false);
      finish(RequestOutcome.errored);
      throw NoHandlerException(dto.address);
    }

    final accepting = tier.candidates
        .where((candidate) => candidate.subscription.acceptsData(dto.data))
        .toList(growable: false);
    if (accepting.isEmpty) {
      _addAllEvent(dto, false);
      finish(RequestOutcome.errored);
      throw NoHandlerException(dto.address);
    }

    final candidates = accepting
        .where((candidate) => candidate.subscription.hasRequestCapacity)
        .toList(growable: false);
    if (candidates.isEmpty) {
      final busy = BusyException(dto.address);
      _addAllEvent(dto, false);
      reportError(EventBusError(
        kind: EventBusErrorKind.busy,
        topic: dto.address,
        error: busy,
      ));
      finish(RequestOutcome.busy);
      throw busy;
    }

    final picked = _pickHandler(tier, candidates);
    onAccepted?.call();
    final previous = picked.node.currentData;
    final matched = _dispatchToListeners(dto, incoming: incoming);
    _addAllEvent(dto, matched);

    final entry = _RequestEntry(
      topic: dto.address,
      invoke: () => picked.subscription.invokeRequest(dto, previous),
      onBusError: reportError,
    );
    entry.dto = dto;
    entry.capturePayloads = isObservable && observabilityConfig.capturePayloads;
    if (isObservable) {
      entry.onFinished = finish;
    }
    entry.arm(timeout: timeout, cancelToken: cancelToken);
    if (!picked.subscription._enqueueRequest(entry)) {
      entry.fail(BusyException(dto.address));
    }
    return entry.future;
  }

  ///Dispatches a request received from another process, for example a
  ///transport. The handler is resolved exactly like a local [request].
  Future<dynamic> handleIncomingRequest(EventDTO dto,
          {CancelToken? cancelToken}) async =>
      _dispatchRequest(dto, incoming: true, cancelToken: cancelToken);

  ///Dispatches an event received from another isolate.
  ///
  ///A request needs a matching handler; a fire event is delivered to listeners
  ///only.
  Future? _dispatchIncoming(EventDTO dto,
      {bool request = true, CancelToken? cancelToken}) {
    if (!request) {
      final matched = _dispatchToListeners(dto, incoming: true);
      _addAllEvent(dto, matched);
      return null;
    }
    return _dispatchRequest(dto, incoming: true, cancelToken: cancelToken);
  }
}

class _HandlerCandidate {
  _HandlerCandidate(this.node, this.subscription);

  final EventNode node;
  final EventSubscription subscription;
}

class _HandlerTier {
  _HandlerTier(this.route, this.candidates);

  ///The exact [EventAddress] or the [EventPattern] that owns the tier.
  final Object route;
  final List<_HandlerCandidate> candidates;
}

///A stream view of a node that runs [onCancel] when its subscription is
///cancelled.
///
///It replaces the former rxdart `doOnCancel` without a controller and without
///an extra microtask: the source stays an ordinary asynchronous broadcast
///stream, and `listen` only wraps the subscription.
class _NodeStream<T> extends Stream<T> {
  _NodeStream(this._source, this._onCancel, {void Function()? onListen})
      : _onListen = onListen;

  final Stream<T> _source;
  final void Function() _onCancel;
  final void Function()? _onListen;

  @override
  bool get isBroadcast => _source.isBroadcast;

  @override
  StreamSubscription<T> listen(
    void Function(T)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final inner = _source.listen(null, cancelOnError: false);
    return _NodeSubscription<T>(
      inner,
      onData,
      onError,
      onDone,
      cancelOnError ?? false,
      _onCancel,
      _onListen,
    );
  }
}

///A subscription wrapper: forwards data/error/done to the current callbacks,
///delegates pause/resume, and calls [_onCancel] once when cancelled.
class _NodeSubscription<T> implements StreamSubscription<T> {
  _NodeSubscription(
    this._inner,
    this._onData,
    this._onError,
    this._onDone,
    this._cancelOnError,
    this._onCancel,
    this._onListen,
  ) {
    _inner.onData((event) => _onData?.call(event));
    _inner.onError(_handleError);
    _inner.onDone(() => _onDone?.call());
    _onListen?.call();
  }

  final StreamSubscription<T> _inner;
  final void Function() _onCancel;
  final void Function()? _onListen;
  final bool _cancelOnError;

  void Function(T event)? _onData;
  Function? _onError;
  void Function()? _onDone;
  bool _canceled = false;

  @override
  void onData(void Function(T data)? handleData) {
    _onData = handleData;
  }

  @override
  void onError(Function? handleError) {
    _onError = handleError;
  }

  @override
  void onDone(void Function()? handleDone) {
    _onDone = handleDone;
  }

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture<E>(futureValue);

  @override
  Future<void> cancel() async {
    if (_canceled) return;
    _canceled = true;
    try {
      await _inner.cancel();
    } finally {
      _onCancel();
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    final handler = _onError;
    if (handler == null) {
      Zone.current.handleUncaughtError(error, stackTrace);
    } else if (handler is void Function(Object, StackTrace)) {
      handler(error, stackTrace);
    } else if (handler is void Function(Object)) {
      handler(error);
    } else {
      Function.apply(handler, [error, stackTrace]);
    }
    if (_cancelOnError) {
      unawaited(cancel());
    }
  }
}
