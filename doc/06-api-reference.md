# 06. API reference

[← Observability](05-observability.md) · [Documentation index](README.md) · [Next: Platforms →](07-platforms.md)

Public API of `package:event_bus_arch/event_bus_arch.dart`. Pattern types (`FSM`, `Scope`,
`Command`) and broker adapters are separate packages; see the package READMEs linked from
[doc/README.md](README.md).

## Typedefs

```dart
typedef EventCallback<T> = FutureOr<void> Function(T event);
typedef Handler<T> = Future<dynamic> Function(EventDTO<T> dto, T? lastData);
typedef Node<T> = EventNode<T>;

typedef WorkerInit = FutureOr<void> Function(EventBus bus, Object? initialData);
typedef WorkerKeySelector = Object? Function(EventDTO dto);
typedef MetricKeyBuilder = String Function(String address);
typedef EventBusErrorFilter = bool Function(EventBusError error);
typedef LayerInit = FutureOr<void> Function(Layer layer, Object? initialData);
typedef LoggerHandler = void Function(EventDTO dto, bool hasDelivered);
```

## Addresses and patterns

```dart
final class EventAddress {
  EventAddress(String value);
  factory EventAddress.parse(String value);

  static const String separator = '.';
  static const String singleWildcard = '*';
  static const String tailWildcard = '>';

  final String value;
  List<String> get tokens;
}

final class EventPattern {
  EventPattern(String value);
  factory EventPattern.parse(String value);

  static const String singleWildcard = '*';
  static const String tailWildcard = '>';

  final String value;
  List<String> get tokens;
  bool get hasWildcard;
  int get specificity;
  bool matches(EventAddress address);
}
```

`EventAddress` rejects empty strings, empty tokens and wildcards. `EventPattern` rejects a `>`
that is not last and a wildcard mixed with literal characters.

## Selectors and keys

```dart
sealed class EventSelector<T> {
  Type get type;
  bool accepts(Object? data); // data is T
}

final class EventKey<T> extends EventSelector<T> {
  EventKey(String address);
  EventKey.fromAddress(EventAddress address);

  final EventAddress address;
  @override
  final Type type;

  @override
  bool operator ==(Object other); // (address, type)
  @override
  int get hashCode;
  @override
  String toString(); // address.value
}

final class EventPatternKey<T> extends EventSelector<T> {
  EventPatternKey(String pattern);
  EventPatternKey.fromPattern(EventPattern pattern);

  final EventPattern pattern;
  @override
  final Type type;

  bool matches(EventAddress address);
  @override
  bool operator ==(Object other); // (pattern, type)
  @override
  int get hashCode;
  @override
  String toString(); // pattern.value
}
```

## EventDTO

```dart
abstract class EventDTO<T> {
  EventKey<T> get key;
  String get address; // key.address.value
  T get data;
  Map<String, String>? get arguments;
  String? get correlationId;

  factory EventDTO.withKey(EventKey<T> key, T data,
      {Map<String, String>? arguments, String? correlationId});

  EventDTO<T> copyWith({T? data, EventKey<T>? key,
      Map<String, String>? arguments, String? correlationId});

  Map<String, dynamic> toJson(); // {'address': ..., 'data': ..., maybe 'correlationId'}
}

class EventDTOImpl<T> implements EventDTO<T> {
  static EventDTO<T> fromJson<T>(Map<String, dynamic> json,
      {EventKey<T>? key,
       T Function(String address, dynamic data)? dataConverter});
}
```

`fromJson` accepts the old `topic` field as an alias for reading legacy payloads.

## Nodes

```dart
abstract class EventNode<T> {
  T? currentData;
  bool get isDisposed;
  StreamController<T> get streamControllerValue;

  bool accepts(Object? data);       // data is T for the built-in nodes
  bool deliver(EventDTO dto);
  EventNode<T> copy();
  Future<void> dispose();

  factory EventNode.create({T? currentData});
}

abstract class KeepAliveNode {
  bool get keepAlive; // core extension point; no built-in node pins itself
}

abstract class IncomingEventNode {
  void deliverIncoming(EventDTO dto); // deliver without republishing
}

abstract class SubscriptionHost<T> {
  Iterable<EventSubscription<T>> get subscriptions;
  void addSubscription(EventSubscription<T> subscription);
  void removeSubscription(EventSubscription<T> subscription);
  bool get hasSubscriptions;
  bool get hasListenerSubscriptions;
}
```

## EventSubscription

Created by `subscribe`; the constructor is private.

