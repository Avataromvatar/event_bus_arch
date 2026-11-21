# M6: documentation, migration, release

- Status: planned
- Started: —
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

## Agent work log

- 2026-11-22: task-sync invoked; M6 planned with the UML diagram set requested
  by the user. M5 is complete; M2–M5 work reports are in this directory.
