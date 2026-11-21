# 07. Pitfalls and upgrade notes

[← 06. API reference](06-api-reference.md) · [Contents](README.md) · [Next: Transports →](08-transports.md)

The traps below are the ones that cost the most time in real applications. Each entry names the
symptom, the cause and the fix. The 3.x history is at the end; the full upgrade path is in
[15](15-migration-3-to-4.md).

## 1. The type is part of the address

`request<int>` and `subscribeEvents<num>(handler: ...)` are different topics. `fire<int>` does not
reach a `num` handler, and a pattern does not change the type token.

```dart
bus.subscribeEvents<num>(handler: ...);
await bus.request<int>(1);              // NoHandlerException: different topic
await bus.request<num>(1);              // answered
```

Use the exact static type on both sides, or normalise at the boundary.

## 2. `lastData` is the previous value

In a handler, `dto.data` is the current event and `lastData` is the previous `currentData` of the
handler's node. On the first call it is `null`. If you need the current stored value, read
`currentData<T>(paths: ...)`.

## 3. `fire` is not a delivery guarantee

`fire` returns `true` only when a listener accepted the event, a model bus stored it, a transport
published it, or a remote listener/model interest is known. It never invokes a handler. A topic with
only a handler subscription returns `false`.

```dart
bus.subscribeEvents<int>(handler: (dto, last) async => 1);
bus.fire<int>(1);                       // false — no listener
```

## 4. Legacy `listen`/`subscribe` have no backpressure controls

They are a facade over the node's raw broadcast stream. A paused legacy subscription buffers
**unboundedly** in the Dart stream, has no overflow policy or counters, and a throwing `onData` goes
to the zone instead of `bus.errors`. Use `subscribeEvents` for buffers, pause policies, error
routing, counters and handlers. The facade is removed in 5.0.0.

```dart
// dangerous under load: the stream queue is invisible and unbounded
bus.subscribe<Price>(onData: slowRender);

// bounded, observable
bus.subscribeEvents<Price>(
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
final result = await bus.request<Receipt>(
  order,
  paths: ['orders', 'place'],
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
iso.subscribe<String>(onData: render);
iso.fire<String>('refresh');

// local pub/sub
layer.current.subscribe<String>(onData: render);
```

## 7. Isolate data must be sendable

Only sendable objects cross the boundary: no closures, `Socket`s, `ReceivePort`s or objects that
capture them. `onInit` and layer init functions must be top-level/static. `arguments` and
`correlationId` travel with the DTO.

## 8. `waitInit` is about readiness and interests

`await iso.waitInit` means the worker's `onInit` finished **and** both sides exchanged listener,
handler and model interests. A `fire`/`request` sent right after it sees subscriptions made in
`onInit`. Before it, `fire`/`request` throw `StateError`; an `onInit` error comes as
`EventBusException` from `waitInit`.

## 9. `removeTopic` is stronger than a cancelled listener

`removeTopic` evicts the node even on a model bus and cancels **all** subscriptions of the topic
(D13). On a common bus, cancelling the last subscription already removes the node; on a model bus
it does not. A model bus recreates the node on the next `fire`, `request` or `listen`.

```dart
await sub.cancel();                     // node stays on a model bus
bus.removeTopic<int>(paths: ['x']);    // value and node are forgotten
```

## 10. Wildcards are local; brokers differ

`*` is one path token, `>` is one or more trailing tokens and must be last. A wildcard must be a
whole token. `fire`/`request` reject wildcard paths; only listeners/handlers/nodes may use patterns.
On the wire, MQTT uses `+`/`#` and `#` also matches zero levels; the transport filters
over-delivery so local semantics stay the same.

## 11. The type token is normalised on the wire

`<` becomes `(`, `>` becomes `)`, commas and whitespace become `_`, repeated `_` collapse. The case
is preserved: `List<int>` is `List(int)`. This matters when a broker subject or an external
producer builds the topic by hand. The type is part of the address, not an annotation.

## 12. Observability is off by default

No metrics are collected unless `ObservabilityConfig(enabled: true)` is passed. Metric keys default
to the event type token; dynamic paths do not create unbounded series. Above `cardinalityLimit`,
new keys go to `__other__` and increment `droppedMetricSeries`. Payload capture is off: errors have
`event == null` unless `capturePayloads: true`.

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

`Scope.initScope` subscribes with `bufferCapacity: 1`, `BufferOverflow.latest`. If `onUpdate` is
slow, intermediate values are dropped by design. `undo()` needs at least two calls in the history
(`maxLenForUndo >= 2`). `disposeScope()` cancels only the scope's own subscription; there is no
`removeHandler:` parameter in 4.0.

## 3.x history

The detailed 3.x fix list and the 3.0 address-model change no longer describe the current package.
Use [15. Migration](15-migration-3-to-4.md) for the upgrade path and [CHANGELOG.md](../CHANGELOG.md)
for the release history.

[Next: Transports →](08-transports.md)
