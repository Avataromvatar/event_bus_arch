# EventBus Arch

`event_bus_arch` is an event-driven architecture toolkit for Dart and Flutter. Components talk to
each other through events addressed by a **topic** — a type plus a path — so they stay decoupled
and can be moved between isolates without changing their logic.

On top of the bus the package ships a finite state machine, an isolate bridge, multi-isolate
"layers", and a scope/command wrapper for stateful values.

* Detailed documentation: **[doc/](doc/README.md)**
* Full API reference: [doc/06-api-reference.md](doc/06-api-reference.md)
* Upgrading from 2.x: [doc/07-caveats.md](doc/07-caveats.md#what-changed-in-300)

## Features

- Send and receive events between components (`fire` / `request` / `listen` / `subscribe`)
- Handlers that return a result to `request`
- Two bus flavours: **common** (`EventBus()`) and **model** (`EventBus(isModelBus: true)`) —
  the model bus keeps the last value per topic even when nobody is listening
- Topic-based routing: event type + `paths`, plus `arguments` as call parameters
- `EventBusIsolate` — the same API, but the events are processed in a worker isolate
- `Layers` — chains of isolates: `main ↔ isolate₂ ↔ isolate₁ ↔ isolate₀`
- `FSM` — finite state machine driven by bus events
- `Scope` / `Command` — stateful value with call history
- `EventBusLogger` — trace every event that crosses the bus
- Type-safe handlers, no code generation

## Installation

```yaml
dependencies:
  event_bus_arch: ^3.0.0
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

  // Handle: the handler returns the response; request waits for it.
  // lastData is the PREVIOUS value of this topic, dto.data is the current one.
  bus.handlers.setHandler<String>(handler: (dto, lastData) async {
    return 'processed: ${dto.data}';
  });

  final result = await bus.request<String>('hello');
  print(result);                 // processed: hello

  // by now the listener has already received the value: request() is a sync point
  await sub.cancel();
  await bus.dispose();
}
```

### Topics

A topic is the **static type argument** of the call plus an optional path:

```text
OrderPlaced.warehouse.in
     │            │
     │            └── paths: ['warehouse', 'in']
     └─────────────── type: the type parameter T of the call
```

```dart
bus.fire<Order>(order, paths: ['warehouse', 'in'], arguments: {'priority': '1'});

bus.subscribe<Order>(paths: ['warehouse', 'in'], onData: (order) => print(order));
```

`paths` selects the topic; `arguments` are delivered to the handler as `dto.arguments` but do not
affect routing. Because the type is part of the address, `request<int>` and a handler
registered with `setHandler<num>` are **different topics** — always be explicit with type
arguments.

A path token must not contain the separator (`.` by default): `paths: ['a.b']` and
`paths: ['a', 'b']` build the same address. Pass `separator: '/'` to address such a topic,
or change the fallback for a whole bus:

```dart
final bus = EventBusImpl(false)..defaultTopicPathSeparator = '/';
```

### Wildcards

`listen`, `subscribe` and `setHandler` accept wildcard path tokens:

- `*` matches exactly one path token: `int.sensor.*`;
- `>` matches one or more trailing tokens and must be the last token:
  `int.sensor.>`.

```dart
bus.subscribe<int>(paths: ['sensor', '*'], onData: (value) => print(value));
bus.fire<int>(21, paths: ['sensor', 'temp']);     // delivered to the pattern

bus.handlers.setHandler<int>(paths: ['sensor', '*'],
    handler: (dto, lastData) async => dto.data * 2);
await bus.request<int>(21, paths: ['sensor', 'temp']);   // 42
```

A `fire` or `request` call itself must name a concrete topic: wildcard paths
throw. A request may be answered by a handler registered on a pattern (exact
handler first, then the most specific pattern). `fire` delivers to the exact
node and to every matching pattern node. `currentData(pattern)` returns the
last matching value; `currentData(concrete)` reads only the exact node.

### Model bus vs common bus

| | `EventBus()` | `EventBus(isModelBus: true)` |
|---|---|---|
| Creates a node when sending to an unknown topic | no | yes |
| Keeps `lastData` after the last listener unsubscribes | no | yes |
| `fire` to a topic with no node | returns `false`, event goes to `allEventStream` with flag `false` | returns `true`, node is created |
| `request` without a handler | throws `NoHandlerException` | creates a node, then throws `NoHandlerException` |

A handler registered with `setHandler` is a request responder: `request` invokes it, while
`fire` only notifies listeners.

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
  final doubled = await iso.request<int>(21, arguments: {'multiplier': '2'});
  print(doubled);                                      // 42

  await iso.dispose();
}

