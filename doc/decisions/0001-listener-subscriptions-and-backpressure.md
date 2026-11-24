# ADR-0001: Listener subscriptions and backpressure

- Status: Accepted
- Date: 2026-11-24
- Current in: 4.1.0

## Context

A node used to expose one `StreamController<T>.broadcast()`. When a consumer paused its stream
subscription, or an asynchronous `onEvent` callback was still running, the events accumulated in
the Dart stream queue. The bus could not see that queue, bound it, or apply a policy. The only
public signal was `StreamSubscription.pause()`.

The package also depended on `rxdart` solely for `doOnCancel`, which coupled consumers to an extra
stream vocabulary. Delivery behavior has to be explicit because a slow listener must not grow
memory without bound and a fast producer must not silently lose events without a counter.

## Decision

1. `subscribe(selector, onEvent: ...)` creates an `EventSubscription<T>` owned by the bus. The
   subscription owns its delivery state: buffer, pause flag, busy flag, counters and errors.
2. `listen(selector)` returns the raw node stream. It has no bounded buffer, overflow policy,
   counters or subscription error routing; it is the simple stream view.
3. Each managed listener subscription owns a FIFO buffer with these settings:

   - `bufferCapacity` defaults to **1024**. `null` means explicitly unbounded; `0` means no
     backlog and an event that cannot be delivered immediately is handled by the overflow policy.
   - `BufferOverflow.latest` discards the entire stale backlog when the buffer is full and keeps
     only the newest event. `dropOldest` is a sliding window: one old event is removed for each
     incoming event. `dropNewest` drops the incoming event and `reject` reports it as not accepted.
   - `resize(capacity, {overflow})` changes the setting at runtime; shrinking applies the policy
     immediately and counts the dropped events.
   - `buffered`, `dropped` and `delivered` expose the counters.

4. `DeliveryMode.async` is the default and schedules the callback in a microtask. `DeliveryMode.sync`
   invokes it inline in `fire` and is documented as reentrancy-sensitive. Ordering is FIFO per
   subscription; registration order is preserved across subscriptions.
5. `pause()` stops listener delivery and `resume()` drains the buffer. While an asynchronous
   `onEvent` is running the subscription is busy; events arriving in that window go through the
   same buffer policy. An idle event occupies a pending slot that is not charged against capacity.
6. A listener error is reported as `EventBusError(kind: listener)` and optionally through the
   subscription's `onError`/`cancelOnError`. It does not break the node or the other listeners.
7. `cancel()` clears the buffer, cancels queued requests and closes the `.stream` view. When the
   last subscription and raw listener leave a common node, the node is detached. A model bus keeps
   the value; a transport node also detaches and cancels its broker subscription.
8. `rxdart` is neither a dependency nor a re-export. The small cancellation hook is implemented by
   the core.

## Consequences

- A slow consumer is bounded by default and has an observable overflow policy.
- The buffer default is not compatible with the old unbounded behavior: code that relied on an
  unlimited listener queue must pass `bufferCapacity: null` explicitly.
- `latest` is deliberately not a sliding window; it represents “state consumers only need the
  newest value” and may drop several queued events at once.
- The node fans out to subscriptions; the subscription, not the node, decides whether to accept,
  buffer, drop or reject an event.

## Alternatives considered

- **Keep the broadcast controller and rely on `StreamSubscription.pause()`.** Rejected: the queue
  is invisible and unbounded, and an async callback does not pause the stream.
- **A single ring buffer shared by all listeners.** Rejected: one slow consumer would create
  head-of-line blocking for everyone.
- **Always unbounded for compatibility.** Rejected: hidden memory growth and no overflow signal;
  `null` remains available for explicit opt-in.
- **A blocking producer policy.** Deferred: `fire` is synchronous; a credit-window API is a later
  feature.
