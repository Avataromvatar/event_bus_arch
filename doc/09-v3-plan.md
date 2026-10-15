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
| 4 | **The address becomes broker-native: `target.path.type`.** | `Topic` stops being a URI. One token-order problem and one ambiguity problem to settle first. §4. |
| 5 | **The NATS wrapper holds filters**, each with its own serializer/deserializer; payload is `Uint8List`. | One structure declares both "what may cross" and "how it is encoded". §5. |
| 6 | **Ordering and duplicates are delegated** to the client library. | Safe under core NATS *provided* one connection per pipe — risk R5. |
| 7 | **The NATS client runs in its own isolate**; sockets never leave it. | Native only: `Isolate.spawn` throws `UnsupportedError` on Flutter Web. §6. |

Compared with the earlier draft of this plan (which removed the `Completer`), decisions 2 and 3
shrink the change from a core rewrite into an addition. That is the right trade for v3 — §2.4 says
why — and the cost is one new rule for users to learn: **`send` for a reply, `fire` for a network.**

---

## 2. `send` and `fire`

### 2.1 Naming: `fire`

Recommended: **`fire`**.

* It names the property that actually distinguishes it: *fire and forget*. A reader who knows the
  idiom knows the event gets no answer, which is the whole point of the method.
* It contrasts with `send` on sight. `send` has a destination and may expect something back;
  `fire` is aimed at no one and expects nothing. Two words, one distinction, no doc needed.
* It is the established verb in the Dart/Flutter event-bus ecosystem, so it costs a newcomer
  nothing to learn.

Runner-up: **`emit`**. Its argument is real — Node's `EventEmitter.emit()` already returns `true`
when there were listeners, which is almost exactly this contract, and borrowing an established
convention is worth something. Against it: in Flutter, `emit` is strongly associated with
Cubit/BLoC, where `emit(state)` means "publish new state", not "dispatch an event outward". The
package would be importing a word that already means something else to its main audience, and the
`send`/`emit` pair reads less clearly than `send`/`fire`.

### 2.2 The contract of `fire`

```dart
/// Dispatches a one-way event. No answer comes back — there is no completer and
/// nothing to await.
///
/// true  — the event was taken: a local node accepted it, or a transport
///         accepted it for publishing
/// false — nothing took it, and retrying the same call may help once the
///         situation changes: no local node, no usable transport, no filter
///         matched the topic, or the transport is over its queue limit
///
/// Throws EventBusException when retrying cannot help: the topic cannot be
/// mapped to a legal subject, no filter can encode the type, the payload is
/// over the size limit, or the bus is disposed.
bool fire<T>(T data, {String? target, String? path, String? fragment,
                      Map<String, String>? arguments});
```

Three things this contract is careful about:

* **`false` never means "not delivered".** It means "not taken". Same reasoning as in
  [08-transports.md §2](08-transports.md) — over core NATS, whether a remote process received
  anything is not observable at all. NATS answers "no subscribers" only for *requests*
  (the `no_responders` 503), and `fire` is not one.
* **`false` doubles as the backpressure signal.** `SendPort` is unbounded and never blocks, so a
  slow socket would otherwise grow the transport isolate's mailbox until the process dies.
  Returning `false` past a configurable in-flight limit turns an OOM into a visible drop —
  risk R6.
* **Filtered-out is `false`, not an error.** A topic that matches no filter is normal operation
  for a wrapper that is meant to keep internal events internal (§5).

### 2.3 What `send` does when a transport is attached

`send` stays exactly as it is *locally*, and gains one new failure mode:

| Situation | Today | v3 |
|---|---|---|
| Local node exists | delivered, completer works | **unchanged** |
| No local node, no transport | returns `null` | **unchanged** |
| No local node, **transport attached** | returns `null` | **throws**, naming `fire` |
| Inbound remote event | n/a | the DTO arrives with `completer == null` |

The third row is the safety net. It cannot produce a false positive in any meaningful way: if
there is no local node, nothing in this program can complete the completer, so a `send` there
could only ever return `null` or hang — it was already useless. The change converts a silent
`null` into a loud, actionable error. (On `isModelBus: true` a node is always created, so this
row does not apply.)

