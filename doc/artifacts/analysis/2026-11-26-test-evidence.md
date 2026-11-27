# Test and analysis evidence — 2026-11-26

Environment: Linux (WSL2), Dart SDK 3.14.1 stable (downloaded to /tmp/dart-sdk-install),
`dart pub get` resolved 65 dependencies.

## Status update — 2026-11-27 (v4.2.0 merged)

`master` advanced to v4.2.0 (`59641bd`); the analysis branch was merged with it and the checks
were re-run on the merged tree:

- Tests: core **292/292**, patterns **21/21**, transport **41/41**, NATS **34/34** and MQTT
  **27/27** with real brokers; Chrome smoke 6/6.
- `dart analyze`: 23 infos, 0 warnings, 0 errors.
- Coverage: **86.3%** (1860/2155); `event_dto.dart` 50.0%, `event_probe.dart` 57.9%,
  `event_bus_logger.dart` 57.1%.
- `dart format`: 22 of 107 files would change (was 53 of 108 at 4.1.0).
- `dart doc`: 5 warnings, 0 errors.
- pub.dev still serves 4.1.0; v4.2.0 is tagged but not published.
- The three independent reproductions now pass: `removeAddress` echo = **1 call** (was 5,892),
  paused-listener dispose **3/3 pass**, sync reentrancy **2/2 pass**. R-01, R-02, R-03, R-04, R-05,
  R-11, R-16 and R-17 are fixed in the repository.

The tables below record the 4.1.0 baseline; the numbers above supersede them for the merged
branch.

## Static analysis

`dart analyze` over the workspace: **19 info-level lints, 0 warnings, 0 errors**.

- 1 × `unnecessary_library_name` (`lib/event_bus_arch.dart:1`)
- 14 × `use_string_in_part_of_directives` (`lib/src/*.dart:1`)
- 2 × `use_super_parameters` (NATS and MQTT bases)
- 2 × `unrelated_type_equality_checks` (`test/event_address_key_test.dart:158-159`)

pub.dev reports 15 issues on the published 4.1.0 (library/part-of) and grants 40/50 for analysis.

## Tests

| Suite | Result | Skipped |
|---|---|---|
| core `dart test` | 280 passed (15 s) | 0 |
| `event_bus_arch_patterns` | 21 passed | 0 |
| `event_bus_arch_transport` | 36 passed | 0 |
| `event_bus_arch_nats` | 24 passed, 10 skipped without `NATS_URL` | 0 |
| `event_bus_arch_mqtt` | 19 passed, 7 skipped without `MQTT_URL` | 0 |
| NATS with a real broker (`nats:2.10-alpine`, port 4222) | **34 passed** | 0 |
| MQTT with a real broker (`eclipse-mosquitto:2`, port 1883) | **26 passed** | 0 |
| core, Chrome `dart test -p chrome test/web_smoke_test.dart` | 6 passed | 0 |
| core repeated | 280/280 at `-j 1` and 280/280 at `-j 8` | 0 |

## Coverage (VM, `dart test --coverage` + `coverage:format_coverage`)

- Core `lib/`: **1848/2125 lines = 87.0%**
  - Lowest: `event_dto.dart` 50.0%, `event_probe.dart` 55.6%, `event_bus_logger.dart` 57.1%,
    `observability.dart` 84.2%, `worker_pool.dart` 85.4%, `event_bus_isolate.dart` 86.8%
- `event_bus_arch_patterns/lib`: **104/119 = 87.4%**
- Transport measurement did not produce a usable lcov in this environment; not claimed.

## Packaging and publication

- `dart pub publish --dry-run` (core): **0 warnings**, archive 179 KB.
- The core archive includes `packages/` (all four workspace packages) and the dev scripts
  `build_script.sh` / `pubspec_changer.dart` — both should not ship; `doc/`, `test/`, `benchmark/`
  and `tool/` also inflate it. There is no `.pubignore`. The published 4.1.0 tarball on pub.dev
  has the same top-level layout.
- Root pubspec description is 219 characters (pub.dev wants 60–180) → 0/10 conventions.
- pub.dev scores (2026-11-26): core 130/160, patterns 150/160, transport 150/160,
  NATS 140/160, MQTT 140/160.
- Core: 4 likes, 401 downloads/30 days. Other packages: 0 likes, 45–138 downloads/30 days.
- `publisherId: null` — no verified publisher.
- pubspecs point to `github.com/Avataromvatar/dart_event_bus` (redirects to
  `Avataromvatar/event_bus_arch`), no `homepage`, `issue_tracker`, `topics`.
