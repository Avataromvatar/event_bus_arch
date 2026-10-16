# 01. Architecture

[← Table of contents](README.md) · [Next: EventBus in practice →](02-event-bus.md)

`event_bus_arch` is an event-driven framework for Dart/Flutter. All interaction between
components goes through events that have an **address (Topic)**, **data**, and, optionally,
**a back channel for the result** (`Completer`). Isolates, layers, a finite state machine,
and scope/command are built on top of the bus.

## What the package consists of

| Layer | Type | Role |
|---|---|---|
| Addressing | `Topic` | Event address: a type plus a path, `OrderPlaced.warehouse.in` |
| Event envelope | `EventDTO<T>` | Data + topic + `arguments` + `Completer` for the response |
| Routing cell | `EventNode<T>` | Stores the handler and the last data for a specific topic |
| Registry | `EventBus` / `EventBusMixin` | `Map<Topic, EventNode>` + a stream of all events |
| Isolate boundaries | `EventBusIsolate`, `Layer`, `Layers` | Forwarding events between isolates and multi-isolate chains |
| On top of the bus | `FSM`, `Scope`, `Command`, `EventBusLogger` | State machine, state with history, logging |

## The flow of a single event

```text
   call                    EventBus.send<T>(data, paths:, separator:, arguments:)
     │                                        │
     │                                        ▼
     │                        EventDTO<T> {topic, data, arguments, completer}
     │                                        │
     │                            node lookup by dto.topic in _eventsMap
     │                                        │
     ├───────────────┬────────────────────────┴──────────────────────┐
     │               │                                               │
     ▼               ▼                                               ▼
 node found    no node, isModelBus: true                  no node, common bus
     │          the node is created "on the fly"             no node is created
     ▼               │                                               │
 EventNode.send(dto) │                                               │
     │               ▼                                               ▼
     ├─ lastData = data                        allEventStream.add((dto, false))
     │                                               → send() will return null
     ├─ the node value stream → listen<T>() / subscribe<T>()   ← listeners receive the data first
     │
     └─ the node event stream → handler(dto, previousLastData)
              ├─ completer.complete(result)   ← what send() will return
              ├─ if the handler did not complete completer → completer.complete(null)
              └─ if the handler threw → completer.completeError(...)
                              allEventStream.add((dto, true))
```

## 1. Topic — the event address

An address is a **type** followed by a **path**:

```text
String.a.b
  │    │
  │    └── paths: the free-form part, one token per path element
  └─────── type: the static type parameter T of the call
```

The routing key is the type and the paths joined by the **separator** (`.` by default):

```dart
Topic.create<String>();                                   // String
Topic.create<String>(paths: ['origin']);                  // String.origin
Topic.create<int>(paths: ['warehouse', 'in']);            // int.warehouse.in
Topic.create<int>(paths: ['a', 'b'], separator: '/');     // int/a/b
Topic.fromParametr(type: MyEvent);                         // when the type is a runtime value
Topic.parse('String.origin');                             // parsing from a string
```

`Topic.create<T>` takes the type from the **static type parameter**, so the same rules as
everywhere else on the bus apply: `create<int>` and `create<num>` are different addresses.

### Key point: topic equality

`TopicImpl` compares only `topic` —

```dart
bool operator ==(Object other) => other is Topic && other.topic == topic;
int get hashCode => Object.hashAll([topic]);
```

and `topic` is the type and the paths joined by the separator. Consequences:

* `setHandler<String>(paths: ['p'])` and `send('x', paths: ['p'], arguments: {'a': '1'})`
  are the **same** topic, and the handler will be called (verified). `arguments` are not part
  of the address.
* The comparison accepts **any** `Topic` implementation, so an alternative implementation
  with the same routing key finds the same node (this was `other is EventTopicImpl` in 2.x).
* A path token must not contain the separator: `paths: ['a.b']` and `paths: ['a', 'b']` build
  the same `String.a.b` and are therefore the same node. Use `separator: '/'` if a token has
  to contain a dot.

### Additional properties

| Getter | Value |
|---|---|
| `topic` | `String.a.b` — the routing key |
| `type` | the first token: `String` |
| `paths` | the path tokens: `['a', 'b']`, empty when there is no path |
| `separator` | the string joining them: `.` by default |
| `copy({paths, separator})` | a copy with those replaced; the type is kept |
| `toString()` | returns `topic` |

