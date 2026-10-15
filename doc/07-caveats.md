# 07. What was fixed and what remains by design

[← 06. API reference](06-api-reference.md) · [Contents](README.md)

This document grew out of an analysis of version 2.2.0: the defects found (with runtime reproductions)
were fixed in **2.3.0**, while some of the behavior remains intentional design. Below is exactly what
changed and what you still need to remember.

---

## What was fixed in 2.3.0

| # | Topic | Was (2.2.0) | Now (2.3.0) |
|---|---|---|---|
| 1 | `Scope` with default settings | `maxLenForUndo: 0` → `Bad state: No element` on `initScope` and on every `call` | default is 10, `Command` clamps `maxLen < 1` to 1 |
| 2 | `EventBusIsolate` responses | were matched by `(topic, FIFO order)` — concurrent requests of the same type got mixed up | matched by request id |
| 3 | Worker readiness | `waitInit` completed on `SendPort`, that is before `onInit` ran; the first events were lost | the worker sends `_IsolateReady` after `onInit`; `createLayers` waits for the whole chain |
| 4 | `Command.undo()` / `Scope.undo()` | re-sent the current value | send the previous value from the history |
| 5 | The `lastData` parameter in the handler | was a copy of `dto.data` | the real previous value (accounting for `initialData`) |
| 6 | Error in the handler | `await send(...)` hung forever | the `completer` completes with an error, the sender gets the exception |
| 7 | Delivery order | listeners received the value only after `await send(...)` returned control; `cancel()` right after `send` swallowed the event | the value reaches the listeners before `send` completes |
| 8 | `dispose` | was not in the `EventBus` interface (a cast was needed), did not wait for the nodes, swallowed errors | in the interface, idempotent, waits for the nodes to close; after dispose `send`/`listen` throw `StateError` |
| 9 | `bus.handlers` | only the cast `bus as EventBusHandlers` | the `EventBus.handlers` getter |
| 10 | Moving handlers between buses | `addAllHandlerFromOtherBus` shared the same `EventNode`s; dead code `doOnCancel` without `listen` | nodes are copied, the old ones are closed, dead code removed |
| 11 | `Layer.close()` | threw `TypeError` inside a worker layer, did not close `current` | works in any layer, closes both branches and the local bus, idempotent |
| 12 | An event of a "foreign" type in a node | was silently lost, the sender waited forever | the `completer` completes with `null` |
| 13 | `EventDTO.toJson` / `toString` | `jsonEncode(data)` — crashed on non-JSON data | the data is returned as is, the caller does the encoding |
| 14 | `Topic.copy` | lost `path` | keeps `path`, `fragment` and `arguments` |
| 15 | A `Topic` with a dot in `target` | silently broke addressing (`a.b.int` collided with `a.int`) | `assert` in debug mode |
| 16 | `EventBusException` | was not exported, errors were bare `Exception`s | exported, `Topic`/`Scope` throw it |
| 17 | `FSM` | there was no way to unsubscribe from the bus | `FSM.dispose()`, a repeated `initFSM` does not multiply subscriptions |
| 18 | Typos in the public API | `queueLenght`, `initalData`, `shema`, `initalDataNeedExecute` | new names + the old ones as `@Deprecated` |
| 19 | `EventBusIsolate.send` | returned `null` if the isolate was not ready | before `waitInit` it throws `StateError`; type `Future<dynamic>` without null |
| 20 | Isolate initialization error | `waitInit` could never complete | an `Isolate.spawn`/`onInit` error arrives in `waitInit`, the isolate is freed |
| 21 | Hanging requests on close | `await send(...)` could never complete | `dispose` and worker death complete pending waits with `EventBusException` |

Tests for every item are in `test/event_node_test.dart`, `test/bus_api_test.dart`,
`test/command_scope_test.dart`, `test/fsm_test.dart`, `test/topic_dto_test.dart`,
`test/event_bus_isolate_protocol_test.dart`.

---

## What remains by design

These are not defects but properties of the model — keep them in mind when designing.

### 1. The type in a topic is a static type parameter

