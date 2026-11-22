# ADR-0009: Event address and key — an explicit address with a local type

- Status: Accepted
- Date: 2026-11-22
- Supersedes: the type-as-address model of 3.x/4.0 (`Topic.create<T>`, `'$T'` as the first token,
  `typeTags`/`wireTypes`, `defaultTopicPathSeparator`). ADR-0001/0002/0003/0005/0007 remain in
  force for subscriptions, handlers, requests, isolate interest and supervision respectively.
- Related: [2026-11-22-event-address-analysis.md](../artifacts/plans/2026-11-22-event-address-analysis.md),
  [2026-11-22-defect-remediation-plan.md](../artifacts/plans/2026-11-22-defect-remediation-plan.md)
- Implementation: implemented on `version4` (2026-11-22). The production API is E-only: `Topic`/`TopicPattern`, `paths`/`separator`, `*Legacy` methods and the legacy transport registries are removed. A test-only facade (`test/legacy_compat.dart`) keeps the old behaviour tests; it is not exported by the package.

## Context

The current address is `'$T'` plus `paths`, joined by `separator` (`lib/src/topic.dart:33-34`).
The type token is therefore the first part of the wire subject and of every local map key.

This was workable locally, but it couples the wire contract to the Dart type name:

* renaming a class changes the address;
* web release minification and AOT obfuscation change `'$T'`; an empirical check on
  `dart compile js -O2` showed a user class token as `minified:…`, and the current
  `TransportEventBus` with string-keyed `serializers`/`typeTags` published **zero** events for a
  user class;
* `typeTags` is keyed by the local type token string, so it does not fix the user-class case;
* routing depends on the static type at the call site: `DomainEvent e = OrderPlaced()` routes to
  `DomainEvent`, not `OrderPlaced`;
* there is no subtype routing, no explicit channel name, and no place for a stable version except
  the type name itself.

The owner has chosen the radical, long-term option: remove the Dart type from the address
entirely, make the address explicit and stable, and keep the type as a local, typed key. This is
"Option E" in the analysis document.

## Decision

### 1. The address is an explicit, user-supplied string

The user chooses the address once. It is the wire contract and the local identity (with the type,
see §2). There is no type token and no implicit address.

```dart
final orderPlaced = EventKey<OrderPlaced>('orders.placed');
final anyOrder = EventPatternKey<OrderPlaced>('orders.*');
```

The local address grammar is fixed: `.` separates tokens; `*` matches exactly one token; `>`
matches one or more trailing tokens. It is a grammar, not a configuration. The transport maps it
to the broker grammar (NATS keeps `.`, MQTT uses `/`). There is no `separator` parameter and no
`defaultTopicPathSeparator`.

### 2. Type is local, not part of the address

`EventKey<T>` pairs the address with the local `Type`. The type is captured without a name
string:

```dart
Type typeOf<T>() => T;

final class EventKey<T> {
  EventKey(String address)
      : address = EventAddress(address), type = typeOf<T>();

  final EventAddress address;
  final Type type;               // local identity only; never on the wire
  bool accepts(Object? data) => data is T;
}
```

`EventPatternKey<T>` is the same for a pattern address. `EventKey` is exact and rejects wildcard
tokens; `EventPatternKey` accepts and validates them. A sealed `EventSelector<T>` base can unify
the two for `subscribeEvents`/`listen`; `fire`/`request` accept only `EventKey`.

`Type` equality survives minification and obfuscation; `Type.toString()` does not. No code may
use `'$T'`, `Type.toString()`, `runtimeType.toString()` or a user-class name string for identity,
routing, registry lookup, the wire or persistence. `Type` keys and `data is T` checks are the
supported mechanisms. The empirical evidence is in §7 of the analysis document.

### 3. `Topic` is removed; `EventAddress` and `EventPattern` replace it

`Topic` currently means "type + paths". Keeping the name with a different meaning would preserve
the confusion that caused this ADR. The replacement:

| Current | New |
|---|---|
| `Topic` | `EventAddress` (exact) / `EventPattern` (pattern) |
| `Topic.type` | removed |
| `Topic.create<T>(paths:)` | `EventKey<T>(address)` / `EventPatternKey<T>(pattern)` |
| `Topic.fromParametr` | `EventKey.forType(type, address)` for dynamic types; otherwise removed |
| `Topic.parse` | `EventAddress.parse` / `EventPattern.parse` |
| `TopicPattern` | `EventPattern` |
| `TopicImpl` | `EventAddress` implementation |
| `_normalizeTypeToken` | removed |
| `TopicSubjectMapper` | `EventAddressMapper` (wire grammar only) |
| `TopicRegistryIndex` | `EventCodecRegistry` (typed codecs, no type-token fallback) |
| `typeTags` / `wireTypes` | removed |

