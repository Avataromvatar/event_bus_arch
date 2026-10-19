# 07. What was fixed and what remains by design

[← 06. API reference](06-api-reference.md) · [Contents](README.md)

This document grew out of an analysis of version 2.2.0: the defects found (with runtime reproductions)
were fixed in **2.3.0**, and the address model and the publish/handler protocol were reworked in
**3.0.0**. Below is exactly what changed and what you still need to remember.

---

## What changed in 3.0.0

The address lost a dimension and the request protocol was rebuilt. `Topic` is no longer URI-like:
there is no `scheme`, no `target`, no `fragment`, and `arguments` moved from the address to the
event envelope. `send` was split into `fire` and `request`, and the completer disappeared.

| # | Topic | Was (2.3.0) | Now (3.0.0) |
|---|---|---|---|
| 1 | The address shape | `event://<target>.<type><path>` | `<type><separator><paths...>` |
| 2 | `target` | a second addressing dimension, `all` by default | **removed** — the first path token takes its place |
| 3 | `fragment` | a label on the topic, outside the routing key | **removed** — nothing replaced it |
| 4 | `arguments` | `Map` on the `Topic`, read as `dto.topic.arguments` | on the `EventDTO`, read as `dto.arguments` |
| 5 | `scheme` / `shema` | always `'event'` | **removed** — it distinguished nothing |
| 6 | `path` (a `String` with a leading `/`) | `path: '/in'` | `paths` (a `List<String>`): `paths: ['in']` |
| 7 | The type in the address | lowercased and percent-encoded by `Uri` | `'$T'` normalised to a subject-safe token: `List<int>` → `List(int)` |
| 8 | `topic`, `topicWithFragment`, `fullTopic` | three strings | one: `topic` (`toString()` returns it) |
| 9 | `Topic.parse` | parsed a URI | splits on the separator; an empty type is an `EventBusException` |
| 10 | The separator | fixed (`.` inside the host, `/` in the path) | a parameter, falling back to `EventBus.defaultTopicPathSeparator` |
| 11 | Topic equality | `other is EventTopicImpl` | `other is Topic` — any implementation with the same key is equal |
| 12 | The deprecated aliases | `queueLenght`, `initalData`, `initalDataNeedExecute`, `shema` | **removed**; only `changeStateByEvent` remains deprecated |
| 13 | Publishing | one `send`, returning `Future<dynamic>?` | `fire` returns `bool`; `request` returns a future with the handler result |
| 14 | Handler result | `EventDTO.completer` completed manually | the handler **returns** the value; throwing is an error |
| 15 | Who calls a handler | `send` delivered the event to the node's handler | only `request` calls a handler; `fire` is listener-only |
| 16 | No responder | `send` returned `null`; "no handler" was indistinguishable from "handler returned null" | `request` throws `NoHandlerException` |
| 17 | `lastData` | bus method `lastData<T>()`; node field `lastData` | `currentData<T>()` and `EventNode.currentData` |
| 18 | Wildcards | none — routing was exact | `*` (one token) and `>` (one or more trailing tokens) in listener/handler paths |
| 19 | Handler resolution | one handler per exact topic | exact → most specific pattern; a pattern may answer concrete requests |
| 20 | Request paths | wildcards silently addressed a literal topic | `fire`/`request` reject wildcard paths with `EventBusException` |
| 21 | `removeHandler` | removed the node and the listener streams | removes the registration; the node stays while listeners or a transport pin exist |
| 22 | `Topic.toString()` | `fullTopic` | the routing key — `Instance of 'TopicImpl'` before the override was restored |

### Migration table

