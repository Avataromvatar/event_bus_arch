# 02. EventBus in practice

[← Table of contents](README.md) · [Next: Isolates and layers →](03-isolate-and-layers.md)

This is the practical guide: how to publish, receive, answer requests and pick addresses. The
architectural details are in [01](01-architecture.md); every public member is in
[06](06-api-reference.md).

## Creating a bus

```dart
final bus = EventBus();                        // common bus: a message pipe
final state = EventBus(isModelBus: true);      // model bus: keeps currentData
final observed = EventBus(
  observability: const ObservabilityConfig(enabled: true),
);
```

`EventBus(...)` returns an `EventBusImpl`. There is no separator setting: addresses always use
`.`. Always call `await bus.dispose()` when the bus is no longer needed; it is idempotent.

An address is a string chosen by the application, and a key binds that string to a static type:

```dart
final orderPlaced = EventKey<Order>('orders.placed');
final anyOrder = EventPatternKey<Order>('orders.*');
final audit = EventKey<AuditEntry>('orders.placed');   // same address, different type node
```

`orders.placed` and `orders.placed.v1` are different addresses. Put a version in the address when
the payload schema can change.

## Publishing: `fire`

```dart
final accepted = bus.fire(orderPlaced, order,
    arguments: {'priority': 'high'}, correlationId: 'job-42');
```

* `fire` returns `true` when a listener accepted the event, a model node stored it, or a transport
  published it. A handler-only subscription does not count (D14).
* `fire` never invokes a handler.
* `fire` requires an `EventKey<T>`; a pattern key does not compile. The address itself is already
  concrete because the key holds it.
* `arguments` travel in `dto.arguments`; `correlationId` travels in `dto.correlationId` and across
  isolates and transport headers.
* `fire` does not wait for listeners; their callbacks may run later.

### The model bus

```dart
final state = EventBus(isModelBus: true);
final serviceKey = EventKey<Status>('service.status');

state.fire(serviceKey, Status.ready);
print(state.currentData(serviceKey)); // Status.ready
```

A model bus creates the node on `fire` and keeps the last value even when nobody is listening. A
common bus returns `false` for a key with no node and does not store the value.

## Publishing: `request`

```dart
final receipt = await bus.request(receiptKey, order,
    arguments: {'priority': 'high'},
    timeout: const Duration(seconds: 2),
    correlationId: 'job-42');
```

`request` resolves one handler: the exact handler first, then the most specific matching pattern
handler. It returns the handler's result. While the handler runs, listeners of the same key also
receive the event, exactly like `fire`.

`request` supports:

* `timeout` — the future fails with `RequestTimeoutException`; a queued request is removed, a
  dispatched handler keeps running and its result is discarded;
* `cancelToken` — the future fails with `RequestCanceledException`; the same queue/dispatch rules
  apply;
* `correlationId` — reaches the handler and the error envelope.

### Exceptions

| Situation | Exception |
|---|---|
| No handler for the key | `NoHandlerException` |
| A handler exists but has no free slot/queue room | `BusyException` |
| The timeout expired | `RequestTimeoutException` |
| The caller cancelled | `RequestCanceledException` |
| The handler threw | the handler's own error, rethrown at the caller |
| The bus is disposed | `StateError` |

Each exception exposes `address` (and the compatibility alias `topic`).

## Receiving: `listen` and `subscribe`

`listen` returns a plain `Stream<T>`; `subscribe` returns a `StreamSubscription<T>`.

```dart
final priceKey = EventKey<Price>('market.btc');
final stream = bus.listen(priceKey);
stream.listen((price) => print(price));

final subscription = bus.subscribe(priceKey, onData: (price) => print(price));
```

These are the raw node-stream views: they have no bounded buffer, overflow policy or counters.
Use `subscribeEvents` when the consumer can be slow.

## Receiving: `subscribeEvents`

`subscribeEvents` returns an `EventSubscription<T>` with its own lifecycle and delivery state:

```dart
final sub = bus.subscribeEvents(priceKey,
  bufferCapacity: 8,
  bufferOverflow: BufferOverflow.latest,
  onEvent: (price) async {
    await render(price);
  },
  onError: (error, stackTrace) => print('listener error: $error'),
);

bus.fire(priceKey, Price(42));
...
await sub.cancel();
```

A listener subscription is a consumer with a bounded buffer. `BufferOverflow` decides what happens
when the buffer is full: `latest`, `dropOldest`, `dropNewest` or `reject`. The subscription also
supports `pause()`, `resume()`, `resize(capacity)`, counters (`delivered`, `dropped`, `buffered`)
and a `.stream` view. See [11](11-backpressure.md).

## Handlers as subscriptions

A handler is a capability of a subscription, not a global registry:

