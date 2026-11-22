# Event address model: type-as-address — analysis and verdict

Date: 2026-11-22
Scope: the review claim that building the event address from `'$T'` is a set of defects.
Repository: `event_bus_arch`, branch `version4`.

## Verdict in one paragraph

The **factual description is correct** (with two precision notes), but calling all of it
"defects" overstates the case. Three of the five points are deliberate, documented properties of
a type-keyed local bus; one is a scope limitation; one is a real production risk — but it is a
**default-policy risk**, not a missing capability, because `typeTags` already exists and is
opt-in. The one thing worth changing now is the wire contract: stable wire names should be the
explicit path for wire-facing buses, not a footnote. The local type-as-address model, the absence
of subtype routing and the absence of a schema registry should stay.

## 1. Fact check

| Claim | Verdict | Evidence |
|---|---|---|
| The address is built from `'$T'` — the static type argument | **Confirmed** | `lib/src/topic.dart:33-34`; the test `test/topic_dto_test.dart:35-43` pins `create<int>` vs `create<num>` and generic tokens |
| No subtype routing: `fire<Order>` does not reach `subscribe<Object>` | **Confirmed** | Different topic strings are different nodes by construction; documented in `doc/07-caveats.md:9-20`, `doc/01-architecture.md:119-120`, `README.md:130-148` |
| `fire<num>(1)` and `fire<int>(1)` are different topics | **Confirmed** | Same evidence; `num` and `int` are different type tokens |
| The route depends on the static type at the call site, not the runtime type | **Confirmed, with a precision note** | Dart infers `T` from the argument's static type; `DomainEvent e = OrderPlaced()` makes `fire(e)` use `DomainEvent`. If the call explicitly says `fire<OrderPlaced>(...)`, the route is `OrderPlaced` (the argument must be assignable to it) |
| Renaming a class/file breaks wire compatibility | **Class rename: confirmed. File rename: not true** | `'$T'` is the class/type name, not the file name; a file rename alone does not change it |
| Web release minification and AOT obfuscation change the token | **Confirmed as a documented risk** | `doc/08-transports.md:152-156`, `doc/09-event-bus-nats.md:255-257`, `doc/10-event-bus-mqtt.md:226-228` |
| The safe path (`typeTags`) is not the default | **Confirmed** | `typeTags` is an optional parameter in both factories (`event_bus_arch_nats_base.dart:32`, `event_bus_arch_mqtt_base.dart:30`); the mapper falls back to the raw type token (`topic_subject_mapper.dart:135`) |
| No schema, event version or contract registry | **Confirmed** | `EventDTOImpl` has `topic`, `data`, `arguments`, `correlationId` and no version (`lib/src/event_dto.dart:55-65`); serializers/deserializers are caller-supplied maps keyed by topic; no schema type exists in the transport packages |

Precision notes:

1. Renaming a **file** does not change the wire token; renaming the **class** (or a generic type
   argument) does. Local and anonymous types are the worst case.
2. The dependency is on the inferred or explicitly supplied **type argument of the call**, not
   merely on the variable's declaration. The practical consequence is the same, but the escape
   hatch — an explicit `fire<OrderPlaced>(...)` — is worth stating.

## 2. Why the model is this way

The type token is the routing key because it gives:

* compile-time checking: `subscribeEvents<Order>` and `fire<Order>` are structurally linked;
* zero configuration: no event-name registry to keep in sync;
* no reflection: Dart (especially Flutter/AOT) has no usable runtime type hierarchy;
* string topics that work identically locally, across an isolate and on a broker.

The alternatives have their own costs:

| Alternative | Why it is not free |
|---|---|
| Route by `data.runtimeType` | The same instability on web/AOT; loses compile-time safety; `dynamic` becomes a routing decision |
| Explicit event-name API (`fireNamed('order.placed', ...)`) | Breaks the type-safe ergonomics; every call site needs a string; still needs a registry to avoid typos |
| Subtype routing (`subscribe<Object>` catches `Order`) | Requires a runtime type hierarchy or an explicit hierarchy registry; Dart generics do not carry a walkable supertype graph; mirrors are not available in Flutter/AOT |
| Schema registry in the core | A product/platform concern, not a bus concern; it would couple the bus to a serialization framework |

## 3. Risk assessment

| Risk | Impact | Likelihood | Current mitigation | Verdict |
|---|---|---|---|---|
| Wire type token changes under minification/obfuscation or a class rename | High — remote producers/consumers stop matching | High if `typeTags` is omitted | `typeTags` exists but is opt-in; documented in three places | **Real risk; fix the default policy** |
| A value stored in a wider static type is routed to the wider topic | Medium — event silently goes to the wrong node | Medium; depends on call-site style | Documented caveat; explicit type argument works | Document/ergonomics, not a code defect |
| No subtype routing | Low — by design, documented | Low once read | Caveat #1 and README | Keep |
| No schema/version/registry | Medium for cross-team wire contracts | Depends on the product | Serializer owns the payload; `typeTags` can carry a versioned name | Scope limitation; add a convention, not a registry |

