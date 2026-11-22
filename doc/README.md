# event_bus_arch documentation

Detailed description of the `event_bus_arch` 4.0 package. The main README (in English) —
[../README.md](../README.md).

New here? Start with [00. Overview](00-overview.md): it has the API and component maps and the
reading paths.

## Contents

| # | Document | What for |
|---|---|---|
| 00 | [Start here](00-overview.md) | API map, component map, reading paths, what is new in 4.0 |
| 01 | [Architecture](01-architecture.md) | EventAddress, EventKey, EventDTO, EventNode, EventSubscription, EventBus, delivery and dispatch |
| 02 | [EventBus in practice](02-event-bus.md) | Sending and receiving events, handlers, keys, recipes |
| 03 | [Isolates and layers](03-isolate-and-layers.md) | `EventBusIsolate`, interest sync, `Layers`, supervision |
| 04 | [FSM](04-fsm.md) | Finite state machine on top of the bus: transitions, filters, ignoredEvents (`event_bus_arch_patterns`) |
| 05 | [Scope and Command](05-scope-and-command.md) | State with history, the command pattern, `undo` pitfalls (`event_bus_arch_patterns`) |
| 06 | [API reference](06-api-reference.md) | Every public type and member with signatures |
| 07 | [Pitfalls and limits](07-caveats.md) | Known traps, failure modes, checklist |
| 08 | [Transports](08-transports.md) | The transport seam, address model, packaging, platform support |
| 09 | [event_bus_arch_nats](09-event-bus-nats.md) | The NATS adapter: architecture, reconnection, request/reply, limitations |
| 10 | [event_bus_arch_mqtt](10-event-bus-mqtt.md) | The MQTT 5 adapter: grammar, user properties, request/reply, limitations |
| 11 | [Backpressure and subscriptions](11-backpressure.md) | Listener buffers, overflow policies, handler queues, pause, credits |
| 12 | [Errors and observability](12-observability.md) | `EventBusError`, error monitor, metrics, correlation ids |
| 13 | [WorkerPool and supervision](13-pool-and-supervision.md) | Dispatch strategies, credits, worker restart, whole-chain Layers restart |
| 14 | [Web and platform](14-web.md) | VM vs browser, capability flags, transport limitations |
| 15 | [Migration 3.x to 4.0](15-migration-3-to-4.md) | What changed, step-by-step migration, the migration script |

## Diagrams

The documents use Mermaid inside Markdown, so every diagram renders on GitHub and in the VS Code
Markdown preview (install a Mermaid-enabled preview if needed). The types are UML-style:

* `classDiagram` — the public API and the relationships between types;
* `sequenceDiagram` — who calls whom for `fire`, `request`, an isolate hop or a broker hop;
* `stateDiagram-v2` — subscription, request, worker and supervisor lifecycles;
* `flowchart` — component maps, error flow and the platform matrix.

Each diagram has a short "what to notice" caption. Node names match the code, so a diagram can be
read next to [06. API reference](06-api-reference.md).

## Quick summary

```dart
import 'package:event_bus_arch/event_bus_arch.dart';

final bus = EventBus();                        // or EventBus(isModelBus: true)

final helloKey = EventKey<String>('greeting.hello');

// a listener with its own buffer
final sub = bus.subscribeEvents(helloKey,
  onEvent: (event) => print(event),
  bufferCapacity: 16,
  bufferOverflow: BufferOverflow.dropOldest,
);

// a handler answers requests; onEvent and handler may be combined
bus.subscribeEvents(helloKey, handler: (dto, lastData) async {
  return 'processed: ${dto.data}';
});

final result = await bus.request(helloKey, 'hello');   // 'processed: hello'
final delivered = bus.fire(helloKey, 'hello');         // whether anyone listened

await sub.cancel();
await bus.dispose();
```

What you need to know right away:

1. **The address is an explicit string; the type is a separate filter.** `EventKey<Order>` and
   `EventKey<Invoice>` on the same address are different nodes. The Dart type never appears in the
   address or on the wire.
2. **`lastData` in a handler is the previous value** of the key; `dto.data` is the current one.
3. **`request` is a sync point for the caller** — by the time `await bus.request(...)` returns, the
   handler has answered and listeners have been offered the event (listener callbacks may still be
   buffered). `fire` does not wait and never invokes a handler; a handler-only node does not make
   `fire` return `true`.
4. **`Scope.undo()` needs a history of at least two calls** (`maxLenForUndo >= 2`, default 10).
   `Scope`, `Command` and `FSM` live in `event_bus_arch_patterns`, not in the core package.
5. **Wildcards are local.** `*` matches one token, `>` one or more trailing tokens. `listen`,
   `subscribe` and `subscribeEvents` accept `EventPatternKey<T>`; `fire`/`request` require an exact
   `EventKey<T>`, and a pattern handler can answer a concrete request.

## Package status

* Core version `4.0.0`, SDK `>=3.6.0 <4.0.0`; rxdart is not a dependency.
* Patterns: `event_bus_arch_patterns` 0.1.0 — `FSM`, `Scope`, `Command`.
* Adapters: `event_bus_arch_transport` 0.2.0, `event_bus_arch_mqtt` 0.2.0,
  `event_bus_arch_nats` 1.1.0; all depend on core `^4.0.0`.
* Tests: 243 in the core on the VM and 6 in Chrome (`test/` plus `dart test -p chrome
  test/web_smoke_test.dart`). Package suites: patterns 20, transport 26, NATS 24 (+10 skipped
  without a broker), MQTT 19 (+7 skipped without a broker).
* Web: the core bus, subscriptions, observability and the transport seam work; isolate APIs throw
  `UnsupportedError` (see [14](14-web.md)).
* Examples: `example/event_bus_arch_exmple.dart` (isolate),
  `example/event_bus_layers_example.dart` (layers),
  `example/event_bus_subscription_example.dart` (buffers, handler queue, cancellation, metrics),
  `example/event_bus_pool_example.dart` (WorkerPool),
  `packages/event_bus_arch_patterns/example/fsm_example.dart` (FSM),
  `packages/event_bus_arch_patterns/example/migration_target_example.dart`
  (the 4.0 form of the 3.x sample), `packages/event_bus_arch_nats/example/event_bus_arch_nats_example.dart`,
  `packages/event_bus_arch_mqtt/example/event_bus_arch_mqtt_example.dart`.
