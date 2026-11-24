# ADR-0002: Handler subscriptions, dispatch and type-aware routing

- Status: Accepted
- Date: 2026-11-24
- Current in: 4.1.0

## Context

Handlers used to live in a separate registry that allowed one handler per topic and pinned a node.
There was no way to have competing handlers, per-handler concurrency or a request queue. The
separate registry also made “does this topic have a consumer?” answer under two different rules:
one for listeners and one for handlers.

With the keyed address model (ADR-0009), the payload type is a local filter rather than an address
token. Dispatch must therefore consider both the registered `(address, Type)` and the actual data:
an `Invoice` handler must not answer an `Order` request merely because both use the same address.

## Decision

1. A handler is a capability of `EventSubscription<T>`. A subscription may have `onEvent`,
   `handler`, or both. `fire` invokes only listeners; `request` invokes the selected handler and
   also notifies the node's listeners.
2. Handler concurrency is per subscription: `handlerConcurrency` defaults to 1.
   `requestQueueCapacity` defaults to the bus setting (64) and may be overridden; `0` means reject
   immediately when no slot is free. Queue overflow is `BusyException`.
3. A request resolves a tier:

   - the exact address with at least one handler subscription whose `selector` accepts the data;
   - otherwise the most specific matching pattern with at least one accepting handler;
   - a foreign-type exact handler does not block a matching pattern handler;
   - if the selected tier has accepting handlers but no capacity, the request waits in its queue or
     fails with `BusyException`; it does not fall back to a less specific pattern.

   Inside the tier, dispatch uses a round-robin cursor and prefers a handler with a free slot,
   otherwise one with queue room.

4. `handlerAddressFor(address, data)` returns the registration address of the single tier that
   should answer an incoming transport request. This prevents overlapping exact/pattern nodes from
   producing two responses.
5. `probeFire(key, data)` and `probeRequest(key, data)` are side-effect-free, data-aware snapshots.
   They count listeners/handlers that accept the data and report local, isolate and transport
   interest. `haveListener`, `haveHandler` and `haveAvailableHandler` are deprecated because a
   no-data query cannot test subtype compatibility; they check the exact registered type and are
   removed in 5.0.
6. A request tries a local accepting handler first. Transport, isolate and `Command` use
   `probeRequest(...).localHandlers > 0` rather than an address-only check, so a local handler of
   another type does not block a broker/worker request. A local supertype pattern handler still
   wins.
7. `fire` delivers to the exact node and every matching pattern node; an event is accepted by a
   listener, a model store, a transport publish or known remote listener/model interest. A
   handler-only subscription does not make `fire` return true.
8. `lastData` is snapshotted when the request is accepted. A `BusyException` rejection does not
   notify listeners and does not update `currentData`.

## Consequences

- One lifecycle covers listeners and handlers: `cancel`, `pause`, counters and error routing.
- Type mismatches are rejected at resolution time instead of failing inside a handler.
- `have*` remains temporarily for compatibility, but new code should use probes; the dependency on
  a later 5.0 removal is explicit.
- Transport answering requires the decoded payload, not only the subject; a node of the wrong type
  stays silent.

## Alternatives considered

- **Keep the separate handler registry.** Rejected: two lifecycles, two pins and no competing
  handlers.
- **Address-only routing.** Rejected: it selects a foreign-type handler and turns a routable
  request into a timeout or a false `NoHandlerException`.
- **Fall back to a pattern when the exact tier is busy.** Rejected: a catch-all handler could
  silently take work intended for a specific handler.
- **Make `have*` data-aware.** Rejected: the API has no data argument; adding an overload would
  duplicate the probe concept and make the old name lie.
