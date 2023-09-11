part of event_arch;

// typedef EventHandler<T> = Future<dynamic> Function(Topic topic, {T? data, T? oldData});
///
typedef EventHandler<T> = Stream Function(EventDTO<T>, {dynamic env, T? oldData});

enum eEventBusConnection { sourceToTarget, targetToSource, bidirectional, none }

typedef OnConnectionEventHandler = EventDTO? Function(eEventBusConnection dir, EventDTO event);

abstract class EventBusConnector {
  // eEventBusConnection get callConnectedType;
  eEventBusConnection get sendConnectedType;
  EventBusStream get source;
  EventBusStream get target;

  ///returned event sended to bus. If return null event dont send to bus
  OnConnectionEventHandler? onEvent;
  // OnConnectionEventHandler? onCall;
  void dispose();
  factory EventBusConnector({
    required EventBusStream source,
    required EventBusStream target,
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
  final EventBusStream source;
  @override
  final EventBusStream target;
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
  // final StreamController<EventDTO> _sendSource = StreamController.broadcast();
  // final StreamController<EventDTO> _sendTarget = StreamController.broadcast();
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
      _streamSubscriptionSource = source.stream.listen((event) {
        if (onEvent != null) {
          var e = onEvent!.call(eEventBusConnection.sourceToTarget, event);
          if (e is EventDTO) {
            target.sink.add(e);
          }
        } else {
          target.sink.add(event);
        }
      });
    }
    if (sendConnectedType == eEventBusConnection.bidirectional ||
        sendConnectedType == eEventBusConnection.targetToSource) {
      _streamSubscriptionTarget = target.stream.listen((event) {
        if (onEvent != null) {
          var e = onEvent!.call(eEventBusConnection.targetToSource, event);
          if (e is EventDTO) {
            source.sink.add(e);
          }
        } else {
          source.sink.add(event);
        }
      });
    }
  }

  @override
  void dispose() {
    _streamSubscriptionSource?.cancel();
    _streamSubscriptionTarget?.cancel();
  }
}

abstract class Event<T> {
  Stream<T> get stream;
  Topic get topic;
  bool sendEvent({T? data});
}

abstract class EventNode<T> implements Event<T> {
  @override
  Topic get topic;
  EventBus get bus;
  bool get isDispose;
  bool get hasListener;
  bool get hasHandler;
  EventDTO<T>? get lastEvent;
  T? get lastData;
  dynamic get environment;
  Stream<EventDTO<T>> get streamEvent;
  // Sink<EventDTO<T>> get sink;
  //
  Function(EventNode node)? onCancel;
  //return true if have listener or handler

  bool send({EventDTO<T>? event, T? data});

  /// throw exception if no have Handler. return last R from EventHandler or null if R not return from EventHandler
  Future<R?> call<R>({EventDTO<T>? event, T? data});
  Future<void> dispose();
  void repeat();

  factory EventNode(
      {required EventBus bus,
      required Topic topic,
      dynamic environment,
      EventHandler<T>? handler,
      Function(EventNode node)? onCancel,
      EventDTO<T>? initalEvent}) {
    return EventNodeImpl(
        bus: bus,
        topic: topic,
        environment: environment,
        handler: handler,
        onCancel: onCancel,
        initalEvent: initalEvent);
  }
}

class EventNodeImpl<T> implements EventNode<T> {
  //-----public
  @override
  final Topic topic;
  @override
  final dynamic environment;
  @override
  final EventBus bus;
  @override
  T? get lastData => _lastEvent?.data;
  @override
  Function(EventNode node)? onCancel;
  @override
  EventDTO<T>? get lastEvent => _lastEvent;
  @override
  bool get hasHandler => _handler != null;

  @override
  bool get hasListener => _streamController.hasListener;

  @override
  bool get isDispose => _isDispose;
  Stream<T> get stream => streamEvent.where((event) => event.data != null).map((event) => event.data!);
  @override
  Stream<EventDTO<T>> get streamEvent => _streamController.stream;
  // @override
  // Sink<EventDTO<T>> get sink => _streamController.sink;
  //-----private
  bool _isDispose = false;
  EventDTO<T>? _lastEvent;

