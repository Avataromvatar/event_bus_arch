# 15. Migration 3.x to 4.0

[← 14. Web and platform](14-web.md) · [Contents](README.md)

4.0 is a breaking release. The address model changes from **type + paths** to an explicit
`EventAddress` plus a typed `EventKey<T>`. The handler API, the subscription model, error
reporting, isolate behaviour, transports and the package versions change as well. This guide is the
shortest safe path; the mechanical part is handled by `tool/migrate_3_to_4.dart` (limited to the
handler rewrite until the address rewrite lands).

## 1. At a glance

| Area | 3.x | 4.0 |
|---|---|---|
| Address | `Topic` = `'$T'` + `paths` joined by a separator: `int.sensor.temp` | `EventAddress('sensor.temp')`; the type is a separate key |
| Key | static type parameter of each call | `EventKey<T>('sensor.temp')`, `EventPatternKey<T>('sensor.*')` |
| Wildcards | `*`/`>` in `paths`, per-call `separator` | fixed `*`/`>` in `EventPatternKey`; no separator |
| Handlers | `bus.handlers.setHandler<T>(handler: ...)`, `removeHandler`, `EventBusHandlers` | `bus.subscribeEvents(key, handler: ...)`, keep the `EventSubscription`, `cancel()` it |
| Handler concurrency / queue | node-level | per subscription: `handlerConcurrency`, `requestQueueCapacity` |
| Listener control | `listen`/`subscribe` only | `subscribeEvents(selector, onEvent:)` with buffer, overflow policy, pause/resume/resize |
| Listener + handler | separate registrations | one subscription can have both callbacks |
| `fire` return | node accepted | listener, model storage, transport or known remote listener/model interest; a handler-only node does **not** count (D14) |
| Errors | separate streams/raw objects | `EventBus.errors` of `EventBusError`; `recentErrors`, `suppressedErrors`, `EventBusErrorMonitor`; `EventBusError.address` |
| Isolate `fire` | outbound only | outbound only (unchanged), but interest-aware and returns a real answer; local listeners never see it |
| Isolate `request` | always crosses; waited for timeout without a handler | local handler first; immediate `NoHandlerException`; timeout + `CancelToken`; cancellation across the bridge |
| Isolate `waitInit` | onInit completed | onInit completed **and** the interest snapshot exchanged |
| Isolate recovery | none | `EventBusIsolate.restart()`, worker watchdog, `WorkerPool`, `Layers.supervise` |
| Observability | `allEventStream` + logger | opt-in metrics, snapshots, changes, correlation ids; `allEventStream` stays; metric keys are addresses |
| rxdart | re-exported | removed; import it yourself if needed |
| Transport | `serializers`/`deserializers`/`typeTags` by type | `EventCodecRegistry` by address/pattern; the subject is the address |
| FSM / Scope / Command | part of the core package | moved to `event_bus_arch_patterns`; take keys, not paths |
| Versions | core 3.x | core 4.0.0; patterns 0.1.0; transport/MQTT 0.2.0; NATS 1.1.0 |

```mermaid
flowchart LR
    A["Bump dependencies"] --> B["Give every event an address and key"]
    B --> C["Replace handlers with subscriptions"]
    C --> D["Review fire return values"]
    D --> E["Review isolate and transport call sites"]
    E --> F["Adopt errors / observability (optional)"]
    F --> G["Run the migration script + tests"]
```

## 2. The address model

Before:

```dart
bus.fire<Order>(order, paths: ['orders', 'placed'], separator: '.');
bus.subscribeEvents<Order>(paths: ['orders', '*'], onEvent: render);

final last = bus.currentData<Order>(paths: ['orders', 'placed']);
```

After:

```dart
final orderPlaced = EventKey<Order>('orders.placed');
final anyOrder = EventPatternKey<Order>('orders.*');

bus.fire(orderPlaced, order);
bus.subscribeEvents(anyOrder, onEvent: render);

final last = bus.currentData(orderPlaced);
```

Rules to carry over:

* An address is a dot-separated string chosen by the application. Put a version in it when the
  payload schema can change: `orders.placed.v1`.
* The Dart type is **not** in the address. It is the delivery filter of the `(address, Type)`
  node, so `EventKey<Order>` and `EventKey<Invoice>` on `orders.placed` are separate nodes.
* `*` matches one token and `>` one or more trailing tokens; a wildcard must be a whole token.
  `fire`/`request` require an exact `EventKey`; the compiler rejects an `EventPatternKey`.
