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
  void deliver(EventDTO dto);

  EventNode<T> copy();

  ///Disposes of the node, closing all stream controllers and cancelling subscriptions.
  Future<void> dispose();

  factory EventNode.create({
    T? currentData,
  }) {
    return EventNodeImp<T>(currentData: currentData);
  }
}

///A request responder registered for a topic.
///
///The closures erase the generic type of the handler, so a request received
///from another isolate can be dispatched without knowing `T` statically.
class RequestHandler {
  RequestHandler({
    required this.topic,
    required this.accepts,
    required this.invoke,
  });

  final Topic topic;

  ///Whether this handler can process an event with [data].
  final bool Function(Object? data) accepts;

  ///Invokes the user handler with a typed DTO and the previous value.
  final Future<dynamic> Function(EventDTO dto, Object? lastData) invoke;
}

///EventNodeImp stores the current value and fans events out to listeners.
class EventNodeImp<T> implements EventNode<T> {
  @override
  T? currentData;
  @override
  bool get isDisposed => _streamControllerValue.isClosed;
  final StreamController<T> _streamControllerValue =
      StreamController<T>.broadcast();
  @override
  StreamController<T> get streamControllerValue => _streamControllerValue;

  EventNodeImp({this.currentData});

  ///Stores the value and notifies listeners. Request handlers are invoked by
  ///the bus, not here, so the value is scheduled before a handler can complete
  ///the request.
  @override
  void deliver(EventDTO dto) {
    if (dto.data is! T) return;
    currentData = dto.data;
    _streamControllerValue.add(dto.data);
  }

  ///Creates an independent node with the same current data.
  @override
  EventNode<T> copy() => EventNodeImp<T>(currentData: currentData);

  @override
  Future<void> dispose() async {
    if (!_streamControllerValue.isClosed) {
      await _streamControllerValue.close();
    }
  }
}

abstract class EventBus {
  bool get isModelBus;
  String get defaultTopicPathSeparator;

  /// Handler management without casting `bus as EventBusHandlers`.
  EventBusHandlers get handlers;

  /// Closes the all-events stream and every node of the bus. Safe to call twice.
  /// After dispose the bus is unusable: send/listen/subscribe/setHandler throw StateError.
  Future<void> dispose();

  /// true once [dispose] has been called
  bool get isDisposed;

  /// Stream for all sent events (event DTO, and whether it had a listener or not)
  Stream<(EventDTO, bool)> get allEventStream;

  /// Returns true if the bus contains a listener for the specified topic
  bool haveListener<T>({List<String>? paths, String? separator});

  /// Returns true if the bus contains a handler for the specified topic
  bool haveHandler<T>({List<String>? paths, String? separator});

  /// Publishes an event to local listeners and forgets about it.
  ///
  /// Handlers registered with [EventBusHandlers.setHandler] are not awaited;
  /// their result is ignored. Returns true when the event was accepted: there
  /// is a local node (or the bus created one) or a transport accepted it.
  /// A false result means nobody is listening and no transport knows the
  /// topic.
  bool fire<T>(
    T data, {
    List<String>? paths,
    String? separator,
    Map<String, String>? arguments,
  });

  /// Sends a request and waits for the result of a handler.
  ///
  /// Wildcard paths are not supported: `*` and `>` throw [EventBusException].
  /// When no handler is registered the returned future fails with
  /// [NoHandlerException]. Use [fire] when no answer is expected.
  Future<dynamic> request<T>(
    T data, {
    List<String>? paths,
    String? separator,
    Map<String, String>? arguments,
    Duration? timeout,
  });

  /// Listens to events on a specific topic.
  /// Returns a Stream of the data type T.
  Stream<T> listen<T>({List<String>? paths, String? separator});

  ///Subscribe to events on a specific topic.
  StreamSubscription<T> subscribe<T>(
      {List<String>? paths,
      String? separator,
      void Function(T e)? onData,
      Function? onError,
      void Function()? onDone,
      bool? cancelOnError});

