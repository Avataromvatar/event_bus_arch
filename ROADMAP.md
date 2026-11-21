# event_bus_arch 4.0.0 — Roadmap and task list

Status: **draft for working use**. This file is the single source of truth for the 4.0.0 scope,
decisions, tasks and estimates. Update the `Status` column as work progresses.

Last updated: 2026-11-21.

## 1. Estimate method

* Estimates are **ideal engineer-days (PD)** for one experienced Dart developer.
* They include implementation, unit tests and documentation of the task itself.
* They exclude code review, PR waiting, CI flakiness, broker setup and release logistics.
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
| M0 | ADRs, Web spike, CI scaffolding | 12–17 | Decisions frozen; CI green on 3.x |
| M1 | Core subscription model, request lifecycle, errors, rxdart removal | 34–46 | Task matrix and acceptance criteria pass |
| M2 | Isolate interest sync, `fire`/`request` semantics, cancellation across the bridge | 15–22 | Isolate matrix passes; no stale-true `fire` |
| M3 | WorkerPool and supervision (including whole-chain Layers restart) | 22–30 | Every pool strategy and restart scenario proven |
| M4 | Observability, metrics, correlation, error monitor | 13–19 | Overhead budget met; metrics consistent |
| M5 | Web compatibility and adapter 0.2.0 | 9–14 | Core tests on VM and Chrome pass; adapters compile |
| M6 | Docs, migration guide/script, release | 13–20 | Migration path exercised; release checklist green |
| **Total** | | **118–168** (midpoint ~143) | |

## 5. Task list

Status values: `todo`, `doing`, `done`, `blocked`.

### E0 — Decisions, spikes, foundation (12–17 PD)

| ID | Task | PD | Depends on | Status |
|---|---|---:|---|---|
| E0-01 | ADR-1: listener subscription contract (buffer policies, async callback, timing, stream facade) | 2 | — | todo |
| E0-02 | ADR-2: handler subscription (dual callbacks, per-subscription queue, concurrency, tier dispatch, pause/busy) | 2 | — | todo |
| E0-03 | ADR-3: request lifecycle (timeout, `CancelToken`, queue removal, dispatched discard, exceptions) | 1 | — | todo |
| E0-04 | ADR-4: `EventBusError`, error stream, `EventBusErrorMonitor` | 1 | — | todo |
| E0-05 | ADR-5: isolate interest protocol, `fire`/`request` semantics, cancellation across the bridge | 2 | — | todo |
| E0-06 | ADR-6: observability model, metrics, correlation ids | 1 | — | todo |
| E0-07 | ADR-7: WorkerPool strategies, supervision, whole-chain Layers restart | 2 | — | todo |
| E0-08 | ADR-8: library layout, Web, rxdart removal, migration policy | 1 | — | todo |
| E0-09 | Web spike: confirm what breaks (`dart:isolate`, parts), pick conditional-import layout | 1 | — | todo |
| E0-10 | CI scaffolding: analyze, VM tests, Chrome tests, NATS/MQTT docker, coverage, benchmark smoke | 2 | — | todo |

### E1 — Core subscription model (34–46 PD)

| ID | Task | PD | Depends on | Status |
|---|---|---:|---|---|
| E1-01 | Base `EventSubscription<T>`: pause/resume/cancel, `isPaused`, `isCanceled`, counters, error routing | 1.5 | E0-01 | todo |
| E1-02 | Listener side: sync/async `onEvent`, buffer, overflow policies, `resize`, `.stream` view | 4 | E1-01 | todo |
| E1-03 | Node refactor: subscription registry, fan-out, `currentData`, lifecycle, `removeTopic` | 4 | E1-01 | todo |
| E1-04 | Handler side: `handler`, `handlerConcurrency`, `isBusy`, `inFlight` | 2 | E1-01 | todo |
| E1-05 | Per-subscription bounded FIFO request queue; bus default + override; capacity 0 | 3 | E1-04 | todo |
| E1-06 | Dispatcher: exact/pattern tier, round-robin, paused/busy filtering, queue selection | 4 | E1-04, E1-05 | todo |
| E1-07 | Dual-callback subscription: `onEvent` + `handler` semantics and tests | 1 | E1-02, E1-04 | todo |
| E1-08 | Request lifecycle: timeout, `CancelToken`, queue removal, dispatched discard, `lastData` snapshot | 3 | E1-05, E1-06 | todo |
| E1-09 | Exceptions and queries: `NoHandler`, `Busy`, `RequestTimeout`, `RequestCanceled`, `haveHandler`, `haveAvailableHandler` | 1 | E1-06 | todo |
| E1-10 | Remove old handler API: `EventBusHandlers`, `setHandler`, `removeHandler`, `addAll...`, `removeAll...` | 1.5 | E1-04 | todo |
| E1-11 | Migrate `Scope`/`Command`/`FSM`: `Scope` `latest(1)`, `FSM` `unbounded` | 2 | E1-10 | todo |
| E1-12 | Transport adaptation: resolve handler subscription, single answer, busy without response | 4 | E1-06, E1-09 | todo |
| E1-13 | `EventBusError` envelope, `EventBus.errors`, `EventBusErrorMonitor` skeleton | 3 | E0-04 | todo |
| E1-14 | Remove rxdart: native `doOnCancel` replacement, export and dependency removal | 1 | E1-02 | todo |
| E1-15 | Test matrix: buffers, queues, tiers, pause, cancellation, dual callbacks, lifecycle | 5 | E1-01..E1-14 | todo |
| E1-16 | Benchmarks: delivery overhead, queue overhead, memory, before/after | 1.5 | E1-15 | todo |

