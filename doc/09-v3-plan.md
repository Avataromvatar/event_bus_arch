# 09. v3.0 plan: `send` + `fire`, and a NATS transport

[← 08. Transports](08-transports.md) · [Contents](README.md)

**Status: plan.** Nothing here exists in 2.3.0. It follows the analysis in
[08-transports.md](08-transports.md) and records the decisions taken after it.

---

## 1. Decisions taken

| # | Decision | Consequence |
|---|---|---|
| 1 | **NATS first, core only — no JetStream.** MQTT kept in mind. | At-most-once. `dart_nats` used as a plain pub/sub client, avoiding its experimental surface. |
| 2 | **`send` is kept as it is**, `Completer` and all. | All 83 tests, `EventBusIsolate`, `Scope`, `Command` and the isolate fixes stay untouched. §2.4. |
| 3 | **A new `fire` carries one-way events** and returns `bool`. | The only dispatch path that crosses a transport. §2. |
| 4 | **`target` is removed.** The address is `<type>.<path>`, with an explicit `subject` override. | Two address dimensions collapse into one, and the reverse-mapping ambiguity of [08-transports.md §4](08-transports.md) stops existing. §4. |
| 5 | **`Uri` is dropped from `Topic`.** `scheme` is dead; `arguments` and `fragment` move to the DTO. | `Topic` becomes a thin value object over a string. §4.5. |
| 6 | **Filters carry the codecs**, `serialize` and `deserialize` independently nullable. | A filter list declares what may cross, in which direction, and how it is encoded — and it is what makes decoding of a free-form `subject` possible. §5. |
| 7 | **Filters run inside the transport isolate.** | Decoding leaves the main thread entirely; the port carries objects rather than bytes. Requires a top-level filter builder. §6. |
| 8 | **Ordering and duplicates are delegated** to the client library. | Safe under core NATS *provided* one connection per pipe — risk R6. |
| 9 | **The NATS client runs in its own isolate**; sockets never leave it. | Native only: `Isolate.spawn` throws `UnsupportedError` on Flutter Web. §6. |

Decisions 2 and 3 shrink the change from a core rewrite into an addition — §2.4 says why that is
the right trade. Decisions 4 and 5 are the 3.0 break, and they pay for themselves: they delete a
concept rather than adding one.

---

## 2. `send` and `fire`

### 2.1 Naming: `fire`

Recommended: **`fire`**.

* It names the property that actually distinguishes it: *fire and forget*. A reader who knows the
  idiom knows no answer is coming, which is the whole point of the method.
* It contrasts with `send` on sight. `send` has a destination and may expect something back;
  `fire` is aimed at no one and expects nothing.
* It is the established verb in the Dart/Flutter event-bus ecosystem.

Runner-up: **`emit`**. Its argument is real — Node's `EventEmitter.emit()` already returns `true`
when there were listeners, which is almost exactly this contract. Against it: in Flutter, `emit` is
strongly associated with Cubit/BLoC, where `emit(state)` means "publish new state", not "dispatch
an event outward". The package would import a word that already means something else to its main
audience.

### 2.2 Signatures

```dart
/// Dispatches a one-way event. No answer comes back — there is no completer and
/// nothing to await.
///
/// true  — the event was taken: a local node accepted it, or a transport
///         accepted it for publishing
/// false — nothing took it, and retrying the same call may help once the
///         situation changes: no local node, no usable transport, no filter can
///         encode the type, or the transport is over its queue limit
///
/// Throws EventBusException when retrying cannot help: the address is not a
/// legal subject, the payload is over the size limit, or the bus is disposed.
bool fire<T>(T data, {String? subject, String? path, Map<String, String>? arguments});

/// Unchanged: keeps the Completer, and stays inside this program.
Future<dynamic>? send<T>(T data, {String? subject, String? path,
                                  Map<String, String>? arguments});
```

`subject` is not a `fire`-only parameter — it belongs on every bus method that takes an address
today (`send`, `setHandler`, `listen`, `subscribe`, `lastData`, `haveHandler`, `haveListener`),
replacing `target` and `path`. The word is the transport's own vocabulary for the thing, which is
why it wins over `topic`: the method already computes a topic, so a `topic:` parameter would name a
concept and its override the same way.

Three rules that must be explicit rather than implied:

* **`subject` wins, and `path` must then be null.** If both are passed, throw. Silent precedence
  between two ways of naming the same thing is how a call site ends up addressing something other
  than what it reads as.
