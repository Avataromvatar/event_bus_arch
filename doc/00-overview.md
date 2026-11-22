# 00. Start here: the package at a glance

[Next: Architecture →](01-architecture.md)

`event_bus_arch` 4.0 is an event-driven core for Dart and Flutter. Everything talks through
events with an explicit **address** and a **typed key**: `fire` publishes, `request` asks one
handler for a result. Subscriptions own their buffers, handlers own their request queues, and the
same model runs in one isolate, across isolates, or across a broker.

Use these diagrams as the map; the numbered documents explain each part.

## Reading paths

| You are | Read in this order |
|---|---|
| New to the package | 00 → 02 → 11 → 12 → 03 → 13 |
| Building an app on one isolate | 00 → 02 → 11 → 12 |
| Adding isolates, pools or layers | 03 → 13 |
| Connecting a broker | 00 → 08 → 09 or 10 |
| Running on the web | 14 → 02 → 12 |
| Migrating from 3.x | [Migration guide](15-migration-3-to-4.md) → 07 |
| Looking up a type | 06 |

## 1. Public API map

The bus is an interface; `EventBusImpl` is the built-in implementation. An `(address, Type)` bucket
is represented by an `EventNode` that owns its subscriptions; an `EventSubscription` may be a
listener, a handler, or both. Errors and metrics are data, not stream errors.

```mermaid
classDiagram
    direction LR

    class EventAddress {
        +String value
        +List~String~ tokens
    }

    class EventKey~T~ {
        +EventAddress address
        +Type type
    }

    class EventPatternKey~T~ {
        +EventPattern pattern
        +Type type
        +matches(address) bool
    }

    class EventBus {
        <<interface>>
        +bool isModelBus
        +bool isObservable
        +fire(key, data, arguments, correlationId) bool
        +request(key, data, timeout, cancelToken, correlationId) Future
        +subscribe(selector, ...) EventSubscription
        +listen(selector) Stream
        +currentData(selector) T?
        +remove(key) bool
        +remove(patternKey) bool
        +errors Stream
        +metrics EventBusMetrics
    }

    class EventSubscription~T~ {
        +onEvent(event)
        +handler(dto, lastData)
        +int handlerConcurrency
        +pause()
        +resume()
        +cancel()
        +int inFlight
        +int buffered
        +int bufferedRequests
    }

    class EventNode~T~ {
        <<interface>>
        +T? currentData
        +deliver(dto) bool
    }

    class EventDTO~T~ {
        +EventKey~T~ key
        +String address
        +T data
        +Map arguments
        +String? correlationId
    }

    class EventBusError {
        +EventBusErrorKind kind
        +EventBusErrorSource source
        +String? address
        +String? correlationId
        +Object error
    }

    class EventBusMetrics {
        +snapshot() EventBusMetricsSnapshot
        +changes Stream
    }

    class EventBusErrorMonitor {
        +add(bus) bool
        +remove(bus) bool
        +snapshot() EventBusErrorSnapshot
    }

    EventKey --> EventAddress
    EventPatternKey --> EventAddress : matches
    EventBus <|.. EventBusImpl
    EventBusImpl *-- EventNode : owns nodes
    EventNode *-- EventSubscription : fans out
    EventBus ..> EventDTO : publishes
    EventSubscription ..> EventBusError : reports
    EventBus --> EventBusMetrics : snapshot / changes
    EventBusErrorMonitor o-- EventBus : observes
```

**What to notice:** `fire` and `request` both build an `EventDTO` with an `EventKey`; only
`request` reaches a `handler`. A subscription with `onEvent` is a listener, one with `handler` is a
responder, and both callbacks can live on the same subscription. The Dart type is not part of the
address; it is the delivery filter of the `(address, Type)` node.

## 2. Component map

The local bus is the same type in every segment. An isolate bridge and a transport are directional
ports: local listeners receive incoming events, `fire` goes out; `request` resolves a local handler
first and crosses the boundary only when the other side has one.

```mermaid
flowchart LR
    subgraph Main["Main isolate (or browser)"]
        EB["EventBus<br/>address/type nodes + subscriptions"]
        OBS["Observability<br/>metrics, errors, monitor"]
        ISO["EventBusIsolate<br/>main-side port"]
        POOL["WorkerPool"]
        LAYERS["Layers /<br/>LayersSupervisor"]
    end

    subgraph Worker["Worker isolate (VM only)"]
        WBus["EventBus (worker side)<br/>listeners and handlers"]
        WChild["next layer<br/>(optional)"]
        WBus --> WChild
    end

    subgraph Broker["Broker"]
        NATS[("NATS subjects")]
        MQTT[("MQTT 5 topics")]
    end

    EB -.->|fire / request / subscribe| EB
    EB -.-> OBS
    ISO <-->|address interest, DTO, request ids| WBus
    POOL --> ISO
    LAYERS --> ISO
    EB <-->|TransportEventBus key + codec + reply subject| NATS
    EB <-->|TransportEventBus key + codec + reply topic| MQTT
```

**What to notice:** isolates are VM-only; the transport seam works on the web, while the shipped
NATS/MQTT connections are VM-only (see 14). Pools and layers are built from the same
`EventBusIsolate`.

## 3. What is new in 4.0

| Area | 4.0 behaviour |
|---|---|
| Addressing | Explicit `EventAddress` string plus `EventKey<T>`/`EventPatternKey<T>`; the Dart type is the delivery filter, never a token in the address |
| Obfuscation | Type identity is captured through a compile-time token, not `Type.toString()`/`runtimeType`; keys survive `dart compile js -O2` |
| Wildcards | Fixed grammar: `.` separates tokens, `*` matches one token, `>` matches one or more trailing tokens; no per-call separator |
| Subscriptions | `subscribe` returns an `EventSubscription` with its own bounded buffer, pause/resume, resize and overflow policy; `onEvent` and `handler` can be combined |
| Handlers | A handler is a subscription capability, not a node-level registry; per-subscription FIFO queue, `handlerConcurrency`, `inFlight`, `BusyException` |
| Requests | Local handler first, timeout and `CancelToken`, queue removal, dispatched-then-cancelled responses discarded |
| Errors | `EventBus.errors` carries `EventBusError` data events with rate limiting and a bounded recent buffer; `EventBusErrorMonitor` aggregates buses; errors carry `address` |
| Isolates | Address interest registries in both directions, outbound-only bridge `fire`, immediate `NoHandlerException`, cancellation across the bridge, in-place worker restart |
| Pools and layers | `WorkerPool` with five strategies and request credits; `Layers.supervise` restarts the whole worker chain while the top layer survives |
| Transports | `EventCodecRegistry` resolves typed codecs by address or pattern; the subject is the address; `typeTags`/`wireTypes` are gone |
| Patterns | `FSM`, `Scope` and `Command` live in `event_bus_arch_patterns` and take keys, not paths |
| Observability | Opt-in per-address/subscription metrics, snapshots, a changes stream, correlation ids; zero hot-path work when disabled |
| Web | The core bus, subscriptions, observability and the transport seam compile and run; isolate APIs throw `UnsupportedError` and report it through `EventBusCapabilities` |
| Dependencies | rxdart is removed; users add it themselves if needed |

## 4. Versions

| Package | Version |
|---|---|
| `event_bus_arch` | 4.0.0 |
| `event_bus_arch_patterns` | 0.1.0 |
| `event_bus_arch_transport` | 0.2.0 |
| `event_bus_arch_mqtt` | 0.2.0 |
| `event_bus_arch_nats` | 1.1.0 |

[Next: Architecture →](01-architecture.md)
