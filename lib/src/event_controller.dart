part of event_arch;

enum eEventBusConnection { sourceToTarget, targetToSource, bidirectional, none }

typedef OnConnectionEventHandler = EventDTO Function(eEventBusConnection dir, EventDTO event);

abstract class EventBusConnector {
  // eEventBusConnection get callConnectedType;
  eEventBusConnection get sendConnectedType;
  EventBus get source;
  EventBus get target;
  OnConnectionEventHandler? onEvent;
  // OnConnectionEventHandler? onCall;
  void dispose();
  factory EventBusConnector({
    required EventBus source,
    required EventBus target,
    // eEventBusConnection callConnectedType = eEventBusConnection.none,
    eEventBusConnection sendConnectedType = eEventBusConnection.bidirectional,
    OnConnectionEventHandler? onEvent,
    // OnConnectionEventHandler? onCall
  }) {
    return EventBusConnectorImpl(
        source: source,
        target: target,
        // callConnectedType: callConnectedType,
        sendConnectedType: sendConnectedType,
        // onCall: onCall,
        onEvent: onEvent);
  }
}

class EventBusConnectorImpl implements EventBusConnector {
  @override
  final EventBus source;
  @override
  final EventBus target;
  @override
  // final eEventBusConnection callConnectedType;
  @override
  final eEventBusConnection sendConnectedType;
  @override
  // OnConnectionEventHandler? onCall;
  @override
  OnConnectionEventHandler? onEvent;
  // final StreamController<EventDTO> _callSource = StreamController.broadcast();
  // final StreamController<EventDTO> _callTarget = StreamController.broadcast();
  final StreamController<EventDTO> _sendSource = StreamController.broadcast();
  final StreamController<EventDTO> _sendTarget = StreamController.broadcast();
  StreamSubscription? _streamSubscriptionSource;
  StreamSubscription? _streamSubscriptionTarget;
  EventBusConnectorImpl(
      {required this.source,
      required this.target,
      // this.callConnectedType = eEventBusConnection.none,
      this.sendConnectedType = eEventBusConnection.bidirectional,
      // this.onCall,
      this.onEvent}) {
    if (sendConnectedType == eEventBusConnection.bidirectional ||
        sendConnectedType == eEventBusConnection.sourceToTarget) {
      _streamSubscriptionSource = source.streamSend.listen((event) {
        target.sinkToSend.add(event);
      });
    }
    if (sendConnectedType == eEventBusConnection.bidirectional ||
        sendConnectedType == eEventBusConnection.targetToSource) {
      _streamSubscriptionTarget = target.streamSend.listen((event) {
        source.sinkToSend.add(event);
      });
    }
  }

  @override
  void dispose() {
    _streamSubscriptionSource?.cancel();
    _streamSubscriptionTarget?.cancel();
  }
}

abstract class EventBusHandler {
  Command<T> addHandler<T>(
    Executor<T> handler, {
    String? path,
    String? target,
  });
  void removeHandler<T>({
    String? path,
    String? target,
  });

  // void connect(EventBusHandlersGroup externHandlers);
  // void disconnect(EventBusHandlersGroup externHandlers);
}

abstract class EventBusStream {
  ///all event what send to bus.
  Stream<EventDTO> get streamSend;

  /// This stream is handler return
  /// $1 event and $2 result after call
  Stream<(EventDTO, dynamic)> get streamCall;

  ///Event that sended to sinkToSend not throw to streamSend
  Sink<EventDTO> get sinkToSend;
  Sink<EventDTO> get sinkToCall;
}

///CHAIN: if event handler(executer) return ChainEventDTO this ChainEventDTO or List< ChainEventDTO> will be sended in bus
///Chain completed if EventDTO have not handler or handler return not ChainEventDTO
///Chain work only for send

abstract class EventBus implements EventBusStream {
  /// name use for Topic target
  /// if Topic.target == 'all' this broadcast event
  String get name;

