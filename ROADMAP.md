# event_bus_arch 4.0.0 — Roadmap and task list

Status: **draft for working use**. This file is the single source of truth for the 4.0.0 scope,
decisions, tasks and estimates. Update the `Status` column as work progresses.

Last updated: 2026-11-21.

**M0 status: completed 2026-11-21.**
ADRs: [doc/decisions/](doc/decisions/README.md).
Web spike results: [ADR-0008](doc/decisions/0008-library-layout-web-rxdart-migration.md).
Local verification was run: core 152 tests, transport 26, NATS 42 (+10 integration skipped without
a broker), MQTT 32 (+7 skipped), Chrome smoke 2 tests, analyze clean (12 pre-existing info),
coverage and benchmark smoke commands exercised. **This project has no CI**; every milestone is
verified locally with the commands in §12.

**M1 status: completed 2026-11-21.**
Done: E1-01…E1-16 — listener/handler subscriptions, per-subscription queues and concurrency,
tier dispatch with round-robin, request timeout/cancellation, dual callbacks, transport
single-answer resolution, removal of the old handler API, `Scope` on `latest(1)`,
`EventBusError`/`errors`/`EventBusErrorMonitor`, D14 `fire` semantics, rxdart removal,
subscription/queue/memory benchmarks. Core suite 197 tests, transport 27, NATS 42 (+10 integration
skipped), MQTT 32 (+7 skipped), Chrome smoke 3. Benchmark smoke: no event loss; local fire
unchanged, local request p50 ~0.010 ms at 10k/s (new entry/dispatch cost is visible but small).

## 1. Estimate method

* Estimates are **ideal engineer-days (PD)** for one experienced Dart developer.
* They include implementation, unit tests and documentation of the task itself.
* They exclude code review, manual PR review, local environment variance, broker setup and release
  logistics.
* The planning range is the task range; a 20% contingency is added at milestone level.
* The total is deliberately split into epics so that scope can be cut without rewriting the plan.

## 2. Fixed decisions

The following decisions are settled and are not open for redesign in 4.0.0.

