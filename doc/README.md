# event_bus_arch documentation

User documentation for the core package. Start with the [main README](../README.md) for install
and a quick example.

## Reading paths

| You are | Read in this order |
|---|---|
| New to the package | 01 → 02 → 03 |
| Adding isolates or workers | 01 → 02 → 04 |
| Adding errors and metrics | 02 → 05 |
| Looking up a type | 06 |
| Running in a browser | 07 |

## Contents

| Document | Content |
|---|---|
| [01-concepts.md](01-concepts.md) | Address, keys, DTO, nodes, subscriptions; the object model |
| [02-event-bus.md](02-event-bus.md) | `fire`, `request`, `listen`, `subscribe`, wildcards, model bus |
| [03-subscriptions.md](03-subscriptions.md) | Buffers, overflow policies, handler queues, timeout and cancellation |
| [04-isolates-and-workers.md](04-isolates-and-workers.md) | `EventBusIsolate`, `Layers`, `WorkerPool`, supervision |
| [05-observability.md](05-observability.md) | `EventBusError`, error monitor, metrics, correlation ids |
| [06-api-reference.md](06-api-reference.md) | Public types and signatures |
| [07-platforms.md](07-platforms.md) | VM and Web support |
| [08-migration-3-to-4.md](08-migration-3-to-4.md) | Migrating from 3.x |

## Developer documentation

- [Architecture decision records](decisions/README.md) — the accepted 4.1 architecture decisions
  (address model, subscriptions, dispatch, isolates, transports, observability and platform scope).

## Separate packages

The core does not document patterns or broker adapters in depth; each has its own package README:

| Package | Documentation |
|---|---|
| `event_bus_arch_patterns` — `FSM`, `Scope`, `Command` | [README](../packages/event_bus_arch_patterns/README.md) |
| `event_bus_arch_transport` — transport seam, codecs, address mapping | [README](../packages/event_bus_arch_transport/README.md) |
| `event_bus_arch_nats` — NATS adapter | [README](../packages/event_bus_arch_nats/README.md) |
| `event_bus_arch_mqtt` — MQTT 5 adapter | [README](../packages/event_bus_arch_mqtt/README.md) |

## Diagrams

The documents use Mermaid inside Markdown, so diagrams render on GitHub and in a Mermaid-enabled
Markdown preview. The diagrams are UML-style:

- `classDiagram` — public types and their relationships;
- `sequenceDiagram` — `fire`, `request`, isolate and transport flows;
- `stateDiagram-v2` — subscription, request and worker lifecycles;
- `flowchart` — component, handler-resolution and platform maps.
