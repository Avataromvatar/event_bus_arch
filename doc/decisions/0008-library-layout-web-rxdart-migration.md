# ADR-0008: Library layout, Web, rxdart removal and migration

- Status: Accepted
- Date: 2026-11-21
- Roadmap: E1-14, E5-01..E5-05, E6-01..E6-06, E0-09

## Context

The package is a single library made of `part` files (`lib/event_bus_arch.dart` imports
`dart:isolate` and re-exports `rxdart`). Two questions were open for 4.0.0:

1. Does Web compatibility require splitting the library, and can `part` files use conditional
   imports?
2. How is rxdart removed without a compat bridge, and how do users migrate from the 3.x API?

`part` files share the enclosing library and cannot carry conditional imports or conditional
exports. A split would be required only if `dart:isolate` prevented web compilation or if isolate
code had to be absent from the web target.

## Web spike (E0-09)

Environment: Dart 3.14.0, Windows, Chrome installed.

1. `dart compile js` of an entry point that imports `package:event_bus_arch/event_bus_arch.dart`
   and uses `EventBus`, `EventBusIsolate` and `Layers` **succeeds** (290,774 characters of JS).
   The web SDK provides `dart:isolate` stubs; importing it does not break compilation.
2. `dart test -p chrome` with a local-bus test **passes**: `fire`, `subscribe`, `currentData` and
   `dispose` work on the web target.
3. `EventBusIsolate.waitInit` on web completes with an error (`Isolate.spawn` is unsupported)
   instead of hanging. The current error is an `EventBusException` wrapping the platform failure,
   not an `UnsupportedError`.

Conclusion: a library split is **not required for compilation** and is deferred until a concrete
need appears (for example, a Flutter Web build failure or tree-shaking problem). The 4.0.0 work is
a capability guard and a clear exception, not a `part`-to-library refactor.

## Decision

1. Keep the single public entry point and the `part` layout in 4.0.0.

2. Add a platform capability check (compile-time constant or a small platform helper):

   ```dart
   EventBusCapabilities.isolateSupported;   // false on web
   ```

   `EventBusIsolate`, `Layers.createLayers` and `WorkerPool` throw `UnsupportedError` on web at
   construction time, with a message naming the unsupported API. A capability flag allows callers
   to branch without catching.

3. If a future platform requirement makes the split necessary, the target layout is:

   ```
   lib/event_bus_arch.dart          core exports + conditional isolate exports
   lib/isolates.dart                isolate API (VM)
   lib/src/core/...                 multiple libraries, no part-of
   ```

   That is a separate ADR and a separate major/minor decision.

4. rxdart removal:

   - replace `Stream.doOnCancel` with native machinery (a controller `onCancel`/subscription
     lifecycle owned by `EventSubscription`);
   - delete `export 'package:rxdart/rxdart.dart'` and the dependency;
   - users who need rxdart import it directly in their own package.

5. Migration policy:

   - no 3.2 deprecation bridge for this major;
   - ship a migration guide (E6-01) and a migration script (E6-02) covering `setHandler`,
     `removeHandler`, `EventBusHandlers`, `fire` return semantics, isolate directionality,
     `EventSubscription` and the rxdart import;
   - the script is regex-based for the known public surface; an analyzer-based rewrite is a
     fallback if the regex approach proves unsafe.

6. Versions: core `4.0.0`; transport/NATS/MQTT `0.2.0` with dependency `^4.0.0`.

## Consequences

- Web support is "core bus + transports work; isolate APIs throw a clear error", documented in the
  platform matrix.
- No `part` refactor in 4.0.0 reduces risk and schedule; the ADR records the escape hatch.
- The rxdart removal is a public breaking change; the migration guide is mandatory, not optional.
- The migration script must be tested on the example app before release.

## Alternatives considered

- **Split the library now.** Rejected: the spike shows compilation succeeds; the split would add
  risk without a current benefit.
- **Conditional imports inside `part` files.** Not possible in Dart; would require the split.
- **Keep an opt-in rxdart re-export library.** Rejected: dependency surface for one method.
- **Ship a 3.x deprecation bridge first.** Rejected by decision; only a guide and script are
  planned.
