part of event_arch;

/// Handler function type for processing events.
/// The handler receives the event data and the previous data from the same topic
/// (the value that was stored in [EventNode.lastData] before this event).
/// If the handler completes but doesn't call EventDTO.completer,
/// EventNode returns null (EventDTO.completer(null)) to the sender.
/// If the handler throws, the sender receives the error through the completer.
typedef Handler<T> = Future<void> Function(EventDTO<T> dto, T? lastData);

/// Alias for EventNode type
typedef Node<T> = EventNode<T>;

/// Internal envelope: DTO plus the `lastData` value at the moment of sending.
class _NodeEvent<T> {
  final EventDTO<T> dto;
  final T? previous;
  const _NodeEvent(this.dto, this.previous);
}

/// EventNode represents a node in the event bus system.
/// It manages the handler, last data, and stream controllers for a specific topic.
class EventNode<T> {
  T? lastData;
  Handler<T>? handler;
  bool get isDisposed => _streamController.isClosed;
  final StreamController<_NodeEvent<T>> _streamController = StreamController<_NodeEvent<T>>.broadcast();
  final StreamController<T> _streamControllerValue = StreamController<T>.broadcast();
  StreamSubscription? _streamControllerSub;

  /// Creates an EventNode with optional initial data and handler.
  /// Sets up the stream listener to process incoming events.
  EventNode({
    this.lastData,
    this.handler,
  }) {
    _streamControllerSub = _streamController.stream.listen(_process);
  }

  /// Handles one event: listeners first, then the handler.
  ///
  /// The value goes to the value stream before the handler runs, so listeners
  /// are notified before the sender's `await send(...)` resumes — and they get
  /// the data even when the handler fails.
  void _process(_NodeEvent<T> message) {
    var event = message.dto;

    _streamControllerValue.add(event.data);

    var h = handler;
    if (h == null) {
      _completeIfNeeded(event.completer, null);
      return;
    }

    try {
      h(event, message.previous).then(
        (_) => _completeIfNeeded(event.completer, null),
        onError: (Object error, StackTrace stackTrace) =>
            _completeErrorIfNeeded(event.completer, error, stackTrace),
      );
    } catch (error, stackTrace) {
      // a non-async handler threw synchronously
      _completeErrorIfNeeded(event.completer, error, stackTrace);
    }
  }

  static void _completeIfNeeded(Completer? completer, dynamic value) {
    if (completer != null && !completer.isCompleted) {
      completer.complete(value);
    }
  }

  static void _completeErrorIfNeeded(Completer? completer, Object error, StackTrace stackTrace) {
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
  }

  bool get isHaveHandler => handler != null;

  /// Sends an event to the node if the data type matches T.
  /// Updates the lastData and adds the event to the stream.
  void send(EventDTO dto) {
    if (dto.data is T) {
      var previous = lastData;
      // arguments are rebuilt with the event: they belong to the call, and the
      // handler reads them from the dto it is given
      var d = EventDTO<T>(dto.data,
          topic: dto.topic, completer: dto.completer, arguments: dto.arguments);
      lastData = dto.data;
      _streamController.add(_NodeEvent<T>(d, previous));
    } else {
      // an event of a foreign type: it must not be dropped silently, otherwise
      // the sender would never get an answer
      _completeIfNeeded(dto.completer, null);
    }
  }

  /// Creates an independent node with the same handler and last data.
  /// Used to move handlers between buses without sharing state.
  EventNode<T> copy() => EventNode<T>(handler: handler, lastData: lastData);