* The per-call `paths`/`separator` parameters and `EventBus.defaultTopicPathSeparator` are gone.
* Do not build addresses from `T.toString()`/`runtimeType`: minifiers rename user classes. The key
  captures type identity through `Type _typeOf<T>() => T;`.

## 3. Handlers become subscriptions

Before:

```dart
bus.handlers.setHandler<Order>(paths: ['orders'], handler: (dto, last) async {
  return await process(dto);
});

bus.handlers.removeHandler<Order>(paths: ['orders']);

// or, historically:
bus.handlers.addAllHandlerFromOtherBus(other);
bus.handlers.removeAllHandlerPresentInOtherBus(other);
```

After:

```dart
final ordersKey = EventKey<Order>('orders');
final orders = bus.subscribeEvents(ordersKey,
  handlerConcurrency: 2,
  requestQueueCapacity: 32,
  handler: (dto, last) async => await process(dto),
);

await orders.cancel(); // replaces removeHandler
```

* `handlerConcurrency` (default 1) and `requestQueueCapacity` (defaults to the bus setting, 64;
  `0` rejects immediately when no slot is free) are per subscription.
* `inFlight`, `bufferedRequests`, `isHandlerBusy` and `hasRequestCapacity` expose the queue state.
* Two subscriptions on the same key compete; the bus round-robins inside the resolved tier. The
  exact tier never falls back to a pattern tier when it is busy.
* A handler returning a value answers `request`; an exception is returned to the caller **and**
  reported through `errors` (kind `handler`).
* There is no cross-bus handler copying. Create subscriptions on each bus; if you need a shared
  queue, keep one subscription and route events to it.

## 4. `fire` return semantics

`fire` now returns `true` only when at least one of these happened:

* a listener accepted the event (a rejected listener did not accept it);
* a model bus stored the value;
* a transport accepted it for publishing;
* the other side of an isolate bridge has a known listener or model interest.

A node that has only a handler subscription does **not** make `fire` true. In 3.x a handler created
a node, so `fire` could return true for a topic nobody listened to. If your code branched on that,
check it: the 4.0 answer is the honest one.

`fire` also accepts `correlationId` (optional). Local and remote delivery are unchanged for a
normal bus; the isolate bridge is directional (see below).

## 5. Isolates and layers

### `fire` on an isolate bridge

`fire` is **outbound only**. Local listeners on the same side do not receive the event; this is what
prevents a listener that fires the same key from re-entering itself. Local pub/sub belongs to a
local `EventBus` (inside `Layers`, that is `layer.current`).

```dart
final updateKey = EventKey<Update>('state');

// before: a main-side listener could see its own fire
// after: it sees only events coming from the worker
iso.subscribe(updateKey, onData: render);

// to send to the worker:
iso.fire(updateKey, Update(...));

// local pub/sub:
final local = EventBus();
final sub = local.subscribeEvents(updateKey, onEvent: (_) {});
```

### Requests

`request` checks the local side first. If a local handler exists, the request never crosses the
bridge. Otherwise it crosses only when the other side has a known handler; with neither it throws
`NoHandlerException` immediately, without waiting for a timeout. `timeout` and `CancelToken` are
supported; cancelling removes a queued request on the worker if it has not been dispatched, and a
late answer is discarded.

### Initialization and recovery

* `await iso.waitInit` now also means "the interest snapshot has been exchanged": a
  `fire`/`request` right after it sees the subscriptions made in `onInit`.
* `iso.restart()` restarts the worker in place: local nodes, listeners and model state survive;
  pending requests fail; a generation counter ignores late messages.
* New: `WorkerPool` for N workers and `Layers.supervise` for a whole-chain restart. See
  [13](13-pool-and-supervision.md).

## 6. Transports

Before, a transport looked up a serializer/deserializer by type token and could use `typeTags` to
stabilise the name. In 4.0 the subject is the address and the codec is typed:

```dart
final bus = TransportEventBus.keys(
  connection: connection,
  addresses: NatsAddressMapper(prefix: 'app'),
  codecs: EventCodecRegistry(
    exact: {
      EventAddress('orders.placed.v1'): EventCodec(
        encode: (dto) =>
            (null, Uint8List.fromList(utf8.encode(jsonEncode(dto.data)))),
        decode: (data, address, {arguments}) => EventDTO.withKey(
          EventKey<Order>(address.value),
          Order.fromJson(jsonDecode(utf8.decode(data))),
          arguments: arguments,
        ),
      ),
    },
  ),
  originId: 'orders-service',
);
```