| ID | Decision |
|---|---|
| D1 | A request handler is a kind of `EventSubscription`; the separate `_requestHandlers` registry is removed. |
| D2 | One `EventSubscription` may carry **both** `onEvent` and `handler`. `fire` invokes only `onEvent`; `request` invokes only `handler`; a request also notifies `onEvent` subscriptions as today. |
| D3 | Handler concurrency is configurable per subscription (`handlerConcurrency`, default **1**, values > 1 allowed). |
| D4 | Each handler subscription owns a **bounded FIFO request queue**. The bus-level `requestQueueCapacity` is the default; a subscription may override it. Capacity `0` means "reject immediately". |
| D5 | Competition between handlers happens **only inside the resolved tier**: exact topic first, otherwise the most specific matching pattern topic. No fallback to a less specific tier. |
| D6 | Handler state is `pause`/`resume` plus read-only `isBusy`/`inFlight`. There is no separate `running` flag. `pause()` pauses both `onEvent` and `handler` of that subscription. |
| D7 | `request` supports **timeout and cancellation**. Both remove the request from its queue if it has not been dispatched. If it has been dispatched, the handler finishes, the response is discarded, and `currentData` stays updated. |
| D8 | `lastData` is snapshotted when the request is accepted into the queue, and that snapshot is passed to the handler at dispatch time. |
| D9 | On an accepted request, listeners are notified and `currentData` is updated at enqueue time. A `BusyException` rejection does **not** notify listeners. |
| D10 | Exception taxonomy: `NoHandlerException` (no matching handler subscription), `BusyException` (handlers exist but no capacity, including all paused, or queue full), `RequestTimeoutException`, `RequestCanceledException`. All extend `EventBusException`. |
| D11 | `haveHandler` is `true` for a paused handler subscription; `haveAvailableHandler` is added for "can accept now". |
| D12 | The old handler API is **removed**: `EventBusHandlers`, `setHandler`, `removeHandler`, `addAllHandlerFromOtherBus`, `removeAllHandlerPresentInOtherBus`. No 3.x deprecation bridge; a migration guide and a migration script are shipped instead. |
| D13 | `removeTopic` cancels all subscriptions of the topic, including handler subscriptions. |
| D14 | `fire` returns `true` only when the event was delivered to at least one listener subscription, stored by a model bus, accepted by a transport for publishing, or a remote listener interest is known. A handler-only node does not make `fire` return `true`. |
| D15 | Transport requests: cancellation is not propagated across a broker in 4.0.0; the caller's timeout is the mechanism. A busy responder sends no response, so the caller times out. |
| D16 | `EventBusError` is a data envelope (not a stream error), exposed as `Stream<EventBusError> get errors` per bus; `EventBusErrorMonitor` aggregates several buses. Errors have a bounded recent buffer, rate limiting and payload redaction by default. |
| D17 | Observability is opt-in and switchable off at bus construction; per-topic and per-subscription metrics are available when on. Correlation id is a first-class optional field of `EventDTO` and is propagated across isolates and transports. |
| D18 | `WorkerPool` strategies: `broadcast`, `roundRobin`, `keyed`, `leastBusy`, `single`. `broadcast` is forbidden for requests. |
| D19 | Supervision: a failed worker is restarted according to policy with backoff and max intensity. A failed layer tears down the whole `Layers` chain: every worker layer is restarted, the top layer (the one that called `Layers.createLayers`) survives. In-flight requests are failed, not retried. |
| D20 | `rxdart` is removed completely: no dependency, no re-export. Users add it themselves if needed. |
| D21 | Web: the local bus and transports must work; isolate APIs (`EventBusIsolate`, `Layers`, `WorkerPool`) are present but throw `UnsupportedError`, with a capability flag for compile-time-free checks. |
| D22 | Versions: `event_bus_arch` 4.0.0; `event_bus_arch_transport`, `event_bus_arch_nats`, `event_bus_arch_mqtt` 0.2.0 with dependency `^4.0.0`. |
| D23 | `Scope` subscriptions default to `latest(1)`; `FSM` subscriptions default to `unbounded` (transitions must not be dropped). |

## 3. Target model

```text
EventSubscription<T>                 pause / resume / cancel / counters
├── onEvent?  FutureOr<void> Function(T)
└── handler?  Future<dynamic> Function(EventDTO<T>, T? lastData)

EventSubscription settings
├── bufferCapacity / bufferOverflow          for onEvent delivery
├── handlerConcurrency                       default 1, > 1 allowed
├── requestQueueCapacity                     default from bus, per-subscription override
└── pause() stops both onEvent and handler
```

Node:

* `currentData` — topic state, updated when a `fire`/`request` is accepted;
* listener subscriptions — fan-out of `fire`, each with its own buffer and overflow policy;
* handler subscriptions — a tier-aware dispatcher for `request`;
* each handler subscription owns a bounded FIFO request queue;
* `deliver(dto)` for `fire`, `dispatchRequest(dto, cancelToken)` for `request`.

Request path:

1. Resolve the tier: exact topic, otherwise the most specific matching pattern that has handler
   subscriptions.
2. No handler subscriptions in any tier -> `NoHandlerException`.
3. Inside the tier, round-robin across handler subscriptions that are not paused.
4. If a subscription has a free concurrency slot, dispatch immediately: notify listeners, update
   `currentData`, invoke the handler.
5. Otherwise, enqueue into the selected subscription's FIFO queue if it has room; if no
   subscription has room, `BusyException`.
6. On handler completion, take the next non-cancelled, non-expired queued request.
7. Timeout or cancellation before dispatch removes the request from its queue. After dispatch, the
   handler continues and the response is discarded.

`fire` path: deliver to listener subscriptions per their policies. Handler subscriptions are not
invoked. A model bus still stores the value.

