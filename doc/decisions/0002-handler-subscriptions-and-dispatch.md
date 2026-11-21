# ADR-0002: Handler subscriptions and request dispatch

- Status: Accepted
- Date: 2026-11-21
- Roadmap: E1-04, E1-05, E1-06, E1-07, E1-09, E1-10, E1-11, E1-12, E1-15

## Context

Handlers currently live in a second registry, `Map<Topic, RequestHandler>`, separate from nodes and
subscriptions. That registry has its own rules:

- one handler per topic; a repeated `setHandler` replaces the previous one;
- a handler pins the node (`_hasHandlerFor`), even when no listener exists;
- `handlerTopicFor` exists only to make transports answer once when an exact and a pattern
  subscription overlap;
- there is no way to have competing handlers for one topic.

The separation is the largest remaining conceptual split in the core: two registries, two
lifecycles, two answers to "does this topic have a consumer".

## Decision

1. A handler is a capability of `EventSubscription<T>`:

   ```dart
   Future<dynamic> Function(EventDTO<T> dto, T? lastData)? handler;
   ```

   A subscription may have `onEvent`, `handler`, or **both**. `fire` invokes only `onEvent`;
   `request` invokes only `handler`. A request also notifies `onEvent` subscriptions of the node,
   preserving current listener semantics.

2. Handler concurrency is per subscription: `handlerConcurrency` (default **1**, values greater
   than 1 allowed). A subscription is **busy** while `inFlight >= handlerConcurrency`. `pause()`
   removes the subscription from dispatch; in-flight handlers continue.

3. Each handler subscription owns a bounded FIFO **request queue**:

   - `requestQueueCapacity` defaults to the bus setting (provisional default 64) and may be
     overridden per subscription;
   - capacity `0` means "reject immediately when no slot is free";
   - queue overflow is `BusyException`;
   - queue entries are removable by timeout and cancellation (ADR-0003).

4. Dispatch is tier-local:

   - resolve the exact topic; if it has handler subscriptions, only they compete;
   - otherwise resolve the most specific matching pattern topic that has handler subscriptions;
   - if the resolved tier has no capacity, the request waits in that tier's queues or fails with
     `BusyException`; it never falls back to a less specific tier.

5. Inside the tier the dispatcher uses a **round-robin cursor** over subscriptions that are not
   paused. It prefers a subscription with a free concurrency slot; otherwise it selects a
   subscription with queue room. "First free" is implemented as round-robin to avoid starving
   later handlers.

6. On an accepted request (dispatched or queued):

   - listeners of the node are notified immediately and `currentData` is updated;
   - `lastData` is snapshotted at enqueue/dispatch acceptance and passed to the handler later;
   - a `BusyException` rejection does **not** notify listeners and does not update `currentData`.

7. `removeTopic` cancels all subscriptions of the topic, including handler subscriptions. The old
   distinction "remove the node but keep the handler" disappears.

8. The old handler API is removed in 4.0.0: `EventBusHandlers`, `setHandler`, `removeHandler`,
   `addAllHandlerFromOtherBus`, `removeAllHandlerPresentInOtherBus`. No 3.x deprecation bridge.
   A migration guide and a migration script (E6-01, E6-02) replace them.

9. Queries:

   - `haveHandler` is `true` when a matching handler subscription exists, even if all are paused;
   - `haveAvailableHandler` is added for "there is a handler that could accept now".

10. Transport adaptation: an incoming request resolves a **registration** (node + subscription) and
    only that node answers. Overlapping exact/pattern subscriptions cannot produce two answers.
    If the chosen subscription has no capacity, the responder sends no response; the requester's
    timeout applies (ADR-0003, D15).

## Consequences

- `EventBusHandlersMixin` and `_requestHandlers` are deleted; `Scope`/`Command` migrate to handler
  subscriptions (`Scope.disposeScope` cancels its subscription).
- `_hasHandlerFor` and the handler pin disappear; node retention is "has any active subscription".
- `handlerTopicFor` becomes an internal resolution helper, not a documented transport hook.
- Requests and events now share one lifecycle (`cancel`, `pause`, counters), which simplifies
  metrics and observability.
- The migration is breaking and must be documented with side-by-side examples.

## Alternatives considered

- **Keep the separate handler registry and add an optional second handler.** Rejected: preserves
  two lifecycles and two pins for the same node.
- **One shared FIFO queue on the node.** Rejected: per-subscription capacity overrides and
  per-subscription concurrency would be meaningless; a slow handler would block the others.
- **First-free instead of round-robin.** Rejected: biases the first handler and starves the rest.
- **Cross-tier fallback when the exact tier is busy.** Rejected: a catch-all pattern handler could
  silently take work that belongs to a specific handler.
- **A separate `running` flag.** Rejected in favour of `pause`/`busy` (ADR-0002, D6): one state
  machine for listeners and handlers.
