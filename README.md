# EventBus Arch

`event_bus_arch` is an event-driven architecture toolkit for Dart and Flutter. Components talk to
each other through events addressed by an explicit **address** and a **typed key** — never by a
Dart type name or a runtime string — so they stay decoupled, survive minification and can cross
isolates and brokers unchanged.

The core package ships an isolate bridge, multi-isolate "layers", a worker pool and
observability. Higher-level patterns — the finite state machine, `Scope` and `Command` — live in
the separate [`event_bus_arch_patterns`](packages/event_bus_arch_patterns) package, so the bus
itself stays a routing library.

* Detailed documentation: **[doc/](doc/README.md)**
* Full API reference: [doc/06-api-reference.md](doc/06-api-reference.md)
* Upgrading from 3.x: [doc/15-migration-3-to-4.md](doc/15-migration-3-to-4.md)
* Load benchmark: [benchmark/README.md](benchmark/README.md)

## Features

- **Explicit addressing**: an `EventAddress` string is the identity; `EventKey<T>` adds the static
  type, and `EventPatternKey<T>` adds a wildcard pattern.
- **Two publish modes**: `fire` (one-way, listeners only) and `request` (one handler, returns a
  result) — see [Two modes: `fire` and `request`](#two-modes-fire-and-request)
- `subscribeEvents` — a subscription handle with its own bounded buffer, pause/resume, resize and
  backpressure policies
- Two bus flavours: **common** (`EventBus()`) and **model** (`EventBus(isModelBus: true)`) —
  the model bus keeps the last value per key even when nobody is listening
- `EventBusIsolate` — the same API, but the events are processed in a worker isolate
- `Layers` — chains of isolates: `main ↔ isolate₂ ↔ isolate₁ ↔ isolate₀`
- `WorkerPool` — N workers with `broadcast`/`roundRobin`/`keyed`/`leastBusy`/`single` dispatch,
  request credits and restart supervision; `Layers.supervise` restarts a whole worker chain
- Observability — opt-in per-address/subscription metrics, snapshots and a changes stream,
  correlation ids across isolates and transports, and an error monitor
- `event_bus_arch_patterns` — `FSM` driven by bus events, and `Scope` / `Command` for a stateful
  value with call history
- `event_bus_arch_transport` — a broker-agnostic seam with typed codecs keyed by address; NATS and
  MQTT 5 adapters are separate packages
- `EventBusLogger` — trace every event that crosses the bus
- Type-safe handlers, no code generation, no `dart:mirrors`

## Installation

```yaml
dependencies:
  event_bus_arch: ^4.0.0
  event_bus_arch_patterns: ^0.1.0   # only if you use FSM, Scope or Command
```

```bash
dart pub get      # or: flutter pub get
```

Dart SDK `>=3.6.0 <4.0.0`. The package no longer re-exports `rxdart`; add it to your own
dependencies if you need `BehaviorSubject`, `debounceTime` and the rest.

## Packages

| Package | What it contains |
|---|---|
| `event_bus_arch` | `EventBus`, addresses/keys, nodes, subscriptions, `EventBusIsolate`, `Layers`, `WorkerPool`, observability, logger |
| `event_bus_arch_patterns` | `FSM`, `Scope`, `Command` |
| `event_bus_arch_transport` | The broker-agnostic transport seam, address mapper, typed codecs, bus and node |
| `event_bus_arch_nats` | The NATS adapter |
| `event_bus_arch_mqtt` | The MQTT 5 adapter |

## Quick start

```dart
import 'package:event_bus_arch/event_bus_arch.dart';

final helloKey = EventKey<String>('greeting.hello');

Future<void> main() async {
  final bus = EventBus();

  // Receive: every event on the key, current and future.
  final listener = bus.listen(helloKey).listen((event) => print('got: $event'));

  // Handle: the handler returns the response; request waits for it.
  // lastData is the PREVIOUS value of this key, dto.data is the current one.
  final handler = bus.subscribeEvents(helloKey, handler: (dto, lastData) async {
    return 'processed: ${dto.data}';
  });

  final delivered = bus.fire(helloKey, 'hi');   // true — the listener exists
  final result = await bus.request(helloKey, 'hello');
  print(result);                                 // processed: hello

  await listener.cancel();
  await handler.cancel();
  await bus.dispose();
}
```

## Two modes: `fire` and `request`

There are exactly two ways to publish an event, and they have different contracts:

| | `fire(key, data)` | `request(key, data)` |
|---|---|---|
| Purpose | one-way event | ask a handler for a result |
| Invokes handler subscriptions | **no** — listeners only | **yes** — one handler |
| Return value | `bool` — was the event accepted | `Future<dynamic>` — the handler's result |
| No listener / no handler | `false`, not an error | throws `NoHandlerException` |
| Waits | no, returns immediately | yes, until the handler returns; optional `timeout` |
| Call arguments | `arguments` reach listeners in `dto.arguments` | the same, plus the handler |
| Wildcard key | rejected — `fire`/`request` require `EventKey<T>` | rejected — the same |

```dart
final bus = EventBus();
final sensorKey = EventKey<int>('sensor.temp');
final anySensor = EventPatternKey<int>('sensor.*');

// A wildcard listener.
bus.subscribe(anySensor, onData: (v) => print('event: $v'));

// A handler is a request responder; fire never calls it.
bus.subscribeEvents(sensorKey, handler: (dto, lastData) async => dto.data * 2);

// fire: one-way, returns whether the event was accepted.
final delivered = bus.fire(sensorKey, 21);          // true
// the wildcard listener printed "event: 21" (asynchronously)

// request: waits for the handler and returns its result.
final doubled = await bus.request(sensorKey, 21);   // 42
// the wildcard listener also saw the request: "event: 21"
```

`fire` and `request` both notify listeners; the difference is the handler call and the result
channel. A request without a handler is an error, not a silently ignored event.

### Addresses and keys

An address is a sequence of tokens separated by `.`:

```text
orders.placed.v1
   │      │    └── version in the address, not in a Dart type name
   │      └─────── event name
   └────────────── domain
```

The address is a plain string chosen by the application. It is the local identity, the metric key
and the wire subject at once. `EventKey<T>` binds an address to a static type:

```dart
final placed = EventKey<OrderPlaced>('orders.placed.v1');

bus.fire(placed, order, arguments: {'priority': '1'});
bus.subscribeEvents(placed, onEvent: (order) => print(order));
```

The type is **not** part of the address. It is the delivery filter: a node is identified by
`(address, Type)`, and `EventKey<OrderPlaced>` and `EventKey<OrderCancelled>` on the same address
are separate nodes with separate `currentData`. A listener subscribed to a supertype key accepts
subtype data; a listener on an unrelated type does not.

Because `Type` is compared through a compile-time token rather than `Type.toString()`, keys keep
working under `dart compile js -O2` and other minifiers. Do not build addresses from
`T.toString()` or `runtimeType`.

The address grammar is fixed: `.` separates tokens, `*` matches exactly one token, and `>`
matches one or more trailing tokens. `EventAddress` rejects empty tokens and wildcards; a
`EventPattern` validates wildcard placement. A transport maps the same tokens to its own grammar
(NATS uses `.`, MQTT uses `/`) — the address string does not change.

### Wildcards

`listen`, `subscribe` and `subscribeEvents` accept an `EventPatternKey<T>`:

- `*` matches exactly one token: `sensor.*`;
- `>` matches one or more trailing tokens and must be last: `sensor.>`.

```dart
final anyReading = EventPatternKey<int>('sensor.*');
final wholeTree = EventPatternKey<int>('sensor.>');

bus.subscribe(anyReading, onData: (value) => print('sensor: $value'));

final temp = EventKey<int>('sensor.temp');
bus.fire(temp, 21);                  // matches both patterns
bus.fire(EventKey<int>('sensor.room.temp'), 22); // matches only '>'
```

`fire` and `request` require an exact `EventKey<T>`; an `EventPatternKey` there is a type error,
not a runtime surprise.

The same pattern can answer requests when it is registered as a handler:

```dart
bus.subscribeEvents(anyReading, handler: (dto, lastData) async => dto.data * 2);
await bus.request(temp, 21);   // 42
```

An exact handler wins over a pattern handler; among patterns, the most specific one wins.
`fire` delivers to the exact node and to every matching pattern node. `currentData(pattern)`
returns the last matching value of that type; `currentData(exactKey)` reads only the exact node.

### Model bus vs common bus

| | `EventBus()` | `EventBus(isModelBus: true)` |
|---|---|---|
| Creates a node on `fire` to an unknown key | no | yes |
| Keeps `currentData` after the last listener unsubscribes | no | yes |
| `fire` to a key with no node | returns `false`, event goes to `allEventStream` with flag `false` | returns `true`, node is created |
| `request` without a handler | throws `NoHandlerException` | throws `NoHandlerException` |
| Forgetting one key | automatic after the last listener | explicit `remove(key)` / `removePattern(patternKey)` / `removeAddress(address)` |

A handler subscription is a request responder: `request` invokes it, while `fire` only notifies
listeners. `remove` works on both flavours, closes the listeners of the node and, on a transport
bus, cancels the broker subscription; a later `fire` recreates the node.

Use the model bus when the bus is a store of current state, and the common bus when it is a
message pipe.

### Isolates

```dart
import 'dart:isolate';
import 'package:event_bus_arch/event_bus_arch.dart';

final requestKey = EventKey<int>('calc');
final responseKey = EventKey<int>('calc.result');

Future<void> main() async {
  final iso = EventBusIsolate(onInit: _worker, initialData: 'worker');
  await iso.waitInit;                                  // true when onInit has completed

  iso.subscribe(responseKey, onData: (e) => print('from worker: $e'));
  final doubled = await iso.request(requestKey, 21, arguments: {'multiplier': '2'});
  print(doubled);                                      // 42

  await iso.dispose();
}

// runs inside the worker isolate — must be a top-level or static function
Future<void> _worker(EventBus bus, Object? initialData) async {
  await _heavyInit();                                  // async init is fine
  bus.subscribeEvents(requestKey, handler: (dto, lastData) async {
    final m = int.tryParse(dto.arguments?['multiplier'] ?? '1') ?? 1;
    return dto.data * m;
  });
  bus.fire(responseKey, 42);
}
```

`EventBusIsolate` is a directional bridge: events sent from the worker reach main-isolate
listeners, and `request` from main returns the worker's handler result. `fire` goes only to the
other side and is never delivered to the firing side's own listeners, so a listener that fires the
same key cannot re-enter itself. For local pub/sub use an ordinary `EventBus` (in `Layers` that is
`Layer.current`). Keys and `arguments` cross the boundary with the event; the address string is
unchanged on both sides.

Good to know:

1. Only sendable objects can cross the isolate boundary.
2. `waitInit` completes when `onInit` has finished (including its `await`s), so events sent right
   after it are never lost. Errors from `onInit` surface as an `EventBusException` from
   `waitInit`.
3. Every request is answered exactly once and correlated by request id, so concurrent requests of
   the same key each get their own result. A key the worker has no handler for fails with
   `NoHandlerException`; a handler error is rethrown at the sender; an in-flight request fails
   with `EventBusException` if the isolate is disposed.
4. `ping()` only checks liveness ("is the worker alive"), not readiness.
5. `EventBusIsolate(isModelBus: true)` makes the bus a model bus on **both** sides of the bridge:
   the main-side bus and the bus inside the worker. The default is a common bus.

### Layers

```dart
final chainKey = EventKey<int>('chain');

final layer = await Layers.createLayers([
  (_initMiddle, null, true),   // (init function, initial data, isModelBus)
  (_initBottom, null, true),
], bridgeIsModelBus: true);    // optional: model buses for the isolate bridges
// main ↔ isolate[middle] ↔ isolate[bottom]

// createLayers completes only when every layer in the chain is initialized,
// so events can be sent right away
layer.bottom!.subscribe(chainKey, onData: (e) => print(e));
layer.bottom!.fire(chainKey, 0);
await layer.close();
```

Inside a layer, `layer.top` sends to the layer above, `layer.bottom` to the layer below, and
`layer.current` is the layer's own bus. The tuple's third element sets `layer.current.isModelBus`;
`bridgeIsModelBus` (default `false`) sets `isModelBus` on every inter-layer `EventBusIsolate`
bridge instead. Init functions may be `async` and may live in any layer; `Layer.close()` works
from any layer and is safe to call twice. See
[doc/03-isolate-and-layers.md](doc/03-isolate-and-layers.md#example-two-worker-layers)
and [example/event_bus_layers_example.dart](example/event_bus_layers_example.dart).

### WorkerPool and supervision

```dart
final jobsKey = EventKey<int>('jobs');
final noteKey = EventKey<String>('note');

final pool = WorkerPool(
  onInit: _worker,                 // top-level/static; runs in every worker
  workers: 4,
  dispatch: DispatchStrategy.leastBusy,
  initialDataFor: (index) => index,
  supervision: const SupervisionPolicy(maxRestarts: 3),
);
await pool.waitInit;

final answer = await pool.request(jobsKey, 21);   // routed to one worker
pool.fire(noteKey, 'refresh');                    // routed by the same strategy
await pool.close();
```

Strategies: `broadcast` (fire only; requests throw `UnsupportedError`),
`roundRobin`, `keyed` (the address by default, a `keySelector` overrides; per-key order is
preserved), `leastBusy`, `single` (one active worker with a standby). A dead worker is restarted
with backoff; restart exhaustion emits `EventBusErrorKind.supervision` and fails the pool.
`maxInFlightPerWorker` bounds in-flight requests per worker; with no free credit `fire` returns
false and `request` throws `BusyException`. Pending requests of a dead worker fail and are never
retried.

`Layers.supervise(...)` builds a chain with the same guarantees: any worker layer failure restarts
the whole worker chain, while the top layer, its `current` bus and the subscriptions on
`layer.bottom` survive. Pending requests fail, and calls on the bridge throw `StateError` while
the chain is restarting.

```dart
final supervisor = Layers.supervise(
    [(_initMiddle, null, true), (_initBottom, null, true)]);
await supervisor.waitInit;
supervisor.errors.listen((error) => print(error));
await supervisor.close();
```

### Observability

Collection is off by default and costs nothing on the hot path. Enable it at construction:

```dart
final bus = EventBus(observability: const ObservabilityConfig(
  enabled: true,
  cardinalityLimit: 1000,     // new keys above the limit go to __other__
  capturePayloads: false,     // errors carry event data only when asked
));

final counterKey = EventKey<int>('counter');
bus.fire(counterKey, 1, correlationId: 'job-42');
final snapshot = bus.metrics.snapshot();
print(snapshot.topics.first.fired);       // 1
```

- Per address: fired/delivered/dropped/overflow and request outcomes
  (started/completed/errored/timeout/canceled/busy), plus fixed-bucket latency histograms.
- Per subscription: buffer and queue depth, `maxBufferedRequests`, in-flight handlers,
  concurrency, delivered/dropped and queue-wait latency.
- The metric key is the event address; `metricKeyBuilder` can coarsen it. Dynamic addresses
  therefore cannot grow the registry without bound.
- `bus.metrics.changes` is a coalesced live stream; implement `EventBusMetricsExporter` to feed
  OpenTelemetry, Prometheus or a dashboard.
- `correlationId:` on `fire`/`request` reaches handlers (`dto.correlationId`), crosses isolates and
  travel transport headers; `EventBusError.correlationId` reports it when known.
- `EventBusErrorMonitor(filter: ..., maxErrorsPerSecond: ...)` aggregates several buses, keeps a
  bounded recent buffer and exposes `snapshot()` counters by kind and address.

### Finite state machine

`FSM` is part of `event_bus_arch_patterns`:

```dart
import 'package:event_bus_arch_patterns/event_bus_arch_patterns.dart';
```

```dart
enum State { idle, loading, ready }

class Loader with FSM<State> {
  Loader(EventBus bus) {
    initFSM(bus, State.idle);
    addFSMTransition<Start>(State.idle, State.loading,
      selector: EventKey<Start>('api.items'),
      filter: (current, last, event) => event.url.isNotEmpty,
      handler: (current, last, event, ignored) async {
        print('$last -> $current ($event)');
        return null;
      });
  }
}

final startKey = EventKey<Start>('api.items');
bus.fire(startKey, Start('/api/items'));   // State.idle -> State.loading
```

Events arriving while a transition handler is running are collected into the `ignoredEvents`
argument and are not replayed afterwards. A handler error resets the transition-in-progress flag in
a `finally` block, so the machine never gets stuck. `FSM.dispose()` unsubscribes the machine from
the bus.

### Scope and Command

`Scope` and `Command` are part of `event_bus_arch_patterns` (the same import as above).

```dart
final scope = Scope<int>();
await scope.initScope(
  bus,
  EventKey<int>('counter'),
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

## Web

The core bus, model buses, `subscribeEvents`, observability and the broker-agnostic transport seam
compile and run in the browser. The isolate APIs are VM-only:

```dart
if (EventBusCapabilities.isolateSupported) {
  // EventBusIsolate, Layers, WorkerPool
} else {
  // local bus + a transport
}
```

`EventBusIsolate`, `Layers.createLayers`, `Layers.supervise` and `WorkerPool` throw
`UnsupportedError` on the web at construction, before touching `dart:isolate`.

```bash
dart test -p chrome test/web_smoke_test.dart
dart compile js tool/web_compile_check.dart -o build/web_check.js
```

`event_bus_arch_transport` is platform-neutral. The shipped NATS and MQTT connections are VM-only:
NATS (`dart_nats`) is TCP-only, and the MQTT adapter uses the VM `MqttServerClient`. On the web,
implement `TransportConnection` over a browser WebSocket (MQTT has `MqttBrowserClient`) and pass it
to `TransportEventBus.keys(...)`.

## Documentation

Detailed guides live in [doc/](doc/README.md):

| Document | Content |
|---|---|
| [01-architecture.md](doc/01-architecture.md) | Addresses, keys, DTOs, nodes, the full send/receive flow |
| [02-event-bus.md](doc/02-event-bus.md) | Practical bus usage, handlers, addressing, recipes |
| [03-isolate-and-layers.md](doc/03-isolate-and-layers.md) | `EventBusIsolate`, `Layers`, exchange limits |
| [04-fsm.md](doc/04-fsm.md) | State machine on top of the bus |
| [05-scope-and-command.md](doc/05-scope-and-command.md) | State with history, command pattern |
| [06-api-reference.md](doc/06-api-reference.md) | Every public type and member |
| [07-caveats.md](doc/07-caveats.md) | Limits, failure modes, checklist |
| [08-transports.md](doc/08-transports.md) | Running the bus over NATS / MQTT: analysis |
| [09-event-bus-nats.md](doc/09-event-bus-nats.md) | The implemented NATS transport: usage, architecture, limitations |
| [10-event-bus-mqtt.md](doc/10-event-bus-mqtt.md) | The implemented MQTT 5 transport: usage, architecture, limitations |
| [15-migration-3-to-4.md](doc/15-migration-3-to-4.md) | Migrating from the type-as-address 3.x model |

## Version 4.0.0 changes

The address model changed; this is a breaking release.

- **Addresses are explicit strings chosen by the application**: `orders.placed.v1`, not
  `OrderPlaced.orders.>`. `EventAddress` is the identity; `EventKey<T>` adds the static type and
  `EventPatternKey<T>` adds a wildcard pattern.
- **The Dart type is no longer in the address.** It is the delivery filter of the node
  `(address, Type)`. `Type.toString()`/`runtimeType` never reach routing or the wire, so keys work
  under `dart compile js -O2` and other minifiers.
- **Wildcards are fixed**: `.` separates tokens, `*` matches one token, `>` one or more trailing
  tokens. The per-call `paths`/`separator` parameters and `EventBus.defaultTopicPathSeparator` are
  gone.
- **The bus API takes selectors**: `fire(key, data)`, `request(key, data)`,
  `listen(selector)`, `subscribe(selector)`, `subscribeEvents(selector)`,
  `currentData(key)`, `haveListener/haveHandler/haveAvailableHandler(selector)`,
  `remove(key)`, `removePattern(patternKey)`, `removeAddress(address)`.
- **`EventDTO.key` and `EventDTO.address`** replace the string `topic`; `EventBusError.address`
  replaces `topic` (the old field remains as a compatibility alias).
- **Transports are typed**: `EventCodecRegistry` resolves an encoder/decoder by address or pattern;
  only the node whose exact key equals the DTO key publishes. `typeTags`/`wireTypes` are gone.
- **`FSM`, `Scope` and `Command` moved** to `event_bus_arch_patterns` and take `EventKey`/
  `EventPatternKey` instead of `paths`.
- The full migration table is in [doc/15-migration-3-to-4.md](doc/15-migration-3-to-4.md).

## Version 3.0.0 changes

- `Topic` lost `scheme`, `target` and `fragment`; `paths` replaced `path`; the type token was
  `'$T'`.
- `send` was split into `fire` and `request`; handlers return their response.
- `lastData` was renamed `currentData`; local wildcards `*` and `>` were added.
- `event_bus_arch_nats`, `event_bus_arch_transport` and `event_bus_arch_mqtt` appeared.

The full history is in [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).
