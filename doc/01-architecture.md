# 01. Architecture

[← Table of contents](README.md) · [Next: EventBus in practice →](02-event-bus.md)

`event_bus_arch` is an event-driven framework for Dart/Flutter. All interaction between
components goes through events that have an **address** (`EventAddress`), a **typed key**
(`EventKey<T>` or `EventPatternKey<T>`), **data**, and optional **call arguments** and
**correlation id**. A `fire` publishes an event; a `request` asks exactly one handler for a
result. Isolates, layers, a worker pool, a finite state machine and scope/command are built on top
of the bus.

The [overview](00-overview.md) has the API and component maps. This document explains the moving
parts in the order an event travels through them.

## What the package consists of

| Layer | Type | Role |
|---|---|---|
| Addressing | `EventAddress` | The identity: a dot-separated string chosen by the application, `orders.placed.v1` |
| Typed keys | `EventKey<T>`, `EventPatternKey<T>`, `EventSelector<T>` | Address + static type; a pattern adds wildcards |
| Wildcards | `EventPattern` | `*` (one token) and `>` (one or more trailing tokens) |
| Event envelope | `EventDTO<T>` | Data + key + `arguments` + optional `correlationId` |
| Node cell | `EventNode<T>` | Stores the last value, the value stream and the subscriptions of one `(address, Type)` |
| Subscription | `EventSubscription<T>` | Listener buffer and/or handler request queue, pause/resume/cancel |
| Registry | `EventBus` / `EventBusImpl` | Exact and pattern node buckets, dispatch, errors, metrics |
| Failures | `EventBusError`, `EventBusErrorMonitor` | Errors as data, rate limiting, aggregation |
| Observability | `EventBusMetrics`, snapshots | Opt-in per-address/subscription counters and histograms |
| Isolate boundaries | `EventBusIsolate`, `Layer`, `Layers`, `LayersSupervisor` | Directional bridges and supervised chains |
| Workers | `WorkerPool` | N isolates with a dispatch strategy and restart supervision |
| Transports | `TransportEventBus` | The same bus over a broker connection, keyed by address |
| On top of the bus | `EventBusLogger` | Event tracing |
| Patterns (separate package) | `FSM`, `Scope`, `Command` | State machine, state with history (`event_bus_arch_patterns`) |

## The two ways to publish

### `fire` — publish to listeners

```mermaid
sequenceDiagram
    autonumber
    participant C as Caller
    participant B as EventBus
    participant N as EventNode
    participant S as Listener subscription

    C->>B: fire(key, data, arguments, correlationId)
    B->>B: build EventDTO.withKey
    B->>N: exact bucket: every type node for key.address
    B->>N: every matching pattern bucket, every type node
    N->>S: offer(dto.data) when data is T
    alt listener accepted or model node stored it
        B-->>C: true
    else nobody listened and no model node
        B-->>C: false
    end
    Note over N,S: a handler subscription is not a listener.<br/>fire never invokes it (D14)
```

`fire` is one-way. It reports whether anyone accepted the event; a handler-only node does not
make it `true`. The value is stored in `currentData` on a model bus even when nobody is listening.
The call requires an exact `EventKey<T>`; a pattern key is rejected by the type system.

### `request` — ask one handler

```mermaid
sequenceDiagram
    autonumber
    participant C as Caller
    participant B as EventBus
    participant N as EventNode
    participant L as Listener subscriptions
    participant H as Handler subscription
    participant Q as Handler FIFO queue

    C->>B: request(key, data, timeout, cancelToken, correlationId)
    B->>B: resolve a handler tier (exact, then most specific pattern)

    alt no accepting handler
        B-->>C: NoHandlerException
    else handlers exist but none has capacity
        B-->>C: BusyException
    else accepted
        B->>N: previous currentData of the handler's node
        B->>L: offer(dto.data) — listeners see the request too
        B->>H: create request entry (timeout / cancellation armed)
        alt a concurrency slot is free
            H->>H: handler(dto, previous)
        else all slots are busy
            H->>Q: enqueue and wait
            Note over Q: timeout or CancelToken removes it before dispatch
        end
        H-->>B: result or thrown error
        B-->>C: result or the same error
    end
```

A dispatched handler keeps running after a timeout or cancellation; its result is discarded. A
request that timed out or was cancelled while queued is removed and never runs.

## 1. EventAddress and keys — the event identity

An address is a dot-separated string chosen by the application:

```text
orders.placed.v1
   │      │    └── version in the address
   │      └─────── event name
   └────────────── domain
```

`EventAddress` validates the exact form: non-empty, no empty tokens, no wildcards. The separator
is a rule of the model (`EventAddress.separator == '.'`), not a per-bus or per-call setting. A
transport may map tokens to its own grammar (NATS uses `.`, MQTT uses `/`), but the address string
does not change.

