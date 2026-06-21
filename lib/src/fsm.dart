part of event_arch;


typedef FSMHandler<T, E> =
    Future<Object?> Function(T currentState, T lastState, E event,List<EventDTO> ignoredEvents);

typedef FSMFilter<T, E> =
    bool Function(T currentState, T lastState, E event);

class _FSM<T> {
  EventBus bus = EventBus(isModelBus: false);
  EventBusHandlers get busHandlers => bus as EventBusHandlers;
  Map<Topic, Map<T, _FSMNode>> _map = {};
}

class _FSMNode<T, E> {
  final T fromState;
  final T toState;
  final FSMHandler<T, E>? handler;
  final FSMFilter<T, E>? filter;
  _FSMNode({required this.fromState, required this.toState, this.handler,this.filter});
  Future<void> call(T currentState, T lastState, E event,List<EventDTO> ignoredEvents) async {
    await handler?.call(currentState, lastState, event,ignoredEvents);
  }
  bool check(T currentState, T lastState, E event,)
  {
    return (filter?.call(currentState, lastState, event))??true;
  }
}

mixin class FSM<T> {
  final _FSM _fsm = _FSM();
  late T _state;
  late T _lastState;
  T get state => _state;
  T get lastState => _lastState;
  final List<EventDTO> __ignoredDTO = [];

  void initFSM(EventBus bus, T currentState, {T? lastState}) {
    _fsm.bus = bus;
    _state = currentState;
    _lastState = lastState ?? currentState;
    bool changeStateStart = false;
    
    bus.allEventStream.listen((e) async {
      if (!changeStateStart) {
        var topic = e.$1.topic;//Topic.fromParametr(type: e.$1.data.runtimeType);
        var eventChannel = _fsm._map[topic];
        if (eventChannel != null) {
          var node = eventChannel[_state];
          if (node != null && node.check(_state, _lastState, e.$1.data)) {
            changeStateStart = true;
            changeState(node.toState);
            await node.call(_state, _lastState, e.$1.data,__ignoredDTO);
            __ignoredDTO.clear();
            changeStateStart = false;
          }
        }
      } else 
      {
        __ignoredDTO.add(e.$1);
      }
    });
  }
  // Future<void> _listenFSMEvent<E>()

  void addFSMTransition<E>(
    T fromState,
    T toState, {
    FSMHandler<T, E>? handler,
    FSMFilter<T, E>? filter,
    String? eventTarget,
    String? eventPath,
    String? eventFragment,
    Map<String, String>? arguments,
  }) {
    var topic = Topic.create<E>(arguments: arguments,fragment: eventFragment,path: eventPath,target: eventTarget);
    var eventChannel = _fsm._map[topic];
    if (eventChannel != null) {
      eventChannel[fromState] = _FSMNode<T, E>(
        fromState: fromState,
        toState: toState,
        handler: handler,
        filter: filter
      );
    } else {
      _fsm._map[topic] = {
        fromState: _FSMNode<T, E>(
          fromState: fromState,
          toState: toState,
          handler: handler,
          filter: filter
        ),
      };
    }
  }

  void changeState(T newState) {
    _lastState = state;
    _state = newState;
  }
  void changeStateByEvent(T newState) {
    _lastState = state;
    _state = newState;
  }
}