  late final StreamController<EventDTO<T>> _streamController;
  EventHandler<T>? _handler;
//------ construct
  EventNodeImpl(
      {required this.bus,
      required this.topic,
      EventHandler<T>? handler,
      this.environment,
      this.onCancel,
      EventDTO<T>? initalEvent}) {
    _handler = handler;
    if (initalEvent != null) {
      _lastEvent = initalEvent;
    }
    _streamController = StreamController<EventDTO<T>>.broadcast();
    _streamController.onCancel = _onCancel;
    _streamController.onListen = _onListen;
  }
//------ methods
  void _onCancel() {
    // if (!hasHandler) {
    onCancel?.call(this);
    // }
  }

  void _onListen() {
    // if(_lastEvent!=null)
    // {

    // }
  }
  @override

  ///this is from Event and sended to bus
  bool sendEvent({T? data}) {
    return bus.send(topic: topic, data: data);
  }

  @override
  Future<R?> call<R>({EventDTO<T>? event, T? data}) async {
    if (_isDispose) {
      throw EventBusException('Topic:$topic is dispose');
    }
    if (!hasHandler) {
      throw EventBusException('Topic:$topic cant be called because not have handler');
    }
    R? ret;
    var e = event ?? EventDTO(data: data, topic: topic);
    ret = await _execute(e, isCall: true);
    _lastEvent = event;
    return ret;
  }

  @override
  bool send({EventDTO<T>? event, T? data}) {
    if (_isDispose) {
      throw EventBusException('Topic:$topic is dispose');
    }
    if (!hasHandler && !hasListener) {
      return false;
    }

    var e = event ?? EventDTO(data: data, topic: topic);
    _execute(e);

    _lastEvent = event;
    return true;
  }

  Future<R?> _execute<R>(EventDTO<T> event, {bool isCall = false}) async {
    R? ret;
    if (hasHandler) {
      if (!isCall) {
        //send
        _handler!.call(event, env: environment, oldData: lastData).forEach((e) {
          if (e is EventDTO) {
            bus.send(event: e);
          }
        });
      } else {
        //call
        await _handler!.call(event, env: environment, oldData: lastData).forEach((e) {
          if (e is EventDTO) {
            bus.send(event: e);
          }
          if (e is R) {
            ret = e;
          }
        });
      }
    }
    if (hasListener) {
      _streamController.add(event);
    }
    return ret;
  }

  @override
  void repeat() {
    if (lastEvent != null) _execute(lastEvent!);
  }

  @override
  Future<void> dispose() async {
    if (!_isDispose) {
      _isDispose = true;
      // onCancel?.call(this);
      await _streamController.close();
    }
  }
}

abstract class EventBusHandler {
  ///if the event node is already present, then its handler will be redefined, and the hideFromBroadcastingEvent flag will also be applied again
  ///
  ///if hideFromBroadcastingEvent set common node(target == all) not create
  Future<Event<T>> addHandler<T>(
      {dynamic env,
      EventHandler<T>? handler,
      String? path,
      EventDTO<T>? initalEvent,
      bool hideFromBroadcastingEvent = false});
  //remove common(target == all) and target node
  Future<bool> removeHandler<T>({
    String? path,
  });
  static Stream<dynamic> emptyHandler<T, E>(EventDTO<T> event, {E? env, T? oldData}) async* {}
}

abstract class EventBusStream {
  ///add event to bus
  Sink<EventDTO> get sink;

  ///all no repeat event
  Stream<EventDTO> get stream;
}

abstract class EventBus implements EventBusStream, EventBusHandler {
  /// name use for Topic target
  /// if Topic.target == 'all' this broadcast event
  /// if use bus added to Master name must be unique
  String get name;

  ///the bus model saves all the topic data that is sent to it and does not delete them if there are no listeners
  ///
  bool get isModelBus;

  ///check if there is a listener on the bus
  bool contain(Topic topic);

  ///choose one from: event or [topic and data?] or [data?,target?,fragment?,target?,arguments? ]
  Event<T>? getEvent<T>(
      {Topic? topic,
      T? data,
      String? path,
      String? fragment,
      String? target,
      Map<String, String>? arguments,
      EventDTO<T>? event});

  ///choose one from: event or [topic and data?] or [data?,target?,fragment?,target?,arguments? ]
  ///if data ==null and EventNode not have lastData return false.
  ///if data ==null and EventNode have lastData return true and send lastData to listeners and handlers
  ///return false if node not have listeners and handler
  bool send<T>(
      {Topic? topic,
      T? data,
      String? path,
      String? fragment,
      String? target,
      Map<String, String>? arguments,
      EventDTO<T>? event});