```dart
final orders = bus.subscribeEvents(orderPlaced,
  handlerConcurrency: 1,          // one in-flight request by default
  requestQueueCapacity: 4,        // queued requests before BusyException
  handler: (dto, lastData) async {
    // lastData is the PREVIOUS value of this node; dto.data is the current one
    return await _placeOrder(dto.data);
  },
);

...
await orders.cancel();            // removes the handler, fails its queued requests
```

`handlerConcurrency` lets one subscription answer several requests in parallel;
`requestQueueCapacity` bounds the FIFO. Without free capacity the request fails with
`BusyException` (an exact tier never falls back to a pattern tier).

### A subscription can be both

```dart
final audit = bus.subscribeEvents(orderPlaced,
  onEvent: (order) => log('fire: $order'),
  handler: (dto, lastData) async {
    log('request: ${dto.data}');
    return 'ok';
  },
);
```

`fire` calls only `onEvent`; `request` calls the handler and also offers the value to `onEvent`.

### Pattern handlers

```dart
final sensorAny = EventPatternKey<Sensor>('sensor.*');

bus.subscribeEvents(sensorAny, handler: (dto, lastData) async {
  return dto.data.value * 2;
});

await bus.request(EventKey<Sensor>('sensor.temp'), Sensor(21)); // 42
```

A concrete request finds the pattern tier when the exact bucket has no accepting handler.
`>` patterns work the same way and match one or more trailing tokens.

## `currentData`

```dart
final last = bus.currentData(serviceKey);
```

`currentData` takes an exact key and reads only that node. For a pattern use
`currentData(patternKey)` — it returns the last value delivered to the pattern node (the pattern's
own type node), not a search across matching concrete nodes. On a model bus the value survives
until `remove`/`dispose`.

The handler's `lastData` is the previous `currentData` of the handler's own node.

## Availability checks

```dart
bus.haveListener(serviceKey);          // a listener exists
bus.haveHandler(serviceKey);           // a handler exists, even if paused
bus.haveAvailableHandler(serviceKey);  // one could accept a request now
```

Each accepts an exact key or a pattern key; a pattern check asks about that pattern node.
A concrete listener check also counts a matching pattern listener.

## Errors and all events

```dart
final errors = bus.errors.listen((error) {
  print('${error.kind} on ${error.address}: ${error.error}');
});
final monitor = EventBusErrorMonitor();
monitor.add(bus);
```

`errors` carries `EventBusError` data events, rate-limited per `(kind, address)`. It never carries
stream errors. `allEventStream` reports every `fire`/`request` with an `accepted` flag; it is used
by `FSM` and `EventBusLogger`. See [12](12-observability.md).

## Cleanup

```dart
bus.remove(serviceKey);                 // one exact type node
bus.removePattern(sensorAny);           // one pattern type node
bus.removeAddress(EventAddress('service.status')); // every type at that address
await bus.dispose();                    // the whole bus
```

`remove` works even on a model bus and cancels all subscriptions of the removed node (D13). A
transport node also cancels its broker subscription. A model bus creates the node again on the next
`fire`, `request` or `listen`.

## Recipes

### Request-response with a timeout

```dart
try {
  final result = await bus.request(receiptKey, order,
      timeout: const Duration(milliseconds: 500));
  print(result);
} on RequestTimeoutException catch (error) {
  print('no answer on ${error.address}');
}
```

### State store with late subscribers

```dart
final state = EventBus(isModelBus: true);
state.fire(serviceKey, Status.ready);

final sub = state.subscribeEvents(serviceKey,
  initialData: state.currentData(serviceKey),
  onEvent: render,
);
```

A late subscriber can read `currentData` or pass it as `initialData`; the model bus has already
stored the value.

### A bounded pipeline

```dart
final stage = bus.subscribeEvents(jobKey,
  bufferCapacity: 16,
  bufferOverflow: BufferOverflow.reject,
  onEvent: process,
);

final accepted = bus.fire(jobKey, job); // false when the reject policy refused it
```

### Sending across an isolate

```dart
final iso = EventBusIsolate(onInit: _worker);
await iso.waitInit;

final result = await iso.request(workKey, 21); // the worker handler's answer
iso.fire(refreshKey, 'refresh');               // one-way to the worker
```

`EventBusIsolate` uses the same keys; the address string crosses the boundary unchanged. See
[03](03-isolate-and-layers.md).

## What's next

| Document | Content |
|---|---|
| [03-isolate-and-layers.md](03-isolate-and-layers.md) | Isolates, layers, interest sync |
| [11-backpressure.md](11-backpressure.md) | Buffers, overflow policies, queues, credits |
| [12-observability.md](12-observability.md) | Errors, metrics, correlation ids |
| [06-api-reference.md](06-api-reference.md) | Every public type and member |
