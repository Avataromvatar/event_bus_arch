# Defect remediation plan and contract-change analysis

Date: 2026-11-22
Repository: `event_bus_arch`, branch `version4`, package version 4.0.0
Source: third-party review, verified against the code (see
`.agai/agent-work/tasks/76bbb0e5-e2ce-435a-9955-8caae9d943d0-verification.md`)

**Status update (2026-11-22, later):** the project is unpublished, so 3.x compatibility is not a
constraint. Decisions taken:

* **CHG-11a is decided and implemented:** `defaultTopicPathSeparator` is a final constructor
  parameter (`separator:`), the mutable field is gone.
* **REF-01 is decided and implemented:** `FSM`, `Scope` and `Command` moved to the new
  `event_bus_arch_patterns` package; the core no longer exports them.

Part I remains valid; FIX-03 was applied while the FSM file was moved. The other Part I bugs are
unchanged, so the remaining estimate is 4.75 human-days.

**Further status update (2026-11-22):** the address-model decision E is accepted
([ADR-0009](../decisions/0009-event-key-and-address.md)). Consequences for this plan:

* **CHG-11a is superseded:** the separator is removed from the public API entirely (no
  `separator:`, no `defaultTopicPathSeparator`); `EventKey`/`EventPatternKey` own a fixed address
  grammar.
* **FIX-01 becomes structural:** only the node whose key equals the DTO key publishes; supertype
  and pattern nodes deliver locally. The duplicate-publication fix is part of the E rewrite.
* **REF-01 remains**, but FSM/Scope/Command move to the key API as part of the E stages.
* FIX-03 (FSM `try/finally`) is already applied.
* The other Part I fixes (FIX-05, 06, 07, 08, 09, 10) are unaffected by the address model and
  still stand.


This document has two parts:

* **Part I** is an implementation plan for the eight confirmed bugs.
* **Part II** analyses the three findings that were confirmed as behaviour but are
  documented contract or design choices, and states whether changing them is acceptable.

Paths and line numbers refer to the tree at the date above. The code is the source of truth;
re-check the line numbers before editing.

## Verdict recap

| # | Finding | Verdict | This document |
|---|---|---|---|
| 1 | Duplicate `fire` publish when a pattern node has a serializer | Bug | FIX-01 |
| 2 | Offline `fire` throws before local delivery | Documented behaviour | CHG-02 |
| 3 | FSM stuck after a handler throws | Bug | FIX-03 |
| 4 | `leastBusy` sends sequential work to one worker | Algorithm property | No change |
| 5 | Handler `StateError` becomes `BusyException` | Bug | FIX-05 |
| 6 | Worker death during initial start is ignored | Bug | FIX-06 |
| 7 | No init timeout; exit listener registered after spawn | Bug | FIX-07 |
| 8 | `CancelToken.whenCancelled.then` is never detached | Bug | FIX-08 |
| 9 | `_errorWindows` never releases keys | Bug | FIX-09 |
| 10 | `BufferOverflow.latest` and `dropOldest` are the same | API defect | FIX-10 |
| 11 | Mutable configuration after registration | Documented contract | CHG-11 |
| 12 | `NoHandlerException` on subscription cancel/dispose | Documented contract | CHG-12 |

## Ground rules for Part I

1. **Test first.** Every fix starts with a test that fails for the stated reason; the fix
   makes it pass. The verification tests used for the review are a starting point, not the
   final suite.
2. **No public API changes in 4.x bug fixes.** New optional parameters (FIX-07) are a minor
   release; everything else is a patch.
3. **No contract changes in Part I.** Part II lists them separately.
4. Every fix updates `CHANGELOG.md` and the relevant `doc/*.md` page.
5. Run `dart analyze` and `dart test` in the root, `packages/event_bus_arch_transport`,
   `packages/event_bus_arch_nats` and `packages/event_bus_arch_mqtt` before hand-off.

---

# Part I — Bug remediation plan

## FIX-01 — Publish each local `fire` at most once from a transport bus

**Severity:** high (duplicate broker messages; "exactly once" is unreachable).

**Where:**

* `lib/src/event_bus.dart:648` — `_dispatchToListeners` delivers to the exact node and to
  every matching pattern node.
* `packages/event_bus_arch_transport/lib/src/transport_event_node.dart:124-132` —
  `deliver` publishes whenever `serializer != null`.
* `packages/event_bus_arch_transport/lib/src/topic_registry_index.dart:28-35` — `resolve`
  falls back to the type token.