`EventKey<T>` binds an address to a static type:

```dart
final placed = EventKey<OrderPlaced>('orders.placed.v1');
final anyOrder = EventPatternKey<OrderPlaced>('orders.*');

placed.address.value;   // 'orders.placed.v1'
placed.type;            // Type captured from T
anyOrder.matches(placed.address); // true
```

The type is **not** part of the address and never reaches the wire. It is the delivery filter:
a node is identified by `(address, Type)`, so `EventKey<OrderPlaced>` and
`EventKey<OrderCancelled>` on the same address are separate nodes with separate `currentData`.
`EventSelector<T>` is the sealed base of exact and pattern keys; `accepts(data)` is
`data is T`.

Type identity is captured with a compile-time token:

```dart
Type _typeOf<T>() => T;
```

Two calls with the same `T` get the same `Type` object even under `dart compile js -O2` and other
minifiers. `Type.toString()` and `runtimeType.name` must never be used for routing or codec
lookup: they are minified, and the local `dart compile js -O2` check showed a user class becoming
`minified:bd`.

### Wildcards

`EventPattern` defines the fixed local wildcards:

* `*` matches exactly **one** token;
* `>` matches **one or more** trailing tokens and must be the last token;
* a wildcard must be a whole token: `sen*or` is rejected.

They are core features, not a transport detail. Transports map them to broker symbols (NATS uses
the same ones, MQTT uses `+`/`#`).

```dart
EventPattern('sensor.*');   // matches sensor.temp, not sensor.a.b
EventPattern('sensor.>');   // matches sensor.temp and sensor.a.b, not sensor
```

A pattern can be registered for subscriptions and handlers. `fire` and `request` calls themselves
must address a concrete key: an `EventPatternKey` there is a compile-time type error. Resolution
is: the exact node first, then the most specific matching pattern (more literal tokens win; ties
keep registration order).

### Equality

`EventAddress` compares its string. `EventKey` compares `(address, type)`; `EventPatternKey`
compares `(pattern, type)`. Consequences:

* `bus.fire(EventKey<int>('p'), 1)` and `bus.subscribe(EventKey<int>('p'))` address the
  **same** node; `arguments` and `correlationId` are not part of the identity;
* a new `EventKey<int>('p')` value finds the same node as any other instance with the same address
  and type;
* `EventKey<int>('p')` and `EventKey<num>('p')` are different nodes, but a `num` node accepts an
  `int` payload at delivery time.

## 2. EventDTO — the event envelope

```dart
abstract class EventDTO<T> {
  EventKey<T> get key;
  String get address;                     // key.address.value
  T get data;
  Map<String, String>? get arguments;    // parameters of this call; not part of the address
  String? get correlationId;             // ties an event and its consequences together
  EventDTO<T> copyWith({T? data, EventKey<T>? key,
      Map<String, String>? arguments, String? correlationId});
  Map<String, dynamic> toJson();         // {'address': ..., 'data': ..., maybe 'correlationId'}
}
```

* `arguments` are the parameters of a specific call. Two calls that differ only in `arguments`
  reach the same handler.
* There is **no completer** in the envelope. A handler returns its result; `request` awaits it.
  `fire` has no result to deliver.
* `correlationId` is optional metadata. It reaches handlers (`dto.correlationId`), crosses isolate
  and transport boundaries and appears in request error envelopes. It is editable with `copyWith`.
* `EventDTOImpl` implements `==`/`hashCode` over `(key, data)` and supports `toJson()`/`fromJson()`.
  `toJson` returns data as is; the caller does the encoding. `arguments` are not in the JSON form.
  `fromJson` accepts the current `address` field and the old `topic` spelling for compatibility.

## 3. EventNode and EventSubscription

An `EventNode<T>` owns the state of one `(address, Type)`. A subscription owns its own delivery
state; the node only fans events out to it.

```dart
abstract class EventNode<T> {
  T? currentData;                       // the last delivered value
  bool get isDisposed;
  StreamController<T> get streamControllerValue;

  bool deliver(EventDTO dto);           // type-filter, store the value, fan out
  EventNode<T> copy();
  Future<void> dispose();
}

abstract class SubscriptionHost<T> {    // implemented by every built-in node
  Iterable<EventSubscription<T>> get subscriptions;
  void addSubscription(EventSubscription<T> subscription);
  void removeSubscription(EventSubscription<T> subscription);
  bool get hasSubscriptions;
  bool get hasListenerSubscriptions;
}
```

`deliver` does three things in order:

1. checks `dto.data is T`; another type is ignored;
2. sets `currentData = dto.data` synchronously;
3. adds the value to the broadcast value stream (`listen`/`subscribe`) and calls `offer` on every
   `EventSubscription`.