```dart
enum BufferOverflow { latest, dropOldest, dropNewest, reject }
enum DeliveryMode { async, sync }

class EventSubscription<T> {
  EventSelector<T> get selector;
  String get address;

  Future<void> cancel();
  void pause();
  void resume();
  void resize(int? capacity, {BufferOverflow? overflow});

  bool get isPaused;
  bool get isBusy;
  bool get isListenerBusy;
  bool get isHandlerBusy;
  bool get isCanceled;
  bool get hasHandler;
  bool get hasListener;

  int? get bufferCapacity;
  BufferOverflow get bufferOverflow;
  int get buffered;
  int get dropped;
  int get delivered;

  int get inFlight;
  int get bufferedRequests;
  int get maxBufferedRequests;
  LatencySnapshot? get queueWaitLatency;
  int get handlerConcurrency;
  int get requestQueueCapacity;
  bool get hasRequestCapacity;

  Stream<T> get stream;
}
```

## EventBus

```dart
abstract class EventBus {
  factory EventBus({bool isModelBus = false, ObservabilityConfig? observability});

  bool get isModelBus;
  bool get isDisposed;
  bool get isObservable;
  EventBusMetrics get metrics;

  Stream<(EventDTO, bool)> get allEventStream;
  Stream<EventBusError> get errors;
  List<EventBusError> get recentErrors;
  int get suppressedErrors;

  bool fire<T>(EventKey<T> key, T data,
      {Map<String, String>? arguments, String? correlationId});

  Future<dynamic> request<T>(EventKey<T> key, T data,
      {Map<String, String>? arguments, Duration? timeout,
       CancelToken? cancelToken, String? correlationId});

  Stream<T> listen<T>(EventSelector<T> selector);

  EventSubscription<T> subscribe<T>(EventSelector<T> selector, {
    EventCallback<T>? onEvent,
    Handler<T>? handler,
    T? initialData,
    int handlerConcurrency = 1,
    int? requestQueueCapacity,
    int? bufferCapacity = 1024, // null = explicitly unbounded
    BufferOverflow bufferOverflow = BufferOverflow.dropOldest,
    DeliveryMode deliveryMode = DeliveryMode.async,
    void Function(Object error, StackTrace? stackTrace)? onError,
    void Function()? onDone,
    bool cancelOnError = false,
  });

  T? currentData<T>(EventSelector<T> selector);

  bool remove<T>(EventSelector<T> selector);
  bool removeAddress(EventAddress address);

  FireProbe probeFire<T>(EventKey<T> key, T data);
  RequestProbe probeRequest<T>(EventKey<T> key, T data);

  @Deprecated('Use probeFire/probeRequest; have* checks only exact types')
  bool haveListener<T>(EventSelector<T> selector);
  @Deprecated('Use probeFire/probeRequest; have* checks only exact types')
  bool haveHandler<T>(EventSelector<T> selector);
  @Deprecated('Use probeFire/probeRequest; have* checks only exact types')
  bool haveAvailableHandler<T>(EventSelector<T> selector);

  Future<void> dispose();
}
```

`EventBusImpl` is the built-in implementation returned by the factory; its internal mixins and
transport hooks are not application API. After `dispose`, public methods throw `StateError`.

`probeFire` and `probeRequest` are side-effect-free. They count nodes that accept the supplied
data, including supertype pattern nodes, and expose local/remote/transport interest. `have*` is
deprecated because a query without data can only match the exact registered type.

```dart
class FireProbe {
  int get localListeners;
  bool get hasRawListener;
  bool get modelStores;
  bool get transportPublishes;
  int get remoteListenerInterest;
  bool get accepted;
}

class RequestProbe {
  int get localHandlers;
  int get localAvailableHandlers;
  int get localListeners;
  bool get hasRawListener;
  bool get remoteHandlerInterest;
  bool get hasHandler;
  bool get isBusy;
}
```

## Errors and request cancellation

```dart
class CancelToken {
  bool get isCancelled;
  Future<void> get whenCancelled;
  Object? get reason;
  int get listenerCount;
  void addListener(void Function() listener);
  void removeListener(void Function() listener);
  void cancel([Object? reason]);
}

class EventBusException implements Exception {
  final dynamic message;
}

class NoHandlerException extends EventBusException {
  String get address;
  String get topic; // same string
}

class BusyException extends EventBusException {
  String get address;
  String get topic;
}

class RequestTimeoutException extends EventBusException {
  String get address;
  String get topic;
  Duration get timeout;
}

class RequestCanceledException extends EventBusException {
  String get address;
  String get topic;
}
```