  ///check if there is a listener on the bus
  bool contain(Topic topic);

  ///return EventDTO if hasListener.

  EventDTO<T>? send<T>(
    T data, {
    String? path,
    String? fragment,
    String? target,
    Map<String, String>? arguments,
  });

  ///use event or [topic and data ]
  EventDTO<T>? sendEvent<T>({
    EventDTO<T>? event,
    Topic? topic,
    T? data,
  });

  ///use events or eventsEntry<topic,data>
  List<EventDTO<dynamic>?> sendAll({Map<Topic, dynamic>? eventsMap, List<EventDTO>? events});
  // Future<List<EventDTO<dynamic>?>> sendChain({EventDTO? event, Topic? topic, dynamic data});

  ///can return value if handler do it(call needComplete) or cancel if handler not complete Future or this even not have a handler
  ///
  ///
  Future<dynamic> call<T>(
    T data, {
    String? path,
    String? fragment,
    String? target,
    Map<String, String>? arguments,
  });

  ///use event or [topic and data ]
  Future<dynamic>? callEvent<T>({EventDTO<T>? event, Topic? topic, T? data});

  ///use events or eventsEntry<topic,data>
  Future<List<dynamic>?> callAll(List<EventDTO> events, {bool asyncOrder = true});

  ///repeat last event by topic.
  ///If set duration event be repeated when duration time end
  ///return EventDTO<T> if event have node
  EventDTO<T>? repeat<T>({String? path, String? target, Duration? duration});
  List<bool?> repeatAll({List<Topic>? events});

  ///Use [repeatLastEvent] if need send lastEvent. @attention event be sended after wait 1 millisecond or [Duration]
  ///
  ///if prefix set and they != bus.prefix, event search in EventMaster and @attention EventMaster can return null
  Stream<T>? listen<T>({
    String? path,
    String? target,
  });
  Stream<EventDTO<T>>? listenEvent<T>({EventDTO<T>? event, Topic? topic});
  Stream<dynamic> groupListen(List<Stream> streams);
  Stream<EventDTO> listenAll(List<Topic> topics);

  ///return the last event
  T? lastData<T>({String? path, String? target});
  EventDTO<T>? lastEvent<T>(Topic topic);

  ///Return map where:
  ///
  ///key = topic
  ///
  ///value = last event
  Map<Topic, dynamic> lastEventAll();
  List<Topic> getAllTopic();

  factory EventBus(
    String name, {
    bool isModelBus = false,
    bool addToMaster = true,
  }) {
    if (isModelBus) {
      return EventModelBusController(
        name: name,
        addToMaster: addToMaster,
      );
    } else {
      return EventBusController(
        name: name,
        addToMaster: addToMaster,
      );
    }
  }
}

class _EventNode<T> {
  final EventBus bus;
  Stream<EventDTO<T>> get stream => _streamController.stream;
  bool get hasListener => _streamController.hasListener;
  bool get hasHandler => _handler != null;
  bool _isDispose = false;
  bool get isDispose => _isDispose;
  late final StreamController<EventDTO<T>> _streamController;
  final Executor<T>? _handler;
  Function(Topic topic)? onCancel;
  EventDTO<T>? lastEvent;
  int executeCount = 0;
  final Topic topic;
  _EventNode(
    this.topic,
    this._handler,
    this.bus, {
    this.onCancel,
  }) {
    _streamController = StreamController<EventDTO<T>>.broadcast(onCancel: _onCancel);
  }

  Command<T> createCommand() {
    return Command<T>(topic, data: lastEvent?.data, eventBusBinded: bus);
  }

  Future<dynamic> execute(EventDTO<T> event) async {
    if (!_isDispose && event.topic == topic) {
      executeCount++;
      var ret = _handler?.call(event.topic, data: event.data, oldData: lastEvent?.data);
      if (_streamController.hasListener) {
        _streamController.add(event);
      }
      lastEvent = event;
      return ret;
    } else {
      if (event.topic != topic) {
        throw EventBusException('Topic:$topic is dispose');
      } else {
        throw EventBusException('Node $topic != ${event.topic}');
      }
    }
  }