**Root cause.** A pattern node is created by a wildcard subscription. It normally has no
serializer, because wildcard keys are rejected for the serializer registry
(`validatePublishKey`). It does get one through the type-token fallback: a serializer
registered as `'int'` resolves for `int` *and* for `int.sensor.*`. A local `fire` then fans
out to the exact node and to the pattern node, and both publish the same payload to the same
subject.

**Proof.** A scratch test with `serializers: {'int': ...}` and
`deserializers: {'int.sensor.*': ...}` recorded two publishes on `int.sensor.temp` for one
`fire<int>(1, paths: ['sensor', 'temp'])`.

**Fix.** In `TransportEventNode.deliver`, publish only from a concrete node:

```dart
@override
bool deliver(EventDTO dto) {
  final serializer = this.serializer;
  // A pattern node is a subscription. Fan-out from a local fire must not
  // publish the event a second time through it. No publish is lost: the only
  // way a pattern node gets a serializer is the type-token fallback, and the
  // same fallback makes _sendNode create the exact node for the concrete topic.
  final published = serializer != null && !TopicPattern.isPattern(topic);
  if (published) {
    _publish(dto, serializer);
  }
  final local = _local.deliver(dto);
  return published || local;
}
```

Update the class doc comment: a pattern node subscribes and delivers locally; publication is
owned by the exact node.

**Why no publish is lost.** A serializer can be registered only for a concrete topic (exact)
or for a type token (empty paths), because `TopicSubjectMapper.validatePublishKey` rejects
wildcards. A pattern node has `_byTopic[pattern] == null`, so its serializer can only come
from `_byType[type]`. The same `_byType` lookup resolves for any concrete topic of that type,
so `EventBus.fire` → `_sendNode` always creates the exact node, and the exact node publishes.
Add this as an invariant test, not only as a comment.

**Alternatives rejected:**

* *Deduplicate in `_dispatchToListeners` with a marker on the DTO.* Touches the core hot path
  and gives `EventDTO` mutable state that can leak into listeners and serializers.
* *Skip pattern nodes in dispatch.* Breaks local pattern listeners, a documented feature.
* *New core interface for "fan-out without publish".* More public surface for a transport-only
  problem; the node already knows whether its own address is a pattern.

**Tests:**

1. Type serializer + pattern deserializer + pattern listener + `fire` → exactly one publish,
   one local delivery.
2. Exact serializer + pattern deserializer (no type serializer) + `fire` → one publish,
   one local delivery (the pattern node has no serializer).
3. Incoming broker message → zero republishes (existing behaviour, keep the test).
4. Re-create the review's scratch test as the permanent regression test.

**Compatibility:** behaviour fix; no API change. Users who observed duplicates lose them;
this is the intended fix. Note it in `CHANGELOG.md` as a fix.

**Effort:** 0.5 day.

---

## FIX-03 — FSM must not stay stuck after a handler throws

**Severity:** high (the machine silently stops processing every later event).

**Where:** `lib/src/fsm.dart:53-73` (`changeStateStart`, `await node.call`), and
`lib/src/fsm.dart:9` (`_FSM.bus` field).

**Root cause.** `changeStateStart` is set to `true` before `await node.call(...)` and reset
after it. If the handler throws, the async listener callback completes with an error (it goes
to the zone), the reset never runs, and every later event is appended to `_ignoredDTO`
instead of driving a transition. `_ignoredDTO.clear()` is skipped as well.

**Fix.**

```dart
if (node != null && node.check(_state, _lastState, e.$1.data)) {
  changeStateStart = true;
  changeState(node.toState);
  try {
    await node.call(_state, _lastState, e.$1.data, _ignoredDTO);
  } finally {
    _ignoredDTO.clear();
    changeStateStart = false;
  }
}
```

* `finally` guarantees the flag is reset and the ignored list does not leak into the next
  transition.
* The transition is still committed before the handler runs, exactly as documented in
  `doc/04-fsm.md` (`currentState` is the new state). Do not reorder state change and handler:
  that is a separate behavioural decision.
* The handler error still escapes to the zone. Routing it to `bus.errors` (kind `listener`)
  is a possible follow-up, but `reportError` is not on the `EventBus` interface; keep it out
  of this patch and record it as a follow-up.
* Remove the unused `_FSM.bus` field. It is assigned in `initFSM` and never read; the field
  initializer creates an extra `EventBus` per FSM instance.

**Tests:**