  ///choose one from: event or [topic and data?] or [data?,target?,fragment?,target?,arguments? ]
  ///if data ==null and EventNode not have lastData return false.
  ///if data ==null and EventNode have lastData return true and send lastData to listeners and handlers
  ///
  ///Call method wait complete work handler and get last R from handler stream
  Future<R?> call<T, R>(
      {Topic? topic,
      T? data,
      String? path,
      String? fragment,
      String? target,
      Map<String, String>? arguments,
      EventDTO<T>? event});

  ///choose one from: topic or [path? and target?]
  T? lastData<T>({
    Topic? topic,
    String? path,
    String? target,
  });

  ///choose one from: topic or [path? and target?]
  EventDTO<T>? lastEvent<T>({
    Topic? topic,
    String? path,
    String? target,
  });

  ///choose one from: topic or [path? and target?]
  Stream<T> getStreamData<T>({
    String? path,
    String? target,
    Topic? topic,
  });

  ///choose one from: topic or [path? and target?]
  Stream<EventDTO<T>> getStreamEvent<T>({
    String? path,
    String? target,
    Topic? topic,
  });
  Stream getGroupStream(List<Stream> eventsStream);
  // EventNode getEventNode<T>({
  //   String? path,
  //   String? target,
  // });
  factory EventBus({required String name, bool isModelBus = false, bool addToMaster = true}) {
    return EventBusImpl(name: name, isModelBus: isModelBus, addToMaster: addToMaster);
  }
}

class EventBusImpl implements EventBus {
  Map<Topic, EventNode> _map = {};
  @override
  final bool isModelBus;

  @override
  final String name;
  EventBusImpl({required this.name, this.isModelBus = false, bool addToMaster = true}) {
    if (addToMaster) {
      EventBusMaster.instance.add(this);
    }
    _sinkController.stream.listen((event) {
      send(event: event, fromSink: true);
    });
  }
  //----- EventBusStream
  final StreamController<EventDTO> _sinkController = StreamController<EventDTO>.broadcast();
  final StreamController<EventDTO> _streamController = StreamController<EventDTO>.broadcast();
  @override
  Sink<EventDTO> get sink => _sinkController.sink;

  @override
  Stream<EventDTO> get stream => _streamController.stream;

  //----- EventBusHandler
  void _onCancelNode(EventNode node) async {
    if (!isModelBus) {
      if (!node.hasHandler) {
        // await node.dispose();

        //TODO: check delete
        removeHandler(topic: node.topic);
      }
    }
  }

  EventNode<T>? _getNode<T>(Topic topic) {
    if (topic.target == _targetDefault) {
      var node = _map[topic] ?? _map[topic.copy(target: name)];

      return node != null ? node as EventNode<T> : null;
    } else {
      var node = _map[topic];
      return node != null ? node as EventNode<T> : null;
    }
  }

  EventNode<T> _createNode<T>(
    Topic topic, {
    bool hideFromBroadcastingEvent = false,
  }) {
    var node = EventNode<T>(bus: this, topic: topic, onCancel: _onCancelNode);
    if (topic.target != _targetDefault) {}
    _map[topic] = node;
    if (!hideFromBroadcastingEvent) {
      var topicCom = topic.copy(target: _targetDefault);
      _map[topicCom] = node;
    }
    return node;
  }

  @override
  Future<EventNode<T>> addHandler<T>(
      {dynamic env,
      EventHandler<T>? handler,
      String? path,
      EventDTO<T>? initalEvent,
      bool hideFromBroadcastingEvent = false,
      Topic? topic}) async {
    var t = topic ?? Topic.create<T>(path: path, target: name);
    var topicCom = t.copy(target: _targetDefault);
    EventNode<T>? node;
    if (_map.containsKey(t)) {
      node = _map[t]! as EventNode<T>;
      (node as EventNodeImpl<T>)._handler = handler;
    }
    if (_map.containsKey(topicCom)) {
      if (!hideFromBroadcastingEvent) {
        node = _map[topicCom]! as EventNode<T>;
        (node as EventNodeImpl<T>)._handler = handler;
      } else {
        await _map[topicCom]!.dispose();
        _map.remove(topicCom);
      }
    }
    if (node == null) {
      node = EventNode<T>(
          bus: this,
          topic: hideFromBroadcastingEvent ? t : topicCom,
          handler: handler,
          environment: env,
          initalEvent: initalEvent,
          onCancel: _onCancelNode);
      _map[t] = node;
      if (!hideFromBroadcastingEvent) {
        _map[topicCom] = node;
      }
    }
    return node;
  }

