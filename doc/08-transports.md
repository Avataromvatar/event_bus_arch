# 08. Transports: NATS, Redis, NanoMQ

[← 07. What was fixed](07-caveats.md) · [Contents](README.md)

This document is the analysis that preceded the transport work. The NATS part is now
implemented in [`packages/event_bus_nats`](../packages/event_bus_nats) and described in
[09-event-bus-nats.md](09-event-bus-nats.md). The analysis below remains useful for the MQTT and
Redis options and for the reasoning behind the broker boundary.

---

## 1. The question, restated precisely

Three different asks are usually mixed into one:

1. **Run the bus over a broker** — a message published on one process is delivered to a handler
   in another process, on another machine.
2. **Replace the URI address with a broker-style subject** — `event://all.string/p` becomes
   something like `orders.created.eu`.
3. **Support three specific brokers** — NATS, Redis, NanoMQ (MQTT).

These have very different costs. (1) is additive. (2) is a breaking change to the single most
load-bearing type in the package. (3) is mostly a packaging question.

They are also not independent: the broker you pick constrains what an address may legally look
like, so (2) cannot be designed before (3) is settled.

---

## 2. What `Topic` is today — and the three jobs it does

`Topic` is one string doing three unrelated jobs:

| Job | Who consumes it | What it needs |
|---|---|---|
| **Local routing key** | `EventBus._eventsMap`, `FSM._map` | cheap `==`/`hashCode`, stable inside one process |
| **Wire address** | `EventBusIsolate` today, transports later | stable across processes, versions and builds |
| **Decode discriminator** | `EventDTO.fromJson(..., dataConverter:)` | tells the receiver which class to construct |

Today all three are the same value, `event://all.orderplaced/in`. That coincidence is what makes
the package pleasant to use locally and what will break first over a network.

The third job is the one that is easy to overlook. `EventBusIsolate` never has to solve it —
both sides are the same Dart program running the same code, so an `EventDTO` with a live object
in `data` can be sent through a `SendPort`. A broker has no such shortcut: it carries bytes.
**A broker subject contains no type information at all.** Whatever replaces `Topic` must answer
"which class do I construct from these bytes" explicitly, because nothing in
`orders.created.eu` says `OrderPlaced`.

`EventDTO.toJson` already exposes the seam for this:

```dart
Map<String, dynamic> toJson() => {'topic': topic.fullTopic, 'data': data};
// the counterpart already takes a callback:
EventDTO.fromJson(json, dataConverter: (topic, data) => ...)
```

That is a good design decision from 2.3.0 and it is the hook a transport should use.

---

## 3. What the brokers actually provide

"Топики как в этих системах" is not one grammar — it is three. They agree only on the vague
shape "hierarchical string, delimited, case-sensitive, wildcards in subscriptions".

| | NATS | MQTT (NanoMQ) | Redis Pub/Sub | Redis Streams |
|---|---|---|---|---|
| Separator | `.` | `/` | none (opaque channel name) | n/a (key) |
| Single-token wildcard | `*` | `+` | glob `?`, `*` (in `PSUBSCRIBE`) | n/a |
| Rest wildcard | `>` (final token only) | `#` (final level only) | glob `*` | n/a |
| Reserved in the name | `.` `*` `>` whitespace, `$`-prefix | `/` `+` `#` are structural | none | none |
| Metadata with the message | headers (NATS 2.2+) | user properties (MQTT 5 only) | **none** | fields in the entry |
| Native request/reply | yes (`_INBOX.…` reply subject) | MQTT 5 response topic + correlation data | **no** | no |
| Persistence | JetStream (experimental in the Dart client) | retained messages, broker-dependent | none | yes, with `XACK` |
| Delivery model | push | push | push, fire-and-forget | **pull** (`XREADGROUP`) |
| Client maturity in Dart | `dart_nats` 1.6.1 — 39 likes, ~5k downloads, MIT, updated recently; JetStream flagged experimental | `mqtt_client` 10.13.0 / `mqtt5_client` 5.1.0 — 550 likes, ~87k downloads, verified publisher | `redis` 4.1.0 — 146 likes, ~277k downloads | same client; Streams are not documented, raw commands only |
| Flutter Web | via WebSocket | via WebSocket | **not supported** (TCP only) | not supported |