`EventAddress` equality is by the address string. `EventAddress.tokens` is a derived getter used
for pattern matching and diagnostics; it is not a constructor parameter or a call argument.

### 4. `paths` and `separator` leave the public API

Every method takes a key or selector, not a `paths` list and a `separator`:

```dart
bool fire<T>(EventKey<T> key, T data, {arguments, correlationId});
Future<dynamic> request<T>(EventKey<T> key, T data, {timeout, cancelToken, ...});
EventSubscription<T> subscribeEvents<T>(EventSelector<T> selector, {...});
Stream<T> listen<T>(EventSelector<T> selector);
T? currentData<T>(EventKey<T> key);
bool haveListener<T>(EventSelector<T> selector);
bool haveHandler<T>(EventSelector<T> selector);
```

`EventBus`, `EventBusIsolate`, `WorkerPool` and `Layers` no longer accept a separator.
`EventDTO` no longer accepts `paths`/`separator`; it carries the key. `EventBusError.topic`
becomes `EventBusError.address`.

`eventPaths` in FSM/Scope/Command is replaced by a key; a convenience `EventKey<T>.fromTokens`
(which joins with the fixed grammar separator) may exist for dynamically built addresses.

### 5. Node identity is `(address, Type)`

Exact and pattern nodes are stored per address bucket and type:

```dart
Map<EventAddress, Map<Type, EventNode>> _eventsMap;
Map<EventAddress, Map<Type, EventNode>> _patternMap;
```

`EventNode<T>` stays typed. `EventNodeImp.deliver` already rejects data that is not `T`; that
becomes the type filter. `currentData` is per key, not per address.

Dispatch to a concrete address visits **every** typed node in the address bucket; each node
accepts or rejects by `data is T`. This gives subtype delivery for free: a node keyed
`EventKey<DomainEvent>('orders')` accepts an `OrderPlaced` value. Pattern buckets are visited the
same way for matching addresses. Handlers are resolved on the address (including patterns) and
filtered by `acceptsData(dto.data)`; a request can therefore be answered by a handler whose key
type is a supertype of the payload.

`haveListener`/`haveHandler` are exact-selector queries. Address-level helpers
(`haveListenerAt(address)`, `haveHandlerAt(address)`) are provided when the caller wants "any
type on this address". `currentData` is exact-key; a supertype key stores values it accepted.

### 6. Transport: the address is the subject; codecs are typed

The wire subject is `key.address` (or a serializer override), with the adapter grammar applied.
There is no type token and no `typeTags`/`wireTypes`.

* Outbound: the codec for the key/address encodes the DTO; the node whose key **equals** the DTO
  key publishes. A supertype node or a pattern node delivers locally and never publishes — this
  also fixes the old duplicate-publication defect.
* Inbound: the subject gives the address; the codec registry resolves an exact address codec or
  the most specific address-pattern codec. The codec returns an `EventDTO` with a key; the
  transport dispatches to the matching typed nodes. One broker subscription per address (or
  pattern) is shared by all its type nodes.
* A heterogeneous address (several keys with the same address) is a codec contract: the payload
  carries a user-defined stable discriminator (for example `kind`) so the codec can choose the
  key. A single-type address needs no discriminator.
* The codec registry is keyed by `EventKey`/`EventAddress`/`EventPattern` and `Type`; it never
  looks up by a Dart type-name string.

### 7. Patterns

`EventPattern` matches address tokens only; it never compares types. A pattern node is typed by
its `EventPatternKey<T>`; delivery filters by `data is T`. `fire`/`request` reject pattern keys;
`subscribeEvents`/`listen` accept an `EventSelector` (exact or pattern).

### 8. Isolates, pools and layers

Interest is exchanged by address. Delivery filters by type locally, so a remote listener of a
different type rejects the event. `fire` acceptance on a bridge is address-level and therefore
coarser than today; precise type interest can be added later by exchanging a local type label
(a build-local value, never persisted). `WorkerPool` and `Layers` use the same key API and have no
separator.

### 9. FSM, Scope and Command

`FSM.addFSMTransition<E>` takes an `EventKey<E>`/`EventPatternKey<E>` (or builds one from tokens).
The transition lookup is by address, then by `data is E`; exact key first, then supertypes in
registration order. `Scope.initScope` and `Command` take an `EventKey<T>`.

### 10. Observability and errors

The default metric key is the address. If per-type series are required, a user-supplied stable
label (not `Type.toString()`) is added to the key or supplied by `metricKeyBuilder`. Error
envelopes carry the address, not the old `topic` string.

## Consequences

**Breaking, and intentionally so.** Every call site, example and test that passed `paths` or a
`separator` changes. Since the package is unpublished, there is no deprecation layer and no dual
API: the old `Topic` model is removed rather than kept beside the new one.