## 4. Milestones

| Milestone | Scope | Estimate (PD) | Exit criteria |
|---|---|---:|---|
| M0 | ADRs, Web spike, local verification | 12–17 | Decisions frozen; local verification green |
| M1 | Core subscription model, request lifecycle, errors, rxdart removal | 34–46 | Task matrix and acceptance criteria pass |
| M2 | Isolate interest sync, `fire`/`request` semantics, cancellation across the bridge | 15–22 | Isolate matrix passes; no stale-true `fire`; no local echo on a bridge; worker death clears interest (restart re-sync in M3) |
| M3 | WorkerPool and supervision (including whole-chain Layers restart) | 22–30 | Every pool strategy and restart scenario proven |
| M4 | Observability, metrics, correlation, error monitor | 13–19 | Overhead budget met; metrics consistent |
| M5 | Web compatibility and adapter 0.2.0 | 7–12 | Core tests on VM and Chrome pass; adapters compile |
| M6 | Docs, migration guide/script, release | 13–20 | Migration path exercised; release checklist green |
| **Total** | | **116–166** (midpoint ~141) | |

## 5. Task list

Status values: `todo`, `doing`, `done`, `blocked`.

### E0 — Decisions, spikes, foundation (12–17 PD)

| ID | Task | PD | Depends on | Status |
|---|---|---:|---|---|
| E0-01 | ADR-1: listener subscription contract (buffer policies, async callback, timing, stream facade) — [ADR-0001](doc/decisions/0001-listener-subscriptions-and-backpressure.md) | 2 | — | done |
| E0-02 | ADR-2: handler subscription (dual callbacks, per-subscription queue, concurrency, tier dispatch, pause/busy) — [ADR-0002](doc/decisions/0002-handler-subscriptions-and-dispatch.md) | 2 | — | done |
| E0-03 | ADR-3: request lifecycle (timeout, `CancelToken`, queue removal, dispatched discard, exceptions) — [ADR-0003](doc/decisions/0003-request-lifecycle.md) | 1 | — | done |
| E0-04 | ADR-4: `EventBusError`, error stream, `EventBusErrorMonitor` — [ADR-0004](doc/decisions/0004-error-stream.md) | 1 | — | done |
| E0-05 | ADR-5: isolate interest protocol, `fire`/`request` semantics, cancellation across the bridge — [ADR-0005](doc/decisions/0005-isolate-interest-and-fire-semantics.md) | 2 | — | done |
| E0-06 | ADR-6: observability model, metrics, correlation ids — [ADR-0006](doc/decisions/0006-observability-and-metrics.md) | 1 | — | done |
| E0-07 | ADR-7: WorkerPool strategies, supervision, whole-chain Layers restart — [ADR-0007](doc/decisions/0007-worker-pool-and-supervision.md) | 2 | — | done |
| E0-08 | ADR-8: library layout, Web, rxdart removal, migration policy — [ADR-0008](doc/decisions/0008-library-layout-web-rxdart-migration.md) | 1 | — | done |
| E0-09 | Web spike: `dart compile js` succeeds, local bus passes Chrome, isolate APIs fail at runtime — split not required; see ADR-0008 | 1 | — | done |
| E0-10 | Local verification harness: analyze, VM tests, Chrome smoke, package tests, optional broker tests, coverage, benchmark smoke; commands in §12 | 2 | — | done |

### E1 — Core subscription model (34–46 PD)

