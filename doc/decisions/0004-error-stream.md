# ADR-0004: Error envelope, error stream and monitor

- Status: Accepted
- Date: 2026-11-24
- Current in: 4.1.0

## Context

Failures arrive from listeners, handlers, codecs, transports, isolates, worker supervision and
request lifecycles. Delivering them as stream errors would turn every failure into an unhandled
zone error for listeners without `onError`, and separate raw-error streams per component would not
give an application one diagnostic surface. A burst of errors must not grow memory without bound.

## Decision

1. `EventBus` exposes `errors` as a broadcast stream of `EventBusError` **data events**. It never
   uses `StreamController.addError`; a listener without an error handler does not receive an
   unhandled error for a bus failure.
2. `EventBusError` is immutable and carries `kind`, `source`, `address` (`topic` is an alias),
   `error`, optional `event`, `correlationId`, `stackTrace`, `timestamp` and small `context` labels.
3. Kinds cover listener, handler, serialization/deserialization, transport, isolate init/death,
   timeout/cancellation, buffer overflow, busy, supervision, dispose and other. Sources are core,
   isolate, transport and supervision.
4. `recentErrors` is a bounded diagnostic ring of the last 100 accepted envelopes.
   `suppressedErrors` counts errors suppressed by rate limiting.
5. Rate limiting is per `(kind, address)`: at most 10 accepted errors in a one-second window. The
   window store is a bounded LRU of 256 keys; timestamps older than one second are pruned when a
   key is accessed. This keeps burst visibility while preventing unbounded growth for dynamic
   addresses.
6. Payload capture is opt-in. `EventBusError.event` is null unless
   `ObservabilityConfig.capturePayloads` is enabled; error messages and context are expected to be
   redaction-safe.
7. `EventBusErrorMonitor` aggregates several buses with filters and an optional monitor-wide limit.
   It is an object, not a global; `snapshot()` returns counters by kind/address plus a bounded
   recent list.
8. An exception thrown by an `errors` listener is sent to the zone and counted, not re-emitted as
   another bus error. Error reporting never recursively calls itself.
9. `allEventStream` remains event tracing; errors are not mixed into it.

## Consequences

- Applications can log, export or assert errors without changing whether `fire`/`request` throws.
- A suppressed error can be invisible in the `errors` stream; `suppressedErrors` and the monitor
  remain the diagnostic signal.
- Buffer overflow, busy rejections and request cancellation are observable even when callers do
  not attach their own error handlers.
- A new failure source must choose a kind, a source and an address; it must not invent a separate
  error stream.

## Alternatives considered

- **Use `StreamController.addError`.** Rejected: unhandled-error semantics and zone interference.
- **One global static error stream.** Rejected: lifecycle leaks, test pollution and multi-app
  interference.
- **Only an `onError` callback.** Rejected: single consumer, no aggregation, no recent buffer.
- **Unbounded recent/window maps.** Rejected: dynamic address keys grow without bound; the
  bounded LRU and one-second pruning are part of the contract.