// runs inside the worker isolate — must be a top-level or static function
Future<void> _worker(EventBus bus, Object? initialData) async {
  await _heavyInit();                                  // async init is fine
  bus.handlers.setHandler<int>(handler: (dto, lastData) async {
    final m = int.tryParse(dto.arguments?['multiplier'] ?? '1') ?? 1;
    return dto.data * m;
  });
}
```

`EventBusIsolate` behaves like a normal bus on both sides: events sent from the worker reach
main-isolate listeners, and `request` from main returns the worker's handler result. Paths, separator
and `arguments` cross the boundary with the event.

Good to know:

1. Only sendable objects can cross the isolate boundary.
2. `waitInit` completes when `onInit` has finished (including its `await`s), so events sent right
   after it are never lost. Errors from `onInit` surface as an `EventBusException` from
   `waitInit`.
3. Every request is answered exactly once and correlated by request id, so concurrent requests of
   the same type each get their own result. A topic the worker has no handler for fails with
   `NoHandlerException`; a handler error is rethrown at the sender; an in-flight request fails with
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
layer.bottom!.fire(Ping(0));
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
      eventPaths: ['api', 'items'],            // the transition listens on Start.api.items
      filter: (current, last, event) => event.url.isNotEmpty,
      handler: (current, last, event, ignored) async {
        print('$last -> $current ($event)');
        return null;
      });
  }
}

bus.fire(Start('/api/items'), paths: ['api', 'items']);   // State.idle -> State.loading
```

Events arriving while a transition handler is running are collected into the `ignoredEvents`
argument and are not replayed afterwards. `FSM.dispose()` unsubscribes the machine from the bus.

### Scope and Command

```dart
final scope = Scope<int>();
await scope.initScope(
  bus,
  paths: ['counter'],
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

Detailed guides live in [doc/](doc/README.md):

| Document | Content |
|---|---|
| [01-architecture.md](doc/01-architecture.md) | Topics, DTOs, nodes, the full send/receive flow |
| [02-event-bus.md](doc/02-event-bus.md) | Practical bus usage, handlers, addressing, recipes |
| [03-isolate-and-layers.md](doc/03-isolate-and-layers.md) | `EventBusIsolate`, `Layers`, exchange limits |
| [04-fsm.md](doc/04-fsm.md) | State machine on top of the bus |
| [05-scope-and-command.md](doc/05-scope-and-command.md) | State with history, command pattern |
| [06-api-reference.md](doc/06-api-reference.md) | Every public type and member |
| [07-caveats.md](doc/07-caveats.md) | What 3.0.0 changed, what remains by design, checklist |
| [08-transports.md](doc/08-transports.md) | Running the bus over NATS / Redis / NanoMQ: analysis |
| [09-event-bus-nats.md](doc/09-event-bus-nats.md) | The implemented NATS transport: usage, architecture, limitations |

## Version 3.0.0 changes

The address model changed; this is a breaking release.

- `Topic` is no longer URI-like: **`scheme`, `target` and `fragment` are gone**
- `path: '/in'` became **`paths: ['in']`** — a list of tokens joined by a configurable `separator`
  (`.` by default, `EventBus.defaultTopicPathSeparator`)
- **`arguments` moved from `Topic` to `EventDTO`**: `dto.topic.arguments` is now `dto.arguments`,
  both locally and across an isolate
- The type in the address is `'$T'` as written — no lowercasing, no percent-encoding
- `topic.topic` is the single routing key (`fullTopic`/`topicWithFragment` are gone)
- **`packages/event_bus_nats`** adds a NATS transport as a separate package; the core stays
  broker-free (see [doc/09-event-bus-nats.md](doc/09-event-bus-nats.md))
- The deprecated `queueLenght`, `initalData`, `initialDataNeedExecute` and `shema` aliases were removed

The full migration table is in [doc/07-caveats.md](doc/07-caveats.md#migration-table).

## Version 2 changes

- `EventBusIsolate`, `Layers`, `FSM`, `Scope`/`Command`, `subscribe`, `dispose` were added
- Reduced API surface; the bus always returns a result or `null` (the old `call` method is gone)
- `EventBusMaster` was removed — buses no longer need names
- Handlers return values through `EventDTO.completer`

## Version 2.3.0 changes

- `EventBus` now exposes `handlers` (no more `bus as EventBusHandlers`) and an idempotent `dispose()`
- Handler failures reach the sender instead of hanging it; listeners receive values before
  `await request(...)` returns
- `EventBusIsolate` correlates responses by request id, `waitInit` means "onInit completed",
  and `ping()` checks liveness; in-flight requests fail instead of hanging on dispose
- `Layers.createLayers` completes only when the whole chain is initialized; `Layer.close()` works
  from any layer
- `Scope`/`Command` `undo()` sends the previous value; `Scope.maxLenForUndo` defaults to 10
- `EventDTO.toJson` no longer encodes data; `EventBusException` is exported
- Typo'd members got correct names (`queueLength`, `initialData`, `scheme`,
  `initialDataNeedExecute`) — those aliases were removed again in 3.0.0

The full list with reproductions is in [doc/07-caveats.md](doc/07-caveats.md#what-was-fixed-in-230).

See [CHANGELOG.md](CHANGELOG.md) for the full history.

## License

MIT — see [LICENSE](LICENSE).