## 4. Recommendations

### R1 — Make stable wire names the explicit path (recommended now)

The current `typeTags` is a stringly-typed map keyed by the local type token. That has two
weaknesses:

* after a class rename, the **key** silently stops matching and the mapper falls back to the raw
  type name — exactly the failure mode the map was meant to prevent;
* it is optional, so the safe path depends on the caller reading the docs.

Proposed changes, in order of value:

1. **Typed wire tags.** Add `Map<Type, String>? wireTypes` (or change `typeTags` to this shape).
   Keys are type literals — `{OrderPlaced: 'order_placed_v1'}` — so a class rename is a compile
   error, not a silent wire change. Convert `'$Type'` to the type token internally.
2. **Require coverage at the wire-facing factories.** `EventBusNats`/`EventBusMqtt` are wire
   facing by definition. When `serializers`/`deserializers` are non-empty, every type token used
   by a registry key should have a wire tag; otherwise fail at construction with a clear error
   listing the missing types. Keep an explicit escape hatch (for tests and local fake
   connections), for example `allowUnstableTypeNames: true`, which preserves today's fallback and
   is documented as not for production.
3. **Examples and tests** use tags in every wire-facing sample; the generic
   `TransportEventBus`/`FakeTransportConnection` remain flexible for unit tests.

This preserves `typeTags` for dynamic/external topics (where a type literal is not available)
and adds a compile-safe path for the common case.

### R2 — Define a version convention

There is no event version today, and the core should not grow a schema registry. A minimal
convention is enough:

* put the version in the stable wire tag: `order_placed_v1`; the tag is a single token, so this
  is already valid;
* keep the previous deserializer registered while old producers exist;
* on a breaking change, add a new tag; never reuse an old one;
* if metadata must travel without changing routing, `arguments` already crosses isolates and
  transports — define a shared key such as `eventVersion` by convention.

Document this in `doc/08-transports.md` and the two adapter pages. A dedicated `eventVersion`
field on `EventDTO` is possible but should wait for a real consumer; it is not needed for routing.

### R3 — Turn the static-type trap into a documented recipe

The caveat exists, but the review's example deserves an explicit recipe:

```dart
DomainEvent event = OrderPlaced();

// Wrong: routes to DomainEvent.*
bus.fire(event);

// Right: routes to OrderPlaced.*
bus.fire<OrderPlaced>(event as OrderPlaced);
```

Also state that `Topic.fromParametr(type: ...)` exists for hand-built topics but is not exposed
through `fire`, and that runtime type names are not wire-safe. The docs already say most of this;
one focused example is enough.

### R4 — Do not add subtype routing or a schema registry to the core

Subtype routing needs an explicit hierarchy registration or reflection; both add cost and
surprise to every event. A schema registry is a separate product concern. Keep the core a
routing library; a schema/contract package can be built on top if the product needs it.

## 5. Decision and effort

| Item | Recommendation | Effort |
|---|---|---|
| R1 typed, required wire tags for NATS/MQTT | Do now (project is unpublished) | ~1 day with tests/docs |
| R2 version convention | Document now; no core field | 0.25 day |
| R3 static-type recipe | Document | 0.25 day |
| R4 subtype routing / schema registry | Do not do | — |

The only change that touches code is R1. It is compatible with the current transport seam: the
generic `TransportEventBus` keeps the flexible `Map<String, String>` path, while the NATS/MQTT
factories add the typed and required layer.

## Evidence index

* `lib/src/topic.dart:33-34` — `Topic.create<T>` builds the token from `'$T'`.
* `test/topic_dto_test.dart:35-43` — static type parameter, not runtime type; generic
  normalisation.
* `doc/07-caveats.md:9-20` — "The type is part of the address".
* `doc/01-architecture.md:98-120` — the address diagram and static-type rule.
* `README.md:130-148` — the same rule for users.
* `doc/08-transports.md:152-156` — wire-address stability and the `typeTags` advice.
* `doc/09-event-bus-nats.md:66-71, 255-257` — `typeTags` and the production warning.
* `doc/10-event-bus-mqtt.md:54-57, 226-228` — the same for MQTT.
* `packages/event_bus_arch_transport/lib/src/topic_subject_mapper.dart:135` — the raw-token
  fallback when no tag is configured.
* `packages/event_bus_arch_nats/lib/src/event_bus_arch_nats_base.dart:32`,
  `packages/event_bus_arch_mqtt/lib/src/event_bus_arch_mqtt_base.dart:30` — `typeTags` is an
  optional constructor parameter.
* `lib/src/event_dto.dart:55-65` — the DTO carries no event version.
