# Release checklist

The project has no CI. Every check below is run locally. **Publishing to pub.dev is manual and is
done by the project owner**, not by an agent or a hook.

## Versions

| Package | Version | Depends on |
|---|---|---|
| `event_bus_arch` | 4.0.0 | — |
| `event_bus_arch_transport` | 0.2.0 | `event_bus_arch: ^4.0.0` |
| `event_bus_arch_mqtt` | 0.2.0 | `event_bus_arch: ^4.0.0`, `event_bus_arch_transport: ^0.2.0` |
| `event_bus_arch_nats` | 1.1.0 | `event_bus_arch: ^4.0.0`, `event_bus_arch_transport: ^0.2.0` |

## 1. Working tree and versions

- [ ] `git status` is reviewed; the changes to release are the only ones in the tree.
- [ ] `pubspec.yaml` versions match the table above; the workspace resolves with `dart pub get`.
- [ ] `CHANGELOG.md` has a 4.0.0 entry with breaking changes, additions and removals.
- [ ] `doc/15-migration-3-to-4.md` and `tool/migrate_3_to_4.dart` exist and are linked.

## 2. Verification

```bash
dart pub get
dart analyze                       # no errors; the known info set only
dart test                          # core: 252
dart test -p chrome test/web_smoke_test.dart   # 6
dart compile js tool/web_compile_check.dart -o build/web_check.js
rm -rf build

(cd packages/event_bus_arch_transport && dart test)   # 28
(cd packages/event_bus_arch_nats && dart test)        # 42 + 10 skipped without a broker
(cd packages/event_bus_arch_mqtt && dart test)        # 32 + 7 skipped without a broker

dart run benchmark/subscription_benchmark.dart
dart run benchmark/observability_benchmark.dart
dart run benchmark/load_benchmark.dart --seconds=1 --rates=1000,10000 --warmup-ms=200
```

With brokers running, set `NATS_URL`/`MQTT_URL` and rerun the NATS/MQTT suites to exercise the
integration tests:

```powershell
$env:NATS_URL = 'nats://127.0.0.1:4222'
$env:MQTT_URL = 'mqtt://127.0.0.1:1883'
```

- [ ] No failing tests; skipped counts are understood.
- [ ] The analyzer has no errors or warnings (info output is the known part-directive/style set).
- [ ] The web compile check and Chrome smoke suite pass.
- [ ] The examples run on the VM:

```bash
dart run example/event_bus_subscription_example.dart
dart run example/event_bus_pool_example.dart
dart run example/event_bus_migration_target_example.dart
dart run example/event_bus_layers_example.dart
dart run example/event_bus_arch_exmple.dart
```

## 3. Package dry-runs (no publish)

Run these locally to catch metadata problems. Do **not** run `dart pub publish`; the owner does
that after reviewing the output.

```bash
dart pub publish --dry-run
(cd packages/event_bus_arch_transport && dart pub publish --dry-run)
(cd packages/event_bus_arch_mqtt && dart pub publish --dry-run)
(cd packages/event_bus_arch_nats && dart pub publish --dry-run)
```

- [ ] No errors in the dry-run output (warnings are reviewed).
- [ ] The package descriptions and repository fields are current.
- [ ] `LICENSE` and `CHANGELOG.md` are included where expected.

## 4. Publish (owner)

Order matters because the adapters depend on the core and the transport layer:

1. `event_bus_arch` 4.0.0
2. `event_bus_arch_transport` 0.2.0
3. `event_bus_arch_mqtt` 0.2.0
4. `event_bus_arch_nats` 1.1.0

## 5. Tag and close

- [ ] Commit the release state (only when the owner asks; auto-commit is disabled).
- [ ] Tag the repository with `v4.0.0`.
- [ ] Close the M6 tasks and write the session report.
- [ ] After publishing, open a 4.0.1/5.0.0 planning note: the legacy `listen`/`subscribe` facade is
  removed in 5.0.0 (ADR-0001); tracing spans are the next observability step.

## Rollback

- A bad release: publish a patch version with the fix; never delete a published version.
- A broken package dependency: publish the adapter patch after the core patch; the constraints
  `^4.0.0`/`^0.2.0` keep a consistent set.
