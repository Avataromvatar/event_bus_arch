# 03. Isolates and Layers: EventBusIsolate and Layers

[← 02. EventBus](02-event-bus.md) · [Contents](README.md) · [Next: FSM →](04-fsm.md)

## Why

An isolate is the only way to take a second core in Dart. `EventBusIsolate` gives a bus that looks
like a regular one, but events go to a worker isolate and come back from it. On top of it, `Layers`
builds chains of layers: `main ↔ isolate₂ ↔ isolate₁ ↔ isolate₀`, where each isolate is a separate
"floor" of the application with its own bus.

## EventBusIsolate

```dart
class EventBusIsolate extends EventBusImpl {
  EventBusIsolate({
    required FutureOr<void> Function(EventBus bus, Object? initialData) onInit,   // may be async
    Object? initialData,
  });

  Future<bool> get waitInit;   // completes when the worker has handed over the SendPort
  bool get isInit;             // true if the SendPort has been received
  Future<void> dispose();      // close the streams, the port, and kill the isolate
}
```

### Initialization

```dart
import 'dart:isolate';
import 'package:event_bus_arch/event_bus_arch.dart';

Future<void> main() async {
  final iso = EventBusIsolate(onInit: _initWorker, initialData: 'prefix');
  await iso.waitInit;                       // must wait for it
  ...
}

// WARNING: this runs IN A DIFFERENT ISOLATE.
// The function must be top-level / static — closures cannot cross the isolate boundary.
Future<void> _initWorker(EventBus bus, Object? initialData) async {
  final prefix = initialData as String;
  await _heavyInit();                       // async initialization is fine too
  bus.subscribe<String>(onData: (e) => bus.send('$prefix: $e'));
  bus.handlers.setHandler<int>(handler: (dto, lastData) async {
    dto.completer?.complete(dto.data * 2);
  });
}
```

`onInit` receives **the bus that lives inside the isolate** plus arbitrary initial data. Everything
the worker needs is set up here: handlers, subscriptions, state. The function may be async.

### Worker readiness

> **`waitInit` completes only after `onInit` has finished** (including all `await`s inside it). An
> event sent right after `await iso.waitInit` is guaranteed to reach the worker's handlers — no
> separate handshake is needed.

* `iso.isInit` — a synchronous check: `true` if the worker has already been initialized;
* if the isolate failed to start or `onInit` threw, `waitInit` completes with an **error**
  (`EventBusException`), and the isolate is released;
* `ping()` only checks worker liveness ("does it answer"), not readiness: messages are read by an
  internal listener that is alive even before `onInit`.

```dart
final iso = EventBusIsolate(onInit: _initWorker);
await iso.waitInit;               // ready
iso.isInit;                       // true
await iso.ping();                 // true — the worker is alive (for example, before reusing it)
```

### Sending

```dart
final iso = EventBusIsolate(onInit: _initWorker);
await iso.waitInit;

// 1. Request-response: whatever the worker put into the completer comes back
final doubled = await iso.send<int>(21);              // 42

// 1a. Before waitInit, send throws a StateError — you can no longer silently do nothing

// 2. A one-way event: the usual common scenario
await iso.send<String>('ping');

// 3. Receiving events sent FROM the worker
iso.subscribe<String>(onData: (e) => print('from worker: $e'));
```

On the main side, `send` **does not look for a local node** — it always goes to the isolate (this is
an overridden implementation). Events coming from the worker, in turn, are dispatched to the local
nodes of the main isolate: listeners and handlers.

### How it works internally

```text
   MAIN ISOLATE                                   WORKER ISOLATE
 ┌────────────────────────┐                     ┌────────────────────────────┐
 │ EventBusIsolate        │  SendPort ────────► │ ReceivePort                │
 │  _toEBSender ──────────┼─────────────────────┼─► _EventBusForIsolate      │
 │                        │   EventDTO          │     _eventsMap, handlers   │
 │  _receivePort ◄────────┼─────────────────────┼── SendPort                 │
 │  _request:             │   (Topic, value)    │   _request:                │
 │    Topic → [Completer] │   EventDTO          │     Topic → [Completer]    │
 └────────────────────────┘                     └────────────────────────────┘
```

* A `Completer` is **never passed across the isolate boundary**. The sender puts its `Completer`
  into `_requests[id]`, and the worker sends back a response with the same `id`; the response pulls
  the right `Completer` from the map, so the order of responses does not matter.
* An `EventDTO` going through the port travels **without** a `completer` — the result travels as a
  separate message.
* When the worker receives an event, it creates its own copy of the DTO with a new `Completer`, and
  sends the result of ITS OWN handler back up. Main behaves in exactly the same way when it receives
  an event from the worker: if there is a local handler for it, its result goes back to the isolate.

### Guarantees and limitations

| Rule | Consequence |
|---|---|
| Exactly one response per request, correlated by `id` | Concurrent requests of the same type each get their own result; the order of responses does not matter |
| No node for the topic in the isolate | The request resolves with `null` (not an error and not a hang) |
| An exception in a worker handler | Reaches the sender as an error from `await iso.send(...)` |
| `dispose` or worker death with a request in flight | The wait completes with an `EventBusException`; there are no forever-pending `await`s |
| Only "sendable" objects can cross the isolate | Closures, `StreamController`s, open files and the like cannot be sent |
| `await iso.send(...)` returns the handler's result, not event ordering | The result may arrive later than events sent by the worker inside the handler (the source comment warns about this explicitly) |
| The worker does not know about `isModelBus` | The bus inside the worker is always common |

