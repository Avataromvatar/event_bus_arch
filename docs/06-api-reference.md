# 06. API Reference

[← 05. Scope and Command](05-scope-and-command.md) · [Contents](README.md) · [Next: Pitfalls →](07-caveats.md)

The entire public API lives in a single library — `package:event_bus_arch/event_bus_arch.dart`
(library name `event_arch`, assembled from `part` files). The package **re-exports `rxdart`**, so
`BehaviorSubject`, `doOnCancel`, `debounceTime` and the rest are available through it — no
separate import is needed.

## Contents

* [Typedefs](#typedefs)
* [Topic](#topic) / [EventTopicImpl](#eventtopicimpl)
* [EventDTO](#eventdto) / [EventDTOImpl](#eventdtoimpl)
* [EventNode](#eventnode)
* [EventBus](#eventbus) / [EventBusHandlers](#eventbushandlers) / [EventBusImpl](#eventbusimpl) / [EventBusMixin](#eventbusmixin)
* [EventBusIsolate](#eventbusisolate)
* [Layer](#layer) / [Layers](#layers)
* [FSM](#fsm)
* [Scope](#scope) / [Command](#command)
* [EventBusLogger](#eventbuslogger)
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

`abstract class Topic` — the event address (format details are in [01-architecture.md](01-architecture.md#1-topic--the-event-address)).

```dart
// Getters
String get shema;                       // 'event'
String? get target;                     // 'all' by default
String get type;                        // type name (lowercase), e.g. 'string'
String get host;                        // 'target.type'
String get path;                        // '/p' or ''
String? get fragment;
Map<String, String>? get arguments;
String get topic;                       // routing key: fragment and arguments are not included
String get topicWithFragment;
String get fullTopic;                   // full URI

// Creation
static Topic create<T>({String? target, String? path, String? fragment, Map<String, String>? arguments});
factory Topic.fromParametr({Type? type, String? nameType, String? target, String? path,
                            String? fragment, Map<String, String>? arguments});
factory Topic.parse(String fullTopic);   // == fromString
factory Topic.fromString(String topic);

Topic copy({String? target, String? fragment, Map<String, String>? arguments});
String toString();                       // returns fullTopic
```

Equality: by `topic` (the scheme + `target.type` + `path`). `fragment` and `arguments` are ignored,
so topics that differ only in them are equal.

`Topic.create<T>` takes only the type and the parameters; `Topic.fromParametr` additionally accepts a `Type`
or a `nameType` (string type name) and **requires at least one of them**, otherwise it throws
`Exception('Topic.create required type or nameType !')`.

## EventTopicImpl

`class EventTopicImpl implements Topic` — the only implementation, returned by all factories.

```dart
EventTopicImpl.parse(String topic);      // uses Uri.tryParse; throws EventBusException on failure
EventTopicImpl.create({Type? type, String? nameType, String target = 'all', String? path,
                       String? fragment, String scheme = 'event',
                       @Deprecated('Use scheme') String? shema,
                       Map<String, String>? arguments});
Topic copy({String? target, String? scheme, String? fragment,
            Map<String, String>? arguments, String? path});
```

`copy` keeps the `path`, `fragment` and `arguments` of the source topic unless they are overridden.
In debug mode an `assert` rejects a dot in `target` and in the type name: the topic host is
`target.type`, and a dot inside a part breaks addressing.

## EventDTO

```dart
abstract class EventDTO<T> {
  Topic get topic;
  T get data;
  Completer? get completer;              // response channel, may be null

  static EventDTO<T> create<T>(T data, {String? target, String? path,
      Map<String, String>? arguments, String? fragment, Completer? completer});

  factory EventDTO(T data, {Topic? topic, String? target, String? path,
      Map<String, String>? arguments, String? fragment, Completer? completer});

  Map<String, dynamic> toJson();
}
```

The factory creates `EventDTOImpl`. If `topic` is not passed, it is built from `T` and the
`target`/`path`/`fragment`/`arguments` parameters.

## EventDTOImpl

```dart
class EventDTOImpl<T> implements EventDTO<T> {
  EventDTOImpl(Topic topic, T data, {Completer? completer});   // topic and data are positional!

  Topic topic;
  T data;
  Completer? completer;

  static EventDTO<T> fromJson<T>(Map<String, dynamic> json,
      {T Function(String topic, dynamic data)? dataConverter});

  Map<String, dynamic> toJson();     // {'topic': fullTopic, 'data': data} — without encoding
  bool operator ==(Object other);    // by (topic, data)
  int get hashCode;                  // Object.hashAll([topic, data])
  String toString();                 // 'EventDTO(<fullTopic>, data: <data>)'
}
```

`toJson` returns the data **as is**, without `jsonEncode`: encoding is the caller's
job, so an arbitrary object in `data` no longer breaks either `toJson` or `toString`.

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
EventBusHandlers get handlers;                 // bus.handlers.setHandler(...) without a cast
Future<void> dispose();                        // idempotent; after it the bus throws StateError
bool get isDisposed;
Stream<(EventDTO, bool)> get allEventStream;   // (event, whether it reached a node)

Future<dynamic>? send<T>(T data, {String? path, String? fragment, String? target,
                                  Map<String, String>? arguments});
Stream<T> listen<T>({String? path, String? target});
StreamSubscription<T> subscribe<T>({String? path, String? target, void Function(T e)? onData,
                                    Function? onError, void Function()? onDone, bool? cancelOnError});
T? lastData<T>({String? path, String? target});

bool haveHandler<T>({String? path, String? target});
bool haveListener<T>({String? path, String? target});
```

Behavior is described in [02-event-bus.md](02-event-bus.md#sending-an-event). After `dispose` the
`send`/`listen`/`subscribe`/`setHandler` methods throw `StateError`.

## EventBusHandlers

A separate interface for managing handlers (accessible through a cast: `bus as EventBusHandlers`).

```dart
void setHandler<T>({
  T? initialData,                              // initial value of lastData
  @Deprecated('Use initialData') T? initalData,
  String? path,
  String? target,
  required Handler<T> handler,
});
void removeHandler<T>({String? path, String? target});
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
    Object? initalData,           // @Deprecated name: initialData
  });

  final FutureOr<void> Function(EventBus isolateBu, Object? initalData) onInit;
  Future<bool> get waitInit;      // true — the worker completed onInit; an error — the isolate failed to start
  bool get isInit;                // true after a successful onInit
  bool get isDisposed;

  @override
  Future<dynamic> send<T>(T data, {String? path, String? fragment, String? target,
                                   Map<String, String>? arguments});   // throws StateError before waitInit
  Future<bool> ping({Duration timeout = const Duration(seconds: 2)});     // liveness check
  @override
  Future<void> dispose();         // completes the waits, closes the port, kills the isolate
}
```

Inherits `listen`, `subscribe`, `lastData`, `haveHandler`, `haveListener`, `allEventStream` from
`EventBusImpl`. Note: `onInit` is a public field, but assigning it again restarts
nothing (the isolate is already created in the constructor).

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
      FSMFilter<T, E>? filter, String? eventTarget, String? eventPath,
      String? eventFragment, Map<String, String>? arguments});
  void changeState(T newState);
  @Deprecated('Use changeState') void changeStateByEvent(T newState);

  /// Unsubscribes the machine from the bus; a repeated initFSM turns it on again
  void dispose();
}
```

Details and transition rules — [04-fsm.md](04-fsm.md).

## Scope

```dart
mixin class Scope<T> {
  T? lastData;
  void Function(T newData)? onUpdate;

  EventBus? get scopeBus;     // throws EventBusException if not initialized
  (T?, String?, Map<String, String>?)? get lastCall;   // (data, fragment, arguments)

  Future<void> initScope(EventBus bus, {
      T? initialData,
      @Deprecated('Use initialData') T? initalData,
      bool initialDataNeedExecute = true,
      @Deprecated('Use initialDataNeedExecute') bool? initalDataNeedExecute,
      String? path,
      int maxLenForUndo = 10,       // history depth; undo needs >= 2
      void Function(T newData)? onUpdate});
  Future<dynamic> call(T newData, {String? fragment, Map<String, String>? arguments});
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
  factory Command(EventBus busBinded, {String? path, int maxLen = 10});

  Future<dynamic> execute(T data, {String? fragment, Map<String, String>? arguments});
  Future<dynamic> undo();                 // sends the previous value; null if there is nothing to roll back
  EventBus get bindedBus;
  int get queueLength;                    // history depth
  @Deprecated('Use queueLength') int get queueLenght;
  String? get path;
  (T data, String? fragment, Map<String, String>? arguments)? get lastCall;
}

class CommandImpl<T> implements Command<T> {
  CommandImpl(EventBus bus, {String? path, int maxLen = 10});
}
```

`maxLen` is the call history depth; values less than 1 are clamped to 1. For a meaningful
`undo` you need at least two calls in the history, so the practical minimum is 2.

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

## Errors

```dart
class EventBusException implements Exception {
  final dynamic message;
  EventBusException([this.message]);
  String toString();      // 'EventBusException: <message>'
}
```

`EventBusException` is exported and used in `Topic` (an invalid topic), `Scope`/`Command`
(access before initialization), and `EventBusIsolate` (exchange problems with the isolate). `StateError`
is thrown when a closed (`disposed`) bus is used — this is a usage error,
not a domain error.

## What is not exported

* Internal types: `_FSM`, `_FSMNode`, `_EventBusForIsolate`, `_IsolateLink`, `_LayerInitDto`,
  `_worker`, `_initLayer`, service messages of the isolate protocol, the `_targetDefault` and
  `_shema` constants.

## What is missing from the API

* no unsubscribe "by topic" without a subscription: only `cancel()` on a `StreamSubscription`;
* no event replay for new subscribers (`replay`) — use `lastData` and the model bus for that;
* no templates/masks in `path` and `target` — matching is always exact;
* no priorities for handlers and listeners; one handler per topic;
* no buffering in `allEventStream` — the stream is broadcast, with no buffer;
* no multiple handlers per topic (use subscriptions or different `target`/`path`).
