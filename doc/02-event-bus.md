# 02. EventBus: a practical guide

[← 01. Architecture](01-architecture.md) · [Table of contents](README.md) · [Next: isolates and layers →](03-isolate-and-layers.md)

## Creating a bus

```dart
import 'package:event_bus_arch/event_bus_arch.dart';

final bus = EventBus();                   // common: does not create nodes "on the fly"
final model = EventBus(isModelBus: true); // model: keeps the current value for every topic
```

Handler management methods are declared in the `EventBusHandlers` interface, reachable through
the `handlers` getter:

```dart
bus.handlers.setHandler<String>(handler: ...);
```

The factory returns `EventBusImpl`, which implements both the delivery and the handler mixins.
If you prefer no interface at all, keep the field typed as `EventBusImpl`:

```dart
final EventBusImpl bus = EventBusImpl(false);
bus.setHandler<String>(handler: ...);
```

## Publishing an event: `fire`

```dart
bool fire<T>(
  T data, {
  List<String>? paths,                   // the path after the type (affects the address)
  String? separator,                     // joins type and paths; '.' unless set on the bus
  Map<String, String>? arguments,        // parameters of the call (do NOT affect the address)
});
```

```dart
bus.fire('hello');                                         // topic: String
bus.fire(42, paths: ['user42']);                           // topic: int.user42
bus.fire('hello', paths: ['ui', 'top']);                   // topic: String.ui.top
bus.fire('hello', arguments: {'k': 'v'});                  // the same topic as 'hello'
```

`fire` returns whether the event was accepted:

* `true` — there is a node for the topic (or the model/transport bus created one);
* `false` — the common bus has no node for the topic and no transport knows it; the event still
  goes to `allEventStream` with flag `false`.

`fire` does **not** invoke request handlers: it is a one-way publish to listeners. It does not
throw when nobody is listening — that is a normal mode, reported by `false`.

## Publishing a request: `request`

```dart
Future<dynamic> request<T>(
  T data, {
  List<String>? paths,
  String? separator,
  Map<String, String>? arguments,
  Duration? timeout,
});
```

```dart
final doubled = await bus.request<int>(21, paths: ['counter']);
```

`request` delivers the event to listeners and then invokes the handler registered for the
topic. The handler's returned value is the result; a thrown error becomes an error of the
returned future. A request without a handler (or with a handler that does not accept the data
type) throws `NoHandlerException`. Without `timeout`, the future waits as long as the handler
runs.

`request` rejects wildcard paths: `paths: ['sensor', '*']` throws an `EventBusException`.
A request addresses a concrete topic; a **handler** may be registered on a pattern.

## Receiving events

### `listen<T>()` — `Stream<T>`

```dart
final sub = bus.listen<String>().listen((data) => print('received: $data'));
bus.fire('hello');     // got: hello
await sub.cancel();
```

### `subscribe<T>()` — `StreamSubscription<T>` right away

```dart
final sub = bus.subscribe<String>(
  paths: ['ui'],
  onData: (data) => print('received: $data'),
  onError: (e, s) => print('error: $e'),
  onDone: () => print('bus closed'),
  cancelOnError: true,
);
```

The only difference is the form of the call: `subscribe` is `listen<T>().listen(...)` returning the
subscription. Both variants use the same broadcast stream of the node, so there can be any number
of subscribers, and each one gets every event of the topic.

### Things to know about subscriptions