  bool repeatLast() {
    if (lastEvent != null) {
      execute(lastEvent!);
      return true;
    }
    return false;
  }

  // Future<void> call(EventDTO<T> event, {bool isRepeat = false, Completer<dynamic>? needComplete}) async {
  //   if (!_isDispose) {
  //     lastEvent = event.data;
  //     _lastUUID = event.uuid;
  //     if (_handler != null) {
  //       _handler!.call(event, (event) {
  //         if (_streamController.hasListener) {
  //           // if (needLogging) _logging(event, 'send');
  //           _streamController.add(event);
  //         } else {
  //           // if (needLogging) _loggingHasNoListener(event.topic, 'send');
  //         }
  //       }, bus: bus, needComplete: needComplete).then((value) {
  //         if (needComplete != null && !needComplete.isCompleted) {
  //           needComplete.completeError('$topic Handler not complete call');
  //         }
  //       });
  //     } else {
  //       if (_streamController.hasListener) {
  //         // if (needLogging) _logging(event, 'send');
  //         _streamController.add(event);
  //         if (needComplete != null) {
  //           needComplete.completeError('No handlers');
  //         }
  //       } else {
  //         // if (needLogging) _loggingHasNoListener(event.topic, 'send');
  //       }
  //       // _streamController.hasListener ? _streamController.add(event) : null;
  //     }
  //   }
  // }

  // Future<void> repeat({String? uuid, Duration? duration}) async {
  //   String u = '';
  //   if (lastEvent != null) {
  //     if (uuid != null) {
  //       u = uuid;
  //     } else {
  //       u = _lastUUID!; // Uuid().v1();
  //     }
  //     if (duration != null) {
  //       await Future.delayed(duration);
  //     }
  //     await call(EventDTO<T>(topic, lastEvent!, uuid: u), isRepeat: true);
  //   }
  // }

  void _onCancel() {
    onCancel?.call(topic);
  }

  Future<void> dispose() async {
    _isDispose = true;
    // _handler = null;
    await _streamController.close();
    // onCancel = null;
  }
}

class EventBusController implements EventBus, EventBusHandler {
  final StreamController<(EventDTO, dynamic)> _callStreamController = StreamController.broadcast();
  final StreamController<EventDTO> _sendStreamController = StreamController.broadcast();
  final StreamController<EventDTO> _callSinkController = StreamController.broadcast();
  final StreamController<EventDTO> _sendSinkController = StreamController.broadcast();
  @override
  // TODO: implement sinkToCall
  Sink<EventDTO> get sinkToCall => _callSinkController.sink;

  @override
  // TODO: implement sinkToSend
  Sink<EventDTO> get sinkToSend => throw _sendSinkController.sink;

  @override
  // TODO: implement streamCall
  Stream<(EventDTO, dynamic)> get streamCall => _callStreamController.stream;

  @override
  // TODO: implement streamSend
  Stream<EventDTO> get streamSend => _sendStreamController.stream;
  @override
  // TODO: implement name
  final String name;

  final Map<Topic, _EventNode> _nodes = {};

  /// addToMaster work only name isNotEmpty @attention name must be uniqe
  EventBusController({required this.name, bool addToMaster = true}) {
    if (addToMaster) {
      EventBusMaster.instance.add(this);
    }
    _callSinkController.stream.listen((event) {
      _call(event.topic, event.data);
    });
    _sendSinkController.stream.listen((event) {
      _send(event, noSendToStream: true);
    });
  }

  void _cancelStreamInNode(Topic topic) {
    _nodes[topic]?.dispose();
    _nodes.remove(topic);
  }

