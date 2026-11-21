# 02. EventBus in practice

[← 01. Architecture](01-architecture.md) · [Contents](README.md) · [Next: Isolates and layers →](03-isolate-and-layers.md)

This is the day-to-day guide: how to create a bus, publish, subscribe, answer requests and control
the lifecycle. The internals are in [01](01-architecture.md); buffers and queues are in
[11](11-backpressure.md).

## Creating a bus

```dart
final bus = EventBus();                          // common: message pipe
final model = EventBus(isModelBus: true);        // model: remembers currentData
final observed = EventBus(observability: const ObservabilityConfig(enabled: true));
```

`EventBus(...)` returns an `EventBusImpl`. `defaultTopicPathSeparator` is `.` unless changed on the
instance. Always call `await bus.dispose()` when the bus is no longer needed; it cancels all
subscriptions and closes every node, stream and resource.

## Publishing: `fire`

```dart
final accepted = bus.fire<Order>(order, paths: ['orders', 'new'],
    arguments: {'source': 'checkout'}, correlationId: 'checkout-42');
```

* `fire` offers the event to the exact node (if it exists) and to every matching pattern node.
  Handler subscriptions are not invoked.
* It returns `true` when a listener accepted the event, a model bus stored it, a transport
  accepted it for publishing, or the other side of an isolate bridge has a known listener/model
  interest. A handler-only node does **not** count (D14).
* `arguments` are call parameters, not part of the address. `correlationId` ties an event and its
  consequences together; it is optional.
* On a common bus a topic with no node is not created: `fire` returns `false` and only
  `allEventStream` sees the event. A model bus creates the node and stores the value.
* Wildcards are not allowed in `fire` itself: `paths: ['orders', '*']` throws `EventBusException`.

### The model bus

```dart
final state = EventBus(isModelBus: true);
state.fire<Status>(Status.ready, paths: ['service']);
print(state.currentData<Status>(paths: ['service'])); // Status.ready
```

A model bus keeps the node and the last value even after its last listener cancels. Use it for
state that a new subscriber should see immediately (via `currentData`), and the common bus for
messages that only matter to current listeners.

## Publishing: `request`

```dart
final receipt = await bus.request<Receipt>(order, paths: ['orders', 'place'],
    timeout: const Duration(seconds: 2),
    correlationId: 'checkout-42');
```

* A request addresses a concrete topic. The bus resolves the exact node first, then the most
  specific matching pattern. A request with wildcard paths throws `EventBusException`.
* When no accepting handler exists, the future fails with `NoHandlerException`. When handlers exist
  but none has a free slot, it fails with `BusyException` (or the request waits in a subscription
  queue when it has one).
* Listeners also receive the request event (they see `dto.data`), then the handler runs. This lets
  a UI observe commands and their results.
* The handler's second argument (`lastData`) is the previous `currentData` of the handler's node.
* `timeout` and `CancelToken` cancel the caller's wait. A queued request is removed before dispatch;
  a dispatched handler keeps running and its result is discarded.
* `arguments` travel with the request; `correlationId` reaches the handler in `dto.correlationId`.

### Exceptions

| Exception | When |
|---|---|
| `NoHandlerException` | No handler accepts the topic/data |
| `BusyException` | Handlers exist, but no capacity (all paused/busy/queue full) |
| `RequestTimeoutException` | The caller's timeout expired |
| `RequestCanceledException` | The `CancelToken` was cancelled |
| the handler's own error | Returned unchanged from the request future |

## Receiving: `listen` and `subscribe`

These are the stream-style APIs and remain useful for small listeners:

```dart
final stream = bus.listen<Price>(paths: ['market', 'btc']);
final sub = bus.subscribe<Price>(
  paths: ['market', 'btc'],
  onData: (price) => print(price),
);
await sub.cancel();
```

A stream is broadcast and unbuffered by the bus: a listener created after `fire` sees nothing
(the value may still be in `currentData` on a model bus).

## Receiving: `subscribeEvents`

For anything beyond a one-line listener, use the control API. It returns an `EventSubscription<T>`
that owns its buffer, pause state, handler queue and counters:

```dart
final sub = bus.subscribeEvents<Price>(
  paths: ['market', 'btc'],
  bufferCapacity: 8,
  bufferOverflow: BufferOverflow.latest,
  onEvent: (price) async => await render(price),
);

sub.pause();
sub.resume();
sub.resize(16);                       // change capacity and/or policy
print('${sub.buffered} buffered, ${sub.dropped} dropped');
final view = sub.stream;              // a broadcast view of delivered events
await sub.cancel();
```

Options:

| Option | Default | Meaning |
|---|---|---|
| `bufferCapacity` | `null` (unbounded) | How many events wait while the callback runs or the subscription is paused |
| `bufferOverflow` | `dropOldest` | `latest`, `dropOldest`, `dropNewest`, `reject` |
| `deliveryMode` | `async` | `async` (microtask) or `sync` (inline in `fire`) |
| `initialData` | — | Seed `currentData` of the node |
| `onError`, `cancelOnError` | — | Listener errors and optional auto-cancel |

