# 04. FSM — a state machine on top of the bus

[← 03. Isolates and Layers](03-isolate-and-layers.md) · [Contents](README.md) · [Next: Scope and Command →](05-scope-and-command.md)

`FSM<T>` is a mixin that turns the bus's event stream into transitions between states. The state
machine does not require anyone to subscribe to an event: it listens to `allEventStream` and reacts
to events **by topic**, that is, by event type, `target` and `path`.

## Setup

```dart
enum State { idle, loading, ready, failed }

class Loader with FSM<State> {
  final EventBus bus;

  Loader(this.bus) {
    initFSM(bus, State.idle);                        // initial state

    addFSMTransition<Start>(State.idle, State.loading,
      filter: (current, last, event) => event.url.isNotEmpty,
      handler: (current, last, event, ignored) async {
        print('$last -> $current on $event');
        await _load(event.url);
        return null;
      });

    addFSMTransition<Done>(State.loading, State.ready);
    addFSMTransition<Fail>(State.loading, State.failed);
  }
}
```

```dart
final bus = EventBus();
final loader = Loader(bus);

await bus.send(Start('/api/items'));   // idle -> loading, handler was called
await bus.send(Done());                // loading -> ready
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
    FSMHandler<T, E>? handler,
    FSMFilter<T, E>? filter,
    String? eventTarget,
    String? eventPath,
    String? eventFragment,
    Map<String, String>? arguments,
  });

  void changeState(T newState);         // change the state manually
  void changeStateByEvent(T newState);  // an alias for changeState
}

typedef FSMFilter<T, E> = bool Function(T currentState, T lastState, E event);

typedef FSMHandler<T, E> =
    Future<Object?> Function(T currentState, T lastState, E event, List<EventDTO> ignoredEvents);
```

## How it works

1. `initFSM(bus, state)` remembers the bus and subscribes to `bus.allEventStream`.
2. For every event, the state machine takes `dto.topic` and looks for a registered transition for
   the pair **(event topic, current state)**.
3. If a transition is found, `filter` is called (if it exists). `false` — the transition is rejected
   and the state does not change.
4. If the filter lets it through: the state changes to `toState`, and `handler` is called with
   `(currentState, lastState, event, ignoredEvents)`, where `currentState` is the **new** state and
   `lastState` is the previous one (the order is confirmed by the package example: it prints
   `state0 -> state1`).
5. While the handler is running, all incoming events are collected into the `ignoredEvents` list and
   passed to the handler. **They are not replayed after the handler finishes** — the events are lost
   and the list is cleared.

```text
   event E arrived
        │
        ├─ no transition for (topic of E, current state) → ignore
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

* **A transition is registered by the static event type.** `addFSMTransition<int>(...)` fires on
  `bus.send<int>(...)` but not on `bus.send<num>(...)`: for the bus these are different topics.
* **`eventPath` / `eventTarget` must match what was sent.** The transition topic is built as
  `Topic.create<E>(target: eventTarget, path: eventPath, ...)`, and `fragment`/`arguments` do not
  participate in the topic — you can pass transition parameters through them without breaking
  routing.
* **One transition per (event, state) pair.** Calling `addFSMTransition` again with the same
  `E`/`fromState` overwrites the previous one — the old handler/transition pair stops working
  (verified).
* **The state machine sees every event on the bus**, including the ones delivered to nobody.
  `allEventStream` carries a delivery flag, but FSM ignores it.
* **The state lives only in the mixin's memory.** It is not published to the bus automatically: if
  other components need to know the state, send an event from the transition handler manually.
* **`changeStateByEvent` is a full alias for `changeState`** (identical bodies). There is no
  separate "state change event".
* **`FSM` has no `dispose`**: the `allEventStream` subscription lives until the bus is disposed, so
  the state machine keeps the bus (and `EventBusLogger`/FSM subscriptions) alive.
* `initFSM` is required: without it, `state`/`lastState` throw a `LateInitializationError`.
* A transition handler may return a value, but it is **not sent anywhere** — the `FSMHandler` result
  is ignored.

## Desync example (events during a transition)

```dart
addFSMTransition<int>(S.a, S.b, handler: (current, last, event, ignored) async {
  await Future.delayed(const Duration(milliseconds: 50));   // "long" work
  print(ignored.map((d) => d.data));                        // what arrived during this time
  return null;
});

bus.send<int>(1);
bus.send<int>(2);   // arrives in the first transition's ignoredEvents
bus.send<int>(3);   // there too
```

If you need to process such events instead of losing them, collect them into your own queue inside
the handler and process them manually, or send them again after the transition finishes.

## What's next

* [05-scope-and-command.md](05-scope-and-command.md) — state with history and the command pattern.
