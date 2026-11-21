# ADR-0006: Observability and per-topic metrics

- Status: Accepted
- Date: 2026-11-21
- Implementation notes: 2026-11-22 (settled API and scope are below)
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

## Implementation notes (2026-11-22)

Settled API and the scope chosen where the decision left room:

- `ObservabilityConfig({enabled, metrics, tracing, sampleRate, cardinalityLimit,
  capturePayloads, metricKeyBuilder})`; `enabled` is false by default. It is passed to
  `EventBus(isModelBus:, observability:)`, `EventBusIsolate(observability:)` and the transport
  buses. `isObservable` reports `enabled`; `metrics` reads `EventBusMetrics`.
- The metric key is the event type token by default (`Topic.type`), so a dynamic path cannot grow
  the registry; `metricKeyBuilder` allows a custom key. The `cardinalityLimit` is enforced before a
  new key is created; overflow goes to `__other__` and increments `droppedMetricSeries`.
- Per-key counters: `fired`, `delivered`, `dropped`, `bufferOverflow`; requests `started`,
  `completed`, `errored`, `timeout`, `canceled`, `busy`. Latency histograms are fixed-bucket and
  are recorded for `fire` dispatch, request round trips and per-subscription queue wait.
  `sampleRate` applies only to histogram samples; counters are exact.
- `EventBusMetrics.snapshot()` returns immutable `EventBusMetricsSnapshot` objects with topic and
  subscription views. A subscription view includes buffer/queue depth, `maxBufferedRequests`,
  `bufferedRequests`, `inFlight`, `handlerConcurrency`, delivered/dropped and queue-wait latency.
  `changes` is a coalesced live stream (at most one snapshot per microtask, only while it has a
  listener). `EventBusMetricsExporter` is the exporter seam; no exporter ships in the core.
- Metric recording happens only when `enabled && metrics`; the disabled hot path adds one field
  read. Benchmark (`benchmark/observability_benchmark.dart`, min of five runs): fire +7.8%,
  request +3.6% on the same machine, within the provisional <10% budget.
- Incoming requests (from an isolate or a broker) are counted as requests handled by the bus; an
  incoming `fire` is not counted as a local `fired` event, but its subscription deliveries are in
  the subscription view.
- Correlation id: `EventDTO.correlationId`; `fire`/`request` accept `correlationId:`; handlers see
  it in the received DTO; isolates carry the DTO unchanged; transports carry it in the
  `X-EventBus-Correlation-Id` header (NATS headers, MQTT 5 user properties). `EventBusError`
  carries it when the envelope is created from a request DTO. Listener errors currently have no
  DTO (the subscription sees only the value), so they carry no correlation id; request errors do.
- `EventBusErrorMonitor({filter, recentLimit, maxErrorsPerSecond})` merges buses, filters before
  counting, keeps a bounded recent buffer and a per-second monitor-wide limit (`suppressed`), and
  exposes `snapshot()` counters by kind and topic. Per-bus limits from ADR-0004 stay in place.
- Tracing spans are not implemented in 4.0.0: `tracing` and `sampleRate` are carried for a future
  exporter, while metrics and correlation are complete. Transport connection/status metrics are not
  in the bus snapshot either; pool restart counters are in `WorkerPoolMetrics` (M3).

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
