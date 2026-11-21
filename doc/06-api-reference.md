# 06. API Reference

[← 05. Scope and Command](05-scope-and-command.md) · [Contents](README.md) · [Next: Pitfalls →](07-caveats.md)

The entire public API lives in a single library — `package:event_bus_arch/event_bus_arch.dart`
(library name `event_arch`, assembled from `part` files). The package does not re-export `rxdart`;
add it to your own dependencies if you need its operators.

## Contents

* [Typedefs](#typedefs)
* [Topic](#topic) / [TopicImpl](#topicimpl) / [TopicPattern](#topicpattern)
* [EventDTO](#eventdto) / [EventDTOImpl](#eventdtoimpl)
* [EventNode](#eventnode) / [EventSubscription](#eventsubscription) / [RequestHandler](#requesthandler)
* [EventBus](#eventbus) / [EventBusHandlers](#eventbushandlers) / [EventBusImpl](#eventbusimpl) /
  [EventBusMixin](#eventbusmixin) / [EventBusHandlersMixin](#eventbushandlersmixin)
* [EventBusIsolate](#eventbusisolate)
* [Layer](#layer) / [Layers](#layers)
* [FSM](#fsm)
* [Scope](#scope) / [Command](#command)
* [EventBusLogger](#eventbuslogger)
* [Errors](#errors)
* [What is not exported](#what-is-not-exported)

## Typedefs

```dart
///A request responder. The returned value is the response; an exception is an error.
typedef Handler<T> = Future<dynamic> Function(EventDTO<T> dto, T? lastData);

typedef Node<T> = EventNode<T>;

typedef FSMHandler<T, E> =
    Future<Object?> Function(T currentState, T lastState, E event, List<EventDTO> ignoredEvents);
typedef FSMFilter<T, E> = bool Function(T currentState, T lastState, E event);

typedef fnInitLayer = FutureOr<void> Function(Layer layer, Object? initialData);
typedef LoggerHandler = void Function(EventDTO dto, bool hasDelivered);
```

## Topic

`abstract class Topic` — the event address. The format, the separator and the equality rules are
in [01-architecture.md](01-architecture.md#1-topic--the-event-address).

```dart
// Getters
String get type;                        // the first token: 'String'
List<String> get paths;                 // the path tokens: ['a', 'b']; empty when there is none
String get separator;                   // joins type and paths: '.' by default
String get topic;                       // the routing key: 'String.a.b'

// Creation
static Topic create<T>({List<String>? paths, String separator = '.'});
factory Topic.fromParametr({Type? type, List<String>? paths, String separator = '.'});
factory Topic.parse(String str, {String separator = '.'});   // == fromString
factory Topic.fromString(String topic, {String separator = '.'});

Topic copy({List<String>? paths, String? separator});   // the type is kept
String toString();                                      // returns topic
```

```dart
Topic.create<String>();                              // String
Topic.create<String>(paths: ['a', 'b']);             // String.a.b
Topic.create<String>(paths: ['a', 'b'], separator: '/');  // String/a/b
Topic.parse('String.a.b');                           // type String, paths ['a', 'b']
Topic.fromParametr(type: MyEvent, paths: ['p']);     // MyEvent.p
```

The type token is normalised: `<` → `(`, `>` → `)`, commas/whitespace → `_`, repeated `_`
collapsed. `List<int>` therefore becomes `List(int)`.

**Equality is by `topic`** — the type, the separator and the paths in the string form.
`arguments` live on the [EventDTO](#eventdto) and are not part of the address, so two calls that
differ only in `arguments` reach the same handler. The comparison is `other is Topic`, so any
implementation with the same routing key is equal.

`Topic.parse` splits the string by `separator` and rejects an empty type with an
`EventBusException` (`Topic.parse('')`, `Topic.parse('.a')`). `Topic.fromParametr` throws the same
exception when `type` is null. `copy` keeps the type and replaces only what is passed.

## TopicImpl

`class TopicImpl implements Topic` — the only implementation, returned by all factories.

```dart
TopicImpl(String type, {String separator = '.', List<String> paths = const []});

String get topic;          // 'String.a.b', or just the type when paths is empty
Topic copy({List<String>? paths, String? separator});
bool operator ==(Object other);   // other is Topic && other.topic == topic
int get hashCode;                 // Object.hashAll([topic])
String toString();                // returns topic
```

`paths` is held as passed, not copied. Do not mutate the list you handed in: the routing key and
the hash are computed from it on every access, so a mutation changes the address of a topic that
is already a key in the node maps.

## TopicPattern

`abstract final class TopicPattern` — the canonical local wildcard rules. Both the bus and every
transport use them; a transport only maps the symbols to its broker's grammar.

```dart
static const String single = '*';   // exactly one path token
static const String tail = '>';     // one or more trailing tokens, must be last

static bool isPattern(Topic topic);          // any path contains '*' or '>'
static void validate(Topic topic);           // '>' last, wildcard is a whole token
static bool matches(Topic pattern, Topic topic);
static int specificity(Topic pattern);       // number of literal path tokens
```

```dart
final pattern = Topic.fromString('int.sensor.*');
TopicPattern.matches(pattern, Topic.fromString('int.sensor.temp'));   // true
TopicPattern.matches(pattern, Topic.fromString('int.sensor.a.b'));    // false
TopicPattern.matches(Topic.fromString('int.>'), Topic.fromString('int.sensor')); // true
TopicPattern.matches(Topic.fromString('int.>'), Topic.fromString('int'));        // false
```

A wildcard must occupy a whole token (`sen*or` is rejected by `validate`). Only the paths can
contain wildcards; the type token is always concrete. `specificity` is used to pick the most
specific handler or pattern node; ties keep insertion order.

## EventDTO

```dart
abstract class EventDTO<T> {
  Topic get topic;
  T get data;
  Map<String, String>? get arguments;    // parameters of this call; not part of the address

  static EventDTO<T> create<T>(T data, {List<String>? paths, String? separator,
      Map<String, String>? arguments});

  factory EventDTO(T data, {Topic? topic, List<String>? paths, String? separator,
      Map<String, String>? arguments});

  Map<String, dynamic> toJson();
}
```

The factory creates `EventDTOImpl`. If `topic` is not passed, it is built from `T` and the
`paths`/`separator` parameters; `separator` defaults to `'.'` when not given.

There is no completer: a handler returns its result, `request` awaits it, and `fire` has no
result channel. `arguments` reach the handler on the DTO it is given, including across an
isolate.

## EventDTOImpl

```dart
class EventDTOImpl<T> implements EventDTO<T> {
  EventDTOImpl(Topic topic, T data, {Map<String, String>? arguments});
                                                       // topic and data are positional!

  Topic topic;
  T data;
  Map<String, String>? arguments;

  static EventDTO<T> fromJson<T>(Map<String, dynamic> json,
      {T Function(String topic, dynamic data)? dataConverter});

  Map<String, dynamic> toJson();     // {'topic': topic.topic, 'data': data} — without encoding
  bool operator ==(Object other);    // by (topic, data)
  int get hashCode;                  // Object.hashAll([topic, data])
  String toString();                 // 'EventDTO(<topic>, data: <data>)'
}
```

`toJson` returns the data **as is**, without `jsonEncode`: encoding is the caller's
job, so an arbitrary object in `data` no longer breaks either `toJson` or `toString`.
`arguments` are **not** part of the JSON form, and `fromJson` does not restore them — carry them
in your own envelope if a wire format has to preserve them.

## EventNode

`abstract class EventNode<T>` — the topic cell: the current value and the listener stream.
A handler is not stored here; it lives in the bus.

```dart
T? currentData;                                 // the last delivered value
bool get isDisposed;
StreamController<T> get streamControllerValue;

void deliver(EventDTO dto);                     // store the value, notify the stream
EventNode<T> copy();                            // independent node with the same value
Future<void> dispose();                         // close the value stream

factory EventNode.create({T? currentData});     // EventNodeImp
```

`EventNodeImp<T>` is the default implementation:

```dart
class EventNodeImp<T> implements EventNode<T> {
  EventNodeImp({T? currentData});
  T? currentData;
  void deliver(EventDTO dto);                   // dto.data is T is checked
  EventNode<T> copy();
  Future<void> dispose();
}
```

`typedef Node<T> = EventNode<T>;` — an alias.

### Marker interfaces

```dart
abstract class KeepAliveNode {
  bool get keepAlive;      // a transport owns a subscription; do not remove the node
}

abstract class IncomingEventNode {
  void deliverIncoming(EventDTO dto);   // deliver from a transport without republishing
}
```

Transport nodes implement both. Local `EventNodeImp` implements neither.

### SubscriptionHost

```dart
abstract class SubscriptionHost<T> {
  void addSubscription(EventSubscription<T> subscription);
  void removeSubscription(EventSubscription<T> subscription);
  bool get hasSubscriptions;           // at least one non-cancelled subscription
  bool get hasListenerSubscriptions;   // at least one subscription that receives events
}
```

Every built-in node implements it; a custom `EventNode` must implement it to work with
`subscribeEvents`. Transport nodes delegate to their local node.

## EventSubscription

`class EventSubscription<T>` — a listener and/or handler registration created by
`bus.subscribeEvents<T>(...)`. Unlike `listen`/`subscribe`, it owns its buffer, its request queue
and its delivery state, and can be paused, resumed, resized and cancelled.

```dart
typedef EventCallback<T> = FutureOr<void> Function(T event);

enum BufferOverflow { latest, dropOldest, dropNewest, reject }
enum DeliveryMode { async, sync }

Future<void> cancel();                 // remove the subscription; does not call onDone
void pause();                          // stop listener delivery and request dispatch
void resume();                         // resume both
void resize(int? capacity, {BufferOverflow? overflow});

bool get isPaused;
bool get isBusy;                       // listener busy or handler at capacity
bool get isListenerBusy;               // an async onEvent future is pending
bool get isHandlerBusy;                // every handler slot is occupied
bool get isCanceled;
bool get hasHandler;
bool get hasListener;
int? get bufferCapacity;               // null = unbounded
BufferOverflow get bufferOverflow;
int get buffered;
int get dropped;
int get delivered;
int get inFlight;                      // running handler invocations
int get bufferedRequests;              // queued requests
int get handlerConcurrency;
int get requestQueueCapacity;
bool get hasRequestCapacity;           // free slot or queue room, and not paused
Stream<T> get stream;                  // broadcast view for UI
```

Delivery:

* `DeliveryMode.async` (default) delivers in a microtask and preserves the stream timing of
  `listen`; `DeliveryMode.sync` invokes `onEvent` inside `fire` and is reentrancy-sensitive.
* While an asynchronous `onEvent` is running the subscription is `isListenerBusy`; incoming
  events go through the buffer policy. A full buffer drops or rejects according to
  `bufferOverflow`; a rejected event is counted in `dropped`.
* A handler subscription owns a FIFO request queue and `handlerConcurrency` slots (default 1).
  Requests are dispatched to a free slot or queued up to `requestQueueCapacity`; beyond that the
  bus throws `BusyException`. `pause()` stops request dispatch; in-flight handlers continue.
* `cancel()` clears the buffers, fails queued requests with `NoHandlerException`, and closes the
  `.stream` view. `onDone` is called only when the node is disposed (`dispose`, `removeTopic`).
* Listener errors go to the subscription-level `onError`; `cancelOnError` also cancels the
  subscription. The bus-level error stream is added by E1-13.
* `CancelToken` (below) and `timeout` remove a queued request; a dispatched handler keeps running
  and its response is discarded.

### CancelToken and request errors

```dart
class CancelToken {
  bool get isCancelled;
  Future<void> get whenCancelled;
  void cancel([Object? reason]);
}

class BusyException extends EventBusException;          // no slot / queue room / all paused
class RequestTimeoutException extends EventBusException; // topic + timeout
class RequestCanceledException extends EventBusException;
```

`request(..., timeout: ..., cancelToken: ...)` uses both; the first of response, timeout and
cancellation wins.

## RequestHandler

`class RequestHandler` — a type-erased responder registration stored by the bus. Its closures
allow `request` and incoming isolate/transport requests to be dispatched without knowing `T`
statically.

> **4.0 transition:** the dispatcher now uses `EventSubscription` handler capabilities. This
> class, `EventBusHandlers` and `setHandler` remain only as a temporary compatibility shim and
> are removed by task E1-10; use `subscribeEvents(handler: ...)`.

```dart
RequestHandler({
  required Topic topic,
  required bool Function(Object? data) accepts,
  required Future<dynamic> Function(EventDTO dto, Object? lastData) invoke,
});

final Topic topic;
final bool Function(Object? data) accepts;
final Future<dynamic> Function(EventDTO dto, Object? lastData) invoke;
```

## EventBus

The abstract bus interface. The factory always returns `EventBusImpl`.

```dart
factory EventBus({bool isModelBus = false});

bool get isModelBus;
String get defaultTopicPathSeparator;          // '.'; the fallback for every address parameter
EventBusHandlers get handlers;                 // bus.handlers.setHandler(...) without a cast
Future<void> dispose();                        // idempotent; after it the bus throws StateError
bool get isDisposed;
Stream<(EventDTO, bool)> get allEventStream;   // (event, whether it reached a node)

bool fire<T>(T data, {List<String>? paths, String? separator,
                      Map<String, String>? arguments});
Future<dynamic> request<T>(T data, {List<String>? paths, String? separator,
                                    Map<String, String>? arguments, Duration? timeout,
                                    CancelToken? cancelToken});

Stream<T> listen<T>({List<String>? paths, String? separator});
StreamSubscription<T> subscribe<T>({List<String>? paths, String? separator,
                                    void Function(T e)? onData, Function? onError,
                                    void Function()? onDone, bool? cancelOnError});
EventSubscription<T> subscribeEvents<T>({
  List<String>? paths, String? separator,
  EventCallback<T>? onEvent,            // listener
  Handler<T>? handler,                  // request responder
  int handlerConcurrency = 1,
  int? requestQueueCapacity,            // default: bus.requestQueueCapacity (64)
  int? bufferCapacity,                  // null = unbounded
  BufferOverflow bufferOverflow = BufferOverflow.dropOldest,
  DeliveryMode deliveryMode = DeliveryMode.async,
  void Function(Object error, StackTrace? stackTrace)? onError,
  void Function()? onDone,
  bool cancelOnError = false,
});
T? currentData<T>({List<String>? paths, String? separator});
bool removeTopic<T>({List<String>? paths, String? separator});

bool haveHandler<T>({List<String>? paths, String? separator});
bool haveAvailableHandler<T>({List<String>? paths, String? separator});
bool haveListener<T>({List<String>? paths, String? separator});
```

`fire` returns whether a node accepted the event. `request` throws `NoHandlerException` when no
handler accepts the data and rejects wildcard paths with `EventBusException`; `timeout` bounds the
wait for the handler. `currentData` reads the exact node, or the pattern node when the address
contains wildcards.

`removeTopic` removes the node and forgets `currentData` even on a model bus and even for a
transport node with a `KeepAliveNode` pin (the broker subscription is cancelled). It returns
whether a node was removed. Active listeners receive `done`; a registered handler is kept, and a
model bus recreates the node on the next `fire`, `request` or `listen`.

Every method that takes an address resolves `separator ?? defaultTopicPathSeparator`, so changing
the field on an `EventBusImpl` changes the fallback for all of them at once:

```dart
final bus = EventBusImpl(false);
bus.defaultTopicPathSeparator = '/';
bus.handlers.setHandler<int>(paths: ['a', 'b'], handler: ...);   // int/a/b
bus.fire<int>(1, paths: ['a', 'b']);                             // int/a/b — delivered
```

`defaultTopicPathSeparator` is a **field** on `EventBusMixin`, not a setter on the interface, so a
variable of type `EventBus` has to be cast (`(bus as EventBusImpl).defaultTopicPathSeparator = '/'`).

After `dispose` the `fire`/`request`/`listen`/`subscribe`/`setHandler`/`removeTopic` methods throw
`StateError`.

## EventBusHandlers

A separate interface for managing handlers (accessible through `bus.handlers` or the cast
`bus as EventBusHandlers`).

```dart
void setHandler<T>({
  T? initialData,                              // initial value of currentData
  List<String>? paths,                         // may contain '*' and '>'
  String? separator,
  required Handler<T> handler,
});
void removeHandler<T>({List<String>? paths, String? separator});
void addAllHandlerFromOtherBus(EventBus fromBus);
void removeAllHandlerPresentInOtherBus(EventBus otherBus);
```

`setHandler` creates (or reuses) the node for the topic, stores a `RequestHandler`, and optionally
sets its `currentData`. A repeated registration for the same topic replaces the previous one.
`removeHandler` removes the registration; the node is removed only if it has no listeners and no
transport pin.

## EventBusImpl

```dart
class EventBusImpl with EventBusMixin, EventBusHandlersMixin {
  EventBusImpl(bool isModelBus);
  bool get isModelBus;
}
```

All behavior comes from the two mixins; the class's own code only stores the flag.

## EventBusMixin

`mixin EventBusMixin implements EventBus` — delivery, node lifecycle and the bus flags.

```dart
String defaultTopicPathSeparator = '.';         // the address fallback, writable
EventBusHandlers get handlers;                  // from EventBusHandlersMixin
bool get isDisposed;

// Hooks for transports:
EventNode<T> createNode<T>({required Topic topic, T? currentData});
bool shouldCreateNodeOnSend(Topic topic);       // default: isModelBus

bool removeTopic<T>({List<String>? paths, String? separator});   // explicit eviction
Future<void> dispose();                         // idempotent; closes allEventStream and the nodes
```

Inside there are `_eventsMap` (concrete topics), `_patternMap` (topics with `*`/`>`), and a
broadcast `_allEventStream`. Automatic cleanup is private: `_removeNode` removes the node from
both maps and disposes it only if it has no listeners, no handler, no `KeepAliveNode` pin, and
the bus is not model. It is called when the last subscription is cancelled, on `removeHandler`
and on `removeAllHandlerPresentInOtherBus`. A map entry is removed only when it still holds the
same node instance, so a late cancellation of an already removed node cannot delete its
replacement.

`removeTopic` is the explicit counterpart: it bypasses the model-bus rule and the `KeepAliveNode`
pin, removes the node from whichever map holds it, and disposes it. `EventBusIsolate` forwards the
call to the other side of the bridge.

`createNode` and `shouldCreateNodeOnSend` are the transport seam: a transport bus overrides them
to create a broker-backed node for topics it knows and to create one on `fire` when a serializer
or deserializer is registered. Local buses keep the defaults.

## EventBusHandlersMixin

`mixin EventBusHandlersMixin on EventBusMixin implements EventBusHandlers` — handler registration,
resolution and invocation.

```dart
EventBusHandlers get handlers;                       // returns this
void setHandler<T>({T? initialData, List<String>? paths, String? separator,
                    required Handler<T> handler});
void removeHandler<T>({List<String>? paths, String? separator});
bool haveHandler<T>({List<String>? paths, String? separator});
Future<dynamic> request<T>(T data, {List<String>? paths, String? separator,
                                    Map<String, String>? arguments, Duration? timeout,
                                    CancelToken? cancelToken});
void addAllHandlerFromOtherBus(EventBus fromBus);
void removeAllHandlerPresentInOtherBus(EventBus otherBus);

///The registered topic of the handler that would answer [topic], or null.
Topic? handlerTopicFor(Topic topic);

///Dispatches a request received from another process (isolate or transport):
///resolves the handler, notifies listeners and returns the handler future.
Future<dynamic> handleIncomingRequest(EventDTO dto);
```

Resolution order: exact topic → most specific matching pattern. A pattern topic passed to
`request` resolves by the exact key only, and `request` rejects wildcard paths first.
`handlerTopicFor` and `handleIncomingRequest` are intended for transports and isolate bridges;
they are public because those layers live outside this library.

## EventBusIsolate

```dart
class EventBusIsolate extends EventBusImpl {
  EventBusIsolate({
    required FutureOr<void> Function(EventBus bus, Object? initialData) onInit,  // can be async
    Object? initialData,
    bool isModelBus = false,   // model bus on both the main side and in the worker
  });

  final FutureOr<void> Function(EventBus isolateBu, Object? initialData) onInit;
  Future<bool> get waitInit;      // true — the worker completed onInit; an error — startup failed
  bool get isInit;                // true after a successful onInit
  bool get isDisposed;

  @override
  bool fire<T>(T data, {List<String>? paths, String? separator,
                        Map<String, String>? arguments});   // throws StateError before waitInit

  @override
  Future<dynamic> request<T>(T data, {List<String>? paths, String? separator,
                                      Map<String, String>? arguments, Duration? timeout});

  Future<bool> ping({Duration timeout = const Duration(seconds: 2)});     // liveness check

  @override
  Future<void> dispose();         // completes the waits, closes the port, kills the isolate
}
```

Inherits `listen`, `subscribe`, `currentData`, `haveHandler`, `haveListener`, `isModelBus`,
`allEventStream` from `EventBusImpl`. `isModelBus` reflects the constructor flag and applies to
both sides of the bridge. `onInit` is a public field, but assigning it again restarts nothing (the
isolate is already created in the constructor).

`fire`/`request` on the isolate **are** the boundary calls: they build the DTO, send it through
the `SendPort` and (for `request`) wait for the reply. Paths, separator and arguments cross with
it, so a worker handler addressed by paths answers on the same address. A request with no handler
in the target returns an error (`NoHandlerException`), never `null`.

Exchange specifics and limitations — [03-isolate-and-layers.md](03-isolate-and-layers.md#guarantees-and-limitations).

## Layer

```dart
class Layer {
  EventBus? top;         // up the layer chain (null for the top/main layer)
  EventBus current;      // the layer's local bus
  EventBus? bottom;      // down the chain (null for the last layer)

  Layer({EventBus? top, required EventBus current, EventBus? bottom});

  /// Closes top, bottom and current; idempotent, works from any layer
  Future<void> close();
}
```

## Layers

```dart
class Layers {
  static Future<Layer> createLayers(
      List<(fnInitLayer, Object?, bool)> layers,      // (init function, data, isModelBus)
      {bool currentIsModelBus = true,                 // flag for the current (top) bus
       bool bridgeIsModelBus = false,                 // flag for every isolate bridge
       Duration? timeout});                           // timeout for initializing the chain
}
```

Returns the top `Layer` when **all** layers of the chain are initialized; an init error
in any layer and an empty list come as an `EventBusException`. `bridgeIsModelBus` applies to
the `EventBusIsolate` bridges between layers; the tuple flag and `currentIsModelBus` apply to
each layer's `current` bus.
Details are in [03-isolate-and-layers.md](03-isolate-and-layers.md#layers--multi-layer-setups).

## FSM

```dart
mixin class FSM<T> {
  T get state;
  T get lastState;

  void initFSM(EventBus bus, T currentState, {T? lastState});
  void addFSMTransition<E>(T fromState, T toState, {FSMHandler<T, E>? handler,
      FSMFilter<T, E>? filter, List<String>? eventPaths});
  void changeState(T newState);
  @Deprecated('Use changeState') void changeStateByEvent(T newState);

  /// Unsubscribes the machine from the bus; a repeated initFSM turns it on again
  void dispose();
}
```

`addFSMTransition` registers the transition under `Topic.create<E>(paths: eventPaths)`, so the
event has to be published with the same type and paths to match. `arguments` never take part in
the lookup. `eventPaths` are exact: wildcard transitions are not matched. Both `fire` and
`request` feed `allEventStream`, so either can drive a transition.

Details and transition rules — [04-fsm.md](04-fsm.md).

## Scope

```dart
mixin class Scope<T> {
  T? lastData;
  void Function(T newData)? onUpdate;

  EventBus? get scopeBus;     // throws EventBusException if not initialized
  (T?, Map<String, String>?)? get lastCall;   // (data, arguments)

  Future<void> initScope(EventBus bus, {
      T? initialData,
      bool initialDataNeedExecute = true,
      List<String>? paths,
      int maxLenForUndo = 10,       // history depth; undo needs >= 2
      void Function(T newData)? onUpdate});
  Future<dynamic> call(T newData, {Map<String, String>? arguments});
  Future<dynamic> undo();                     // publishes the previous value from the history
  void disposeScope({bool removeHandler = true});
}
```

`initScope` returns a `Future` that completes after the initial value has gone
through the bus (a handler error is visible to the caller). A repeated call removes the handler
of the previous topic itself. Details are in [05-scope-and-command.md](05-scope-and-command.md).

## Command

```dart
abstract class Command<T> {
  factory Command(EventBus busBinded, {List<String>? paths, int maxLen = 10});

  Future<dynamic> execute(T data, {Map<String, String>? arguments});
  Future<dynamic> undo();                 // publishes the previous value; null if there is nothing to roll back
  EventBus get bindedBus;
  int get queueLength;                    // history depth
  List<String>? get paths;
  (T data, Map<String, String>? arguments)? get lastCall;
}

class CommandImpl<T> implements Command<T> {
  CommandImpl(EventBus bus, {List<String>? paths, int maxLen = 10});
}
```

`execute` calls `request` when the bus has a handler for the topic, otherwise `fire` and returns
`null`. `maxLen` is the call history depth; values less than 1 are clamped to 1. For a meaningful
`undo` you need at least two calls in the history, so the practical minimum is 2.
`maxLen` is a field of `CommandImpl`, not a member of the `Command<T>` interface.

## EventBusLogger

```dart
mixin class EventBusLogger {
  bool add(EventBus bus, {LoggerHandler handler = defaultLoggerHandler});   // true if the subscription was created
  bool remove(EventBus bus);                                                // true if the subscription existed
  static void defaultLoggerHandler(EventDTO dto, bool hasDelivered);        // print(...)
}
```

`add` subscribes to the `allEventStream` of the given bus; a repeated `add` for the same bus returns
`false`. When `allEventStream` closes, the subscription is removed automatically (`onDone`).
The default handler prints `Event:<topic> hasListeners <bool>`, where `<topic>` is the routing key
and the boolean means "the event reached a node".

## Errors

```dart
class EventBusException implements Exception {
  final dynamic message;
  EventBusException([this.message]);
  String toString();      // 'EventBusException: <message>'
}

class NoHandlerException extends EventBusException {
  NoHandlerException(String topic);   // 'no request handler for "<topic>"'
  final String topic;
}
```

`EventBusException` is used in `Topic` (an address that cannot be parsed or built),
`Scope`/`Command` (access before initialization), `EventBusIsolate` (exchange problems), and for
wildcard paths passed to `fire`/`request`. `NoHandlerException` is thrown by `request` when no
handler accepts the value. `StateError` is thrown when a closed (`disposed`) bus is used — this
is a usage error, not a domain error.

## What is not exported

* Internal types: `_FSM`, `_FSMNode`, `_EventBusForIsolate`, `_IsolateLink`, `_LayerInitDto`,
  `_worker`, `_initLayer`, and the service messages of the isolate protocol.
* Transport packages are separate: `packages/event_bus_arch_transport`, `packages/event_bus_arch_nats`,
  `packages/event_bus_arch_mqtt`.

## What is missing from the API

* no wildcard paths in `fire`/`request` — only listeners, nodes and handlers may use patterns;
* no regular expressions or partial-token wildcards: `*` and `>` are whole tokens;
* no unsubscribe "by topic" without a subscription: only `cancel()` on a `StreamSubscription`;
* no event replay for new subscribers (`replay`) — use `currentData` and the model bus for that;
* no priorities for handlers and listeners; one handler per topic;
* no buffering in `allEventStream` — the stream is broadcast, with no buffer;
* no multiple handlers per topic (use subscriptions or different `paths`).