| ID | Task | PD | Depends on | Status |
|---|---|---:|---|---|
| E1-01 | Base `EventSubscription<T>`: pause/resume/cancel, `isPaused`, `isCanceled`, counters, error routing | 1.5 | E0-01 | done |
| E1-02 | Listener side: sync/async `onEvent`, buffer, overflow policies, `resize`, `.stream` view | 4 | E1-01 | done |
| E1-03 | Node refactor: subscription registry, fan-out, `currentData`, lifecycle, `removeTopic` | 4 | E1-01 | done |
| E1-04 | Handler side: `handler`, `handlerConcurrency`, `isBusy`, `inFlight` | 2 | E1-01 | done |
| E1-05 | Per-subscription bounded FIFO request queue; bus default + override; capacity 0 | 3 | E1-04 | done |
| E1-06 | Dispatcher: exact/pattern tier, round-robin, paused/busy filtering, queue selection | 4 | E1-04, E1-05 | done |
| E1-07 | Dual-callback subscription: `onEvent` + `handler` semantics and tests | 1 | E1-02, E1-04 | done |
| E1-08 | Request lifecycle: timeout, `CancelToken`, queue removal, dispatched discard, `lastData` snapshot | 3 | E1-05, E1-06 | done |
| E1-09 | Exceptions and queries: `NoHandler`, `Busy`, `RequestTimeout`, `RequestCanceled`, `haveHandler`, `haveAvailableHandler` | 1 | E1-06 | done |
| E1-10 | Remove old handler API: `EventBusHandlers`, `setHandler`, `removeHandler`, `addAll...`, `removeAll...` | 1.5 | E1-04 | done |
| E1-11 | Migrate `Scope`/`Command`/`FSM`: `Scope` `latest(1)`, `FSM` `unbounded` | 2 | E1-10 | done |
| E1-12 | Transport adaptation: resolve handler subscription, single answer, busy without response | 4 | E1-06, E1-09 | done |
| E1-13 | `EventBusError` envelope, `EventBus.errors`, `EventBusErrorMonitor` skeleton | 3 | E0-04 | done |
| E1-14 | Remove rxdart: native `doOnCancel` replacement, export and dependency removal | 1 | E1-02 | done |
| E1-15 | Test matrix: buffers, queues, tiers, pause, cancellation, dual callbacks, lifecycle | 5 | E1-01..E1-14 | done |
| E1-16 | Benchmarks: delivery overhead, queue overhead, memory, before/after | 1.5 | E1-15 | done |

### E2 — Isolate semantics (15–22 PD)

| ID | Task | PD | Depends on | Status |
|---|---|---:|---|---|
| E2-01 | Interest model: listener/handler, exact/pattern, protocol messages | 2.5 | E1-13, E0-05 | done |
| E2-02 | Interest sync on register/cancel/remove; initial handshake and `waitInit` | 3 | E2-01 | done |
| E2-03 | `fire`: bridge is outbound only; remote send on listener/model interest; no local echo | 2 | E2-02 | done |
| E2-04 | `request`: local handler first, remote handler interest, immediate `NoHandlerException` | 2 | E2-02 | done |
| E2-05 | Cancellation across the bridge: `_IsolateCancel`, queue removal, discarded response | 3 | E1-08, E2-04 | done |
| E2-06 | Worker death detection (`addOnExitListener`), pending failure, remote interest cleared; generation-based re-sync moves to E3-06 (restart does not exist yet) | 2 | E2-02 | done |
| E2-07 | Test matrix: local/remote/both/none, patterns, model bus, cancellation, restart | 4 | E2-03..E2-06 | done |

### E3 — WorkerPool and supervision (22–30 PD)

| ID | Task | PD | Depends on | Status |
|---|---|---:|---|---|
| E3-01 | Pool core: N `EventBusIsolate`, lifecycle, readiness, dispose | 3 | E2-07 | done |
| E3-02 | Dispatch strategies: `broadcast`, `roundRobin`, `keyed`, `leastBusy`, `single` | 5 | E3-01 | done |
| E3-03 | Request routing in the pool; `broadcast` forbidden for requests; busy/queues | 2 | E3-02 | done |
| E3-04 | Pool backpressure: per-worker request credit, fail-fast busy, metrics (no pool-level queue in 4.0.0) | 2 | E3-02 | done |
| E3-05 | Worker supervision: crash detection, backoff, max intensity, give-up error | 4 | E3-01 | done |
| E3-06 | Layers supervisor: whole worker-chain restart except top, bridge re-handshake, unavailable state, pending failure | 6 | E3-05 | done |
| E3-07 | Tests: strategies, worker crash, whole-chain restart, pending requests, no retry | 4 | E3-02, E3-06 | done |

