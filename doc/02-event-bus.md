# 02. EventBus: a practical guide

[← 01. Architecture](01-architecture.md) · [Table of contents](README.md) · [Next: isolates and layers →](03-isolate-and-layers.md)

## Creating a bus

```dart
import 'package:event_bus_arch/event_bus_arch.dart';

final bus = EventBus();                  // common: does not create nodes "on the fly"
final model = EventBus(isModelBus: true); // model: keeps the last value for every topic
```

Handler management methods are declared in the `EventBusHandlers` interface, so a variable of type
`EventBus` needs a cast:

```dart
bus.handlers.setHandler<String>(handler: ...);
```

The cast is always safe: the `EventBus(...)` factory returns `EventBusImpl`, which implements
`EventBusHandlers` through `EventBusMixin`. If the cast annoys you, keep the field typed as
`EventBusImpl` right away:

```dart
final EventBusImpl bus = EventBusImpl(false);
bus.setHandler<String>(handler: ...);   // no cast
```

## Sending an event

```dart
Future<dynamic>? send<T>(
  T data, {
  List<String>? paths,                   // the path after the type (affects the address)
  String? separator,                     // joins type and paths; '.' unless set on the bus
  Map<String, String>? arguments,        // parameters of the call (do NOT affect the address)
});
```

```dart
await bus.send('hello');                                     // topic: String
await bus.send(42, paths: ['user42']);                       // topic: int.user42
await bus.send('hello', paths: ['ui', 'top']);               // topic: String.ui.top
await bus.send('hello', arguments: {'k': 'v'});              // the same topic as 'hello'
```

`send` returns `Future?`:

* if the node exists → a `Future` that will complete with the handler result (or `null` if the
  handler did not fill in the `Completer`);
* if there is no node on the common bus → a `Future` completing with `null` (the event goes to
  `allEventStream` with flag `false`);
* for `EventBusIsolate.send` a literal `null` is also possible if the isolate has not started yet.

`send` **does not throw** when nobody is listening — that is not an error, but a normal mode.

## Receiving events

### `listen<T>()` — `Stream<T>`

```dart
final sub = bus.listen<String>().listen((data) => print('received: $data'));
await bus.send('hello');     // got: hello
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
  [`lastData`](#lastdata--the-last-value).
* After `await bus.send(...)` the listeners have already received the value — it is safe to
  unsubscribe. But if the send is not awaited (`bus.send(x);` without `await`), the delivery
  happens in a separate microtask, and canceling the subscription in the same tick loses the event
  ([07-caveats.md, item 3](07-caveats.md#3-delivery-to-listeners-is-asynchronous)).
* Canceling the last subscription on the common bus destroys the node (if it has no handler), and
  `lastData` with it
  ([07-caveats.md, item 2](07-caveats.md#2-a-node-and-lastdata-live-exactly-until-the-last-subscription)).

## Handlers

A handler is the "event receiver inside the bus", and it can return a result to the sender:

```dart
///dto — the event, lastData — the PREVIOUS value of this topic
typedef Handler<T> = Future<void> Function(EventDTO<T> dto, T? lastData);

bus.handlers.setHandler<int>(
  initialData: 0,                    // optional initial value of lastData
  paths: ['counter'],
  handler: (dto, lastData) async {
    print('got ${dto.data}, previous $lastData, arguments ${dto.arguments}');
    dto.completer?.complete(dto.data * 2);   // ← the result for the sender
  },
);

final result = await bus.send<int>(21, paths: ['counter']);
print(result);   // 42
```

Handlers are available in two ways: through the `bus.handlers` getter (recommended) or the
`bus as EventBusHandlers` cast — they are the same thing.

The first call of the handler receives the `initialData` value in `lastData`, the following ones
get the data of the previous event.

Rules:

| Situation | What the sender gets |
|---|---|
| The handler called `dto.completer?.complete(x)` | `x` |
| The handler returned without touching `completer` | `null` (the node completes `completer` itself) |
| The node has no handler, only listeners | `null` right away, waiting for nothing |
| There is no node, the bus is common | `null` |
| The handler threw | that exception: `await send(...)` throws it at the sender, and listeners still get the data ([07-caveats.md, item 4](07-caveats.md#4-a-handler-error-is-visible-to-the-sender--and-in-the-zone-if-nobody-waits-for-it)) |

There is **one** handler per topic. A repeated `setHandler` with the same topic replaces it;
`removeHandler<T>()` destroys the node entirely (together with `lastData` and the subscriptions).

```dart
bus.handlers.removeHandler<int>(paths: ['counter']);
```

### Errors in a handler

`EventNode` completes `completer` with an error itself, so a separate `try/catch` is not
required — it is enough to let the exception propagate:

```dart
bus.handlers.setHandler<int>(handler: (dto, lastData) async {
  dto.completer?.complete(await _riskyWork(dto.data));
});
```

If you need to return your own error or a default value to the sender, complete `completer`
explicitly:

```dart
bus.handlers.setHandler<int>(handler: (dto, lastData) async {
  try {
    dto.completer?.complete(await _riskyWork(dto.data));
  } catch (e, s) {
    dto.completer?.completeError(EventBusException('failed to handle: $e'), s);
  }
});
```

## `lastData` — the last value

```dart
bus.lastData<String>();                    // topic: String
bus.lastData<String>(paths: ['ui']);       // topic: String.ui
```

Returns `null` if there is no node (including the case when the node was removed after the
subscriptions were canceled).

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
await bus.send('x', paths: ['a.b'], separator: '/');   // topic: String/a.b — one token
await bus.send('x', paths: ['a', 'b'], separator: '/'); // topic: String/a/b — two tokens
```

