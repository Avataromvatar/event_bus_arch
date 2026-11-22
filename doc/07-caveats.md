# 07. Pitfalls and limits

[← 06. API reference](06-api-reference.md) · [Contents](README.md) · [Next: Transports →](08-transports.md)

The traps below are the ones that cost the most time in real applications. Each entry names the
symptom, the cause and the fix. The full upgrade path from 3.x is in [15](15-migration-3-to-4.md).

## 1. The address is a string; the type is a separate filter

`EventKey<Order>('orders')` and `EventKey<Invoice>('orders')` are different nodes with separate
`currentData`, but they share the address string. A listener on a supertype key accepts subtype
data; a listener on an unrelated type does not.

```dart
final asNum = EventKey<num>('counter');
bus.subscribe(asNum, handler: (dto, last) async => dto.data);
await bus.request(EventKey<int>('counter'), 1);   // answered — int is num
await bus.request(EventKey<String>('counter'), 'x'); // NoHandlerException
```

Pick the type deliberately on both sides, or normalise at the boundary.

## 2. `lastData` is the previous value

In a handler, `dto.data` is the current event and `lastData` is the previous `currentData` of the
handler's node. On the first call it is `null`. If you need the current stored value, read
`currentData(key)`.

## 3. `fire` is not a delivery guarantee

`fire` returns `true` only when a listener accepted the event, a model bus stored it, a transport
published it, or a remote listener/model interest is known. It never invokes a handler. A key with
only a handler subscription returns `false`.

```dart
bus.subscribe(counterKey, handler: (dto, last) async => 1);
bus.fire(counterKey, 1);                // false — no listener
```

## 4. `listen`/`subscribe` have no backpressure controls

They are the raw node-stream view. A paused raw subscription buffers **unboundedly** in the Dart
stream, has no overflow policy or counters, and a throwing `onData` goes to the zone instead of
`bus.errors`. Use `subscribe` for buffers, pause policies, error routing, counters and
handlers.

```dart
// dangerous under load: the stream queue is invisible and unbounded
bus.subscribe(priceKey, onEvent: slowRender);

// bounded, observable
bus.subscribe(priceKey,
  bufferCapacity: 1,
  bufferOverflow: BufferOverflow.latest,
  onEvent: slowRender,
);
```

## 5. Requests: one outcome, no retry

`request` fails with `NoHandlerException`, `BusyException`, `RequestTimeoutException` or
`RequestCanceledException`. A queued request is removed on timeout/cancel; a dispatched handler keeps
running and its result is discarded. A request whose worker dies fails and is **not retried** — make
idempotency explicit if you need it.

```dart
final result = await bus.request(receiptKey, order,
  timeout: const Duration(seconds: 2),
  correlationId: trackId,
);
```

## 6. An isolate bridge is directional

Local listeners on an `EventBusIsolate` receive events coming from the other side; `fire` goes out
only. A main-side listener does not see a main-side fire, and a worker listener does not see its own
fire. This prevents feedback loops. Use a local `EventBus` (or `layer.current` inside `Layers`) for
local pub/sub.

```dart
// does not echo back to the main-side listener
iso.subscribe(refreshKey, onEvent: render);
iso.fire(refreshKey, 'refresh');

// local pub/sub
layer.current.subscribe(refreshKey, onEvent: render);
```

## 7. Isolate data must be sendable

Only sendable objects cross the boundary: no closures, `Socket`s, `ReceivePort`s or objects that
capture them. `onInit` and layer init functions must be top-level/static. The key, `arguments` and
`correlationId` travel with the DTO.

## 8. `waitInit` is about readiness and interests

`await iso.waitInit` means the worker's `onInit` finished **and** both sides exchanged listener,
handler and model interests. A `fire`/`request` sent right after it sees subscriptions made in
`onInit`. Before it, `fire`/`request` throw `StateError`; an `onInit` error comes as
`EventBusException` from `waitInit`.

## 9. `remove` is stronger than a cancelled listener

`remove(key)` evicts the node even on a model bus and cancels **all** subscriptions of that keys
(D13). On a common bus, cancelling the last subscription already removes the node; on a model bus
it does not. A model bus recreates the node on the next `fire`, `request` or `listen`.

```dart
await sub.cancel();                 // node stays on a model bus
bus.remove(counterKey);             // value and node are forgotten
```

`remove(patternKey)` removes one pattern type node; `removeAddress(address)` removes every
type node at an exact address.

## 10. Wildcards are local; brokers differ

`*` is one token, `>` is one or more trailing tokens and must be last. A wildcard must be a whole
token. `fire`/`request` require an `EventKey`; only listeners/handlers/nodes may use
`EventPatternKey`. On the wire, MQTT uses `+`/`#` and `#` also matches zero levels; the transport
filters over-delivery so local semantics stay the same.

## 11. Type identity must not be stringified

The type is captured from `T` (`Type _typeOf<T>() => T;`) and compared as a `Type` object. Do not
build an address, a codec key or a metric key from `T.toString()`/`runtimeType`: minifiers rename
user classes, and the local `dart compile js -O2` check showed a user class becoming `minified:bd`.
Put the stable name in the address (`orders.placed.v1`) and use typed codecs.

## 12. Observability is off by default

No metrics are collected unless `ObservabilityConfig(enabled: true)` is passed. Metric keys default
to the event address; `metricKeyBuilder` can coarsen them. Above `cardinalityLimit`, new keys go to
`__other__` and increment `droppedMetricSeries`. Payload capture is off: errors have `event == null`
unless `capturePayloads: true`.

```dart
final bus = EventBus(observability: const ObservabilityConfig(enabled: true));
print(bus.metrics.snapshot().fired);
```

## 13. Pool and layer recovery has limits

`WorkerPool` and `Layers.supervise` restart workers with `SupervisionPolicy`. After `maxRestarts` in
the window the pool/chain becomes `failed`. Pending requests fail; they are never replayed. During a
restart, calls on the bridge throw `StateError`; use `waitReady()`. On the web both throw
`UnsupportedError` at construction.

## 14. rxdart is not re-exported

4.0 has no rxdart dependency. If you used the 3.x re-export, add `rxdart` to your own `pubspec.yaml`.
The one method the bus used (`doOnCancel`) is replaced by native subscription machinery.

## 15. Scope is a latest-value consumer

`Scope` lives in `event_bus_arch_patterns`. `Scope.initScope` subscribes with
`bufferCapacity: 1`, `BufferOverflow.latest`. If `onUpdate` is slow, intermediate values are dropped
by design. `undo()` needs at least two calls in the history (`maxLenForUndo >= 2`).
`disposeScope()` cancels only the scope's own subscription; there is no `removeHandler:` parameter
in 4.0.

[Next: Transports →](08-transports.md)
