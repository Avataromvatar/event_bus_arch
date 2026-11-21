# ADR-0004: Error stream and EventBusErrorMonitor

- Status: Accepted
- Date: 2026-11-21
- Roadmap: E1-13, E4-06

## Context

Failures are reported inconsistently today:

- `request` returns a handler error to its caller;
- `fire` has no error path; a listener exception goes to the subscription's `onError` or the zone;
- transport errors are a separate `Stream<Object>` on `TransportEventBus`;
- isolate failure completes `waitInit` with an error and fails pending requests;
- there is no error type, no topic context, no rate limiting, and no place to see errors from
  several buses at once.

The backpressure, handler dispatch and supervision work creates new failure kinds (buffer overflow,
busy queue, timeout, cancellation, restart), so a single error contract is needed before those
features ship.

## Decision

1. `EventBus` exposes:

   ```dart
   Stream<EventBusError> get errors;
   List<EventBusError> get recentErrors;   // bounded diagnostic buffer
   ```

   Errors are delivered as **data events**, never with `StreamController.addError`. A listener
   without an `onError` must not receive an unhandled error for every bus failure.

2. `EventBusError` is an immutable envelope:

   ```dart
   class EventBusError {
     final EventBusErrorKind kind;
     final String? topic;
     final EventDTO? event;       // optional, redacted by default
     final Object error;
     final StackTrace? stackTrace;
     final DateTime timestamp;
     final EventBusErrorSource source; // core, isolate, transport, supervision
     final Map<String, String> context;
   }
   ```

3. Kinds include: `listener`, `handler`, `serialization`, `deserialization`, `transport`,
   `isolateInit`, `isolateDeath`, `requestTimeout`, `requestCanceled`, `bufferOverflow`, `busy`,
   `supervision`, `dispose`, `other`.

4. Emission points:

   - listener and handler exceptions (handlers are additionally returned to the request caller);
   - serializer/deserializer failures;
   - transport connection, publish and subscribe errors;
   - isolate `onInit` failure, worker death, restart and give-up;
   - request timeout and cancellation;
   - buffer overflow and `BusyException`;
   - disposal failures.

5. The error stream must never recurse: an exception thrown by an `errors` listener is sent to the
   zone and counted, but is not re-emitted. Errors are rate-limited per `(kind, topic)` (provisional
   default: 10 events per second, with a suppressed counter) to prevent a storm.

6. `recentErrors` is a bounded ring (provisional default: 100). It exists for diagnostics and does
   not grow without bound.

7. Payload capture is redacted by default: `event` is `null` unless payload capture is enabled in
   the observability config. Error messages may still contain user data; the redaction policy is
   documented and testable.

8. `EventBusErrorMonitor` is an aggregator over several buses:

   ```dart
   monitor.add(bus);
   monitor.remove(bus);
   monitor.errors;             // merged stream
   monitor.snapshot();         // counters by kind/topic
   ```

   It is not a static global. Per-bus streams plus an aggregator keep tests isolated and allow
   several applications in one process.

9. `TransportEventBus.errors` is aligned with the envelope in 4.0.0. `Stream<EventBusError>` is a
   subtype of `Stream<Object>`, so existing consumers of `Stream<Object>` still compile; transport
   consumers that expected raw objects migrate in the migration guide.

10. `allEventStream` remains event tracing; errors are not mixed into it. `EventBusLogger` remains
    the event-trace helper; error aggregation and metrics belong to `EventBusErrorMonitor` and the
    observability layer (ADR-0006).

## Consequences

- New public types and one new getter on `EventBus`; custom `EventBus` implementations must add it.
- Core, isolate and transport code gain a shared error-reporting helper.
- Rate limiting and bounded retention must be implemented before errors are exposed.
- Error tests must prove: no recursion, no unbounded growth, redaction, and all kinds emitted.

## Alternatives considered

- **`StreamController.addError`.** Rejected: unhandled-error semantics and zone interference.
- **A static global error stream.** Rejected: lifecycle leaks, test pollution, multi-app isolation.
- **A single callback (`onError`).** Rejected: one consumer, no fan-out, harder to compose.
- **Zone-based capture.** Rejected: implicit, global, poor composability, and no topic context.
