# ADR-0005: Isolate interest, fire and initialization semantics

- Status: Accepted
- Date: 2026-11-24
- Current in: 4.1.1
- Implementation note: the `initTimeout` abort cleanup was implemented in 4.1.1 (REL-01 in the
  [post-4.1 plan](../artifacts/plans/2026-11-24-post-4.1-hardening-and-migration-plan.md))

## Context

`EventBusIsolate` runs a bus in another isolate and exchanges events, requests and current model
state. The bridge must be directional to avoid an echo loop: a listener that fires the same address
must not receive its own outbound event through the bridge. The main side also needs to know
whether the other side is interested before claiming that a `fire` was accepted.

Initialization is asynchronous and an `onInit` may hang or be slow. A `waitInit` future that never
completes is not acceptable, and a timeout must not leave a live worker or a bridge that becomes
usable after the caller has already observed an initialization error.

## Decision

1. Each side keeps a remote-interest registry of `EventSelector` objects, split by listener,
   handler and model interest. Interest changes and the full handshake are sent over the bridge.
2. Interest is matched by both address/pattern and payload type: a remote `Invoice` listener does
   not accept an `Order` event. `EventSelector.accepts(data)` is the filter.
3. `fire` on a bridge is outbound only. The sending side never delivers it to its own local
   listeners. It is sent only when the other side has a matching listener or model interest and
   returns true only in that case. A handler-only interest does not count.
4. `request` tries local handlers that accept the data first, then crosses to a remote handler
   with matching interest. With no accepting handler on either side it throws
   `NoHandlerException` immediately. A busy/timed-out remote handler follows ADR-0003.
5. `waitInit` completes after `onInit` finishes and the initial interest snapshot is exchanged.
   `fire`/`request` throw `StateError` until the bridge is ready.
6. The worker is spawned paused; the exit listener is registered before it is resumed. A worker
   that exits during `onInit` fails `waitInit` promptly.
7. `initTimeout` (default 30 seconds, `null` disables it) bounds initialization. On timeout the
   generation is invalidated, the receive port and isolate are closed/killed, the bridge is marked
   not ready, and only then is `waitInit` completed with `EventBusException`. Late messages and a
   late ready signal from that generation are ignored.
8. `restart()` keeps local nodes, listeners and model state, invalidates the old generation, fails
   pending requests, exchanges interest with the new worker and returns its `waitInit`. A bridge is
   not usable during restart.
9. `remove`/`removeAddress` remove the local nodes and forward the deletion so both interest
   registries forget the selector.
10. Only sendable values cross the boundary. The protocol is 4.x-only; mixed 3.x/4.x peers are not
    supported.

## Consequences

- The bridge is a port, not a local pub/sub shortcut; local pub/sub belongs to an ordinary
  `EventBus` (`Layer.current` in `Layers`).
- A stale `true` from `fire` remains possible because interest is a cached approximation; `false`
  means “no known interest at the moment”.
- Typed interest makes the “wrong remote type acknowledged a fire” failure impossible; the cost is
  carrying selectors and matching patterns on both sides.
- The timeout abort is implemented and covered by the regression tests: a late ready cannot revive
  the bridge, and `restart()` starts a fresh generation.

## Alternatives considered

- **Deliver `fire` locally too.** Rejected: creates an implicit echo and an infinite loop for a
  forwarding listener.
- **Address-only interest.** Rejected: a listener of another payload type would acknowledge an
  event that cannot be delivered.
- **No initialization timeout.** Rejected: a hung `onInit` would hang `waitInit` forever.
- **Leave the worker alive after timeout.** Rejected: it leaks an isolate/port and allows a
  contradictory “waitInit failed but bus works” state.
- **Ask the other side on every fire.** Rejected: adds a pending request and latency to every
  event; a cached registry is the cheaper approximation.
