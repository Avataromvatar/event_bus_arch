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