* **`subject` is the local address; the prefix is the transport's job** (§4.4). An address that
  works locally keeps working when a transport appears under it.
* **`fire` never creates a completer**, and an event that arrives over a network carries
  `completer == null`. A handler written for `send` that calls `dto.completer?.complete(x)` — the
  pattern used throughout the package — quietly no-ops when reached by `fire`. No handler rewrite
  is needed.

### 2.3 What `send` does when a transport is attached

`send` stays exactly as it is *locally*, and gains one new failure mode:

| Situation | Today | v3 |
|---|---|---|
| Local node exists | delivered, completer works | **unchanged** |
| No local node, no transport | returns `null` | **unchanged** |
| No local node, **transport attached** | returns `null` | **throws**, naming `fire` |
| Inbound remote event | n/a | arrives with `completer == null` |

The third row cannot produce a false positive in any meaningful way: with no local node, nothing in
this program can complete the completer, so a `send` there could only ever return `null` or hang —
it was already useless. The change turns a silent `null` into a loud, actionable error. (On
`isModelBus: true` a node is always created, so this row does not apply.)

### 2.4 Why keeping `send` is the cheaper plan

Worth stating plainly, because an earlier draft of this plan argued the opposite.

Removing the `Completer` would have simplified `EventBusIsolate` — but that is the most-repaired
file in the package: fixes #2, #3, #19, #20 and #21 all live in it, five of twenty-one. It would
also have silently killed the error path for throwing handlers (fix #6) and broken
`Scope.initScope`, which awaits the result of its first send
([scope.dart:56](../lib/src/scope.dart#L56)).

Keeping `send` costs one thing instead: **two dispatch paths coexist, and users must know which one
to reach for.** That is a documentation problem with a one-line rule — reply wanted → `send`;
crossing a process boundary → `fire` — rather than a rewrite of the package's most fragile code.

### 2.5 Why not auto-mirror

An obvious temptation: when a transport is attached, make `send` also publish. **Rejected.** It
would deliver the same event twice to a process with both a local handler and a remote subscriber,
and it would leave the completer's meaning ambiguous — complete on local handling, on publish, or
on both? One method, one path across the boundary: `fire`.

---

## 3. The error path

With `send` kept, the error story is mostly intact: a throwing handler still reaches its sender
through the completer (fix #6). Only two cases have nowhere to report:

* a handler that throws while serving a **fired** event — nobody is waiting;
* a transport-level failure — connection lost, publish rejected, undecodable inbound message.

Both need a channel, so `errorStream` is still required, but scoped:

```dart
enum EventErrorSource { handler, filter, transport }

class EventBusError {
  final EventDTO? dto;          // null for transport-level failures
  final Object error;
  final StackTrace? stackTrace;
  final EventErrorSource source;
}

abstract class EventBus {
  Stream<EventBusError> get errorStream;
}
```

`EventBusLogger` subscribes to it, so the default experience is "you see it in the log".
`EventErrorSource.filter` covers the case that matters most: **an inbound message no filter can
decode must not be a silent drop** — that is how a filter table that drifted between two deployed
services becomes visible instead of looking like a quiet night.

Because filters run in the transport isolate (decision 7), a filter failure happens on the far side
of the port and must be **sent back explicitly** (§6).

---

## 4. The address

### 4.1 One dimension, not two

Today an address has two independent free-form parts, `target` and `path`:

```dart
Topic.create<T>(target: 'warehouse', path: '/in')   // event://warehouse.string/in
```

`target` is documented as "to whom" and `path` as "about what". But they are concatenated into the
same string, matched by the same exact-equality lookup, and [08-transports.md §4.2](08-transports.md)
showed what happens when both may contain a delimiter: **the composition is not invertible**.
`target: 'factory1.line3'` with `path: 'temp'` and `target: 'factory1'` with `path: 'line3.temp'`
produce the same address, so a receiver that rebuilds `target` and `path` picks one, and the handler
registered under the other is never found.

Removing `target` deletes the problem instead of legislating around it. One free-form part composes
invertibly with a fixed-position part in front of it:

```text
<type> . <path...>
   │         │
   │         └─ free-form, dots allowed, no parsing rule needed
   └─────────── one token, declared by the filters
```

Migration is mechanical and small: `target: 'warehouse', path: '/in'` becomes
`path: 'warehouse.in'`. `target:` appears 16 times in `lib/`, and only **5 times** across all tests
and examples. `Scope` and `Command` never had a `target` at all, so they are unaffected.

### 4.2 `subject`: the override

```dart
bus.fire<OrderPlaced>(order, path: 'warehouse.in');
// address: OrderPlaced.warehouse.in

bus.fire<OrderPlaced>(order, subject: 'legacy.deprecated.orders.placed');
// address: legacy.deprecated.orders.placed — verbatim
```

When `subject` is set it **is** the address: the local key, and (with the prefix) the NATS subject.
No composition, no parsing. This is the escape hatch that makes a fixed `<type>.<path>` shape
acceptable — arbitrary hierarchy is still reachable, just spelled out. And it is what makes §4.3
work.

### 4.3 Decoding is driven by the filters, not by the subject

An explicit `subject` is free-form, so the type cannot be recovered by counting tokens. It does not
need to be: **the filter table already says which type a subject carries** (§5). A filter is keyed
by type and declares a subject pattern, so:

* outbound — find the filter for `T`, substitute the concrete path, serialize;
* inbound — match the subject against the filter patterns; **the matching filter supplies the type
  and the deserializer**.

The type is therefore never discovered by parsing. That removes the "the type must sit at a fixed
position" constraint entirely, and with it the whole class of bugs where a subject of unexpected
shape is silently unrouteable.

It also means the **type token in the default `<type>.<path>` composition is a convention, not a
parsing contract**. It is worth keeping anyway, for three real reasons:

* `acme.OrderPlaced.>` subscribes to every `OrderPlaced` regardless of path — one obvious pattern;
* a non-Dart peer on the same broker can route on the subject;
* the subject is readable in broker logs and in `nats sub` output.

A user who sets an explicit `subject` without a type token opts out of all three. That must be
documented on the parameter, not discovered later.

**Type first, not last.** With filter-driven decoding this is no longer a correctness constraint,
only a subscription-expressiveness one. `>` matches one or more tokens and is legal only as the
final token; `*` matches exactly one. So with the type first, `acme.OrderPlaced.>` works at any path
depth, while with the type last the equivalent `acme.>.OrderPlaced` is illegal and
`acme.*.OrderPlaced` matches only a single-token path. Since the default is `<type>.<path>`, this
falls out for free.

### 4.4 The prefix

The tenant/application prefix (`acme.shop`) is **added by the transport on publish and stripped on
receive**. Local addresses stay clean, and an address that works locally keeps working when a
transport is attached beneath it. It also keeps two applications on one broker from colliding, and
gives broker ACLs a stable prefix to be written against.

Validation: an address that already begins with the prefix must be rejected at the boundary, not
silently doubled.

### 4.5 Dropping `Uri`

`scheme` is verifiably dead. Outside [topic.dart](../lib/src/topic.dart) it appears exactly once, in
a test asserting `topic.scheme == 'event'` — a constant carried through equality that distinguishes
nothing.

What else `Uri` currently provides, and where each goes:

| `Uri` feature | Today | v3 |
|---|---|---|
| `scheme` | always `'event'` | **removed** |
| percent-encoding of type names | `List<int>` → `list%3Cint%3E`, `String?` → `string%5E` | **removed** — the type is a declared token, not a runtime type name |
| `path` | `/in` | a plain dot-separated string, `in` |
| `arguments` (query) | on the `Topic` | **moves to `EventDTO`** |
| `fragment` | on the `Topic` | **moves to `EventDTO`** |

The last two are a correction rather than a loss: [01-architecture.md](01-architecture.md) already
states that `fragment` and `arguments` "are **routing payload, not part of the route**" — they are
excluded from `Topic` equality and never affect node selection. They were payload attached to an
address. Moving them to the DTO says so:

```dart
Map<String, String>? get arguments;   // on EventDTO, not on Topic
```

Handlers reading `dto.topic.arguments` change to `dto.arguments`. `01-architecture.md` names the old
path explicitly, so it is a documented API change.

### 4.6 `Topic` after all this

A value object over a string, with equality on that string:

```dart
class Topic {
  final String value;          // 'OrderPlaced.warehouse.in'
  const Topic(this.value);
  @override bool operator ==(Object other) => other is Topic && other.value == value;
  @override int get hashCode => value.hashCode;
}
```

That is what makes §4.3 work end to end: the subject that arrives **is** the key, so nothing is ever
reconstructed, and the ambiguity of §4.1 cannot be reached. `Topic.parse` becomes a constructor;
`Topic.create<T>()` stays for local-only use.

### 4.7 Rules

| Part | Rule | Why |
|---|---|---|
| `prefix` | 1+ tokens of `[A-Za-z0-9_-]` | tenant namespace; ACLs are written against it; added by the transport |
| `type` | one token, `[A-Za-z0-9_-]`, declared by the filters | a dot would shift every following token; this is what a wildcard subscription keys on |
| `path` | free-form, dots allowed, each token non-empty | §4.1 |
| any token | no whitespace, no `*`, no `>`, no `$`-prefix, no leading/trailing dot | NATS wildcards, reserved `$SYS`/`$JS`/`$KV`, and `..` is not a valid subject |
| total | ≤ 16 tokens, ≤ 256 chars | NATS's own sizing advice |
| payload | 1 MiB by default | the NATS server default; checked in the pipe so the failure is loud (R12) |

Validation happens at `fire` / `setHandler`, not at the socket: an address that is illegal *for the
broker* must never reach it. Today's only guard is a debug-mode `assert`
([topic.dart:128](../lib/src/topic.dart#L128)), which does nothing in a release build.

---

## 5. Filters

### 5.1 Shape

One ordered list declares routing, type, direction and encoding together, so they cannot drift
apart. Both codec functions are nullable, and the pair gives the direction:

```dart
class NatsFilter<T> {
  final String subject;      // <prefix>.<type>.<path>, NATS wildcards allowed
  final Uint8List Function(T value, EventDTO<T> dto)? serialize;
  final T Function(Uint8List bytes, String subject)? deserialize;
}

final nats = NatsPipe('nats://localhost:4222',
                      prefix: 'acme.shop',
                      filters: buildNatsFilters);   // top-level, see §6.2

List<NatsFilter> buildNatsFilters() => [
      // two-way
      NatsFilter<OrderPlaced>(
        subject: 'acme.shop.OrderPlaced.>',
        serialize: (v, dto) => utf8.encode(jsonEncode(v.toJson())),
        deserialize: (b, s) => OrderPlaced.fromJson(jsonDecode(utf8.decode(b))),
      ),
      // receive-only: consumed from the broker, never published by this process
      NatsFilter<PaymentSettled>(
        subject: 'acme.shop.PaymentSettled.>',
        deserialize: (b, s) => PaymentSettled.fromJson(jsonDecode(utf8.decode(b))),
      ),
      // send-only: published, never subscribed
      NatsFilter<AuditRecord>(
        subject: 'acme.shop.AuditRecord.>',
        serialize: (v, dto) => AuditRecord.encodeBinary(v),
      ),
    ];
```

| `serialize` | `deserialize` | Meaning | Publish table | Subscription list |
|---|---|---|---|---|
| set | set | two-way | ✓ | ✓ |
| null | set | **receive-only** — inbound from the broker only | — | ✓ |
| set | null | **send-only** — outbound only | ✓ | — |
| null | null | meaningless | **rejected at registration** | |

Direction is not just bookkeeping:

* **A send-only filter prevents self-echo.** NATS delivers a published message back to a
  subscription on the same connection if it matches, so a filter that both publishes and subscribes
  to one pattern receives its own events. Declaring `serialize` only is the way to say "I produce
  this, I do not consume it".
* **A receive-only filter lets a process consume events it never produces** — a gateway or bridge
  feeding the bus from outside.
* **The publish table and the subscription list are derived from the same declaration**, so they
  cannot disagree.

Other properties worth having from this shape:

* **The filter list is the subscription list.** The wrapper subscribes to exactly the declared
  patterns, so an undeclared subject is never received and never costs traffic.
* **Omitting a filter is default deny.** An internal event nobody registered simply does not leave
  the process. That is a safety property, not just tidiness.
* **Encoding is per filter**, so JSON, msgpack, protobuf and hand-rolled binary coexist, and
  `Uint8List` payloads make binary formats first-class rather than a workaround.
* **The filter table is what decodes a free-form `subject`** (§4.3). Filters and an explicit
  `subject` are a matched pair, not two independent additions.

`fire`'s "no filter can encode the type" is precisely: **no filter with a non-null `serialize`
covers this type**. A receive-only filter does not make its type publishable, and `fire` on such a
type still delivers locally — it just does not leave the process.

### 5.2 Decisions this shape needs

* **Overlap and precedence.** Two filters matching one subject is a misroute waiting to happen.
  **Recommend rejecting overlaps at registration** — the failure mode is otherwise a silent wrong
  codec. Checking declared patterns is cheap and happens once.
* **One filter per type.** Keying by type and allowing exactly one subject pattern per type removes
  most overlap by construction.
* **Catch-all filters.** A filter whose subject ends in `>` covers several types, so it cannot supply
  the type on its own. Allowed, but its `deserialize` receives the subject and must branch — and
  there is no type-based dispatch for it. Document, or forbid a trailing `>` where several types
  share a pattern.

---

## 6. Isolate layout

### 6.1 Where the work happens

```text
        main isolate                          transport isolate
┌──────────────────────────────┐         ┌────────────────────────────┐
│ EventBus                     │         │ dart_nats Client           │
│   _eventsMap                 │         │   Socket ◄──────────► NATS │
│   filter data:               │         │                            │
│     type → subject,          │ object  │  filters:                  │
│     direction                │────────►│   serialize   → bytes      │
│                              │◄────────│   deserialize ← bytes      │
│   handlers, listeners        │ object  │  SUB list from filters     │
└──────────────────────────────┘         └────────────────────────────┘
```

Filters run **in the transport isolate** (decision 7), so `jsonEncode`/`jsonDecode` and object
construction never touch the main isolate. Two consequences, one of which is a cost that should be
stated rather than discovered:

* **The receive path is a full win.** Bytes are decoded on the far side, and the main isolate
  receives a ready object. Decoding is usually the heavier direction — it allocates a whole object
  graph — so this is the larger half of the gain.
* **The send path is a partial win, and the honest number matters.** `SendPort.send()` serializes
  its message synchronously **on the sender's thread** before the receiving isolate ever sees it. So
  moving `serialize` into the isolate replaces "encode to JSON here" with "copy the object graph
  here". Both are O(payload) work on the main isolate. The win exists only because a VM message copy
  is cheaper than text encoding — not because the main isolate becomes free. It is worth measuring
  with a representative payload before claiming a figure.
* **A free bonus: bytes never cross a port.** Since serialization happens where the socket is,
  `TransferableTypedData` and the zero-copy dance are unnecessary — the port carries objects, and
  the isolate writes bytes straight to the client.

### 6.2 The constraint this creates: filters must be built by a top-level function

`SendPort` cannot carry closures, and `serialize`/`deserialize` are closures. This is the same
constraint already documented for `onInit` and `fnInitLayer` in
[07-caveats.md, item 6](07-caveats.md#6-everything-that-crosses-an-isolate-boundary-must-be-sendable).

So the filter table cannot be constructed in the main isolate and handed over. It must be built
**inside** the isolate by a top-level function whose reference is passed at spawn time:

```dart
final nats = NatsPipe(url, prefix: 'acme.shop', filters: buildNatsFilters);
```

The same builder is called in the main isolate, which keeps only its **data part** — the type tag,
the subject pattern and the direction, none of which are closures. That is exactly what `fire`
needs synchronously: to validate the address, to build `<type>.<path>`, and to answer "can any
filter encode this type?" without asking the isolate.

So the table exists in two halves:

| Half | Where it lives | What it holds | Why there |
|---|---|---|---|
| data | main isolate | type → subject pattern, direction | `fire` is synchronous and cannot ask the isolate |
| code | transport isolate | `serialize`, `deserialize` | keeps encoding and decoding off the main thread |

**Consequence to document:** filters are declared **in code**, not configured at runtime. A filter
cannot be added after startup without a means of sending a closure to the isolate, which does not
exist. For a routing table that is a reasonable place to land — but it should be a stated property,
not a surprise.

### 6.3 Port protocol

* **down:** `_Connect(config)`, `_Publish(subject, dynamic value, EventDTO dto)`, `_Subscribe(subject)`,
  `_Unsubscribe(subject)`, `_Dispose()`
* **up:** `_Ready()`, `_InitError(error)`, `_Message(subject, dynamic value)`,
  `_Status(connecting|connected|lost)`, `_PublishFailed(subject, error)`,
  **`_FilterError(subject, error)`** — filter failures happen on the far side now, so they need an
  explicit message to reach `errorStream` (§3)

Discipline kept from [event_bus_isolate.dart](../lib/src/event_bus_isolate.dart) — each rule there
is somebody's bug fix:

1. the port listener **never throws** — an exception there escapes to the zone and kills the isolate;
2. readiness is signalled only after the client is genuinely connected (`waitInit`, fix #3);
   `fire` returns `false` until then;
3. `_InitError` completes `waitInit` with an error rather than hanging (fix #20);
4. the main side mirrors `_Status` into a cached `bool` — `fire` is synchronous.

**Platform:** `Isolate.spawn` throws `UnsupportedError` on Flutter Web; `dart:isolate` is "currently
only supported by the Dart Native platform". With `runInIsolate: false` the same builder runs on the
main isolate and the split of §6.2 collapses — which is why the builder is a separate function
rather than a constructor argument.

---

## 7. Blast radius

| Area | Change |
|---|---|
| `lib/src/topic.dart` | rewritten as a value object over a string; `Uri`, `scheme` and parse-from-URI gone; `arguments`/`fragment` removed |
| `lib/src/event_bus.dart` | `fire` added; `errorStream` added; `target` removed from eight signatures; `subject` override added; `send` gains the guard of §2.3 |
| `lib/src/event_dto.dart` | gains `arguments` and `fragment` |
| `lib/src/fsm.dart` | `addFSMTransition(eventTarget:)` removed |
| `lib/src/event_bus_isolate.dart` | `target` removed from `send`; **no structural change** |
| `lib/src/layers.dart`, `scope.dart`, `command.dart` | **unchanged** — they never took a `target` |
| `test/` (83 tests) | 5 `target:` sites; `topic_dto_test.dart` rewritten for the new address |
| `doc/` | `Topic` sections of 01, 02, 06 and 07 rewritten; README quick-start; a migration table |
| `packages/` | new workspace: `event_bus_transport`, `event_bus_nats` |

For comparison, an earlier draft of this plan (removing the `Completer`) touched
`event_bus_isolate.dart`, `scope.dart`, `command.dart` and all 34 `Completer` sites in the tests.
That is the difference decisions 2 and 3 buy.

---

## 8. What is lost, and what must be documented

* **`send` cannot cross a process boundary**, by construction. Reaching for it from a network
  context throws, with a pointer to `fire`.
* **`fire` has no delivery guarantee.** `true` means "taken", nothing more.
* **`haveListener` / `haveHandler` stay local**, and cannot be made remote by any amount of work.
* **`target` is gone.** An address that used it as a separate dimension becomes a `path` token, and
  a subscription that relied on `target` being one token loses that guarantee, since `path` is
  free-form.
* **An explicit `subject` opts out of the type-token conventions** — no `type.>` wildcarding for it,
  and nothing stops two types from colliding on one address.
* **Filters are declared in code, not configured at runtime** (§6.2).
* **Ordering.** Delegated to the client library (decision 8) — valid only while there is exactly one
  connection per pipe. Per-subject connections would reorder, so "one connection" is an invariant of
  the pipe contract, not an implementation detail.

---

## 9. Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | **`send` becomes a trap** over a network — someone uses it for a remote topic and gets a confusing failure | high | medium | The throw names `fire`; document the rule at the top of both methods |
| R2 | **Two dispatch paths confuse users** | high | medium | One line: reply wanted → `send`, crossing a boundary → `fire`. README's first screen, not chapter 6 |
| R3 | **An explicit `subject` silently loses type routing** for non-Dart peers and wildcard subscriptions | medium | medium | Document on the parameter; the type token is a convention, but a load-bearing one |
| R4 | **Removing `target` breaks every address** that used it, and every pattern that assumed it was one token | **high** | medium | 3.0 break. A migration table: `target: 'x', path: '/y'` → `path: 'x.y'`. Only 5 sites in tests and examples |
| R5 | **The send path is not as off-thread as it looks** — `SendPort.send` copies synchronously on the caller's thread | certain | low–medium | Know it, measure it, and do not advertise "zero main-thread cost" (§6.1) |
| R6 | **Delegate-ordering assumption breaks** if connections are not one-per-pipe | medium | medium | One connection per pipe, stated as a contract invariant |
| R7 | **Backpressure.** `SendPort` is unbounded and never blocks; a slow socket grows the isolate mailbox until OOM | **high** | medium | In-flight counter in the pipe; past the limit `fire` returns `false` |
| R8 | **`dart_nats` maturity** — 39 likes, unverified uploader, JetStream experimental, headers thinly documented | certain | medium | Core pub/sub only; confined to `packages/event_bus_nats`; a fake pipe keeps the bus testable without it |
| R9 | **Header support unknown.** If `dart_nats` `pub` cannot attach headers, `arguments` cannot travel as NATS headers | medium | medium | **Verify before the first publish.** Fallback: a JSON envelope carrying the tag, args and data in the payload |
| R10 | **Filter overlap produces a misroute** | medium | medium | Key by type, one pattern per type, reject overlaps at registration |
| R11 | **Silent drops on an unknown subject inbound** | medium | medium | `_FilterError` → `EventBusError(filter)` → `errorStream`; never drop quietly |
| R12 | **Payload size.** NATS default max is typically 1 MiB and server-configurable; locally there is no limit | medium | medium | Local check → throw; document the server limit |
| R13 | **Flutter Web cannot spawn the isolate**, so the filter split of §6.2 collapses | certain | medium | The builder is a function, so the same table runs on the main isolate; declare platform support and the cost difference |
| R14 | **A filter with both codecs null** registered by mistake | medium | low | Rejected at registration (§5.1) |
| R15 | **`subject` and `path` passed together** | medium | low | Throw when both are set (§2.2) |

---

## 10. Phases

### Phase 0 — the address and `fire`, no transports yet

`Topic` becomes a value object over a string; `Uri`, `scheme` and `target` go; `arguments`/`fragment`
move to `EventDTO`; the `subject` override is added everywhere an address is taken; `fire` and
`errorStream` are added; the `send` guard of §2.3 is added. No broker anywhere.

*Exit criteria:* the rules of §4.7 are fixed and tested; `fire` returns the documented `bool` in
each of the four cases; a handler reached by `fire` that throws lands in `errorStream`; `send`
throws with a pointer to `fire` when a transport is attached and no local node exists; passing both
`subject` and `path` throws; the migration table is written and the docs updated.

### Phase 1 — workspace and the pipe contract

`packages/event_bus_transport`: `EventPipe`, `NatsFilter` (broker-agnostic in shape), a `FakePipe`,
and a **conformance suite** any transport must pass.

*Exit criteria:* the bus runs against `FakePipe` with no core changes; the filter direction rules of
§5.1 are enforced and tested; the conformance suite is written so a real transport drops into it.

### Phase 2 — `event_bus_nats`

Transport isolate, filters built by a top-level function and running in that isolate, one connection,
the in-flight limit, `dart_nats` behind the pipe. Core NATS only.

*Exit criteria:* two processes exchange fired events through a real broker; the conformance suite
passes against NATS; killing the broker is survivable and `fire` returns `false` while it is down;
a receive-only filter is proven not to subscribe and a send-only filter not to publish; R9 is
answered and the wire format is documented.

### Phase 3 — hardening

Reconnect and shutdown tests, a docker CI harness, a measurement of the §6.1 send-path claim, docs,
an example, and a README section on what is *not* guaranteed.

### Later — MQTT

Only after the pipe contract survives one real transport. Retained messages map onto
`isModelBus` / `lastData`; MQTT 5 response topic and correlation data would let `send` cross a
network if that is ever wanted; user properties cover `arguments` for v5 only.

---

## 11. Open questions

1. **§4.3 — catch-all filters.** Forbid a trailing `>` where several types share a pattern, or allow
   it with a branching `deserialize`?
2. **§4.6 — does `Topic` still need `Topic.create<T>()`** as a standalone, or does all construction
   move to the bus now that `runtimeType` is only a local fallback?
3. **§5.2 — overlap**: reject at registration (recommended) or first-match-wins?
4. **§2.2 — `false` for a type no filter can encode**: correct, or should an unmatched outgoing
   event be a loud error instead?
5. **§6.2 — is "filters are declared in code" acceptable**, or is runtime-registered filtering a
   requirement? The second would need a different mechanism entirely.
6. Does `fire` need a `Future` variant for callers who want to await the publish reaching the socket?
   The contract says no; confirm that nothing needs it.

---

## What next

* [08-transports.md](08-transports.md) — the option analysis behind these decisions.
* [01-architecture.md](01-architecture.md) — the model v3 changes, and the parts it leaves alone.
* [07-caveats.md](07-caveats.md) — the guarantees decision 2 keeps in place.