The event address is built from `T.runtimeType`, where `T` is the type parameter **at the call site**:

```dart
bus.handlers.setHandler<num>(handler: ...);

await bus.send<num>(1);       // handler called
await bus.send<int>(1);       // NOT called: event://all.int ≠ event://all.num
bus.haveHandler<String>();    // a separate topic even for String?
```

Build events on your own types (`class OrderPlaced`), not on `String`/`int`/`Map`, and
specify the type parameter explicitly when the value comes from a wide-typed variable.

### 2. A node and `lastData` live exactly until the last subscription

On the common bus, a node without a handler is removed together with its accumulated value as soon as
the last listener unsubscribes:

```dart
final sub = bus.listen<String>().listen((_) {});
await bus.send('keep?');
await sub.cancel();
bus.lastData<String>();   // null — the node is gone
```

For state, use `EventBus(isModelBus: true)` (nodes are not removed) or keep
a handler — a node with a handler survives subscription cancellations.

### 3. Delivery to listeners is asynchronous

After fix #7, `await bus.send(...)` guarantees that listeners **have already received** the value.
But if the send is not awaited (`bus.send(x);` without `await`) and the subscription is cancelled
right away, the event is lost — a broadcast stream does not buffer:

```dart
bus.send('x');            // no await
await sub.cancel();       // delivery has not happened yet
```

The rule is simple: if the event matters, await `send` or do not cancel the subscription in the same tick.

### 4. A handler error is visible to the sender — and in the zone, if nobody waits for it

`EventNode` completes the `completer` with an error, so:

```dart
try {
  await bus.send<int>(1);          // will throw the handler error
} catch (e) { ... }
```

If the sender does not await the result (`bus.send(1);`), the error becomes an unhandled async
error — in an application it shows up in the log/zone. This is a deliberate choice: "hanging silently" is worse than
"seeing the error".

### 5. One handler per topic

A repeated `setHandler` replaces the handler, `removeHandler` destroys the node entirely (together with
`lastData` and the listener streams — they get `onDone`). For several reactions to one event
use subscriptions (`listen`/`subscribe`) or different `target`/`path`.

### 6. Everything that crosses an isolate boundary must be sendable

`EventBusIsolate` and `Layer` send data between isolates: your own classes are sendable (copied),
closures, `StreamController`, open files are not. Initialization functions (`onInit`,
`fnInitLayer`) must be top-level/static.

### 7. One transition per (event, state) pair in the FSM

A repeated `addFSMTransition` with the same event type and the same `fromState` overwrites the previous one.
Events that arrive while a transition handler is running go into `ignoredEvents` and
**are not replayed** after it completes.

### 8. `Scope` owns its topic

`initScope` subscribes to the topic and creates a history. `disposeScope(removeHandler: true)`
(by default) removes the handler entirely — if the topic is shared with other
consumers, call `disposeScope(removeHandler: false)`.

---

## Checklist before use

* [ ] A decision is made for each topic: `isModelBus: true` (we keep state) or common (delivery only).
* [ ] Type parameters are explicit in `send`/`listen`/`setHandler`/`haveHandler`.
* [ ] Event types are custom classes, not `String`/`int`/`Map`.
* [ ] Handlers whose response is awaited complete the `completer` (including with an error) — or
      the send is deliberately one-way.
* [ ] `Scope.initScope` is called with `maxLenForUndo >= 2` if `undo` is planned.
* [ ] State lives in the model bus or behind a handler, so `lastData` is not lost on unsubscribe.
* [ ] After `await iso.waitInit` the worker is ready — no extra handshake is needed.
* [ ] The `iso.send(...)` future is not left without handling: when the bus is disposed, an in-flight request
      completes with `EventBusException`.
* [ ] `onInit`/`fnInitLayer` are top-level/static functions, event data is sendable.
* [ ] `Layer.close()` is called from the top level; a repeated call is safe.
* [ ] `dispose` is called on buses that are no longer needed (including the `current` of a layer).

## What next

* [01-architecture.md](01-architecture.md) — how everything works inside.
* [06-api-reference.md](06-api-reference.md) — the full list of API members.
