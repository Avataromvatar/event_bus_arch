# 04. FSM — a state machine on top of the bus

[← 03. Isolates and Layers](03-isolate-and-layers.md) · [Contents](README.md) · [Next: Scope and Command →](05-scope-and-command.md)

> `FSM` is part of the separate `event_bus_arch_patterns` package. Add it to your dependencies and
> import `package:event_bus_arch_patterns/event_bus_arch_patterns.dart`; the core package does not
> export it.

`FSM<T>` is a mixin that turns the bus's event stream into transitions between states. The state
machine does not require anyone to subscribe to an event: it listens to `allEventStream` and reacts
to events by their **selector** — an exact `EventKey<E>` or an `EventPatternKey<E>`. Both `fire` and
`request` produce entries there, so either call can drive a transition.

## Setup

```dart
enum State { idle, loading, ready, failed }

class Loader with FSM<State> {
  final EventBus bus;

  Loader(this.bus) {
    initFSM(bus, State.idle);                        // initial state

    addFSMTransition<Start>(State.idle, State.loading,
      selector: EventKey<Start>('api.items'),
      filter: (current, last, event) => event.url.isNotEmpty,
      handler: (current, last, event, ignored) async {
        print('$last -> $current on $event');
        await _load(event.url);
        return null;
      });

    addFSMTransition<Done>(State.loading, State.ready,
      selector: EventKey<Done>('api.done'));
    addFSMTransition<Fail>(State.loading, State.failed,
      selector: EventPatternKey<Fail>('api.*'));
  }
}
```

```dart
final bus = EventBus();
final loader = Loader(bus);

bus.fire(EventKey<Start>('api.items'), Start('/api/items')); // idle -> loading
bus.fire(EventKey<Done>('api.done'), Done());                // loading -> ready
```

## API

```dart
mixin class FSM<T> {
  T get state;        // current state
  T get lastState;    // the state we came from

  void initFSM(EventBus bus, T currentState, {T? lastState});

  void addFSMTransition<E>(
    T fromState,
    T toState, {
    required EventSelector<E> selector,
    FSMHandler<T, E>? handler,
    FSMFilter<T, E>? filter,
  });

  void changeState(T newState);         // change the state manually
  void changeStateByEvent(T newState);  // deprecated alias for changeState

  void dispose();                       // unsubscribe from the bus
}

typedef FSMFilter<T, E> = bool Function(T currentState, T lastState, E event);

typedef FSMHandler<T, E> =
    Future<Object?> Function(T currentState, T lastState, E event, List<EventDTO> ignoredEvents);
```

## How it works

1. `initFSM(bus, state)` remembers the bus and subscribes to `bus.allEventStream`.
2. For every event, the state machine matches the event key against the registered transition
   selectors for the current state. An exact selector beats a pattern; among patterns the most
   specific wins. The payload must also be an `E` (`data is E`).
3. If a transition is found, `filter` is called (if it exists). `false` — the transition is rejected
   and the state does not change.
4. If the filter lets it through: the state changes to `toState`, and `handler` is called with
   `(currentState, lastState, event, ignoredEvents)`, where `currentState` is the **new** state and
   `lastState` is the previous one.
5. While the handler is running, all incoming events are collected into the `ignoredEvents` list and
   passed to the handler. **They are not replayed after the handler finishes** — the events are lost
   and the list is cleared. A handler error resets the transition-in-progress flag in a `finally`
   block, so the machine never gets stuck.

```text
   event E arrived
        │
        ├─ no transition for (key of E, current state) → ignore
        │
        ├─ filter returned false → ignore
        │
        └─ transition: state = toState
                     │
                     ├─ handler(...) runs
                     │     └─ events arriving meanwhile → ignoredEvents
                     │
                     └─ ignoredEvents.clear()
```

## Important details

* **A transition is registered by a selector.** The payload must be an `E` at delivery time:
  `addFSMTransition<int>` accepts an event delivered to `EventKey<int>('x')`; a
  `EventKey<num>('x')` carrying an `int` also matches because `int is num`. A differently typed
  node (`EventKey<String>('x')`) does not.
* **`selector` is required and exact by default.** Use `EventKey<E>` for one address and
  `EventPatternKey<E>` for a family. `arguments` do not participate in matching — pass transition
  parameters through them without breaking routing.
* **One transition per (selector, fromState) pair.** Calling `addFSMTransition` again with the same
  `E`/`selector`/`fromState` replaces the previous one.
* **The state machine sees every event on the bus**, including the ones delivered to nobody and
  requests that end with `NoHandlerException`. `allEventStream` carries a delivery flag, but FSM
  ignores it.
* **The state lives only in the mixin's memory.** It is not published to the bus automatically: if
  other components need to know the state, send an event from the transition handler manually.
* **`changeStateByEvent` is a deprecated alias for `changeState`.** There is no separate "state
  change event".
* **`FSM.dispose()` unsubscribes the machine from the bus.** Until it is called, the
  `allEventStream` subscription lives on and keeps the bus alive; a repeated `initFSM` does not add
  a second subscription.
* `initFSM` is required: without it, `state`/`lastState` throw a `LateInitializationError`.
* A transition handler may return a value, but it is **not sent anywhere** — the `FSMHandler` result
  is ignored.

## Desync example (events during a transition)

```dart
final pulse = EventKey<int>('pulse');

addFSMTransition<int>(S.a, S.b,
  selector: pulse,
  handler: (current, last, event, ignored) async {
    await Future.delayed(const Duration(milliseconds: 50));   // "long" work
    print(ignored.map((d) => d.data));                        // what arrived during this time
    return null;
  });

bus.fire(pulse, 1);
bus.fire(pulse, 2);   // arrives in the first transition's ignoredEvents
bus.fire(pulse, 3);   // there too
```

If you need to process such events instead of losing them, collect them into your own queue inside
the handler and process them manually, or send them again after the transition finishes.

## What's next

* [05-scope-and-command.md](05-scope-and-command.md) — state with history and the command pattern.