The fourth row is what keeps the two paths from interfering: an event that arrived over the
network has no sender waiting, so its `completer` is `null`. A handler written for `send` that
calls `dto.completer?.complete(x)` — the pattern used throughout the package — quietly no-ops when
the same handler is reached by `fire` or by a remote event. No handler rewrite is needed.

### 2.4 Why keeping `send` is the cheaper plan

Worth stating plainly, because the earlier draft of this plan argued the opposite.

Removing the `Completer` would have simplified `EventBusIsolate` — but `event_bus_isolate.dart` is
the most-repaired file in the package: fixes #2, #3, #19, #20 and #21 all live in it, five of
twenty-one. Removing the `Completer` would also have silently killed the error path for throwing
handlers (fix #6) and broken `Scope.initScope`, which awaits the result of its first send
([scope.dart:56](../lib/src/scope.dart#L56)).

Keeping `send` costs one thing instead: **two dispatch paths must coexist, and users must know
which one to reach for.** That is a documentation problem with a clear rule — reply wanted → `send`;
crossing a process boundary → `fire` — rather than a rewrite of the package's most fragile code.
The blast radius in §7 reflects that.

### 2.5 Why not auto-mirror

An obvious temptation: when a transport is attached, make `send` also publish. **Rejected.**
It would deliver the same event twice to a process that has both a local handler and a remote
subscriber, and it would leave the completer's meaning ambiguous — should it complete on local
handling, on publish, or on both? One method, one path across the boundary: `fire`.

---

## 3. The error path (smaller than before)

With `send` kept, the error story is mostly intact: a throwing handler still reaches its sender
through the completer (fix #6). Only two cases have nowhere to report:

* a handler that throws while serving a **fired** event — nobody is waiting;
* a transport-level failure — connection lost, publish rejected, undecodable inbound message.

Both need a channel, so `errorStream` is still required, but scoped:

```dart
enum EventErrorSource { handler, transport, filter }

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
decode must not be a silent drop** — that is how a registry that drifted between two deployed
services becomes visible instead of looking like a quiet night.

---

## 4. The address: `target.path.type`

### 4.1 What the order buys, and what it costs

```text
<prefix> . <type> . <target> . <path...>      ← proposed below
   │         │         │          │
   │         │         │          └─ free-form, dots allowed
   │         │         └──────────── free-form, dots allowed
   │         └────────────────────── exactly ONE token, dot-free
   └──────────────────────────────── tenant / application namespace

acme.shop.OrderPlaced.factory1.line3.machine7.temp
```

Required change to the proposal: **the type must come first, not last.** `target.path.type` reads
better as a hierarchy — location, then what happened — but it breaks a pattern that is hard to give
up once noticed.

NATS's `>` wildcard matches one or more tokens and is **legal only as the final token**. `*` matches
exactly one token. That makes the two orders unequal:

| You want | `<prefix>.<type>.<target>.<path>` | `<prefix>.<target>.<path>.<type>` |
|---|---|---|
| everything for a tenant | `acme.>` ✓ | `acme.>` ✓ |
| one type, **any target** | `acme.OrderPlaced.>` ✓ | `acme.>.OrderPlaced` ✗ illegal (`>` not final) |
| one type, one-token target | `acme.OrderPlaced.*` ✓ | `acme.*.OrderPlaced` ✓ |
| any type, a given target | `acme.*.warehouse` ✓ | `acme.warehouse.>` ✓ |
| everything for a target | `acme.>.warehouse` ✗ | `acme.warehouse.>` ✓ |

The blocking line is the second one. With the type last, "give me every `OrderPlaced` regardless of
where it came from" is expressible **only if `target` is exactly one token** — `acme.*.OrderPlaced`
matches one middle token and nothing deeper. The moment `target` may contain dots, as decision 4
wants, the pattern becomes unwritable at any depth. With the type first it is a single obvious
`acme.OrderPlaced.>`.

A second, independent reason: with the type first, the type is at a **fixed position** immediately
after the prefix, so it can be found by counting, and the rest of the subject can be free-form
without any parsing rule. With the type last it is found by taking the last token — also fixed —
but then `>` in a subscription can never cover a multi-token target, as above.

Note also that today's order is `target.type/path` — the type in the **middle**. That is the worst
of the three: it is a fixed position only while `target` is a single token, which is exactly the
constraint decision 4 wants to lift.

### 4.2 The ambiguity, and the fix

If both `target` and `path` may contain dots, the reverse mapping becomes ambiguous:

```text
subject : acme.shop.factory1.line3.machine7.temp.OrderPlaced
prefix  : acme.shop            (known)
type    : the fixed token
middle  : factory1.line3.machine7.temp      ← split where?
```

`target = factory1.line3`, `path = machine7.temp` and `target = factory1`, `path = line3.machine7.temp`
produce the same subject. Anything that needs to rebuild `target` and `path` on the receive side
will pick one, the handler registered under the other will not be found, and the event is dropped
with no error.

Three ways out:

* **(a) The subject is the key — recommended.** `Topic` equality becomes the subject string.
  `target` and `path` are *write-side builders*: both `fire<T>(data, target:, path:)` and
  `setHandler<T>(target:, path:)` build the same subject from their inputs, and the receive path
  never reconstructs anything — the arriving subject is the key. The ambiguity cannot be reached
  because nothing is ever parsed back.
* **(b) Fix the boundary.** Forbid dots in `target` — keep today's `assert` — and let only `path`
  be free-form. The split becomes deterministic: first token after the prefix is the target, the
  rest is path. Costs the flexibility decision 4 asked for on `target`, and keeps
  `dto.topic.target` / `dto.topic.path` meaningful on both sides.
* **(c) A separator token** between target and path. Ugly, and it reserves a token that can collide
  with application data.

**Recommendation: (a).** It is the smallest rule set — the subject is the address, full stop — and
it is the only one that needs no parsing convention to be remembered by every reader.

The cost of (a) must be documented, though: on an **inbound remote event**, `dto.topic.target` and
`dto.topic.path` cannot be recovered reliably. A handler that branches on them to decide what to do
will work for locally-sent events and quietly misbehave for remote ones. Handlers should branch on
the event type and use the subject string for logging and routing. If branching on `target` inside
a handler is a real pattern in existing code, take option (b) instead — it is the conservative
choice and it is strictly less powerful, not less correct.

### 4.3 Rules

| Part | Rule | Why |
|---|---|---|
| `prefix` | 1+ tokens of `[A-Za-z0-9_-]` | tenant namespace; broker ACLs are written against it |
| `type` | exactly **one** token, `[A-Za-z0-9_-]`, from the filter table | a dot would shift every following token; this is the token the decoder keys on |
| `target` | free-form, dots allowed under (a) | decision 4 |
| `path` | free-form, dots allowed under (a) | decision 4 |
| any token | non-empty, no whitespace, no `*`, no `>`, no `$`-prefix, no leading/trailing dot | NATS wildcards, reserved `$SYS`/`$JS`/`$KV`, and `..` is not a valid subject |
| total | ≤ 16 tokens, ≤ 256 chars | NATS's own sizing advice |
| payload | 1 MiB by default | the NATS server default; configurable, and checked locally so a failure is loud (risk R11) |

Validation happens at `fire` / `setHandler`, not at the socket: a subject that is illegal *for the
broker* should never reach it. Today's only guard is a debug-mode `assert` on `target`
([topic.dart:128](../lib/src/topic.dart#L128)), which does nothing in a release build.

### 4.4 Where the type tag comes from

Under the new address the type is an explicit token — which is exactly what
[08-transports.md §4.1](08-transports.md) said `T.runtimeType` cannot be: it is minified in Flutter
Web release builds by default, obfuscated under `--obfuscate`, and silently changed by renaming a
class.

So every type that crosses the wire needs a **declared, dot-free tag**, supplied by the filter
table (§5). The tension to settle: `Topic.create<T>()` is standalone today and uses `runtimeType`,
and standalone `Topic` creation has no access to a filter table.

Recommended resolution, in order of preference:

1. **Construction moves into the bus.** `bus.fire<T>()` and `bus.setHandler<T>()` know the bus, the
   bus knows its filter table, so they build the subject with the declared tag. `Topic.create<T>()`
   stays for local-only use, where `runtimeType` is fine because nothing leaves the process.
2. **A bus-level tag registry** consulted by `Topic.create<T>()`. Works, but it is global mutable
   state and two buses in one process could disagree.

Option 1 keeps the tag where it is used and needs no global state.

---

## 5. The NATS wrapper: filters with codecs

### 5.1 Shape

One ordered list declares both the routing and the encoding, so "what may cross" and "how it is
encoded" cannot drift apart:

```dart
class NatsFilter<T> {
  final String subject;      // <prefix>.<type>.<target>.<path>, NATS wildcards allowed
  final Uint8List Function(T value, EventDTO<T> dto) serialize;
  final T Function(Uint8List bytes, String subject) deserialize;
}

final nats = NatsPipe('nats://localhost:4222', prefix: 'acme.shop')
  ..filter<OrderPlaced>(
        subject: 'acme.shop.OrderPlaced.warehouse.>',
        serialize: (v, dto) => utf8.encode(jsonEncode(v.toJson())),
        deserialize: (b, s) => OrderPlaced.fromJson(jsonDecode(utf8.decode(b))),
      );
```

Properties worth having from this shape:

* **The filter list is the subscription list.** The wrapper subscribes to exactly the patterns that
  were declared, so a subject nothing declared is never received and never costs traffic.
* **Omitting a filter is the default deny.** An internal event that nobody registered simply does
  not leave the process. That is a real safety property, not just tidiness.
* **Encoding is per filter**, so JSON, msgpack, protobuf or hand-rolled binary all coexist, and
  `Uint8List` payloads make binary formats first-class rather than a workaround.
* **Deserialization receives the subject**, so one filter covering `>` can branch on the concrete
  subject if it needs to.

### 5.2 Decisions this shape needs

* **Overlap and precedence.** Two filters matching one subject is a misroute waiting to happen.
  Either reject overlaps at registration (checking patterns is cheap and can be done once), or
  document first-match-wins and make it explicit. **Recommend rejection** — the failure mode is
  otherwise a silent wrong codec.
* **One filter per type, or one per subject?** If several filters share a type, the type→filter
  direction is ambiguous. Keying the table by type and giving each type exactly one subject pattern
  removes both this and most overlaps.
* **Wildcards still resolve to concrete subjects on receive**, and a concrete subject must find its
  node. That works under §4.2(a) because the subject *is* the key; it does not work under (b) or (c)
  without reconstruction.

---

## 6. Isolate layout

```text
        main isolate                          transport isolate
┌──────────────────────────────┐         ┌────────────────────────────┐
│ EventBus                     │         │ dart_nats Client           │
│   _eventsMap                 │         │   Socket ◄──────────► NATS │
│                              │         │                            │
│ NatsPipe (main side)         │ SendPort│ NatsPipe (worker side)     │
│   filters: value → bytes     │────────►│   pub(subject, bytes)      │
│   status cache               │◄────────│   sub(subject) → bytes     │
└──────────────────────────────┘         └────────────────────────────┘
```

**Serialization runs in the main isolate**, where the filters — and therefore the application's
classes — live. The transport isolate never sees a domain object, never imports the application, and
is testable without it. Bytes cross the port as `TransferableTypedData` (zero-copy; the sender's
buffer is invalidated, which is fine since serialization just produced it).

Port protocol, following the discipline already proven in
[event_bus_isolate.dart](../lib/src/event_bus_isolate.dart) — each rule there is somebody's bug fix:

* **down:** `_Connect(config)`, `_Publish(subject, TransferableTypedData)`, `_Subscribe(subject)`,
  `_Unsubscribe(subject)`, `_Dispose()`
* **up:** `_Ready()`, `_InitError(error)`, `_Message(subject, bytes)`, `_Status(connecting|connected|lost)`,
  `_PublishFailed(subject, error)`

1. the port listener **never throws** — an exception there escapes to the zone and kills the isolate;
2. readiness is signalled only after the client is genuinely connected (`waitInit`, fix #3);
   `fire` returns `false` until then;
3. `_InitError` completes `waitInit` with an error rather than hanging (fix #20);
4. **the main side mirrors `_Status` into a cached `bool`** — `fire` is synchronous and cannot ask
   the worker isolate.

**Platform:** `Isolate.spawn` throws `UnsupportedError` on Flutter Web; `dart:isolate` is
"currently only supported by the Dart Native platform". The package already has this property
through `EventBusIsolate`. So: `runInIsolate: false` plus `wss://` on web, an explicit platform
declaration in the package, and a loud failure rather than subtly different behaviour.

---

## 7. Blast radius

Small, by design — this is the payoff of decision 2.

| Area | Change |
|---|---|
| `lib/src/topic.dart` | address builder rewritten for `target.path.type`; `runtimeType` replaced by a declared tag on the bus path (§4.4); validation moves from `assert` to a real check |
| `lib/src/event_bus.dart` | `fire` added; `errorStream` added; `send` gains the "no local node + transport attached → throw" rule |
| `lib/src/event_dto.dart` | unchanged |
| `lib/src/event_bus_isolate.dart` | **unchanged** |
| `lib/src/layers.dart`, `fsm.dart`, `scope.dart`, `command.dart` | **unchanged** |
| `test/` (83 tests) | untouched, plus new tests for `fire`, the address rules and the filters |
| `doc/` | new document for `fire`; `Topic` sections in 01, 02 and 06 rewritten |
| `packages/` | new workspace: `event_bus_transport`, `event_bus_nats` |

For comparison, the earlier draft of this plan touched `event_bus_isolate.dart`, `scope.dart`,
`command.dart` and all 34 `Completer` sites in the tests. That is the difference decision 2 buys.

---

## 8. What is lost, and what must be documented

* **`send` cannot cross a process boundary**, by construction. Anyone reaching for it from a
  network context gets a throw and a pointer to `fire`.
* **`fire` has no delivery guarantee.** `true` means "taken", nothing more.
* **`haveListener` / `haveHandler` stay local**, and cannot be made remote by any amount of work —
  §2.2's third question is unanswerable in core NATS.
* **`dto.topic.target` / `.path` are unreliable on inbound remote events** under §4.2(a).
* **Ordering.** Delegated to the client library (decision 6) — which is valid only while there is
  exactly one connection per pipe. Per-subject connections would reorder, so "one connection" is an
  invariant of the pipe contract, not an implementation detail.

---

## 9. Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | **`send` becomes a trap** over a network — someone uses it for a remote topic and gets a confusing failure | high | medium | The throw names `fire`; document the rule at the top of both methods; a doc test on the wording is not absurd |
| R2 | **Two dispatch paths confuse users** — which one do I call? | high | medium | The rule is one line: reply wanted → `send`, crossing a boundary → `fire`. Put it in the README's first screen, not in chapter 6 |
| R3 | **The address rewrite breaks existing users** — any code holding a `Topic` string, parsing it, or matching on it | high | medium | This is the 3.0 break. A migration section listing `event://all.string/p` → `acme.shop.String.all.p` |
| R4 | **Dots in target and path make the reverse mapping ambiguous** | certain if neither fix is chosen | **high** — silent drops | §4.2; choose (a) or (b) before writing the builder |
| R5 | **Delegate-ordering assumption breaks** if connections are not one-per-pipe | medium | medium | One connection per pipe, stated as a contract invariant |
| R6 | **Backpressure.** `SendPort` is unbounded and never blocks; a slow socket grows the isolate mailbox until OOM | **high** | medium | In-flight counter in the pipe; past the limit `fire` returns `false` |
| R7 | **`dart_nats` maturity** — 39 likes, unverified uploader, JetStream experimental, headers thinly documented | certain | medium | Core pub/sub only; the library is confined to `packages/event_bus_nats`; a fake pipe keeps the bus testable without it |
| R8 | **Header support unknown.** If `dart_nats` `pub` cannot attach headers, `arguments` cannot travel as NATS headers | medium | medium | **Verify before the first publish.** Fallback: put `tag`, `args` and `data` in a JSON envelope, which changes the wire format |
| R9 | **Filter overlap produces a misroute** — the wrong serializer for a subject | medium | medium | Key the table by type, one subject pattern per type, reject overlaps at registration (§5.2) |
| R10 | **Silent drops on an unknown tag inbound** | medium | medium | `EventBusError(filter)` → `errorStream`; never drop quietly |
| R11 | **Payload size.** NATS default max is typically 1 MiB and server-configurable; locally there is no limit | medium | medium | Local check → throw; document the server limit |
| R12 | **Flutter Web cannot spawn the isolate** | certain | medium | `runInIsolate: false` + `wss://`; declare platform support |
| R13 | **Two paths race on one topic** — `send` and `fire` to the same topic from different places | low | medium | Explicitly out of scope: `fire` is not a delivery guarantee, and `send` is local. Document rather than arbitrate |

---

## 10. Phases

### Phase 0 — the address and `fire`, no transports yet

Rewrite the address builder for `<prefix>.<type>.<target>.<path>`; add declared type tags;
add `fire` and `errorStream`; add the `send` guard. No broker anywhere.

*Exit criteria:* the subject format is fixed and tested against the §4.3 rules; `fire` returns the
documented `bool` in each of the four cases; a handler reached by `fire` that throws lands in
`errorStream`; `send` throws with a pointer to `fire` when a transport is attached and no local node
exists; §4.2 is decided in code.

### Phase 1 — workspace and the pipe contract

`packages/event_bus_transport`: `EventPipe`, the filter table, a `FakePipe`, and a **conformance
suite** any transport must pass.

*Exit criteria:* the bus runs against `FakePipe` with no core changes; the conformance suite is
written so a real transport drops into it.

### Phase 2 — `event_bus_nats`

Transport isolate, filters serializing on the sender, one connection, the in-flight limit,
`dart_nats` behind the pipe. Core NATS only.

*Exit criteria:* two processes exchange fired events through a real broker; the conformance suite
passes against NATS; killing the broker is survivable and `fire` returns `false` while it is down;
R8 is answered and the wire format is documented.

### Phase 3 — hardening

Reconnect and shutdown tests, a docker CI harness, docs, an example, and a README section on what
is *not* guaranteed.

### Later — MQTT

Only after the pipe contract survives one real transport. Retained messages map onto
`isModelBus` / `lastData`; MQTT 5 response topic and correlation data would let `send` cross a
network if that is ever wanted; user properties cover `arguments` for v5 only.

---

## 11. Open questions

1. **§4.1 — token order.** Type first (recommended, keeps `acme.OrderPlaced.>`) or type last as
   proposed (loses it as soon as `target` may contain dots)?
2. **§4.2 — (a) subject-as-key or (b) dots forbidden in `target`?** (a) is simpler; (b) keeps
   `dto.topic.target` / `.path` meaningful on both sides. Says which one depends on whether existing
   handlers branch on `target`.
3. **§4.4 — where the type tag lives**: bus-level construction (recommended) or a global registry?
4. **§5.2 — overlap**: reject at registration (recommended) or first-match-wins?
5. **§2.2 — `false` for a filtered-out topic**: correct, or should an unmatched outgoing event be a
   loud error instead?
6. Does `fire` need a `Future` variant for callers who want to await the publish reaching the socket?
   The contract says no; confirm that nothing needs it.

---

## What next

* [08-transports.md](08-transports.md) — the option analysis behind these decisions.
* [01-architecture.md](01-architecture.md) — the model that survives v3 unchanged.
* [07-caveats.md](07-caveats.md) — the guarantees decision 2 leaves in place.