  /// Disposes of the node, closing all stream controllers and cancelling subscriptions.
  Future<void> dispose() async {
    await _streamControllerSub?.cancel();
    _streamControllerSub = null;
    if (!_streamControllerValue.isClosed) {
      await _streamControllerValue.close();
    }
    if (!_streamController.isClosed) {
      await _streamController.close();
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
  bool haveListener<T>({
    List<String>? paths,
    String? separator
  });

  /// Returns true if the bus contains a handler for the specified topic
  bool haveHandler<T>({
    List<String>? paths,
    String? separator
  });

  /// Sends an event to the bus.
  /// If a handler exists for the topic, it will be called.
  /// Returns a Future that completes with the result if EventDTO.completer was called by the handler.
  Future<dynamic>? send<T>(
    T data, {
   List<String>? paths,
    String? separator,
    Map<String, String>? arguments,
  });
  
  /// Listens to events on a specific topic.
  /// Returns a Stream of the data type T.
  Stream<T> listen<T>({
   List<String>? paths,
    String? separator
  });
  ///Subscribe to events on a specific topic.
  StreamSubscription<T> subscribe<T>({List<String>? paths, String? separator,void Function(T e)? onData, Function? onError, void Function()? onDone, bool? cancelOnError});
  /// Gets the last data sent to a specific topic.
  T? lastData<T>({
    List<String>? paths,
    String? separator
  });
  
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
  void removeHandler<T>({
   List<String>? paths,
    String? separator
  });
  
  /// Adds all handlers from another EventBus to this one.
  void addAllHandlerFromOtherBus(EventBus fromBus);
  
  /// Removes all handlers that are present in another EventBus from this one.
  void removeAllHandlerPresentInOtherBus(EventBus otherBus);
}

class EventBusImpl with EventBusMixin {
  final bool _isModelBus;
  @override
  bool get isModelBus => _isModelBus;

  /// Creates an EventBusImpl instance.
  /// If isModelBus is true, the bus behaves as a model bus.
  EventBusImpl(this._isModelBus);
}

mixin EventBusMixin implements EventBus, EventBusHandlers {
  @override
   String defaultTopicPathSeparator = '.';
  /// Stream controller for all events sent through the bus
  final StreamController<(EventDTO, bool)> _allEventStream = StreamController<(EventDTO, bool)>.broadcast();

  @override
  Stream<(EventDTO, bool)> get allEventStream => _allEventStream.stream;

  /// Map storing all event nodes by their topic
  final Map<Topic, EventNode> _eventsMap = {};

  bool _disposed = false;
  Future<void>? _disposeFuture;

  @override
  EventBusHandlers get handlers => this;

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

  /// Adds the event to the all-events stream if the bus is still alive.
  void _addAllEvent(EventDTO dto, bool delivered) {
    if (!_allEventStream.isClosed) {
      _allEventStream.add((dto, delivered));
    }
  }
  
  /// Gets the last data sent to a specific topic.
  /// Returns null if no data has been sent to that topic.
  @override
  T? lastData<T>({List<String>? paths,String? separator}) {
    var t = Topic.create<T>(paths: paths, separator: separator??defaultTopicPathSeparator);
    var node = _eventsMap[t];
    if (node != null && node is EventNode<T>) {
      // if (node.lastData is T) {
      return node.lastData;
      // } else {
      //   throw Exception('EventBus storage node($t) with broken data ');
      // }
    }

    return null;
  }

  /// Returns the node of a topic, creating it when needed.
  EventNode<T> _nodeFor<T>(Topic topic) {
    var node = _eventsMap[topic];
    if (node != null && node is EventNode<T>) {
      return node;
    }
    var created = EventNode<T>();
    _eventsMap[topic] = created;
    return created;
  }

  /// Value stream of a topic; the node may be removed when the last subscription is cancelled.
  Stream<T> _valueStream<T>(Topic topic) {
    var node = _nodeFor<T>(topic);
    return node._streamControllerValue.stream.doOnCancel(() {
      removeNode(topic, node);
    });
  }

  /// Listens to events on a specific topic.
  /// Creates a new EventNode if one doesn't exist for that topic.
  /// Returns a Stream of the data type T.
  @override
  Stream<T> listen<T>({List<String>? paths,String? separator}) {
    _checkNotDisposed();
    return _valueStream<T>(Topic.create<T>(paths: paths, separator: separator??defaultTopicPathSeparator));
  }

  @override
  StreamSubscription<T> subscribe<T>({List<String>? paths,String? separator,void Function(T e)? onData, Function? onError, void Function()? onDone, bool? cancelOnError}) {
    _checkNotDisposed();
    return _valueStream<T>(Topic.create<T>(paths: paths, separator: separator??defaultTopicPathSeparator))
        .listen(onData, cancelOnError: cancelOnError, onDone: onDone, onError: onError);
  }

  /// Sends an event to the bus.
  /// If a handler exists for the topic, it will be called.
  /// Returns a Future that completes with the result if EventDTO.completer was called by the handler.
  /// If no handler exists, returns null.
  @override
  Future? send<T>(T data, {List<String>? paths,String? separator, Map<String, String>? arguments}) async {
    _checkNotDisposed();
    var dto = EventDTO<T>(data,
        paths: paths,
        // the same fallback as setHandler/listen/lastData: otherwise a send
        // would address a node nobody else can address
        separator: separator ?? defaultTopicPathSeparator,
        arguments: arguments,
        completer: Completer());
    var node = _eventsMap[dto.topic];
    if (node != null && node is EventNode<T>) {
      node.send(dto);
      _addAllEvent(dto, true);
      return dto.completer?.future;
    } else if (isModelBus) {
      _eventsMap[dto.topic] = EventNode<T>();
      _eventsMap[dto.topic]!.send(dto);
      _addAllEvent(dto, true);
      return dto.completer?.future;
    }

    _addAllEvent(dto, false);
    return null;
  }

  /// Removes a handler from a specific topic.
  /// Disposes of the EventNode if it exists.
  @override
  void removeHandler<T>({List<String>? paths,String? separator}) {
    _checkNotDisposed();
    var t = Topic.create<T>(paths: paths, separator: separator??defaultTopicPathSeparator);
    var node = _eventsMap.remove(t);
    if (node != null) {
      unawaited(node.dispose());
    }
  }

  /// Adds all handlers from another EventBus to this one.
  /// Nodes are copied: buses don't share state, disposing one doesn't affect the other.
  @override
  void addAllHandlerFromOtherBus(
    EventBus fromBus,
  ) {
    _checkNotDisposed();
    if (fromBus is EventBusMixin) {
      for (var element in fromBus._eventsMap.entries) {
        var replaced = _eventsMap[element.key];
        if (replaced != null && !identical(replaced, element.value)) {
          unawaited(replaced.dispose());
        }
        _eventsMap[element.key] = element.value.copy();
      }
    }
  }

  /// Removes all handlers that are present in another EventBus from this one.
  @override
  void removeAllHandlerPresentInOtherBus(EventBus otherBus) {
    _checkNotDisposed();
    if (otherBus is EventBusMixin) {
      for (var element in otherBus._eventsMap.entries) {
        var node = _eventsMap.remove(element.key);
        if (node != null && !identical(node, element.value)) {
          unawaited(node.dispose());
        }
      }
    }
  }

  /// Sets a handler for a specific topic.
  /// If an EventNode already exists for that topic, it updates the handler.
  /// Otherwise, it creates a new EventNode with the handler and initial data.
  @override
  void setHandler<T>({
    T? initialData,
   List<String>? paths,String? separator,
    required Handler<T> handler,
  }) {
    _checkNotDisposed();
    var data = initialData ;
    var t = Topic.create<T>(paths: paths, separator: separator??defaultTopicPathSeparator);
    var node = _eventsMap[t];
    if (node != null && node is EventNode<T>) {
      node.handler = handler;
      if (data != null) {
        node.lastData = data;
      }
    } else {
      _eventsMap[t] = EventNode<T>(handler: handler, lastData: data);
    }
  }

  /// This method is called every time a listener closes the stream.
  /// The node is removed if it has no listeners, no handler, and this is not a model bus.
  bool removeNode(Topic topic, EventNode node) {
    if (!node._streamControllerValue.hasListener && !isModelBus && !node.isHaveHandler) {
      unawaited(node.dispose());
      _eventsMap.remove(topic);
      return true;
    }
    return false;
  }

  /// Checks if the bus contains a handler for the specified topic.
  @override
  bool haveHandler<T>({List<String>? paths,String? separator,}) {
    var t = Topic.create<T>(paths: paths, separator: separator??defaultTopicPathSeparator);
    var node = _eventsMap[t];
    return node?.isHaveHandler??false;
  }

  /// Checks if the bus contains a listener for the specified topic.
  @override
  bool haveListener<T>({List<String>? paths,String? separator,}) {
    var t = Topic.create<T>(paths: paths, separator: separator??defaultTopicPathSeparator);
    var node = _eventsMap[t];
    return node?._streamControllerValue.hasListener ?? false;
  }

  /// Closes the all-events stream and every node of the bus.
  /// Safe to call more than once; after dispose the bus throws StateError on use.
  @override
  Future<void> dispose() => _disposeFuture ??= _disposeImpl();

  Future<void> _disposeImpl() async {
    _disposed = true;
    await _allEventStream.close();
    var nodes = _eventsMap.values.toList(growable: false);
    _eventsMap.clear();
    await Future.wait(nodes.map((e) => e.dispose()));
  }
}
