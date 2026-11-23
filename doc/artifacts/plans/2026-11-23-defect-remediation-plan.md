# Defect remediation plan — type-aware routing and reliability

- Date: 2026-11-23
- Scope: core `event_bus_arch`, `event_bus_arch_transport`
- Source: third-party review (12 existing defects) and the type-filter review (5 new defects)
- Status: implemented (2026-11-23)

## Decisions

1. **Type-scoped isolate interest uses `EventSelector`, not closures.**
   `EventSelector`, `EventKey`, `EventPatternKey` already cross isolate boundaries in
   `_IsolateDeleteSelector`; sending the selector avoids closure/AOT uncertainty and gives
   `accepts(data)` plus pattern matching without extra protocol fields.
2. **Probe with data; `have*` is deprecated.** `probeFire(key, data)` and
   `probeRequest(key, data)` take the data that would be sent and return local/remote statistics
   without side effects. `haveListener`, `haveHandler` and `haveAvailableHandler` remain
   temporarily as exact-type, no-data queries but are marked `@Deprecated`; they are removed in
   5.0. A no-data query cannot test subtype compatibility in Dart.
   - `probeFire`: `localListeners`, `hasRawListener`, `modelStores`, `transportPublishes`,
     `remoteListenerInterest`.
   - `probeRequest`: `localHandlers`, `localAvailableHandlers`, `localListeners`,
     `hasRawListener`, `remoteHandlerInterest`.
3. **Requests try the local bus first and fall back on `NoHandlerException`.** Do not route on
   `haveHandler`; a local handler with an unrelated type must not block a broker/worker request,
   and a supertype local handler must still win.
4. **Do not adopt “one address = one schema” now.** It removes the documented `(address, Type)`
   capability, does not solve supertype patterns or remote interest, and can diverge between
   processes. Keep it as a possible 5.0 discussion.
5. **`fireConfirmed`/ack is deferred.** `fire` remains best-effort; an ack protocol is a separate
   guarantee feature.
6. **Default managed listener buffer becomes 1024.** `null` remains explicit unbounded.
7. **Transport `fire` delivers locally before publishing, then propagates a publish error.**
   Local listeners and `currentData` are not rolled back by a broker failure.
8. **Keyed transport nodes are no longer unconditionally `KeepAliveNode`.** Nodes without local
   subscriptions/handlers are removed and their broker subscription is cancelled; `remove` remains
   the explicit eviction.
9. **Queued requests cancelled with their handler subscription fail with
   `RequestCanceledException`.** They are not “no handler” and must not look retryable as busy.
10. **The per-`(kind, address)` error window store is bounded (LRU, 256 keys).** The per-second
    limit remains 10; burst visibility is via `suppressedErrors`/`EventBusErrorMonitor`.

---

## 1. Defect register

### Existing review

