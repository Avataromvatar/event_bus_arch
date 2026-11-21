# ADR-0005: Isolate interest, fire and request semantics

- Status: Accepted
- Date: 2026-11-21
- Roadmap: E2-01..E2-07

## Context

`EventBusIsolate.fire` currently sends every event to the other side and returns `true` when the
`SendPort` accepted it. It does not look for a local node, does not deliver to local listeners, and
cannot know whether anyone on the other side is interested. `request` always crosses the bridge and
waits for a handler, even when neither side has one, until the caller's timeout.

The node/handler unification (ADR-0002) makes it possible to describe "interest" precisely: a
subscription with `onEvent`, a subscription with `handler`, or a model node that retains state.
The two sides can exchange that registry.

## Decision

1. Each side maintains a **remote interest registry**: exact topics and pattern topics, split by
   kind (`listener` for `fire`, `handler` for `request`). The registry is updated on:

   - subscription creation with `onEvent` or `handler`;
   - subscription cancellation;
   - `removeTopic` / node removal;
   - model-node creation and disposal.

2. Protocol additions (v4, both sides must run 4.x; no cross-version compatibility):

   - `_IsolateInterest(topic, kind, present)` — fire-and-forget;
   - `_IsolateCancel(id)` — fire-and-forget, for request cancellation (ADR-0003).

   Interest messages and events share the same port, so their order is FIFO. The registry is
   best-effort: a listener that cancels concurrently with a `fire` may still appear interested.

3. `fire`:

   - delivers to local listener subscriptions first;
   - sends to the other side only when the remote registry has a matching listener interest;
   - returns `true` when the event was accepted by a local listener subscription, stored by a local
     model bus, accepted by a transport for publishing, or a remote listener interest was known;
   - a handler-only node does not make `fire` return `true` (ADR-0002, D14);
   - stale `true` is possible by design; `false` means "no known interest at the moment".

4. `request`:

   - resolves a local handler subscription first and uses it when present;
   - otherwise sends the request when the remote registry has a handler interest;
   - when neither side has a handler, throws `NoHandlerException` immediately (no timeout wait);
   - a remote busy/timed-out handler is reported according to ADR-0003.

5. Initial handshake: both sides exchange their full interest registry. `waitInit` completes only
   after `onInit` and the registry exchange, so a `fire`/`request` sent right after `await
   waitInit` sees the interests that `onInit` registered.

6. On worker death or restart, the remote registry is cleared and re-synchronised with a generation
   counter (ADR-0007). During restart, calls follow the supervision policy (fail fast or wait for
   readiness, decided in ADR-0007).

7. A model bus does **not** create a typed node for an incoming `fire` with no local node: the
   receiving side has no compile-time `T` and cannot construct a correctly typed `EventNode<T>`.
   A local listener or handler must establish the node; after that, model retention applies.

8. `removeTopic` propagates to the other side, so both registries forget the topic together.

9. The old directional documentation remains partly true: the main side still uses
   `EventBusIsolate.fire` to reach the worker. The change is that local listeners also receive the
   event and the return value reflects real interest.

## Consequences

- `EventBusIsolate` and `_EventBusForIsolate` gain local dispatch for `fire`, plus registry state
  and sync messages.
- `_IsolateLink` gains a remote interest map and a generation counter.
- Tests must cover: local only, remote only, both, none, pattern interest, model node, interest
  removal, cancellation across the bridge, worker restart, `waitInit` ordering.
- The protocol is versioned by the 4.0 major; mixed 3.x/4.x peers are unsupported.

## Alternatives considered

- **Keep fire-and-forget with a `true` on port send.** Rejected: the return value lies and local
  listeners are bypassed.
- **Synchronise actual `currentData` values between sides.** Rejected for 4.0.0: conflict
  resolution, ordering and ownership are a separate feature; only interest and node topics are
  synchronised.
- **Ask the other side on every `fire` (request/reply).** Rejected: asynchronous, adds latency and
  a pending map to every event; the registry is the cheaper approximation.
- **Create an untyped node on the receiving side.** Rejected: breaks `currentData<T>` and type
  checks.
