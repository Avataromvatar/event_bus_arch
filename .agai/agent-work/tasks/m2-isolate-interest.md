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
- `fire`: local delivery plus remote only when the other side has listener
  interest; return true on local acceptance, model storage, transport publish,
  or known remote listener interest.
- `request`: local handler first; remote only when handler interest is known;
  immediate `NoHandlerException` when neither side has a handler.
- `_IsolateCancel` and queued-request removal across the bridge.
- Interest snapshot exchange so `waitInit` sees `onInit` subscriptions.
- Resync after worker death; clear stale remote interest.
- Tests: local/remote/both/none, pattern, cancellation, restart/resync.

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
- `fire` on `EventBusIsolate` and `_EventBusForIsolate`: local delivery first,
  then a remote send only when the other side registered listener or model
  interest (D14). A handler-only node never makes `fire` true.
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
- Tests: `test/event_bus_isolate_interest_test.dart` (16 tests) covers the
  local/remote/both/none matrix, local handler precedence, immediate
  `NoHandlerException`, handler withdrawal, queued cancellation and timeout,
  async-onInit snapshot, `removeTopic` withdrawal and worker death. The Layers
  ping-pong test now uses `down`/`up` paths: with local delivery, a listener that
  echoes on the same bus and the same topic is an infinite loop by construction.

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
