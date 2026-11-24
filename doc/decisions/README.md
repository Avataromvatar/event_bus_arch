# Architecture decision records

These records describe the architecture of the current `4.1.1` codebase. The numbering follows the
pre-4.1 ADR set so references such as `ADR-0008` (Web capability) and `ADR-0009` (address model)
remain valid. The records were rewritten on 2026-11-24 to reflect the current code rather than the
historical 4.0 planning baseline.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-listener-subscriptions-and-backpressure.md) | Listener subscriptions, buffers and backpressure | Accepted |
| [0002](0002-handler-subscriptions-and-dispatch.md) | Handler subscriptions, dispatch and type-aware routing | Accepted |
| [0003](0003-request-lifecycle.md) | Request timeout, cancellation and cleanup | Accepted |
| [0004](0004-error-stream.md) | Error envelope, error stream and monitor | Accepted |
| [0005](0005-isolate-interest-and-fire-semantics.md) | Isolate interest, fire and initialization semantics | Accepted |
| [0006](0006-observability-and-metrics.md) | Observability and metrics | Accepted |
| [0007](0007-worker-pool-and-supervision.md) | WorkerPool and supervision | Accepted |
| [0008](0008-library-layout-web-rxdart-migration.md) | Library layout, Web, dependencies and migration | Accepted |
| [0009](0009-event-key-and-address.md) | Explicit event address and local type (`EventKey`) | Accepted |
| [0010](0010-keyed-transport-seam.md) | Keyed transport seam and node lifecycle | Accepted |

## Conventions

- ADRs are written in English, like the rest of the repository.
- Status is one of `Proposed`, `Accepted`, `Superseded`, `Deprecated`.
- A decision that changes after acceptance is recorded as a revision or superseded by a new ADR;
  the old record is not silently rewritten.
- The records describe the public and internal contracts that are expensive to change later.
  User-facing how-to documentation remains in [../README.md](../README.md).
- The current follow-up work is tracked in
  [../artifacts/plans/2026-11-24-post-4.1-hardening-and-migration-plan.md](../artifacts/plans/2026-11-24-post-4.1-hardening-and-migration-plan.md).
