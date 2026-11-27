# 08. Migrating from 3.x to 4.x

[← Platforms](07-platforms.md) · [Documentation index](README.md)

4.x is a deliberate breaking release. The address model, handler lifecycle, transports and package
layout changed, and 3.x and 4.x peers are not wire-compatible. There is no compatibility adapter;
migrate the application and all participants together.

The migration has three parts:

1. choose explicit event addresses and replace type-prefixed topics;
2. replace `paths:`/handler APIs with `EventKey`/`EventSubscription`;
3. replace transport serializer registries with keyed codecs.

## 1. Version and wire compatibility

- Core: `event_bus_arch` 4.x; patterns: `event_bus_arch_patterns` 0.1.x; transport:
  `event_bus_arch_transport` 0.2.x; broker adapters have their own versions.
- A 3.x broker subject contains a type token (for example `OrderPlaced.orders.placed`). A 4.x
  subject is the application address (for example `orders.placed.v1`).
- Mixed 3.x/4.x processes do not interoperate. Deploy all publishers and subscribers together, or
  use a translation service outside the bus.

## 2. Choose addresses first

An address is an application-owned routing identity. It is not derived from a Dart class name:

```dart
// 3.x style: the type is part of the topic
OrderPlaced.orders.placed

// 4.x: the address is chosen by the application
EventKey<OrderPlaced>('orders.placed.v1')
EventPatternKey<OrderPlaced>('orders.*')
```

Rules of thumb:

- keep addresses lowercase and stable; use a version suffix when the payload schema can change;
- do not include `Type.toString()` or `runtimeType` in an address;
- one address may carry more than one payload type, because the key still contains the local type;
- define address constants near the domain type, not in dispatch code.

## 3. API mapping

### `fire`

```dart
// 3.x
bus.fire<OrderPlaced>(order, paths: ['orders', 'placed']);
bus.fire<OrderPlaced>(order, paths: ['orders', 'placed'], separator: '/');

// 4.x
final placed = EventKey<OrderPlaced>('orders.placed.v1');
bus.fire(placed, order);
```

`fire` takes an exact `EventKey<T>`; a pattern key is not accepted.

### `request`

```dart
// 3.x
final result = await bus.request<OrderPlaced>(order, paths: ['orders', 'placed']);

// 4.x
final result = await bus.request(placed, order);
```

### `listen`, `subscribe` and `subscribeEvents`

```dart
// 3.x
bus.listen<OrderPlaced>(paths: ['orders', 'placed']).listen(render);
bus.subscribe<OrderPlaced>(paths: ['orders', 'placed'], onData: render);
bus.subscribeEvents<OrderPlaced>(paths: ['orders', 'placed'], onEvent: render);

// 4.x
bus.listen(placed).listen(render);
bus.subscribe(placed, onEvent: render);
```

`subscribe` is the managed subscription and returns `EventSubscription<T>`; the old raw
`subscribe` stream is now `listen(selector).listen(...)`. A pattern uses `EventPatternKey<T>`.

### `currentData`, `have*`, removal

```dart
// 3.x
bus.currentData<OrderPlaced>(paths: ['orders', 'placed']);
bus.haveListener<OrderPlaced>(paths: ['orders', 'placed']);
bus.haveHandler<OrderPlaced>(paths: ['orders', 'placed']);
bus.removeTopic<OrderPlaced>(paths: ['orders', 'placed']);

// 4.x
bus.currentData(placed);
bus.probeFire(placed, order).localListeners > 0;
bus.probeRequest(placed, order).localHandlers > 0;
bus.remove(placed);
```

`haveListener`/`haveHandler`/`haveAvailableHandler` are deprecated: they cannot see whether the
payload type is accepted. Use `probeFire(key, data)` and `probeRequest(key, data)`. Use
`remove(selector)` for one typed node and `removeAddress(address)` for every type at an address.

### Handlers

```dart
// 3.x
bus.handlers.setHandler<OrderPlaced>((dto, last) async => process(dto.data));
bus.handlers.removeHandler<OrderPlaced>();

// 4.x
final sub = bus.subscribe(placed, handler: (dto, last) async => process(dto.data));
await sub.cancel(); // replacing removeHandler
```

A handler is a capability of a subscription. Store the subscription for cancellation; `fire` does
not invoke handlers.

### Types renamed or moved