### The type name in the topic

The type is `'$T'` of the static type parameter — the plain type name, as written:

* the case is **not** lowercased: `String` stays `String` (in 2.x it became `string`);
* nothing is percent-encoded: `List<int>` is `List<int>`, and `String?` is `String?`
  (in 2.x these were `list%3Cint%3E` and `string%5E`);
* the type is still **part of the address**, not just an annotation — details and examples are
  in [07-caveats.md, item 1](07-caveats.md#1-the-type-in-a-topic-is-a-static-type-parameter).

### The separator

Every method that takes an address takes `separator`, and falls back to
`EventBus.defaultTopicPathSeparator` (`.` by default) when it is not passed:

```dart
final bus = EventBus();
bus.handlers.setHandler<int>(paths: ['a', 'b'], handler: ...);         // int.a.b
await bus.send<int>(1, paths: ['a', 'b']);                             // int.a.b — found
await bus.send<int>(1, paths: ['a', 'b'], separator: '/');             // int/a/b — another node
```

The separator is part of the address only through the string it produces: two topics with
different separators are equal when their `topic` strings are equal.

## 2. EventDTO — the event envelope

```dart
abstract class EventDTO<T> {
  Topic get topic;
  T get data;
  Map<String, String>? get arguments;   // parameters of this call; not part of the address
  Completer? get completer;             // the response channel; may be null
}
```

* `arguments` are the parameters of a specific call. They do not select a node — two calls
  that differ only in `arguments` reach the same handler. In 2.x they lived on `Topic` as
  `dto.topic.arguments`; they are payload, so they live on the envelope.
* `completer` is how the handler returns a result to the sender. If the handler did not call
  `completer.complete(...)`, the node completes it with `null` right after the handler finishes.
* If the handler throws, `completer` completes with an **error** — the sender receives it from
  `await send(...)`.
* If the node **has no handler** (only listeners, or the node was created by the model bus),
  `completer` completes with `null` immediately, waiting for nothing.
* `EventDTOImpl` implements `==`/`hashCode` over the `(topic, data)` pair and supports
  `toJson()`/`fromJson()`. `toJson` returns the data as is (without `jsonEncode`) — the caller
  does the encoding. `arguments` are not part of the JSON form.

## 3. EventNode — the topic cell

`EventNode<T>` is everything the bus knows about a specific topic:

```dart
class EventNode<T> {
  T? lastData;                              // the last sent value
  Handler<T>? handler;                      // the handler (may be absent)
  bool get isDisposed;                      // whether the event stream is closed
  bool get isHaveHandler;
  void send(EventDTO dto);                  // put the event into the node
  Future<void> dispose();                   // close both streams
}
```

Inside there are **two broadcast streams**:

| Stream | What it carries | Who listens |
|---|---|---|
| `_streamController` (private) | `EventDTO` | the node itself: calls `handler` |
| `_streamControllerValue` (private) | `data` | `listen<T>()` / `subscribe<T>()` subscribers |

Processing order in the node:

1. `dto.data is T` is checked — if it does not match, `completer` completes with `null`
   (the event does not "hang").
2. `lastData = dto.data` — synchronously, before the event goes to the streams.
3. The event stream gets the pair "`EventDTO` + the previous `lastData`"; the handler
   receives `handler(dto, previous)`. The DTO handed to the handler is rebuilt for type `T`,
   keeping the topic, the `arguments` and the `completer` of the original event.
4. Listeners receive the value from the value stream **before** the sender returns from
   `await send(...)`, and regardless of how the handler finishes.
5. When the handler has finished: if `completer` is not completed yet — `completer.complete(null)`;
   if the handler threw — `completer.completeError(...)`.

This order guarantees that by the time `await bus.send(...)` returns, listeners have already
received the data (see [07-caveats.md, item 3](07-caveats.md#3-delivery-to-listeners-is-asynchronous)
for the case when the send is not awaited).

## 4. EventBus — the node registry

```dart
abstract class EventBus {
  bool get isModelBus;
  String get defaultTopicPathSeparator;         // '.' unless changed
  EventBusHandlers get handlers;                // no cast: bus.handlers.setHandler(...)
  bool get isDisposed;                          // true after dispose
  Future<void> dispose();                       // idempotent; closes the nodes and allEventStream
  Stream<(EventDTO, bool)> get allEventStream;  // (the event, whether it was delivered to a node)
  bool haveListener<T>({List<String>? paths, String? separator});
  bool haveHandler<T>({List<String>? paths, String? separator});
  Future<dynamic>? send<T>(T data, {List<String>? paths, String? separator,
                                    Map<String, String>? arguments});
  Stream<T> listen<T>({List<String>? paths, String? separator});
  StreamSubscription<T> subscribe<T>({List<String>? paths, String? separator,
                                      void Function(T e)? onData, Function? onError,
                                      void Function()? onDone, bool? cancelOnError});
  T? lastData<T>({List<String>? paths, String? separator});
  factory EventBus({bool isModelBus = false}) => EventBusImpl(isModelBus);
}
```

`EventBus` is an abstract interface with a factory: `EventBus(...)` always creates `EventBusImpl`.
Handler management methods live in a separate interface, `EventBusHandlers`, so on a variable of
type `EventBus` you have to cast:

```dart
final bus = EventBus();
(bus as EventBusHandlers).setHandler<String>(handler: ...);
```

`EventBusMixin` implements both interfaces (`class EventBusImpl with EventBusMixin`). Inside there
is `Map<Topic, EventNode> _eventsMap` and a broadcast `_allEventStream`.

### Two bus configurations

| | `EventBus()` — common | `EventBus(isModelBus: true)` — model |
|---|---|---|
| Creates a node on `send` to a nonexistent topic | no | yes |
| What `send` returns for an empty topic | a `Future` completing with `null` | a `Future` completing with `null` |
| `allEventStream` | `(dto, false)` | `(dto, true)` |
| Keeps `lastData` | only while the node is alive (a handler or a listener exists) | always |
| When the node is removed | when it has no listeners and no handler left | never (until `dispose`) |

The model bus is a "state store": the value is remembered even if nobody was listening at the
moment of the send. The common bus is a "message pipe": with no one to hand the value to, the
event goes to `allEventStream` and that is it.

### `allEventStream`

```dart
Stream<(EventDTO, bool)> get allEventStream;
```

The second element of the tuple is **not** "is there a listener", but "was there a node that
accepted the event" (inside `isModelBus` a node is always created, so there it is always `true`).
The stream is read by `FSM` and `EventBusLogger`; it is useful for end-to-end logging and tracing.

### Node life cycle

* `listen` / `subscribe` create a node if it did not exist.
* `setHandler` also creates a node (and overwrites the handler if the node already existed).
* `subscribe`/`listen` attach `doOnCancel(() => removeNode(...))`. `removeNode` removes and
  destroys the node **if** it has no listeners, no handler, and the bus is not model.
* So on the common bus `lastData` lives exactly until the last subscription is canceled. If you
  need to keep state, use `isModelBus: true` or a handler.

A detailed walkthrough of the practical consequences is in [02-event-bus.md](02-event-bus.md),
and the full list of pitfalls is in [07-caveats.md](07-caveats.md).

## 5. Overview of the package modules

```text
                 ┌──────────────────────────────────────────────┐
                 │                 EventBus                     │
   Scope ────────┤  _eventsMap: Map<Topic, EventNode>           │────── FSM
   (state +      │  _allEventStream: Stream<(EventDTO, bool)>   │   (reacts to events
    history)     └──────────────────────────────────────────────┘    by topic)
                                   ▲
                                   │
                          EventBusIsolate
                 (bridge to the worker isolate: events down,
                  results and events — up)
                                   ▲
                                   │
                   Layers: main ↔ isolate₂ ↔ isolate₁ ↔ isolate₀
```

## What's next

| Document | Content |
|---|---|
| [02-event-bus.md](02-event-bus.md) | Sending/receiving events, handlers, addressing, life cycle |
| [03-isolate-and-layers.md](03-isolate-and-layers.md) | Working through isolates and multi-layer schemes |
| [04-fsm.md](04-fsm.md) | Finite state machine on top of the bus |
| [05-scope-and-command.md](05-scope-and-command.md) | State with history, the command pattern |
| [06-api-reference.md](06-api-reference.md) | Full API reference |
| [07-caveats.md](07-caveats.md) | Pitfalls, known defects, workarounds |