- All direct dependencies are current (`dart pub outdated`: none outdated).
- `intl ^0.20.2` and `async ^2.13.0` are declared in the root pubspec but not imported
  anywhere in `lib/` or `packages/` (only a commented import).

## Web

- `dart compile js tool/web_compile_check.dart` succeeds (265 KB JS).
- Chrome smoke tests pass; README's web claim is true at runtime.
- pub.dev still marks Web unsupported because `lib/event_bus_arch.dart` imports `dart:isolate`
  unconditionally; `EventBusCapabilities` works around it at runtime, not at package metadata.

## CI

- No `.github/` directory, no CI configuration, no badges; no broker integration job.

## Independent review verification

The two reviews produced two blockers, three high findings and a set of medium/low findings. The
coordinator verified the top findings before recording them in the product analysis:

- **R-16 (`dispose`/`cancel` hang with a paused listener)** — reproduced in three variants, each
  with a 2 s timeout that expired:
  - `bus.listen(key).listen(...).pause()` then `await bus.dispose()`;
  - `sub.stream.listen(...).pause()` then `await sub.cancel()`;
  - `monitor.errors.listen(...).pause()` then `await monitor.dispose()`.
  The root cause is awaiting `StreamController.close()`, whose future waits for paused listeners.
  Test: `/tmp/eba_quickstart/test/dispose_pause_test.dart`.
- **R-17 (sync reentrancy)** — reproduced with `DeliveryMode.sync`:
  - a sync listener calling `bus.remove(key)` while another type node follows →
    `ConcurrentModificationError: Concurrent modification during iteration: _Map len:1`;
  - a sync listener calling `bus.removeAddress(...)` in the same position →
    `StateError: Cannot add new events after calling close`.
  Test: `/tmp/eba_quickstart/test/sync_reentrancy_test.dart`.
- **R-01 (`removeAddress` echo across isolates)** — reproduced. A counting `EventBusIsolate`
  subclass called `removeAddress(EventAddress('orders'))` once after `waitInit`; over the next
  300 ms the main-side override was entered **5,892 times** (expected < 3). The loop is between
  `event_bus_isolate.dart:389-390` (handler calls the public `removeAddress`), `:695-707` and
  `:1043-1051` (both overrides forward the delete back). `remove(selector)` uses a local-only
  helper and is not affected. The experiment lives in `/tmp/eba_quickstart/test/iso_loop_test.dart`
  (outside the repository).
- **R-02 (watchdog)** — verified by code reading: ping every 1 s, 500 ms timeout, immediate
  `Isolate.current.kill()` on one miss; pong is served by the parent's port listener.
- **R-03 (pool start window)** — verified by code reading: `_handleDeath` returns on `!_started`;
  `_started` is set only after all `_spawn` futures complete.
- **R-04 (MQTT ws/wss)** — verified against the installed `mqtt5_client 5.4.1` source:
  `MqttServerWsConnection` requires a `ws(s)://` server string, and `MqttServerClient.connect`
  disables WebSocket when `secure` is true. The adapter passes a bare host and sets `secure` for
  `wss`.
- The remaining review findings were verified by code reading only; no failing test was written.

## Superseded verification notes

The first pass of the R-17 experiment (a sync listener cancelling only its own subscription)
passed; the crash requires a second node to remain in the dispatch iteration. The corrected
experiment is the one cited above.

## Claims that are not reproducible from the repository

- `CHANGELOG.md:9,39` and the remediation plan claim a `dart compile js -O2` obfuscation check
  ("publishes exactly once", `type=minified:bS`). No test or tool in the repository performs this
  check today: `tool/web_compile_check.dart` only compiles and prints. The result was recorded in
  the plan, but CI cannot reproduce it.
- Package READMEs say "Dart SDK 3.12 or newer" while the pubspecs declare `^3.6.0` (NATS,
  transport, patterns) and `^3.8.0` (MQTT); the core README says `>=3.6.0`.

## README quick start

A fresh project outside the repository with a path dependency on `event_bus_arch` ran the README
quick start verbatim:

```text
$ dart pub get     # 7 dependencies resolved (includes the unused intl/async)
$ dart run main.dart
listen: hi
subscribe: hi
subscribe: hello
listen: hello
processed: hello
```

The quick start works as documented, including `listen`, `subscribe`, `fire` and `request` with a
handler. Time from empty directory to first event: under two minutes.

The same quick start was run in a second fresh project that depends on the **published**
`event_bus_arch: ^4.1.0` from pub.dev (not a path dependency), with the identical output. The
published artifact is usable as documented.
