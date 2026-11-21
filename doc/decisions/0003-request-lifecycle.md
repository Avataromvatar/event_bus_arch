# ADR-0003: Request lifecycle — timeout and cancellation

- Status: Accepted
- Date: 2026-11-21
- Roadmap: E1-08, E1-09, E2-05, E3-06, E4-02

## Context

`EventBusIsolate.request` wraps the pending future with `Future.timeout`, but the entry in
`_IsolateLink._pending` is removed only when a response arrives or the link is disposed. A request
that times out against a hung worker leaves its completer, topic string and listener chain in the
map forever. A queued request (ADR-0002) adds a second place where a dead wait can remain: the
handler queue on the node.

There is also no way for a caller to cancel a request that is no longer needed.

## Decision

1. `request` accepts both a timeout and a cancellation token:

   ```dart
   Future<dynamic> request<T>(
     T data, {
     List<String>? paths,
     String? separator,
     Map<String, String>? arguments,
     Duration? timeout,
     CancelToken? cancelToken,
   });
   ```

2. `CancelToken` is a small core type:

   ```dart
   class CancelToken {
     bool get isCancelled;
     Future<void> get whenCancelled;
     void cancel([Object? reason]);
   }
   ```

   It composes with timeout; the first of "response", "timeout" and "cancellation" wins.

3. Ownership of cleanup is with the request, not with `Future.timeout`:

   - local request: if the request is in a handler queue, remove it; if it has been dispatched, mark
     the response as unwanted and let the handler finish;
   - isolate request: the pending map entry is removed by a per-request `Timer` or by cancellation;
     a late response with an unknown id is ignored by the protocol;
   - transport request: the reply subscription is always cancelled in `finally`; cancellation
     cancels the wait locally (no broker-side cancellation message in 4.0.0).

4. Exceptions:

   | Situation | Exception |
   |---|---|
   | No matching handler subscription | `NoHandlerException` |
   | Handlers exist but no capacity / queue full / all paused | `BusyException` |
   | Timeout expired | `RequestTimeoutException` |
   | Caller cancelled | `RequestCanceledException` |

   All extend `EventBusException`; `RequestTimeoutException` also carries the topic and duration.

5. If a request is accepted into a queue, listeners are notified and `currentData` is updated at
   that moment (ADR-0002). A later timeout or cancellation does not roll that back; it only
   discards the response.

6. If a request is dispatched and then cancelled/timed out, the handler continues to completion.
   Its result is ignored by the caller; the node may still have updated state at acceptance time.

7. Isolate cancellation: the sender emits a fire-and-forget `_IsolateCancel(id)` (ADR-0005). The
   receiving side removes the request from its queue if it has not been dispatched; otherwise it
   ignores the result. The response, if it arrives, is ignored by the sender because the id is no
   longer pending.

8. No transparent retry. A request that fails because a worker died or was restarted is failed, not
   replayed (ADR-0007); an idempotency-key retry is a later feature.

9. Diagnostics: `pendingRequestCount` (visible for testing) and `EventBusError(kind:
   requestTimeout/requestCanceled)` provide the observability hook. The metrics work (ADR-0006)
   adds queue wait time, dispatch-to-completion time and timeout/cancel counters.

## Consequences

- `_PendingRequest` gains a timer and a completion guard; `Timer` objects are cancelled on every
  terminal path, including `failAllPending` and `dispose`.
- The node queue needs a per-entry handle so timeout/cancellation can remove it in O(1) or O(n)
  with a small queue; the provisional implementation may use a linked list or an id-to-entry map.
- `Future.timeout` is no longer used for isolate requests; the timeout is owned by the link.
- The timeout now includes queue wait time, which must be documented.

## Alternatives considered

- **Keep `Future.timeout` and only remove the pending entry in a timer.** Rejected: two completion
  paths and a retained completer until the worker answers.
- **Return `CancelableOperation` (package:async).** Rejected for 4.0.0: it changes the return type
  and adds a dependency for one concept; `CancelToken` is composable with the existing `Future`.
- **A `RequestHandle` with `cancel()`.** Possible later; the token keeps the API close to today's.
- **Cancel across a broker.** Rejected for 4.0.0: no standard broker primitive; the timeout and an
  optional deadline propagation remain the mechanism.
