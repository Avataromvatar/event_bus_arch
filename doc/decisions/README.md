# Architecture decision records — 4.0.0

Decisions for the 4.0.0 work. The roadmap is [../../ROADMAP.md](../../ROADMAP.md).

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-listener-subscriptions-and-backpressure.md) | Listener subscriptions, buffers and backpressure | Accepted |
| [0002](0002-handler-subscriptions-and-dispatch.md) | Handler subscriptions and request dispatch | Accepted |
| [0003](0003-request-lifecycle.md) | Request timeout, cancellation and cleanup | Accepted |
| [0004](0004-error-stream.md) | Error envelope, error stream and monitor | Accepted |
| [0005](0005-isolate-interest-and-fire-semantics.md) | Isolate interest registry, `fire` and `request` | Accepted |
| [0006](0006-observability-and-metrics.md) | Observability and per-topic metrics | Accepted |
| [0007](0007-worker-pool-and-supervision.md) | WorkerPool and supervision | Accepted |
| [0008](0008-library-layout-web-rxdart-migration.md) | Library layout, Web, rxdart and migration | Accepted |

## Conventions

- ADRs are English, like the rest of the repository.
- Status is one of `Proposed`, `Accepted`, `Superseded`, `Deprecated`.
- A decision that changes after acceptance is superseded by a new ADR; the old file is kept.
- The roadmap task IDs (for example `E1-04`) link an ADR to its implementation work.