### E4 — Observability (13–19 PD)

| ID | Task | PD | Depends on | Status |
|---|---|---:|---|---|
| E4-01 | `ObservabilityConfig` and toggle; zero allocations when off | 2 | E1-13 | done |
| E4-02 | Metrics model: per topic/subscription, queue depth, busy, timeouts, cancellations | 3 | E4-01 | done |
| E4-03 | Snapshot + stream + exporter interface | 2 | E4-02 | done |
| E4-04 | Correlation id on `EventDTO`; propagation across isolates and transports | 3 | E1-13 | done |
| E4-05 | Cardinality limits and aggregation for dynamic topics | 2 | E4-02 | done |
| E4-06 | `EventBusErrorMonitor`: multi-bus aggregation, filters, rate limit, bounded recent buffer | 2 | E1-13 | done |
| E4-07 | Tests and overhead benchmark (on/off) | 2 | E4-03..E4-06 | done |

### E5 — Web and adapters (7–12 PD)

| ID | Task | PD | Depends on | Status |
|---|---|---:|---|---|
| E5-01 | Web capability guard: detect web, throw `UnsupportedError` in isolate APIs; no library split unless a concrete failure appears (ADR-0008) | 2 | E0-09, E1-14 | todo |
| E5-02 | `EventBusCapabilities.isolateSupported` capability flag | 1 | E5-01 | todo |
| E5-03 | Core tests on Chrome (start with `test/web_smoke_test.dart`) and local check command | 2 | E5-01 | todo |
| E5-04 | Adapters 0.2.0 against core `^4.0.0`; compile and tests | 3 | E1-12 | todo |
| E5-05 | NATS/MQTT over WebSocket checks and documentation | 2 | E5-04 | todo |

### E6 — Documentation, migration, release (13–20 PD)

| ID | Task | PD | Depends on | Status |
|---|---|---:|---|---|
| E6-01 | Migration guide 3.x -> 4.0 | 3 | E1-15, E2-07, E3-07 | todo |
| E6-02 | Migration script for `setHandler`/`removeHandler`/imports | 3 | E6-01 | todo |
| E6-03 | Update docs 01–10; add 11 (backpressure), 12 (errors/observability), 13 (pool/supervision), 14 (Web) | 5 | E1..E5 | todo |
| E6-04 | Examples and benchmark updates | 2 | E1..E5 | todo |
| E6-05 | CHANGELOG, versioning, publish dry-run, release checklist | 2 | E6-03 | todo |
| E6-06 | Final regression, API freeze, tag | 2 | all | todo |

## 6. Dependency order

```text
E0 -> E1 -> E2 -> E3
       \-> E4 (after E1-13; pool metrics after E3)
       \-> E5 (after E1; needs ADR-8)
E0..E5 -> E6
```

Critical path: `E0 -> E1 -> E2 -> E3 -> E4 -> E6`.

Parallelisable pairs:

* E1-02 (listeners) and E1-04 (handler) after E1-01;
* E4-04 (correlation) and E4-06 (monitor) after E1-13;
* E5-04 (adapters) after E1-12, independent of E2/E3.

## 7. Milestone acceptance criteria

### M1

* One handler subscription, `handlerConcurrency: 1`, queue capacity 64: 65 concurrent requests
  leave one in flight, 64 queued, the rest receive `BusyException`.
* A timed-out or cancelled queued request leaves the queue; a late response does not complete it.
* A dispatched-then-cancelled request lets the handler finish; `currentData` stays updated.
* Exact tier busy -> the request waits in the exact tier; a free pattern handler is not used.
* Two handler subscriptions receive requests round-robin.
* A subscription with both callbacks receives `fire` through `onEvent` and answers `request`
  through `handler`.
