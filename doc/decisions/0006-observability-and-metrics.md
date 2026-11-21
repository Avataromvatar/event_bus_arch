# ADR-0006: Observability and per-topic metrics

- Status: Accepted
- Date: 2026-11-21
- Roadmap: E4-01..E4-07

## Context

The package has `allEventStream` and `EventBusLogger`, but no structured metrics, no correlation
id, no sampling and no way to turn collection off. For a primary application core, operators need
to answer "what is the rate, latency, error rate and queue depth per topic?" without attaching a
listener that changes the timing of the bus.

Dynamic topics (`session.<id>`, `order.<uuid>`) make naive per-topic counters unbounded.

## Decision

1. Observability is configured at bus construction:

   ```dart
   EventBus(
     isModelBus: false,
     observability: ObservabilityConfig(
       enabled: true,
       metrics: true,
       tracing: false,
       sampleRate: 1.0,
       cardinalityLimit: 1000,
       capturePayloads: false,
     ),
   )
   ```

   `enabled: false` is the default and must add no measurable allocation or work to the hot path.
   A read-only `bool get isObservable` exposes the current state.

2. Metrics are collected per topic and per subscription:

   - events: `fired`, `delivered`, `dropped`, `bufferOverflow`;
   - requests: `started`, `completed`, `errored`, `timeout`, `canceled`, `busy`;
   - queues: `depth`, `maxDepth`, `waitMicros` (histogram);
   - handlers: `inFlight`, `concurrency`;
   - listeners: `buffered`, `delivered`, `dropped`;
   - latency histograms for delivery and request round trips;
   - connections/isolates: status changes, reconnects, restarts.

3. Cardinality control:

   - the metric key is the event type token plus a path pattern, not every concrete path;
   - `cardinalityLimit` caps the number of distinct keys; overflow goes to an `other` bucket and a
     `droppedMetricSeries` counter;
   - the policy is documented and configurable.

4. Reading metrics:

   - `bus.metrics.snapshot()` returns an immutable snapshot;
   - `bus.metrics.changes` is an optional stream for live dashboards;
   - exporters (OpenTelemetry, Prometheus) live outside the core; the core only defines the
     snapshot/exporter interface.

5. Correlation id:

   - `EventDTO` gains an optional `correlationId` field in 4.0.0;
   - it is propagated through the isolate protocol and transport headers/user properties;
   - `EventBusError` carries the correlation id when known;
   - tracing spans are opt-in and never required for metrics.

6. Sampling applies to metrics/tracing events, not to actual bus delivery. Errors are never
   sampled out; they can be rate-limited (ADR-0004).

7. `EventBusErrorMonitor` (ADR-0004) is the aggregation point for errors across buses;
   `EventBusMetrics` is its metrics counterpart. Both are per-process objects, not statics.

8. `EventBusLogger` remains the simple event-trace helper; it is not the metrics mechanism and is
   not required for observability.

## Consequences

- Hot paths gain `if (observabilityEnabled)` branches and timestamp captures only when enabled.
- `EventDTO` changes shape (new optional field); migration guide covers constructors/copying.
- The isolate protocol and transport metadata gain an optional correlation id.
- Benchmarks must prove off/on overhead; the on-budget is provisional (< 10% for fire/request in
  the benchmark scenario).

## Alternatives considered

- **Always-on counters.** Rejected: measurable cost on the hot path and unavoidable cardinality
  risk.
- **A separate instrumentation package only.** Rejected: it cannot observe internal queue depth and
  in-flight handlers without core hooks.
- **Per-concrete-topic metrics.** Rejected: unbounded cardinality for dynamic topics.
- **Zone-based tracing.** Rejected: implicit and hard to scope per bus.
