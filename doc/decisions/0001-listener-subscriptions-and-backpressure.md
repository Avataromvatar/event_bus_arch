# ADR-0001: Listener subscriptions and backpressure

- Status: Accepted
- Date: 2026-11-21
- Roadmap: E1-01, E1-02, E1-03, E1-14, E1-15, E1-16

## Context

Today every node owns a single `StreamController<T>.broadcast()`. A subscriber that pauses its
`StreamSubscription`, or an `onData` callback that starts asynchronous work and returns, leaves the
events in an unbounded queue inside the Dart stream. The bus cannot see that queue, cannot bound
it, and cannot apply a policy. The only public signal is `StreamSubscription.pause()`, and no
policy exists for "the consumer is slower than the producer".

The package also re-exports `rxdart` solely for `Stream.doOnCancel`, which couples every consumer
to that dependency and adds a second stream vocabulary to the public API.

## Decision

1. The consumer contract becomes `EventSubscription<T>`, owned by the bus, with listener and
   handler capabilities on the same object (see ADR-0002). The listener side is:

   ```dart
   FutureOr<void> Function(T event) onEvent;
   ```

2. Each listener subscription owns its **bounded or unbounded FIFO buffer**. The node keeps the
   registry and fans an event out to every listener subscription; the subscription decides whether
   to deliver inline, buffer, drop or reject.

3. Buffer settings are per subscription:

   - `bufferCapacity`: `null` = unbounded (compatibility default); `0` = no buffer, inline reject
     when busy;
   - `bufferOverflow`: `latest`, `dropOldest`, `dropNewest`, `reject`;
   - `resize(capacity, {overflow})` changes both at runtime. Shrinking applies the policy
     immediately and reports the dropped count;
   - counters: `buffered`, `dropped`, `delivered`.

4. `pause()` and `resume()` are explicit consumer backpressure. While an asynchronous `onEvent`
   is running, the subscription is **busy**; events arriving in that window go through the buffer
   policy exactly as if it were paused. `isPaused`, `isBusy`, `isCanceled` are read-only.

5. Delivery timing keeps the current semantics by default: the bus schedules delivery in a
   microtask (`DeliveryMode.async`). A `DeliveryMode.sync` option may be selected per
   subscription; it is opt-in and documented as reentrancy-sensitive.

6. Ordering is FIFO per subscription. Across subscriptions, registration order is preserved.
   A `fire` issued from inside `onEvent` is buffered and delivered after the current callback and
   the already buffered events; the drain loop is not re-entered.

7. Overflow is observable: it emits `EventBusError(kind: bufferOverflow)` (ADR-0004) and increments
   the subscription counters. The bus never drops an event silently.

8. Defaults:

   - existing `listen`/`subscribe` keep `unbounded` behavior in 4.0.0;
   - `Scope` uses `latest(1)`;
   - `FSM` uses `unbounded` because transitions must not be lost;
   - `subscribeEvents` (the new control API) defaults to `unbounded`; `latest(1)` is the
     recommended preset for state consumers.

9. The stream facade stays: `listen<T>()` returns `Stream<T>`, `EventSubscription.stream` exposes a
   single-subscription view, and `EventNode.streamControllerValue` remains a legacy facade in 4.0.0
   so transports continue to compile. It is removed in 5.0.0.

10. `rxdart` is removed: the one used method is replaced by native stream/controller machinery and
    the package no longer exports or depends on it.

## Consequences

- `EventNode`/`EventNodeImp` are refactored from "one broadcast controller" to "state + subscription
  registry". `TransportEventNode` delegates to the new node and must be updated in the same change.
- `haveListener` becomes "there is at least one active `onEvent` subscription".
- `removeNode`/`removeTopic` must close subscriptions and clear buffers.
- Per-subscription fan-out adds a small per-event loop; benchmark E1-16 must prove the overhead is
  acceptable and that `unbounded` remains close to the current numbers.
- Users who relied on the rxdart re-export must import rxdart themselves.

## Alternatives considered

- **Ring buffer on the node, shared by subscribers.** Rejected: head-of-line blocking, no
  per-consumer policy, and one slow consumer would affect the others.
- **Keep the broadcast controller and rely on `StreamSubscription.pause()`.** Rejected: the
  internal queue is invisible and unbounded, and an async callback never pauses the stream.
- **Blocking producer (`block` policy).** Deferred: `fire` is synchronous and cannot block. A
  `fireAsync`/credit-window API is a 4.1+ candidate.
- **Keep rxdart for one extension.** Rejected: dependency and API-surface cost for one method.