| ID | Problem | Fix | Main files | Priority |
|---|---|---|---|---|
| DEF-01 | Transport `fire` publishes before local delivery; offline broker throws and local listeners/`currentData` are lost | Deliver locally first, then publish; propagate the transport error after local delivery | `transport_key_event_node.dart` | P1 |
| DEF-02 | `leastBusy` uses strict `<`; ties always pick slot 0 | Add a rotating cursor for tie-breaking; keep least-in-flight as the primary key | `worker_pool.dart` | P1 |
| DEF-03 | Any `StateError` from a handler is caught and rethrown as `BusyException` | Convert to `BusyException` only when the worker is not ready/disposed; otherwise rethrow the handler error | `worker_pool.dart` | P0 |
| DEF-04 | `waitInit` has no timeout; `addOnExitListener` is registered after `await Isolate.spawn` | Spawn paused, register the exit listener, then resume; add configurable `initTimeout` (default 30 s); fail `waitInit` if the worker exits before ready | `event_bus_isolate.dart` | P1 |
| DEF-05 | `CancelToken.whenCancelled.then` callbacks are never removed; long-lived tokens leak | Add listener add/remove to `CancelToken`; isolate request registers and removes on completion/timeout/close | `event_subscription.dart`, `event_bus_isolate.dart` | P1 |
| DEF-06 | `TransportEventBus.request` accepts `CancelToken` but does not pass it to the broker request | Race the broker request with token cancellation; fail with `RequestCanceledException`; remove the listener; document that the underlying request continues until its own timeout | `transport_event_bus.dart` | P1 |
| DEF-07 | `_errorWindows` grows by `(kind, address)` without eviction | Move windows into a bounded LRU store (256); prune stale windows; keep counters exact | `event_bus.dart` | P1 |
| DEF-08 | Managed subscription buffer defaults to unbounded | Default `bufferCapacity` to 1024; `null` means explicit unbounded | `event_bus.dart`, `event_subscription.dart` | P2 |
| DEF-09 | `BufferOverflow.latest` and `dropOldest` both call `removeFirst()` | `latest` keeps only the newest event: clear the buffered backlog, count dropped, add the new event; `dropOldest` keeps a sliding window | `event_subscription.dart` | P0 |
| DEF-10 | Cancel/dispose fails queued requests with `NoHandlerException` | Fail queued requests with `RequestCanceledException(address)` | `event_subscription.dart` | P1 |
| DEF-11 | Transport nodes are always `KeepAliveNode`; dynamic addresses never disappear | Remove the unconditional pin; clean up nodes with no listeners/handlers after `fire`; dispose cancels the broker subscription | `transport_key_event_node.dart`, `event_bus.dart` | P1 |
| DEF-12 | `replyTo` is published without subject validation | Validate `replyTo` with the address mapper before publishing; report an error and do not publish invalid subjects | `transport_key_event_node.dart` | P0 |

### Type-filter review

| ID | Problem | Fix | Main files | Priority |
|---|---|---|---|---|
| TYPE-01 | `haveHandler`/`haveAvailableHandler` return true for a different type on the same address | Exact typed tier for `have*`; add `probeRequest(key, data)` for data-aware counts and capacity; deprecate `have*` | `event_bus.dart` | P0 |
| TYPE-02 | `haveListener` misses a supertype pattern listener | Keep `haveListener` exact; add `probeFire(key, data)` using `EventNode.accepts(data)`; deprecate `haveListener` | `event_bus.dart`, `event_node` | P0 |
| TYPE-03 | Isolate interest is keyed by address only; a worker listening to `Invoice` acknowledges `fire<Order>` | Carry `EventSelector` in `_IsolateInterest`; store selectors in `_RemoteInterest`; check `accepts(data)`; include model interest | `event_bus_isolate.dart`, `event_bus.dart` | P0 |
| TYPE-04 | A local handler of a foreign type makes `haveHandler` true; request stays local and fails instead of going to broker/worker | Try local request first; fall back only on `NoHandlerException`; apply to transport, isolate main/worker and `Command` | `transport_event_bus.dart`, `event_bus_isolate.dart`, `command.dart` | P0 |
| TYPE-05 | Inbound request routing uses address only; a foreign-type handler can be selected and then fail internally, producing a timeout | `handlerAddressFor(address, data)` filters candidates by `acceptsData(data)`; only a matching handler node answers | `event_bus.dart`, `transport_event_bus.dart` | P0 |

---

## 2. Detailed work packages

### WP-1 — Probes and deprecated `have*` (`TYPE-01`, `TYPE-02`, `TYPE-05`)

**Core changes**

- Add a concrete `bool accepts(Object? data) => data is T;` to `EventNode<T>`.
  `EventNodeImp` and `TransportKeyEventNode` inherit or implement it.
- Add `_resolveTypedTier(selector)`:
  - exact selector: candidates from `_eventsMap[address][selector.type]`;
  - pattern selector: candidates from `_patternMap[pattern][selector.type]`;
  - no fallback to another type.
- `haveHandler` and `haveAvailableHandler` use `_resolveTypedTier`; `haveListener` uses the exact
  typed node and, for a concrete key, matching pattern buckets with the same `key.type`.