### Shutdown

```dart
await iso.dispose();
```

`dispose` is idempotent: it completes all pending requests with an error, closes `allEventStream`,
the main-bus nodes and the `ReceivePort`, then kills the isolate. After it is closed, `send` throws
a `StateError` and `ping()` returns `false`. If the worker dies on its own, pending waits also
complete with an error.

## Layers — multi-layer setups

`Layers.createLayers` builds a chain of isolates. Each element of the list is a tuple
`(init function, initial data, isModelBus)`:

```dart
typedef fnInitLayer = FutureOr<void> Function(Layer layer, Object? initialData);

static Future<Layer> createLayers(
  List<(fnInitLayer, Object?, bool)> layers, {
  bool currentIsModelBus = true,
});
```

### What each layer gets

```text
Main isolate (top)
  layer.current == EventBus(isModelBus: currentIsModelBus)   ← the layer's local bus
  layer.top     == null                                      ← nothing above
  layer.bottom  == EventBusIsolate → first worker

Worker N (layers[N] ran exactly here)
  layer.current == EventBus(isModelBus: layers[N].$3)        ← the layer's local bus
  layer.top     == EventBus leading to the layer above       ← up the chain
  layer.bottom  == EventBusIsolate → the next worker         ← or null if this is the last layer
```

Rules:

* `layer.top!.send(...)` — the event goes **up**;
* `layer.bottom!.send(...)` — the event goes **down**;
* `layer.current` — the layer's local bus for internal logic;
* sending down/up is asymmetric: `send` to `bottom`/`top` goes through the isolate branch and
  returns the handler's result, while the layer's "own" events live in `current`;
* the init function runs **inside** the corresponding isolate and must be top-level/static (see
  below).

### Example: two worker layers

```dart
import 'dart:isolate';
import 'package:event_bus_arch/event_bus_arch.dart';

class Ping { final int count; Ping(this.count); }

Future<void> main() async {
  // main ↔ isolate[A] ↔ isolate[B]
  // createLayers completes when ALL layers in the chain are initialized,
  // so events can be sent right away
  final layer = await Layers.createLayers([
    (_initMiddle, null, true),
    (_initBottom, null, true),
  ]);

  // create the subscription for the final event BEFORE sending, or you may miss it:
  // node streams are broadcast and unbuffered
  final answerFuture = layer.bottom!.listen<Ping>().first;
  layer.bottom!.subscribe<Ping>(onData: (e) => print('back to top: ${e.count}'));

  layer.bottom!.send(Ping(0));

  final answer = await answerFuture;
  print('result: ${answer.count}');       // 3

  await layer.close();
}

// runs in the MIDDLE isolate (may be async — createLayers waits for it)
Future<void> _initMiddle(Layer layer, Object? _) async {
  layer.top!.subscribe<Ping>(onData: (e) => layer.bottom!.send(Ping(e.count + 1)));
  layer.bottom!.subscribe<Ping>(onData: (e) => layer.top!.send(Ping(e.count + 1)));
}

// runs in the BOTTOM isolate
void _initBottom(Layer layer, Object? _) {
  layer.top!.subscribe<Ping>(onData: (e) => layer.top!.send(Ping(e.count + 1)));
}
```

An error in any init function (including one thrown from an `await`) comes out of
`Layers.createLayers` as an `EventBusException`; if needed, bound the wait with the `timeout`
parameter.

Data flow in this example:

```text
main  send(Ping(0))
        │  layer.bottom!.send
        ▼
isolate[A]  top receives 0 → bottom!.send(Ping(1))
        ▼
isolate[B]  top receives 1 → top!.send(Ping(2))
        ▲
isolate[A]  bottom receives 2 → top!.send(Ping(3))
        ▲
main  receives 3
```

### Shutdown

```dart
await layer.close();     // close the layer's bottom and top isolate bridges
```

`close()` closes `top`, `bottom` and `current` — that is, it shuts down the isolate branches and the
layer's local bus. It works in any layer (including inside a worker) and is safe to call again: the
`top`/`bottom` fields are set to null, and `dispose` is idempotent.

### Requirements for init functions

* Top-level or `static` functions only: closures and bound methods cannot cross the isolate
  boundary.
* Everything that goes into the isolate (`Layer`, `EventDTO`, event data) must be sendable. Your own
  classes — yes (they are copied); closures and system resources — no.
* The function is called asynchronously, after the isolate has handed over the `SendPort`; the
  neighboring layer's `waitInit` is guaranteed to be complete by the time of the call only for the
  layer below.

## Full example

Working examples in the package:

* `example/event_bus_arch_exmple.dart` — EventBusIsolate: subscriptions, a handler with `arguments`,
  events in both directions;
* `example/event_bus_layers_example.dart` — two worker layers with an event chain
  (output: `SEND 0 → FROM MIDDLE TO BOTTOM 0->1 → FROM BOTTOM TO MIDDLE 1->2 →
  FROM MIDDLE TO TOP 2->3 → GET 3`).

## What's next

* [04-fsm.md](04-fsm.md) — a state machine on top of the bus.
* [07-caveats.md](07-caveats.md) — pitfalls of the isolate bus.
