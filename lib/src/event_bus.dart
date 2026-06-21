part of event_arch;

/// Handler function type for processing events.
/// The handler receives the event data and the last data from the same topic.
/// If the handler completes but doesn't call EventDTO.completer, 
/// EventNode returns null (EventDTO.completer(null)) to the sender.
typedef Handler<T> = Future<void> Function(EventDTO<T> dto, T? lastData);

/// Alias for EventNode type
typedef Node<T> = EventNode<T>;

/// EventNode represents a node in the event bus system.
/// It manages the handler, last data, and stream controllers for a specific topic.
class EventNode<T> {
  T? lastData;
  Handler<T>? handler;
  bool get isDisposed => _streamController.isClosed;
  // void Function()? onCancel;
  StreamController<EventDTO<T>> _streamController = StreamController<EventDTO<T>>.broadcast();
  StreamController<T> _streamControllerValue = StreamController<T>.broadcast();
  StreamSubscription? _streamControllerSub;
  // void Function()? _onDispose;
  
  /// Creates an EventNode with optional initial data and handler.
  /// Sets up the stream listener to process incoming events.
  EventNode({
    this.lastData,
    this.handler,
    /*this.onCancel*/
  }) {
    _streamControllerSub = _streamController.stream.listen((event) {
      if (handler != null) {
        handler!(event, lastData).then((value) {
          if (!(event.completer?.isCompleted ?? false)) {
            event.completer?.complete(null);
          }
        });
      } else 
      {
        if (!(event.completer?.isCompleted ?? false)) {
            event.completer?.complete(null);
          }
      }


      _streamControllerValue.add(event.data);
    });
  }
  
  bool get isHaveHandler => handler!=null;
  /// Sends an event to the node if the data type matches T.
  /// Updates the lastData and adds the event to the stream.
  void send(EventDTO dto) {
    if (dto.data is T) {
      var d = EventDTO<T>(dto.data, topic: dto.topic, completer: dto.completer);
      lastData = dto.data;
      _streamController.add(d);
    }
  }

  /// Disposes of the node, closing all stream controllers and cancelling subscriptions.
  Future<void> dispose() async {
    _streamControllerSub?.cancel();
    _streamControllerSub = null;
    if (!_streamControllerValue.isClosed) {
      await _streamControllerValue.close();
    }
    if (!_streamController.isClosed) {
      await _streamController.close();
    }
    // if (_onDispose != null) {
    //   _onDispose!.call();
    //   _onDispose = null;
    // }
  }
}

abstract class EventBus {
  bool get isModelBus;

  /// Stream for all sent events (event DTO, and whether it had a listener or not)
  Stream<(EventDTO, bool)> get allEventStream;

  /// Returns true if the bus contains a listener for the specified topic
  bool haveListener<T>({
    String? path,
    String? target,
  });

  /// Returns true if the bus contains a handler for the specified topic
  bool haveHandler<T>({
    String? path,
    String? target,
  });

  /// Sends an event to the bus.
  /// If a handler exists for the topic, it will be called.
  /// Returns a Future that completes with the result if EventDTO.completer was called by the handler.
  Future<dynamic>? send<T>(
    T data, {
    String? path,
    String? fragment,
    String? target,
    Map<String, String>? arguments,
  });
  
  /// Listens to events on a specific topic.
  /// Returns a Stream of the data type T.
  Stream<T> listen<T>({
    String? path,
    String? target,
  });
  ///Subscribe to events on a specific topic.
  StreamSubscription<T> subscribe<T>({String? path, String? target,void Function(T e)? onData, Function? onError, void Function()? onDone, bool? cancelOnError});
  /// Gets the last data sent to a specific topic.
  T? lastData<T>({
    String? path,
    String? target,
  });
  
  /// Factory constructor for EventBus.
  /// Creates an EventBusImpl instance.
  factory EventBus({bool isModelBus = false}) {
    return EventBusImpl(isModelBus);
  }
  // void _addNode() {
  //   _map[Topic.create<int>()] = (0, null, StreamController<EventDTO<int>>.broadcast());
  //   _map[Topic.create<int>()]!.$3.onCancel = () {
  //     _map.remove(Topic.create<int>());
  //   };

  // }
}

/// 
abstract class EventBusHandlers {
  /// Sets a handler for a specific topic.
  /// If initialData is provided, it will be used as the initial data for the topic.
  void setHandler<T>({T? initalData, String? path, String? target, required Handler<T> handler});
  
