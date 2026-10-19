# 01. Architecture

[← Table of contents](README.md) · [Next: EventBus in practice →](02-event-bus.md)

`event_bus_arch` is an event-driven framework for Dart/Flutter. All interaction between
components goes through events that have an **address (Topic)**, **data**, and optional
**call arguments**. A `fire` publishes an event; a `request` asks a handler for a result.
Isolates, layers, a finite state machine, and scope/command are built on top of the bus.

## What the package consists of

| Layer | Type | Role |
|---|---|---|
| Addressing | `Topic` | Event address: a type plus a path, `OrderPlaced.warehouse.in` |
| Wildcards | `TopicPattern` | `*` (one path token) and `>` (one or more trailing tokens) |
| Event envelope | `EventDTO<T>` | Data + topic + `arguments` (no response channel) |
| Routing cell | `EventNode<T>` | Stores the last value and the listener stream for one topic |
| Responder | `RequestHandler` | A type-erased handler registration used by `request` |
| Registry | `EventBus` / `EventBusMixin` | Exact and pattern node maps + a stream of all events |
| Isolate boundaries | `EventBusIsolate`, `Layer`, `Layers` | Forwarding events between isolates and multi-isolate chains |
| On top of the bus | `FSM`, `Scope`, `Command`, `EventBusLogger` | State machine, state with history, logging |

## The two ways to publish

```text
   fire<T>(data, paths:, separator:, arguments:)
     │
     ▼
   EventDTO<T> {topic, data, arguments}
     │
     ├─ model/transport bus? create the exact node when it is missing
     ├─ deliver to the exact node (if it exists)
     ├─ deliver to every matching pattern node (`*`, `>`)
     └─ allEventStream.add((dto, matched))      → fire() returns `matched`
        No handler is called. No value is returned to the caller.


   request<T>(data, paths:, separator:, arguments:, timeout:)
     │
     ▼
   EventDTO<T> {topic, data, arguments}
     │
     ├─ resolve a handler: exact topic → most specific pattern topic
     ├─ none (or its data type does not accept the value)
     │     → allEventStream.add((dto, false)); throw NoHandlerException
     ├─ deliver to listeners (exact + matching patterns), so they see the request
     ├─ invoke handler(dto, previousCurrentData)
     │     ├─ returned value → request() result
     │     └─ thrown error    → request() error
     └─ optional timeout covers the handler future
```

`fire` is fire-and-forget: it reports whether anyone was listening. `request` is the only
way to get a handler's result; it never invokes a handler that `fire` reached.

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

### Wildcards

`TopicPattern` defines the canonical local wildcards:

* `*` matches exactly **one** path token;
* `>` matches **one or more** trailing tokens and must be the last token;
* a wildcard must be a whole token: `sen*or` is rejected.

They are core features, not a transport detail. Transports map them to broker symbols
(NATS uses the same ones, MQTT uses `+`/`#`).

```dart
Topic.fromString('int.sensor.*');   // matches int.sensor.temp, not int.sensor.a.b
Topic.fromString('int.>');          // matches int.sensor and int.a.b, not int
```

Patterns are used by `listen`/`subscribe`/`setHandler` and by the registry lookups.
`fire` and `request` calls themselves must address a concrete topic: a wildcard path in
`fire`/`request` throws an `EventBusException`.

### Key point: topic equality

`TopicImpl` compares only `topic` —

```dart
bool operator ==(Object other) => other is Topic && other.topic == topic;
int get hashCode => Object.hashAll([topic]);
```

and `topic` is the type and the paths joined by the separator. Consequences:

* `setHandler<String>(paths: ['p'])` and `fire('x', paths: ['p'], arguments: {'a': '1'})`
  address the **same** topic; `arguments` are not part of the address.
* The comparison accepts **any** `Topic` implementation, so an alternative implementation
  with the same routing key finds the same node.
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

The type is `'$T'` of the static type parameter, normalised to a broker-safe token:

* the case is **not** lowercased: `String` stays `String`;
* `<` becomes `(`, `>` becomes `)`, commas and whitespace become `_`, repeated `_` collapse:
  `List<int>` becomes `List(int)`, `Map<String, int>` becomes `Map(String_int)`;
* the type is still **part of the address**, not just an annotation — details are in
  [07-caveats.md, item 1](07-caveats.md#1-the-type-in-a-topic-is-a-static-type-parameter).

The normalisation matters on the wire: `<`/`>` and commas are structural in broker subjects.

### The separator

Every method that takes an address takes `separator`, and falls back to
`EventBus.defaultTopicPathSeparator` (`.` by default) when it is not passed:

```dart
final bus = EventBus();
bus.handlers.setHandler<int>(paths: ['a', 'b'], handler: ...);         // int.a.b
bus.fire<int>(1, paths: ['a', 'b']);                                   // int.a.b — delivered
await bus.request<int>(1, paths: ['a', 'b'], timeout: ...);            // int.a.b — answered
```

The separator is part of the address only through the string it produces: two topics with
different separators are equal when their `topic` strings are equal.

## 2. EventDTO — the event envelope

```dart
abstract class EventDTO<T> {
  Topic get topic;
  T get data;
  Map<String, String>? get arguments;   // parameters of this call; not part of the address
  Map<String, dynamic> toJson();        // {'topic': ..., 'data': ...}
}
```

* `arguments` are the parameters of a specific call. They do not select a node — two calls
  that differ only in `arguments` reach the same handler.
* There is **no completer**. A handler returns its result; `request` awaits it. `fire` has
  no result to deliver.
* `EventDTOImpl` implements `==`/`hashCode` over the `(topic, data)` pair and supports
  `toJson()`/`fromJson()`. `toJson` returns the data as is (without `jsonEncode`) — the
  caller does the encoding. `arguments` are not part of the JSON form.

## 3. EventNode — the topic cell

`EventNode<T>` holds the current value and the listener stream of one topic. A handler is
registered on the bus, not on the node:

```dart
abstract class EventNode<T> {
  T? currentData;                             // the last delivered value
  bool get isDisposed;
  StreamController<T> get streamControllerValue;

  void deliver(EventDTO dto);                 // store the value, notify listeners
  EventNode<T> copy();                        // independent node with the same value
  Future<void> dispose();                     // close the value stream
}
```

Processing order in the node:

1. `dto.data is T` is checked — a value of another type is ignored.
2. `currentData = dto.data` — synchronously.
3. The data is added to the broadcast value stream; `listen<T>()`/`subscribe<T>()`
   subscribers receive it. A broadcast stream does not buffer: only subscriptions made
   before the delivery see the event.

Two marker interfaces extend the contract for transports:

* `KeepAliveNode` — a transport owns an incoming subscription, so the bus must not remove
  the node when its last local listener unsubscribes;
* `IncomingEventNode` — an event that came from a transport is delivered to local listeners
  without being published back.

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
  bool fire<T>(T data, {List<String>? paths, String? separator,
                        Map<String, String>? arguments});
  Future<dynamic> request<T>(T data, {List<String>? paths, String? separator,
                                      Map<String, String>? arguments, Duration? timeout});
  Stream<T> listen<T>({List<String>? paths, String? separator});
  StreamSubscription<T> subscribe<T>({List<String>? paths, String? separator,
                                      void Function(T e)? onData, Function? onError,
                                      void Function()? onDone, bool? cancelOnError});
  T? currentData<T>({List<String>? paths, String? separator});
  factory EventBus({bool isModelBus = false}) => EventBusImpl(isModelBus);
}
```

`EventBus` is an abstract interface with a factory: `EventBus(...)` always creates `EventBusImpl`.
Handler management methods live in a separate interface, `EventBusHandlers`, reachable through
`bus.handlers`; on a variable of type `EventBus` use the getter:

```dart
final bus = EventBus();
bus.handlers.setHandler<String>(handler: ...);
```

`EventBusImpl` mixes in `EventBusMixin` (delivery and node lifecycle) and
`EventBusHandlersMixin` (handler registration, resolution and invocation). Inside there are
two maps:

* `Map<Topic, EventNode> _eventsMap` — concrete topics;
* `Map<Topic, EventNode> _patternMap` — topics containing `*` or `>`;
* `Map<Topic, RequestHandler> _requestHandlers` — responder registrations, exact and pattern.

### Two bus configurations

| | `EventBus()` — common | `EventBus(isModelBus: true)` — model |
|---|---|---|
| Creates a node on `fire` to a topic that has none | no | yes |
| What `fire` returns for an empty topic | `false` | `true` (the node is created) |
| `allEventStream` flag for an empty topic | `false` | `true` |
| Keeps `currentData` | only while the node is alive (a handler, a listener or a pin exists) | always |
| When the node is removed | when it has no listeners, no handler and no transport pin | never (until `dispose`) |

The model bus is a "state store": the value is remembered even if nobody was listening at the
moment of the `fire`. The common bus is a "message pipe": with no one to hand the value to, the
event goes to `allEventStream` and that is it.

### `allEventStream`

```dart
Stream<(EventDTO, bool)> get allEventStream;
```

The second element of the tuple is **not** "is there a listener", but "was there a node that
accepted the event" (inside `isModelBus` a node is always created, so there it is always `true`).
The stream is read by `FSM` and `EventBusLogger`; it is useful for end-to-end logging and tracing.
Both `fire` and `request` report their events there.

### Handler resolution and invocation

`setHandler<T>` creates (or reuses) a node and stores a `RequestHandler`:

* `accepts(data)` checks `data is T`;
* `invoke(dto, previousData)` rebuilds a typed `EventDTO<T>` and calls the user handler,
  returning its future.

`request` resolves a handler in this order:

1. the exact topic;
2. the most specific pattern topic that matches (more literal tokens win; ties keep
   registration order).

A request that itself contains wildcards resolves only by the exact key — and `request` rejects
wildcard paths before that. When no handler accepts the data, the call throws
`NoHandlerException`, and listeners are not notified.

The handler's second argument is the **previous** `currentData` of the handler's own node (the
topic the handler is registered on), not of the request topic when they differ. The returned
value is the response; a thrown error becomes the error of the request future.

### Node life cycle

* `listen` / `subscribe` create a node if it did not exist (exact or pattern).
* `setHandler` also creates a node and stores the registration in `_requestHandlers`. A repeated
  `setHandler` replaces the handler for the same topic.
* `cancel` of the last subscription calls `removeNode`. `removeNode` removes and disposes the
  node **only if** it has no listeners, no handler, no `KeepAliveNode` pin, and the bus is not
  model. Both maps are checked.
* `removeHandler` removes the registration; it removes the node only when that leaves the node
  without listeners (a shared topic with listeners keeps the node and its `currentData`).
* `fire` on a model bus or a transport bus may create the exact node (`shouldCreateNodeOnSend`).

So on the common bus `currentData` lives exactly until the last subscription is cancelled and
no handler is left. If you need to keep state, use `isModelBus: true` or a handler.

A detailed walkthrough of the practical consequences is in [02-event-bus.md](02-event-bus.md),
and the full list of pitfalls is in [07-caveats.md](07-caveats.md).

## 5. Overview of the package modules

```text
                 ┌──────────────────────────────────────────────┐
                 │                 EventBus                     │
   Scope ────────┤  _eventsMap:  Map<Topic, EventNode>          │────── FSM
   (state +      │  _patternMap: Map<Topic, EventNode>          │   (reacts to events
    history)     │  _requestHandlers: Map<Topic, RequestHandler>│    by topic)
                 │  _allEventStream: Stream<(EventDTO, bool)>   │
                 └──────────────────────────────────────────────┘
                                   ▲
                                   │
                          EventBusIsolate
                 (bridge to the worker isolate: events down,
                  requests and results up)
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
| [09-event-bus-nats.md](09-event-bus-nats.md) | The NATS transport |
| [10-event-bus-mqtt.md](10-event-bus-mqtt.md) | The MQTT 5 transport |