* `fire` never invokes a handler; `fire` returns `false` for a handler-only topic.
* `removeTopic` cancels handler subscriptions.
* `setHandler`/`EventBusHandlers` no longer exist; `Scope`/`Command`/`FSM` work on subscriptions.
* The transport answers exactly once with overlapping subscriptions; a busy responder sends nothing.
* rxdart is absent from `pubspec.yaml` and the public import.
* Overflow, busy, timeout and cancellation appear in `errors`; the error stream cannot recurse.

### M2

* `fire` on a bridge is outbound only: local listeners receive incoming events, not the side's own
  fires, so a same-topic forwarding listener cannot re-enter itself.
* `fire` returns `false` when only a local or remote handler exists and there is no remote
  listener/model interest.
* `request` with no handler on either side throws `NoHandlerException` immediately.
* A local handler wins over a remote one.
* Cancelling a request on the main side removes it from the worker queue if not dispatched.
* Worker death is detected through `Isolate.addOnExitListener`; pending requests fail with
  `EventBusException` and the remote interest registry is cleared. Generation-based re-sync after a
  restart is E3-06, because restart itself is M3.
* No stale-true `fire` after a listener is gone (best effort, documented).

### M3

* Every dispatch strategy has a test, including per-key ordering for `keyed`.
* A worker crash restarts it with backoff; after max restarts the pool emits a supervision error.
* A failed layer restarts every worker layer except the top one; bridges re-handshake; pending
  requests fail and are not retried.
* The top `Layer` object, its `current` bus and the subscriptions on `layer.bottom` survive a
  restart: the bridge is restarted in place (same object) with a generation counter; calls fail fast
  with `StateError` while the chain is restarting.
* Orphaned workers are torn down by the parent watchdog instead of staying alive after a parent dies.
* Backpressure is a per-worker request credit: saturated workers are skipped, and with no credit
  `fire` is false and `request` throws `BusyException`.
* `broadcast` request is rejected with `UnsupportedError`.

### M4

* Observability off adds no measurable allocation/overhead in the hot path; the benchmark reports
  fire +7.8% and request +3.6% when it is on (within the provisional <10% budget).
* Metrics are consistent with counters: fired/delivered/dropped, request outcomes
  (started/completed/errored/timeout/canceled/busy), overflow, in-flight and queue depth.
* The metric key defaults to the event type token; a custom builder is available, and the
  cardinality limit routes new keys to `__other__` with a `droppedMetricSeries` counter.
* `snapshot()`, the coalesced `changes` stream and `EventBusMetricsExporter` are the read/exporter
  seam; queue-wait latency is recorded per subscription.
* Correlation id survives an isolate hop and a transport hop; errors carry it when known.
* `EventBusErrorMonitor` filters, limits per second, keeps a bounded recent buffer and snapshots by
  kind and topic.
* Tracing spans are deferred: `tracing` and `sampleRate` are carried but no span exporter ships in
  4.0.0.

### M5

* Core package passes tests on VM and Chrome.
* Isolate APIs on Web throw `UnsupportedError`; the capability flag reports `false`.
* Adapters compile against core 4 and pass their suites.

### M6

* The migration guide is exercised on an example that uses `setHandler`, handler errors, `Scope`
  and an isolate.
* The migration script transforms that example mechanically.
* All docs links resolve; CHANGELOG is complete; publish dry-run is clean.

