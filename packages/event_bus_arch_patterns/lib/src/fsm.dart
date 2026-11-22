import 'dart:async';

import 'package:event_bus_arch/event_bus_arch.dart';

typedef FSMHandler<T, E> = Future<Object?> Function(
    T currentState, T lastState, E event, List<EventDTO> ignoredEvents);

typedef FSMFilter<T, E> = bool Function(T currentState, T lastState, E event);

class _FSM<T> {
  final List<_FSMTransition<T>> transitions = <_FSMTransition<T>>[];
}

class _FSMTransition<T> {
  _FSMTransition({
    required this.fromState,
    required this.toState,
    required this.selector,
    required this.accepts,
    required this.order,
    this.handler,
    this.filter,
  });

  final T fromState;
  final T toState;

  ///The exact or pattern key this transition listens on.
  final EventSelector selector;

  ///Whether the event data has the transition's local type.
  final bool Function(Object? data) accepts;

  final int order;

  ///Type-erased handler; the wrapper casts to the registered `E`.
  final Future<Object?> Function(
      T current, T last, Object? event, List<EventDTO> ignored)? handler;

  ///Type-erased filter; the wrapper casts to the registered `E`.
  final bool Function(T current, T last, Object? event)? filter;

  bool matches(EventKey key) {
    final selector = this.selector;
    if (selector is EventPatternKey) {
      return selector.pattern.matches(key.address);
    }
    return (selector as EventKey).address == key.address;
  }

  bool check(T current, T last, Object? event) =>
      filter?.call(current, last, event) ?? true;

  Future<void> call(
      T current, T last, Object? event, List<EventDTO> ignored) async {
    await handler?.call(current, last, event, ignored);
  }
}

///A finite state machine driven by bus events.
///
///A transition is registered for an exact [EventKey] or an [EventPatternKey].
///The event's address selects a transition; the event data must match the
///transition's local type (`data is E`), which gives subtype transitions for
///free. While a handler runs, events are collected into `ignoredEvents` and are
///not replayed afterwards.
mixin class FSM<T> {
  final _FSM<T> _fsm = _FSM<T>();
  late T _state;
  late T _lastState;
  StreamSubscription<(EventDTO, bool)>? _fsmSubscription;
  T get state => _state;
  T get lastState => _lastState;
  final List<EventDTO> _ignoredDTO = [];
  int _nextOrder = 0;

  void initFSM(EventBus bus, T currentState, {T? lastState}) {
    // a repeated initFSM must not leave a second live subscription
    _fsmSubscription?.cancel();
    _fsmSubscription = null;
    _state = currentState;
    _lastState = lastState ?? currentState;
    bool changeStateStart = false;

    _fsmSubscription = bus.allEventStream.listen((e) async {
      if (changeStateStart) {
        _ignoredDTO.add(e.$1);
        return;
      }
      final dto = e.$1;
      final transition = _match(dto);
      if (transition == null) return;
      changeStateStart = true;
      changeState(transition.toState);
      try {
        await transition.call(_state, _lastState, dto.data, _ignoredDTO);
      } finally {
        // A handler that throws must not leave the machine stuck: the
        // transition is committed, ignored events are consumed, and the next
        // event can drive the next transition.
        _ignoredDTO.clear();
        changeStateStart = false;
      }
    });
  }

  _FSMTransition<T>? _match(EventDTO dto) {
    final candidates = _fsm.transitions
        .where((transition) =>
            transition.fromState == _state &&
            transition.matches(dto.key) &&
            transition.accepts(dto.data) &&
            transition.check(_state, _lastState, dto.data))
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    final sorted = List<_FSMTransition<T>>.of(candidates);
    sorted.sort((a, b) {
      final aExact = a.selector is EventKey;
      final bExact = b.selector is EventKey;
      if (aExact != bExact) return aExact ? -1 : 1;
      if (!aExact && !bExact) {
        final aPattern = (a.selector as EventPatternKey).pattern;
        final bPattern = (b.selector as EventPatternKey).pattern;
        final bySpecificity =
            bPattern.specificity.compareTo(aPattern.specificity);
        if (bySpecificity != 0) return bySpecificity;
      }
      return a.order.compareTo(b.order);
    });
    return sorted.first;
  }

  ///Unsubscribes from the bus: the state machine stops reacting to events.
  ///A repeated [initFSM] turns it on again.
  void dispose() {
    _fsmSubscription?.cancel();
    _fsmSubscription = null;
  }

  ///Registers a transition from [fromState] to [toState] for [selector].
  ///
  ///Re-registering the same selector and [fromState] replaces the previous
  ///transition, so the last registration wins for that pair.
  void addFSMTransition<E>(
    T fromState,
    T toState, {
    required EventSelector<E> selector,
    FSMHandler<T, E>? handler,
    FSMFilter<T, E>? filter,
  }) {
    _fsm.transitions.removeWhere((transition) =>
        transition.fromState == fromState && transition.selector == selector);
    _fsm.transitions.add(_FSMTransition<T>(
      fromState: fromState,
      toState: toState,
      selector: selector,
      accepts: (data) => data is E,
      order: _nextOrder++,
      handler: handler == null
          ? null
          : (current, last, event, ignored) =>
              handler(current, last, event as E, ignored),
      filter: filter == null
          ? null
          : (current, last, event) => filter(current, last, event as E),
    ));
  }

  void changeState(T newState) {
    _lastState = state;
    _state = newState;
  }

  @Deprecated('Use changeState')
  void changeStateByEvent(T newState) => changeState(newState);
}