  @override
  Future<bool> removeHandler<T>({String? path, Topic? topic}) async {
    var t = topic ?? Topic.create<T>(path: path, target: name);
    bool isDel = false;
    var topicCom = t.copy(target: _targetDefault);
    if (_map.containsKey(topic)) {
      await _map[t]!.dispose();
      _map.remove(t);
      isDel = true;
    }
    if (_map.containsKey(topicCom)) {
      await _map[topicCom]!.dispose();
      _map.remove(t);
      isDel = true;
    }
    return isDel;
  }

  //----- EventBus
  @override
  T? lastData<T>({
    Topic? topic,
    String? path,
    String? target,
  }) {
    var t = topic ?? Topic.create<T>(path: path, target: name);
    return _map[t]?.lastData;
  }

  @override
  EventDTO<T>? lastEvent<T>({
    Topic? topic,
    String? path,
    String? target,
  }) {
    var t = topic ?? Topic.create<T>(path: path, target: name);
    return _map[t]?.lastData;
  }

  void _sendToStream(EventDTO event) {
    if (!event.checkTraversedPath(name)) {
      event.addTraversedPath(name);
      _streamController.add(event);
    } else {
      print('Event ${event.topic} sended to EventBus $name many time ${event.traversedPath}');
      // throw EventBusException('Event ${event.topic} sended to EventBus $name many time ${event._pathResend}');
    }
  }

  Event<T>? getEvent<T>(
      {Topic? topic,
      T? data,
      String? path,
      String? fragment,
      String? target,
      Map<String, String>? arguments,
      EventDTO<T>? event}) {
    Topic t = topic ??
        (event?.topic ?? Topic.create<T>(path: path, fragment: fragment, target: target, arguments: arguments));
    return _map[t]! as Event<T>;
  }

  @override
  bool send<T>(
      {Topic? topic,
      T? data,
      String? path,
      String? fragment,
      String? target,
      Map<String, String>? arguments,
      EventDTO<T>? event,
      bool fromSink = false}) {
    if (fromSink && (event?.checkTraversedPath(name) ?? false)) {
      return false;
    }
    Topic t = topic ??
        (event?.topic ?? Topic.create<T>(path: path, fragment: fragment, target: target, arguments: arguments));

    T? d = data ?? event?.data;
    var e = event ?? EventDTO(topic: t, data: d);
    EventNode<dynamic>? node;
    //block multisend event

    if (!fromSink) {
      e.clearTraversedPath();
    }

    node = _map[t];
    if (node == null && isModelBus) {
      node = _createNode(t);
    }
    _sendToStream(e);
    return node?.send(event: e) ?? false;
  }

  @override
  Future<R?> call<T, R>(
      {Topic? topic,
      T? data,
      String? path,
      String? fragment,
      String? target,
      Map<String, String>? arguments,
      EventDTO<T>? event}) {
    Topic t = topic ??
        (event?.topic ?? Topic.create<T>(path: path, fragment: fragment, target: target, arguments: arguments));

    T? d = data ?? event?.data;
    var e = EventDTO(topic: t, data: d);
    var node = _map[t];
    if (node == null && isModelBus) {
      throw EventBusException('EventBus $name not have node ${t.topic}');
    } else {
      return node!.call(event: e);
    }
  }

  @override
  bool contain(Topic topic) {
    return _map.containsKey(topic);
  }

  // @override
  // EventNode getEventNode<T>({String? path, String? target}) {
  //   // TODO: implement getEventNode
  //   throw UnimplementedError();
  // }

  @override
  Stream getGroupStream(List<Stream> eventsStream) {
    return StreamGroup.mergeBroadcast(eventsStream);
  }

  @override
  Stream<T> getStreamData<T>({String? path, String? target, Topic? topic}) {
    Topic t = topic ??
        (Topic.create<T>(
          path: path,
          target: target,
        ));
    var node = _map[t];
    if (node == null) {
      node = _createNode<T>(t);
    }
    return node.stream as Stream<T>;
  }

  @override
  Stream<EventDTO<T>> getStreamEvent<T>({String? path, String? target, Topic? topic}) {
    Topic t = topic ??
        (Topic.create<T>(
          path: path,
          target: target,
        ));
    var node = _map[t];
    if (node == null) {
      node = _createNode<T>(t);
    }
    return node.stream as Stream<EventDTO<T>>;
  }
}
