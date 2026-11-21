# ADR-0007: WorkerPool and supervision

- Status: Accepted
- Date: 2026-11-21
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
