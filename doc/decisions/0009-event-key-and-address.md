# ADR-0009: Explicit event address and local type (`EventKey`)

- Status: Accepted
- Date: 2026-11-24
- Current in: 4.1.0

## Context

The 3.x model encoded the Dart type in the topic string (`OrderPlaced.orders.placed`). That makes
the type a wire name and a routing token. It breaks under `dart2js` minification, makes the address
depend on class names, prevents two payload types from sharing an address, and forces the bus to
strip or reconstruct a type prefix in every transport.

The alternatives were:

- keep type-as-address and add a type tag for the wire;
- use a channel-first model (a typed channel object);
- use an explicit application address plus a typed key.

Type-as-address also cannot answer “is this handler for an `Order`?” when the address is all the
bus knows. The package needs a model that is stable across obfuscation and usable as the
application's routing vocabulary.

## Decision

1. An event address is an application-owned, dot-separated string such as `orders.placed.v1`.
   The application chooses it; the bus does not derive it from a Dart type and never uses
   `Type.toString()`/`runtimeType` for routing or wire names.
2. `EventAddress` is the concrete address. The grammar is fixed: `.` separates tokens, `*` matches
   exactly one token, `>` matches one or more trailing tokens. Separators and wildcards are not
   per-call settings.
3. `EventKey<T>` binds an exact address to a compile-time payload type and compares by both address
   and type. `EventPatternKey<T>` binds a pattern to a type. `EventSelector<T>` is their sealed
   base. `fire` and `request` take an exact key; `listen`, `subscribe`, `currentData`, probes and
   removal accept a selector.
4. A node is identified by `(address, Type)`. `EventKey<Order>('orders')` and
   `EventKey<Invoice>('orders')` are different nodes with separate listeners, handlers and
   `currentData`. The type is a **local filter**, never a wire field; `EventNode.accepts(data)`
   is the payload check.
5. Transport subjects are the explicit addresses; codecs are keyed by address and typed by the
   payload. Only the exact-key node whose key equals the fired DTO key publishes; pattern and
   supertype nodes deliver locally and never publish a second copy. The wire carries no Dart type
   name.
6. Type identity uses `Type` captured with `Type _typeOf<T>() => T;`, not stringification. A
   `dart compile js -O2` check must prove that a user-class key still resolves its codec and
   publishes once while `Type.toString()` is minified.
7. Addresses are versionable by convention (`orders.placed.v1`). A schema change that cannot be
   read compatibly gets a new address rather than relying on the Dart type or a type tag.
8. `haveListener`/`haveHandler`/`haveAvailableHandler` cannot check subtype compatibility without
   data and are deprecated; `probeFire(key, data)` and `probeRequest(key, data)` are the data-aware
   queries. The deprecated methods remain until 5.0.
9. A single address may carry multiple payload types. “One address = one schema” is not adopted;
   it would remove the documented `(address, Type)` capability and does not solve supertype
   patterns or remote interest.

## Consequences

- Address naming is an application design decision; the bus cannot infer a type prefix for
  migration.
- The type is stripped from wire subjects, so 3.x topics are not wire-compatible with 4.x.
- Local and remote code must agree on the address and payload schema; the type is not available
  to the broker.
- Pattern matching is type-filtered locally, so a pattern listener for `DomainEvent` can accept
  `Order` and `Invoice` while a key for one type stays separate.
- Obfuscation-safe keys and explicit addresses make deployment and schema evolution predictable.

## Alternatives considered

- **Keep type-as-address with a wire type tag (3.x).** Rejected: obfuscation instability, class
  names as protocol, one type per address, and type/topic coupling in every transport.
- **Channel-first object without strings.** Rejected as the only model: it makes cross-process
  addresses and broker subject mapping awkward; the explicit string address is the stable seam.
- **One address = one schema.** Deferred, not adopted: it loses useful coexistence of types and
  does not address pattern/remote filtering.
- **Derive the address from a class name.** Rejected: minification, package renames and schema
  versioning make it unstable.
