# event_bus_arch documentation

Detailed description of the `event_bus_arch` 3.0.0 package. The main README (in English) —
[../README.md](../README.md).

## Contents

| # | Document | What for |
|---|---|---|
| 01 | [Architecture](01-architecture.md) | How the package works: Topic, EventDTO, EventNode, EventBus, the event stream |
| 02 | [EventBus in practice](02-event-bus.md) | Sending and receiving events, handlers, addressing, recipes |
| 03 | [Isolates and layers](03-isolate-and-layers.md) | `EventBusIsolate`, `Layers`, exchange limits between isolates |
| 04 | [FSM](04-fsm.md) | Finite state machine on top of the bus: transitions, filters, ignoredEvents |
| 05 | [Scope and Command](05-scope-and-command.md) | State with history, the command pattern, `undo` pitfalls |
| 06 | [API reference](06-api-reference.md) | Every public type and member with signatures |
| 07 | [Pitfalls](07-caveats.md) | Known defects, reproductions, workarounds, checklist |
| 08 | [Transports](08-transports.md) | Running the bus over NATS / Redis / NanoMQ: address model, packaging, pitfalls |
| 09 | [event_bus_nats](09-event-bus-nats.md) | The implemented NATS transport: architecture, registries, reconnection, request/reply, limitations |
| 10 | [event_bus_mqtt](10-event-bus-mqtt.md) | The implemented MQTT 5 transport: grammar, wildcard difference, user properties, request/reply, limitations |

## Quick summary

```dart
import 'package:event_bus_arch/event_bus_arch.dart';

final bus = EventBus();                        // or EventBus(isModelBus: true)

// receive
final sub = bus.subscribe<String>(onData: (e) => print(e));

// a handler that returns a result
bus.handlers.setHandler<String>(handler: (dto, lastData) async {
  return 'processed: ${dto.data}';
});

// send: the address is type + paths, call parameters go in arguments
// a request waits for the handler result
final result = await bus.request<String>('hello');          // 'processed: hello'

// a fire-and-forget event returns whether anyone is listening
final delivered = bus.fire<String>('hello');

await sub.cancel();
await bus.dispose();
```

What you need to know right away:

1. **The type is part of the address.** `request<int>` and `setHandler<num>` are different topics
   ([07-caveats.md, item 1](07-caveats.md#1-the-type-in-a-topic-is-a-static-type-parameter)).
2. **`lastData` in a handler is the previous value** of the topic, while `dto.data` is the current one.
3. **`request` is a sync point:** by the time `await bus.request(...)` returns, listeners have
   already received the value, and a handler error arrives as an exception from `await`
   ([07-caveats.md, items 3 and 4](07-caveats.md#3-delivery-to-listeners-is-asynchronous)).
   `fire` does not wait: it delivers to listeners and returns whether the event
   was accepted. A request handler is a responder for `request`; `fire` does not
   invoke it. Wildcard paths are rejected by `request`.
4. **`Scope.undo()` needs a history of at least two calls** (`maxLenForUndo >= 2`,
   by default 10).
5. **Wildcards are local.** `*` matches one path token, `>` one or more trailing tokens.
   `fire`/`request` calls must be concrete; a pattern handler can answer a concrete request.

## Package status

* Version: 3.0.0, SDK `>=3.6.0 <4.0.0`, dependencies: `intl`, `async`, `rxdart` (re-exported).
* Tests: 131 tests in `test/` (bus, nodes, isolates and layers, FSM, Scope/Command, Topic/EventDTO,
  wildcards) — they pass. The NATS transport has its own suite in `packages/event_bus_nats/test`.
* Examples: `example/event_bus_arch_exmple.dart` (isolate), `example/event_bus_fsm_example.dart`
  (FSM), `example/event_bus_layers_example.dart` (layers),
  `packages/event_bus_nats/example/event_bus_nats_example.dart` (NATS).
* The fix history of version 2.3.0 is in [07-caveats.md](07-caveats.md#what-was-fixed-in-230).
* What changed in 3.0.0 (the address) is in
  [07-caveats.md](07-caveats.md#what-changed-in-300) and [CHANGELOG.md](../CHANGELOG.md).
* What remains unchanged (intentional design) — items 1–2 in [07-caveats.md](07-caveats.md#what-remains-by-design).