`BufferOverflow.reject` makes `fire` report that this listener did not accept the event; the other
policies drop silently (with counters/errors).

## Handlers as subscriptions

A handler is a capability of an `EventSubscription`:

```dart
final orders = bus.subscribeEvents<Order>(
  paths: ['orders'],
  handlerConcurrency: 2,
  requestQueueCapacity: 32,
  handler: (dto, lastData) async => await place(dto),
);
```

* `handlerConcurrency` (default 1) bounds concurrent invocations; the rest wait in this
  subscription's FIFO.
* `requestQueueCapacity` defaults to `bus.requestQueueCapacity` (64). `0` means "reject immediately
  when no slot is free", producing `BusyException`.
* `inFlight`, `bufferedRequests`, `isHandlerBusy`, `hasRequestCapacity` expose the state;
  `pause()` stops new requests from being selected.
* Two subscriptions on one topic compete; dispatch is round-robin inside the resolved tier.
* The exact tier never falls back to a pattern tier: if the exact handlers are saturated, the
  request is busy even when a pattern handler is free.
* A handler error is returned to the caller **and** reported through `errors` (kind `handler`).

### A subscription can be both

```dart
final audit = bus.subscribeEvents<Order>(
  paths: ['orders'],
  onEvent: (order) => log(order),
  handler: (dto, last) async => await handle(dto),
);
```

`fire` reaches `onEvent`; `request` reaches the handler and also offers the event to listeners.

### Pattern handlers

```dart
bus.subscribeEvents<Sensor>(
  paths: ['sensor', '*'],
  handler: (dto, last) async => dto.data.value,
);
```

A concrete `request<Sensor>(..., paths: ['sensor', 'temp'])` finds the pattern tier when the exact
tier has no accepting handler. More literal tokens win; ties keep registration order.

## `currentData`

```dart
final last = bus.currentData<Status>(paths: ['service']);
```

It is the last value delivered to the node, synchronously updated by `fire`/`request` delivery. On
a common bus the value lives only while the node has a subscription or a transport pin; on a model
bus it survives until `removeTopic`/`dispose`.

## Availability checks

```dart
bus.haveListener<Status>(paths: ['service']);       // a listener (or matching pattern) exists
bus.haveHandler<Status>(paths: ['service']);        // a handler exists, even if paused
bus.haveAvailableHandler<Status>(paths: ['service']); // one could accept a request now
```

Use `haveAvailableHandler` before `request` when you want to avoid a `BusyException`; use
`haveHandler` for routing decisions that tolerate a busy responder.

## Errors and all events

```dart
final errSub = bus.errors.listen((error) => log(error));
final trace = bus.allEventStream.listen((event) {
  final (dto, delivered) = event;
  log('${dto.topic} $delivered ${dto.correlationId}');
});
```

`errors` carries `EventBusError` data events. `allEventStream` carries `(EventDTO, delivered)` for
every `fire` and `request`; `delivered` means a node accepted it. The two streams are independent.
See [12](12-observability.md) for rate limits, the monitor and metrics.

## Cleanup

```dart
await sub.cancel();     // remove a subscription, drop its buffer and queue
bus.removeTopic<Status>(paths: ['service']); // evict the node explicitly
await bus.dispose();    // close every node, stream and resource
```

`removeTopic` works even on a model bus and cancels all subscriptions of the topic (D13). After
`dispose`, every bus method throws `StateError`.

## Recipes

### Request-response with a timeout

```dart
final result = await bus.request<Receipt>(
  order,
  paths: ['orders', 'place'],
  timeout: const Duration(seconds: 2),
  correlationId: 'checkout-42',
);
```

### State store with late subscribers

```dart
final state = EventBus(isModelBus: true);
state.fire<Status>(Status.ready, paths: ['service']);

final sub = state.subscribeEvents<Status>(
  paths: ['service'],
  onEvent: (status) => render(status),
);
render(state.currentData<Status>(paths: ['service'])); // immediate value
```

### A bounded pipeline

```dart
final stage = bus.subscribeEvents<Job>(
  paths: ['jobs'],
  bufferCapacity: 32,
  bufferOverflow: BufferOverflow.dropOldest,
  onEvent: (job) async => await process(job),
);
bus.fire<Job>(job, paths: ['jobs']); // false when a `reject` policy refuses it
```

### Sending across an isolate

```dart
final iso = EventBusIsolate(onInit: workerInit);
await iso.waitInit;
final result = await iso.request<int>(21); // worker handler's answer
iso.fire<String>('refresh');               // one-way to the worker
```

See [03](03-isolate-and-layers.md) for the directional rules and recovery.

## What's next

| Document | Content |
|---|---|
| [03-isolate-and-layers.md](03-isolate-and-layers.md) | Working through isolates and multi-layer schemes |
| [11-backpressure.md](11-backpressure.md) | Buffers, queues, pause and credits in depth |
| [12-observability.md](12-observability.md) | Errors, metrics, correlation |
| [04-fsm.md](04-fsm.md) | Finite state machine on top of the bus |
| [06-api-reference.md](06-api-reference.md) | Full API reference |
