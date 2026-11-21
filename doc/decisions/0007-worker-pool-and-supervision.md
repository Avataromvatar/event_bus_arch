# ADR-0007: WorkerPool and supervision

- Status: Accepted
- Date: 2026-11-21
- Implementation notes: 2026-11-22 (the settled API and mechanisms are below)
- Roadmap: E3-01..E3-07

## Context

`EventBusIsolate` runs one worker. `Layers` builds a fixed chain of isolates, one worker per layer.
There is no pool, no dispatch strategy and no recovery: a dead worker fails its pending requests,
and the layer chain is left broken.

The handler unification (ADR-0002) gives competing consumers inside one isolate. A pool adds
competition between isolates.

## Decision

1. `WorkerPool` is a separate type, not an `EventBus` subtype:

   ```dart
   WorkerPool(
     onInit: workerInit,
     workers: 4,
     dispatch: DispatchStrategy.roundRobin,
     requestQueueCapacity: 64,
     supervision: SupervisionPolicy(...),
   );
   ```

   It owns N `EventBusIsolate`s and exposes `fire`, `request`, `close`, `isReady`, `errors` and
   `metrics`.

2. Dispatch strategies:

   - `broadcast` — every event to every worker (state duplication is explicit);
   - `roundRobin` — each event to the next ready worker;
   - `keyed` — hash of a key (default: the topic path, overridable) selects a worker, preserving
     per-key ordering;
   - `leastBusy` — the worker with the fewest in-flight events/requests;
   - `single` — active-passive, failover only.

   `broadcast` is forbidden for requests (`UnsupportedError`/`ArgumentError` at construction or at
   call time; the exact exception is fixed in implementation).

3. Requests are routed by the same strategy. For `keyed`, the key function is shared between fire
   and request. A request that loses its worker to a crash is failed, not retried (ADR-0003).

4. Backpressure: the pool has a bounded dispatch queue and a per-worker credit window. When every
   worker is at capacity, `fire` returns `false` or raises `BusyException` according to the
   configured policy; request callers receive `BusyException` or wait within their timeout.

5. Worker supervision:

   - detect death via isolate exit/port close and ping failures;
   - restart with a backoff policy (reuse `ReconnectPolicy` shape);
   - `SupervisionPolicy(maxRestarts, window, backoff)`; after the limit, the pool emits
     `EventBusError(kind: supervision)` and becomes failed;
   - pending requests fail with a supervision exception; no transparent retry;
   - `close()` marks shutdown as intentional and never restarts.

6. Layers supervision:

   - **Any worker layer failure tears down the whole worker chain.** The top layer — the isolate
     that called `Layers.createLayers` — survives.
   - every worker `EventBusIsolate` in the chain is disposed and recreated;
   - bridges re-handshake, interest registries are re-synchronised (ADR-0005), `onInit` is re-run
     for every restored layer;
   - pending requests fail; no retry;
   - `Layers` exposes a restart state (restarting/ready/failed), a restart counter and an error
     stream; calls during restart fail fast or wait according to a documented policy.

7. API shape (provisional, to settle in implementation): `Layers.supervise(...)` or a controller
   returned alongside the top `Layer`. The top layer remains the owner of the chain and of
   `close()`.

8. Web: `WorkerPool` throws `UnsupportedError` on web (ADR-0008).

## Implementation notes (2026-11-22)

Settled API and the mechanisms chosen where the decision left room:

- `WorkerPool({onInit, workers, dispatch, supervision, maxInFlightPerWorker, initialData,
  initialDataFor, isModelBus, keySelector})`. `initialDataFor(index)` supplies per-worker data;
  `maxInFlightPerWorker` (default 64, null = unlimited) is the request credit of one worker.
  Exposes `fire`, `request`, `close`/`dispose`, `waitInit`, `waitReady`, `isReady`, `isUsable`,
  `state` (`WorkerPoolState`), `restarts`, `errors`, `metrics` (`WorkerPoolMetrics` with per-worker
  counters).
- `broadcast` requests throw `UnsupportedError` at call time. `keyed` uses `key.hashCode` (default
  key: the topic path) and never reroutes a key to another worker, so per-key order survives a
  temporarily unavailable worker as a `false`/`BusyException`, not as an out-of-order delivery.
- Backpressure is the per-worker request credit. When no worker has a free credit, `fire` returns
  `false` and `request` throws `BusyException`. 4.0.0 has no pool-level dispatch queue: callers fail
  fast instead of waiting. `leastBusy` therefore has a real counter to compare.
- `EventBusIsolate.restart()` restarts a worker **in place**: the main-side bus, its local nodes,
  listeners and model state survive; pending requests fail through `_link.failAllPending`; a fresh
  link re-handshakes and both sides re-send their interest snapshots. A generation counter ignores
  every late message and callback of the previous worker.
- A worker-side watchdog pings its parent every second and kills itself when no pong comes. A dead
  parent therefore tears down the rest of the chain instead of leaving orphaned isolates.
- A failure of a deeper layer is forwarded up the chain as `_IsolateFailure` (a message String only:
  the original error object is not guaranteed to be sendable). The top bridge reports it as an
  `isolateDeath`; the supervisor reacts to any `isolateDeath` on the top bridge.
- `Layers.supervise(...)` returns `LayersSupervisor` with `layer`, `waitInit`, `waitReady`, `state`
  (`LayersState`), `restarts`, `errors`, `close`. The top `Layer` object, its `current` bus and the
  subscriptions on `layer.bottom` survive: the bridge is the same object, restarted in place. Calls
  on the bridge fail fast with `StateError` during a restart. The whole worker chain is recreated,
  every `onInit` runs again, and pending requests fail without a retry.
- On restart exhaustion the supervisor emits `EventBusError(kind: supervision)`, moves to
  `failed` and disposes the top bridge while keeping `layer.current` until `close()`.
- The web guard (`UnsupportedError` on web) remains E5-01; on the VM the pool is available.

## Consequences

- The isolate interest protocol (ADR-0005) must support generation-based re-sync; otherwise a
  restarted chain has stale interests.
- `Layers` becomes a supervised object, not just a factory return value; the public API grows.
- Tests must prove whole-chain recovery, not only single-worker recovery.
- The pool duplicates state under `broadcast`; documentation must state that model-bus state is
  per worker and not aggregated.

## Alternatives considered

- **Pool as an `EventBus` subtype.** Rejected: request/broadcast semantics do not match `EventBus`,
  and the substitution would be misleading.
- **Per-layer restart instead of whole-chain restart.** Rejected by decision: a failed layer loses
  its isolate and its bridges; restarting only it leaves the neighbours with dead ports.
- **Transparent request retry.** Rejected: at-most-once semantics and non-idempotent handlers make
  it unsafe by default.
- **Dynamic worker scaling in 4.0.0.** Rejected: the protocol and metrics are not ready; fixed
  pool size first.
