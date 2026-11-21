# M4: observability, metrics, correlation, error monitor

- Status: done
- Started: 2026-11-22
- Finished: 2026-11-22
- Estimate: 13–19 PD (ROADMAP M4)
- Local work report: no task record exists, and `record_create.py` requires a
  parent Feature/User Story; per `agai-sdlc:task-sync`, this file is the allowed
  fallback for work without a linked task.
- YouGile: not configured.
- Decision record: ADR-0006 (implementation notes 2026-11-22), ADR-0004.

## Scope

- `ObservabilityConfig` at bus construction (`enabled`, `metrics`, `tracing`,
  `sampleRate`, `cardinalityLimit`, `capturePayloads`, metric key builder).
  Off by default and no measurable hot-path work when off.
- Per-topic and per-subscription metrics: events, requests, queues, handlers,
  listeners, latency histograms; cardinality limit with an `other` bucket.
- `bus.metrics.snapshot()`, an optional `changes` stream and a snapshot type
  usable by external exporters.
- `EventDTO.correlationId`, propagated through the isolate protocol and
  transport headers; `EventBusError` carries it when known.
- `EventBusErrorMonitor`: filters, rate limit, bounded recent buffer,
  `snapshot()` by kind and topic.
- Tests and an on/off overhead benchmark.

## Result

- `lib/src/observability.dart`: `ObservabilityConfig`, `EventBusMetrics`,
  `EventBusMetricsSnapshot`, `TopicMetricsSnapshot`,
  `SubscriptionMetricsSnapshot`, `LatencySnapshot`, `RequestOutcome` and
  `EventBusMetricsExporter`.
- `EventBus(isModelBus:, observability:)`, `EventBusIsolate(observability:)`,
  transport buses; `isObservable` and `metrics` on the `EventBus` interface.
  Metrics record only when `enabled && metrics`; the off path is a field read.
- Per-topic counters (fired/delivered/dropped/overflow, request outcomes),
  dispatch/request latency histograms, per-subscription queue depth,
  `maxBufferedRequests`, in-flight, concurrency and queue-wait latency.
  Metric key = event type token by default, custom builder available;
  cardinality overflow goes to `__other__` and `droppedMetricSeries`.
- `snapshot()` immutable views; `changes` coalesced per microtask and only with
  a listener; `EventBusMetricsExporter` is the exporter seam.
- Correlation id: `EventDTO.correlationId`, `fire/request(correlationId:)`,
  handler DTOs, isolate protocol, `X-EventBus-Correlation-Id` in NATS headers
  and MQTT 5 user properties; `EventBusError.correlationId` for request errors.
- `EventBusErrorMonitor({filter, recentLimit, maxErrorsPerSecond})` with
  `snapshot()` by kind/topic and `suppressed`.
- Payload capture: listener and request errors include the event only when
  `capturePayloads` is on.
- Tests: `test/observability_test.dart` (13), `test/error_monitor_test.dart`
  (3), `packages/event_bus_arch_transport/test/transport_observability_test.dart`
  (1).

## Deviations and limits

- Tracing spans are deferred: `tracing`/`sampleRate` are accepted, sampling
  applies to latency histograms, no span exporter ships in 4.0.0.
- Listener errors carry no correlation id: the subscription receives the value,
  not the DTO. Request errors carry it.
- Transport connection/status metrics are not in the bus snapshot (M5); pool
  restart counters live in `WorkerPoolMetrics`.
- NATS/MQTT header propagation is implemented but the broker integration tests
  are skipped without brokers; the transport seam is covered by the fake.

## Verification

- `dart test` — 250 passed (13 observability, 3 error monitor).
- `dart analyze` — 16 infos: the pre-existing set plus the part-of info for the
  two new part files.
- `packages/event_bus_arch_transport`: 28 passed (1 transport observability).
- `packages/event_bus_arch_nats`: 42 passed, 10 skipped (no broker).
- `packages/event_bus_arch_mqtt`: 32 passed, 7 skipped (no broker).
- `dart test -p chrome test/web_smoke_test.dart`: 3 passed.
- `dart run benchmark/observability_benchmark.dart` — fire +7.8%, request
  +3.6% with collection on (min of five runs, same machine).

## Agent work log

- 2026-11-22: task-sync invoked; local report created (same fallback as M2/M3).
  M4 implementation started with the config, metrics and correlation id.
- 2026-11-22: E4-01..E4-07 implemented and tested; ADR-0006 implementation
  notes added, ROADMAP updated. Agents/skills: `agai-sdlc:task-sync`,
  `agai-sdlc:records`; token attribution unavailable (single session, metrics
  not split by task); active time approximately 2026-11-22 03:00 — 05:30 local.
