# EventBus Arch

An event-driven toolkit for Dart and Flutter. Events are addressed by an explicit **address** and
a typed **key**; components stay decoupled, and the same event model works in one isolate, across
isolates, and over a broker.

```dart
final orderPlaced = EventKey<Order>('orders.placed.v1');

bus.fire(orderPlaced, order);                         // one-way, listeners only
final result = await bus.request(orderPlaced, order); // one handler answers
```

The Dart type is not part of the address. It is the delivery filter of the `(address, Type)` node,
so keys keep working under minification and obfuscation, and the address is the stable wire
contract.

## Packages

| Package | What it provides | Documentation |
|---|---|---|
| `event_bus_arch` | `EventBus`, addresses and keys, subscriptions, `EventBusIsolate`, `Layers`, `WorkerPool`, observability | this README and [doc/](doc/README.md) |
| `event_bus_arch_patterns` | `FSM`, `Scope`, `Command` | [package README](packages/event_bus_arch_patterns/README.md) |
| `event_bus_arch_transport` | Broker-agnostic transport seam, address mapping, typed codecs | [package README](packages/event_bus_arch_transport/README.md) |
| `event_bus_arch_nats` | NATS adapter | [package README](packages/event_bus_arch_nats/README.md) |
| `event_bus_arch_mqtt` | MQTT 5 adapter | [package README](packages/event_bus_arch_mqtt/README.md) |

Patterns and transports are separate packages on purpose: the core stays a routing library.
Install only what your application uses.

## Installation

```yaml
dependencies:
  event_bus_arch: ^4.1.1

  # optional
  event_bus_arch_patterns: ^0.1.0
  event_bus_arch_transport: ^0.2.0
  event_bus_arch_nats: ^1.1.0
  event_bus_arch_mqtt: ^0.2.0
```

```bash
dart pub get
```

Dart SDK `>=3.6.0 <4.0.0`. `rxdart` is not re-exported; add it to your own dependencies if needed.

## Quick start

```dart
import 'package:event_bus_arch/event_bus_arch.dart';

final hello = EventKey<String>('greeting.hello');

Future<void> main() async {
  final bus = EventBus();

  // A raw Stream.
  final streamSub = bus.listen(hello).listen((value) => print('listen: $value'));

  // A managed subscription with a bounded buffer and/or a request handler.
  final subscription = bus.subscribe(
    hello,
    onEvent: (value) => print('subscribe: $value'),
    handler: (dto, lastData) async => 'processed: ${dto.data}',
  );

  bus.fire(hello, 'hi');
  print(await bus.request(hello, 'hello')); // processed: hello

  await streamSub.cancel();
  await subscription.cancel();
  await bus.dispose();
}
```

## Core model

### `fire` and `request`

| | `fire(key, data)` | `request(key, data)` |
|---|---|---|
| Purpose | one-way event | ask one handler for a result |
| Invokes a handler | no | yes, exactly one |
| Return value | `bool` — accepted by a listener, model store or transport | `Future<dynamic>` — the handler's result |
| No listener / handler | `false` | `NoHandlerException` |
| Waits | no | yes, until the handler answers; optional `timeout` |

Both modes deliver the event to listeners. A wildcard selector can subscribe to a family of
addresses; `fire` and `request` always take an exact `EventKey<T>`.

### Addresses and keys

```dart
final placed = EventKey<Order>('orders.placed.v1');
final anyOrder = EventPatternKey<Order>('orders.*');
```

- Addresses use `.` between tokens. `*` matches one token, `>` matches one or more trailing
  tokens.
- `EventKey<T>` is exact; `EventPatternKey<T>` is a pattern. Both extend `EventSelector<T>`.
- A node is `(address, Type)`. `EventKey<Order>` and `EventKey<Invoice>` on the same address are
  separate nodes with separate `currentData`.
- Put a version in the address when the payload schema can change: `orders.placed.v1`.

### Subscriptions

- `listen(selector)` returns a raw `Stream<T>`.
- `subscribe(selector, ...)` returns an `EventSubscription<T>` with its own buffer, overflow
  policy, pause/resume/resize, counters and an optional request handler.
- Use `subscribe(onEvent:)` whenever the consumer can be slow.

### Model bus

`EventBus(isModelBus: true)` keeps the last value per key even when nobody is listening.
`currentData(selector)` reads it. A common bus forgets the node after the last subscription.

### Isolates, layers and workers

```dart
final iso = EventBusIsolate(onInit: _worker);
await iso.waitInit;
print(await iso.request(workKey, 21));

final layer = await Layers.createLayers([
  LayerSpec(init: _initMiddle, isModelBus: true),
  LayerSpec(init: _initBottom, isModelBus: true),
], bridgeIsModelBus: true);

final pool = WorkerPool(
  onInit: _worker,
  workers: 4,
  dispatch: DispatchStrategy.leastBusy,
);
await pool.waitInit;
```

`Layers` builds a chain of isolate layers; `WorkerPool` runs N workers with a dispatch strategy
and restart supervision. Isolate APIs are VM-only.

### Observability

```dart
final bus = EventBus(
  observability: const ObservabilityConfig(enabled: true),
);
bus.fire(counterKey, 1, correlationId: 'job-42');
final snapshot = bus.metrics.snapshot();
```

Metrics are opt-in and keyed by event address. `bus.errors` carries `EventBusError` data events
with a bounded recent buffer and rate limiting.

## Documentation

| Document | Content |
|---|---|
| [doc/README.md](doc/README.md) | Index and reading paths |
| [01-concepts.md](doc/01-concepts.md) | Address, keys, DTO, nodes, subscriptions |
| [02-event-bus.md](doc/02-event-bus.md) | Publishing, receiving, handlers, model bus |
| [03-subscriptions.md](doc/03-subscriptions.md) | Buffers, backpressure, handler queues, request lifecycle |
| [04-isolates-and-workers.md](doc/04-isolates-and-workers.md) | `EventBusIsolate`, `Layers`, `WorkerPool`, supervision |
| [05-observability.md](doc/05-observability.md) | Errors, metrics, correlation ids |
| [06-api-reference.md](doc/06-api-reference.md) | Public types and signatures |
| [07-platforms.md](doc/07-platforms.md) | VM and Web support |

## Web

The local bus, subscriptions, observability and `event_bus_arch_transport` compile and run in the
browser. `EventBusIsolate`, `Layers` and `WorkerPool` throw `UnsupportedError`; see
[doc/07-platforms.md](doc/07-platforms.md).

## License

MIT — see [LICENSE](LICENSE).