* The node stream is **broadcast**, there is no buffering: a subscription receives only the events
  that happened after it. A value sent before the subscription can be taken from
  [`currentData`](#currentdata--the-current-value).
* Listeners are notified by **both** `fire` and `request`; the request then waits for the handler.
* Delivery to the stream is scheduled, not synchronous: after `bus.fire(x)` returns, the listener
  callback runs in a microtask. Cancelling the subscription in the same tick loses the event
  ([07-caveats.md, item 3](07-caveats.md#3-delivery-to-listeners-is-asynchronous)).
* Cancelling the last subscription on the common bus destroys the node (if it has no handler,
  transport pin, and the bus is not model), and `currentData` with it
  ([07-caveats.md, item 2](07-caveats.md#2-a-node-and-currentdata-live-exactly-until-the-last-subscription)).
* A subscription on a pattern (`paths: ['sensor', '*']`) receives every concrete topic that
  matches it.

## Handlers

A handler is the responder for `request`. It can return a result:

```dart
///dto — the event, lastData — the PREVIOUS value of this topic
typedef Handler<T> = Future<dynamic> Function(EventDTO<T> dto, T? lastData);

bus.handlers.setHandler<int>(
  initialData: 0,                    // optional initial value of currentData
  paths: ['counter'],
  handler: (dto, lastData) async {
    print('got ${dto.data}, previous $lastData, arguments ${dto.arguments}');
    return dto.data * 2;             // ← the response for request()
  },
);

final result = await bus.request<int>(21, paths: ['counter']);
print(result);   // 42
```

Handlers are available through `bus.handlers` (recommended) or the `bus as EventBusHandlers` cast —
they are the same thing.

The first call of the handler receives the `initialData` value in `lastData`, the following ones
get the data of the previous event (the previous `currentData` of the handler's node).

Rules:

| Situation | What `request` does |
|---|---|
| The handler returns a value | the caller receives it |
| The handler returns `null` | the caller receives `null` |
| The handler throws | the caller receives that exception; listeners still get the data |
| The node has no handler, only listeners | `NoHandlerException`; listeners are not notified |
| There is no node, the bus is common | `NoHandlerException` |
| The request is sent with `fire` instead | the handler is not invoked; listeners still get the data |

There is **one** handler per topic. A repeated `setHandler` with the same topic replaces it.
`removeHandler<T>()` removes the registration; if the node has listeners left, the node and its
`currentData` stay alive. On a common bus with no listeners left, the node is removed too.

```dart
bus.handlers.removeHandler<int>(paths: ['counter']);
```

### Handlers on patterns

`setHandler` accepts wildcard paths too:

```dart
bus.handlers.setHandler<int>(
  paths: ['sensor', '*'],
  handler: (dto, lastData) async => dto.data,
);
```

`request<int>(1, paths: ['sensor', 'temp'])` resolves the exact registration first, then the most
specific pattern (more literal tokens win). A pattern handler registered for `sensor.*` also
answers `sensor.temp`, but a pattern is matched only by concrete requests.

### Errors in a handler

Let the exception propagate — the request future receives it:

```dart
bus.handlers.setHandler<int>(handler: (dto, lastData) async {
  return await _riskyWork(dto.data);
});
```

If you need to translate the error, throw your own:

```dart
bus.handlers.setHandler<int>(handler: (dto, lastData) async {
  try {
    return await _riskyWork(dto.data);
  } catch (e, s) {
    Error.throwWithStackTrace(EventBusException('failed to handle: $e'), s);
  }
});
```

A `fire` never runs a handler, so a handler error can only surface through `request` (or as an
unhandled error if the `request` future is not awaited).

## `currentData` — the current value

```dart
bus.currentData<String>();                       // topic: String
bus.currentData<String>(paths: ['ui']);          // topic: String.ui
bus.currentData<int>(paths: ['sensor', '*']);    // a pattern node's current value
```

Returns `null` if there is no node (including the case when the node was removed after the
subscriptions were cancelled). On a pattern topic it reads the pattern node.

## Addressing

An address is the **type** plus the **path**:

```text
String.ui.top
  │   │  │
  │   └──┴── paths: one token per element, joined by the separator
  └───────── type: the static type parameter of the call
```

| Parameter | Affects the address | Where the receiver can access it |
|---|---|---|
| `paths` | yes | `dto.topic.paths` |
| `separator` | yes, through the string it builds | `dto.topic.separator` |
| `arguments` | no | `dto.arguments` |

Use `paths` to address between modules/devices — the first token is the natural place for the
"to whom" part and the rest for "about what" — and `arguments` to pass parameters of a specific
call (for example, `{'multiplier': '10'}` in the package example).

`target` and `fragment` were **removed in 3.0.0**; the migration table is in
[07-caveats.md](07-caveats.md#what-changed-in-300).

### The separator

`separator` defaults to `EventBus.defaultTopicPathSeparator` (`.`). Pass it when the paths need
another separator — for example when a path token itself contains a dot:

```dart
bus.fire('x', paths: ['a.b'], separator: '/');   // topic: String/a.b — one token
bus.fire('x', paths: ['a', 'b'], separator: '/'); // topic: String/a/b — two tokens
```

Two topics are the same node exactly when their `topic` strings are equal, so a path token that
contains the separator makes two different path lists collide.

## The type is part of the address

Routing is done by the type parameter `T` **at the call site**, not by the type of the value:

```dart
bus.handlers.setHandler<num>(handler: (dto, lastData) async => dto.data);

await bus.request<num>(1);   // the handler is called
await bus.request<int>(1);   // NoHandlerException — this is a different topic (int)
bus.haveHandler<num>();      // true
bus.haveHandler<int>();      // false
```

Two more practical consequences:

* `fire`/`request` infer `T` from the argument (`'hello'` → `String`), so usually everything
  matches automatically; be explicit when the value comes from a wider-typed variable;
* a nullable type gives a **different** topic: `request<String?>(x)` builds `String?` and will
  not reach `setHandler<String>`.

Bottom line: **be explicit with the type parameter** in `fire`/`request`/`listen`/`setHandler`
when the value comes from a variable of a wider type (`Object`, `dynamic`, `num`, `Map`),
otherwise the address will be different.

## Availability checks

```dart
bus.haveHandler<String>(paths: ['ui']);        // exact or matching pattern handler
bus.haveListener<String>(paths: ['ui']);       // exact node or any matching pattern node
bus.haveListener<String>(paths: ['sensor', '*']); // that pattern node
```

`haveHandler` on a concrete topic returns true for an exact registration or for the most
specific matching pattern. `haveListener` inspects the value streams: for a concrete topic it is
true when the exact node **or** any matching pattern node has subscribers.

## Logging all events

```dart
class BusLog with EventBusLogger {}

final log = BusLog()..add(bus, handler: (dto, delivered) {
  print('[${dto.topic.topic}] delivered=$delivered data=${dto.data}');
});

log.remove(bus);
```

`EventBusLogger.add(bus, {handler})` subscribes to `allEventStream`. The default handler prints a
line like `Event:String.ui hasListeners true`. The second parameter is not "is there a
listener", but "the event reached a node" (for the model bus it is always `true`). Both `fire`
and `request` produce entries.

## Moving handlers between buses

```dart
busA.handlers.addAllHandlerFromOtherBus(busB);              // add the registrations from busB
busA.handlers.removeAllHandlerPresentInOtherBus(busB);      // remove the same registrations
```

The nodes are **copied**: the handler registration and the current value are moved into new
`EventNode`s, so `dispose` of one bus does not break the other. This lets you, for example,
"mix in" a set of handlers from a test bus into a production bus. Pattern registrations are
copied as well.

## Cleanup

```dart
await bus.dispose();        // close allEventStream and all nodes
bus.isDisposed;             // true
await bus.dispose();        // a repeated call is safe
```

The method is declared in the `EventBus` interface and is idempotent. After `dispose` the bus is
unusable: `fire`, `request`, `listen`, `subscribe`, and `setHandler` throw `StateError`.

## Recipes

### Request-response

```dart
final bus = EventBus();

bus.handlers.setHandler<String>(
  paths: ['upper'],
  handler: (dto, lastData) async => dto.data.toUpperCase(),
);

final answer = await bus.request<String>('hi', paths: ['upper']);   // 'HI'
```

### State store

```dart
final store = EventBus(isModelBus: true);   // nodes are not removed, currentData is always kept

store.handlers.setHandler<int>(paths: ['counter'], handler: (dto, lastData) async {
  return dto.data;                          // "successfully accepted"
});

await store.request<int>(1, paths: ['counter']);
print(store.currentData<int>(paths: ['counter']));   // 1

// A new subscriber reads the current state from currentData,
// and later changes come through the stream:
final sub = store.subscribe<int>(paths: ['counter'], onData: print);
store.fire<int>(2, paths: ['counter']);      // will print 2
await sub.cancel();
```

`EventBusHandlers` is only the handler management interface; it has no `fire`/`listen`/`currentData`
methods. Use `bus.handlers` for handler management and the bus itself for everything else.

### Exchange between application layers

Different subsystems talk over different paths on one bus without knowing about each other:

```dart
bus.fire<AuthEvent>(AuthEvent.loggedIn, paths: ['analytics']);
bus.fire<AuthEvent>(AuthEvent.loggedIn, paths: ['cache']);
```

### Pattern listener

```dart
final sub = bus.subscribe<int>(
  paths: ['sensor', '*'],
  onData: (value) => print('sensor reading: $value'),
);

bus.fire<int>(21, paths: ['sensor', 'temp']);
bus.fire<int>(22, paths: ['sensor', 'humidity']);
```

A `>` pattern receives the whole subtree:

```dart
bus.subscribe<int>(paths: ['sensor', '>']).listen(print);
// int.sensor.temp, int.sensor.room.temp, … but not int.sensor itself
```

## What's next

* [03-isolate-and-layers.md](03-isolate-and-layers.md) — the same events, but between isolates.
* [07-caveats.md](07-caveats.md) — what can go wrong.
* [09-event-bus-nats.md](09-event-bus-nats.md), [10-event-bus-mqtt.md](10-event-bus-mqtt.md) —
  the same API over a broker.