  @override
  Command<T> addHandler<T>(Executor<T> handler, {String? path, String? target}) {
    var t = Topic.create<T>(path: path, target: target);
    var n = _EventNode<T>(
      t,
      handler,
      this,
      onCancel: _cancelStreamInNode,
    );
    _nodes[t] = n;
    return n.createCommand();
  }

  @override
  void removeHandler<T>({String? path, String? target}) {
    var t = Topic.create<T>(path: path, target: target);
    _nodes[t]?.dispose();
    _nodes.remove(t.topic);
  }

  Future _call<T>(Topic topic, T? data) async {
    var n = _nodes[topic];
    if (n != null) {
      if (n.hasHandler) {
        var e = EventDTO<T>(topic, data);
        var ret = await n.execute(e);
        _callStreamController.add((e, ret));

        //CHAIN CALL
        if (ret is ChainEventDTO) {
          _send(ret);
        }
        if (ret is List<ChainEventDTO>) {
          ret.forEach(
            (element) {
              _send(element);
            },
          );
        }
        return ret;
      } else {
        throw EventBusException('EventBus $name not have ${topic.topic} handler');
      }
    } else {
      throw EventBusException('EventBus $name not have ${topic.topic} Node');
    }
  }

  @override
  Future call<T>(T data, {String? path, String? fragment, String? target, Map<String, String>? arguments}) {
    var t = Topic.create<T>(path: path, target: target);

    return _call<T>(t, data);
  }

  @override
  Future<List<dynamic>?> callAll(List<EventDTO> events, {bool asyncOrder = true}) async {
    var l = events.map((e) => _call(e.topic, e.data)).toList();
    if (asyncOrder) {
      return Future.wait(l);
    } else {
      var ret = [];
      for (var i = 0; i < l.length; i++) {
        ret.add(await l[i]);
      }
      return ret;
    }
  }

  @override
  Future? callEvent<T>({EventDTO<T>? event, Topic? topic, T? data}) {
    assert(event != null || (topic != null));
    if (event != null) {
      return _call<T>(event.topic, event.data);
    } else {
      return _call<T>(topic!, data);
    }
  }

  @override
  bool contain(Topic topic) {
    return _nodes.containsKey(topic.topic);
  }

  @override
  Stream groupListen(List<Stream> streams) {
    return StreamGroup.mergeBroadcast(streams);
  }

  @override
  T? lastData<T>({String? path, String? target}) {
    var t = Topic.create<T>(path: path, target: target);
    return _nodes[t.topic]?.lastEvent?.data;
  }

  @override
  EventDTO<T>? lastEvent<T>(Topic topic) {
    var r = _nodes[topic.topic]?.lastEvent;
    if (r != null) {
      return _nodes[topic.topic]?.lastEvent as EventDTO<T>;
    } else {
      return null;
    }
  }

  @override
  Map<Topic, dynamic> lastEventAll() {
    return _nodes.map((key, value) => MapEntry(value.topic, value.lastEvent));
  }

  @override
  Stream<T>? listen<T>({String? path, String? target}) {
    var t = Topic.create<T>(path: path, target: target);
    var node = _nodes[t.topic];
    if (node == null) {
      node = _EventNode(t, null, this, onCancel: _cancelStreamInNode);
      _nodes[t] = node;
    }
    return node.stream.map((event) => event.data);
  }

  @override
  Stream<EventDTO> listenAll(List<Topic> topics) {
    List<Stream<EventDTO>> s = [];
    _EventNode? tmp;
    for (var element in topics) {
      tmp = _nodes[element.topic];
      if (tmp != null) {
        s.add(tmp.stream);
      }
    }
    return StreamGroup.mergeBroadcast<EventDTO>(s);
  }

  @override
  Stream<EventDTO<T>>? listenEvent<T>({EventDTO<T>? event, Topic? topic}) {
    assert(event != null || topic != null);
    var t = event?.topic ?? topic;
    var n = _nodes[t!.topic];
    if (n != null) {
      return n.stream as Stream<EventDTO<T>>;
    }
    return null;
  }

