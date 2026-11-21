# ADR-0005: Isolate interest, fire and request semantics

- Status: Accepted
- Date: 2026-11-21
- Revised: 2026-11-22 — `fire` on a bridge is outbound only (see Revision)
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

3. `fire` (revised 2026-11-22):

   - on a bridge, `fire` targets only the other side: the bridge is a directional port, local
     listeners receive incoming events and `fire` is outbound. The event is never delivered to the
     local listeners of the same side, so a listener that fires the same topic cannot re-enter
     itself through the bridge;
   - sends to the other side only when the remote registry has a matching listener or model interest;
   - returns `true` when the event was handed to a side with known remote listener/model interest;
     the local side does not accept a bridge `fire`. Local pub/sub belongs to an ordinary `EventBus`
     (`Layer.current` inside `Layers`);
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

9. The old directional documentation is true again: the main side uses `EventBusIsolate.fire` to
   reach the worker, and local listeners on a side receive only events coming from the other side.
   A bridge does not deliver a fired event back to its own listeners.

## Revision 2026-11-22

The first version of this ADR also delivered `fire` to the local listeners of the bridge. That
creates an implicit return path: a listener that receives an inbound event and fires the same topic
on the same bus receives its own fire and fires again — an infinite loop with `DeliveryMode.async`
and immediate recursion with `DeliveryMode.sync`. The 3.x bridge did not have this path because its
`fire` was outbound only, so the M2 change silently broke the forwarding pattern that `Layers` and
worker middleware are built on.

The bridge is a port: listeners are inbound, `fire` is outbound. Local delivery of a bridge `fire`
is removed; local pub/sub uses a local `EventBus` (`Layer.current`). The remote-interest check and
the return semantics of revision 1 stay: `fire` is `true` only when the other side has a matching
listener or model interest. A model bridge still retains the values it *receives*; a fire does not
update the sending side's local model, exactly as in 3.x.

The regression is covered by `test/event_bus_isolate_protocol_test.dart` (the Layers ping-pong uses
the same topic in both directions) and by the same-topic echo test in
`test/event_bus_isolate_interest_test.dart`.

## Consequences

- `EventBusIsolate` and `_EventBusForIsolate` gain registry state and sync messages; `fire` stays
  outbound only, so the bridge remains a directional port.
- `_IsolateLink` gains a remote interest map and a generation counter.
- Tests must cover: fire with and without remote interest, handler-only interest, pattern interest,
  model node, interest removal, cancellation across the bridge, worker death, `waitInit` ordering,
  and the same-topic echo that must not re-enter its listener.
- The protocol is versioned by the 4.0 major; mixed 3.x/4.x peers are unsupported.

## Alternatives considered

- **Keep fire-and-forget with a `true` on port send.** Rejected: the return value lies; the event may
  have no interested side. The revised decision keeps the outbound direction but gates the send and
  the return value on known remote interest.
- **Deliver `fire` to local listeners too (revision 1).** Rejected in the 2026-11-22 revision: it
  makes the bridge create an implicit local echo and loops a listener that fires the same topic.
  Local pub/sub belongs to a local bus.
- **Synchronise actual `currentData` values between sides.** Rejected for 4.0.0: conflict
  resolution, ordering and ownership are a separate feature; only interest and node topics are
  synchronised.
- **Ask the other side on every `fire` (request/reply).** Rejected: asynchronous, adds latency and
  a pending map to every event; the registry is the cheaper approximation.
- **Create an untyped node on the receiving side.** Rejected: breaks `currentData<T>` and type
  checks.