  /// Removes a handler from a specific topic.
  void removeHandler<T>({
    String? path,
    String? target,
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
  /// Stream controller for all events sent through the bus
  final StreamController<(EventDTO, bool)> _allEventStream = StreamController<(EventDTO, bool)>.broadcast();
  Stream<(EventDTO, bool)> get allEventStream => _allEventStream.stream;

  /// Map storing all event nodes by their topic
  final Map<Topic, EventNode> _eventsMap = {};
  
  @override
  bool get isModelBus => false;
  // EventBusImpl(this.isModelBus);
  
  /// Gets the last data sent to a specific topic.
  /// Returns null if no data has been sent to that topic.
  @override
  T? lastData<T>({String? path, String? target}) {
    var t = Topic.create<T>(path: path, target: target);
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

  /// Listens to events on a specific topic.
  /// Creates a new EventNode if one doesn't exist for that topic.
  /// Returns a Stream of the data type T.
  @override
  Stream<T> listen<T>({String? path, String? target}) {
    var t = Topic.create<T>(path: path, target: target);
    var node = _eventsMap[t];
    if (node != null && node is EventNode<T>) {
      return node._streamControllerValue.stream.doOnCancel(() {
        removeNode(t, node!);
      });
      // return node._streamControllerValue.stream.doOnCancel(() {
      //   removeNode(t, node!);
      // }) as Stream<T>;
    } else {
      node = EventNode<T>();
      _eventsMap[t] = node;
      return node._streamControllerValue.stream.doOnCancel(() {
        removeNode(t, node!);
      });
      // return node._streamControllerValue.stream.doOnCancel(() {
      //   removeNode(t, node!);
      // }) as Stream<T>;
    }
  }
  @override
  StreamSubscription<T> subscribe<T>({String? path, String? target,void Function(T e)? onData, Function? onError, void Function()? onDone, bool? cancelOnError}) {
    var t = Topic.create<T>(path: path, target: target);
    var node = _eventsMap[t];
    if (node != null && node is EventNode<T>) {
      return node._streamControllerValue.stream.doOnCancel(() {
        removeNode(t, node!);
      }).listen(onData,cancelOnError: cancelOnError,onDone: onDone,onError: onError);
      // return node._streamControllerValue.stream.doOnCancel(() {
      //   removeNode(t, node!);
      // }) as Stream<T>;
    } else {
      node = EventNode<T>();
      _eventsMap[t] = node;
      return node._streamControllerValue.stream.doOnCancel(() {
        removeNode(t, node!);
      }).listen(onData,cancelOnError: cancelOnError,onDone: onDone,onError: onError);
      // return node._streamControllerValue.stream.doOnCancel(() {
      //   removeNode(t, node!);
      // }) as Stream<T>;
    }
  }

  /// Sends an event to the bus.
  /// If a handler exists for the topic, it will be called.
  /// Returns a Future that completes with the result if EventDTO.completer was called by the handler.
  /// If no handler exists, returns null.
  @override
  Future? send<T>(T data, {String? path, String? fragment, String? target, Map<String, String>? arguments}) async {
    var dto =
        EventDTO<T>(data, path: path, fragment: fragment, arguments: arguments, target: target, completer: Completer());
    var node = _eventsMap[dto.topic];
    if (node != null && node is EventNode<T>) {
      node.send(dto);
      _allEventStream.add((dto, true));
      return dto.completer?.future;
    } else if (isModelBus) {
      _eventsMap[dto.topic] = EventNode<T>();
      _eventsMap[dto.topic]!.send(dto);
      _allEventStream.add((dto, true));
      return dto.completer?.future;
    }

    _allEventStream.add((dto, false));
    return null;
  }

  /// Removes a handler from a specific topic.
  /// Disposes of the EventNode if it exists.
  @override
  void removeHandler<T>({String? path, String? target}) {
    var t = Topic.create<T>(path: path, target: target);
    var node = _eventsMap[t];
    if (node != null) {
      node.dispose();
      _eventsMap.remove(t);
    }
  }

  /// Adds all handlers from another EventBus to this one.
  /// Sets up stream cancellation to remove nodes when they're no longer needed.
  @override
  void addAllHandlerFromOtherBus(
    EventBus fromBus,
  ) {
    if (fromBus is EventBusMixin) {
      for (var element in fromBus._eventsMap.entries) {
        // if (element.value.handler != null) {

        _eventsMap[element.key] = element.value;
        element.value._streamController.stream.doOnCancel(() {
          removeNode(element.key, element.value);
        });
      }
      // }
    }
  }

  /// Removes all handlers that are present in another EventBus from this one.
  @override
  void removeAllHandlerPresentInOtherBus(EventBus otherBus) {
    if (otherBus is EventBusMixin) {
      for (var element in otherBus._eventsMap.entries) {
        // if (element.value.handler != null) {
        _eventsMap.remove(element.key);
        // }
      }
    }
  }

  /// Sets a handler for a specific topic.
  /// If an EventNode already exists for that topic, it updates the handler.
  /// Otherwise, it creates a new EventNode with the handler and initial data.
  @override
  void setHandler<T>({T? initalData, String? path, String? target, required Handler<T> handler}) {
    var t = Topic.create<T>(path: path, target: target);
    var node = _eventsMap[t];
    if (node != null && node is EventNode<T>) {
      node.handler = handler;
    } else {
      _eventsMap[t] = EventNode<T>(handler: handler, lastData: initalData);
    }
  }

  /// This method is called every time a listener closes the stream.
  /// The node is removed if it has no listeners, no handler, and this is not a model bus.
  bool removeNode(Topic topic, EventNode node) {
    if (!node._streamControllerValue.hasListener && !isModelBus && !node.isHaveHandler) {
      node.dispose();
      _eventsMap.remove(topic);
      return true;
    }
    return false;
  }

  /// Checks if the bus contains a handler for the specified topic.
  @override
  bool haveHandler<T>({String? path, String? target}) {
    var t = Topic.create<T>(path: path, target: target);
    var node = _eventsMap[t];
    return node?.isHaveHandler??false;
  }

  /// Checks if the bus contains a listener for the specified topic.
  @override
  bool haveListener<T>({String? path, String? target}) {
    var t = Topic.create<T>(path: path, target: target);
    var node = _eventsMap[t];
    return node?._streamControllerValue.hasListener ?? false;
  }

  Future<void> dispose()async
  {
    
    await _allEventStream.close();
    for (var e in _eventsMap.values){
      try {
        e.dispose();
      } catch (e) {
        //TODO
      }
    }
    _eventsMap.clear();
  }
}