`EventSubscription<T>` is created by `subscribe`:

| Capability | Fields / methods |
|---|---|
| Listener | `onEvent`, bounded buffer, `bufferCapacity`, `bufferOverflow` (`latest`, `dropOldest`, `dropNewest`, `reject`), `deliveryMode` (`async`/`sync`), `pause`/`resume`/`resize` |
| Handler | `handler`, `handlerConcurrency`, per-subscription FIFO `requestQueueCapacity`, `inFlight`, `bufferedRequests`, `hasRequestCapacity` |
| Lifecycle | `cancel`, `isCanceled`, `isPaused`, `isBusy`, `stream` view, counters (`delivered`, `dropped`, `buffered`) |
| Both | `onEvent` and `handler` may be set on the same subscription: it receives `fire` through `onEvent` and answers `request` through `handler` |

A handler is **not** registered on the node or in a separate registry. It is a capability of a
subscription, so its queue, concurrency, pause state and lifecycle are owned by that subscription.
See [11](11-backpressure.md) for the full buffer/queue model.

## 4. EventBus — the registry and dispatcher

```dart
abstract class EventBus {
  bool get isModelBus;
  bool get isObservable;
  EventBusMetrics get metrics;
  bool get isDisposed;
  Future<void> dispose();

  Stream<(EventDTO, bool)> get allEventStream;
  Stream<EventBusError> get errors;
  List<EventBusError> get recentErrors;
  int get suppressedErrors;

  bool haveListener<T>(EventSelector<T> selector);
  bool haveHandler<T>(EventSelector<T> selector);
  bool haveAvailableHandler<T>(EventSelector<T> selector);

  bool fire<T>(EventKey<T> key, T data, {Map<String, String>? arguments,
      String? correlationId});

  Future<dynamic> request<T>(EventKey<T> key, T data,
      {Map<String, String>? arguments, Duration? timeout,
      CancelToken? cancelToken, String? correlationId});

  Stream<T> listen<T>(EventSelector<T> selector);
  StreamSubscription<T> subscribe<T>(EventSelector<T> selector, {...});

  EventSubscription<T> subscribe<T>(EventSelector<T> selector,
      {EventCallback<T>? onEvent, Handler<T>? handler, T? initialData,
      int handlerConcurrency, int? requestQueueCapacity,
      int? bufferCapacity, BufferOverflow bufferOverflow,
      DeliveryMode deliveryMode, ...});

  T? currentData<T>(EventSelector<T> selector);
  bool remove<T>(EventKey<T> key);
  bool remove<T>(EventPatternKey<T> key);
  bool removeAddress(EventAddress address);

  factory EventBus({bool isModelBus = false, ObservabilityConfig? observability});
}
```

`EventBus` is an interface with a factory: `EventBus(...)` creates `EventBusImpl`.
`EventBusImpl` mixes in `EventBusMixin` (delivery, errors, metrics, node lifecycle) and the handler
dispatch mixin (`_EventBusHandlersMixin`). Inside there are two node maps:

* `Map<EventAddress, Map<Type, EventNode>> _eventsMap` — exact address buckets, one node per type;
* `Map<EventPattern, Map<Type, EventNode>> _patternMap` — pattern buckets, one node per type.

There is no separate handler map: handler subscriptions live in the nodes.

### Handler resolution

```mermaid
flowchart TD
    A[request on an exact key] --> B{exact bucket has an accepting handler of the key's type?}
    B -- yes --> T[exact tier]
    B -- no --> C{any matching pattern bucket has an accepting handler?}
    C -- yes, most specific --> T
    C -- no --> N[NoHandlerException]
    T --> D{any subscription in the tier has a free request credit?}
    D -- no --> BUSY[BusyException]
    D -- yes --> E[round-robin inside the tier]
    E --> F{fewer in-flight than handlerConcurrency?}
    F -- yes --> G[run the handler now]
    F -- no --> H[FIFO queue of that subscription]
```

An exact tier never falls back to a pattern tier: if the exact node has handlers and all are busy,
the request is busy instead of silently going to a pattern handler. The handler's second argument
is the **previous** `currentData` of the handler's own node. A thrown error becomes the error of the
request future. `haveHandler` counts a paused handler; `haveAvailableHandler` answers whether a
request could be accepted now.

Within a handler tier, a subscription registered on a supertype key (`EventKey<num>`) is a
candidate for a subtype request (`EventKey<int>`) only when its `accepts(data)` is true. The tier
is keyed by the concrete route, so round-robin and busy state do not leak between addresses.

### Two bus configurations