Notification-only errors (`bus.errors`):

```dart
enum EventBusErrorKind { listener, handler, serialization, deserialization,
  transport, isolateInit, isolateDeath, requestTimeout, requestCanceled,
  bufferOverflow, busy, supervision, dispose, other }

enum EventBusErrorSource { core, isolate, transport, supervision }

class EventBusError {
  final EventBusErrorKind kind;
  final EventBusErrorSource source;
  final String? address;
  String? get topic; // alias
  final EventDTO? event;
  final String? correlationId;
  final Object error;
  final StackTrace? stackTrace;
  final DateTime timestamp;
  final Map<String, String> context;
}

class EventBusErrorMonitor {
  EventBusErrorMonitor({EventBusErrorFilter? filter,
      int recentLimit = 100, int? maxErrorsPerSecond = 200});

  bool add(EventBus bus);
  bool remove(EventBus bus);
  Stream<EventBusError> get errors;
  List<EventBusError> get recentErrors;
  Map<EventBusErrorKind, int> get counts;
  int get suppressed;
  EventBusErrorSnapshot snapshot();
  void resetCounters();
  Future<void> dispose();
}
```

`EventBusErrorSnapshot` exposes `total`, `suppressed`, `byKind`, `byAddress` (`byTopic` alias)
and `recent`.

## Observability

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
}

abstract interface class EventBusMetricsExporter {
  void export(EventBusMetricsSnapshot snapshot);
}
```

`EventBusMetricsSnapshot` has `timestamp`, `fired`, `delivered`, `dropped`,
`droppedMetricSeries`, `topics` (`AddressMetricsSnapshot`) and `subscriptions`
(`SubscriptionMetricsSnapshot`). `AddressMetricsSnapshot` and `SubscriptionMetricsSnapshot` carry
the counters listed in [05-observability.md](05-observability.md); `LatencySnapshot` is a
fixed-bucket histogram.

## EventBusIsolate

```dart
class EventBusIsolate extends EventBusImpl {
  EventBusIsolate({
    required FutureOr<void> Function(EventBus bus, Object? initialData) onInit,
    Object? initialData,
    bool isModelBus = false,
    ObservabilityConfig observability = ObservabilityConfig.disabled,
    Duration? initTimeout = const Duration(seconds: 30),
  });

  Future<bool> get waitInit;
  bool get isInit;
  Future<bool> restart();
  Future<bool> ping({Duration timeout});
  Future<void> dispose();
}
```

Inherits `fire`, `request`, `listen`, `subscribe`, `currentData`, `remove`, `removeAddress`,
`probeFire`, `probeRequest`, `have*`, `allEventStream`, `errors` and `metrics`. `fire` is outbound
only. `waitInit` fails when the worker dies before ready or when `initTimeout` elapses.

## Layers

```dart
typedef LayerInit = FutureOr<void> Function(Layer layer, Object? initialData);

class LayerSpec {
  const LayerSpec({required LayerInit init, Object? initialData,
      bool isModelBus = false});
  final LayerInit init;
  final Object? initialData;
  final bool isModelBus;
}

class Layer {
  EventBus? top;
  EventBus current;
  EventBus? bottom;

  Layer({EventBus? top, required EventBus current, EventBus? bottom});
  Future<void> close();
}

class Layers {
  static Future<Layer> createLayers(List<LayerSpec> layers, {
    bool currentIsModelBus = true,
    bool bridgeIsModelBus = false,
    Duration? timeout,
  });

  static LayersSupervisor supervise(List<LayerSpec> layers, {
    bool currentIsModelBus = true,
    bool bridgeIsModelBus = false,
    Duration? timeout,
    SupervisionPolicy policy = const SupervisionPolicy(),
  });
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

## WorkerPool

```dart
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
```

`WorkerPoolMetrics` has `state`, `workers`, `readyWorkers`, `fired`, `accepted`, `dropped`,
`requests`, `failedRequests`, `restarts` and `perWorker` (`WorkerMetrics`).

## Logger and capabilities

```dart
mixin class EventBusLogger {
  bool add(EventBus bus, {LoggerHandler handler = defaultLoggerHandler});
  bool remove(EventBus bus);
  static void defaultLoggerHandler(EventDTO dto, bool hasDelivered);
}

abstract final class EventBusCapabilities {
  static const bool isWeb;
  static const bool isolateSupported;
  static const bool transportSupported;
}
```

## What's next

[07-platforms.md](07-platforms.md) covers VM/Web differences and the capability flags.