Two topics are the same node exactly when their `topic` strings are equal, so a path token that
contains the separator makes two different path lists collide.

## The type is part of the address

Routing is done by the type parameter `T` **at the call site**, not by the type of the value:

```dart
bus.handlers.setHandler<num>(handler: (dto, lastData) async {});

await bus.send<num>(1);   // the handler is called
await bus.send<int>(1);   // the handler is NOT called — this is a different topic (int)
bus.haveHandler<num>();   // true
bus.haveHandler<int>();   // false
```

Two more practical consequences:

* `EventBus` does not support `Future<dynamic>? send(data)` without an explicit type — the compiler
  infers `T` from the argument (`'hello'` → `String`), so usually everything matches automatically;
* a nullable type gives a **different** topic: `send<String?>(x)` builds the topic `String?` and
  will not reach `setHandler<String>`.

Bottom line: **be explicit with the type parameter** in `send`/`listen`/`setHandler` when the value
comes from a variable of a wider type (`Object`, `dynamic`, `num`, `Map`), otherwise the address
will be different.

## Availability checks

```dart
bus.haveHandler<String>(paths: ['ui']);   // whether a node with a handler exists
bus.haveListener<String>(paths: ['ui']);  // whether the node has active subscribers
```

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
listener", but "the event reached a node" (for the model bus it is always `true`).

## Moving handlers between buses

```dart
(busA.handlers).addAllHandlerFromOtherBus(busB);              // add the nodes from busB
(busA.handlers).removeAllHandlerPresentInOtherBus(busB);      // remove the nodes as in busB
```

The nodes are **copied**: the handler and the last value are moved into new `EventNode`s, so
`dispose` of one bus does not break the other. This lets you, for example, "mix in" a set of
handlers from a test bus into a production bus.

## Cleanup

```dart
await bus.dispose();        // close allEventStream and all nodes
bus.isDisposed;             // true
await bus.dispose();        // a repeated call is safe
```

The method is declared in the `EventBus` interface and is idempotent. After `dispose` the bus is
unusable: `send`, `listen`, `subscribe`, and `setHandler` throw `StateError`.

## Recipes

### Request-response

```dart
final bus = EventBus();

bus.handlers.setHandler<String>(
  paths: ['upper'],
  handler: (dto, lastData) async => dto.completer?.complete(dto.data.toUpperCase()),
);

final answer = await bus.send<String>('hi', paths: ['upper']);   // 'HI'
```

### State store

```dart
final store = EventBus(isModelBus: true);   // nodes are not removed, lastData is always kept

store.handlers.setHandler<int>(paths: ['counter'], handler: (dto, lastData) async {
  dto.completer?.complete(dto.data);        // "successfully accepted"
});

await store.send<int>(1, paths: ['counter']);
print(store.lastData<int>(paths: ['counter']));   // 1

// A new subscriber gets the current state right away from lastData,
// and later changes come through the stream:
final sub = store.subscribe<int>(paths: ['counter'], onData: print);
await store.send<int>(2, paths: ['counter']);     // will print 2
await sub.cancel();
```

Note that `EventBusHandlers` is only the handler management interface; it has no
`send`/`listen`/`lastData` methods. Do not save the cast into a variable if you need to send events
through it: either cast at the call site, or keep the variable typed as `EventBusImpl`.

### Exchange between application layers

Different subsystems talk over different paths on one bus without knowing about each other:

```dart
await bus.send<AuthEvent>(AuthEvent.loggedIn, paths: ['analytics']);
await bus.send<AuthEvent>(AuthEvent.loggedIn, paths: ['cache']);
```

## What's next

* [03-isolate-and-layers.md](03-isolate-and-layers.md) — the same events, but between isolates.
* [07-caveats.md](07-caveats.md) — what can go wrong.