## 8. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `EventNode` refactor breaks transport adapters | High | Do E1-12 together with E1-03; keep the stream facade until adapters compile |
| New `fire` semantics surprises users | High | Migration guide; explicit tests for local/remote/both/none; document the breaking change |
| Per-subscription queues add complexity | Medium | Keep one queue per handler subscription; no shared node queue |
| Whole-chain Layers restart is hard to get right | High | ADR-7 first; test bridge re-handshake and pending failure before implementing pool strategies |
| Web capability assumptions | Low | Spike in E0-09 proved JS compilation and local-bus runtime; split is deferred until a concrete failure appears |
| Error storms | Medium | Rate limiting and bounded recent buffer in E1-13 |
| Dynamic-topic metric cardinality | Medium | Cardinality limit in E4-05 before exposing metrics |
| rxdart removal breaks consumers | Medium | No re-export; migration guide; replace only the one used method |
| Estimate drift | Medium | Ranges per task; 20% contingency at milestone level; cut line below |

## 9. Optional cut line

If schedule pressure appears, defer in this order (the first cut keeps 4.0 coherent):

1. Full observability detail (keep `errors`; defer metrics/exporter to 4.1).
2. `leastBusy`/`single` pool strategies (keep `broadcast`/`roundRobin`/`keyed`).
3. Web polish (keep the core Web build; defer NATS/MQTT WebSocket documentation).

Do not cut: `EventSubscription`, handler subscriptions, request lifecycle, D14 `fire` semantics,
D19 Layers restart, rxdart removal — together they are the reason for 4.0.

## 10. Residual decisions (non-blocking)

| ID | Question | Provisional default |
|---|---|---|
| R1 | Default `requestQueueCapacity` on the bus | 64 |
| R2 | Default `bufferCapacity` for listener subscriptions | `unbounded` (compatibility); `latest(1)` is the recommended preset |
| R3 | API shape of Layers supervision | A controller returned by a new `Layers.supervise(...)`; settle in ADR-7 |
| R4 | Does `onEvent` of a dual subscription receive request events? | Yes, preserving current listener semantics |
| R5 | Migration script implementation | Regex-based for the known API surface; analyzer-based only if needed |
| R6 | `EventBusError` payload capture | Redacted by default; opt-in payload capture |
| R7 | Exporter interface scope | Snapshot + optional stream; concrete exporters live outside the core |

## 11. Working agreement

* One task in progress at a time; update `Status` in this file when starting and finishing.
* A task is `done` only with: implementation, tests, task-level docs/comments, `dart analyze`
  clean, and the relevant suite green.
* Every milestone closes with all its acceptance criteria quoted in the session report.
* ADRs are updated before code when a decision changes; this file links the decision IDs.
* Release is a separate task (E6-05/E6-06); no version bump before the full milestone is green.

## 12. Local verification

This project has no CI. Every milestone is closed with these commands run locally.

### Core and web

```bash
dart pub get
dart analyze
dart test
dart test -p chrome test/web_smoke_test.dart
```

### Packages

```bash
(cd packages/event_bus_arch_transport && dart test)
(cd packages/event_bus_arch_nats && dart test)
(cd packages/event_bus_arch_mqtt && dart test)
```

Without a broker, the NATS/MQTT integration tests are reported as skipped. To run them locally,
start the brokers and set the environment variable for the shell:

```powershell
# PowerShell
$env:NATS_URL = 'nats://127.0.0.1:4222'
$env:MQTT_URL = 'mqtt://127.0.0.1:1883'
```

```bash
# POSIX
NATS_URL=nats://127.0.0.1:4222 MQTT_URL=mqtt://127.0.0.1:1883
```

The local brokers used for development are NATS 2.15.1 and NanoMQ 0.25.6 (started with
`-s 1024`, because the default MQTT user-property size is 32).

### Coverage

```bash
dart test --coverage=coverage
dart pub global activate coverage
dart pub global run coverage:format_coverage \
  --lcov \
  --in=coverage \
  --out=coverage/lcov.info \
  --packages=.dart_tool/package_config.json \
  --report-on=lib
```

### Benchmark smoke

```bash
dart run benchmark/load_benchmark.dart --seconds=1 --rates=1000,10000 --warmup-ms=200
```

### Milestone close record

Record the command output (test counts, skipped integration counts, analyze result) in the session
report and in the milestone status line at the top of this file.
