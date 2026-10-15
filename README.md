# EventBus Arch

`event_bus_arch` is an event-driven architecture toolkit for Dart and Flutter. Components talk to
each other through events addressed by a URI-like **topic**, so they stay decoupled and can be
moved between isolates without changing their logic.

On top of the bus the package ships a finite state machine, an isolate bridge, multi-isolate
"layers", and a scope/command wrapper for stateful values.

* Detailed documentation: **[doc/](doc/README.md)**
* Full API reference: [doc/06-api-reference.md](doc/06-api-reference.md)
* What changed in 2.3.0 and what to watch out for: [doc/07-caveats.md](doc/07-caveats.md)

## Features

- Send and receive events between components (`send` / `listen` / `subscribe`)
- Handlers that can return a result to the sender (`EventDTO.completer`)
- Two bus flavours: **common** (`EventBus()`) and **model** (`EventBus(isModelBus: true)`) —
  the model bus keeps the last value per topic even when nobody is listening
- Topic-based routing: event type + `target` + `path`, plus `fragment` and `arguments` as payload
- `EventBusIsolate` — the same API, but the events are processed in a worker isolate
- `Layers` — chains of isolates: `main ↔ isolate₂ ↔ isolate₁ ↔ isolate₀`
- `FSM` — finite state machine driven by bus events
- `Scope` / `Command` — stateful value with call history
- `EventBusLogger` — trace every event that crosses the bus
- Type-safe handlers, no code generation

## Installation

```yaml
dependencies:
  event_bus_arch: ^2.3.0
```

```bash
dart pub get      # or: flutter pub get
```

Dart SDK `>=3.0.0 <4.0.0`. The package re-exports `rxdart`, so `BehaviorSubject`,
`debounceTime`, `doOnCancel` and friends are available without an extra import.

## Quick start

```dart
import 'package:event_bus_arch/event_bus_arch.dart';

Future<void> main() async {
  final bus = EventBus();

  // Receive: every event of that topic, current and future
  final sub = bus.subscribe<String>(onData: (event) => print('got: $event'));

  // Handle: the handler may answer the sender through dto.completer.
  // lastData is the PREVIOUS value of this topic, dto.data is the current one.
  bus.handlers.setHandler<String>(handler: (dto, lastData) async {
    dto.completer?.complete('processed: ${dto.data}');
  });

  final result = await bus.send<String>('hello');
  print(result);                 // processed: hello

  // by now the listener has already received the value: send() is a sync point
  await sub.cancel();
  await bus.dispose();
}
```

### Topics

A topic is built from the **static type argument** of the call plus `target` and `path`:

```text
event://all.String/origin#frag?a=b
       └ target └ type  └ path  └ fragment, arguments
```

```dart
await bus.send<Order>(order, target: 'warehouse', path: '/in', arguments: {'priority': '1'});

bus.subscribe<Order>(target: 'warehouse', path: '/in', onData: (order) => print(order));
```

`target` and `path` select the topic; `fragment` and `arguments` are delivered to the handler but
do not affect routing. Because the type is part of the address, `send<int>` and a handler
registered with `setHandler<num>` are **different topics** — always be explicit with type
arguments.

### Model bus vs common bus

| | `EventBus()` | `EventBus(isModelBus: true)` |
|---|---|---|
| Creates a node when sending to an unknown topic | no | yes |
| Keeps `lastData` after the last listener unsubscribes | no | yes |
| `send` to a topic nobody handles | resolves with `null`, event goes to `allEventStream` with flag `false` | resolves with `null`, node is created |

Use the model bus when the bus is a store of current state, and the common bus when it is a
message pipe.

### Isolates

```dart
import 'dart:isolate';
import 'package:event_bus_arch/event_bus_arch.dart';

Future<void> main() async {
  final iso = EventBusIsolate(onInit: _worker, initialData: 'worker');
  await iso.waitInit;                                  // true when onInit has completed

  iso.subscribe<String>(onData: (e) => print('from worker: $e'));
  final doubled = await iso.send<int>(21, arguments: {'multiplier': '2'});
  print(doubled);                                      // 42

  await iso.dispose();
}

// runs inside the worker isolate — must be a top-level or static function
Future<void> _worker(EventBus bus, Object? initialData) async {
  await _heavyInit();                                  // async init is fine
  bus.handlers.setHandler<int>(handler: (dto, lastData) async {
    final m = int.tryParse(dto.topic.arguments?['multiplier'] ?? '1') ?? 1;
    dto.completer?.complete(dto.data * m);
  });
}
```

`EventBusIsolate` behaves like a normal bus on both sides: events sent from the worker reach
main-isolate listeners, and `send` from main returns the worker's handler result.

Good to know:

1. Only sendable objects can cross the isolate boundary.
2. `waitInit` completes when `onInit` has finished (including its `await`s), so events sent right
   after it are never lost. Errors from `onInit` surface as an `EventBusException` from
   `waitInit`.