| 2.3.0 | 3.0.0 |
|---|---|
| `await bus.send(x)` (waits for a result) | `await bus.request(x)` |
| `bus.send(x)` / `await bus.send(x)` (one-way) | `bool delivered = bus.fire(x)` |
| `send(x, path: '/in')` | `fire(x, paths: ['in'])` / `request(x, paths: ['in'])` |
| `send(x, target: 'warehouse', path: '/in')` | `fire(x, paths: ['warehouse', 'in'])` |
| `send(x, fragment: 'f')` | *removed* — send it in `arguments` or in the data |
| `dto.completer?.complete(v)` in a handler | `return v;` |
| `dto.completer?.completeError(e, s)` in a handler | `throw e;` |
| `lastData<T>(path: '/in')` | `currentData<T>(paths: ['in'])` |
| `EventNode.lastData` | `EventNode.currentData` |
| `EventNode.send(dto)` (internal) | `EventNode.deliver(dto)` |
| `setHandler<T>(path: '/in')` | `setHandler<T>(paths: ['in'])` |
| `listen<T>(path: '/in')`, `subscribe<T>(path: '/in')` | `listen<T>(paths: ['in'])` |
| `haveHandler<T>(path: '/in')`, `haveListener<T>(path: '/in')` | `haveHandler<T>(paths: ['in'])` |
| `Command(bus, path: '/in')` | `Command(bus, paths: ['in'])` |
| `initScope(bus, path: '/in')` | `initScope(bus, paths: ['in'])` |
| `addFSMTransition<E>(a, b, eventTarget: t, eventPath: p, eventFragment: f, arguments: m)` | `addFSMTransition<E>(a, b, eventPaths: [...])` |
| `Topic.create<T>(target:, path:, fragment:, arguments:)` | `Topic.create<T>(paths:, separator:)` |
| `Topic.create<T>(path: '/p').path` | `Topic.create<T>(paths: ['p']).paths` |
| `Topic.parse('event://all.string/origin')` | `Topic.parse('String.origin')` |
| `topic.target`, `topic.host` | *removed* — the first token of `topic.paths` |
| `topic.fullTopic`, `topic.topicWithFragment` | `topic.topic` |
| `topic.arguments` | `dto.arguments` |
| `topic.copy(target:, scheme:, fragment:, arguments:)` | `topic.copy(paths:, separator:)` |
| `EventDTO(x, target:, path:, fragment:)` | `EventDTO(x, paths:, separator:, arguments:)` |
| `command.queueLenght` | `command.queueLength` |
| `setHandler<T>(initalData: v)` | `setHandler<T>(initialData: v)` |
| `initScope(bus, initalData: v, initalDataNeedExecute: b)` | `initScope(bus, initialData: v, initialDataNeedExecute: b)` |
| `EventBusIsolate(onInit: f, initalData: v)` | `EventBusIsolate(onInit: f, initialData: v)` |

`target: 'x', path: '/y'` becomes `paths: ['x', 'y']` and produces the same kind of address
(`String.x.y`), so the address part of the migration is mechanical. What is **not** mechanical:
an address that used `target` as a separate dimension loses the guarantee that it was exactly one
token, because a path token is free-form.

The publish part is a semantic choice, not a rename: decide for each call whether it is a
one-way event (`fire`) or an answered request (`request`). A handler no longer sees `fire`
events, so code that relied on `send` running a handler must use `request`.

---

## What was fixed in 2.3.0