Read the table as a fit ranking for *this* bus:

* **NATS is the closest fit.** A dot-separated subject maps almost one-to-one onto the existing
  `target.type.path`, it has real request/reply (which the `Completer` back channel needs),
  headers (which `arguments` needs), and wildcards. Its Dart client is the youngest of the three.
* **MQTT is the safest client and a decent fit.** MQTT 5 supplies response topic, correlation
  data and user properties — everything the bus needs. Retained messages map neatly onto
  `isModelBus` / `lastData`. Downside: `/` is structural, so the current `path` values
  (`/origin`) produce a leading empty level.
* **Redis Pub/Sub is the poorest fit.** No metadata, no request/reply, no persistence: a
  `Completer` cannot be expressed at all without inventing a private reply channel, and
  `arguments`/`fragment` have nowhere to live. Redis Streams is durable but is a *pull* model,
  which fights a push-based bus and drags in consumer groups, `XACK` and pending-entry handling.

Ordering of effort should follow what you actually deploy, but if the choice is open, NATS first
for fit, MQTT first for client stability.

---

## 4. The address problem

### 4.1 `T.runtimeType` cannot be a wire address

This is the single most serious finding. `Topic.create<T>()` builds the address from
`T.runtimeType`, and `EventTopicImpl.create` does `'${type ?? nameType}'.replaceAll("?", "^")`.
The consequences on the wire are worse than they look locally:

* **Flutter Web release builds minify type names by default.** `runtimeType.toString()` returns
  `minified:Ah`. This is not opt-in — dart2js minification is on for release, and the Dart team's
  guidance is explicit that `runtimeType.toString()` must not be used for control flow or name
  comparison. The same applies to `dart compile wasm` with `-O4`.
* **AOT `--obfuscate`** renames types the same way, by design.
* **Renaming a Dart class silently changes the wire address.** No compile error, no test failure
  in-process — just messages that stop arriving between two deployed services.
* **Case is lowercased.** `OrderPlaced` → `orderplaced`, which collides with `Orderplaced`.
* **Generics are percent-encoded.** `List<int>` → `list%3Cint%3E`. A non-Dart consumer — a Go or
  Python service on the same broker — can do nothing sensible with that token.

Locally none of this matters: one process, one build, one type table. Across a network every one
of them becomes a defect that only appears in a release build of a deployed system. This alone
justifies an explicit, string-literal type tag on the wire, whatever happens to `Topic`.

### 4.2 `arguments` and `fragment`

`Topic` equality ignores `fragment` and `arguments` — they are routing *payload*, visible to the
handler via `dto.topic.arguments`, but they do not select a node. On the wire they must go
somewhere, and the options differ per broker: NATS headers, MQTT user properties, Redis — the
payload envelope, because Redis Pub/Sub has no metadata at all.

### 4.3 Reserved characters collide with the current grammar

* `path` values in the current API begin with `/`. Under MQTT that creates an empty leading level.
* `target`/`type` must not contain a dot (`assert` in `EventTopicImpl.create`). Under NATS the dot
  *is* the separator, so a dotted `path` silently becomes extra tokens — a different subject, a
  different set of subscribers, and a wildcard subscription that now catches the wrong events.
* `*`, `>`, `+`, `#` must never appear in a published subject. Any value that reaches a subject
  from application data has to be sanitised, not merely asserted in debug mode.
* `$`-prefixed subjects are reserved by NATS (`$SYS`, `$JS`, `$KV`) and by MQTT (`$SYS`).

### 4.4 Wildcards have no local counterpart

Locally a subscription is an exact `Map` key. Brokers match patterns. A pattern subscription means
one broker subscription serving N concrete subjects, each of which must be resolved back to a
node — and the bus has no pattern-matching layer. A `>` subscription also catches events the local
design would have treated as unrelated topics.

### 4.5 Namespacing

Two applications on one broker share one subject space. A tenant/application prefix
(`acme.shop.orders.created`) is needed both to avoid collisions and because broker ACLs are
usually written against a subject prefix. This prefix is not part of the local topic and has to
be added and stripped at the boundary.

