# ADR-0006: Observability and metrics

- Status: Accepted
- Date: 2026-11-24
- Current in: 4.1.1

## Context

Operators need to answer “what is the rate, latency, error rate and queue depth per address?”
without attaching a listener that changes bus timing or enabling allocation on every event. Addresses
can be dynamic (`session.<id>`, `order.<uuid>`), so per-address series need cardinality control.

## Decision

1. Observability is configured at construction:
   `EventBus(observability: ObservabilityConfig(...))`. `enabled: false` is the default and adds no
   metric collection on the hot path.
2. `metrics` collects per-address and per-subscription data:
   - events: fired, delivered, dropped, buffer overflow;
   - requests: started, completed, errored, timeout, canceled, busy;
   - queues: depth, maximum depth and queue-wait latency;
   - handlers: in-flight count and concurrency;
   - listeners: buffered, delivered and dropped;
   - delivery/dispatch histograms and connection/isolate status where applicable.
3. `cardinalityLimit` caps distinct metric keys (default 1000). New keys above the limit go to a
   shared `other` bucket and are counted; this prevents unbounded series from dynamic addresses.
4. `sampleRate` controls latency sampling; counters remain exact. `capturePayloads` controls
   whether error envelopes carry the event; the default is redacted.
5. Correlation ids travel with `fire`/`request`, through handlers, isolates and transport headers,
   and in request error envelopes. `metricKeyBuilder` can coarsen a key when address cardinality is
   too high.
6. `EventBusMetrics` exposes a snapshot and a change stream; `EventBusMetricsExporter` is the
   integration point for an external backend. The core does not hard-code an exporter.
7. Observability never changes delivery semantics: enabling it must not turn a busy rejection,
   timeout or cancellation into a different exception.
8. The error stream and monitor are separate from metrics (ADR-0004). An error can be visible in
   both: the error stream for diagnosis and the metric counters for rates.

## Consequences

- Production can run with observability off and pay only a configuration check.
- Cardinality control is a deliberate loss of precision: the `other` bucket is visible and must be
  monitored.
- Per-subscription metrics exist only for managed `subscribe` consumers; a raw `listen` has no
  subscription counters.
- A metric exporter failure must not break event delivery; exporters are isolated from the bus.

## Alternatives considered

- **Global static metric registry.** Rejected: test pollution and multi-app isolation.
- **Record every concrete address.** Rejected: unbounded cardinality for dynamic addresses.
- **Enable observability by default.** Rejected: hot-path cost and surprise allocations.
- **Mix errors into metrics only.** Rejected: metrics lose the envelope, stack trace and error
  context needed for diagnosis.