  @override
  EventDTO<T>? repeat<T>({String? path, String? target, Duration? duration}) {
    var t = Topic.create<T>(path: path, target: target);
    var n = _nodes[t];
    if (n != null && n.lastEvent != null) {
      if (duration != null) {
        Future.delayed(duration).then((value) => n.repeatLast());
      } else {
        n.repeatLast();
      }
      return n.lastEvent as EventDTO<T>;
    }
    return null;
  }

  @override
  List<bool?> repeatAll({List<Topic>? events}) {
    List<bool?> r = [];
    if (events != null) {
      for (var e in events) {
        r.add(_nodes[e]?.repeatLast());
      }
    } else {
      for (MapEntry<Topic, _EventNode<dynamic>> e in _nodes.entries) {
        r.add(e.value.repeatLast());
      }
    }
    return r;
  }

  bool _send(EventDTO event, {bool noSendToStream = false}) {
    var node = _nodes[event.topic];
    if (node != null) {
      if (node.hasListener || node.hasHandler) {
        if (!noSendToStream) {
          _sendStreamController.add(event);
        }

        var ret = node.execute(event);
        //CHAIN CALL
        ret.then((value) {
          if (value is ChainEventDTO) {
            _send(value);
          }
          if (value is List<ChainEventDTO>) {
            value.forEach(
              (element) {
                _send(element);
              },
            );
          }
        });
        return true;
      }
    }
    return false;
  }

  @override
  EventDTO<T>? send<T>(T data, {String? path, String? fragment, String? target, Map<String, String>? arguments}) {
    var e = EventDTO.create(data, target: target, fragment: fragment, arguments: arguments, path: path);
    if (_send(e)) {
      return e;
    }

    return null;
  }

  @override
  List<EventDTO?> sendAll({Map<Topic, dynamic>? eventsMap, List<EventDTO>? events}) {
    assert(events != null || eventsMap != null);
    List<EventDTO?> r = [];
    if (events != null) {
      for (var e in events) {
        if (_send(e)) {
          r.add(e);
        }
      }
    }
    if (eventsMap != null) {
      for (var e in eventsMap.entries) {
        var ev = EventDTO(e.key, e.value);
        if (_send(ev)) {
          r.add(ev);
        }
      }
    }
    return r;
  }

  @override
  EventDTO<T>? sendEvent<T>({
    EventDTO<T>? event,
    Topic? topic,
    T? data,
  }) {
    assert(event != null || (topic != null));
    if (event != null) {
      if (_send(event)) {
        return event;
      }
    } else {
      var ev = EventDTO(topic!, data);
      if (_send(ev)) {
        return ev;
      }
    }
    return null;
  }

  @override
  List<Topic> getAllTopic() {
    return _nodes.keys.toList();
  }

  ///Очищает узлы события если в них нет слушателей и обработчиков
  void clearNotUseListeners() {
    List<Topic> toDel = [];

    for (var e in _nodes.entries) {
      if (!e.value.hasListener && !e.value.hasHandler) {
        toDel.add(e.key);
      }
    }
    for (var e in toDel) {
      _cancelStreamInNode(e);
    }
  }
}

class EventModelBusController extends EventBusController {
  EventModelBusController({required super.name, super.addToMaster});

  @override
  bool _send(EventDTO event, {bool noSendToStream = false}) {
    if (!_nodes.containsKey(event.topic)) {
      _nodes[event.topic] = _EventNode(event.topic, null, this, onCancel: _cancelStreamInNode);
    }
    return super._send(event, noSendToStream: noSendToStream);
  }

  @override
  void _cancelStreamInNode(Topic topic) {
    // TODO: implement _cancelStreamInNode
    // super._cancelStreamInNode(topic);
  }

  @override
  void clearNotUseListeners() {
    // TODO: implement clearNotUseListeners
    // super.clearNotUseListeners();
  }
}
