# M5: Web compatibility and adapter 0.2.0

- Status: done
- Started: 2026-11-22
- Finished: 2026-11-22
- Estimate: 7–12 PD (ROADMAP M5)
- Local work report: no task record exists, and `record_create.py` requires a
  parent Feature/User Story; per `agai-sdlc:task-sync`, this file is the allowed
  fallback for work without a linked task.
- YouGile: not configured.
- Decision record: ADR-0008 (implementation notes 2026-11-22).

## Scope

- `EventBusCapabilities.isolateSupported` / `isWeb` compile-time flags.
- `EventBusIsolate`, `Layers.createLayers`, `Layers.supervise` and `WorkerPool`
  throw `UnsupportedError` on the web at construction time.
- Chrome smoke tests for the local bus and the capability guard; local check
  commands.
- Adapter packages 0.2.0 depending on core `^4.0.0`; compile and tests.
- NATS/MQTT over WebSocket: what is supported, what is documented.

## Result

- `lib/src/capabilities.dart`: `EventBusCapabilities.isWeb` from
  `bool.fromEnvironment('dart.library.js_interop')`,
  `isolateSupported = !isWeb`, `transportSupported = true`; a shared
  `_requireIsolates` guard.
- Guards added to `EventBusIsolate`, `WorkerPool`, `Layers.createLayers` and
  `Layers.supervise`; they throw `UnsupportedError` before any isolate API is
  called. The single `part` layout is unchanged.
- `test/web_smoke_test.dart` now has 6 browser tests: local bus, model
  retention, `subscribeEvents`, observability + correlation, the capability
  flag and the isolate guard.
- `tool/web_compile_check.dart`: `dart compile js` of the core succeeds
  (264,556 characters of JS). The transport package also compiles for the web;
  NATS and MQTT packages compile as libraries.
- Versions: core `4.0.0`; `event_bus_arch_transport` and `event_bus_arch_mqtt` `0.2.0`;
  `event_bus_arch_nats` `1.1.0` (a minor bump from its `1.0.0` line). All depend on
  `event_bus_arch: ^4.0.0`; the broker adapters also on `event_bus_arch_transport: ^0.2.0`.
- Web transports documented (ADR-0008, doc/08, README): the seam is
  platform-neutral; the shipped NATS (`dart_nats`, TCP-only) and MQTT
  (`MqttServerClient`, VM sockets) connections are VM-only. A web app injects a
  browser-WebSocket `TransportConnection`; `mqtt5_client` ships
  `MqttBrowserClient` for that.

## Verification

- `dart test` — 250 passed.
- `dart test -p chrome test/web_smoke_test.dart` — 6 passed.
- `dart compile js tool/web_compile_check.dart` — compiled to 264,556
  characters of JavaScript.
- `packages/event_bus_arch_transport`: 28 passed; compiles for the web.
- `packages/event_bus_arch_nats`: 42 passed, 10 skipped (no broker).
- `packages/event_bus_arch_mqtt`: 32 passed, 7 skipped (no broker).
- `dart analyze` — 17 infos: the pre-existing set plus the part-of info for
  `capabilities.dart`.
- `dart pub get` after the version bumps resolves the workspace.

## Agent work log

- 2026-11-22: task-sync invoked; local report created (same fallback as M2–M4).
  M5 implementation started with the capability guard.
- 2026-11-22: E5-01..E5-05 implemented, versions bumped and docs updated.
  Agents/skills: `agai-sdlc:task-sync`, `agai-sdlc:records`; token attribution
  unavailable (single session, metrics not split by task); active time
  approximately 2026-11-22 05:30 — 07:00 local.