---

## 5. Where the code should live

Three options.

### A. Separate repositories, one package per broker

`event_bus_nats`, `event_bus_mqtt`, `event_bus_redis`, each in its own repo.

* **For:** full isolation; independent CI and release cadence.
* **Against:** the core's internal contract cannot be changed without touching N repos in
  lockstep; a shared conformance suite has nowhere to live; every core change risks breaking a
  transport that CI in this repo cannot see.

### B. `packages/` inside this repository, one published package per broker

```
event_bus_arch/                     ← core, zero broker dependencies
├── pubspec.yaml                    ← workspace root
├── lib/
├── packages/
│   ├── event_bus_transport/        ← Transport contract + fake transport (no broker deps)
│   ├── event_bus_nats/
│   ├── event_bus_mqtt/
│   └── event_bus_redis/
```

* **For:** the core contract and all transports change in one PR and one CI run; a single shared
  conformance suite proves every transport honours the same guarantees; a user installs only the
  broker they use — which matters, because Flutter Web cannot open a TCP socket to Redis or NATS
  and the `redis` package does not support the web at all.
* **Against:** a package matrix in CI; more pubspec files.

### C. Everything in the core package

Rejected. `event_bus_arch` currently depends on `intl`, `async`, `rxdart` only. Adding
`mqtt_client`, `redis` and `dart_nats` would pull all three — plus their transitive dependencies —
into every consumer, including Flutter Web applications for which two of them cannot compile. It
would also end the "no code generation, no broker lock-in" property the README sells.

**Recommendation: B.** Separate *published* packages in a workspace inside this repository.

**Status (v3).** `packages/event_bus_transport` holds the broker-agnostic contract and the shared
bus/connection layer; `packages/event_bus_nats` and `packages/event_bus_mqtt` are its adapters.
Redis and MQTT 3.1.1 are out of scope. The sketches below are the analysis that led to the
implementation; the implemented contracts are described in
[09-event-bus-nats.md](09-event-bus-nats.md), [10-event-bus-mqtt.md](10-event-bus-mqtt.md) and the
package READMEs.

