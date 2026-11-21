# M3: WorkerPool and supervision

- Status: done
- Started: 2026-11-22
- Finished: 2026-11-22
- Estimate: 22–30 PD (ROADMAP M3)
- Local work report: no task record exists, and `record_create.py` requires a
  parent Feature/User Story; per `agai-sdlc:task-sync`, this file is the allowed
  fallback for work without a linked task.
- YouGile: not configured.
- Decision record: ADR-0007 (implementation notes 2026-11-22).

## Scope

- `WorkerPool`: N `EventBusIsolate`s, lifecycle, readiness, dispose, errors.
- Strategies: `broadcast`, `roundRobin`, `keyed`, `leastBusy`, `single`;
  `broadcast` is forbidden for requests.
- Requests use the same strategy; keyed preserves per-key ordering; a request
  whose worker dies fails and is not retried.
- Backpressure: per-worker request credit; a saturated pool fails fast (`false`
  for fire, `BusyException` for requests); metrics.
- Supervision: death detection, restart with backoff, max restarts per window,
  `supervision` error and a failed pool after the limit; `close()` never
  restarts.
- Layers supervision: a failed worker layer restarts the whole worker chain,
  the top layer survives, bridges re-handshake, pending requests fail.
- Tests: every strategy, worker crash and restart, exhaust, close, whole-chain
  restart, pending failure, no retry.

## Result

- `lib/src/worker_pool.dart`: `WorkerPool`, `DispatchStrategy`,
  `SupervisionPolicy`, `WorkerPoolState`, `WorkerPoolMetrics`,
  `WorkerMetrics`. Round-robin cursor, keyed hash with per-key no-reroute,
  least-busy over in-flight requests, single active-passive failover,
  broadcast fan-out. Request credits via `maxInFlightPerWorker`; no pool-level
  queue in 4.0.0.
- Supervision restarts a dead worker with backoff, prunes the restart window,
  reports `EventBusError(kind: supervision)` and fails the pool after the
  limit. Pending requests fail through the dead isolate, never retried.
- `EventBusIsolate.restart()` restarts a worker in place: the main-side bus,
  nodes, listeners and model state survive; pending requests fail; a new link
  re-handshakes and re-sends interest; a generation counter ignores late
  callbacks and messages of the old worker. The top worker's init error no
  longer disposes the bus, so supervision can retry.
- Worker-side watchdog: every worker pings its parent once a second and kills
  itself without a pong; a dead parent tears down the subtree, so no orphan
  isolates remain.
- `layers.dart`: `_LayerInitDto` is immutable (safe across restarts),
  `_initLayer` forwards a deeper `isolateDeath` up as `_IsolateFailure`,
  `Layers.supervise` returns `LayersSupervisor` (`layer`, `waitInit`,
  `waitReady`, `state`, `restarts`, `errors`, `close`). Any worker failure
  restarts the whole worker chain; the top `Layer`, `current` and
  `layer.bottom` subscriptions survive because the bridge restarts in place.
  Restart exhaustion reports a supervision error, moves to failed and disposes
  the bridge while keeping `layer.current` until close.
- Tests: `test/worker_pool_test.dart` (13), `test/layers_supervision_test.dart`
  (5), `test/event_bus_isolate_restart_test.dart` (3).

## Verification

- `dart test` — 234 passed.
- `dart analyze` — 15 infos: the pre-existing set plus one
  `use_string_in_part_of_directives` for the new part file.
- `packages/event_bus_arch_transport`: 27 passed.
- `packages/event_bus_arch_nats`: 42 passed, 10 skipped (no broker).
- `packages/event_bus_arch_mqtt`: 32 passed, 7 skipped (no broker).
- `dart test -p chrome test/web_smoke_test.dart`: 3 passed.

## Agent work log

- 2026-11-22: task-sync invoked; local report created (same fallback as M2).
  M3 implementation started with the pool core and strategies.
- 2026-11-22: E3-01..E3-07 implemented and tested; ADR-0007 implementation
  notes added, ROADMAP updated. Agents/skills: `agai-sdlc:task-sync`,
  `agai-sdlc:records`; token attribution unavailable (single session, metrics
  not split by task); active time approximately 2026-11-22 00:00 — 03:00 local.