- Add:
  ```dart
  FireProbe probeFire<T>(EventKey<T> key, T data);
  RequestProbe probeRequest<T>(EventKey<T> key, T data);
  ```
  - Both are pure snapshots: no node creation, no listener/handler invocation, no
    `allEventStream`, no metric counters.
  - `probeFire` counts managed listener subscriptions that accept `data`, plus
    `hasRawListener`, `modelStores`, `transportPublishes`, `remoteListenerInterest`.
  - `probeRequest` resolves the exact → most-specific-pattern tier, filters candidates by
    `acceptsData(data)`, and reports `localHandlers`, `localAvailableHandlers`, `localListeners`,
    `hasRawListener`, `remoteHandlerInterest`.
  - `fire` and `request` keep their current semantics; probes are pre-flight snapshots, not
    delivery guarantees.
- Deprecate `haveListener`, `haveHandler`, `haveAvailableHandler`:
  ```dart
  @Deprecated('Use probeFire/probeRequest; have* checks only exact registered types')
  ```
  - Do not add the annotation until the probes exist and internal call sites are migrated
    (`Command`, transport request, isolate request).
  - Keep the methods working with exact-type semantics through 4.x; remove them in 5.0.
- `handlerAddressFor(String address, Object? data)` filters candidates by
  `subscription.acceptsData(data)`; no accepting candidate returns `null`.

**Tests**

- `test/probe_test.dart`
  - Pattern `EventPatternKey<DomainEvent>('orders.*')` listener + `Order` data:
    `probeFire(orderKey, Order(...)).localListeners == 1`, `accepted == true`.
  - `Invoice` handler on `orders` does not count for `Order` data.
  - Model bus: `modelStores == true` even with no listener.
  - Raw `listen(...).listen(...)`: `hasRawListener == true`; managed count is separate.
  - Probe does not create a node, does not change `metrics.snapshot().fired`, does not write to
    `allEventStream`.
  - Two exact types on one address remain separate nodes (regression guard for `(address, Type)`).
- `test/probe_request_test.dart`
  - Exact `Order` handler: `probeRequest(orderKey, Order(...)).localHandlers == 1` and
    `localAvailableHandlers == 1`.
  - Only `Invoice` handler: `probeRequest(orderKey, Order(...)).localHandlers == 0`.
  - Busy handler: `localHandlers == 1`, `localAvailableHandlers == 0`, `isBusy == true`.
  - Pattern `DomainEvent` handler accepts `Order` and is reported when no exact handler exists.
  - Exact tier wins over pattern; pattern is not counted for availability when exact is busy.
- `test/type_queries_test.dart`
  - With `// ignore: deprecated_member_use`, `haveHandler<Invoice>(orders)` and
    `haveAvailableHandler<Invoice>(orders)` are false when only an `Order` handler exists.
  - `haveListener(orderKey)` remains exact-type false for a supertype pattern; `probeFire` is the
    accurate data-aware check.
- `packages/event_bus_arch_transport/test/type_routing_test.dart`
  - Inbound request with `Invoice` does not select an `Order` handler; no response/wrong answer.
  - Inbound request with a handler of the matching type answers once.
  - `probeFire` reports `transportPublishes` when a codec exists; no broker subscriber count is
    implied.

### WP-2 — Type-aware isolate interest (`TYPE-03`)

**Protocol**

```dart
class _IsolateInterest {
  const _IsolateInterest(
    this.selector,
    this.id, {
    required this.listener,
    required this.handler,
    required this.model,
    required this.present,
  });

  final EventSelector selector;
  final int id;
  final bool listener;
  final bool handler;
  final bool model;
  final bool present;
}
```

- Core interest counts become selector-keyed:
  `Map<EventSelector,int> _listenerCounts`, `_handlerCounts`, `Set<EventSelector> _modelTopics`.
- `_onListenerInterestChanged`, `_onHandlerInterestChanged`, `_onModelInterestChanged`,
  `_onTopicInterestRemoved` take `EventSelector`.
- `_subscriptionAdded/_subscriptionRemoved/_markModelTopic` take the selector; raw `listen`
  subscriptions also register a selector.