### E2 — Isolate semantics (15–22 PD)

| ID | Task | PD | Depends on | Status |
|---|---|---:|---|---|
| E2-01 | Interest model: listener/handler, exact/pattern, protocol messages | 2.5 | E1-13, E0-05 | todo |
| E2-02 | Interest sync on register/cancel/remove; initial handshake and `waitInit` | 3 | E2-01 | todo |
| E2-03 | `fire`: local delivery + remote send on listener interest; new return semantics | 2 | E2-02 | todo |
| E2-04 | `request`: local handler first, remote handler interest, immediate `NoHandlerException` | 2 | E2-02 | todo |
| E2-05 | Cancellation across the bridge: `_IsolateCancel`, queue removal, discarded response | 3 | E1-08, E2-04 | todo |
| E2-06 | Resync after worker death/restart, generation counter | 2 | E2-02 | todo |
| E2-07 | Test matrix: local/remote/both/none, patterns, model bus, cancellation, restart | 4 | E2-03..E2-06 | todo |

### E3 — WorkerPool and supervision (22–30 PD)

| ID | Task | PD | Depends on | Status |
|---|---|---:|---|---|
| E3-01 | Pool core: N `EventBusIsolate`, lifecycle, readiness, dispose | 3 | E2-07 | todo |
| E3-02 | Dispatch strategies: `broadcast`, `roundRobin`, `keyed`, `leastBusy`, `single` | 5 | E3-01 | todo |
| E3-03 | Request routing in the pool; `broadcast` forbidden for requests; busy/queues | 2 | E3-02 | todo |
| E3-04 | Pool backpressure: credit windows, bounded queues, metrics | 2 | E3-02 | todo |
| E3-05 | Worker supervision: crash detection, backoff, max intensity, give-up error | 4 | E3-01 | todo |
| E3-06 | Layers supervisor: whole worker-chain restart except top, bridge re-handshake, unavailable state, pending failure | 6 | E3-05 | todo |
| E3-07 | Tests: strategies, worker crash, whole-chain restart, pending requests, no retry | 4 | E3-02, E3-06 | todo |

### E4 — Observability (13–19 PD)

| ID | Task | PD | Depends on | Status |
|---|---|---:|---|---|
| E4-01 | `ObservabilityConfig` and toggle; zero allocations when off | 2 | E1-13 | todo |
| E4-02 | Metrics model: per topic/subscription, queue depth, busy, timeouts, cancellations | 3 | E4-01 | todo |
| E4-03 | Snapshot + stream + exporter interface | 2 | E4-02 | todo |
| E4-04 | Correlation id on `EventDTO`; propagation across isolates and transports | 3 | E1-13 | todo |
| E4-05 | Cardinality limits and aggregation for dynamic topics | 2 | E4-02 | todo |
| E4-06 | `EventBusErrorMonitor`: multi-bus aggregation, filters, rate limit, bounded recent buffer | 2 | E1-13 | todo |
| E4-07 | Tests and overhead benchmark (on/off) | 2 | E4-03..E4-06 | todo |

### E5 — Web and adapters (9–14 PD)

| ID | Task | PD | Depends on | Status |
|---|---|---:|---|---|
| E5-01 | Library split and conditional imports/stubs for isolate features | 4 | E0-09, E1-14 | todo |
| E5-02 | Capability flag; isolate APIs throw `UnsupportedError` on Web | 1 | E5-01 | todo |
| E5-03 | Core tests on Chrome and CI matrix | 2 | E5-01 | todo |
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

* `fire` returns `false` when only a remote handler exists and there is no local/model/transport
  acceptance.
* `request` with no handler on either side throws `NoHandlerException` immediately.
* A local handler wins over a remote one.
* Cancelling a request on the main side removes it from the worker queue if not dispatched.
* Interest is resynced after a worker restart; no stale-true `fire` after a listener is gone
  (best effort, documented).

### M3

* Every dispatch strategy has a test, including per-key ordering for `keyed`.
* A worker crash restarts it with backoff; after max restarts the pool emits a supervision error.
* A failed layer restarts every worker layer except the top one; bridges re-handshake; pending
  requests fail and are not retried.
* `broadcast` request is rejected with a documented exception.

### M4

* Observability off adds no measurable allocation/overhead in the hot path.
* Metrics are consistent with counters: fired/delivered/dropped/errors/requests/busy/timeouts.
* Dynamic topics do not grow the metric registry without bound.
* Correlation id survives an isolate hop and a transport hop.

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
| Web library split touches the `part` layout | Medium | Spike in E0-09; do the split before E1-14 |
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