* `EventCodecRegistry.resolve(address)` picks an exact codec or the most specific pattern codec.
* Only the node whose exact key equals the DTO key publishes; pattern and supertype nodes deliver
  locally.
* `typeTags`, `wireTypes`, `TopicSubjectMapper` and type-string lookup are not used by the keyed
  transport. NATS and MQTT map address tokens to their grammar (`NatsAddressMapper`,
  `MqttAddressMapper`).
* A pattern subscription may have a decoder but no encoder; it then receives without publishing.

## 7. Error handling

Before, failures could arrive through separate transport streams, raw objects, zone errors or a
failed `waitInit`. In 4.0:

```dart
final sub = bus.errors.listen((error) {
  print('${error.kind.name} ${error.address}: ${error.error}');
});
```

* `EventBusError` is data; the stream never carries stream errors.
* `recentErrors` is a bounded buffer (100); `suppressedErrors` counts rate-limited errors.
* `EventBusErrorMonitor` aggregates several buses and offers `snapshot()`.
* `EventBusError.event` is `null` unless `ObservabilityConfig(capturePayloads: true)` is used.
* `TransportEventBus.errors` is now `Stream<EventBusError>`; a consumer that expected
  `Stream<Object>` still compiles, but code that pattern-matched raw errors must switch to
  `EventBusError.error`.
* `EventBusError.address` is the event address; `topic` remains as a compatibility alias.
* Listener exceptions: use `subscribeEvents(onError:)` or the `errors` stream; a raw `listen`
  still has its stream `onError`, but the bus-level contract is the error stream.

Migration checklist:

- [ ] give every event an explicit address and an `EventKey`/`EventPatternKey`;
- [ ] replace every `setHandler`/`removeHandler` with a stored `subscribeEvents` subscription;
- [ ] search for code that relied on `fire == true` for a handler-only key;
- [ ] review every isolate `fire` that expected a local echo (use a local bus instead);
- [ ] add timeouts to remote requests and decide whether to pass a `CancelToken`;
- [ ] replace serializer/typeTag registries with `EventCodecRegistry` by address;
- [ ] replace raw transport error handling with `EventBusError`;
- [ ] if you used rxdart, add it to your own dependencies (it is no longer re-exported);
- [ ] run the analyzer and the package test suites.

## 8. Observability (optional)

Nothing is collected unless you ask for it:

```dart
final bus = EventBus(observability: const ObservabilityConfig(enabled: true));
final snapshot = bus.metrics.snapshot();
```

See [12](12-observability.md). Metric keys are event addresses. `allEventStream` and
`EventBusLogger` remain available and are independent of metrics.

## 9. Versions and packages

| Package | 4.0 line | Constraint |
|---|---|---|
| `event_bus_arch` | 4.0.0 | — |
| `event_bus_arch_patterns` | 0.1.0 | `event_bus_arch: ^4.0.0` |
| `event_bus_arch_transport` | 0.2.0 | `event_bus_arch: ^4.0.0` |
| `event_bus_arch_mqtt` | 0.2.0 | `event_bus_arch: ^4.0.0`, `event_bus_arch_transport: ^0.2.0` |
| `event_bus_arch_nats` | 1.1.0 | `event_bus_arch: ^4.0.0`, `event_bus_arch_transport: ^0.2.0` |

Bump the dependencies together; a 3.x adapter cannot talk to a 4.0 core (the isolate protocol and
the transport metadata changed).

## 10. Migration script

`tool/migrate_3_to_4.dart` scans for the known 3.x handler surface and reports every finding:

```bash
dart run tool/migrate_3_to_4.dart lib test
```

* `bus.handlers.setHandler<T>(...)` is reported: replace it with
  `bus.subscribeEvents(EventKey<T>('stable.address'), handler: ...)` and keep the returned
  `EventSubscription`.
* `removeHandler` is reported: cancelling the subscription replaces it.
* `addAllHandlerFromOtherBus` / `removeAllHandlerPresentInOtherBus` are reported for manual work.
* `EventBusHandlers` type references and `rxdart` usage are reported; add rxdart to your own
  dependencies if you still need it.

Nothing is rewritten automatically. The address model is the breaking change: a script cannot
choose the stable address, the `EventKey<T>` and the codec registry for you. Use the table in
section 2, then run the analyzer and the package tests.

[Back to the overview](00-overview.md)