- `_RemoteInterest` stores selectors per kind and implements:
  ```dart
  bool hasListener(String address, Object? data);
  bool hasHandler(String address, Object? data);
  ```
  Exact/pattern match plus `selector.accepts(data)`; model interest is checked the same way.
- `_IsolateInterest` is sent with the selector; cancellation sends `present:false` for the same
  selector when its count reaches zero.
- `EventBusIsolate.fire` and `request` pass `data` into `remoteInterest.hasListener/hasHandler`.

**Tests**

- `test/isolate_type_interest_test.dart`
  - Worker listens `EventKey<Invoice>('orders')`; main `fire(EventKey<Order>('orders'), Order())`
    returns false; no callback; no timeout.
  - Worker listens `EventPatternKey<DomainEvent>('orders.*')`; main fires `Order`; returns true and
    the callback runs.
  - Worker handles `Invoice`; main `request<Order>` throws `NoHandlerException` immediately and
    does not send a request.
  - Worker model bus retains `Invoice` at an address; main fires `Order` and gets false.
  - Cancel the worker listener; the next `fire` returns false (interest removed).
  - A listener and a handler on the same address but different types are tracked independently.
- Extend `event_bus_isolate_interest_test.dart` to assert `_RemoteInterest` is selector-aware
  through the public fire/request behavior, not private fields.

### WP-3 — Request routing (`TYPE-04`)

- `TransportEventBus.request`:
  ```dart
  try {
    return await super.request<T>(key, data, ...);
  } on NoHandlerException {
    // codec/broker path
  }
  ```
  Do not catch `BusyException`; a busy exact local handler must not fall back.
- `EventBusIsolate.request` and `_EventBusForIsolate.request`: same local-first/catch-NoHandler
  pattern before `_link.request`.
- `Command._call`: try `request`; on `NoHandlerException` use `fire`; return `null`.
- Ensure cancellation (`CancelToken`) still short-circuits before the local attempt.

**Tests**

- `packages/event_bus_arch_transport/test/type_routing_test.dart`
  - Local `Order` handler on `orders`; `request<Invoice>(orders)` is published to the broker
    (no local `NoHandlerException` from the wrong-type handler).
  - Local `EventPatternKey<DomainEvent>` handler answers `request<Order>` locally; the broker is
    not used.
  - Local handler busy still throws `BusyException`, not a broker fallback.
- `test/isolate_type_interest_test.dart`
  - Main has a local supertype handler; `request<Order>` is served locally.
  - Main has a local unrelated-type handler; `request<Invoice>` goes to the worker (when a worker
    handler exists), not to a local failure.
- `packages/event_bus_arch_patterns/test/command_scope_test.dart`
  - `Command` with no handler fires; with a handler requests.

### WP-4 — Worker and isolate reliability (`DEF-02`, `DEF-03`, `DEF-04`, `DEF-05`)

**WorkerPool**

- Add `_leastBusyCursor`; start the scan after the last selected slot so equal `inFlight` values
  rotate.
- In `request`, catch `StateError` only when the worker is actually unavailable:
  `if (!slot.ready || bus.isDisposed) throw BusyException(...); else rethrow;`.
  Do not swallow handler `StateError`.

**EventBusIsolate**

- Spawn with `paused: true`, add the exit listener, then `resume`.
- Add `Duration? initTimeout = const Duration(seconds: 30)` to the constructor. A timer completes
  `waitInit` with `EventBusException('worker initialization timed out')`; `null` disables it.
- On exit before ready, complete `waitInit` with `EventBusException('worker exited before ready')`.
- `CancelToken`:
  ```dart
  void addListener(void Function() listener);
  void removeListener(void Function() listener);
  ```
  `_link.request` registers a listener, removes it on response/timeout/close; `whenCancelled`
  remains for callers.

**Tests**

- `test/worker_pool_reliability_test.dart`
  - `leastBusy` with 3 workers and six sequential requests returns/round-robins across workers.
  - Handler throwing `StateError` surfaces as `StateError`; a killed worker still surfaces as
    `BusyException`.