Dart supports this natively since 3.6 via [pub workspaces](https://dart.dev/tools/pub/workspaces):
a `workspace:` list in the root pubspec, `resolution: workspace` in each member, one
`dart pub get`, one shared `pubspec.lock`. Melos 7 is optional on top. Note the cost: the SDK
floor moves from `>=3.0.0` to `^3.6.0`.

---

## 6. Recommended architecture

Keep `Topic` as the **local** routing key — that is genuinely its job, and replacing it is the
expensive part of ask (2). Introduce three new pieces instead, and let the broker-native grammar
live at the boundary.

```dart
/// One message as it exists on the wire. No Dart objects except bytes.
class TransportMessage {
  final String subject;                  // broker-native address
  final String typeTag;                  // stable string literal, NOT runtimeType
  final Uint8List payload;
  final Map<String, String> headers;     // arguments; NATS headers / MQTT v5 props / payload
  final String? replyTo;                 // correlation, if the broker has one
  final String? correlationId;
}

abstract class EventTransport {
  String get scheme;                     // 'nats' | 'mqtt' | 'redis'
  Future<void> connect();
  Future<void> dispose();

  Stream<TransportMessage> get incoming;
  Stream<TransportStatus> get status;    // connected / reconnecting / lost
  Future<void> publish(TransportMessage message);
}

/// Explicit type tag <-> Dart class. The registry is the price of no codegen.
abstract class EventCodec {
  String tagOf(Type type);
  TransportMessage encode(EventDTO dto);
  EventDTO decode(TransportMessage message);
}

/// Bridges a transport into an ordinary EventBus.
class BusTransportLink { ... }
```

Three points make this the cheap version of the change:

1. **`Topic` is untouched.** Existing code, all 83 tests, the isolate bridge and the docs keep
   working. The broker grammar appears in `subject`, which is derived from `Topic` by a
   configurable mapper and parsed back on the way in.
2. **The type tag is an explicit string**, registered once per event class. This kills the
   minification, obfuscation, case-collision and generics problems in one move — and it is
   required regardless of which option is chosen for `Topic`.
3. **Request/reply already has a proven implementation in this repo.** `_IsolateLink`
   (`event_bus_isolate.dart:73-174`) solves exactly the same problem: id correlation, a pending
   map, an error reply, `failAllPending` so `await send(...)` never hangs. A transport needs the
   same machine with a broker in place of the `SendPort`. Reuse the design; do not invent a
   second one.

The broker-native grammar can then be offered *in addition* — for example a subject layout that
keeps the decode tag as an explicit token:

```text
NATS :  acme.shop.order.placed.<target>.<path...>
MQTT :  acme/shop/order/placed/<target>/<path...>
```

If the goal is that a non-Dart service on the same broker can route the events sensibly, this
layout is what makes it possible — the type is a readable token rather than a percent-encoded
runtime type name.

---

## 7. Pitfalls

### A. Addressing

1. **Three different grammars, not one.** A single "broker-style topic" cannot be designed
   without picking a broker first; the delimiter and the wildcard characters are mutually
   incompatible.
2. **`T.runtimeType` as a wire address is not stable** — see §4.1. Minified on Flutter Web
   release by default, obfuscated on AOT with `--obfuscate`, silently changed by renaming a class.
3. **`arguments`/`fragment` have nowhere to live on Redis Pub/Sub.** On NATS and MQTT 5 they map
   to headers / user properties, but only in MQTT 5 — MQTT 3.1.1 has no equivalent.
4. **Reserved characters.** `*`, `>`, `+`, `#`, `/`, `.`, and the `$` prefix all mean something to
   one broker or another. The current `path` starts with `/` (empty level under MQTT), and the
   only guard against a dotted `target` is a debug-mode `assert`.
5. **Wildcard subscriptions break the exact-match node model.** One pattern subscription maps to
   N concrete subjects, each needing a resolved node — and it will match events the local design
   considered unrelated.
6. **No tenant namespace.** Subjects are global per broker/account; collisions and ACL mistakes
   are silent.
7. **`Topic` equality is `other is EventTopicImpl`.** Any alternative `Topic` implementation never
   compares equal, so introducing a second address type into `_eventsMap` will silently fail to
   find nodes.

### B. Request/reply (the `Completer`)

8. **`Completer` does not serialise.** Correlation id plus a pending map is mandatory — the
   `_IsolateLink` pattern.
9. **A deadline is mandatory.** Locally an answer is guaranteed (fixes #6 and #12 in
   [07-caveats.md](07-caveats.md)), so `await send(...)` cannot hang. Across a network the peer
   can vanish and a `Future` without a timeout hangs forever. Today only `ping` has a timeout.
10. **"Is anyone listening?" is unanswerable remotely.** Locally, `send` to an unknown topic
    returns `null` and `haveListener`/`haveHandler` are exact. Over a broker the sender usually
    cannot know (`NatsNoRespondersException` and `PUBSUB NUMSUB` are partial exceptions).
11. **The `send`-as-sync-point guarantee cannot hold.** Documented in
    [07-caveats.md, item 3](07-caveats.md#3-delivery-to-listeners-is-asynchronous) and in the
    README: by the time `await send(...)` returns, listeners have received the value. Through a
    broker this is impossible. Code relying on it breaks silently.

### C. Delivery and reliability

12. **Delivery models differ.** Core NATS is at-most-once; MQTT QoS 0/1/2; Redis Pub/Sub is
    at-most-once fire-and-forget; JetStream is at-least-once. At-least-once means duplicates, which
    means handlers must be idempotent — a concept the bus does not currently have.
13. **Ordering is not preserved.** The local bus is strictly ordered per node, and `lastData` and
    the FSM both rely on that. A broker with several consumers or partitions does not guarantee it.
14. **No backpressure policy.** `StreamController` is unbounded locally; a broker is slower than
    the producer and the queue grows in memory. The policy — drop, block, or fail — has to be
    chosen deliberately.
15. **Reconnection has to rebuild subscriptions, and pending requests must be failed.** Failing is
    the honest default; retrying requires idempotency, which item 12 says you may not have.
16. **Message size limits.** The NATS server default is typically 1 MiB and configurable; MQTT
    limits are broker-dependent. An event that passes every test locally fails on publish in
    production.
17. **`lastData` becomes broker state.** Retained messages (MQTT) or a JetStream KV entry hold the
    value, and the broker — not the application — now owns it.

### D. Serialisation

18. **Only bytes cross.** Every event class needs an explicit encoder and decoder and a registry
    entry. The package's "no code generation" property turns into a manual registry that must be
    kept in sync on both sides. A forgotten registration is a silent drop or a runtime error.
19. **Errors do not serialise.** `EventBusException` carries a `StackTrace`; stack traces are not
    portable and leak internals to the broker and to other tenants. An error envelope is needed:
    a stable code, a message, and whether it is retryable.
20. **Binary data.** `toJson` returns `data` as is, so `Uint8List` cannot go through JSON. Large or
    binary payloads need a separate representation.

### E. Lifecycle and resources

21. **Connection ownership.** Two buses sharing one connection means disposing one kills the
    other. A shared connection manager with reference counting is needed, or one connection per
    bus declared explicitly.
22. **Cancelling the last local listener should unsubscribe from the broker.** `removeNode` runs on
    `doOnCancel`; without a matching broker unsubscribe, traffic keeps arriving and is dropped.
23. **Sockets cannot cross an isolate boundary.** If the transport lives on the main isolate,
    `EventBusIsolate` workers cannot use it directly — they need a `SendPort`-based proxy, or the
    transport must be confined to one isolate. This is the same constraint that makes
    `onInit`/`fnInitLayer` have to be top-level functions.
24. **Platform support differs per transport.** Flutter Web cannot open raw TCP: NATS and MQTT work
    over WebSocket, the `redis` package does not support the web at all. Each transport package
    therefore has its own platform constraints, and the core must not assume otherwise.

### F. Public API and compatibility

25. **Replacing the `Topic` grammar is a breaking change to the whole surface.**
    `Topic.create<T>()` is called from eight `EventBus` methods, `Command`, `Scope`, `FSM`
    (`_FSM._map` is `Map<Topic, …>`) and `EventBusIsolate`. It also invalidates seven documents
    and the examples. This is a 3.0 release, not a feature.
26. **`scheme` is already part of the routing key and is always `'event'`.** It is a ready-made
    slot for the transport name (`nats://…`), but note the consequence: if the scheme is part of
    the key, a local and a remote topic with the same path are different nodes. That is either the
    feature you want or a trap — decide explicitly.

### G. Observability and testing

27. **`allEventStream` and `EventBusLogger` see only the local half.** End-to-end tracing needs a
    correlation id that survives the broker hop.
28. **The existing tests are all in-process.** Transports need either a docker harness or a fake
    transport for unit tests, and the conformance suite proving "every transport behaves the same"
    has to be shared between them.

---

## 8. Open questions

1. Is a breaking change to the `Topic` grammar acceptable (3.0), or must 2.x addressing stay
   intact and the broker grammar live only at the boundary?
2. Which broker is actually being deployed first? The client maturity ranking (MQTT) and the
   semantic fit ranking (NATS) point in different directions.
3. Must a non-Dart service consume the same subjects? If yes, the type tag has to be a readable
   token and percent-encoded runtime type names are off the table.
4. Which of `haveListener` / `haveHandler` / `send`-returns-`null` / `send`-as-sync-point are
   contractual and must be preserved, and which may simply be documented as local-only?
5. Is at-least-once delivery required? If yes, idempotency and dedup become part of the handler
   contract and belong in the core, not in a transport package.

---

## What next

* [09-event-bus-nats.md](09-event-bus-nats.md) — the implemented NATS transport and its usage.
* [01-architecture.md](01-architecture.md) — the current address model in full.
* [03-isolate-and-layers.md](03-isolate-and-layers.md) — the existing boundary-crossing design
  that a transport should mirror.
* [07-caveats.md](07-caveats.md) — the guarantees a transport cannot keep.
