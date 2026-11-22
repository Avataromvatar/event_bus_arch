# 06. API Reference

[← 05. Scope and Command](05-scope-and-command.md) · [Contents](README.md) · [Next: Pitfalls →](07-caveats.md)

The core public API lives in `package:event_bus_arch/event_bus_arch.dart` (library name
`event_arch`, assembled from `part` files). The pattern types — `FSM`, `Scope`, `Command` — live
in `package:event_bus_arch_patterns/event_bus_arch_patterns.dart` and are described at the end of
this page. The package does not re-export `rxdart`; add it to your own dependencies if you need
its operators. The isolation APIs are VM-only; see `EventBusCapabilities` below.

## Contents

* [Typedefs](#typedefs)
* [EventAddress](#eventaddress) / [EventPattern](#eventpattern)
* [EventKey](#eventkeyt) / [EventPatternKey](#eventpatternkeyt) / [EventSelector](#eventselectort)
* [EventDTO](#eventdto) / [EventDTOImpl](#eventdtoimpl)
* [EventNode](#eventnode) / [EventSubscription](#eventsubscription)
* [EventBus](#eventbus) / [EventBusImpl](#eventbusimpl) / [EventBusMixin](#eventbusmixin)
* [EventBusError](#eventbuserror) / [EventBusErrorMonitor](#eventbuserrormonitor)
* [EventBusMetrics](#eventbusmetrics) / [ObservabilityConfig](#observabilityconfig)
* [EventBusIsolate](#eventbusisolate)
* [Layer](#layer) / [Layers](#layers) / [LayersSupervisor](#layerssupervisor)
* [WorkerPool](#workerpool) / [SupervisionPolicy](#supervisionpolicy)
* [Patterns package](#patterns-fsm-scope-command) — [FSM](#fsm), [Scope](#scope) / [Command](#command)
* [EventBusLogger](#eventbuslogger)
* [EventBusCapabilities](#eventbuskapabilities)
* [Errors](#errors)
* [What is not exported](#what-is-not-exported)

## Typedefs

```dart
typedef EventCallback<T> = FutureOr<void> Function(T event);   // listener
typedef Handler<T> = Future<dynamic> Function(EventDTO<T> dto, T? lastData); // responder
typedef Node<T> = EventNode<T>;

typedef WorkerInit = FutureOr<void> Function(EventBus bus, Object? initialData);
typedef WorkerKeySelector = Object? Function(EventDTO dto);
typedef MetricKeyBuilder = String Function(String address);
typedef EventBusErrorFilter = bool Function(EventBusError error);

typedef fnInitLayer = FutureOr<void> Function(Layer layer, Object? initialData);
typedef LoggerHandler = void Function(EventDTO dto, bool hasDelivered);
```

## EventAddress

`final class EventAddress` — the event identity. The format, the grammar and the equality rules
are in [01-architecture.md](01-architecture.md#1-eventaddress-and-keys--the-event-identity).

```dart
EventAddress(String value);          // validates and throws EventBusException
factory EventAddress.parse(String value);

static const String separator = '.';        // the grammar rule, not a setting
static const String singleWildcard = '*';   // one token
static const String tailWildcard = '>';     // one or more trailing tokens

final String value;                 // the identity string
List<String> get tokens;            // split on '.'; unmodifiable
```

An exact address rejects an empty string, empty tokens (`a..b`, `.a`, `a.`) and wildcards.
`EventAddress` compares by `value`. `arguments` live on the [EventDTO](#eventdto) and are not part
of the address, so two calls that differ only in `arguments` reach the same handler.

```dart
EventAddress('orders.placed.v1').tokens;   // ['orders', 'placed', 'v1']
EventAddress('orders.*');                  // throws EventBusException
```

## EventPattern

`final class EventPattern` — a wildcard pattern over addresses.

```dart
EventPattern(String value);                 // validates and throws EventBusException
factory EventPattern.parse(String value);

final String value;
List<String> get tokens;                    // unmodifiable
bool get hasWildcard;
int get specificity;                        // number of literal tokens
bool matches(EventAddress address);

static const String singleWildcard = '*';
static const String tailWildcard = '>';
```

A wildcard must occupy a whole token (`sen*or` is rejected); `>` must be the last token. A
pattern cannot be an exact address: `EventPattern('orders.placed')` is valid syntactically, but it
matches only that address and should usually be an `EventKey` instead.

```dart
EventPattern('sensor.*').matches(EventAddress('sensor.temp'));   // true
EventPattern('sensor.*').matches(EventAddress('sensor.a.b'));    // false
EventPattern('sensor.>').matches(EventAddress('sensor.a.b'));    // true
```

## EventKey<T>

`final class EventKey<T> extends EventSelector<T>` — an exact address plus the static type.

```dart
EventKey(String address);
EventKey.fromAddress(EventAddress address);

final EventAddress address;
Type get type;              // captured from T; stable under minification
bool accepts(Object? data); // data is T
bool operator ==(Object other);   // (address, type)
int get hashCode;                 // Object.hash(address, type)
String toString();                // address.value
```

The type is not part of the address. Two keys with the same address and different types are
different nodes with separate `currentData`.

## EventPatternKey<T>

`final class EventPatternKey<T> extends EventSelector<T>` — a wildcard pattern plus the type.

```dart
EventPatternKey(String pattern);
EventPatternKey.fromPattern(EventPattern pattern);

final EventPattern pattern;
Type get type;
bool matches(EventAddress address);
bool accepts(Object? data); // data is T
bool operator ==(Object other);   // (pattern, type)
int get hashCode;                 // Object.hash(pattern, type)
String toString();                // pattern.value
```

## EventSelector<T>

`sealed class EventSelector<T>` — the base of `EventKey<T>` and `EventPatternKey<T>`. A bus method
that can take a pattern (`listen`, `subscribe`, `subscribeEvents`, `have*`) accepts an
`EventSelector<T>`; `fire`, `request` and `currentData` require an `EventKey<T>`.

```dart
Type get type;
bool accepts(Object? data) => data is T;
```

## EventDTO

```dart
abstract class EventDTO<T> {
  EventKey<T> get key;
  String get address;                    // key.address.value
  T get data;
  Map<String, String>? get arguments;    // parameters of this call; not part of the address
  String? get correlationId;             // optional cross-boundary correlation

  EventDTO<T> copyWith({T? data, EventKey<T>? key,
      Map<String, String>? arguments, String? correlationId});

  static EventDTO<T> create<T>(T data, {EventKey<T>? key, ...}); // compatibility
  factory EventDTO.withKey(EventKey<T> key, T data,
      {Map<String, String>? arguments, String? correlationId});

  Map<String, dynamic> toJson();
}
```

New code uses `EventDTO.withKey(key, data, ...)`. There is no completer: a handler returns its
result, `request` awaits it, and `fire` has no result channel. `arguments` and `correlationId`
reach the handler on the DTO it is given, including across an isolate and a transport.

## EventDTOImpl

```dart
class EventDTOImpl<T> implements EventDTO<T> {
  EventDTOImpl.withKey(EventKey<T> key, T data,
      {Map<String, String>? arguments, String? correlationId});

  EventKey<T> key;
  T data;
  Map<String, String>? arguments;
  final String? correlationId;

  static EventDTO<T> fromJson<T>(Map<String, dynamic> json,
      {EventKey<T>? key,
       T Function(String address, dynamic data)? dataConverter});

  Map<String, dynamic> toJson();     // {'topic': address, 'data': ..., maybe 'correlationId'}
  bool operator ==(Object other);    // by (address, data)
  int get hashCode;                  // Object.hash(address, data)
  String toString();                 // 'EventDTO(<address>, data: <data>)'
}
```

`toJson` returns the data **as is**, without `jsonEncode`: encoding is the caller's job, so an
arbitrary object in `data` no longer breaks either `toJson` or `toString`. `arguments` are **not**
part of the JSON form; `correlationId` is included when non-null and restored by `fromJson`.
`fromJson` accepts either the `address` field or the legacy `topic` field as the address. Carry
`arguments` in your own envelope if a wire format has to preserve them.

## EventNode

`abstract class EventNode<T>` — one `(address, Type)` cell: the current value, the listener stream
and the subscriptions of that key. A handler is a capability of an `EventSubscription`, not a node-level
registration.

```dart
T? currentData;                                 // the last delivered value
bool get isDisposed;
StreamController<T> get streamControllerValue;  // legacy stream facade

bool deliver(EventDTO dto);                     // store the value, fan out to subscriptions
EventNode<T> copy();                            // independent node with the same value
Future<void> dispose();                         // close the value stream and subscriptions

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
int get maxBufferedRequests;           // largest queue depth observed (metrics on)
LatencySnapshot? get queueWaitLatency; // queue-wait histogram (metrics on)
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
  `.stream` view. `onDone` is called only when the node is disposed (`dispose`, `remove`).
* Listener errors go to the subscription-level `onError` and to `bus.errors` (kind `listener`);
  `cancelOnError` also cancels the subscription. `capturePayloads` puts the event into the error
  envelope.
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
class RequestTimeoutException extends EventBusException; // address + timeout
class RequestCanceledException extends EventBusException;
```

`request(..., timeout: ..., cancelToken: ...)` uses both; the first of response, timeout and
cancellation wins.

## EventBus

The abstract bus interface. The factory always returns `EventBusImpl`.

```dart
factory EventBus({bool isModelBus = false, ObservabilityConfig? observability});

bool get isModelBus;
bool get isObservable;                         // observabilityConfig.enabled
EventBusMetrics get metrics;                   // snapshot / changes
Future<void> dispose();                        // idempotent; after it the bus throws StateError
bool get isDisposed;
Stream<(EventDTO, bool)> get allEventStream;   // (event, whether a listener accepted it)
Stream<EventBusError> get errors;              // bus failures as data
List<EventBusError> get recentErrors;          // bounded (100)
int get suppressedErrors;                      // rate-limited errors

bool fire<T>(EventKey<T> key, T data,
    {Map<String, String>? arguments, String? correlationId});
Future<dynamic> request<T>(EventKey<T> key, T data,
    {Map<String, String>? arguments, Duration? timeout,
     CancelToken? cancelToken, String? correlationId});

Stream<T> listen<T>(EventSelector<T> selector);
StreamSubscription<T> subscribe<T>(EventSelector<T> selector,
    {void Function(T e)? onData, Function? onError,
     void Function()? onDone, bool? cancelOnError});
EventSubscription<T> subscribeEvents<T>(EventSelector<T> selector, {
  EventCallback<T>? onEvent,            // listener
  Handler<T>? handler,                  // request responder
  T? initialData,
  int handlerConcurrency = 1,
  int? requestQueueCapacity,            // default: bus.requestQueueCapacity (64)
  int? bufferCapacity,                  // null = unbounded
  BufferOverflow bufferOverflow = BufferOverflow.dropOldest,
  DeliveryMode deliveryMode = DeliveryMode.async,
  void Function(Object error, StackTrace? stackTrace)? onError,
  void Function()? onDone,
  bool cancelOnError = false,
});

T? currentData<T>(EventKey<T> key);
bool remove<T>(EventKey<T> key);
bool removePattern<T>(EventPatternKey<T> key);
bool removeAddress(EventAddress address);

bool haveHandler<T>(EventSelector<T> selector);
bool haveAvailableHandler<T>(EventSelector<T> selector);
bool haveListener<T>(EventSelector<T> selector);
```

`fire` returns true when at least one listener accepted the event, a model bus stored it, or a
transport published it. On an `EventBusIsolate` the same call also reports a known remote
listener/model interest; in both cases a handler subscription alone does not make `fire` return true
(D14).

`request` throws `NoHandlerException` when no handler matches, `BusyException` when handlers exist
but none has capacity, `RequestTimeoutException` on timeout and `RequestCanceledException` when its
`CancelToken` is cancelled. It requires an `EventKey<T>`; an `EventPatternKey` does not compile.
`currentData` reads only the exact node of that key. `correlationId` is optional; it reaches
handlers and crosses isolates and transports.

`remove(key)` removes one type node; `removePattern(patternKey)` removes one pattern type node;
`removeAddress(address)` removes every type node at an exact address. They forget `currentData`
even on a model bus and even for a transport node with a `KeepAliveNode` pin (the broker
subscription is cancelled). Each returns whether something was removed. Active listeners receive
`done`; handler subscriptions are cancelled with the node. A model bus recreates the node on the
next `fire`, `request` or `listen`.

`haveListener`, `haveHandler` and `haveAvailableHandler` accept an exact or a pattern selector.
A concrete listener check also counts a matching pattern listener; `haveHandler` counts a paused
handler; `haveAvailableHandler` answers whether a request could be accepted now.

After `dispose` the public bus methods throw `StateError`.

## EventBusImpl

```dart
class EventBusImpl with EventBusMixin, /* internal dispatch mixin */ {
  EventBusImpl(bool isModelBus,
      {ObservabilityConfig observability = ObservabilityConfig.disabled});
  bool get isModelBus;
  ObservabilityConfig get observabilityConfig;
}
```

All behavior comes from the mixins; the class's own code only stores the model flag and the
observability config. The dispatch mixin is private: request resolution, tier selection,
round-robin and the request lifecycle.

## EventBusMixin

`mixin EventBusMixin implements EventBus` — delivery, node lifecycle and the bus flags.

```dart
int requestQueueCapacity = 64;                  // default for handler subscriptions
ObservabilityConfig get observabilityConfig;
bool get isObservable;
EventBusMetrics get metrics;                    // lazily created
bool get isDisposed;
Stream<EventBusError> get errors;
List<EventBusError> get recentErrors;
int get suppressedErrors;
void reportError(EventBusError error);          // transport/isolate seam

// Hooks for transports:
EventNode<T> createNodeForKey<T>({required EventKey<T> key, T? currentData});
EventNode<T> createPatternNodeForKey<T>({required EventPatternKey<T> key, T? currentData});
bool shouldCreateNodeOnSendKey<T>(EventKey<T> key);   // default: isModelBus

bool remove<T>(EventKey<T> key);                // explicit eviction
Future<void> dispose();                         // idempotent; closes allEventStream and the nodes
```

Inside there are `_eventsMap` (`Map<EventAddress, Map<Type, EventNode>>`), `_patternMap`
(`Map<EventPattern, Map<Type, EventNode>>`), a broadcast `_allEventStream` and a broadcast
`_errorsController`. Automatic cleanup is private: `_removeNode` removes the node from its bucket
and disposes it only if it has no legacy stream listeners, no subscriptions (listener or handler),
no `KeepAliveNode` pin, and the bus is not model. A map entry is removed only when it still holds
the same node instance, so a late cancellation of an already removed node cannot delete its
replacement.

`remove`/`removePattern`/`removeAddress` are the explicit counterparts: they bypass the model-bus
rule and the `KeepAliveNode` pin, remove the node(s), and dispose them (cancelling handler
subscriptions too). `EventBusIsolate` forwards the call to the other side of the bridge.

`createNodeForKey`, `createPatternNodeForKey` and `shouldCreateNodeOnSendKey` are the transport
seam: a transport bus overrides them to create a broker-backed node for keys it knows and to
create one on `fire` when a codec is registered. Local buses keep the defaults.

Request resolution order is exact bucket → most specific matching pattern; competition happens
only inside the resolved tier. `handleIncomingRequest` is public because transports and isolate
bridges live outside this library.

## EventBusError

`class EventBusError` — one bus failure delivered as data through `bus.errors`.

```dart
enum EventBusErrorKind {
  listener, handler, serialization, deserialization, transport,
  isolateInit, isolateDeath, requestTimeout, requestCanceled,
  bufferOverflow, busy, supervision, dispose, other,
}
enum EventBusErrorSource { core, isolate, transport, supervision }

class EventBusError {
  EventBusError({
    required EventBusErrorKind kind,
    required Object error,
    EventBusErrorSource source = EventBusErrorSource.core,
    String? topic,                    // legacy spelling
    String? address,                  // preferred; wins when both are passed
    EventDTO? event,                  // null unless payload capture is enabled
    String? correlationId,            // when the envelope came from a request DTO
    StackTrace? stackTrace,
    Map<String, String> context = const {},
    DateTime? timestamp,
  });

  String? get address => topic;       // the event address
  final String? topic;                // compatibility alias
}
```

The stream never carries stream errors: a listener without `onError` does not receive unhandled
errors for bus failures. Rate limit: 10 per `(kind, address)` per second; the rest increments
`suppressedErrors`. `recentErrors` keeps the last 100.

## EventBusErrorMonitor

Aggregates the error streams of several buses; it is not a static global.

```dart
EventBusErrorMonitor({
  EventBusErrorFilter? filter,
  int recentLimit = 100,
  int? maxErrorsPerSecond = 200,   // null = unlimited
});

bool add(EventBus bus);
bool remove(EventBus bus);
Stream<EventBusError> get errors;
List<EventBusError> get recentErrors;      // bounded by recentLimit
Map<EventBusErrorKind, int> get counts;
int get suppressed;                       // dropped by the monitor-wide limit
EventBusErrorSnapshot snapshot();         // total, suppressed, byKind, byTopic, recent
void resetCounters();
Future<void> dispose();
```

`EventBusErrorSnapshot` exposes `total`, `suppressed`, `byKind`, `byTopic` (key `__none__` for an
error without an address) and `recent`. The monitor filters before counting; each bus keeps its own
per-`(kind, address)` limit from ADR-0004.

## EventBusMetrics / ObservabilityConfig

```dart
class ObservabilityConfig {
  const ObservabilityConfig({
    bool enabled = false,
    bool metrics = true,
    bool tracing = false,
    double sampleRate = 1.0,
    int cardinalityLimit = 1000,
    bool capturePayloads = false,
    MetricKeyBuilder? metricKeyBuilder,
  });
  static const ObservabilityConfig disabled;
}

class EventBusMetrics {
  Stream<EventBusMetricsSnapshot> get changes;
  EventBusMetricsSnapshot snapshot();
  // record... methods are for the bus and adapter implementers
}

abstract interface class EventBusMetricsExporter {
  void export(EventBusMetricsSnapshot snapshot);
}
```

`EventBusMetricsSnapshot` has `timestamp`, `fired`, `delivered`, `dropped`,
`droppedMetricSeries`, `topics` (`TopicMetricsSnapshot`) and `subscriptions`
(`SubscriptionMetricsSnapshot`). Each address has event/request counters and dispatch/request
latency; each subscription has buffer/queue depth, in-flight, concurrency and queue-wait latency.
The metric key defaults to the address string; `cardinalityLimit` routes new keys to `__other__`.
`sampleRate` controls histogram samples only; counters are exact. See
[12](12-observability.md).

## EventBusIsolate

```dart
class EventBusIsolate extends EventBusImpl {
  EventBusIsolate({
    required FutureOr<void> Function(EventBus bus, Object? initialData) onInit,  // can be async
    Object? initialData,
    bool isModelBus = false,   // model bus on both the main side and in the worker
    ObservabilityConfig observability = ObservabilityConfig.disabled,
  });

  final FutureOr<void> Function(EventBus isolateBu, Object? initialData) onInit;
  Future<bool> get waitInit;      // true — onInit done AND interests exchanged; an error — startup failed
  bool get isInit;
  bool get isDisposed;

  @override
  bool fire<T>(EventKey<T> key, T data,
      {Map<String, String>? arguments, String? correlationId}); // outbound only

  @override
  Future<dynamic> request<T>(EventKey<T> key, T data,
      {Map<String, String>? arguments, Duration? timeout,
       CancelToken? cancelToken, String? correlationId});

  Future<bool> restart();                                     // new worker, same main-side bus
  Future<bool> ping({Duration timeout = const Duration(seconds: 2)}); // liveness check

  @override
  Future<void> dispose();
}
```

Inherits `listen`, `subscribe`, `subscribeEvents`, `currentData`, `haveHandler`, `haveListener`,
`isModelBus`, `allEventStream`, `errors` and `metrics` from `EventBusImpl`; the worker side is not
observable through this object.

The bridge is **directional**: local listeners receive incoming events, `fire` goes to the worker
only and is never delivered to this side's listeners. `request` checks a local handler first and
crosses only when the worker has a known handler; with neither it throws `NoHandlerException`
immediately. `restart()` fails pending requests, keeps local nodes/listeners/model state, creates a
new worker and re-handshakes interests; a generation counter ignores late messages. On the web the
constructor throws `UnsupportedError` (see [14](14-web.md)).

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
Details are in [03-isolate-and-layers.md](03-isolate-and-layers.md#2-layers).

## LayersSupervisor

```dart
class Layers {
  static LayersSupervisor supervise(
      List<(fnInitLayer, Object?, bool)> layers, {
      bool currentIsModelBus = true,
      bool bridgeIsModelBus = false,
      Duration? timeout,
      SupervisionPolicy policy = const SupervisionPolicy()});
}

enum LayersState { starting, ready, restarting, failed, closed }

class LayersSupervisor {
  Layer get layer;
  Future<void> get waitInit;
  LayersState get state;
  bool get isReady;
  int get restarts;
  Stream<EventBusError> get errors;
  Future<void> waitReady();
  Future<void> close();
}
```

Any worker layer failure restarts the whole worker chain; the top `Layer`, its `current` bus and the
subscriptions on `layer.bottom` survive (the bridge is restarted in place). Pending requests fail
and are not retried; `fire`/`request` on the bridge throw `StateError` while restarting. On restart
exhaustion the supervisor emits `EventBusErrorKind.supervision` and becomes `failed`. It is VM-only.
See [13](13-pool-and-supervision.md#2-layers-supervision).

## WorkerPool

```dart
class WorkerPool {
  WorkerPool({
    required WorkerInit onInit,
    int workers = 1,
    DispatchStrategy dispatch = DispatchStrategy.roundRobin,
    SupervisionPolicy supervision = const SupervisionPolicy(),
    int? maxInFlightPerWorker = 64,
    Object? initialData,
    Object? Function(int index)? initialDataFor,
    bool isModelBus = false,
    WorkerKeySelector? keySelector,
  });

  Future<void> get waitInit;
  Future<void> waitReady();
  bool get isReady;
  bool get isUsable;
  WorkerPoolState get state;
  int get restarts;
  Stream<EventBusError> get errors;
  WorkerPoolMetrics get metrics;

  bool fire<T>(EventKey<T> key, T data,
      {Map<String, String>? arguments, String? correlationId});
  Future<dynamic> request<T>(EventKey<T> key, T data,
      {Map<String, String>? arguments, Duration? timeout,
       CancelToken? cancelToken, String? correlationId});
  Future<void> close();
  Future<void> dispose();
}

enum DispatchStrategy { broadcast, roundRobin, keyed, leastBusy, single }
enum WorkerPoolState { starting, ready, restarting, failed, closed }

class SupervisionPolicy {
  const SupervisionPolicy({
    int maxRestarts = 5,
    Duration window = const Duration(minutes: 1),
    Duration initialBackoff = const Duration(milliseconds: 100),
    Duration maxBackoff = const Duration(seconds: 10),
    double multiplier = 2.0,
  });
  Duration delayFor(int attempt);
}
```

`WorkerPoolMetrics` has `state`, `workers`, `readyWorkers`, `fired`, `accepted`, `dropped`,
`requests`, `failedRequests`, `restarts` and `perWorker` (`WorkerMetrics` with index, ready,
in-flight, fired, requests, restarts). `broadcast` requests throw `UnsupportedError`; `keyed`
never reroutes a key. A dead worker restarts with backoff; pending requests fail and are not
retried. VM-only; see [13](13-pool-and-supervision.md).

## Patterns: FSM, Scope, Command

These three types are **not** part of `event_bus_arch`; they live in
`event_bus_arch_patterns`, so the core stays a routing library:

```yaml
dependencies:
  event_bus_arch_patterns: ^0.1.0
```

```dart
import 'package:event_bus_arch_patterns/event_bus_arch_patterns.dart';
```

```dart
typedef FSMHandler<T, E> =
    Future<Object?> Function(T currentState, T lastState, E event, List<EventDTO> ignoredEvents);
typedef FSMFilter<T, E> = bool Function(T currentState, T lastState, E event);
```

## FSM

```dart
mixin class FSM<T> {
  T get state;
  T get lastState;

  void initFSM(EventBus bus, T currentState, {T? lastState});
  void addFSMTransition<E>(T fromState, T toState, {
      required EventSelector<E> selector,
      FSMHandler<T, E>? handler,
      FSMFilter<T, E>? filter});
  void changeState(T newState);
  @Deprecated('Use changeState') void changeStateByEvent(T newState);

  /// Unsubscribes the machine from the bus; a repeated initFSM turns it on again
  void dispose();
}
```

`addFSMTransition` registers the transition under an `EventSelector<E>`: an exact `EventKey<E>` or
an `EventPatternKey<E>`. The payload must be an `E` at delivery time. An exact selector beats a
pattern; among patterns the most specific wins. `arguments` never take part in the lookup. Both
`fire` and `request` feed `allEventStream`, so either can drive a transition.

Details and transition rules — [04-fsm.md](04-fsm.md).

## Scope

```dart
mixin class Scope<T> {
  T? lastData;
  void Function(T newData)? onUpdate;

  EventBus? get scopeBus;     // throws EventBusException if not initialized
  (T?, Map<String, String>?)? get lastCall;   // (data, arguments)

  Future<void> initScope(EventBus bus, EventKey<T> key, {
      T? initialData,
      bool initialDataNeedExecute = true,
      int maxLenForUndo = 10,       // history depth; undo needs >= 2
      void Function(T newData)? onUpdate});
  Future<dynamic> call(T newData, {Map<String, String>? arguments});
  Future<dynamic> undo();                     // publishes the previous value from the history
  void disposeScope();                        // cancels the scope's own subscription
}
```

`initScope` returns a `Future` that completes after the initial value has gone
through the bus (a handler error is visible to the caller). The scope subscribes with
`bufferCapacity: 1`, `BufferOverflow.latest`. A repeated `initScope` cancels the previous
subscription; `disposeScope()` cancels only the scope's own subscription (there is no
`removeHandler:` parameter in 4.0). Details are in [05-scope-and-command.md](05-scope-and-command.md).

## Command

```dart
abstract class Command<T> {
  factory Command(EventBus busBinded, EventKey<T> key, {int maxLen = 10});

  Future<dynamic> execute(T data, {Map<String, String>? arguments});
  Future<dynamic> undo();                 // publishes the previous value; null if there is nothing to roll back
  EventBus get bindedBus;
  EventKey<T> get key;
  int get queueLength;                    // history depth
  (T data, Map<String, String>? arguments)? get lastCall;
}

class CommandImpl<T> implements Command<T> {
  CommandImpl(EventBus bus, EventKey<T> key, {int maxLen = 10});
}
```

`execute` calls `request` when the bus has a handler for the key, otherwise `fire` and returns
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
The default handler prints `Event:<address> hasListeners <bool>`, where `<address>` is the event
address and the boolean means "the event reached a node".

## EventBusCapabilities

```dart
abstract final class EventBusCapabilities {
  static const bool isWeb;               // true on JS/Wasm
  static const bool isolateSupported;    // false on the web
  static const bool transportSupported;  // true: the transport seam is platform-neutral
}
```

`EventBusIsolate`, `WorkerPool`, `Layers.createLayers` and `Layers.supervise` throw
`UnsupportedError` on the web at construction. See [14](14-web.md).

## Errors

```dart
class EventBusException implements Exception {
  final dynamic message;
  EventBusException([this.message]);
  String toString();      // 'EventBusException: <message>'
}

class NoHandlerException extends EventBusException {
  NoHandlerException(String address);   // 'no request handler for "<address>"'
  String get address;                   // same string as `topic`
  final String topic;                   // compatibility alias
}

class BusyException extends EventBusException;          // handlers exist, no capacity
class RequestTimeoutException extends EventBusException; // address + timeout
class RequestCanceledException extends EventBusException; // address
```

`NoHandlerException`, `BusyException`, `RequestTimeoutException` and `RequestCanceledException`
all expose `address`; `topic` remains as a compatibility alias with the same string.

`EventBusException` is used in `EventAddress`/`EventPattern` (an address that cannot be parsed or built),
`Scope`/`Command` (access before initialization), `EventBusIsolate` (exchange problems), and for
a pattern passed where `fire`/`request` need an exact key does not compile. `NoHandlerException` is thrown by `request` when no
handler accepts the value; `BusyException` when handlers exist but none has capacity;
`RequestTimeoutException`/`RequestCanceledException` cover the two cancellation paths. All extend
`EventBusException`. `StateError` is thrown when a closed (`disposed`) bus is used or an isolate API
is unavailable — that is a usage error, not a domain error.

## What is not exported

* Internal core types: `_EventBusForIsolate`, `_IsolateLink`, `_IsolateRequest`,
  `_IsolateResponse`, `_IsolateInterest`, `_IsolateCancel`, `_IsolateFailure`, `_LayerInitDto`,
  `_MetricEntry`, `_RequestEntry`, `_RequestOutcome` and the other protocol/service messages.
  The patterns package has its own internal `_FSM`/`_FSMNode`; they are not exported there either.
* The 3.x handler API is gone: `EventBusHandlers`, `setHandler`, `removeHandler`,
  `addAllHandlerFromOtherBus`, `removeAllHandlerPresentInOtherBus` do not exist. Use
  `subscribeEvents(handler:)`.
* Pattern types are a separate package: `FSM`, `Scope`, `Command` live in
  `packages/event_bus_arch_patterns`, not in the core library.
* Transport packages are separate: `packages/event_bus_arch_transport`, `packages/event_bus_arch_nats`,
  `packages/event_bus_arch_mqtt`.

## What is missing from the API

* no wildcard keys in `fire`/`request` — only listeners, nodes and handlers may use patterns;
* no regular expressions or partial-token wildcards: `*` and `>` are whole tokens;
* no event replay for new subscribers — use `currentData` and the model bus for that;
* no handler priorities: subscriptions on the same tier compete round-robin; the exact tier never
  falls back to a pattern tier when busy;
* no blocking producer: `fire` is synchronous and cannot wait; use subscription buffers or
  `WorkerPool.maxInFlightPerWorker` for flow control;
* `allEventStream` is a broadcast stream with no buffer; attach a listener before publishing if you
  need every event;
* `listen`/`subscribe` are the raw node-stream view; they do not use `EventSubscription` (no
  bounded buffer, overflow policy, counters or error routing). Use `subscribeEvents` when the
  consumer needs those controls;
* isolate APIs are VM-only; the web has the local bus, observability and the transport seam.