- `test/event_bus_isolate_reliability_test.dart`
  - Worker exits during `onInit`; `waitInit` fails promptly, not by caller timeout.
  - `initTimeout` fires for a hung `onInit`; `null` disables it.
  - A long-lived `CancelToken` used for many isolate requests does not retain listeners
    (assert `token.listenerCount` returns to zero; add a test-only/diagnostic getter).
  - Cancellation removes the pending request and does not deliver a late response.

### WP-5 — Transport reliability (`DEF-01`, `DEF-06`, `DEF-11`, `DEF-12`)

- `TransportKeyEventNode.deliver`: local delivery first, publish second; if publish throws, the
  transport exception still propagates but local state is updated.
- `TransportEventBus._requestKeyTransport`: accept `CancelToken`; race the broker request with a
  cancellation future; remove the listener; throw `RequestCanceledException`. Document that the
  underlying request continues until its timeout.
- Remove unconditional `keepAlive` from `TransportKeyEventNode`; after `fire`, detach a node that
  has no listeners/handlers and is not a model node. `remove(selector)` remains explicit.
- Validate `replyTo` with `addresses.validatePublishSubject(replyTo)` in `_answer`; report
  `TransportSubjectException` instead of publishing.

**Tests**

- `packages/event_bus_arch_transport/test/transport_reliability_test.dart`
  - Offline `fire` delivers locally, updates `currentData`, and throws
    `TransportServerUnavailableException`.
  - A large `CancelToken` request fails with `RequestCanceledException` before the broker timeout;
    a late response is ignored.
  - Cancelling the last listener unsubscribes the keyed node; a subsequent `listen` resubscribes.
  - A `fire`-created node with no subscriptions is removed after delivery.
  - A message with an invalid `replyTo` does not publish; an error is reported.
  - A valid `replyTo` still publishes one response.

### WP-6 — Subscription semantics (`DEF-08`, `DEF-09`, `DEF-10`)

- `subscribe` defaults `bufferCapacity` to 1024; `null` is explicit unbounded.
- `BufferOverflow.latest`: clear the buffered backlog, count dropped events, add the newest event;
  `dropOldest` remains a sliding window.
- `_failQueuedRequests` uses `RequestCanceledException(address)`.

**Tests**

- `test/event_subscription_overflow_test.dart`
  - Default `bufferCapacity` is 1024; passing `null` is unbounded.
  - `latest` with a slow listener keeps only the newest event; `dropOldest` with capacity 3 keeps
    the last three.
  - Cancel a handler subscription with a queued request; the request fails with
    `RequestCanceledException`, not `NoHandlerException`.
  - Dispose a node with a queued request; same terminal exception.
- Update existing `event_subscription_test.dart` / `handler_subscription_test.dart` expectations.

### WP-7 — Error window (`DEF-07`)

- Extract the window logic into a small bounded store:
  - max 256 `(kind, address)` keys;
  - LRU eviction;
  - prune timestamps older than one second on access/insert.
- `reportError` uses the store; `suppressedErrors` remains exact.
- Keep the 10/s limit; optionally expose `ObservabilityConfig.errorRateLimitPerSecond` in a later
  change.

**Tests**

- `test/error_window_store_test.dart` (internal store)
  - 1000 distinct keys never exceed 256 entries; the oldest key is evicted.
  - The per-key limit still suppresses after 10 errors/second.
  - An evicted key can be inserted again.
- `test/event_bus_error_test.dart`
  - Existing rate-limit and recent-buffer tests stay green.

---

## 3. Test matrix