| # | Topic | Was (2.2.0) | Now (2.3.0) |
|---|---|---|---|
| 1 | `Scope` with default settings | `maxLenForUndo: 0` → `Bad state: No element` on `initScope` and on every `call` | default is 10, `Command` clamps `maxLen < 1` to 1 |
| 2 | `EventBusIsolate` responses | were matched by `(topic, FIFO order)` — concurrent requests of the same type got mixed up | matched by request id |
| 3 | Worker readiness | `waitInit` completed on `SendPort`, that is before `onInit` ran; the first events were lost | the worker sends `_IsolateReady` after `onInit`; `createLayers` waits for the whole chain |
| 4 | `Command.undo()` / `Scope.undo()` | re-sent the current value | send the previous value from the history |
| 5 | The handler's previous-value parameter | was a copy of `dto.data` | the real previous value (accounting for `initialData`) |
| 6 | Error in the handler | `await send(...)` hung forever | the sender gets the error (in 2.3.0 via the completer; in 3.0.0 via the returned future) |
| 7 | Delivery order | listeners received the value only after `await send(...)` returned control; `cancel()` right after `send` swallowed the event | the value is added to the node stream before the handler future is awaited |
| 8 | `dispose` | was not in the `EventBus` interface (a cast was needed), did not wait for the nodes, swallowed errors | in the interface, idempotent, waits for the nodes to close; after dispose `fire`/`listen` throw `StateError` |
| 9 | `bus.handlers` | only the cast `bus as EventBusHandlers` | the `EventBus.handlers` getter |
| 10 | Moving handlers between buses | `addAllHandlerFromOtherBus` shared the same `EventNode`s; dead code `doOnCancel` without `listen` | nodes are copied, the old ones are closed, dead code removed |
| 11 | `Layer.close()` | threw `TypeError` inside a worker layer, did not close `current` | works in any layer, closes both branches and the local bus, idempotent |
| 12 | An event of a "foreign" type in a node | was silently lost, the sender waited forever | the value is ignored; `request` reports no accepting handler |
| 13 | `EventDTO.toJson` / `toString` | `jsonEncode(data)` — crashed on non-JSON data | the data is returned as is, the caller does the encoding |
| 14 | `Topic.copy` | lost `path` | keeps the paths (in 3.0.0: the type, the paths and the separator) |
| 15 | An address part containing the separator | silently broke addressing (`a.b.int` collided with `a.int`) | the separator is a parameter, and the collision is documented (see [01-architecture.md](01-architecture.md#key-point-topic-equality)) |
| 16 | `EventBusException` | was not exported, errors were bare `Exception`s | exported, `Topic`/`Scope` throw it |
| 17 | `FSM` | there was no way to unsubscribe from the bus | `FSM.dispose()`, a repeated `initFSM` does not multiply subscriptions |
| 18 | Typos in the public API | `queueLenght`, `initalData`, `shema`, `initalDataNeedExecute` | correct names in 2.3.0; the deprecated aliases were removed in 3.0.0 |
| 19 | `EventBusIsolate.send` | returned `null` if the isolate was not ready | before `waitInit` it throws `StateError`; type `Future<dynamic>` without null |
| 20 | Isolate initialization error | `waitInit` could never complete | an `Isolate.spawn`/`onInit` error arrives in `waitInit`, the isolate is freed |
| 21 | Hanging requests on close | `await send(...)` could never complete | `dispose` and worker death complete pending waits with `EventBusException` |
| 22 | `Topic` with no paths (3.0.0) | `Bad state: No element` from `paths.reduce` — **every** call without paths crashed | the routing key is the type alone |
| 23 | `Topic.parse` (3.0.0) | `'$l[0]'` interpolated the whole list, so `type` was `'[String, a, b][0]'` | the type is the first token |
| 24 | `arguments` in a handler (3.0.0) | the node and the isolate rebuilt the DTO without them, so `dto.arguments` was always null | moved along with the event |

Tests for every item are in `test/event_node_test.dart`, `test/bus_api_test.dart`,
`test/command_scope_test.dart`, `test/fsm_test.dart`, `test/topic_dto_test.dart`,
`test/naming_test.dart`, `test/event_bus_isolate_protocol_test.dart`, and `test/wildcard_test.dart`.

---

## What remains by design

These are not defects but properties of the model — keep them in mind when designing.

### 1. The type in a topic is a static type parameter

The event address is built from the type parameter `T` **at the call site**:

```dart
bus.handlers.setHandler<num>(handler: ...);

bus.fire<num>(1);            // the listener on num sees it
bus.request<int>(1);         // NoHandlerException: int ≠ num
bus.haveHandler<String>();   // a separate topic even for String?
```

Build events on your own types (`class OrderPlaced`), not on `String`/`int`/`Map`, and
specify the type parameter explicitly when the value comes from a wide-typed variable.

Because the type is `'$T'`, a class rename silently changes the address — the same hazard a
transport has with `runtimeType` (see [08-transports.md §4.1](08-transports.md#41-truntimetype-cannot-be-a-wire-address)).

### 2. A node and `currentData` live exactly until the last subscription

On the common bus, a node without a handler is removed together with its accumulated value as soon as
the last listener unsubscribes:

```dart
final sub = bus.listen<String>().listen((_) {});
bus.fire('keep?');
await sub.cancel();
bus.currentData<String>();   // null — the node is gone
```

For state, use `EventBus(isModelBus: true)` (nodes are not removed) or keep
a handler — a node with a handler survives subscription cancellations. A transport node is
pinned by `KeepAliveNode` while its broker subscription exists.

### 3. Delivery to listeners is asynchronous

`fire` adds the value to a broadcast stream and returns immediately. Listener callbacks run in a
microtask after the current synchronous block. If the subscription is cancelled right away, the
event is lost — a broadcast stream does not buffer:

```dart
bus.fire('x');
await sub.cancel();       // delivery has not happened yet
```

The same is true for `request`: listeners are notified while the request is dispatched, before the
handler future completes.

### 4. A handler error is visible to the request sender

A handler's returned future is the request future, so:

```dart
try {
  await bus.request<int>(1);       // will throw the handler error
} catch (e) { ... }
```

If the sender does not await the result (`bus.request(1);`), the error becomes an unhandled async
error — in an application it shows up in the log/zone. This is a deliberate choice: "hanging
silently" is worse than "seeing the error". `fire` never invokes a handler, so it cannot produce
a handler error.

### 5. One handler per topic

A repeated `setHandler` replaces the handler. `removeHandler` removes the registration; the node
and its listener streams stay alive while listeners (or a transport pin) exist. For several
reactions to one event use subscriptions (`listen`/`subscribe`) or different `paths`.

### 6. A path token must not contain the separator

The routing key is a string, so `paths: ['a.b']` and `paths: ['a', 'b']` are the same node:

```dart
Topic.create<String>(paths: ['a.b']) == Topic.create<String>(paths: ['a', 'b']);   // true
```

If a token has to contain a dot, address the topic with another separator
(`separator: '/'`) — and pass the same separator everywhere that addresses the topic.

### 7. Everything that crosses an isolate boundary must be sendable

`EventBusIsolate` and `Layer` send data between isolates: your own classes are sendable (copied),
closures, `StreamController`, open files are not. Initialization functions (`onInit`,
`fnInitLayer`) must be top-level/static.

### 8. One transition per (event, state) pair in the FSM

A repeated `addFSMTransition` with the same event type and the same `fromState` overwrites the previous one.
Events that arrive while a transition handler is running go into `ignoredEvents` and
**are not replayed** after it completes. Transitions are registered by exact topic: wildcard
`eventPaths` are not matched against concrete events.

### 9. `Scope` owns its topic

`initScope` subscribes to the topic and creates a history. `disposeScope(removeHandler: true)`
(by default) removes the handler; if the topic is shared with other consumers, call
`disposeScope(removeHandler: false)`.

### 10. Wildcard requests are not supported

`fire` and `request` address concrete topics. A wildcard in `paths` throws an
`EventBusException`; patterns belong to listener nodes and handler registrations. A request
answered by a pattern handler still names a concrete topic.

### 11. Brokers are at-most-once by default

The transport packages keep the local API, but a broker adds its own delivery model. NATS core is
at-most-once; MQTT uses QoS 0 by default. See
[09-event-bus-nats.md](09-event-bus-nats.md#10-guarantees-and-limitations) and
[10-event-bus-mqtt.md](10-event-bus-mqtt.md#10-guarantees-and-limitations).

---

## Checklist before use

* [ ] A decision is made for each topic: `isModelBus: true` (we keep state) or common (delivery only).
* [ ] Each publish is classified: one-way (`fire`) or answered (`request`).
* [ ] Handlers **return** their response (or throw), and `request` futures are awaited.
* [ ] Type parameters are explicit in `fire`/`request`/`listen`/`setHandler`/`haveHandler`.
* [ ] Event types are custom classes, not `String`/`int`/`Map`.
* [ ] A path token never contains the separator, or the topic is addressed with another one.
* [ ] `fire`/`request` address concrete topics; wildcards are only in listener/handler paths.
* [ ] `Scope.initScope` is called with `maxLenForUndo >= 2` if `undo` is planned.
* [ ] State lives in the model bus or behind a handler, so `currentData` is not lost on unsubscribe.
* [ ] After `await iso.waitInit` the worker is ready — no extra handshake is needed.
* [ ] The `iso.request(...)` future is not left without handling: when the bus is disposed, an in-flight request
      completes with `EventBusException`.
* [ ] `onInit`/`fnInitLayer` are top-level/static functions, event data is sendable.
* [ ] `Layer.close()` is called from the top level; a repeated call is safe.
* [ ] `dispose` is called on buses that are no longer needed (including the `current` of a layer).

## What next

* [01-architecture.md](01-architecture.md) — how everything works inside.
* [06-api-reference.md](06-api-reference.md) — the full list of API members.
