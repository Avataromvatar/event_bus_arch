# event_bus_arch — product and production-readiness analysis

- Date: 2026-11-26
- Revision: master @ 9a0cb35, published core 4.1.0 (2026-11-23)
- Scope: five packages (`event_bus_arch`, `_patterns`, `_transport`, `_nats`, `_mqtt`),
  documentation, tests, packaging and publication state
- Companion evidence: [2026-11-26-test-evidence.md](2026-11-26-test-evidence.md)
- Status: analysis; no code changed

---

## 1. Verdict

The product is a genuinely differentiated event bus, and the 4.x code is in better shape than
most solo-maintained Dart packages: 380 tests pass (397 including real NATS and MQTT brokers),
the analyzer is clean apart from 19 infos, core line coverage is 87%, the benchmarks show
~100,000 events/s without loss or duplication, and the documentation is unusually thorough.

It is **not yet production-ready for broad adoption**, because production readiness for a library
is not only code quality. Five things are missing, and all of them are cheap relative to their
impact:

1. **No release engineering** — no CI, no formatting gate, no broker integration job, no release
   automation. Nothing prevents the next commit from breaking the package.
2. **Publication is under-optimised** — 130/160 pub points on the core (description, example,
   analyzer infos), 140–150/160 on the others; no verified publisher; archives include the whole
   workspace and dev scripts.
3. **No stability contract** — 4.0.0 was followed by 4.1.0 one day later, after a breaking 4.0.0
   only a month after 3.0.0; the sub-packages are 0.x; there is no support policy or removal date
   for deprecated APIs.
4. **No documented guarantees** — delivery semantics, ordering, backpressure limits and broker
   guarantees live in an internal remediation plan, not in the user documentation.
5. **No adoption engine** — 4 likes, 401 downloads/30 days, 3 GitHub stars, no example app, no
   launch, no external users feeding back issues.

On top of the systemic gaps, the independent review found **two release blockers**: the isolate
bridge echoes `removeAddress` between isolates (R-01 — reproduced at 5,892 calls in 300 ms), and
`dispose`/`cancel` hang forever when any stream listener is paused (R-16 — reproduced for the bus,
a subscription and the error monitor). Five high findings follow: the worker watchdog kills a live
worker on one missed pong (R-02), a death during pool start is not supervised (R-03), a sync
listener that mutates the bus crashes `fire` (R-17), MQTT `ws://`/`wss://` is documented but
broken (R-04), and a transport request without a timeout can hang across a disconnect (R-05). The
core routing model and the NATS/TCP paths are otherwise usable; the defects cluster in lifecycle
edges, not in the product idea.

Recommended verdict: **technical preview today, with those blockers named in the README; production
release after a focused 5–6 week push** (epics Q1–Q5, ~22–33 person-days including the lifecycle
fixes), then growth work (A1–A3). The code does not need a rewrite; it needs release discipline, a
stability contract, the lifecycle fixes and distribution.

---

## 2. The product

### 2.1 The idea in one sentence

**One event model from a single isolate to a broker: the event address is the stable contract, the
Dart type is a local delivery filter, and the same `fire` / `request` / `subscribe` code works
in-process, across isolates and over NATS or MQTT.**

### 2.2 The two insights behind it

1. **In a distributed system, the Dart type is not an identity.** It is minified (`Type.toString()`
   becomes `minified:bd`), it differs across processes and versions, and it is not a wire contract.
   The stable identity is an explicit string address chosen by the application
   (`orders.placed.v1`). Locally, however, the type is exactly what gives safety and routing.
   Separating the two gives both: `(address, Type)` is a node, the address goes on the wire, the
   type stays local. This is the core idea, documented in ADR-0009 and verified in a recorded
   `dart compile js -O2` experiment — though that check is not yet committed as an automated test
   (F-22).
2. **Production eventing is more than pub/sub.** Real systems need request/reply, timeouts and
   cancellation, bounded buffers and overflow policies, handler concurrency, worker supervision,
   metrics and an error stream. Building these once in the bus stops every application from
   reinventing them, differently and badly.

### 2.3 Who it is for, and the jobs it does

| User | Job to be done | What the library gives |
|---|---|---|
| Flutter app developer | "Move heavy work off the UI isolate without rewriting my event code" | `EventBusIsolate`, `WorkerPool`, `Layers`, typed keys across the port |
| Dart backend developer | "Connect services over NATS/MQTT with the same event API I use locally" | `_transport` seam, `_nats` and `_mqtt` adapters, typed codecs, request/reply |
| Team building an event-driven app | "Decouple components and see what happens in production" | explicit addresses, correlation ids, metrics, `bus.errors`, backpressure |
| IoT / edge developer | "Deliver typed events over MQTT 5" | MQTT 5 adapter with QoS, sessions, TLS options |
| Library author / platform team | "Give applications one eventing model instead of five" | core routing only; patterns and transports are opt-in packages |

### 2.4 Value proposition

- **Continuity across boundaries.** The same model at three scales — one isolate, many isolates,
  many processes. This is the differentiator no mainstream Dart event bus offers.
- **Type safety that survives release builds.** Keys are captured with `Type _typeOf<T>() => T;`,
  not `runtimeType.toString()`, so routing survives `dart compile js -O2` and AOT.
- **Production features built in.** Bounded buffers (`latest`, `dropOldest`, `dropNewest`,
  `reject`), handler concurrency and request queues, request timeout/cancellation, worker restart
  supervision, metrics, error envelopes with rate limiting, correlation ids.
- **Evidence, not claims.** A reproducible benchmark measures 100k events/s local and isolate
  paths with zero loss/duplication on sequence numbers; the docs include Mermaid diagrams and an
  ADR trail.
- **Small dependency footprint.** The core code uses only the Dart SDK; the declared `intl` and
  `async` dependencies are unused and should be removed, leaving the core dependency-free.
- **Economic value.** A team that needs isolate workers, request/reply, backpressure, reconnect,
  metrics and a broker adapter would otherwise spend one to three developer-weeks assembling and
  debugging those pieces, and would still own the edge cases. The library turns that into a
  dependency with tests and a documented model. The value is highest exactly where the team would
  otherwise build a bespoke event layer.

### 2.5 Alternatives and positioning

