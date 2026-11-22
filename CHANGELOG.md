## 4.0.0
-  breaking: **the address model is explicit** — an `EventAddress` is a dot-separated string chosen by the application (`orders.placed.v1`); `EventKey<T>` adds the static type and `EventPatternKey<T>` adds a wildcard pattern. The Dart type is no longer a token in the address: a node is identified by `(address, Type)`, the type never reaches the wire, and keys survive `dart compile js -O2` because identity is captured with `Type _typeOf<T>() => T;` rather than `Type.toString()`
-  breaking: the bus API takes selectors — `fire(key, data)`, `request(key, data)`, `listen(selector)`, `subscribe(selector, ...)`, `currentData(selector)`, `haveListener/haveHandler/haveAvailableHandler(selector)`, `remove(selector)`, `removeAddress(address)`; the old `paths:`/`separator:` bus methods are gone from the production API; a test-only facade keeps the old behaviour tests running while they are migrated
-  breaking: `subscribeEvents` is renamed to `subscribe` and the old raw `subscribe` method is removed; `currentData` accepts any `EventSelector` (exact or pattern); `remove` accepts any `EventSelector`, while `removeAddress` stays the whole-address operation; `Layers.createLayers`/`supervise` take `LayerSpec` instead of `(fnInitLayer, Object?, bool)` tuples
-  breaking: `EventDTO.key`/`EventDTO.address` replace the string `topic`; `EventBusError.address` is the E name (`topic` remains an alias), and request exceptions expose `address`
-  breaking: the legacy `Topic`/`TopicPattern`, `EventDTO.topic`, `EventSubscription.topic`, `serializers`/`deserializers`/`typeTags`, `TopicSubjectMapper`, `TransportEventNode` and `TopicRegistryIndex` are removed; the transport is keyed by `EventAddress`/`EventPattern` and `EventCodecRegistry` only
-  breaking: transport codecs are typed and keyed by address — `EventCodec`, `EventCodecRegistry`, `EventAddressMapper`, `TransportEventBus.keys`, `EventBusNats.keys`, `EventBusMqtt.keys`; the subject is the address, only the exact-key node publishes, and `typeTags`/`wireTypes` are not used by the keyed path
-  breaking: `FSM`, `Scope` and `Command` take `EventKey`/`EventPatternKey` (`selector:` for FSM, a key for Scope and Command) instead of `paths`/`eventPaths`
-  breaking: the address grammar is fixed — `.` separates tokens, `*` matches one, `>` matches one or more trailing tokens. The per-call `paths`/`separator` parameters and `EventBus.defaultTopicPathSeparator` are gone; `EventAddress.separator` is a constant, not a setting
-  breaking: `FSM`, `Scope` and `Command` moved to the new `event_bus_arch_patterns` package (0.1.0); the core package no longer exports them, so the bus stays a routing library
-  fix: an exception thrown by an FSM transition handler no longer leaves the machine stuck — the transition-in-progress flag and the ignored-events list are reset in a `finally`
-  breaking: the old handler API is removed — `EventBusHandlers`, `setHandler`, `removeHandler`, `addAllHandlerFromOtherBus` and `removeAllHandlerPresentInOtherBus` no longer exist; use `subscribe(handler: ...)` and cancel the returned `EventSubscription`
-  breaking: `fire` returns `true` only for a listener, a model store, a transport publish or a known remote listener/model interest; a handler-only subscription does not count (D14)
-  breaking: an isolate bridge is directional — local listeners receive incoming events, `fire` goes out only and never echoes back to its own side
-  add: `EventSubscription<T>` with a bounded listener buffer (`latest`/`dropOldest`/`dropNewest`/`reject`), `pause`/`resume`/`resize`, counters and an optional `.stream` view; `onEvent` and `handler` may share one subscription
-  add: per-subscription handler queues — `handlerConcurrency`, `requestQueueCapacity`, round-robin inside the exact or pattern tier, `BusyException`; exact tiers never fall back to a pattern tier when busy
-  add: request lifecycle — `timeout`, `CancelToken`, queued-request removal, dispatched-then-cancelled results discarded, `NoHandlerException`/`BusyException`/`RequestTimeoutException`/`RequestCanceledException`
-  add: `EventBus.errors` as `EventBusError` data events with per-`(kind, address)` rate limiting, bounded `recentErrors`, `suppressedErrors`; `EventBusErrorMonitor` with filters, a monitor-wide limit and `snapshot()`
-  add: isolate interest registries, immediate `NoHandlerException`, cancellation across the bridge, `waitInit` after interest exchange, `EventBusIsolate.restart()` in place, worker parent watchdog
-  add: `WorkerPool` with `broadcast`/`roundRobin`/`keyed`/`leastBusy`/`single`, request credits, `WorkerPoolMetrics`, restart supervision; `Layers.supervise` restarts the whole worker chain while the top layer and its subscriptions survive
-  add: opt-in observability — `ObservabilityConfig`, per-address/subscription metrics, latency histograms, `metrics.snapshot()`/`changes`, `EventBusMetricsExporter`, cardinality limiting, payload capture control; zero hot-path work when disabled
-  add: `EventDTO.correlationId`, `fire`/`request(correlationId:)`, propagation through handlers, isolates and transport headers (`X-EventBus-Correlation-Id`); request errors carry it
-  add: Web capability guard — `EventBusCapabilities.isWeb`/`isolateSupported`, `UnsupportedError` from `EventBusIsolate`/`WorkerPool`/`Layers` at construction; the local bus, observability and the transport seam work in the browser
-  change: `Scope` uses `bufferCapacity: 1`, `BufferOverflow.latest` and `disposeScope()` no longer takes `removeHandler:`; `FSM` uses `allEventStream`
-  change: `listen` is the raw node-stream view and `subscribe` is the managed subscription (no bounded buffer, overflow policy, counters or error routing); use `subscribe` when the consumer needs those controls
-  remove: rxdart dependency and re-export; add it to your own dependencies if needed
-  change: package versions — core `4.0.0`; `event_bus_arch_patterns` 0.1.0, `event_bus_arch_transport` 0.2.0, `event_bus_arch_mqtt` 0.2.0, `event_bus_arch_nats` 1.1.0; a 3.x adapter is not wire-compatible with 4.0
-  docs: new `00` overview, `11` backpressure, `12` errors/observability, `13` pool/supervision, `14` Web, `15` migration; rewritten `01`–`03`, `06`–`10`; Mermaid class/sequence/state/flow diagrams throughout
-  tests: 243 core tests, 20 pattern tests, 6 Chrome smoke tests; transport 26, NATS 24 (+10 skipped without a broker), MQTT 19 (+7 skipped without a broker); a `dart compile js -O2` check proves a user-class `EventKey` still resolves its codec and publishes once while `Type.toString()` is minified

