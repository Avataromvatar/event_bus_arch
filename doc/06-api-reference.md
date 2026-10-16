# 06. API Reference

[← 05. Scope and Command](05-scope-and-command.md) · [Contents](README.md) · [Next: Pitfalls →](07-caveats.md)

The entire public API lives in a single library — `package:event_bus_arch/event_bus_arch.dart`
(library name `event_arch`, assembled from `part` files). The package **re-exports `rxdart`**, so
`BehaviorSubject`, `doOnCancel`, `debounceTime` and the rest are available through it — no
separate import is needed.

## Contents

* [Typedefs](#typedefs)
* [Topic](#topic) / [TopicImpl](#topicimpl)
* [EventDTO](#eventdto) / [EventDTOImpl](#eventdtoimpl)
* [EventNode](#eventnode)
* [EventBus](#eventbus) / [EventBusHandlers](#eventbushandlers) / [EventBusImpl](#eventbusimpl) / [EventBusMixin](#eventbusmixin)
* [EventBusIsolate](#eventbusisolate)
* [Layer](#layer) / [Layers](#layers)
* [FSM](#fsm)
* [Scope](#scope) / [Command](#command)
* [EventBusLogger](#eventbuslogger)
* [Errors](#errors)
* [What is not exported](#what-is-not-exported)

## Typedefs

```dart
typedef Handler<T> = Future<void> Function(EventDTO<T> dto, T? lastData);
typedef Node<T> = EventNode<T>;

typedef FSMHandler<T, E> =
    Future<Object?> Function(T currentState, T lastState, E event, List<EventDTO> ignoredEvents);
typedef FSMFilter<T, E> = bool Function(T currentState, T lastState, E event);

typedef fnInitLayer = FutureOr<void> Function(Layer layer, Object? initialData);
typedef LoggerHandler = void Function(EventDTO dto, bool hasListeners);
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

**Equality is by `topic`** — the type, the separator and the paths in the string form. `arguments`
live on the [EventDTO](#eventdto) and are not part of the address, so two calls that differ only in
`arguments` reach the same handler. The comparison is `other is Topic`, so any implementation with
the same routing key is equal.

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

Two things worth knowing about the class itself:

* `TopicImpl implements Topic`, so the `toString` body on the abstract class is **not** inherited —
  the implementation repeats it. Without that override `toString` would be
  `Instance of 'TopicImpl'`.
* `paths` is held as passed, not copied. Do not mutate the list you handed in: the routing key and
  the hash are computed from it on every access, so a mutation changes the address of a topic that
  is already a key in `_eventsMap`.

## EventDTO

```dart
abstract class EventDTO<T> {
  Topic get topic;
  T get data;
  Map<String, String>? get arguments;    // parameters of this call; not part of the address
  Completer? get completer;              // response channel, may be null

  static EventDTO<T> create<T>(T data, {List<String>? paths, String? separator,
      Map<String, String>? arguments, Completer? completer});

  factory EventDTO(T data, {Topic? topic, List<String>? paths, String? separator,
      Map<String, String>? arguments, Completer? completer});

  Map<String, dynamic> toJson();
}
```

The factory creates `EventDTOImpl`. If `topic` is not passed, it is built from `T` and the
`paths`/`separator` parameters; `separator` defaults to `'.'` when not given.

`arguments` reach the handler on the DTO it is given: the node rebuilds the event for type `T` and
carries `topic`, `arguments` and `completer` over. `EventBusIsolate` does the same, so `arguments`
survive the isolate boundary.

## EventDTOImpl

```dart
class EventDTOImpl<T> implements EventDTO<T> {
  EventDTOImpl(Topic topic, T data, {Completer? completer, Map<String, String>? arguments});
                                                       // topic and data are positional!

  Topic topic;
  T data;
  Completer? completer;
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

`class EventNode<T>` — the topic cell: a handler + the latest data + two broadcast streams.

```dart
EventNode({T? lastData, Handler<T>? handler});

T? lastData;                    // the last value sent
Handler<T>? handler;            // handler (can be replaced at any time)
bool get isDisposed;            // whether the event stream is closed
bool get isHaveHandler;         // handler != null

void send(EventDTO dto);        // called by the bus; checks dto.data is T
Future<void> dispose();         // close both streams and cancel the subscription
```

`typedef Node<T> = EventNode<T>;` — an alias.

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

Future<dynamic>? send<T>(T data, {List<String>? paths, String? separator,
                                  Map<String, String>? arguments});
Stream<T> listen<T>({List<String>? paths, String? separator});
StreamSubscription<T> subscribe<T>({List<String>? paths, String? separator,
                                    void Function(T e)? onData, Function? onError,
                                    void Function()? onDone, bool? cancelOnError});
T? lastData<T>({List<String>? paths, String? separator});

bool haveHandler<T>({List<String>? paths, String? separator});
bool haveListener<T>({List<String>? paths, String? separator});
```

Every method that takes an address resolves `separator ?? defaultTopicPathSeparator`, so changing
the field on an `EventBusImpl` changes the fallback for all of them at once:

```dart
final bus = EventBusImpl(false);
bus.defaultTopicPathSeparator = '/';
bus.handlers.setHandler<int>(paths: ['a', 'b'], handler: ...);   // int/a/b
await bus.send<int>(1, paths: ['a', 'b']);                       // int/a/b — found
```

`defaultTopicPathSeparator` is a **field** on `EventBusMixin`, not a setter on the interface, so a
variable of type `EventBus` has to be cast (`(bus as EventBusImpl).defaultTopicPathSeparator = '/'`).

Behavior is described in [02-event-bus.md](02-event-bus.md#sending-an-event). After `dispose` the
`send`/`listen`/`subscribe`/`setHandler` methods throw `StateError`.

## EventBusHandlers

A separate interface for managing handlers (accessible through a cast: `bus as EventBusHandlers`).

```dart
void setHandler<T>({
  T? initialData,                              // initial value of lastData
  List<String>? paths,
  String? separator,
  required Handler<T> handler,
});
void removeHandler<T>({List<String>? paths, String? separator});
void addAllHandlerFromOtherBus(EventBus fromBus);
void removeAllHandlerPresentInOtherBus(EventBus otherBus);
```

## EventBusImpl

```dart
class EventBusImpl with EventBusMixin {
  EventBusImpl(bool isModelBus);
  bool get isModelBus;
}
```

All the behavior comes from the mixin; the class's own code only stores the flag.

## EventBusMixin

```dart
mixin EventBusMixin implements EventBus, EventBusHandlers {
  String defaultTopicPathSeparator = '.';         // the address fallback, writable
  // all EventBus and EventBusHandlers methods
  EventBusHandlers get handlers;                  // returns this
  bool get isDisposed;
  bool removeNode(Topic topic, EventNode node);   // removes the node if it is empty and the bus is not model
  Future<void> dispose();                         // idempotent; closes allEventStream and the nodes
}
```

`removeNode` returns `true` if the node was removed. It is called automatically when the
last subscription is cancelled.

## EventBusIsolate

```dart
class EventBusIsolate extends EventBusImpl {
  EventBusIsolate({
    required FutureOr<void> Function(EventBus bus, Object? initialData) onInit,  // can be async
    Object? initialData,
  });

  final FutureOr<void> Function(EventBus isolateBu, Object? initialData) onInit;
  Future<bool> get waitInit;      // true — the worker completed onInit; an error — the isolate failed to start
  bool get isInit;                // true after a successful onInit
  bool get isDisposed;

  @override
  Future<dynamic> send<T>(T data, {List<String>? paths, String? separator,
                                   Map<String, String>? arguments});   // throws StateError before waitInit
  Future<bool> ping({Duration timeout = const Duration(seconds: 2)});     // liveness check
  @override
  Future<void> dispose();         // completes the waits, closes the port, kills the isolate
}
```

Inherits `listen`, `subscribe`, `lastData`, `haveHandler`, `haveListener`, `allEventStream` from
`EventBusImpl`. Note: `onInit` is a public field, but assigning it again restarts
nothing (the isolate is already created in the constructor).

`send` on the isolate side **is** the boundary call: it builds the DTO, serializes it through the
`SendPort` and awaits the reply. Paths, separator and arguments cross with it, so a worker handler
addressed by paths answers on the same address.

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
       Duration? timeout});                           // timeout for initializing the chain
}
```

Returns the top `Layer` when **all** layers of the chain are initialized; an init error
in any layer and an empty list come as an `EventBusException`.
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
event has to be sent with the same type and paths to match. `arguments` never take part in the
lookup — in 2.x a transition also took `eventTarget`/`eventPath`/`eventFragment`.

`changeStateByEvent` is a kept alias for `changeState`; it is the only deprecated member left in
the package.

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
  Future<dynamic> undo();                     // sends the previous value from the history
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
  Future<dynamic> undo();                 // sends the previous value; null if there is nothing to roll back
  EventBus get bindedBus;
  int get queueLength;                    // history depth
  List<String>? get paths;
  (T data, Map<String, String>? arguments)? get lastCall;
}

class CommandImpl<T> implements Command<T> {
  CommandImpl(EventBus bus, {List<String>? paths, int maxLen = 10});
}
```

`maxLen` is the call history depth; values less than 1 are clamped to 1. For a meaningful
`undo` you need at least two calls in the history, so the practical minimum is 2.
`maxLen` is a field of `CommandImpl`, not a member of the `Command<T>` interface.

## EventBusLogger

```dart
mixin class EventBusLogger {
  bool add(EventBus bus, {LoggerHandler handler = defaultLoggerHandler});   // true if the subscription was created
  bool remove(EventBus bus);                                                // true if the subscription existed
  static void defaultLoggerHandler(EventDTO dto, bool hasListeners);        // print(...)
}
```

`add` subscribes to the `allEventStream` of the given bus; a repeated `add` for the same bus returns
`false`. When `allEventStream` closes, the subscription is removed automatically (`onDone`).
The default handler prints `Event:<topic> hasListeners <bool>`, where `<topic>` is the routing key.

## Errors

```dart
class EventBusException implements Exception {
  final dynamic message;
  EventBusException([this.message]);
  String toString();      // 'EventBusException: <message>'
}
```

`EventBusException` is exported and used in `Topic` (an address that cannot be parsed or built),
`Scope`/`Command` (access before initialization), and `EventBusIsolate` (exchange problems with the
isolate). `StateError` is thrown when a closed (`disposed`) bus is used — this is a usage error,
not a domain error.

## What is not exported

* Internal types: `_FSM`, `_FSMNode`, `_EventBusForIsolate`, `_IsolateLink`, `_LayerInitDto`,
  `_worker`, `_initLayer`, and the service messages of the isolate protocol.

## What is missing from the API

* no unsubscribe "by topic" without a subscription: only `cancel()` on a `StreamSubscription`;
* no event replay for new subscribers (`replay`) — use `lastData` and the model bus for that;
* no templates/masks in `paths` — matching is always exact, on the whole routing key;
* no priorities for handlers and listeners; one handler per topic;
* no buffering in `allEventStream` — the stream is broadcast, with no buffer;
* no multiple handlers per topic (use subscriptions or different `paths`).