| 3.x | 4.x |
|---|---|
| `Topic` / `TopicPattern` | `EventAddress` / `EventPattern` |
| `EventDTO.topic` | `EventDTO.address` / `EventDTO.key` |
| `EventSubscription.topic` | `EventSubscription.selector` / `.address` |
| `paths:` / `separator:` arguments | `EventKey` / `EventPatternKey` |
| `FSM`, `Scope`, `Command` in core | `event_bus_arch_patterns` package |
| `EventBusHandlers` | `EventSubscription` with `handler:` |

## 4. Transport migration

3.x transports accepted string serializer/deserializer registries and type tags. 4.x uses
address-keyed codecs:

```dart
// 3.x
final bus = EventBusNats(
  uri,
  serializers: {'OrderPlaced.orders.placed': encodeOrder},
  deserializers: {'OrderPlaced.orders.placed': decodeOrder},
  typeTags: {'OrderPlaced': 'OrderPlaced'},
);

// 4.x
final bus = EventBusNats.keys(
  uri,
  codecs: EventCodecRegistry(exact: {
    EventAddress('orders.placed.v1'): EventCodec(
      encode: (dto) => (null, encodeOrder(dto)),
      decode: (bytes, address, {arguments}) => decodeOrder(bytes, address),
    ),
  }),
  originId: newTransportOriginId(),
);
```

- The subject is the address; `EventAddressMapper` applies the broker separator/namespace.
- A codec may support only `encode`, only `decode`, or both. A request needs both.
- Only the exact-key node publishes; a pattern/supertype node delivers locally only.
- `fire` delivers locally before publishing; an offline broker does not roll back local listeners.
- `replyTo` is validated; an invalid response subject is reported and not published.
- `CancelToken` cancels the caller's wait; the broker request continues until its own timeout.
  Pending requests fail on connection drop or close.
- There are no `typeTags`, string serializer maps, `TopicSubjectMapper`, `TransportEventNode` or
  `TopicRegistryIndex` in the keyed path.

## 5. Patterns package

`FSM`, `Scope` and `Command` moved out of core:

```yaml
dependencies:
  event_bus_arch: ^4.2.0
  event_bus_arch_patterns: ^0.1.0
```

```dart
import 'package:event_bus_arch_patterns/event_bus_arch_patterns.dart';

final command = Command<int>(bus, EventKey<int>('counter'));
```

See the [patterns README](../packages/event_bus_arch_patterns/README.md) for the selector-based
APIs.

## 6. Migration tool

`tool/migrate_3_to_4.dart` is a review-first assistant:

```bash
# report only; writes nothing
dart run tool/migrate_3_to_4.dart lib test

# apply only the safe handler rewrite
dart run tool/migrate_3_to_4.dart --write lib
```

The tool reports:

- `handlers.setHandler` calls (the only automatic rewrite);
- `paths:` and `separator:` usages, with file and line;
- `Topic`/`TopicPattern`, `subscribeEvents` and `removeTopic` usages;
- legacy transport registries (`serializers`, `deserializers`, `typeTags`,
  `TopicSubjectMapper`, `TransportEventNode`, `TopicRegistryIndex`);
- `EventBusHandlers`, `removeHandler`, cross-bus handler copies and `rxdart`.

It does **not** invent addresses. A path-to-address rewrite changes routing identity and must be
chosen by the application. Each reported call needs a manual `EventKey`/`EventPatternKey` decision;
the tool's report is the checklist.

## 7. Checklist

- [ ] All participants use 4.x; no mixed 3.x/4.x deployment.
- [ ] Address constants are chosen and documented; no type names in addresses.
- [ ] `fire`/`request` call sites use exact `EventKey<T>`.
- [ ] Listener/handler subscriptions use `subscribe`; raw streams use `listen`.
- [ ] Handlers store and cancel their `EventSubscription`.
- [ ] `have*` routing decisions are replaced by probes with the actual data.
- [ ] Removal uses `remove`/`removeAddress` intentionally.
- [ ] Transport codecs replace serializer/deserializer/typeTag registries.
- [ ] Pattern-based code imports `event_bus_arch_patterns`.
- [ ] The migration tool report has no unexplained path, topic or transport findings.
- [ ] Tests exercise the new addresses, not the old type-prefixed topics.

## What's next

| Document | Content |
|---|---|
| [README](README.md) | Documentation index |
| [01-concepts](01-concepts.md) | Addresses, keys, nodes and subscriptions |
| [06-api-reference](06-api-reference.md) | Public types and signatures |