## 3.1.0
-  add: `EventBus.removeTopic<T>` — explicit per-topic eviction that works on a model bus and on a transport node (the broker subscription is cancelled); active listeners receive `done`, a registered handler stays
-  add: `EventBusIsolate` forwards `removeTopic` to the other side of the bridge (fire-and-forget `_IsolateDelete`, applied in port order; the call requires a finished `waitInit`)
-  fix: `request` creates the topic node on a model or transport bus, like `fire`, so `currentData` keeps being recorded after a manual removal
-  fix: a late `doOnCancel` of an already removed node no longer deletes a node created later for the same topic (automatic removal now matches the node instance)
-  change: `EventBusMixin.removeNode` is now the private `_removeNode`; `removeTopic` is the public removal
-  note: custom implementations of the `EventBus` interface must add `removeTopic`; the factory and all built-in buses are unaffected
## 3.0.2
-  add: `isModelBus` flag for the `EventBusIsolate` constructor — applies to both the main-side and the worker bus
-  add: `bridgeIsModelBus` flag for `Layers.createLayers` — applies to every `EventBusIsolate` bridge between layers
-  fix: documentation for the isolate and layers model-bus flags
## 3.0.1
-  change name for inner packages
## 3.0.0
-  breaking: new address model — `Topic` lost `scheme`/`target`/`fragment`; `path: '/in'` became `paths: ['in']` with a configurable `separator`; `arguments` moved to `EventDTO`; the type token is `'$T'` normalised for broker subjects (`List<int>` → `List(int)`)
-  breaking: `EventBus.send` is split into `fire<T>` (one-way, returns `bool`, listeners only) and `request<T>` (one handler, returns its result, supports `timeout`, throws `NoHandlerException`, rejects wildcard paths)
-  breaking: `EventDTO.completer` is removed; handlers return the response and throw to fail a request; `fire` never invokes a handler
-  breaking: `lastData` renamed to `currentData` (`bus.currentData<T>()`, `EventNode.currentData`); `EventNode.send` became `deliver`
-  add: local wildcards `*` (one path token) and `>` (one or more trailing tokens) for `listen`/`subscribe`/`setHandler`, with exact and pattern node maps and exact → most-specific-pattern handler resolution
-  add: transport hooks (`KeepAliveNode`, `IncomingEventNode`, `createNode`/`shouldCreateNodeOnSend`); handlers moved from nodes into `EventBusHandlersMixin`; `removeHandler` keeps a node that still has listeners
-  change: `EventBusIsolate` uses `fire`/`request`; a request with no handler in the worker fails with `NoHandlerException` instead of returning `null`
-  add: pub workspace with `packages/event_bus_arch_transport` (shared broker layer), `packages/event_bus_arch_nats` (NATS) and `packages/event_bus_arch_mqtt` (MQTT 5): reconnection, arguments via headers/user properties, self-echo filtering and request/reply
-  remove: the deprecated `queueLenght`, `initalData`, `initialDataNeedExecute` and `shema` aliases (`changeStateByEvent` remains deprecated)
-  docs: README and `doc/01–07` migrated to the 3.0.0 API; new `doc/09` (NATS) and `doc/10` (MQTT 5)
-  tests: 131 core tests, plus 24 shared-transport, 52 NATS (live) and 39 MQTT (live)