  /// Gets the last data sent to a specific topic.
  T? currentData<T>({List<String>? paths, String? separator});

  /// Factory constructor for EventBus.
  /// Creates an EventBusImpl instance.
  factory EventBus({bool isModelBus = false}) {
    return EventBusImpl(isModelBus);
  }
}

///
abstract class EventBusHandlers {
  /// Sets a handler for a specific topic.
  /// If initialData is provided, it will be used as the initial data for the topic.
  void setHandler<T>({
    T? initialData,
    List<String>? paths,
    String? separator,
    required Handler<T> handler,
  });

  /// Removes a handler from a specific topic.
  void removeHandler<T>({List<String>? paths, String? separator});

  /// Adds all handlers from another EventBus to this one.
  void addAllHandlerFromOtherBus(EventBus fromBus);

  /// Removes all handlers that are present in another EventBus from this one.
  void removeAllHandlerPresentInOtherBus(EventBus otherBus);
}

class EventBusImpl with EventBusMixin, EventBusHandlersMixin {
  final bool _isModelBus;
  @override
  bool get isModelBus => _isModelBus;

  /// Creates an EventBusImpl instance.
  /// If isModelBus is true, the bus behaves as a model bus.
  EventBusImpl(this._isModelBus);
}

mixin EventBusMixin implements EventBus {
  @override
  String defaultTopicPathSeparator = '.';

  /// Stream controller for all events sent through the bus
  final StreamController<(EventDTO, bool)> _allEventStream =
      StreamController<(EventDTO, bool)>.broadcast();

  @override
  Stream<(EventDTO, bool)> get allEventStream => _allEventStream.stream;

  /// Map storing exact event nodes by their topic
  final Map<Topic, EventNode> _eventsMap = {};

  /// Map storing wildcard pattern nodes ('*', '>') by their topic
  final Map<Topic, EventNode> _patternMap = {};

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

  ///Whether a request handler is registered for [topic]. The delivery mixin
  ///uses this to keep a node alive after its last listener goes away.
  bool _hasHandlerFor(Topic topic);

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

  /// Gets the last data sent to a specific topic.
  /// Returns null if no data has been sent to that topic.
  @override
  T? currentData<T>({List<String>? paths, String? separator}) {
    var t = Topic.create<T>(
        paths: paths, separator: separator ?? defaultTopicPathSeparator);
    final pattern = TopicPattern.isPattern(t);
    if (pattern) {
      TopicPattern.validate(t);
    }
    var node = pattern ? _patternMap[t] : _eventsMap[t];
    if (node != null && node is EventNode<T>) {
      return node.currentData;
    }
    return null;
  }

  /// Returns the node of a topic, creating it when needed.
  EventNode<T> _nodeFor<T>(Topic topic) {
    final pattern = TopicPattern.isPattern(topic);
    if (pattern) {
      TopicPattern.validate(topic);
    }
    final map = pattern ? _patternMap : _eventsMap;
    var node = map[topic];
    if (node != null && node is EventNode<T>) {
      return node;
    }
    var created = createNode<T>(topic: topic);
    map[topic] = created;
    return created;
  }

  /// Value stream of a topic; the node may be removed when the last subscription is cancelled.
  Stream<T> _valueStream<T>(Topic topic) {
    var node = _nodeFor<T>(topic);
    return node.streamControllerValue.stream.doOnCancel(() {
      removeNode(topic, node);
    });
  }

  /// Listens to events on a specific topic.
  /// Creates a new EventNode if one doesn't exist for that topic.
  /// Returns a Stream of the data type T.
  @override
  Stream<T> listen<T>({List<String>? paths, String? separator}) {
    _checkNotDisposed();
    return _valueStream<T>(Topic.create<T>(
        paths: paths, separator: separator ?? defaultTopicPathSeparator));
  }

  @override
  StreamSubscription<T> subscribe<T>(
      {List<String>? paths,
      String? separator,
      void Function(T e)? onData,
      Function? onError,
      void Function()? onDone,
      bool? cancelOnError}) {
    _checkNotDisposed();
    return _valueStream<T>(Topic.create<T>(
            paths: paths, separator: separator ?? defaultTopicPathSeparator))
        .listen(onData,
            cancelOnError: cancelOnError, onDone: onDone, onError: onError);
  }

  /// Publishes an event to local listeners without waiting for a handler.
  @override
  bool fire<T>(T data,
      {List<String>? paths,
      String? separator,
      Map<String, String>? arguments}) {
    _checkNotDisposed();
    _rejectWildcardPaths(paths, 'fire');
    var dto = EventDTO<T>(data,
        paths: paths,
        // the same fallback as setHandler/listen/currentData: otherwise a send
        // would address a node nobody else can address
        separator: separator ?? defaultTopicPathSeparator,
        arguments: arguments);
    // A model or transport bus may create the exact node for this topic.
    _sendNode<T>(dto.topic);
    final matched = _dispatchToListeners(dto);
    _addAllEvent(dto, matched);
    return matched;
  }

  ///Delivers to the exact node and to every matching pattern node.
  ///
  ///An [incoming] event came from another process: a transport node delivers it
  ///locally without publishing it back.
  bool _dispatchToListeners(EventDTO dto, {bool incoming = false}) {
    var matched = false;
    final exact = _eventsMap[dto.topic];
    if (exact != null) {
      _deliverNode(exact, dto, incoming);
      matched = true;
    }
    for (final entry in _matchingPatternEntries(dto.topic)) {
      _deliverNode(entry.value, dto, incoming);
      matched = true;
    }
    return matched;
  }

  void _deliverNode(EventNode node, EventDTO dto, bool incoming) {
    if (incoming && node is IncomingEventNode) {
      (node as IncomingEventNode).deliverIncoming(dto);
    } else {
      node.deliver(dto);
    }
  }

  ///Pattern nodes matching a concrete topic, most specific first.
  List<MapEntry<Topic, EventNode>> _matchingPatternEntries(Topic topic) {
    if (TopicPattern.isPattern(topic)) return const [];
    final insertion = <Topic, int>{};
    final matches = <MapEntry<Topic, EventNode>>[];
    var index = 0;
    for (final entry in _patternMap.entries) {
      insertion[entry.key] = index++;
      if (TopicPattern.matches(entry.key, topic)) {
        matches.add(entry);
      }
    }
    matches.sort((a, b) {
      final byScore = TopicPattern.specificity(b.key)
          .compareTo(TopicPattern.specificity(a.key));
      if (byScore != 0) return byScore;
      return insertion[a.key]!.compareTo(insertion[b.key]!);
    });
    return matches;
  }

  ///The node stored for a concrete or pattern topic, without creating one.
  EventNode? _nodeByTopic(Topic topic) =>
      TopicPattern.isPattern(topic) ? _patternMap[topic] : _eventsMap[topic];

  ///The node an event is sent to, created when the bus allows it.
  EventNode<T>? _sendNode<T>(Topic topic) {
    var node = _eventsMap[topic];
    if (node is EventNode<T>) return node;
    if (shouldCreateNodeOnSend(topic)) {
      var created = createNode<T>(topic: topic);
      _eventsMap[topic] = created;
      return created;
    }
    return null;
  }

  /// This method is called every time a listener closes the stream.
  /// The node is kept when it has listeners, a request handler, a pin from a
  /// transport, or when this is a model bus.
  bool removeNode(Topic topic, EventNode node) {
    final pinned = node is KeepAliveNode && (node as KeepAliveNode).keepAlive;
    if (!node.streamControllerValue.hasListener &&
        !isModelBus &&
        !_hasHandlerFor(topic) &&
        !pinned) {
      unawaited(node.dispose());
      _eventsMap.remove(topic);
      _patternMap.remove(topic);
      return true;
    }
    return false;
  }

  /// Checks if the bus contains a listener for the specified topic.
  ///
  ///For a concrete topic a matching pattern listener also counts.
  @override
  bool haveListener<T>({
    List<String>? paths,
    String? separator,
  }) {
    var t = Topic.create<T>(
        paths: paths, separator: separator ?? defaultTopicPathSeparator);
    if (TopicPattern.isPattern(t)) {
      TopicPattern.validate(t);
      return _patternMap[t]?.streamControllerValue.hasListener ?? false;
    }
    final exact = _eventsMap[t];
    if (exact?.streamControllerValue.hasListener ?? false) return true;
    return _matchingPatternEntries(t)
        .any((entry) => entry.value.streamControllerValue.hasListener);
  }

  /// Closes the all-events stream and every node of the bus.
  /// Safe to call more than once; after dispose the bus throws StateError on use.
  @override
  Future<void> dispose() => _disposeFuture ??= _disposeImpl();

  Future<void> _disposeImpl() async {
    _disposed = true;
    await _allEventStream.close();
    var nodes = [..._eventsMap.values, ..._patternMap.values];
    _eventsMap.clear();
    _patternMap.clear();
    await Future.wait(nodes.map((e) => e.dispose()));
  }
}