**Wins:** a stable wire address chosen by the user; no type-name dependence; obfuscation-safe
identity (`Type` keys/`is` checks); subtype delivery; explicit versioning by address
(`order_placed_v1`); one codec contract per address; the duplicate-publish problem disappears
because only the exact key publishes; `typeTags`/`wireTypes` and the separator configuration
disappear.

**Costs:** addresses are strings, so a typo is not compile-checked — centralize keys as static
final constants and validate at construction; tokens cannot contain the grammar separator; a
heterogeneous address requires a payload discriminator or a single-type address; the isolate
`fire` acceptance is coarser; `haveListener`/`haveHandler` are exact-key unless the address-level
helper is used.

**Not in this ADR:** a schema registry or mandatory event versioning. The address can carry a
version (`order_placed_v1`), and the codec owns the payload schema. A schema product, if needed,
is built above this model.

## Migration shape

```dart
// before
bus.fire<OrderPlaced>(order, paths: ['orders'], separator: '.');
bus.subscribeEvents<OrderPlaced>(paths: ['orders', '*'], onEvent: ...);

// after
final orderPlaced = EventKey<OrderPlaced>('orders.placed');
final anyOrder = EventPatternKey<OrderPlaced>('orders.*');

bus.fire(orderPlaced, order);
bus.subscribeEvents(anyOrder, onEvent: ...);
```

* Transport: replace `serializers`/`deserializers`/`typeTags` with typed codecs keyed by
  address; the subject is the address. A version goes into the address (`order_placed_v1`).
* `EventDTO.topic` -> `dto.key` (`dto.key.address` for the string).
* `EventBusError.topic` -> `EventBusError.address`.
* FSM/Scope/Command: replace `eventPaths`/`paths` with keys.
* Docs and examples: replace the type-as-address explanation with address/key; rewrite
  `doc/01`, `doc/02`, `doc/04`, `doc/05`, `doc/06`, `doc/07`, `doc/08`–`doc/10`, `doc/15`,
  `README.md`, `CHANGELOG.md`.

## Alternatives considered

1. **Keep type-as-address.** Rejected for wire stability and obfuscation; proven by the local
   `dart compile js -O2` check.
2. **V1: type only when `paths` is empty.** Rejected: it does not remove type dependence for
   pathless events, creates path collisions, and cannot be represented without changing the
   `Topic` abstraction and node identity.
3. **V2: mandatory paths, type ignored.** Close to E, but E adds a declared key object, so paths
   are not repeated on every call, and it removes the separator from the API. E is V2 with a
   value object and a fixed grammar.
4. **A: keep the local model, add stable wire names (`typeTags`/`wireTypes`).** Rejected as the
   final direction: it leaves the type in the local address and does not fix the string-keyed
   codec registries; the obfuscation check showed that `typeTags` alone publishes zero for user
   classes.
5. **Hybrid: keep `Topic` and add `EventKey` beside it.** Rejected: two identities, duplicate
   node stores and docs; the package is unpublished, so one clean break is cheaper.
6. **`Topic<T>` as the key.** Rejected: generic values in `Map`/DTO, pattern selectors without a
   concrete `T`, dynamic transport types, and the old "type in topic" mental model.

## Implementation stages

1. **Core:** `EventAddress`/`EventPattern`, `EventKey`/`EventPatternKey`, `EventSelector`,
   `EventDTO.key`, node buckets `(address, Type)`, dispatch, patterns, `EventBus` API,
   removal/dispose, errors. Tests for exact, pattern, subtype, `currentData`, `have*`.
2. **Patterns package:** FSM/Scope/Command keys; tests; examples.
3. **Transport:** `EventAddressMapper`, `EventCodec` + registry, one subscription per address,
   inbound dispatch, exact-key publish rule, adapter factories; NATS/MQTT tests, including the
   obfuscation build check.
4. **Isolate/pool/layers:** address interest, key API, no separator, worker tests.
5. **Observability/errors:** address metric keys, error envelope, dashboards/docs.
6. **Docs/examples/migration:** rewrite the address model, update `doc/decisions/README.md`,
   add the migration section to `doc/15`, update `CHANGELOG.md`.

Estimate: 8–12 human-days for implementation and tests, plus documentation. The work is
deliberately staged so the core can be reviewed before the transport is rewritten.

## Verification

* Unit tests for address/key equality, pattern matching, subtype delivery, per-key `currentData`,
  exact-key-only publication.
* Transport tests for address-only subjects, typed codecs, heterogeneous addresses with a
  discriminator, and pattern subscriptions.
* The `dart compile js -O2` build check: user-class keys must resolve codecs and publish; no
  `'$T'`/`Type.toString()` lookup may be on the path.
* `dart analyze` and the full suite across core, patterns, transport, NATS and MQTT.
