# ADR-0003: Request lifecycle — timeout and cancellation

- Status: Accepted
- Date: 2026-11-24
- Current in: 4.1.0

## Context

A request can wait in a handler queue, run a handler, cross an isolate bridge or wait for a broker
reply. Each path needs one owner for the timeout, cancellation and cleanup; otherwise a timed-out
request leaves a completer, a queue entry or a broker subscription behind.

## Decision

1. `EventBus.request<T>(EventKey<T> key, T data, {arguments, timeout, cancelToken,
   correlationId})` returns `Future<dynamic>` in 4.1.0. A typed response API is a separate design
   decision; it is not implied by this lifecycle record.
2. `CancelToken` has `isCancelled`, `whenCancelled`, `reason`, `addListener`, `removeListener`,
   `listenerCount` and `cancel([reason])`. Listeners are removed on completion, timeout,
   cancellation or close, so a long-lived token does not retain request callbacks.
3. The first terminal event wins: response, timeout or cancellation. A terminal path cancels its
   timer, detaches the token listener, removes a queued entry and completes the caller once.
4. Exceptions:

   | Situation | Exception |
   |---|---|
   | No accepting handler anywhere | `NoHandlerException` |
   | Handlers exist but no capacity/queue room | `BusyException` |
   | Timeout expired | `RequestTimeoutException` |
   | Caller cancelled | `RequestCanceledException` |

5. A queued request cancelled with its handler subscription or node disposal fails with
   `RequestCanceledException`, not `NoHandlerException`. It is not a “no handler” condition and
   must not look retryable as a busy request.
6. An in-flight handler keeps running after a timeout or cancellation; its result is discarded.
   Listeners and `currentData` were updated when the request was accepted and are not rolled back.
7. The local bus routes a request only to a tier with accepting handlers. If there is no accepting
   local handler, an isolate bridge or transport may route it remotely; the local path is not
   selected merely because a foreign-type handler exists at the address.
8. Isolation: a cancelled or timed-out bridge request removes the pending entry and sends
   `_IsolateCancel` to the worker. A late response for an unknown id is ignored.
9. Transport: the caller-side future races the broker request with a `CancelToken`. Cancellation
   fails the caller with `RequestCanceledException`; the underlying broker request continues until
   its own timeout and a late reply is ignored. There is no broker-side cancel message in 4.1.0.
10. No transparent retry. A request that fails because a worker died or a broker is unavailable is
    failed, not replayed. An idempotency-key retry is a later feature.

## Consequences

- Timeout ownership is consistent across local, isolate and transport requests.
- A cancelled request can leave a running handler and a broker request alive; this is explicit,
  bounded by the handler and the broker timeout, and observable.
- `requestQueueCapacity` and `handlerConcurrency` define the queue/busy behavior (ADR-0002).
- The `dynamic` response type keeps the 4.1 API source-compatible but pushes response typing to
  handler/user code; a typed alternative is tracked separately.

## Alternatives considered

- **Rely on `Future.timeout` only.** Rejected: it does not remove queue or pending-map entries and
  can leave the request alive on the other side.
- **Return a `CancelableOperation`.** Rejected for 4.1: it changes the return type and adds a
  dependency for one concept.
- **Broker-side cancellation.** Rejected for 4.1: no standard broker primitive; the caller-side
  future and broker timeout are the contract.
- **Retry a failed request automatically.** Rejected: hidden duplicate execution; retries need an
  idempotency contract.
