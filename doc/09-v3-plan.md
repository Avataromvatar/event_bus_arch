# 09. v3.0 plan: no Completer, and a NATS transport

[← 08. Transports](08-transports.md) · [Contents](README.md)

**Status: plan.** Nothing in this document exists in 2.3.0, and parts of it describe a breaking
change to the public API. It follows the analysis in [08-transports.md](08-transports.md) and
records the decisions taken after it.

---

## 1. Decisions taken

| # | Decision | Consequence |
|---|---|---|
| 1 | **NATS first, core only — no JetStream.** MQTT kept in mind as the second transport. | At-most-once delivery. No broker dedup, no persistence. `dart_nats` is used as a plain pub/sub client, avoiding its experimental surface. |
| 2 | **`Completer` is removed in 3.0.** `send` no longer returns a result. | The bus is a bus, not an RPC. `EventBusIsolate` simplifies drastically. **But an error path must replace it** — see §3. |
| 3 | **`send` returns `bool`.** | Synchronous, and therefore only answerable from state the caller already holds. See §2 for exactly what it can and cannot mean. |
| 4 | **Ordering and duplicates are delegated** to the NATS/MQTT client library. | Safe under core NATS *provided* the transport uses a single connection — see §7, risk R6. |
| 5 | **The NATS client runs inside its own isolate**, and sockets never leave it. | Native only: `Isolate.spawn` throws `UnsupportedError` on Flutter Web. See §5.4. |

Decisions 2 and 3 are the breaking ones; 1, 4 and 5 are additive.

---

## 2. What `send` returning `bool` can mean

Three different questions hide behind "отправлено и есть подписчик", and only one of them is
answerable synchronously:

| Question | Answerable? |
|---|---|
| Is there a local node (handler or listener) for this topic? | Yes — the `_eventsMap` lookup is synchronous. |
| Is a transport connected and able to accept the event? | Yes, but only from a **cached** state, because the socket lives in another isolate. |
| Does a *remote* process have a subscriber? | **No.** Core NATS gives no way to ask. |

The third line is the important one. In NATS, "did anyone receive this?" is only observable
through `no_responders`, and that works **exclusively for request/reply** — the server answers a
*request* whose subject has no subscribers with a 503. Decision 2 removed request/reply, so this
mechanism is gone too. Plain `pub` is fire-and-forget by design.

### 2.1 The contract

```dart
/// true  — the bus took responsibility for the event:
///         a local node accepted it, or a live transport accepted it for publishing
/// false — nothing took it: no local node and no usable transport,
///         or the transport refused it (down, or over its queue limit)
bool send<T>(T data, {String? path, String? fragment, String? target,
                      Map<String, String>? arguments});
```

`false` means **dropped, and the caller may retry or log it**. It deliberately does not promise
delivery, and must not be documented as if it did.

This is a change in kind, not just in type: `send` stops being a query about the world and becomes
a statement about what the bus did with the event. It is the honest form of what decision 3 asks
for, and it is the only form that stays true across a network.

### 2.2 Things that throw rather than return `false`

`false` means "not accepted now, retryable". Contract violations still throw
`EventBusException`, because retrying them never helps:

