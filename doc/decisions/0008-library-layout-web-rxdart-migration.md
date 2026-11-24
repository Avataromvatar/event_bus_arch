# ADR-0008: Library layout, Web, dependencies and migration

- Status: Accepted
- Date: 2026-11-24
- Current in: 4.1.0

## Context

The core package is used as an application-level event bus. Keeping patterns (FSM, Scope, Command)
and broker adapters in the same package makes the core depend on concerns an application may not
need, and forces every consumer to carry transports it does not use. At the same time, browser
builds must not import VM-only isolate APIs, and the package must not re-export a stream utility
library merely for one helper.

## Decision

1. The workspace is split into:
   - `event_bus_arch` (core): addresses/keys, nodes, subscriptions, request dispatch, isolates,
     worker pool, layers, errors and metrics;
   - `event_bus_arch_patterns`: `FSM`, `Scope`, `Command`;
   - `event_bus_arch_transport`: connection seam, keyed codecs, address mapping, transport bus/node;
   - `event_bus_arch_nats` and `event_bus_arch_mqtt`: broker adapters.
2. The core does not export pattern or transport types. A consumer adds only the packages it uses.
   Package versions are independent; the workspace packages currently target core `^4.1.0`.
3. `rxdart` is neither a dependency nor a re-export. Its one used helper is replaced by core stream
   machinery; consumers that need rxdart add it to their own dependencies.
4. The core supports the Web target; isolate-backed APIs are VM-only. `EventBusCapabilities`
   (`isWeb`, `isolateSupported`) is available at compile time and `EventBusIsolate`, `WorkerPool`
   and `Layers` throw `UnsupportedError` when constructed without isolate support. A compile-only
   Web check lives in `tool/web_compile_check.dart`.
5. A transport adapter is responsible for its platform: the shipped NATS adapter is TCP/VM-only;
   MQTT 5 can use a browser client through a custom `TransportConnection`. No browser adapter is
   shipped by default.
6. 3.x is not source- or wire-compatible with 4.x. There is no compatibility adapter. A migration
   guide and a review-first migration tool are part of the migration track; the tool does not
   invent application addresses, because an address is an application-owned routing identity
   (ADR-0009).
7. The test-only legacy facade is not part of the public API. It exists only while the behaviour
   tests are migrated to the keyed API and is removed when that migration completes.

## Consequences

- A minimal application depends only on the core package; patterns and transports are opt-in.
- Web builds can compile the core, but isolate-backed features fail explicitly rather than at an
  obscure import or runtime point.
- Removing rxdart reduces the public surface and dependency graph, but consumers using rxdart must
  add it themselves.
- The migration from 3.x requires a deliberate address choice and a test update; it cannot be a
  purely mechanical string rewrite.
- Version constraints must be kept in sync across the workspace packages when the core minor
  version changes.

## Alternatives considered

- **One package with all patterns and transports.** Rejected: heavy dependency graph and unclear
  core scope.
- **Keep rxdart for compatibility.** Rejected: a public re-export for one helper.
- **A 3.x adapter.** Rejected: the address model and handler lifecycle changed; an adapter would
  preserve two incompatible contracts.
- **Automatic type-prefixed path migration.** Rejected: it would carry `Type.toString()` into the
  new address and break the obfuscation-safe model.
