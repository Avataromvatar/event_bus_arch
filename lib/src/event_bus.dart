part of event_arch;

///If hadler completed but no complite EventDTO.completer EventNode return null(EventDTO.completer(null)) to sender
typedef Handler<T> = Future<void> Function(EventDTO<T> dto, T? lastData);

typedef Node<T> = EventNode<T>;

class EventNode<T> {
  T? lastData;
  Handler<T>? handler;
  bool get isDisposed => _streamController.isClosed;
  // void Function()? onCancel;
  StreamController<EventDTO<T>> _streamController = StreamController<EventDTO<T>>.broadcast();
  StreamController<T> _streamControllerValue = StreamController<T>.broadcast();
  StreamSubscription? _streamControllerSub;
  // void Function()? _onDispose;
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
      }

      _streamControllerValue.add(event.data);
    });
  }
  void send(EventDTO dto) {
    if (dto.data is T) {
      var d = EventDTO<T>(dto.data, topic: dto.topic, completer: dto.completer);
      lastData = dto.data;
      _streamController.add(d);
    }
  }

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

  ///stream for sended event (event dto, have listener or not)
  Stream<(EventDTO, bool)> get allEventStream;

  ///true if bus contain listener
  bool haveListener<T>({
    String? path,
    String? target,
  });

  ///true if bus contain handler
  bool haveHandler<T>({
    String? path,
    String? target,
  });

  ///When you send event, handler can return result if call EventDTO.completer
  Future<dynamic>? send<T>(
    T data, {
    String? path,
    String? fragment,
    String? target,
    Map<String, String>? arguments,
  });
  Stream<T> listen<T>({
    String? path,
    String? target,
  });
  T? lastData<T>({
    String? path,
    String? target,
  });
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

abstract class EventBusHandlers {
  void setHandler<T>({T? initalData, String? path, String? target, required Handler<T> handler});
  void removeHandler<T>({
    String? path,
    String? target,
  });
  void addAllHandlerFromOtherBus(EventBus fromBus);
  void removeAllHandlerPresentInOtherBus(EventBus otherBus);
}

class EventBusImpl with EventBusMixin {
  final bool _isModelBus;
  @override
  bool get isModelBus => _isModelBus;

  EventBusImpl(this._isModelBus);
}
// class EventBusImpl implements EventBus, EventBusHandlers {
//   final StreamController<(EventDTO, bool)> _allEventStream = StreamController<(EventDTO, bool)>.broadcast();
//   Stream<(EventDTO, bool)> get allEventStream => _allEventStream.stream;

//   final Map<Topic, EventNode> _map = {};
//   @override
//   final bool isModelBus;
//   EventBusImpl(this.isModelBus);
//   @override
//   T? lastData<T>({String? path, String? target}) {
//     var t = Topic.create<T>(path: path, target: target);
//     var node = _map[t];
//     if (node != null && node is EventNode<T>) {
//       // if (node.lastData is T) {
//       return node.lastData;
//       // } else {
//       //   throw Exception('EventBus storage node($t) with broken data ');
//       // }
//     }
//     return null;
//   }

//   @override
//   Stream<T> listen<T>({String? path, String? target}) {
//     var t = Topic.create<T>(path: path, target: target);
//     var node = _map[t];
//     if (node != null && node is EventNode<T>) {
//       return node._streamControllerValue.stream.doOnCancel(() {
//         removeNode(t, node!);
//       }) as Stream<T>;
//     } else {
//       node = EventNode<T>();
//       _map[t] = node;
//       return node._streamControllerValue.stream.doOnCancel(() {
//         removeNode(t, node!);
//       }) as Stream<T>;
//     }
//   }

//   @override
//   Future? send<T>(T data, {String? path, String? fragment, String? target, Map<String, String>? arguments}) async {
//     var dto =
//         EventDTO<T>(data, path: path, fragment: fragment, arguments: arguments, target: target, completer: Completer());
//     var node = _map[dto.topic];
//     if (node != null && node is EventNode<T>) {
//       node.send(dto);
//       _allEventStream.add((dto, true));
//       return dto.completer?.future;
//     } else if (isModelBus) {
//       _map[dto.topic] = EventNode<T>();
//       _map[dto.topic]!.send(dto);
//       _allEventStream.add((dto, true));
//       return dto.completer?.future;
//     }
//     _allEventStream.add((dto, false));
//     return null;
//   }