| | `EventBus()` — common | `EventBus(isModelBus: true)` — model |
|---|---|---|
| Creates a node on `fire` to a key that has none | no | yes |
| What `fire` returns for an empty key | `false` | `true` (the node stores the value) |
| `allEventStream` flag for an empty key | `false` | `true` |
| Keeps `currentData` | only while the node has a listener, a handler or a transport pin | always |
| When the node is removed | when it has no subscriptions and no transport pin | never (until `remove`/`dispose`) |

The model bus is a "state store": the value is remembered even if nobody was listening. The common
bus is a "message pipe": with no one to hand the value to, the event goes to `allEventStream` and
that is it.

### `allEventStream`

`Stream<(EventDTO, bool)>` reports every `fire` and `request`. The second element is "was there a
node that accepted the event" (a model node counts). It is used by `FSM` and `EventBusLogger`; it is
not the error stream. Errors have their own stream and are rate-limited (see [12](12-observability.md)).

## 5. Lifecycle

* `listen`/`subscribe`/`subscribe` create a node if it did not exist (exact or pattern).
* A handler subscription also creates/uses a node; the first handler interest is what makes a node
  an answering tier.
* Cancelling the last subscription calls the private `_removeNode`. It removes and disposes the
  node **only if** it has no subscriptions, no `KeepAliveNode` pin, and the bus is not a model bus.
  A map entry is removed only when it still holds the same node instance, so a late cancellation of
  an old node cannot delete a newer one.
* `remove(key)` removes one type node; `remove(patternKey)` removes one pattern type node;
  `removeAddress(address)` removes every type node at an exact address. They forget `currentData`
  **even on a model bus and even with a `KeepAliveNode` pin**. All subscriptions of the removed
  nodes are cancelled (D13); a transport node cancels its broker subscription. A model bus creates
  the node again on the next `fire`, `request` or `listen`.
* Subscriptions have their own lifecycle: `EventSubscription.cancel` removes it from the node,
  drops its buffer, fails queued requests and removes the node when it was the last one.

## 6. Errors, metrics and observability

* `EventBus.errors` is a stream of `EventBusError` **data events**, never stream errors. Every
  event has a kind, a source, an optional address/correlation id and a bounded recent buffer. The
  bus rate-limits errors per `(kind, address)` and counts suppressed ones.
* `EventBusError.address` is the event address; `topic` remains as a compatibility alias with the
  same string.
* `EventBusErrorMonitor` aggregates several buses, has an optional filter and a monitor-wide
  per-second limit and exposes counters by kind and address.
* Observability is off by default. `EventBus(observability: ObservabilityConfig(enabled: true))`
  collects per-address and per-subscription counters, latency histograms and queue depth;
  `metrics.snapshot()` and `metrics.changes` read them. Invalid/unknown metric keys above the
  cardinality limit go to `__other__`.
* Correlation ids travel through handlers, isolates and transport headers; they appear in request
  error envelopes. See [12](12-observability.md).

## 7. The rest of the package

```mermaid
flowchart TD
    BUS["EventBus<br/>address/type nodes + subscriptions"] --> FSM["FSM<br/>transitions"]
    BUS --> SCOPE["Scope / Command<br/>state + history"]
    BUS --> LOG["EventBusLogger<br/>allEventStream"]
    BUS --> OBS["metrics / errors<br/>EventBusErrorMonitor"]
    BUS --> ISO["EventBusIsolate<br/>directional bridge"]
    ISO --> LAYERS["Layers / LayersSupervisor"]
    ISO --> POOL["WorkerPool"]
    BUS --> TRANSPORT["TransportEventBus<br/>NATS / MQTT"]
```

| Type | What it adds | Document |
|---|---|---|
| `EventBusIsolate` | A worker isolate behind a bus-like port; interest sync, request ids, cancellation | [03](03-isolate-and-layers.md) |
| `Layers` / `LayersSupervisor` | A chain of worker layers; whole-chain restart | [03](03-isolate-and-layers.md), [13](13-pool-and-supervision.md) |
| `WorkerPool` | N isolates, five dispatch strategies, request credits, supervision | [13](13-pool-and-supervision.md) |
| `TransportEventBus` | The same bus over a broker connection | [08](08-transports.md) |
| `FSM` | A state machine driven by events (`event_bus_arch_patterns`) | [04](04-fsm.md) |
| `Scope`/`Command` | A value with call history and undo (`event_bus_arch_patterns`) | [05](05-scope-and-command.md) |

## What's next

| Document | Content |
|---|---|
| [02-event-bus.md](02-event-bus.md) | Sending/receiving events, handlers, addressing, recipes |
| [11-backpressure.md](11-backpressure.md) | Buffers, overflow policies, handler queues, pause, credits |
| [12-observability.md](12-observability.md) | Errors, metrics, correlation ids |
| [03-isolate-and-layers.md](03-isolate-and-layers.md) | Isolates, layers, supervision |
| [06-api-reference.md](06-api-reference.md) | Full API reference |