## 2.3.0
-  fix: EventBus now exposes `handlers` and an idempotent `dispose()` in its interface
-  fix: a handler error completes the completer with that error (the sender used to wait forever)
-  fix: listeners receive the value before `await send(...)` returns
-  fix: EventBusIsolate correlates responses by request id (concurrent requests used to swap results)
-  fix: waitInit completes after `onInit` finished; init errors are reported through waitInit
-  fix: Layers.createLayers waits for the whole chain; Layer.close works in any layer
-  fix: Scope.maxLenForUndo defaults to 10; Command.undo sends the previous value
-  fix: the handler's lastData argument is the previous value of the topic
-  fix: EventDTO.toJson no longer encodes data; Topic.copy keeps path
-  fix: addAllHandlerFromOtherBus copies nodes; FSM.dispose; EventBusException is exported
-  behavior: send and any use of a disposed bus throw StateError
-  add: EventBus.handlers, EventBusIsolate.ping, Command.queueLength, Topic.scheme, initialData
-  deprecated: queueLenght, initalData, shema, initalDataNeedExecute, changeStateByEvent
-  add: 66 tests covering bus, nodes, isolates, layers, FSM, Scope/Command, Topic/EventDTO

## 2.2.0
-  fix bug when send from isolate not call completer
-  add dispose
-  add subscribe method
-  add FSM
-  add Layers
## 2.1.0
-  update dependencies
-  add test for EventBus and EventBusIsolate
-  change readme
-  fix problem in haveHandler and add getter in Node isHaveHandler  
## 2.0.6
-  update intl to 0.19.0 
## 2.0.5
-  fix bug with Topic where type YouClass?
-  add Scope and change Command 
## 2.0.4
-  add method: void addAllHandlerFromOtherBus(EventBus fromBus);
-  add method: void removeAllHandlerPresentInOtherBus(EventBus otherBus);
## 2.0.3
-  add EventBusMixin
-  change EvenBusImpl to EvenBusImpl with mixin
## 2.0.2
-  fix initalData for EventBusIsolate
## 2.0.1
-  add method haveListener and haveHandler
-  add initalData for EventBusIsolate
## 2.0.0
-  change api. reduced the code base. simplified work with the bus
-  add EventBusIsolate  
-  add Command pattern
-  remove EventBusMaster
## 1.3.2  
-  add groupListen method to EventBus   
-  add getAllTopic method to EventBus   
-  add clearAll method to EvenModelController
## 1.3.1+1  
-  change version  
## 1.3.1  
-  add new method getAllTopics
## 1.3.0+8  
-  change in pubignore  
## 1.3.0+7  
-  change readme  
## 1.3.0+6  
-  change package name  
## 1.3.0+5  
-  remove warning from eventDTO  
## 1.3.0+4  
-  change scripts and some code style fix  
## 1.3.0
-  !! change EventHandler (need customer code fix)!!
-  add method "call" to EventBus and EvenBusMaster
-  add contain method to EvenBusMaster
## 1.2.0
-  add logger, generator uuid, fix bugs
## 0.1.0

- Initial version.