//   @override
//   void removeHandler<T>({String? path, String? target}) {
//     var t = Topic.create<T>(path: path, target: target);
//     var node = _map[t];
//     if (node != null) {
//       node.dispose();
//       _map.remove(t);
//     }
//   }

//   @override
//   void setHandler<T>({T? initalData, String? path, String? target, required Handler<T> handler}) {
//     var t = Topic.create<T>(path: path, target: target);
//     var node = _map[t];
//     if (node != null && node is EventNode<T>) {
//       node.handler = handler;
//     } else {
//       _map[t] = EventNode<T>(handler: handler, lastData: initalData);
//     }
//   }

//   ///This method call every time when listener close stream
//   ///node removed if has no listener and handler and this !isModelBus
//   bool removeNode(Topic topic, EventNode node) {
//     if (!node._streamControllerValue.hasListener && !isModelBus && node.handler == null) {
//       node.dispose();
//       _map.remove(topic);
//       return true;
//     }
//     return false;
//   }

//   @override
//   bool haveHandler<T>({String? path, String? target}) {
//     var t = Topic.create<T>(path: path, target: target);
//     var node = _map[t];
//     return node?.handler != null;
//   }

//   @override
//   bool haveListener<T>({String? path, String? target}) {
//     var t = Topic.create<T>(path: path, target: target);
//     var node = _map[t];
//     return node?._streamControllerValue.hasListener ?? false;
//   }
// }

mixin EventBusMixin implements EventBus, EventBusHandlers {
  final StreamController<(EventDTO, bool)> _allEventStream = StreamController<(EventDTO, bool)>.broadcast();
  Stream<(EventDTO, bool)> get allEventStream => _allEventStream.stream;

  final Map<Topic, EventNode> _eventsMap = {};
  @override
  bool get isModelBus => false;
  // EventBusImpl(this.isModelBus);
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

  @override
  Stream<T> listen<T>({String? path, String? target}) {
    var t = Topic.create<T>(path: path, target: target);
    var node = _eventsMap[t];
    if (node != null && node is EventNode<T>) {
      return node._streamControllerValue.stream.doOnCancel(() {
        removeNode(t, node!);
      }) as Stream<T>;
    } else {
      node = EventNode<T>();
      _eventsMap[t] = node;
      return node._streamControllerValue.stream.doOnCancel(() {
        removeNode(t, node!);
      }) as Stream<T>;
    }
  }

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

  @override
  void removeHandler<T>({String? path, String? target}) {
    var t = Topic.create<T>(path: path, target: target);
    var node = _eventsMap[t];
    if (node != null) {
      node.dispose();
      _eventsMap.remove(t);
    }
  }

  @override
  void addAllHandlerFromOtherBus(EventBus fromBus) {
    if (fromBus is EventBusMixin) {
      for (var element in fromBus._eventsMap.entries) {
        if (element.value.handler != null) {
          _eventsMap[element.key] = element.value;
        }
      }
    }
  }

  @override
  void removeAllHandlerPresentInOtherBus(EventBus otherBus) {
    if (otherBus is EventBusMixin) {
      for (var element in otherBus._eventsMap.entries) {
        if (element.value.handler != null) {
          _eventsMap.remove(element.key);
        }
      }
    }
  }

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

  ///This method call every time when listener close stream
  ///node removed if has no listener and handler and this !isModelBus
  bool removeNode(Topic topic, EventNode node) {
    if (!node._streamControllerValue.hasListener && !isModelBus && node.handler == null) {
      node.dispose();
      _eventsMap.remove(topic);
      return true;
    }
    return false;
  }

  @override
  bool haveHandler<T>({String? path, String? target}) {
    var t = Topic.create<T>(path: path, target: target);
    var node = _eventsMap[t];
    return node?.handler != null;
  }

  @override
  bool haveListener<T>({String? path, String? target}) {
    var t = Topic.create<T>(path: path, target: target);
    var node = _eventsMap[t];
    return node?._streamControllerValue.hasListener ?? false;
  }
}
