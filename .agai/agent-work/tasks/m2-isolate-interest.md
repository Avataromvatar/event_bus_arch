# M2: isolate interest sync and fire/request semantics

- Status: done
- Started: 2026-11-21
- Finished: 2026-11-22
- Estimate: 18 PD (ROADMAP M2)
- Local work report: no task record exists, and `record_create.py` requires a
  parent Feature/User Story; per `agai-sdlc:task-sync`, this file is the allowed
  fallback for work without a linked task.
- YouGile: not configured.

## Scope

- Interest registry: listener/handler, exact and pattern topics.
- `fire`: outbound only on a bridge; a remote send happens only when the other
  side has listener or model interest; no local echo, so a same-topic
  forwarding listener cannot re-enter itself. Return true only for known remote
  interest (a handler-only node does not count).
- `request`: local handler first; remote only when handler interest is known;
  immediate `NoHandlerException` when neither side has a handler.
- `_IsolateCancel` and queued-request removal across the bridge.
- Interest snapshot exchange so `waitInit` sees `onInit` subscriptions.
- Worker death detection; clear stale remote interest.
- Tests: remote/no-interest, outbound direction, same-topic echo, pattern,
  cancellation, worker death.

## Acceptance

- `fire` does not send an event to a side with no listener interest and does
  not return true for it.
- A request with no handler on either side fails without waiting for a timeout.
- Cancelling a request on the main side removes a queued request on the worker.
- `waitInit` completes only after the worker's interests are known.
- All existing and new tests pass; README/ROADMAP status updated.

## Result

- `_IsolateInterest` (listener/handler/model, exact/pattern, `present`) and
  `_RemoteInterest` with pattern matching; interest is sent on the first
  subscription and the last cancellation, on model-node creation, on topic
  removal, and as a snapshot on both handshake sides.
- `fire` on `EventBusIsolate` and `_EventBusForIsolate` is outbound only: local
  listeners receive incoming events, a fired event is never delivered back to
  the side that fired it. The event is sent only when the other side registered
  listener or model interest (D14); a handler-only node never makes `fire` true.
  Local pub/sub belongs to a local `EventBus` (`Layer.current` in Layers).
  This is the 2026-11-22 revision of ADR-0005: the first M2 version delivered a
  bridge fire locally too, which made a same-topic forwarding listener re-enter
  itself endlessly.
- `request`: a local handler is checked first; otherwise a known remote handler
  is required, and the absence of both throws `NoHandlerException` without a
  round trip.
- `_IsolateCancel`: timeout and `CancelToken` on the caller side remove the
  pending entry and withdraw a queued request in the worker; a response to a
  cancelled request is ignored.
- Worker death: detected with `Isolate.addOnExitListener` (a `ReceivePort` does
  not fire `onDone` when the other isolate dies); pending requests fail with
  `EventBusException`, remote interest is cleared and `isolateDeath` is reported.
  Generation-based re-sync belongs to E3-06 because restart is M3.
- Tests: `test/event_bus_isolate_interest_test.dart` (16 tests) covers fire with
  and without remote interest, outbound-only delivery, the same-topic echo that
  must not re-enter its listener, local handler precedence, immediate
  `NoHandlerException`, handler withdrawal, queued cancellation and timeout,
  async-onInit snapshot, `removeTopic` withdrawal and worker death. The Layers
  ping-pong test uses the same topic in both directions as the regression for
  the directional bridge.

## Verification

- `dart test` — 213 passed.
- `dart analyze` — 14 infos, unchanged pre-existing set.
- `packages/event_bus_arch_transport`: 27 passed.
- `packages/event_bus_arch_nats`: 42 passed, 10 skipped (no broker).
- `packages/event_bus_arch_mqtt`: 32 passed, 7 skipped (no broker).
- `dart test -p chrome test/web_smoke_test.dart`: 3 passed.

## Agent work log

- 2026-11-21: task-sync invoked; no task record or YouGile project found; local
  report created. M2 implementation started.
- 2026-11-22: M2 implementation and tests completed; ROADMAP E2-01..E2-07
  marked done. Agents/skills: `agai-sdlc:task-sync`, `agai-sdlc:records`;
  session token attribution unavailable (single session, metrics not split by
  task); active time tracked approximately 2026-11-21 20:00 — 2026-11-22 00:00
  local.
- 2026-11-22 (revision): the user rejected the local delivery of `fire` on a
  bridge: a listener that fires the same topic re-enters itself. `fire` was
  returned to the 3.x outbound-only port semantics, ADR-0005 was revised, and
  the Layers ping-pong was restored to one topic. Re-run after the revision:
  core 213 passed; transport 27, NATS 42 (+10 skipped), MQTT 32 (+7 skipped),
  Chrome 3 passed; analyzer 14 infos (unchanged).
