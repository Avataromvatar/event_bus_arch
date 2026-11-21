# M6: documentation, migration, release

- Status: in progress
- Started: 2026-11-22
- Estimate: 13–20 PD (ROADMAP M6)
- Local work report: no task record exists, and `record_create.py` requires a
  parent Feature/User Story; per `agai-sdlc:task-sync`, this file is the allowed
  fallback for work without a linked task.
- YouGile: not configured.
- Decision records: ADR-0008 (library layout/Web/rxdart/migration), ADR-0005,
  ADR-0007 (behaviour to document).

## Scope

- E6-01 migration guide 3.x -> 4.0.
- E6-02 regex-based migration script for `setHandler`/`removeHandler`/imports.
- E6-03 rewrite docs 01–10 for 4.0 and add 11 (backpressure), 12 (errors and
  observability), 13 (pool and supervision), 14 (Web and platform).
- E6-04 examples and benchmarks updated.
- E6-05 CHANGELOG, versions, publish dry-run, release checklist.
- E6-06 final regression, API freeze, tag.
- **UML diagrams** (user request, as part of E6-03): Mermaid class, sequence,
  state and component diagrams that make the package easier to learn.

## Diagram plan

Mermaid inside Markdown (`classDiagram`, `sequenceDiagram`,
`stateDiagram-v2`, `flowchart`); no binary images. Diagrams use 4.0 type names.

| # | Diagram | Type | Document | What it explains |
|---|---|---|---|---|
| 1 | Public API map | class | 00-overview / 01 | EventBus, EventSubscription, EventNode, EventDTO, errors, metrics |
| 2 | Component map | flowchart | 00-overview / 01 | local bus, isolate bridge, transports, pool, layers |
| 3 | Local fire and request | sequence | 02 | delivery vs handler answer, request sync point |
| 4 | Listener subscription and buffer | state | 11 | buffered, paused, busy, canceled, overflow |
| 5 | Request lifecycle | state | 11 / 02 | queued, in flight, timeout, canceled, busy, completed |
| 6 | Isolate handshake and interest sync | sequence | 03 | waitInit, interest registry, cancel |
| 7 | Layers chain and whole-chain restart | sequence + state | 13 / 03 | failure propagation, bridge restart in place |
| 8 | WorkerPool strategies and credits | class + flowchart | 13 | broadcast/roundRobin/keyed/leastBusy/single |
| 9 | Transport request/reply and correlation | sequence | 08 | headers, reply subject, correlation id |
| 10 | Observability model | class | 12 | config, metrics, snapshot, exporter, monitor |
| 11 | Error flow and monitor | flowchart | 12 | report -> rate limit -> recent/streams -> monitor |
| 12 | Platform matrix | flowchart | 14 | VM vs web, core vs brokers, capability flag |

Conventions: one concept per diagram; node names match code; a caption states
what to notice; split public and internal views; keep each diagram under ~15
nodes; diagrams live next to the text they explain and are linked from
`doc/README.md`.

## Progress

- 2026-11-22: documentation first batch done:
  * `doc/00-overview.md` — new start page with the API class diagram, component flowchart,
    reading paths, 4.0 changes and versions.
  * `doc/01-architecture.md` — rewritten for 4.0 with fire/request sequence diagrams, handler
    resolution flowchart and the module map.
  * `doc/02-event-bus.md` — rewritten: subscriptions, dual callbacks, request lifecycle,
    currentData/removeTopic, recipes.
  * `doc/03-isolate-and-layers.md` — rewritten: directional bridge, interest handshake sequence,
    local-first requests, restart/watchdog, Layers/Supervisor.
  * `doc/11-backpressure.md`, `doc/12-observability.md`, `doc/13-pool-and-supervision.md`,
    `doc/14-web.md` — new, diagram-first.
  * `doc/15-migration-3-to-4.md` — E6-01 migration guide.
  * `doc/README.md` — 4.0 contents, diagram conventions, current test counts.
- Remaining: rewrite 04–10, add `tool/migrate_3_to_4.dart` (E6-02), update examples/benchmarks
  (E6-04), CHANGELOG/publish dry-run/release checklist (E6-05), final regression (E6-06).

## Agent work log

- 2026-11-22: task-sync invoked; M6 planned with the UML diagram set requested
  by the user. M5 is complete; M2–M5 work reports are in this directory.
- 2026-11-22: first documentation batch and the migration guide written; ROADMAP E6-01 marked
  done, E6-03 in progress. Agents/skills: `agai-sdlc:task-sync`, `agai-sdlc:records`; token
  attribution unavailable.
