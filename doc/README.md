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

## Quick summary

```dart
import 'package:event_bus_arch/event_bus_arch.dart';

final bus = EventBus();                        // or EventBus(isModelBus: true)

// receive
final sub = bus.subscribe<String>(onData: (e) => print(e));

// a handler that returns a result
bus.handlers.setHandler<String>(handler: (dto, lastData) async {
  dto.completer?.complete('processed: ${dto.data}');
});

// send: the address is type + paths, call parameters go in arguments
final result = await bus.send<String>('hello');             // 'processed: hello'

await sub.cancel();
await bus.dispose();
```

What you need to know right away:

1. **The type is part of the address.** `send<int>` and `setHandler<num>` are different topics
   ([07-caveats.md, item 1](07-caveats.md#1-the-type-in-a-topic-is-a-static-type-parameter)).
2. **`lastData` in a handler is the previous value** of the topic, while `dto.data` is the current one.
3. **`await bus.send(...)` is a sync point:** by the time it returns, listeners have already received
   the value, and a handler error arrives as an exception from `await`
   ([07-caveats.md, items 3 and 4](07-caveats.md#3-delivery-to-listeners-is-asynchronous)).
4. **`Scope.undo()` needs a history of at least two calls** (`maxLenForUndo >= 2`,
   by default 10).

## Package status

* Version: 3.0.0, SDK `>=3.0.0 <4.0.0`, dependencies: `intl`, `async`, `rxdart` (re-exported).
* Tests: 110 tests in `test/` (bus, nodes, isolates and layers, FSM, Scope/Command, Topic/EventDTO) —
  they pass.
* Examples: `example/event_bus_arch_exmple.dart` (isolate), `example/event_bus_fsm_example.dart`
  (FSM), `example/event_bus_layers_example.dart` (layers).
* The fix history of version 2.3.0 is in [07-caveats.md](07-caveats.md#what-was-fixed-in-230).
* What changed in 3.0.0 (the address) is in
  [07-caveats.md](07-caveats.md#what-changed-in-300) and [CHANGELOG.md](../CHANGELOG.md).
* What remains unchanged (intentional design) — items 1–2 in [07-caveats.md](07-caveats.md#what-remains-by-design).