| Defect | Regression test |
|---|---|
| DEF-01 | `transport_reliability_test.dart`: offline local delivery |
| DEF-02 | `worker_pool_reliability_test.dart`: leastBusy ties |
| DEF-03 | `worker_pool_reliability_test.dart`: StateError propagation |
| DEF-04 | `event_bus_isolate_reliability_test.dart`: exit-before-ready, initTimeout |
| DEF-05 | `event_bus_isolate_reliability_test.dart`: token listener cleanup |
| DEF-06 | `transport_reliability_test.dart`: request cancellation |
| DEF-07 | `error_window_store_test.dart`: LRU bound |
| DEF-08 | `event_subscription_overflow_test.dart`: default capacity |
| DEF-09 | `event_subscription_overflow_test.dart`: latest vs dropOldest |
| DEF-10 | `event_subscription_overflow_test.dart`: queued cancel exception |
| DEF-11 | `transport_reliability_test.dart`: node cleanup |
| DEF-12 | `transport_reliability_test.dart`: invalid replyTo |
| TYPE-01 | `probe_request_test.dart`: exact/wrong-type handler counts; `type_queries_test.dart`: deprecated `have*` exact semantics |
| TYPE-02 | `probe_test.dart`: supertype pattern and raw listener; `type_queries_test.dart`: deprecated `haveListener` exact semantics |
| TYPE-03 | `isolate_type_interest_test.dart`: Invoice/Order/domain pattern/model |
| TYPE-04 | `isolate_type_interest_test.dart`, `type_routing_test.dart`, `command_scope_test.dart` |
| TYPE-05 | `type_routing_test.dart`: inbound wrong-type handler |

The new tests should fail on the current code first (red), then pass after the fix. Where a test
cannot fail deterministically (isolate spawn race), use a controlled worker that exits/hangs in
`onInit` and a timeout assertion.

---

## 4. Execution order

1. **WP-1** probes (`EventNode.accepts`, `probeFire`/`probeRequest`, exact `have*` plus
   `@Deprecated`, `handlerAddressFor(address, data)`).
2. **WP-2** selector-based isolate interest and interest snapshot.
3. **WP-3** request routing in transport, isolates and `Command`.
4. **WP-4** worker/isolate reliability.
5. **WP-5** transport reliability.
6. **WP-6** subscription defaults and overflow semantics.
7. **WP-7** bounded error window.
8. Full suite, obfuscation check, docs/CHANGELOG updates.

WP-1 and WP-2 are the critical path for the new type defects; they must land before WP-3 to avoid
temporary false-positive routing.

---

## 5. Definition of done

- Every ID in the defect register has a regression test that fails on the old code and passes on
  the new code.
- `dart analyze` has no errors or warnings.
- Core, patterns, transport, NATS and MQTT suites are green; broker-backed tests remain skipped
  without `NATS_URL`/`MQTT_URL`.
- `dart compile js -O2` obfuscation check still resolves an `EventKey` codec and publishes once.
- Public docs reflect: deprecated exact `have*`, `probeFire`/`probeRequest`, default buffer 1024,
  `latest` semantics, `CancelToken` cancellation, transport local-first fire, keyed node cleanup,
  and request fallback behavior.
- `CHANGELOG.md` has a 4.1.0 entry describing the behavior changes.
- No commit is made until requested.

## 6. Out of scope

- “One address = one schema” (retained as a 5.0 discussion).
- `fireConfirmed`/ack protocol (separate guarantee feature).
- Broker-side request cancellation (the caller-side future is cancelled; the underlying request
  completes or times out).
- Durable transport semantics, queue groups or JetStream.
- Removing the test-only `legacy_compat.dart` facade.

## 7. Implementation status

All work packages are implemented. Verification:

- `dart analyze`: no errors or warnings in core, patterns, transport, NATS and MQTT.
- Tests: core 280, patterns 21, transport 36, NATS 24 (+10 skipped without `NATS_URL`),
  MQTT 19 (+7 skipped without `MQTT_URL`).
- `dart compile js -O2` obfuscation check: `type=minified:bS`, `accepted=true publishes=1`.
- Docs updated: probes and deprecated `have*`, buffer 1024/`latest`, `RequestCanceledException`
  for queued cancellation, `initTimeout`, bounded error windows, transport local-first fire,
  keyed node cleanup, `replyTo` validation and request cancellation.
- Deviations: the `KeepAliveNode` interface remains as a core extension point, but no built-in
  node implements it; transport cleanup is opt-in via the `shouldRemoveSendNode` hook, which keeps
  the `shouldCreateNodeOnSend` contract for custom buses.