3. Every request is answered exactly once and correlated by request id, so concurrent requests of
   the same type each get their own result. A topic the worker knows nothing about resolves to
   `null`; a handler error is rethrown at the sender; an in-flight request fails with
   `EventBusException` if the isolate is disposed.
4. `ping()` only checks liveness ("is the worker alive"), not readiness.

### Layers

```dart
final layer = await Layers.createLayers([
  (_initMiddle, null, true),   // (init function, initial data, isModelBus)
  (_initBottom, null, true),
]);
// main ↔ isolate[middle] ↔ isolate[bottom]

// createLayers completes only when every layer in the chain is initialized,
// so events can be sent right away
layer.bottom!.subscribe<Ping>(onData: (e) => print(e.count));
layer.bottom!.send(Ping(0));
await layer.close();
```

Inside a layer, `layer.top` sends to the layer above, `layer.bottom` to the layer below, and
`layer.current` is the layer's own bus. Init functions may be `async` and may live in any layer;
`Layer.close()` works from any layer and is safe to call twice. See
[doc/03-isolate-and-layers.md](doc/03-isolate-and-layers.md#example-two-worker-layers)
and [example/event_bus_layers_example.dart](example/event_bus_layers_example.dart).

### Finite state machine

```dart
enum State { idle, loading, ready }

class Loader with FSM<State> {
  Loader(EventBus bus) {
    initFSM(bus, State.idle);
    addFSMTransition<Start>(State.idle, State.loading,
      filter: (current, last, event) => event.url.isNotEmpty,
      handler: (current, last, event, ignored) async {
        print('$last -> $current ($event)');
        return null;
      });
  }
}

await bus.send(Start('/api/items'));   // State.idle -> State.loading
```

Events arriving while a transition handler is running are collected into the `ignoredEvents`
argument and are not replayed afterwards.

### Scope and Command

```dart
final scope = Scope<int>();
await scope.initScope(
  bus,
  path: '/counter',
  initialData: 0,
  maxLenForUndo: 10,                 // history depth; undo needs at least 2 entries
  onUpdate: (value) => print('value: $value'),
);

await scope.call(1);                 // goes through the bus
print(scope.lastData);               // 1  (filled by the bus subscription)
await scope.undo();                  // re-sends the PREVIOUS value from the history
scope.disposeScope();
```

`Command` keeps the call history (`maxLen`) and `undo()` sends the previous value back through the
bus. `undo()` returns `null` when there is nothing to roll back to.

## Documentation

Detailed guides live in [docs/](docs/README.md) (Russian):

| Document | Content |
|---|---|
| [01-architecture.md](doc/01-architecture.md) | Topics, DTOs, nodes, the full send/receive flow |
| [02-event-bus.md](doc/02-event-bus.md) | Practical bus usage, handlers, addressing, recipes |
| [03-isolate-and-layers.md](doc/03-isolate-and-layers.md) | `EventBusIsolate`, `Layers`, exchange limits |
| [04-fsm.md](doc/04-fsm.md) | State machine on top of the bus |
| [05-scope-and-command.md](doc/05-scope-and-command.md) | State with history, command pattern |
| [06-api-reference.md](doc/06-api-reference.md) | Every public type and member |
| [07-caveats.md](doc/07-caveats.md) | What was fixed in 2.3.0, what remains by design, checklist |

## Version 2 changes

- `EventBusIsolate`, `Layers`, `FSM`, `Scope`/`Command`, `subscribe`, `dispose` were added
- Reduced API surface; the bus always returns a result or `null` (the old `call` method is gone)
- `EventBusMaster` was removed — buses no longer need names
- Handlers return values through `EventDTO.completer`

## Version 2.3.0 changes

- `EventBus` now exposes `handlers` (no more `bus as EventBusHandlers`) and an idempotent `dispose()`
- Handler failures reach the sender instead of hanging it; listeners receive values before
  `await send(...)` returns
- `EventBusIsolate` correlates responses by request id, `waitInit` means "onInit completed",
  and `ping()` checks liveness; in-flight requests fail instead of hanging on dispose
- `Layers.createLayers` completes only when the whole chain is initialized; `Layer.close()` works
  from any layer
- `Scope`/`Command` `undo()` sends the previous value; `Scope.maxLenForUndo` defaults to 10
- `EventDTO.toJson` no longer encodes data; `Topic.copy` keeps `path`; `EventBusException` is exported
- Typo'd members got correct names (`queueLength`, `initialData`, `scheme`,
  `initialDataNeedExecute`) with the old ones kept as `@Deprecated`

The full list with reproductions is in [doc/07-caveats.md](doc/07-caveats.md#what-was-fixed-in-230).

See [CHANGELOG.md](CHANGELOG.md) for the full history.

## License

MIT — see [LICENSE](LICENSE).