* the topic cannot be mapped to a legal NATS subject (§4.4);
* no codec is registered for the static type `T` (§4.3);
* payload exceeds the local size limit;
* the bus is disposed (today's behaviour, kept).

### 2.3 What is lost, and cannot be recovered

* "There is a remote subscriber" is unknowable. `haveListener` / `haveHandler` keep their exact
  local meaning and must be documented as **local only**.
* `send`-as-sync-point ([07-caveats.md, item 3](07-caveats.md#3-delivery-to-listeners-is-asynchronous))
  holds locally and is meaningless remotely. Under decision 2 it stops being a promise anyone
  could rely on for a result — which removes the trap rather than hiding it.

---

## 3. The error path that must replace the Completer

This is the largest single risk in the whole plan, and it is created by decision 2.

Today a handler that throws is visible to the sender, because `EventNode` completes the
`completer` with the error (fix #6 in [07-caveats.md](07-caveats.md), with tests). Remove the
`Completer` and a throwing handler has **nowhere to report**. The default would be an unhandled
async error in the zone — invisible in a Flutter app, fatal in a well-behaved server.

**The replacement is a first-class error channel:**

```dart
enum EventErrorSource { handler, transport, codec }

class EventBusError {
  final EventDTO? dto;          // null for transport-level failures
  final Object error;
  final StackTrace? stackTrace;
  final EventErrorSource source;
}

abstract class EventBus {
  /// Replaces "the sender gets the handler error through the completer".
  Stream<EventBusError> get errorStream;
}
```

Rules:

* a handler that throws publishes an `EventBusError(handler)` and the bus carries on;
* a transport that fails to publish publishes an `EventBusError(transport)`;
* an undecodable inbound message publishes an `EventBusError(codec)` — this is how a missing
  registry entry stops being a silent drop;
* `EventBusLogger` gains an `errorStream` subscription so the default experience is "you see it
  in the log", matching today's behaviour.

Without this item, v3.0 is a **regression against a documented, tested guarantee**. It should be
implemented in the same commit that removes the `Completer`, not after.

---

## 4. Blast radius of removing the Completer

Measured against 2.3.0: 34 `Completer` references across `lib/`, `test/` and `example/`, and 83
tests.

| File | Change | Risk |
|---|---|---|
| [topic.dart](../lib/src/topic.dart) | untouched | none — the local address model survives v3 unchanged |
| [event_dto.dart](../lib/src/event_dto.dart) | `completer` field, the `Completer` parameter and the `completer:` named argument removed; `toJson` shrinks | low |
| [event_bus.dart](../lib/src/event_bus.dart) | `EventNode._process` loses `_completeIfNeeded` / `_completeErrorIfNeeded`; `EventNode.send` loses the `dto.data is T` completion branch; `EventBus.send` returns `bool`; `errorStream` added | medium — the `data is T` branch also existed to stop foreign-type events hanging a sender; with no sender waiting, that path becomes "report and drop" |
| [event_bus_isolate.dart](../lib/src/event_bus_isolate.dart) | `_PendingRequest`, `_IsolateResponse`, `_IsolateErrorResponse`, `_IsolateRequest.completer` and most of `failAllPending` disappear. `_IsolateLink` becomes a one-way forwarder plus ping plus status | **high** — this is the most-repaired file in the package (fixes #2, #3, #19, #20, #21 all live here) |
| [command.dart](../lib/src/command.dart) | `execute` / `undo` return `bool`; `undo()` with a short history returns `false` instead of `null` | low, but see §4.1 |
| [scope.dart](../lib/src/scope.dart) | `initScope` no longer has a result to await | **high** — see §4.1 |
| [fsm.dart](../lib/src/fsm.dart) | none — it reads `allEventStream` and never uses the completer | none |
| [layers.dart](../lib/src/layers.dart) | none structurally; its `EventBusIsolate` shrinks underneath it | low |
| `test/` (9 files, 34 references) | rewritten around `bool` and `errorStream` | medium — the tests are the only safety net for the isolate fixes |
| `doc/` (7 documents) | every reference to `send` returning a value | medium — 3,230 lines to re-read |

### 4.1 The one non-obvious casualty: `Scope.initScope`

[scope.dart](../lib/src/scope.dart) documents and relies on:

```dart
/// The returned future is worth awaiting: it completes once the initial value
/// has gone through the bus (or with a handler error).
await _scopeCommand!.execute(data);      // scope.dart:56
```

That await is a `Completer` round-trip. With no `Completer` it cannot complete "after the value
went through the bus", and `Command.execute` returning `bool` leaves nothing to await.

Options:

* **A (recommended):** `initScope` keeps `Future<void>`, and completes after the value stream has
  delivered the initial value to its own subscription — a microtask hop, no round-trip. Loses the
  "handler error surfaces here" clause, which moves to `errorStream`.
* **B:** `initScope` becomes synchronous `void`. Smaller, blunter, and a wider break for callers.

Either way the doc comment and [05-scope-and-command.md](05-scope-and-command.md) must change.

### 4.2 A simplification worth taking

Removing the `Completer` makes `EventBusIsolate` and a network transport **the same shape**: a
bidirectional pipe that forwards events between two buses, one direction each, with a readiness
handshake and a status stream.

That is the reason to do the `Completer` removal *before* the transport work rather than with it:
after §3 and §4 are done, `EventBusIsolate` is a 366-line file reduced to roughly a pipe, and a
NATS transport is the same pipe with a codec bolted on. Doing it in the other order means writing
the request/reply machinery twice — once for the isolate, once for the broker — and then deleting
one of them.

### 4.3 Workspace migration (independent of everything above)

Move to a [pub workspace](https://dart.dev/tools/pub/workspaces): `workspace:` in the root
pubspec, `resolution: workspace` in members, SDK floor `^3.6.0` (from `>=3.0.0`). No Melos needed.
Do this as a separate commit before any transport code exists, so the first transport package does
not have to land in the same change as the monorepo restructure.

---

## 5. The transport layer

### 5.1 Shape

Three pieces, one package contract, one implementation per broker.

```dart
/// One message as it exists on the wire. Bytes and strings only.
class TransportMessage {
  final String subject;
  final String tag;                       // the event type tag, one NATS token
  final Uint8List payload;
  final Map<String, String> headers;      // arguments
}

/// Explicit tag <-> Dart type. The registry is the price of "no code generation".
class EventCodec {
  void register<T>(String tag,
                   T Function(Map<String, dynamic>) fromJson,
                   Map<String, dynamic> Function(T) toJson);
  TransportMessage encode(EventDTO dto);
  EventDTO decode(TransportMessage message);
}

/// A live connection to a broker, from the bus's point of view.
abstract class EventPipe {
  Stream<EventDTO> get incoming;
  Stream<PipeStatus> get status;          // connecting | connected | lost
  bool send(EventDTO dto);                // what EventBus.send forwards to
  void subscribe(Topic topic);
  void unsubscribe(Topic topic);
  Future<void> dispose();
}
```

`EventBus.send` becomes: local node? → deliver. Else, pipe attached? → `pipe.send(dto)`.
Else → `false`.

### 5.2 Where the isolate boundary sits, and who runs the codec

```text
        main isolate                          transport isolate
┌──────────────────────────────┐         ┌────────────────────────────┐
│ EventBus                     │         │ dart_nats Client           │
│   _eventsMap                 │         │   Socket ◄──────────► NATS │
│                              │         │                            │
│ NatsPipe (main side)         │ SendPort│ NatsPipe (worker side)     │
│   codec: EventDTO → bytes    │────────►│   pub(subject, bytes)      │
│   status cache               │◄────────│   sub(subject) → bytes     │
└──────────────────────────────┘         └────────────────────────────┘
```

**The codec runs on the sending side, in the main isolate.** The transport isolate is a pure byte
pipe: it never sees a Dart domain class, never imports the application, and can be tested without
one. Two consequences worth having:

* The transport isolate has no dependency on the app's event classes. Its entry point is a
  top-level function that takes a connect config and a `SendPort` — nothing else.
* Bytes cross the port as `TransferableTypedData` (zero-copy; the sender's buffer is invalidated,
  which is fine because the codec just produced it). Inbound bytes arrive the same way and are
  decoded in the main isolate, where the registry lives.

The alternative — codec inside the transport isolate — would force the registry, and therefore the
application's classes, into the isolate. Rejected.

### 5.3 Port protocol

The message set is small, and the discipline is the one already proven in
[event_bus_isolate.dart](../lib/src/event_bus_isolate.dart):

* **down:** `_Connect(config)`, `_Publish(subject, tag, TransferableTypedData, headers)`,
  `_Subscribe(subject)`, `_Unsubscribe(subject)`, `_Dispose()`
* **up:** `_Ready()`, `_InitError(error)`, `_Message(subject, tag, bytes, headers)`,
  `_Status(connecting|connected|lost)`, `_PublishFailed(subject, error)`

Rules kept from the current implementation because each one was a bug fix:

1. the port listener **never throws** — an exception there escapes to the zone and kills the
   isolate;
2. readiness is signalled only after the client is genuinely connected (`waitInit` semantics,
   fix #3) — `send` returns `false` until then;
3. `_InitError` completes `waitInit` with an error rather than hanging (fix #20);
4. the main side mirrors `_Status` into a cached `bool _connected`, because `send` is synchronous
   and cannot ask the worker.

### 5.4 Platform: native only

`Isolate.spawn` throws `UnsupportedError` on Flutter Web — the Dart docs state that `dart:isolate`
"is currently only supported by the Dart Native platform". The package already has this property
via `EventBusIsolate`; decision 5 extends it to transports.

Therefore:

* on native, the pipe runs in its own isolate by default, with `runInIsolate: false` available for
  tests and for running inside a `Layers` worker;
* on web, NATS must run over WebSocket (`wss://`) on the main isolate — supported by `dart_nats`
  but a different code path;
* this is a **documentation item**, not a blocker: `event_bus_nats` should declare its platform
  support explicitly and fail loudly on web rather than behave subtly differently.

### 5.5 Subject mapping (NATS)

```text
<prefix>.<tag>.<target>.<path token>...
   │       │      │         │
   │       │      │         └─ from Topic.path, split on '/'
   │       │      └─────────── Topic.target (already asserted dot-free)
   │       └────────────────── the codec registry tag — exactly ONE token
   └────────────────────────── tenant/application namespace, e.g. "acme.shop"

acme.shop.OrderPlaced.warehouse.created
```

Rules, all of them testable and all of them enforced at the boundary:

| Part | Rule | Why |
|---|---|---|
| `prefix` | 1+ tokens of `[A-Za-z0-9_-]` | tenant namespace; broker ACLs are written against it |
| `tag` | exactly 1 token of `[A-Za-z0-9_-]` | it is one position in the subject; a dot would shift every following token |
| `target` | 1 token, no dot | already asserted today (`Topic.create`) |
| path tokens | from `path.split('/')`, leading empty dropped, empties rejected | today's `path` begins with `/`, which under MQTT would create an empty level |
| **never** | `*`, `>`, whitespace, `$`-prefix | NATS wildcards and `$SYS`/`$JS`/`$KV` are reserved |
| total | ≤ 16 tokens, ≤ 256 chars | NATS's own sizing advice |

The reverse mapping (`subject → Topic`) needs `tag → Type` from the registry, which is why the
registry is bidirectional: without it the receiving bus cannot compute the `Topic` its handler is
registered under.

**One broker subscription per local topic.** No pattern inference from several topics — NATS
subscriptions are cheap (trie-based interest graph, the docs call subjects "essentially free to
create"), and inference would silently widen what a subscriber receives. Explicit wildcard
subscriptions can be added later as an opt-in; the receive path already supports them, because an
incoming concrete subject is decoded to a concrete `Topic` and looked up in `_eventsMap` as usual.

### 5.6 Verification needed before implementation

`dart_nats` headers support is documented thinly — the only reference found is reading
`msg.header?.status`. **Check whether `pub` accepts headers.** If it does not, `arguments` cannot
travel as NATS headers and must go into the payload envelope:

```json
{ "tag": "OrderPlaced", "args": {"priority": "1"}, "data": { ... } }
```

This is a small change to the codec and a real one to the wire format, so it should be settled
before the first message is published, not after.

---

## 6. What becomes possible

* **The same API across processes and machines.** `send` / `subscribe` / `setHandler` do not change
  shape; only the pipe behind them is new.
* **A much smaller isolate bridge.** Fixes #2, #19 and #21 become unreachable — their subject
  matter (correlating replies, failing hung requests) stops existing.
* **One pipe contract, three transports.** MQTT with its retained messages and QoS, and Redis with
  its reply-channel workaround, are implementations of `EventPipe`, not new architectures.
* **Non-Dart peers, if the tag is readable.** With `acme.shop.OrderPlaced.warehouse.created` a Go
  or Python service can route on the subject. This is exactly what percent-encoded
  `runtimeType` names (`list%3Cint%3E`) made impossible.
* **An honest failure story.** `bool` plus `errorStream` replaces "a Future that may or may not
  complete" with two explicit outcomes.

---

## 7. Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | **Handler errors become invisible** after the `Completer` goes | high if §3 slips | **high** — regression against a tested guarantee | Implement `errorStream` in the same commit as the removal; port the existing error tests to it |
| R2 | **`Scope.initScope` changes meaning** | certain | medium | Decide A or B in §4.1 before touching the code; update [05-scope-and-command.md](05-scope-and-command.md) |
| R3 | **Regressing the isolate fixes** (#2, #3, #19, #20, #21) while rewriting `event_bus_isolate.dart` | medium | **high** — those bugs were silent hangs | Rewrite against the existing tests; they are the only guard. Do not delete a test because its API disappeared — translate it or prove the scenario is impossible |
| R4 | **`bool send` documented as "delivered"** | medium | high — the API would lie, and callers would build on it | The doc comment in §2.1 is the contract; a doc test asserting the wording is not absurd here |
| R5 | **`dart_nats` maturity.** 39 likes, unverified uploader, JetStream experimental, headers thinly documented | certain | medium | Use core pub/sub only; confine it to `packages/event_bus_nats`; the `EventPipe` contract plus a fake implementation keeps the bus testable without the library |
| R6 | **Delegate-ordering assumption breaks.** "Order is the library's job" holds only while there is **one connection** — per-subject connections would reorder | medium | medium | One connection per pipe, stated as an invariant in the pipe contract, not left implicit |
| R7 | **Backpressure.** `SendPort` is unbounded and never blocks; a slow socket grows the isolate's mailbox without limit | **high** | medium — memory growth, then OOM | A max-in-flight counter in the pipe; when exceeded, `send` returns `false` rather than queueing. This is the third meaning of `false` and it belongs in §2.1 |
| R8 | **No codec for a type** — or the static type is a supertype and the registry has only the concrete class | medium | medium | Throw at `send` (never drop); the error names the type. Same class of trap as [07-caveats.md, item 1](07-caveats.md#1-the-type-in-a-topic-is-a-static-type-parameter) |
| R9 | **Registry drift** between two deployed services | medium | medium | Throw on unknown tag inbound → `errorStream`, plus a startup assertion that registered tags are unique |
| R10 | **Flutter Web cannot spawn the isolate** | certain | medium | `runInIsolate: false` + `wss://` on web; explicit platform declaration; fail loudly |
| R11 | **Isolate count grows**: one per `EventBusIsolate` layer plus one per pipe | medium | low–medium on mobile | `runInIsolate: false` when the pipe is created inside a `Layers` worker |
| R12 | **Workspace migration raises the SDK floor** to `^3.6.0` | certain | low | Separate commit, separate decision, version note in the changelog |
| R13 | **Payload size.** NATS's default maximum is typically 1 MiB and is server-configurable; locally there is no limit | medium | medium | Local size check → throw; document the broker limit in the transport README |
| R14 | **`haveListener` / `haveHandler` read as global** | medium | medium | Rename or document as local; they cannot be made remote by any amount of work |

---

## 8. Phases

### Phase 0 — v3.0 core, no transports

Remove the `Completer`; `send → bool`; add `errorStream`; resolve §4.1; shrink
`EventBusIsolate` to the pipe shape; rewrite the 34 completer-dependent test sites and the docs.

**Exit criteria:** 83 tests pass in their v3 form (translated, not deleted); no `Completer` in
`lib/`; `doc/` and README describe `bool` and `errorStream`; a handler that throws lands in
`errorStream` with a test proving it.

### Phase 1 — workspace and the pipe contract

`packages/event_bus_transport`: `EventPipe`, `TransportMessage`, `EventCodec`, `SubjectMapper`,
a `FakePipe`, and a **conformance suite** that any transport must pass.

**Exit criteria:** the bus runs against `FakePipe` with no changes to core; the conformance suite
is green against the fake and is written so that a real transport can be dropped into it.

### Phase 2 — `event_bus_nats`

Transport isolate, codec on the sender, subject mapping, status mirroring, reconnect, the
backpressure limit, `dart_nats` behind the pipe. Core NATS only.

**Exit criteria:** two processes exchange events through a real broker; the conformance suite
passes against NATS; a handler error in process B reaches B's `errorStream`; killing the broker is
survivable and `send` returns `false` while it is down; §5.6 is answered and the wire format is
documented.

### Phase 3 — hardening

Reconnect and shutdown tests, a real-broker CI harness (docker), docs, an example, a README
section on what is *not* guaranteed.

### Later — MQTT

Only after the pipe contract has survived one real transport. Retained messages map onto
`isModelBus` / `lastData`, MQTT 5 response topic and correlation data are available if request/reply
is ever wanted back, and user properties cover `arguments` for v5 only.

---

## 9. Open questions

1. §4.1 — `initScope`: option A (`Future<void>`, completes on delivery) or B (synchronous)?
2. §2.1 — is "`false` also means the pipe is over its queue limit" (R7) acceptable in the same
   `bool`, or does it need a distinct signal?
3. §5.6 — does `dart_nats` publish headers? This changes the wire format.
4. Is `errorStream` enough, or does a throwing handler also need to keep its stack trace visible
   in the default logger?
5. Does the existing `EventBusIsolate` keep its name in v3, or is it renamed to reflect that it is
   now one implementation of the pipe?

---

## What next

* [08-transports.md](08-transports.md) — the option analysis behind these decisions.
* [01-architecture.md](01-architecture.md) — the model that survives v3 unchanged.
* [07-caveats.md](07-caveats.md) — the guarantees §3 and §4 have to preserve or explicitly drop.
