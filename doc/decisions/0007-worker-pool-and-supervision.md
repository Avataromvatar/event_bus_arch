# ADR-0007: WorkerPool and supervision

- Status: Accepted
- Date: 2026-11-24
- Current in: 4.1.1

## Context

An application that processes events in isolates needs a reusable pool: several workers, a routing
policy, a limit on in-flight work, restart after a worker dies and a way to stop the pool without
restarting intentionally closed workers. A worker is an `EventBusIsolate`; its lifecycle and
interest rules are defined in ADR-0005.

## Decision

1. `WorkerPool(onInit:, workers:, dispatch:, maxInFlightPerWorker:, supervision:, ...)` creates
   worker isolates and exposes `waitInit`, `waitReady`, `fire`, `request`, `metrics`, `errors`,
   `close` and `dispose`.
2. Dispatch strategies:
   - `roundRobin` rotates over ready workers;
   - `keyed` routes by address (`keySelector` can override) and never reroutes a key, preserving
     per-key order;
   - `leastBusy` selects the ready worker with the fewest in-flight requests and rotates between
     equal counts;
   - `single` uses one active worker with a ready standby;
   - `broadcast` fires to every ready worker and rejects requests.
3. `maxInFlightPerWorker` is a per-worker request credit. When no worker has a free credit, `fire`
   returns false and `request` throws `BusyException`. The pool has no dispatch queue: callers fail
   fast instead of waiting.
4. Worker death is detected by the isolate exit/port lifecycle. A dead worker is removed from
   routing and restarted with exponential backoff under `SupervisionPolicy`; restart exhaustion
   emits `EventBusErrorKind.supervision` and fails the pool. Intentional `close` is never restarted.
5. A request that was in flight when a worker died fails; it is not retried or rerouted. A handler
   `StateError` reaches the caller unchanged; `BusyException` is reserved for a worker that is not
   ready/disposed or a pool with no capacity.
6. `waitInit` completes when every worker is ready. A worker initialization failure fails the pool;
   `waitReady` waits for a restart to finish. `waitInit`/`waitReady` must not hang on a dead or hung
   worker (ADR-0005's timeout and exit listener apply to each worker).
7. `WorkerPoolMetrics` exposes pool state, worker readiness, fired/accepted/dropped, request and
   restart counters and per-worker in-flight/request counts. Pool errors are emitted as
   `EventBusError` data, not as stream errors.
8. `Layers.supervise` applies the same supervision to a chain of layers; the top layer and its
   subscriptions survive a worker-chain restart.
9. A pool is not an `EventBus`: it has no local nodes, `currentData` or subscription API, and model
   state is per worker rather than aggregated.

## Consequences

- Routing policy is explicit; a key never moves to another worker, even when its worker is busy or
  dead.
- Callers see a fast `BusyException` instead of a hidden queue; backpressure belongs to the caller
  or to the worker handler queue.
- Worker death is observable through `errors` and `metrics`, and restarts are bounded by policy.
- A broken worker initialization is a pool failure, not a partially usable pool.

## Alternatives considered

- **A global pool dispatch queue.** Rejected: hides latency and unbounded memory; callers fail fast
  instead.
- **Reroute a keyed request when its worker is busy.** Rejected: breaks per-key ordering.
- **Retry a request after worker death.** Rejected: possible duplicate side effects; retries need
  an idempotency contract.
- **Silently absorb `StateError` as busy.** Rejected: masks handler bugs and makes diagnosis
  impossible.