| Alternative | Strength | What it does not do | Our position |
|---|---|---|---|
| [`event_bus`](https://pub.dev/packages/event_bus) (749 likes, 369k dl/30d) | Tiny, simple, stable, well known | In-process only; string topics; no request/reply, isolates, transports or observability | "When `event_bus` is not enough, and you do not want to assemble five packages" |
| `rxdart` (2.9k likes, 6.5M dl/30d) | Rich stream operators | Not an event bus; no address/type routing, no isolates, no transport, no request lifecycle | Complement, not competitor |
| `bloc` (3.2k likes, 2.5M dl/30d) | State management with a strong ecosystem | UI state, not application eventing; no cross-process story | Different job |
| `event_bus_plus` (40 likes, 5.3k dl/30d) | Small event bus | No isolate/worker or broker story | Same niche, less depth |
| Hand-rolled `StreamController` + `Isolate.spawn` + broker client | Zero dependency, full control | All the hard parts are yours: cancellation, backpressure, reconnect, observability, type identity | "Buy the hard parts, keep the app" |

The honest positioning is **not** "a better simple event bus". It is **"the event bus for systems
that outgrow one isolate"**: Flutter apps with real background compute, Dart services on NATS, and
MQTT edge applications. The package already ranks first on pub.dev for "isolate event bus"; that
is the niche to own.

### 2.6 When not to use it

This section is missing from the README and should be added; it prevents disappointed users and
builds trust:

- A simple in-app notification bus → use `event_bus` or plain streams.
- UI state management → use `bloc`/`riverpod`.
- Durable messaging, replay or exactly-once delivery → use a broker's native durable features
  (JetStream, Kafka); this library is a bus, not a queue.
- Browser-only apps that need isolate workers → isolates do not exist on the web; only the local
  bus and the transport seam are portable.

### 2.7 Traction baseline (2026-11-26)

| Signal | Core | Patterns | Transport | NATS | MQTT |
|---|---:|---:|---:|---:|---:|
| pub.dev points | 130/160 | 150/160 | 150/160 | 140/160 | 140/160 |
| Likes | 4 | 0 | 0 | 0 | 0 |
| Downloads / 30 days | 401 | 45 | 138 | 133 | 130 |
| Version | 4.1.0 | 0.1.0 | 0.2.0 | 1.1.0 | 0.2.0 |

GitHub: 3 stars, 0 forks, 0 open issues, 1 subscriber, no description, no topics, no discussions,
releases only up to v3.0.0 (4.0.0/4.1.0 tagged but not released). Publisher is not verified.
There is no visible external adoption yet: no external issues, no "used by" references, no
community. The download counts are small enough that they may include CI and mirrors, so they are
a baseline, not proof of users. The product has no feedback loop yet.

---

## 3. Readiness assessment

### 3.1 Evidence

| Check | Result | Source |
|---|---|---|
| Static analysis | 19 infos, 0 warnings, 0 errors | `dart analyze` |
| Core tests | 280 passed in 15 s | `dart test` |
| Patterns / transport / NATS / MQTT | 21 / 36 / 24 (+10 skipped) / 19 (+7 skipped) passed | per-package `dart test` |
| Broker integration, real servers | NATS 34/34, MQTT 26/26 passed | Docker `nats:2.10-alpine`, `eclipse-mosquitto:2` |
| Web smoke (Chrome) | 6 passed | `dart test -p chrome test/web_smoke_test.dart` |
| Web compile | `dart compile js tool/web_compile_check.dart` succeeds | 265 KB JS |
| Coverage, core lib | 87.0% lines (1848/2125) | `dart test --coverage` |
| Coverage, patterns lib | 87.4% (104/119) | same |
| dartdoc | 5 warnings, 0 errors; 1 public library | `dart doc` |
| Formatting | 53 of 108 files would be reformatted by Dart 3.14 formatter | `dart format --set-exit-if-changed` |
| Dependencies | all direct dependencies current | `dart pub outdated` |
| Publish dry-run | 0 warnings, 179 KB archive | `dart pub publish --dry-run` |
| README quick start | works verbatim from a fresh project, both against the working tree and the published 4.1.0 | `/tmp/eba_quickstart`, `/tmp/eba_published`; output in the evidence file |
| CI | none | no `.github/` |
| Broker integration | skipped without `NATS_URL` / `MQTT_URL` | test output |

### 3.2 What is strong

- **Coherent architecture.** The 4.x address/key model is documented, decided in an ADR and
  covered by tests; patterns and transports are separate packages; the core stays a routing
  library.
- **Test discipline.** 403 test declarations and 971 assertions (380 runnable on the VM, 17
  broker-gated, 6 web); there is almost no real sleeping in the suite, so tests use controlled
  fakes rather than delays; regression tests exist for the defects found by the third-party
  review; `naming_test.dart` treats public parameter names as part of the contract and breaks the
  build if one is renamed.
- **Documentation depth.** Seven user documents, Mermaid diagrams, an API reference, package
  READMEs, a migration tool from 3.x, and benchmark methodology. This is above the Dart OSS
  average.
- **Performance evidence.** The benchmark is open-loop, sequence-tagged and reports loss,
  duplication and percentiles; ~100k events/s local and isolate, isolate request p99 0.43 ms at
  that rate.
- **Correctness work already done.** The 2026-11-23 remediation plan closed 17 defects (transport
  local-first delivery, least-busy rotation, isolate init timeout, cancel-token cleanup, error
  window LRU, buffer semantics, type-aware interest, request fallback) with regression tests.
- **Broker integration tests are real.** Started NATS 2.10 and Mosquitto 2 in Docker; the full
  integration suites passed (NATS 34/34, MQTT 26/26), including requests, timeouts, wildcards,
  arguments and self-echo suppression. The tests exist; only the CI job is missing.
- **Healthy supply chain.** MIT license on all five packages; the core has no runtime dependency
  once the unused `intl`/`async` entries are removed; the broker clients are maintained
  (`dart_nats` 1.7.1, `mqtt5_client` 5.4.1, both 160/160 pub points and updated in November 2026);
  no secrets or credentials in the repository.

### 3.3 Readiness by area

| Area | Verdict | Why |
|---|---|---|
| Core correctness | **Red–amber** | Two verified blockers (R-16 shutdown hang with a paused listener; R-17 sync reentrancy crash) and three medium lifecycle/observability defects; 280 green tests and 87% coverage did not cover these windows. The routing model itself is sound |
| Isolates / workers | **Red–amber** | Two verified high defects (watchdog kills a live worker on one missed pong; a death during pool start is not supervised) and one blocker in `removeAddress` across the bridge; strong tests otherwise, but the tested scenarios miss these windows. VM-only, port-queue backpressure is unbounded, protocol has no version field |
| Transport adapters | **Amber** | The full integration suites pass against real NATS 2.10 and Mosquitto 2 (34/34 and 26/26), but a request without a timeout can hang across a disconnect, MQTT `ws://`/`wss://` is documented but broken, CI does not run broker tests, and per-adapter guarantees are under-documented |
| API stability | **Amber–red** | 41 public types, several implementation types exposed; `request` returns `dynamic`; deprecated `have*` has no date; sub-packages at 0.x; breaking cadence is fast |
| Packaging / publication | **Red** | 130–150/160 points; archive contains the whole workspace and dev scripts; no example recognised; no verified publisher; stale repository URL; descriptions out of range |
| Release engineering | **Red** | No CI, no formatting gate, no release automation, no coverage or broker jobs, no branch protection |
| Documentation | **Amber** | Excellent narrative docs; 70.9% API documented; no recognised example; no guarantees/limitations section; no docs site; package SDK floors contradict READMEs |
| Web story | **Amber** | Runtime works (compile + Chrome tests pass), but pub.dev marks Web unsupported because the entry library imports `dart:isolate`; no platform badge |
| Community / support | **Red** | No CONTRIBUTING, CODE_OF_CONDUCT, SECURITY, issue templates, discussions, roadmap or release notes; no visible external users |

Reading the table: a green suite is not a green product. R-01, R-02 and R-03 all pass the
existing tests because the tests do not exercise those windows. The verdicts reflect what an
adopter would hit, not how many tests exist.

### 3.4 Risks to the plan

| Risk | Why it matters | Mitigation |
|---|---|---|
| Solo-maintainer capacity | Five packages × three OS targets × two SDK floors × two brokers is not manually verifiable; the first regression that ships will cost the early adopters | Q1 first: automate everything before adding scope |
| Scope creep | Adding a third transport or a new pattern before the base is trustworthy spreads the same effort thinner | Freeze the adapter list; depth before breadth (A2 acceptance rule) |
| Breaking-change cadence | 3.0 → 4.0 → 4.1 in five weeks tells adopters the API is not settled; another major soon would burn the first users | Stability policy, ship 4.2 as the production release, batch the breaking cleanup into 5.0 (Q4) |
| Lifecycle edges are under-tested | Two blockers and three highs passed 280 tests because the suite does not cover paused listeners, sync reentrancy, reconnects or start-window deaths | Q3 adds targeted regression tests for each; Q1 runs them on every change |
| Documentation drift | Excellent docs are a liability if snippets stop compiling; there is no doc test today | Compile examples and quick starts in CI (Q1/Q5) |
| No feedback loop | With zero external users, the roadmap is guesswork and the value proposition is unvalidated | Launch after Q2/Q5, then interview the first ten users; measure downloads, issues, likes |

### 3.5 What "production" means for a library

For an application, production means deployed and monitored. For a library, production means a
consumer can depend on it and be safe:

1. every published version is built and tested by an automated pipeline;
2. the API has a stability contract and a deprecation policy;
3. behaviour that consumers rely on is documented as a guarantee, including its limits;
4. the package is discoverable, correctly packaged and trusted (metadata, verified publisher,
   example, changelog, license);
5. there is a support path (issues, security policy, response expectation).

The code already meets most of the "works" bar; the remaining work is mostly 1–5.

---

## 4. Findings register

Priority: **P0** blocks a production release; **P1** should land before 1.0 or the first launch;
**P2** improves quality or adoption and can follow.

### 4.1 Release engineering and packaging

| ID | Priority | Finding | Evidence |
|---|---|---|---|
| F-01 | P0 | No CI at all: no analyzer, test, format, coverage, web or broker job | no `.github/`; verification is manual |
| F-02 | P0 | 53 of 108 files are not formatted by the current stable formatter; no format gate | `dart format --set-exit-if-changed` reports 53 changed on Dart 3.14 |
| F-03 | P0 | The published core archive contains `packages/` (all four workspace packages) and the dev scripts `build_script.sh`/`pubspec_changer.dart`; `test/`, `doc/` and `tool/` are acceptable but inflate the archive to 179 KB | `dart pub publish --dry-run` tree and the published 4.1.0 tarball; no `.pubignore` |
| F-04 | P1 | Core description is 237 chars (limit 180) → 0/10 conventions; NATS 34 and MQTT 36 chars (min 50) → 0/10 | pub.dev score pages; `pubspec.yaml` |
| F-05 | P1 | No recognised example → 0/10 documentation for core, patterns and transport | pana recognises `example/<package>_example.dart`: NATS and MQTT have it; core has the misspelled `event_bus_arch_exmple.dart`, patterns has only `fsm_example.dart`, transport has an empty `example/` |
| F-06 | P1 | 15 analyzer infos on pub.dev (library name, part-of URIs) → 40/50 analysis; locally 19 including tests and super parameters | `dart analyze`; pub.dev score |
| F-07 | P1 | Repository URL in all five pubspecs points to the old name `dart_event_bus` (redirects, but stale); no `homepage`, `issue_tracker`, `topics` | pubspecs; GitHub API |
| F-08 | P1 | No verified publisher; `publisherId: null` | pub.dev API |
| F-09 | P1 | Unused direct dependencies `intl` and `async` in the core pubspec | no imports in `lib/`; commented import only |
| F-10 | P2 | SDK floors disagree: core `>=3.6.0`, MQTT `^3.8.0`, package READMEs say 3.12 | pubspecs vs READMEs |
| F-11 | P2 | `CHANGELOG.md` starts at 4.0.0; 3.x history is gone; GitHub releases stop at v3.0.0 although v4.x tags exist | `CHANGELOG.md`; GitHub API |
| F-12 | P2 | `dart doc` has 5 warnings (no library-level doc, unresolved references) | `dart doc` |

### 4.2 Correctness, API and documentation

| ID | Priority | Finding | Evidence |
|---|---|---|---|
| F-13 | P1 | Delivery guarantees and limits are not in user docs: `fire` is best-effort, no ack, no persistence; isolate queues can grow without bound; broker semantics differ | remediation plan §Decisions; benchmark README "no backpressure"; no guarantees section in README/doc |
| F-14 | P1 | API surface exports implementation types: 41 public classes including `EventBusImpl`, `EventDTOImpl`, `EventNodeImp`, `SubscriptionHost`, `KeepAliveNode`; docs coverage 70.9% and every internal becomes a compatibility obligation | `lib/event_bus_arch.dart` (single library with parts); pub.dev docs |
| F-15 | P1 | `request` returns `Future<dynamic>` — callers must cast; no typed response contract | `lib/src/event_bus.dart` `request<T>` signature |
| F-16 | P1 | Deprecated `have*` APIs have no removal version beyond "5.0"; the test-only legacy facade keeps old semantics alive | `@Deprecated` comments; `test/legacy_compat.dart` |
| F-17 | P1 | Web is marked unsupported by pub.dev because the entry library imports `dart:isolate` unconditionally, although the web build and Chrome tests pass | pub.dev score "Web unsupported"; `lib/event_bus_arch.dart:4`; `doc/07-platforms.md` |
| F-18 | P1 | Coverage gaps in contract-critical code: `event_dto.dart` 50%, `event_probe.dart` 55.6%, `event_bus_logger.dart` 57.1%. `EventDTO.copyWith` has no test; `toJson`/`fromJson` have one test each; the legacy `topic` alias and `dataConverter` paths are unverified | coverage report; `test/naming_test.dart:94`, `test/event_key_bus_test.dart:242` |
| F-19 | P2 | The version cadence signals instability: 3.0.0 (2026-10-19) → 4.0.0 (2026-11-22) → 4.1.0 (2026-11-23); sub-packages remain 0.x | git tags; pub.dev |
| F-20 | P2 | `dart format` and analyzer rules are not enforced anywhere; `analysis_options.yaml` has no strict rules | `analysis_options.yaml` |
| F-21 | P2 | No security policy, contributing guide, code of conduct, issue/PR templates or discussions | repo root; GitHub API |
| F-22 | P1 | The obfuscation check claimed in CHANGELOG and docs is not committed as a runnable test or tool; `tool/web_compile_check.dart` only compiles and prints, it does not assert key identity or publish count | `CHANGELOG.md:9,39`; `tool/web_compile_check.dart`; no matching test |

### 4.3 Independent code review

Two read-only reviewer sessions worked from briefs in
`.agai/briefs/4f8971a6-0afb-44b1-b6b9-f336b0f127f0/`: one on core routing/subscriptions/DTO/
observability, one on isolates/workers/layers/transport/NATS/MQTT. They did not modify files and
did not run the suites; the coordinator verified the top findings against the code and reproduced
both blockers with executable tests.

| ID | Severity | Location | Finding and failure scenario | Verification | Action |
|---|---|---|---|---|---|
| R-01 | **P0 blocker** | `lib/src/event_bus_isolate.dart:389-390`, `:695-707`, `:1043-1051` | `removeAddress` across an isolate bridge loops forever: the `_IsolateDeleteAddress` handler calls the public `_host.removeAddress`, whose override sends the delete back; both sides echo until disposal. A second failure mode: a delete arriving before readiness throws `StateError` inside the port listener. | **Reproduced**: a counting subclass recorded **5,892 calls in 300 ms** after one `iso.removeAddress(...)`. `remove(selector)` is safe. The existing test passes only because it disposes immediately (`test/event_isolate_key_test.dart:108-126`). | Q3, fix before release |
| R-02 | High | `event_bus_isolate.dart:922-929`, `:885` | The worker watchdog pings every 1 s with a 500 ms timeout and kills the worker on one missed pong. Pong handling runs on the parent's event loop, so a main-isolate sync block of ~1.5 s kills a healthy worker; in a pool this triggers restarts and can exhaust supervision, failing the pool permanently. | Code reading; no blocking-parent test exists | Q3 + guarantees doc |
| R-03 | High | `worker_pool.dart:538-552`, `:484-525` | A worker that dies after its own `waitInit` but before the pool sets `_started` is not supervised: `_handleDeath` returns on `!_started`, `slot.ready` stays true, the pool reports ready with a dead slot, and a request to it throws a raw `StateError`. Requires at least two workers (one still spawning). | Code reading; no test for this window | Q3 |
| R-04 | High | `packages/event_bus_arch_mqtt/lib/src/mqtt5_client_connection.dart:50-90` | The documented `ws://`/`wss://` support does not work: the client receives a bare host, while `mqtt5_client 5.4.1` requires a `ws(s)://` server string (`mqtt_server_ws_connection.dart:100-110`); for `wss` the adapter sets `secure = true`, and `MqttServerClient.connect` then disables WebSocket (`mqtt_server_client.dart:117-128`); `broker.path` (`/mqtt`) is ignored. | Verified against the installed `mqtt5_client` source; not run against a WS broker | Q3/Q4: fix or remove the claim |
| R-05 | High | `packages/event_bus_arch_transport/lib/src/reconnecting_transport_connection.dart:134-175`, `:222-230` | A transport `request` with no timeout can hang forever: if the connection drops after publish, `handleDrop` does not fail pending requests, the reply subject is re-subscribed on reconnect, and the response went to the old socket. The caller's future never completes; the reply registration leaks and is re-subscribed on every reconnect. | Code reading; no disconnect-with-pending-request test | Q3 |
| R-06 | Medium | `lib/src/layers.dart:116-124` | `Layers.createLayers(timeout:)` throws on timeout without closing the partially built chain; if initialisation later succeeds, the isolate chain lives with no owner. | Code reading | Q3 |
| R-07 | Medium | `event_bus_isolate.dart:501-512`; `layers.dart:96,112-115,232-235`; `worker_pool.dart:510-517` | `timeout: null` in `Layers`/`WorkerPool` does not disable the per-bridge 30 s `initTimeout`; `WorkerPool` has no parameter at all. A 35 s model load fails the pool permanently despite an "unlimited" outer timeout. | Code reading | Q3 |
| R-08 | Medium | `worker_pool.dart:424-441`, `:24`, `:157-159` | `DispatchStrategy.single` switches to the standby worker on saturation (no free credit), not only on death, breaking the serialisation the strategy is chosen for; code and docs disagree. | Code reading | Q3 + decide the contract |
| R-09 | Medium | `packages/event_bus_arch_transport/lib/src/transport_event_bus.dart:78-84` | `waitConnected()` can hang forever: it waits for the first `connected` status without handling `closed`, and a status event between the `isConnected` check and the subscription is lost (broadcast stream). | Code reading | Q3 |
| R-10 | Medium | `event_bus_isolate.dart:396-416` | A handler result or error that cannot be sent over the port kills the worker (or raises an uncaught async error on the main side) instead of failing the request cleanly. The sendability limit is documented; the failure mode is not. | Code reading | Q3 + guarantees doc |
| R-11 | Low | `event_bus_isolate.dart:752-758`, `:801-803` | After an `initTimeout`, the worker is not stopped; a late ready sets `isInit == true` and the isolate keeps running unless disposed. | Code reading | Q3 |
| R-12 | Low | `event_bus_isolate.dart:599-613`, `event_bus.dart:1091-1097` | A pre-cancelled request served by a local handler records `started`/`canceled` twice (isolate and core). | Code reading | Q3 |
| R-13 | Low | `layers.dart:294-320` | `LayersSupervisor` can stay in `restarting` forever if the layer was closed directly and a late failure arrives; `waitReady` hangs. | Code reading | Q3 |
| R-14 | Low | `packages/event_bus_arch_transport/lib/src/transport_event_bus.dart:191-198` | A transport request timeout surfaces as `TimeoutException`, not the core `RequestTimeoutException`; shared handlers and metrics miss it. | Code reading | Q3 |
| R-15 | Low | `packages/event_bus_arch_mqtt/lib/src/mqtt5_client_connection.dart:64-65,70,86` | Without `originId`, the MQTT client id is generated twice (connection and CONNECT), so a persistent session changes identity on reconnect. Not reachable through `EventBusMqtt.keys` (originId always set). | Code reading | Q3/Q4 |

**Design preferences (not defects):** duplicated backoff policy in `worker_pool.dart:36-69` and
`reconnect_policy.dart:1-45`; duplicated interest-snapshot code; no jitter in reconnect backoff
(thundering herd); `TransportConnection.errors` is `Stream<Object>` rather than typed errors.

**What the review did not check:** core routing/subscription internals outside the bridge,
`event_bus_arch_patterns`, packaging, CI, docs accuracy; no broker was started by the reviewers
(the coordinator separately ran the real-broker suites); no performance or memory measurement.
The core reviewer's report is merged in §4.3.1.

#### 4.3.1 Core surface review

The core reviewer read the routing, subscription, DTO, error and observability sources end to end.
The coordinator reproduced its blocker and its high finding; the rest are code-reading findings.

| ID | Severity | Location | Finding and failure scenario | Verification | Action |
|---|---|---|---|---|---|
| R-16 | **P0 blocker** | `event_bus.dart:916-922,934`, `:130-138`; `event_subscription.dart:357-382`; `event_bus_error.dart:215-222`; `observability.dart:460` | `await bus.dispose()`, `await sub.cancel()` and `await monitor.dispose()` never complete when a stream listener is paused: the code awaits `StreamController.close()`, whose future waits for paused listeners to resume or cancel. A paused listener is a documented backpressure pattern (`doc/03-subscriptions.md:15`), and `await bus.dispose()` is the documented shutdown (`README.md:75`). | **Reproduced**: all three hang; 2 s timeouts expired in `bus.dispose` (paused raw listener), `sub.cancel` (paused `.stream` listener) and `monitor.dispose` (paused listener). | Q3, fix before release |
| R-17 | High | `event_bus.dart:734,738-741`, `:812-818`, `:868-895`; `event_subscription.dart:357-368`; `EventNodeImp.deliver` | A sync listener (`DeliveryMode.sync`) that mutates the bus during delivery breaks the dispatch loop: `bus.remove(key)` → `ConcurrentModificationError`; `bus.removeAddress(...)` disposes the next node and its delivery throws `StateError: Cannot add new events after calling close`. The event is lost for the remaining listeners and `fire` throws. | **Reproduced**: a sync listener removing its own key while another type node followed threw `ConcurrentModificationError`; removing the address threw `StateError`. | Q3 |
| R-18 | Medium | `event_bus.dart:397,823,891,930,1079-1080` | `_handlerCursors` is keyed by route but only cleaned by node/never; dynamic request addresses (`session.<id>`) leak one entry per address until `dispose`. | Code reading | Q3 |
| R-19 | Medium | `event_bus_error.dart:130,135,155-158,178-179` | `EventBusErrorMonitor._byTopic` is unbounded for dynamic addresses, and `add(bus)` keeps a disposed bus and its subscription until `remove`/`dispose` (the logger removes itself on `onDone`). | Code reading | Q3 |
| R-20 | Medium | `event_probe.dart:32-38,72-75`; `event_bus.dart:546-556,706-707`; `event_subscription.dart:192-194,390-394,401-404` | Probe contract disagrees with delivery: a paused `bufferCapacity: 0` + `reject` subscription is counted by `probeFire.accepted`, but `fire` returns false; `probeRequest.hasHandler` is true for a busy handler while `request` throws `BusyException`. Doc comments promise equivalence; the plan calls probes a snapshot. | Code reading | Q3 + decide the contract |
| R-21 | Low | `event_bus.dart:944-953,979-988,1174-1176,274,918-922` | The "after dispose public methods throw `StateError`" contract is broken by `haveHandler`, `haveAvailableHandler`, `handlerAddressFor`, `handleIncomingRequest`; reading `metrics` after dispose creates a new metrics object whose `changes` never closes. | Code reading | Q3 |
| R-22 | Low | `event_subscription.dart:384-419,283-284`; `event_bus.dart:706-707` | `fire` returns true when the only listeners dropped the event via `dropNewest` or `bufferCapacity: 0`; the docs say true means "a listener accepted the event". | Code reading | Q3 |
| R-23 | Low | `event_dto.dart:102-114`, `:52`, `:79-88` | `EventDTO.fromJson` does not validate `address` or `data is T`; bad input surfaces as a raw `TypeError` or a later handler error, not a deserialization error. `data` is publicly mutable while `==`/`hashCode` depend on it. `arguments` are not serialized. | Code reading | Q3/Q4 |
| R-24 | Low | `observability.dart:80-81` vs `:100-106` | The latency histogram documents an inclusive upper bound but the bucket search is exclusive; a value exactly on a boundary lands in the next bucket. | Code reading | Q3 |
| R-25 | Low | `observability.dart:324-331` | `sampleRate > 0.5` rounds `every` to 1 and always samples; 0.7–0.9 do not reduce cost as a user expects. | Code reading | Q3 |
| R-26 | Low | `event_bus.dart:754-772`; `event_address.dart:32,77,121-136` | The pattern hot path allocates a Map, a List and a sort on every `fire`/`request`, even with no patterns; `tokens` splits on every comparison. | Code reading, not benchmarked | Q3 (performance pass) |
| R-27 | Low | `event_subscription.dart:192-194,154-155,285-286` | `hasListener`/`hasHandler` stay true after `cancel()`, although the doc says "can receive events right now". | Code reading | Q3 |
| R-28 | Low | `event_bus.dart:585-602,425-459,868-895` | `listen` creates the node/interest before `.listen()`; a late subscription to an already removed node leaves a false listener interest, which a bridge may treat as a remote listener. | Code reading | Q3 |
| R-29 | Low | `event_bus.dart:1091-1098`; `event_bus_error.dart:16` | A pre-cancelled request records metrics but emits neither `allEventStream` nor `requestCanceled`; `EventBusErrorKind.dispose` is never emitted anywhere, so shutdown failures are invisible. | Code reading | Q3 |
| R-30 | Low | `event_subscription.dart:477-493,455-467,371-382` | A throwing user `onError`/`onDone` escapes into the zone; the drain loop stops and the rest of the buffer is not delivered until the next `offer`. | Code reading | Q3 |

**Core design preferences (not defects):** `arguments` have no documented remote channel; the bus
`requestQueueCapacity` is not on the `EventBus` interface; `EventDTOImpl.data` is mutable;
`EventBusException.toString()` loses the subclass type; most behavioural tests still run through
the test-only `legacy_compat.dart` facade, so the public API (buffer 1024, named parameters) is
less proven than the legacy path.

**Review verdict:** request changes. R-01 and R-16 are release blockers; R-02/R-03/R-17 are
serious. Transport is usable with a documented deadline requirement (R-05); MQTT is usable only
over `mqtt://`/`mqtts://` until R-04 is fixed. These findings do not invalidate the product idea;
they confirm that Q3 is the gating epic and that the 5–6 week estimate must absorb roughly 1.5
weeks of lifecycle and concurrency fixes.

---

## 5. Quality epics

### 5.0 Quick wins (first 72 hours)

These are small, reversible and measurable; together they take all five packages to 160/160 pub
points and remove the most visible signs of an unmaintained package.

| # | Action | Gain | Effort |
|---|---|---|---|
| 1 | Rewrite five pubspec descriptions to 60–180 chars, correcting the stale core text (it still advertises FSM, which moved to `_patterns`) | +30 pub points (core, NATS, MQTT) | 1 h |
| 2 | Rename `example/event_bus_arch_exmple.dart` → `event_bus_arch_example.dart`; add `event_bus_arch_patterns_example.dart` and `event_bus_arch_transport_example.dart` | +30 pub points (core, patterns, transport) | 2 h |
| 3 | Remove the library name and switch to URI `part of` directives; convert the NATS/MQTT constructors to super parameters | +30 pub points (analysis 50/50 on core, NATS, MQTT) | 2 h |
| 4 | Add `.pubignore` (`packages/`, `build_script.sh`, `pubspec_changer.dart`, `.agai/`) and verify the archive | Clean, smaller package | 1 h |
| 5 | Add a CI workflow for analyze + test + format (even before the full matrix) | First automated gate, README badge | 3 h |
| 6 | Apply for a verified publisher and fix `repository`/`topics`/`homepage` metadata | Trust + discoverability | 0.5 d (review wait) |
| 7 | Add README sections "When not to use" and "Delivery guarantees" (short, honest) | Fewer mismatched adopters, clearer promise | 3 h |

The register contains 22 product/infrastructure findings and 30 independent-review findings; every
one is assigned to an epic through the `Closes` field below. Each epic has a goal, the reason it
matters, scope, acceptance criteria and an estimate in person-days for one experienced Dart
developer, including tests and docs. These are proposals, not yet registered records;
formalisation through the product process is the next step after the human approves the priorities.

### Q1 — Release engineering and CI

- **Priority:** P0 · **Estimate:** 2–3 d · **Closes:** F-01, F-02, F-20, F-11
- **Goal:** every change is verified automatically and every release is reproducible.
- **Why:** without this, the other epics cannot be trusted; a solo maintainer cannot manually
  verify five packages, two brokers, web and three OS targets on every change.
- **Scope:**
  - GitHub Actions: `dart analyze --fatal-infos`, `dart format --set-exit-if-changed`, tests for
    all five packages on Linux (plus Windows/macOS for the core), lowest and latest supported Dart.
  - Web job: `dart compile js` and Chrome smoke tests.
  - Broker jobs: NATS and MQTT services (Docker) with the integration tests enabled.
  - Coverage: upload and a floor per package; fail below it.
  - `dart doc` build job; artifact published to GitHub Pages.
  - Release workflow: version consistency check across five pubspecs, changelog presence,
    `dart pub publish --dry-run`, tag → publish with provenance.
  - Badges in README; branch protection on `master`; Dependabot for dependencies and Actions.
- **Acceptance:** a red pipeline blocks merge; a release PR bumps all versions, verifies dry-runs
  and publishes; README shows green CI and coverage badges; broker tests run on every PR.
- **Notes:** format the tree once in a dedicated commit before enabling the gate, so the change is
  reviewable.

### Q2 — Publication excellence and packaging

- **Priority:** P0 · **Estimate:** 1.5–2.5 d · **Closes:** F-03…F-10, F-12
- **Goal:** 160/160 pub points on all five packages and a clean, trustworthy archive.
- **Why:** pub.dev score is the first credibility signal a developer sees; the gap is cheap to
  close and directly affects conversion.
- **Scope:**
  - Rewrite five descriptions to 60–180 chars with the value, not the category.
  - Add `example/<package>_example.dart` (runnable, copy-pasteable) to every package; rename the
    misspelled core file; add `example/pubspec.yaml` where an app is shown.
  - Document the remaining public API to 100%, or hide internals (preferred, see Q4).
  - Fix the 15 analyzer infos (remove library name, use URI part-of, super parameters).
  - Add `topics`, `homepage`, `issue_tracker`, `documentation`; correct the repository URL.
  - Apply for a verified publisher and transfer the five packages.
  - Add `.pubignore` excluding `packages/`, dev scripts, `.agai`, build artifacts; verify the
    archive size and contents.
  - Remove unused `intl`/`async`; unify the SDK floor; document it once.
  - Restore a complete changelog and create GitHub releases for 4.0.0/4.1.0.
- **Acceptance:** all five packages show 160/160; verified publisher; `dart pub publish --dry-run`
  archive contains only the package; `example/` appears on pub.dev; no doc warnings.

### Q3 — Correctness and delivery guarantees

- **Priority:** P0 · **Estimate:** 9–13 d (both blockers and the three high findings are now sized) ·
  **Closes:** F-13, F-18, F-22, R-01…R-30
- **Goal:** no known production defect, and every guarantee a consumer relies on is written down
  and tested.
- **Why:** users adopt a library for what it promises; unwritten promises become incidents.
- **Scope:**
  - Fix all P0/P1 findings from the independent review; each gets a failing regression test first.
    Start with R-16 (shutdown hang on paused listeners) and R-01 (`removeAddress` echo), then R-17
    (sync reentrancy) and R-02/R-03 (watchdog and pool-start death), then R-04 (MQTT WebSocket
    claim) and R-05 (request deadline across reconnects).
  - Decide and document the `DispatchStrategy.single` contract (strict serialisation vs
    opportunistic standby); align code and docs.
  - Close coverage gaps in `event_dto.dart`, `event_probe.dart`, `event_bus_logger.dart` and any
    new untested branch; target ≥90% core.
  - Write a "Delivery guarantees and limits" document: local fire semantics, listener vs handler,
    ordering, model-bus retention, buffer/overflow behaviour, isolate queue growth, request
    cancellation, broker at-most-once/at-least-once per adapter, no persistence.
  - Add stress/soak tests: 100k events, isolate restart under load, reconnect with in-flight
    requests, cancellation storms; run them in CI nightly if too slow for PRs.
  - Fuzz the address/pattern grammar (invalid tokens, wildcard placement, long addresses).
  - Commit the obfuscation check as an automated test: `dart compile js -O2`, run under Node,
    assert that a user-class `EventKey` resolves its codec, publishes exactly once and that
    `Type.toString()` is minified.
  - Codify the error taxonomy and ensure every failure path reports through `bus.errors` exactly
    once.
- **Acceptance:** zero open P0/P1; guarantees document reviewed against tests; nightly stress job
  green for 7 consecutive days.

### Q4 — API stabilisation and platform story

- **Priority:** P1 · **Estimate:** 5–8 d · **Closes:** F-14…F-17, F-19
- **Goal:** a consumer can depend on the API for a year, and the platform story is honest and
  visible.
- **Why:** 4.x is the right model, but the public surface, versioning and web badge do not yet
  signal stability; this is the difference between "interesting" and "safe to adopt".
- **Scope:**
  - Publish a stability policy: semver, deprecation window, what counts as breaking, support for
    the previous major.
  - Define 5.0 (or 4.2 + 5.0) scope: remove `have*`, remove the legacy facade, decide on typed
    `request<T, R>`, hide implementation types behind a facade library (`export ... show ...` or
    `@internal`), settle `EventBusImpl` visibility.
  - Bring the four sub-packages to 1.0.0 once their APIs pass the same stability review.
  - Resolve the web badge: conditional import/export or a separate `event_bus_arch_isolates`
    library so the entry library does not force `dart:isolate`; verify the pub.dev platform badge.
  - Document the isolate protocol compatibility rule (same Dart major, AOT/JIT, message shapes).
  - Decide the SDK floor and test it in CI.
- **Acceptance:** stability policy in README/CONTRIBUTING; 1.0 releases for sub-packages; pub.dev
  shows Web support; no public API added without dartdoc; 5.0 plan approved.

### Q5 — Documentation and onboarding

- **Priority:** P1 · **Estimate:** 4–6 d · **Closes:** F-05, F-12, F-13 (docs part), F-16 (docs)
- **Goal:** time-to-first-event under five minutes, and a user can succeed without reading source.
- **Why:** the narrative docs are strong but the entry path is not optimised for evaluation; most
  pub.dev visitors decide in the README and the example.
- **Scope:**
  - Restructure the README: one-sentence value, 20-line quick start, "when to use / when not to
    use", guarantees table, comparison table, benchmark summary, package map, support links.
  - Build and publish a docs site (dartdoc + guides) on GitHub Pages from CI.
  - Add a runnable example app per package; add one Flutter demo (worker pool) and one Dart
    backend demo (NATS or MQTT).
  - Add recipes: Flutter + isolates, NATS service, MQTT IoT, backpressure, observability,
    migration from `event_bus`/3.x.
  - Add FAQ/troubleshooting: "events seem lost", "no handler", "worker died", "broker offline",
    "web not supported".
  - Test the quick start from a fresh project in CI.
- **Acceptance:** a new user reaches a working event in <5 minutes; every public symbol documented;
  docs site deployed; examples compile in CI; FAQ covers the five most likely failures.

---

## 6. Adoption epics

Adoption is not one epic: roughly half is removing friction (Q2 + Q5), the other half is
distribution. The metrics below are the baseline to move.

| Metric | Baseline (2026-11-26) | 90-day target | 6-month target |
|---|---:|---:|---:|
| Core downloads / 30 d | 401 | 2,000 | 10,000 |
| Core likes | 4 | 25 | 75 |
| GitHub stars | 3 | 50 | 200 |
| External dependents / issues | 0 | 3 | 15 |
| pub points (all packages) | 130–150 | 160 | 160 |
| Time to first event (fresh project) | unmeasured | < 5 min | < 5 min |

### A1 — Positioning, launch and content

- **Priority:** P1 (start after Q2/Q5) · **Estimate:** 3–5 d initial + ongoing
- **Goal:** the target developer hears the right message in the right place and tries the package.
- **Why:** the product presently ranks first for "isolate event bus" but has no story around it;
  discovery is the bottleneck, not quality.
- **Scope:**
  - Lock the positioning: "the event bus that scales from one isolate to a broker without changing
    your events"; lead with the Flutter isolate/worker use case, then Dart services on NATS/MQTT.
  - Launch sequence: pub.dev refresh, GitHub release notes, one long-form article, one benchmark
    article, one "why not just Streams" article; Reddit r/dartlang and r/FlutterDev, Dart
    community Discord, X/LinkedIn, Habr for the Russian community.
  - Add GitHub description, topics, social preview; "Awesome Dart/Flutter" list submissions.
  - Publish the benchmark numbers and methodology in the README; keep them reproducible in CI.
  - Add a "used by" section and ask early users for permission to list them.
- **Acceptance:** positioning statement in README; three published pieces; two community launches;
  downloads measured weekly against baseline.

### A2 — Reference integrations and ecosystem

- **Priority:** P2 · **Estimate:** 3–5 d per reference app; start with one
- **Goal:** a developer sees their own stack in the examples.
- **Why:** "works with my framework" is a stronger adoption signal than another feature.
- **Scope:**
  - Flutter reference app: WorkerPool doing real work (image or JSON processing), progress and
    cancellation, metrics screen.
  - Dart backend reference: two services over NATS with request/reply, correlation ids,
    reconnect, graceful shutdown; Docker Compose.
  - MQTT reference: device simulator + dashboard, QoS and session options.
  - Interop recipes: `bloc`/`riverpod` bridging, `shelf`/`dart_frog` request handlers, Serverpod
    (if demand).
  - Evaluate one additional transport only with demand evidence (Redis Streams or WebSocket);
    do not add breadth before depth.
- **Acceptance:** at least one reference app runs from a clean checkout with one command; recipes
  compile in CI; external users can point to them.

### A3 — Community and governance

- **Priority:** P2 · **Estimate:** 1–2 d setup + ongoing · **Closes:** F-21
- **Goal:** an open-source project that a stranger can trust and contribute to.
- **Why:** the bus is infrastructure; trust signals matter more than feature count.
- **Scope:**
  - CONTRIBUTING (dev setup, test commands, PR gates), CODE_OF_CONDUCT, SECURITY.md (private
    disclosure), issue and PR templates, GitHub Discussions.
  - Roadmap and release notes; a "good first issue" label; a response expectation (e.g., issues
    within 72 h).
  - A public support channel (GitHub Discussions, no private DMs for support).
  - Keep the changelog and migration guides current; publish a deprecation calendar.
- **Acceptance:** all files present; first external PR merged with a documented process; issues
  answered within the stated window; roadmap updated monthly.

---

## 7. Path to production

The sequence matters: do not launch before the package is trustworthy, and do not polish forever
before talking to users.

| Phase | Window | Work | Exit gate |
|---|---|---|---|
| 0. Hygiene | Days 1–3 | Q2 publication fixes, `.pubignore`, descriptions, example, analyzer infos, verified publisher; Q1 CI skeleton | All packages 160/160; CI green on analysis/tests/format |
| 1. Hardening | Week 1–2 | Q1 complete (broker, coverage, docs jobs); Q3: R-16 and R-01 first, then R-17, R-02…R-10 with regression tests, guarantees document; nightly stress | Zero P0/P1; guarantees documented; broker tests in CI |
| 2. Stabilisation | Week 3–4 | Q4 stability policy, 5.0 plan, sub-package 1.0, web badge; Q5 README/docs site/example app; release 4.2 or 5.0 | All 160/160; docs site live; release published and announced |
| 3. Launch | Week 4–5 | A1 positioning, articles, community launches; A2 first reference app | Launch executed; metrics baseline recorded |
| 4. Growth | Ongoing | A2/A3, feedback loop, roadmap, external adopters | 90-day metric targets |

**Production gate (all must be true before calling the product production-ready):**

1. CI green on Linux/Windows/macOS, lowest and latest Dart, with NATS and MQTT integration jobs.
2. No open P0/P1 defect; every deliberate limitation named in the guarantees document.
3. 160/160 pub points on all five packages; verified publisher; clean archives; correct metadata.
4. 100% dartdoc on the intended public API; docs site; recognised example; quick start tested in
   CI.
5. Stability policy, deprecation calendar, complete changelog, GitHub releases, security policy.
6. At least one reference app and one external early adopter; issues answered within 72 h.
7. Release version chosen deliberately (recommendation below) and published with provenance.

---

## 8. Open questions for the human

These change the roadmap and cannot be answered from the repository.

1. **Primary segment.** Recommendation: lead with **Flutter apps that need isolate workers**,
   because it has the clearest pain, the largest audience and the best demo; keep Dart backend /
   NATS as the second story. Alternative: lead with backend/NATS, which has higher willingness to
   pay attention but a smaller Dart audience. Which one is the target for the next six months?
2. **Breaking-change policy.** Recommendation: freeze 4.x for six months, ship one 5.0 with the
   accumulated deprecations (`have*`, legacy facade, typed `request`, hidden internals) and then
   commit to semver + a two-minor deprecation window. Alternative: stabilise 4.x and never ship
   5.0 soon, accepting the API debt. Which is acceptable?
3. **Web investment.** Recommendation: spend 2–3 days on conditional imports/a facade so pub.dev
   shows Web support; it widens the funnel at low cost. Alternative: keep VM-only and document it.
4. **Maintainer capacity for brokers.** Recommendation: keep NATS and MQTT as the only supported
   adapters and make their guarantees first-class; add a new transport only with external demand
   and a maintainer. Is there capacity for a third adapter?
5. **Community language and channels.** Recommendation: English for docs and issues, Russian for
   the Habr launch; GitHub Discussions as the single support channel. Confirm or change.
6. **Naming and repository.** Recommendation: keep `event_bus_arch` as the package name, rename
   the GitHub repository to `event_bus_arch` (the old `dart_event_bus` URL already redirects) and
   align all metadata. Alternative: keep the redirect and avoid the churn.
7. **Release version for the production milestone.** Recommendation: ship a **4.2.0** as the
   "production" release after Q1–Q5 (no breaking changes), and put the breaking API cleanup into
   a later 5.0. Alternative: make the production release 5.0 immediately, which is cleaner but
   delays launch and asks users to adopt a brand-new major.
8. **MQTT WebSocket.** R-04 is a documented-but-broken feature. Recommendation: fix it (1–2 days,
   including a WS broker in the integration job) because WebSocket MQTT is how browser and
   restrictive-network users connect. Alternative: remove `ws://`/`wss://` from README/CHANGELOG
   and `doc/07-platforms.md` until someone needs it. Which is it?
9. **`DispatchStrategy.single` contract.** The code switches to standby on saturation; the docs
   imply "one active worker". Recommendation: make it strict (saturation → `BusyException`/`false`)
   because that is the reason to choose `single`; add a separate `failover` strategy if
   opportunistic standby is wanted. Alternative: keep the code and document the current behaviour.
10. **Shutdown semantics (R-16).** Recommendation: do not await the `done` delivery in
    `dispose`/`cancel` (fast, deterministic shutdown; document that a paused listener may not see
    `done`). Alternatives: track raw subscriptions and cancel/resume them on dispose (guarantees
    `done`, more machinery), or a bounded wait (compromise, still slow in the worst case).
11. **Probe contract (R-20).** Recommendation: make `localListeners`/`localAvailableHandlers`
    accurate for paused and rejecting subscriptions, and define `accepted` explicitly as "a
    candidate exists" rather than "`fire` would return true" — or align the docs to a pure routing
    snapshot. The current mixed promise is the defect.

---

## 9. Sources and commands

- Repository: `git@github.com:Avataromvatar/event_bus_arch`, master @ `9a0cb35`.
- Published versions: pub.dev API for the five packages, fetched 2026-11-26.
- pub.dev scores: `/api/packages/<name>/score` and the score pages.
- GitHub metadata: `api.github.com/repos/Avataromvatar/event_bus_arch`.
- Test evidence: [2026-11-26-test-evidence.md](2026-11-26-test-evidence.md).
- Defect history: `doc/artifacts/plans/2026-11-23-defect-remediation-plan.md`.
- Product docs: `README.md`, `doc/01`–`doc/07`, package READMEs, `benchmark/README.md`.
- Independent review: §4.3, produced by two read-only reviewer sessions with briefs
  `.agai/briefs/4f8971a6-0afb-44b1-b6b9-f336b0f127f0/`.

Commands used (Dart 3.14.1, Linux x64):

```bash
dart pub get
dart analyze
dart test                                  # core
cd packages/<pkg> && dart test             # per package
dart test -p chrome test/web_smoke_test.dart
dart compile js tool/web_compile_check.dart
dart test --coverage=/tmp/eba_coverage && dart pub global run coverage:format_coverage ...
dart doc --output=/tmp/eba_doc
dart format --output=none --set-exit-if-changed lib test packages
dart pub outdated
dart pub publish --dry-run
```