///Request handlers: registration, resolution and invocation.
///
///A handler is a responder for [EventBus.request]. It is not called by
///[EventBus.fire]; event processing belongs to listeners.
mixin EventBusHandlersMixin on EventBusMixin implements EventBusHandlers {
  final Map<Topic, RequestHandler> _requestHandlers = {};

  @override
  EventBusHandlers get handlers => this;

  @override
  bool _hasHandlerFor(Topic topic) => _requestHandlers.containsKey(topic);

  @override
  void setHandler<T>({
    T? initialData,
    List<String>? paths,
    String? separator,
    required Handler<T> handler,
  }) {
    _checkNotDisposed();
    final topic = Topic.create<T>(
        paths: paths, separator: separator ?? defaultTopicPathSeparator);
    final node = _nodeFor<T>(topic);
    if (initialData != null) {
      node.currentData = initialData;
    }
    _requestHandlers[topic] = RequestHandler(
      topic: topic,
      accepts: (data) => data is T,
      invoke: (dto, lastData) {
        final typed = EventDTO<T>(dto.data as T,
            topic: dto.topic, arguments: dto.arguments);
        return handler(typed, lastData as T?);
      },
    );
  }

  @override
  void removeHandler<T>({List<String>? paths, String? separator}) {
    _checkNotDisposed();
    final topic = Topic.create<T>(
        paths: paths, separator: separator ?? defaultTopicPathSeparator);
    _requestHandlers.remove(topic);
    final node = _nodeByTopic(topic);
    if (node != null) {
      removeNode(topic, node);
    }
  }

  @override
  bool haveHandler<T>({List<String>? paths, String? separator}) {
    final topic = Topic.create<T>(
        paths: paths, separator: separator ?? defaultTopicPathSeparator);
    if (TopicPattern.isPattern(topic)) {
      TopicPattern.validate(topic);
      return _requestHandlers.containsKey(topic);
    }
    return _resolveHandler(topic) != null;
  }

  ///The exact handler for [topic], or the most specific pattern handler that
  ///matches it. A pattern topic is resolved by the exact key only.
  RequestHandler? _resolveHandler(Topic topic) {
    final exact = _requestHandlers[topic];
    if (exact != null) return exact;
    if (TopicPattern.isPattern(topic)) return null;

    RequestHandler? best;
    var bestScore = -1;
    for (final entry in _requestHandlers.entries) {
      final pattern = entry.key;
      if (!TopicPattern.isPattern(pattern)) continue;
      if (!TopicPattern.matches(pattern, topic)) continue;
      final score = TopicPattern.specificity(pattern);
      if (score > bestScore) {
        best = entry.value;
        bestScore = score;
      }
    }
    return best;
  }

  @override
  Future<dynamic> request<T>(T data,
      {List<String>? paths,
      String? separator,
      Map<String, String>? arguments,
      Duration? timeout}) async {
    _checkNotDisposed();
    _rejectWildcardPaths(paths, 'request');
    final topic = Topic.create<T>(
        paths: paths, separator: separator ?? defaultTopicPathSeparator);
    final registration = _resolveHandler(topic);
    if (registration == null || !registration.accepts(data)) {
      _addAllEvent(
          EventDTO<T>(data, topic: topic, arguments: arguments), false);
      throw NoHandlerException(topic.topic);
    }

    final handlerNode = _nodeByTopic(registration.topic);
    final previous = handlerNode?.currentData;
    final dto = EventDTO<T>(data, topic: topic, arguments: arguments);
    final matched = _dispatchToListeners(dto);
    _addAllEvent(dto, matched);

    final future = _invoke(registration, dto, previous);
    return timeout == null ? await future : await future.timeout(timeout);
  }

  ///Runs the user handler. Its returned value is the response; an exception
  ///becomes the error of the request.
  Future<dynamic> _invoke(
      RequestHandler registration, EventDTO dto, Object? lastData) {
    return registration.invoke(dto, lastData);
  }

  ///Dispatches a request received from another process, for example a
  ///transport.
  ///
  ///The handler is resolved exactly like a local [request]; listeners are
  ///notified too. The returned future is the handler's response. Throws
  ///[NoHandlerException] when no registered handler accepts the data.
  Future<dynamic> handleIncomingRequest(EventDTO dto) =>
      _dispatchIncoming(dto)!;

  ///Dispatches an event received from another isolate.
  ///
  ///A request needs a registered handler; a fire event is delivered to
  ///listeners only.
  Future? _dispatchIncoming(EventDTO dto, {bool request = true}) {
    if (!request) {
      final matched = _dispatchToListeners(dto, incoming: true);
      _addAllEvent(dto, matched);
      return null;
    }

    final registration = _resolveHandler(dto.topic);
    if (registration == null || !registration.accepts(dto.data)) {
      _addAllEvent(dto, false);
      throw NoHandlerException(dto.topic.topic);
    }

    final handlerNode = _nodeByTopic(registration.topic);
    final previous = handlerNode?.currentData;
    final matched = _dispatchToListeners(dto, incoming: true);
    _addAllEvent(dto, matched);
    return _invoke(registration, dto, previous);
  }

  @override
  void addAllHandlerFromOtherBus(EventBus fromBus) {
    _checkNotDisposed();
    if (fromBus is EventBusHandlersMixin) {
      for (final entry in fromBus._requestHandlers.entries) {
        _requestHandlers[entry.key] = entry.value;
      }
    }
    if (fromBus is EventBusMixin) {
      void copyInto(Map<Topic, EventNode> from, Map<Topic, EventNode> to) {
        for (final entry in from.entries) {
          final replaced = to[entry.key];
          if (replaced != null && !identical(replaced, entry.value)) {
            unawaited(replaced.dispose());
          }
          to[entry.key] = entry.value.copy();
        }
      }

      copyInto(fromBus._eventsMap, _eventsMap);
      copyInto(fromBus._patternMap, _patternMap);
    }
  }

  @override
  void removeAllHandlerPresentInOtherBus(EventBus otherBus) {
    _checkNotDisposed();
    if (otherBus is EventBusHandlersMixin) {
      for (final topic in otherBus._requestHandlers.keys) {
        _requestHandlers.remove(topic);
        final node = _nodeByTopic(topic);
        if (node != null) {
          removeNode(topic, node);
        }
      }
    }
  }
}

///A fire or request must address one concrete topic: wildcards are not
///allowed in the call itself.
void _rejectWildcardPaths(List<String>? paths, String operation) {
  if (paths == null) return;
  for (final path in paths) {
    if (path.contains('*') || path.contains('>')) {
      throw EventBusException(
          '$operation does not support wildcard paths ("$path")');
    }
  }
}