1. A throwing handler leaves the state changed, the flag reset, and the next transition still
   runs (the review's scratch test).
2. Events fired while a throwing handler runs are cleared and are not passed to the next
   handler.
3. A normal handler still receives the events that arrived during the transition (existing
   test).

**Compatibility:** no API change; a machine that previously stopped now keeps working.

**Effort:** 0.5 day.

---

## FIX-05 — Do not turn a handler's `StateError` into `BusyException`

**Severity:** medium-high (the caller loses the original error type and stack trace; the
metrics record a bus problem instead of a handler failure).

**Where:** `lib/src/worker_pool.dart:352-364` (`on StateError` around the whole
`await bus.request(...)`), compared with `lib/src/event_bus_isolate.dart:373-375` (handler
errors travel back unchanged).

**Root cause.** The `catch` is intended for one case — the worker died between the readiness
check and the send, so `EventBusIsolate.request` throws
`StateError('EventBusIsolate is not initialized…')`. But it covers the entire await, and a
handler that throws `StateError` crosses the isolate boundary as the same object, so it is
caught and replaced by `BusyException`.

**Fix.** Classify by the bus state at catch time, not by the exception type alone:

```dart
} on StateError catch (error) {
  if (!bus.isInit || bus.isDisposed) {
    _counters.failedRequests++;
    throw BusyException(topic.topic, 'worker ${slot.index} is not ready any more');
  }
  _counters.failedRequests++;
  rethrow;
}
```

`EventBusIsolate.isInit` is the public `_ready` flag; it turns false on death before the
pool's own supervision handles the event. A handler `StateError` leaves the bus initialized,
so it is rethrown unchanged.

**Alternative considered:** wrap remote handler errors in a dedicated marker in
`_IsolateErrorResponse`. Rejected: it changes the public error type that callers already
receive today; the `isInit` check is local and does not change the API.

**Tests:**

1. A worker handler that throws `StateError('handler boom')` → the caller receives
   `StateError`, not `BusyException` (the review's scratch test).
2. A request sent to a dead/not-ready worker → `BusyException` (existing lifecycle tests).
3. A handler that throws a `StateError` while the worker also dies: either error is acceptable;
   assert only that the pool does not hang and the credit is released.

**Compatibility:** a bug fix; code that relied on `BusyException` for a handler failure was
relying on the bug. Note it in `CHANGELOG.md`.

**Effort:** 0.5 day.

---

## FIX-06 — Supervise a worker that dies during the initial start

**Severity:** medium (a narrow race leaves a dead slot marked ready with no restart).

**Where:** `lib/src/worker_pool.dart:521` (`slot.ready = true` inside `_spawn`),
`lib/src/worker_pool.dart:482-487` (`_started = true` only after `Future.wait`),
`lib/src/worker_pool.dart:534-548` (`_handleDeath` returns on `!_started`).

**Root cause.** A slot can become ready before the pool as a whole is started. If its isolate
dies in that window (while another slot still initializes), `_handleDeath` returns early, the
slot keeps `ready = true` and its dead `EventBusIsolate`, and no restart is scheduled. The
claim's effect needs one correction: the pool reports `ready`, not `restarting`, because the
early return happens before `slot.ready = false` and `_updateState()`.

**Fix.** Keep the "initial start owns not-yet-ready workers" rule, but let supervision handle
a worker that is already ready:

```dart
void _handleDeath(_WorkerSlot slot, EventBusIsolate bus) {
  if (_closing || _failed) return;
  if (slot.restarting) return;
  // During the initial start, a worker that never became ready is owned by
  // waitInit/_start. A worker that is already ready needs supervision now.
  if (!_started && !slot.ready) return;
  ...
}
```

`_start` may set `_started = true` while the first restart is in flight; `_updateState`
already reports `restarting` when part of the pool is ready, so this is consistent.

**Alternatives rejected:**

* *Set `_started = true` per slot.* Changes the meaning of the flag and makes `_start`
  failure handling ambiguous.
* *Rely on `waitInit`.* It has already completed successfully for the dead slot; a death
  after readiness is not reported there.

**Tests.** Use a deterministic two-worker setup to widen the window:

* worker 0: `onInit` returns, then kills its isolate after a short timer;
* worker 1: `onInit` awaits a longer delay (for example 300 ms).

With `workers: 2`, worker 0 dies while `_start` is still waiting for worker 1. Assert that
worker 0 is restarted (or that the pool reports it not ready and schedules a restart) instead
of staying silently ready. Keep the test's timings generous to avoid flakiness; the window is
widened by worker 1's delay, not by scheduler luck.

**Compatibility:** no API change. Supervision now applies in a case it previously missed.

**Effort:** 1 day (mostly the deterministic test).

---

## FIX-07 — Bound initialization and close the exit-listener race

**Severity:** medium (a hung `onInit` blocks start forever; a worker that dies before the
listener registration is never reported).

**Where:** `lib/src/event_bus_isolate.dart:452` (`waitInit` getter),
`lib/src/event_bus_isolate.dart:701-718` (`_init`: `await Isolate.spawn`, then
`addOnExitListener`), `lib/src/worker_pool.dart:517` (`await bus.waitInit`, no timeout).

**Root cause.**

* `waitInit` completes only on ready, init error, death or dispose. A worker whose `onInit`
  never completes sends none of those; `WorkerPool._spawn` waits forever and the pool stays in
  `starting`. `Layers.createLayers` and `Layers.supervise` already accept a timeout; the pool
  does not.
* The Dart SDK documents that `addOnExitListener` registered after spawn may miss the exit
  message: "Since isolates run concurrently, it's possible for it to exit before the exit
  listener is established, and in that case no response will be sent… start the isolate
  paused, add the listener and then resume the isolate."

**Fix A — init timeout.** Add an optional `Duration? initTimeout` to `WorkerPool` (default
`null` keeps the current behaviour; document a recommended value). In `_spawn`:

```dart
final ready = initTimeout == null
    ? await bus.waitInit
    : await bus.waitInit.timeout(initTimeout!, onTimeout: () => false);
if (!ready) {
  throw EventBusException('worker ${slot.index} did not become ready'
      '${initTimeout == null ? '' : ' within $initTimeout'}');
}
```

Do not change `EventBusIsolate.waitInit` from a getter to a method; callers can already apply
`.timeout()` themselves, and `Layers` does.

**Fix B — spawn paused.** In `_init`:

```dart
final isolate = await Isolate.spawn(
    _worker, [receivePort.sendPort, onInit, _initialData, _workerIsModelBus],
    paused: true);
if (generation != _generation || isDisposed) {
  isolate.kill(priority: Isolate.immediate);
  return;
}
_isolate = isolate;
isolate.addOnExitListener(receivePort.sendPort, response: _isolateExitMessage);
receivePort.listen(...);
isolate.resume(isolate.pauseCapability!);
```

The worker runs no user code before the listener is in place. Keep the generation check and
the `receivePort.listen` registration before `resume`.

**Tests:**

1. A worker whose `onInit` never completes + `initTimeout: 100 ms` → `pool.waitInit` fails
   with `EventBusException`; the pool does not hang; `close()` still works.
2. A worker that terminates immediately (before sending its `SendPort`) → `waitInit` fails
   (or returns false) instead of hanging: the exit message is delivered thanks to the paused
   spawn.
3. Existing isolate restart, interest and supervision tests stay green.

**Compatibility:** the new constructor parameter is optional; no behaviour change without it.
Reserve `unawaited`/timer cleanup for timers created by `.timeout()`; the returned future is
already bounded.

**Effort:** 1 day.

---

## FIX-08 — Detach cancellation callbacks from a long-lived `CancelToken`

**Severity:** medium (memory retained per completed request for the lifetime of the token).

**Where:** `lib/src/event_subscription.dart:491-510` (`CancelToken`),
`lib/src/event_subscription.dart:568-586` (`_RequestEntry.arm`),
`lib/src/event_bus_isolate.dart:240-245` (`EventBusIsolate.request`).

**Root cause.** `whenCancelled` exposes the `Completer` future. `.then(...)` adds a listener
that cannot be removed; it lives until the token is cancelled. A token shared by many
requests accumulates one closure per completed request, retaining the completer, the DTO and
the entry.

**Fix.** Keep the public `whenCancelled` future for users, and add an internal cancelable
hook used by the two call sites (both are in the same library, so the hook can be private):

```dart
class CancelToken {
  final _cancelled = Completer<void>();
  final _listeners = <void Function()>[];

  _CancelHook onCancel(void Function() listener) { ... }
  void _removeListener(void Function() listener) { ... }

  void cancel([Object? reason]) {
    if (_cancelled.isCompleted) return;
    _reason = reason;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    _cancelled.complete();
    for (final listener in listeners) {
      listener();
    }
  }

  ///Visible for tests.
  int get listenerCountForTest => _listeners.length;
}
```

`_CancelHook` holds the token and the callback and removes it from `_listeners` on `cancel()`.
Call sites:

* `_RequestEntry.arm`: store `_CancelHook? _cancelHook`; attach it after the timeout setup;
  call `_cancelHook?.cancel()` in `run`'s `finally`, in `cancel()` and in `fail()`.
* `EventBusIsolate.request`: store the hook on `_PendingRequest`; call it in `_takePending`
  (the single place that removes a pending entry) so every completion path detaches it.

**Alternative considered:** replace the completer with a broadcast stream and use
subscriptions. It works but changes more public behaviour and does not preserve
`whenCancelled` semantics as simply. The hook keeps the API intact.

**Tests:**

1. Complete N requests with the same token → `token.listenerCountForTest == 0`.
2. Cancel a queued request → the hook is removed exactly once; a later normal completion does
   not call the cancel path twice.
3. The existing cancellation tests (`event_subscription_test`, `event_bus_isolate_*`) stay
   green.

**Compatibility:** additive/internal; `whenCancelled` and `cancel` keep their signatures.

**Effort:** 1 day.

---

## FIX-09 — Bound `_errorWindows`

**Severity:** medium (unbounded memory with dynamic error topics; contradicts ADR-0004).

**Where:** `lib/src/event_bus.dart:310` (`_errorWindows`),
`lib/src/event_bus.dart:331-354` (`reportError`), `lib/src/event_bus.dart:813` (`clear` on
dispose).

**Root cause.** A key is created with `putIfAbsent` and never removed. The one-second window
is cleaned inside a key; keys themselves survive forever, including after errors stop. ADR-0004
requires "no unbounded growth", so this is a defect rather than a rate-limit trade-off.

**Fix.** Add a hard cap with amortized pruning:

```dart
static const int _maxErrorWindows = 1024;

void _pruneErrorWindows(DateTime now) {
  _errorWindows.removeWhere((_, window) {
    window.removeWhere((time) => now.difference(time) > const Duration(seconds: 1));
    return window.isEmpty;
  });
}

void reportError(EventBusError error) {
  ...
  if (_errorWindows.length >= _maxErrorWindows) {
    _pruneErrorWindows(now);
  }
  if (_errorWindows.length >= _maxErrorWindows) {
    // Hard cap: the insertion-ordered map drops the oldest key.
    _errorWindows.remove(_errorWindows.keys.first);
  }
  final window = _errorWindows.putIfAbsent(key, () => <DateTime>[]);
  ...
}
```

The cap is a safety valve, not a normal path: a bus with more than 1024 distinct error topics
in one second is already an incident. Optionally add a periodic sweep only if a profiler shows
stale-key accumulation matters; do not add a timer to the hot path without need.

**Tests.** Emit errors for more than `_maxErrorWindows` distinct topics and assert the map
size stays at or below the cap. A test-only getter (`errorWindowCountForTest`) is needed; keep
it clearly marked.

**Compatibility:** internal; no API change. Document the cap in `doc/12-observability.md`.

**Effort:** 0.5 day.

---

## FIX-10 — Make the overflow-policy API honest

**Severity:** low (misleading API; no wrong data at runtime).

**Where:** `lib/src/event_subscription.dart:7-19` (enum docs),
`lib/src/event_subscription.dart:372-401` (`_bufferEvent`),
`lib/src/event_subscription.dart:322-341` (`resize`).

**Root cause.** For a bounded FIFO, "keep the newest N" and "drop the oldest buffered event"
are the same operation: `removeFirst` + `addLast`. Both enum values execute the shared branch.

**Options:**

1. **Document them as aliases now, choose a survivor in 5.0.** No behaviour change, no
   deprecation warnings; docs stop implying a difference. Lowest risk.
2. **Deprecate one value now.** `@Deprecated` on an enum value produces warnings in user code
   and forces doc/test churn; a 4.x patch with deprecation warnings is noisy.
3. **Give `latest` a distinct meaning** ("replace the whole buffer with the newest event").
   Breaks the documented "keep the newest `bufferCapacity` events" and existing users.

**Recommendation:** option 1 for 4.x. Update the enum dartdoc and
`doc/01-architecture.md`, `doc/02-event-bus.md`, `doc/11-backpressure.md` to say that `latest`
and `dropOldest` are the same policy. In 5.0, keep one canonical value and remove the other
with a migration note. `Scope` uses `latest(1)`; changing it is part of the 5.0 decision, not
this patch.

**Tests:** a test that documents the equivalence (same buffer contents for both policies);
no production code change.

**Compatibility:** none in 4.x; the 5.0 removal is breaking and belongs in the migration guide.

**Effort:** 0.25 day.

---

## Implementation order and releases

| Order | Fix | Release | Why this order |
|---|---|---|---|
| 1 | FIX-03 (FSM) | 4.0.1 | isolated, high user impact, smallest diff |
| 2 | FIX-01 (transport duplicate) | 4.0.1 | isolated package, high impact |
| 3 | FIX-09 (`_errorWindows`) | 4.0.1 | internal, no API change |
| 4 | FIX-05 (`StateError`) | 4.0.1 | worker pool, no API change |
| 5 | FIX-10 (overflow docs) | 4.0.1 | docs only |
| 6 | FIX-08 (`CancelToken`) | 4.1.0 | internal hooks, test hook |
| 7 | FIX-06 (start race) | 4.1.0 | supervision behaviour, deterministic test |
| 8 | FIX-07 (init timeout, paused spawn) | 4.1.0 | new optional parameter |

FIX-06 and FIX-07 touch the same start path; implement them together and test both orders:
death during start, and a hung init with and without a timeout. FIX-05 should land before
FIX-06 so the "dead slot" failures are visible as `BusyException` during the transition, then
FIX-06 removes the dead slot.

Total estimate for Part I: **5.25 human-days** (code, tests, docs, changelog).

---

# Part II — Contract-change analysis

The three remaining findings are facts about the code, but each is either documented or is a
deliberate design choice. The question is not "is the code like this" (it is) but "should the
contract change". Use three categories:

* **Keep** — the current contract is defensible; changing it would make the API worse or
  break users for no proven benefit.
* **Acceptable in 4.x** — a compatible hardening that does not change documented semantics.
* **Major (5.0)** — a breaking semantic/API change that needs a migration note.

## CHG-02 — Offline `fire` and local delivery

**Current contract.** `TransportEventNode.deliver` publishes before delivering locally; when
the connection is not connected, `_publish` throws `TransportServerUnavailableException`, so
local listeners do not see the event and `currentData` is not updated. This is documented in
the node's dartdoc ("fires publish to the server before delivering locally") and follows from
the transport design: `ReconnectingTransportConnection.publish` throws when offline, and
nothing is buffered. `doc/09-event-bus-nats.md:194-196` states the decision explicitly:
`buffer: false` is used because a message written while offline "would be queued and reported
as sent, which contradicts the bus's contract; the adapter throws instead."

**Is this a defect?** No under the current contract. It is fail-fast: the caller learns that
the event did not reach the broker. The cost is that a transport bus is not usable as a local
bus while the broker is down.

**Options:**

| Option | Behaviour | Pros | Cons | Compatibility |
|---|---|---|---|---|
| A. Keep | Publish first; throw offline; no local delivery | Fail-fast; no false confidence; matches the documented design | Broker outage blocks local listeners on a transport bus | Current |
| B. Local-first | Deliver locally always; attempt publish; report failures on `errors` | Local listeners unaffected; state keeps updating | `fire` may return `true` while remote subscribers got nothing; changes the meaning of the return value | Breaking → 5.0 |
| C. Local fallback | Try publish; on unavailability deliver locally, report the error, return local acceptance | Best effort without throwing | Same "true but not delivered" ambiguity as B; two paths to test | Breaking → 5.0 |
| D. Offline outbox | Queue publishes while disconnected; flush on reconnect | Real resilience | Memory bounds, ordering, dedup, replay semantics, at-most-once mismatch; a feature, not a fix | Feature → 5.0+ |

**Recommendation: A for 4.x.** The transport bus is a mirror, not a local bus; the documented
contract is coherent, and a local-first change would silently weaken the only signal that a
publish failed. Add an explicit caveat to `doc/07-caveats.md`: "On a transport bus, `fire`
requires an established connection; local delivery is not a fallback. Use a local `EventBus`
when local delivery must survive broker downtime." If resilience is required, plan option D
as a separate feature with a bounded queue, a drop policy, metrics and a replay contract; do
not smuggle it in as part of this review.

**Acceptability:** keeping is acceptable now. B/C are acceptable only as an explicit 5.0
contract decision; D is a roadmap feature. **Decision owner:** product/architecture.

## CHG-11 — Mutable configuration after registration

This finding has three independent parts; treat them separately.

### CHG-11a — `defaultTopicPathSeparator`

**Original contract.** A public mutable field on `EventBusMixin`
(`lib/src/event_bus.dart:281`), used as the fallback in every address method. Changing it
after nodes exist made calls without an explicit `separator` address different topics. This
was documented with an example in `doc/06-api-reference.md:391-402`.

**Options:**

1. Keep as-is for 4.x; document the pitfall in `doc/07-caveats.md`.
2. Deprecate the setter in 4.x (`@Deprecated` on the setter) while keeping the field readable.
   Warnings in user code, but no break.
3. Make it a constructor argument and `final` now.

**Decision (2026-11-22): option 3, implemented.** The project is unpublished, so the breaking
change is free. `EventBus`, `EventBusImpl`, `EventBusIsolate` and `WorkerPool` take
`separator:`; `defaultTopicPathSeparator` is a final field on `EventBusImpl`. `EventBusIsolate`
forwards the separator to the worker-side bus, so interest keys and topics agree on both sides
of the bridge. `TransportEventBus` keeps `.` because the wiring grammar requires it.

**Acceptability:** done, then superseded by ADR-0009. The `separator:` parameter and
`defaultTopicPathSeparator` were removed from `EventBus`, `EventBusImpl`, `EventBusIsolate` and
`WorkerPool` during stage 7b-core; the address grammar is the `EventAddress.separator` constant.
`doc/02`, `doc/06`, `README.md` and `CHANGELOG.md` were updated again for the final API.

### CHG-11b — `Topic.paths`

**Current contract.** `TopicImpl` stores the list it was given (`lib/src/topic.dart:79-87`);
the hash and the routing key are recomputed from it. The API reference explicitly says:
"`paths` is held as passed, not copied. Do not mutate the list you handed in"
(`doc/06-api-reference.md:105`).

**Options:**

1. Keep and rely on the contract.
2. Defensive copy: `paths = List.unmodifiable(paths)` in `TopicImpl` (with a `const []` fast
   path for empty paths) and let `copy` pass a fresh list. Mutation throws instead of
   corrupting a map key.
3. Document only.

**Recommendation: 2, acceptable in 4.x.** The documented rule already forbids mutation; making
the forbidden operation throw is a hardening, not a semantic change. Measure the per-event
cost first: `Topic.create` runs for every `EventDTO`, so a copy per event is on the hot path.
Use `const []` when `paths.isEmpty` and `List.unmodifiable` only for non-empty lists. Run
`benchmark/` before/after; if the regression is measurable, keep option 1 and add an assert
in debug builds instead.

**Acceptability:** 4.x yes, subject to the benchmark. No public signature change.

### CHG-11c — Mutable `EventDTOImpl` fields

**Current contract.** `topic`, `data` and `arguments` are public mutable fields
(`lib/src/event_dto.dart:55-65`); the API reference lists them. `arguments` is also a shared
mutable map.

**Options:**

1. Keep; document that a DTO must be treated as immutable once delivered.
2. Add `copyWith`-only construction in 5.0: private fields, final, `arguments` copied or
   unmodifiable.
3. Add a debug assert/report when a delivered DTO is mutated (not practical without paying for
   wrappers).

**Recommendation:** 1 now, 2 in 5.0. Making the fields final is a source-breaking change for
any user who sets `dto.data`; it belongs to a major release. In 4.x, add the "treat as
immutable after delivery" note to the `EventDTO` section of `doc/06-api-reference.md`.

**Acceptability:** keep now; breaking in 5.0.

## CHG-12 — `NoHandlerException` when a subscription is cancelled or disposed

**Current contract.** `_failQueuedRequests` fails queued requests with
`NoHandlerException(topic)` (`lib/src/event_subscription.dart:249-255`), called from
`cancel()` and `_close()`; `_RequestEntry.fail` maps it to `RequestOutcome.noHandler`. The
behaviour is documented (`doc/06-api-reference.md:300`) and pinned by
`test/handler_subscription_test.dart:403-429`.

**Is this a defect?** It is a semantic mismatch, not an accidental bug: the subscription had
a handler when the request was accepted, and "cancelled" is not "no handler". But the current
behaviour is a documented contract; changing the type silently would break callers that catch
`NoHandlerException`.

**Options:**

| Option | Behaviour | Pros | Cons | Compatibility |
|---|---|---|---|---|
| A. Keep | `NoHandlerException` | Documented; distinguishes "no responder" from "caller timed out" | Misleading type and metric outcome | Current |
| B. Change to `RequestCanceledException` in 5.0 | Queued requests fail as cancelled | Semantically right; matches `timeout`/`CancelToken` | Breaking for `catch (NoHandlerException)`; outcome metric changes | Major |
| C. 4.x compatible detail | Keep the type; add an optional `reason`/`cause` to `NoHandlerException` | Callers can inspect why; no break | Still the wrong type; extra surface | Compatible |
| D. New `SubscriptionClosedException` in 5.0 | Dedicated type for "the responder went away" | Most precise | One more exception type; migration | Major |

**Recommendation: A now, B in 5.0** (option D only if "cancelled by the caller" and "the
subscription was disposed" must be distinguishable — they have different causes). If a
compatible improvement is wanted in 4.x, C is acceptable: an optional `cause` field on
`NoHandlerException`, set to `RequestCanceledException` by `_failQueuedRequests`, documented
in the API reference. Do not change `RequestOutcome` in 4.x: adding an enum value breaks
exhaustive switches, and changing `noHandler` to `canceled` changes metrics semantics.

**Acceptability:** A acceptable now; C acceptable as an additive diagnostic; B/D only in
5.0 with a migration note.

---

## REF-01 — Move FSM, Scope and Command to `event_bus_arch_patterns`

**Decision (2026-11-22):** do it now. The core package should stay a routing library; FSM, Scope
and Command are higher-level patterns and do not belong in it. Since the project is unpublished,
the breaking move is free.

**What was done:**

* New workspace package `packages/event_bus_arch_patterns`, version `0.1.0`, depending only on
  `event_bus_arch: ^4.0.0` (no cycle).
* `fsm.dart`, `scope.dart` and `command.dart` moved from `lib/src/` to the new package, converted
  from `part of event_arch` to normal libraries with imports of the core public API. They use no
  core private members, so no core API had to be widened.
* Core `lib/event_bus_arch.dart` no longer includes the three parts; the core package no longer
  exports `FSM`, `Scope` or `Command`.
* Tests moved: `fsm_test.dart`, `command_scope_test.dart`, and the FSM/Scope/Command naming
  groups from `naming_test.dart`; the core keeps the bus/isolate/layers/logger naming groups.
* Examples moved: `event_bus_fsm_example.dart` and `event_bus_migration_target_example.dart`.
  They cannot stay in the core `example/` folder: the core would need a dev-dependency on the
  patterns package, which would create a cycle.
* The FSM fix (FIX-03) was applied while moving: `try/finally`, ignored-events cleanup, and the
  unused `_FSM.bus` field removed.
* Docs updated: `doc/04-fsm.md` and `doc/05-scope-and-command.md` point at the new package;
  `doc/06-api-reference.md` has a patterns section; `README.md`, `doc/README.md`,
  `doc/01`, `doc/02`, `doc/07`, `doc/14`, `doc/15`, `CHANGELOG.md` and `RELEASE.md` updated.
* New package README, CHANGELOG and LICENSE.

**Verification:**

```
dart analyze                  # no errors or warnings
dart test                     # core: 235
(cd packages/event_bus_arch_patterns && dart test)   # 20
(cd packages/event_bus_arch_transport && dart test)  # 28
(cd packages/event_bus_arch_nats && dart test)       # 42 + 10 skipped
(cd packages/event_bus_arch_mqtt && dart test)       # 32 + 7 skipped
```

**Package naming.** `event_bus_arch_patterns` was chosen because the package contains three
patterns, not only FSM; `event_bus_arch_fsm` would misdescribe it. Rename before the first publish
if a different name is preferred; nothing in the core depends on the name.

**Not moved:** `EventBusLogger` (it is a bus-level tracing helper and uses no pattern types) and
`Layers` (isolate infrastructure).

## Decisions needed

| ID | Decision | Recommendation | Impact if changed | Owner |
|---|---|---|---|---|
| CHG-02 | Should a transport `fire` deliver locally while offline? | Keep fail-fast; document the caveat; outbox is a separate feature | Breaking semantic; broker-loss signal changes | Product / architecture |
| CHG-11a | Make the separator immutable? | **Decided 2026-11-22: constructor + final (done)** | Implemented; no further migration | Architecture |
| CHG-11b | Defensive-copy `Topic.paths`? | Yes in 4.x, subject to a benchmark | Compatible hardening; mutation starts throwing | Dev |
| CHG-11c | Make DTO fields final? | 5.0, or now if the breaking change is accepted | Source-breaking | Architecture |
| CHG-12 | Change the cancel/dispose error type? | Keep in 4.x; `RequestCanceledException` in 5.0 | Breaking for catch blocks and metrics | Architecture / QA |
| REF-01 | Move FSM/Scope/Command out of the core | **Decided 2026-11-22: done** | Implemented; core no longer exports them | Architecture |

No contract change is required to ship the Part I bug fixes. Part I can proceed while these
decisions are open.

## Verification

For every fix and contract change:

```bash
dart analyze
dart test
(cd packages/event_bus_arch_transport && dart test)
(cd packages/event_bus_arch_nats && dart test)
(cd packages/event_bus_arch_mqtt && dart test)
```

Re-create these as regression tests first; the review's scratch tests were deleted after the run, so the list below is the required behaviour, not a file to reuse:

* duplicate publish (FIX-01): one `fire`, two publishes on the same subject;
* FSM stuck (FIX-03): throwing handler, next transition never runs;
* `StateError` masking (FIX-05): handler error arrives as `BusyException`;
* `leastBusy` (no fix): sequential requests all go to slot 0;
* offline fire (CHG-02): `TransportServerUnavailableException`, no local delivery.

For the race fixes (FIX-06, FIX-07) prefer a deterministic setup over timing loops: widen the
window with a slow second worker or a never-completing `onInit`; do not assert on wall-clock
scheduling without such a seam.
