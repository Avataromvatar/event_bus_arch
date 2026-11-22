# Проверка дефектов сторонней проверки (event_bus_arch)

Дата: 2026-11-22. Репозиторий: `e:/workspace/dart/event_bus_arch`, ветка `version4`.
Метод: чтение кода по цитируемым местам + три подтверждающих теста (написаны, прогнаны, удалены после прогона).

## Сводка

| № | Дефект | Вердикт | Доказательство |
|---|---|---|---|
| 1 | Двойная публикация `fire` при pattern-узле с сериализатором | **Подтверждён** | Тест: 2 публикации в `FakeTransportConnection` на один `fire` |
| 2 | Offline `fire` ломает локальную доставку | **Подтверждён фактически**; поведение задокументировано как «publish before local» | Тест: исключение до локальной доставки, `currentData == null` |
| 3 | FSM залипает после исключения в handler | **Подтверждён** (+ лишний `EventBus` — подтверждён, минорный) | Тест: после броска handler'а переход b→c не выполняется |
| 4 | `leastBusy` вырождается в single-worker | **Подтверждён механически**; свойство самого алгоритма, не бага | Тест: 5 последовательных запросов — все в слот 0 |
| 5 | `StateError` маскируется под `BusyException` | **Подтверждён** | Тест: handler бросает `StateError`, наружу приходит `BusyException` |
| 6 | Гонка смерти воркера на старте | **Подтверждён по причине**, эффект уточнён | Анализ кода |
| 7 | `waitInit` без таймаута; exit-listener после spawn | **Подтверждён** | Анализ кода |
| 8 | `CancelToken.whenCancelled.then` не отписывается | **Подтверждён** | Анализ кода |
| 9 | Ошибки теряются под burst; `_errorWindows` не чистит ключи | **Частично**: rate-limit — документированное решение с счётчиком; утечка ключей — реальный дефект | Анализ кода + ADR-0004 |
| 10 | `BufferOverflow.latest == dropOldest` | **Подтверждён** (избыточность API) | Анализ кода |
| 11 | Мутабельная конфигурация после регистрации | **Подтверждён фактически**; почти всё задокументировано как контракт | Анализ кода + doc/06-api-reference.md |
| 12 | `NoHandlerException` при отмене/диспоузе подписки | **Подтверждён фактически**; задокументирован и закреплён тестом | `doc/06-api-reference.md`, `test/handler_subscription_test.dart` |

## Подробно

### 1. Двойная публикация fire при pattern-узле с сериализатором — подтверждён

`EventBusImpl.fire` → `_dispatchToListeners` ([lib/src/event_bus.dart:648](lib/src/event_bus.dart#L648)) доставляет событие и точному узлу, и всем подходящим pattern-узлам. `TransportEventNode.deliver` ([transport_event_node.dart:124](packages/event_bus_arch_transport/lib/src/transport_event_node.dart#L124)) при наличии `serializer` публикует событие в брокер **на каждый узел**. Если сериализатор зарегистрирован на тип (`'int'`; `TopicRegistryIndex.resolve` сначала ищет exact, потом `_byType`, [topic_registry_index.dart:28](packages/event_bus_arch_transport/lib/src/topic_registry_index.dart#L28)), то pattern-узел, созданный подпиской на `int.sensor.*`, тоже получает непустой сериализатор.

Подтверждающий тест: `serializers: {'int': _encode}`, `deserializers: {'int.sensor.*': _decode}`, `subscribe<int>(paths: ['sensor','*'])`, затем `fire<int>(1, paths: ['sensor','temp'])` → `connection.publishes.length == 2`, обе на `int.sensor.temp`. Все тесты прошли (`dart test`), файл теста удалён.

Важно: wildcard-ключ сериализатора запрещён (`validatePublishKey`), но type-fallback `'int'` легален и документирован — сценарий достижим в обычной конфигурации «один сериализатор на тип + pattern-подписки». Механизма дедупликации публикации нет (origin-фильтр в NATS/MQTT отсекает только self-echo входящих).

### 2. Offline fire ломает локальную доставку — подтверждён фактически

`deliver` ([transport_event_node.dart:124-132](packages/event_bus_arch_transport/lib/src/transport_event_node.dart#L124-L132)) сначала вызывает `_publish`, а `_publish` при `!connection.isConnected` бросает `TransportServerUnavailableException` ([transport_event_node.dart:139-142](packages/event_bus_arch_transport/lib/src/transport_event_node.dart#L139-L142)) — до `_local.deliver`. Подтверждающий тест: при `TransportStatus.disconnected` `fire` бросил, локальный listener не вызван, `currentData` остался `null`.

Оговорка: порядок «publish before local» прямо задокументирован в doc-комментарии узла (строки 29-32) и, видимо, является осознанным fail-fast. Дефектом это делает последствие (локальная шина зависит от брокера), а не скрытое расхождение с контрактом.

### 3. FSM залипает после исключения в handler — подтверждён

`initFSM` ([lib/src/fsm.dart:53-73](lib/src/fsm.dart#L53-L73)): `changeStateStart = true`, затем `changeState(...)`, затем `await node.call(...)`. Исключение из handler'а выходит из async-колбэка подписки, не сбрасывая `changeStateStart`; `_ignoredDTO.clear()` тоже пропускается. Дальнейшие события складываются в `_ignoredDTO`, переходов больше нет. Подтверждающий тест: переход a→b с бросающим handler'ом, затем событие для b→c — состояние осталось b, второй handler не вызван.

Дополнительно подтверждено: `_FSM` инициализирует `EventBus(isModelBus: false)` в поле ([fsm.dart:9](lib/src/fsm.dart#L9)), который сразу заменяется в `initFSM` — лишний объект со своими StreamController'ами; функционального вреда нет, но аллокация бессмысленна.

### 4. leastBusy вырождается в single-worker — подтверждён механически

`_leastBusySlot` ([worker_pool.dart:415-424](lib/src/worker_pool.dart#L415-L424)) при равном `inFlight` оставляет первый найденный слот (строгое `<`), рандомизации нет. Последовательные запросы всегда видят `inFlight == 0` у всех слотов → слот 0. Тест: 5 последовательных `request` → `metrics.perWorker[0].requests == 5`, у слота 1 — 0. Под параллельной нагрузкой распределение работает (существующий тест `worker_pool_test.dart:170`). Это ожидаемая семантика «наименее загруженный», а не ошибка; практический эффект — детерминированный хотспот при низкой конкуренции.

### 5. StateError маскируется под BusyException — подтверждён

`WorkerPool.request` ловит `on StateError` вокруг всего `await bus.request(...)` ([worker_pool.dart:352-364](lib/src/worker_pool.dart#L352-L364)), хотя комментарий говорит лишь о смерти воркера между проверкой готовности и отправкой. `EventBusIsolate` передаёт ошибку handler'а как есть (`_IsolateErrorResponse`, [event_bus_isolate.dart:373-375](lib/src/event_bus_isolate.dart#L373-L375)), поэтому `StateError` из пользовательского handler'а приходит в этот `catch` и превращается в `BusyException` (теряются тип и стек). Тест подтвердил: handler бросает `StateError('handler boom')`, наружу — `BusyException`.

### 6. Гонка смерти воркера на старте — подтверждён по причине, эффект уточнён

`_handleDeath` ([worker_pool.dart:534-548](lib/src/worker_pool.dart#L534-L548)) при `!_started || slot.restarting` молча выходит. `_spawn` ставит `slot.ready = true` ([worker_pool.dart:521](lib/src/worker_pool.dart#L521)) до того, как `_start` выставит `_started = true` после `Future.wait` ([worker_pool.dart:482-487](lib/src/worker_pool.dart#L482-L487)). Смерть воркера в этом окне (после успешного `waitInit`, но до `_started = true`) не обрабатывается: слот остаётся `ready = true` с мёртвым `EventBusIsolate`, рестарт не планируется.

Уточнение эффекта: `_handleDeath` выходит **до** `slot.ready = false`/`_updateState()`, поэтому пул остаётся в состоянии `ready` с мёртвым слотом (а не «навсегда restarting»). Запросы на этот слот будут падать `BusyException` (из-за дефекта 5), `fire` — возвращать `false` и считать dropped ([worker_pool.dart:470-474](lib/src/worker_pool.dart#L470-L474)). Это противоречит ADR-0007 («detect death via isolate exit/port close … restart»), но окно узкое.

### 7. waitInit без таймаута; exit-listener после await spawn — подтверждён

`EventBusIsolate.waitInit` — обычный future ([event_bus_isolate.dart:452](lib/src/event_bus_isolate.dart#L452)); сам по себе он не дефектен, таймаут может навесить вызывающий (`Layers.createLayers(timeout:)` так и делает, [layers.dart:100-108](lib/src/layers.dart#L100-L108)). Дефект в том, что `WorkerPool._spawn` ждёт `bus.waitInit` без таймаута ([worker_pool.dart:517](lib/src/worker_pool.dart#L517)): зависший `onInit` навсегда оставляет пул в `starting`, без диагностики и рестарта.

`isolate.addOnExitListener` регистрируется **после** `await Isolate.spawn` ([event_bus_isolate.dart:707-718](lib/src/event_bus_isolate.dart#L707-L718)). Если воркер умирает между завершением spawn и регистрацией слушателя (например, падение до отправки SendPort/готовности), уведомление о выходе может быть потеряно, и `waitInit` не завершится никогда. Окно узкое, но реальное.

### 8. CancelToken.whenCancelled.then не отписывается — подтверждён

`CancelToken` — это `Completer<void>` с геттером `whenCancelled` ([event_subscription.dart:491-510](lib/src/event_subscription.dart#L491-L510)); API отписки нет. Оба места подписываются через `.then`: [event_bus_isolate.dart:242](lib/src/event_bus_isolate.dart#L242) и [event_subscription.dart:581](lib/src/event_subscription.dart#L581). Замыкание держит completer/DTO/entry до момента отмены токена. Если токен долгоживущий и не отменяется, замыкания накапливаются на каждый завершённый запрос. Если токен отменят — освободятся. Утечка ограничена временем жизни токена, но не ограничена числом запросов.

### 9. Ошибки под burst и `_errorWindows` — частично

Rate-limit 10 событий/сек на `(kind, topic)` — осознанное решение (ADR-0004 п.5, doc/12-observability.md): подавленные считаются в `suppressedErrors`. «Инцидент не виден в мониторинге» — верно лишь для потока `errors` и `recentErrors` (bounded 100); счётчик подавления есть. Это не дефект реализации, а ограничение дизайна.

Реальный дефект: `_errorWindows` ([event_bus.dart:310](lib/src/event_bus.dart#L310), заполнение [event_bus.dart:336-346](lib/src/event_bus.dart#L336-L346)) никогда не удаляет ключи — только `clear()` при dispose ([event_bus.dart:813](lib/src/event_bus.dart#L813)). При ошибках на динамических топиках карта растёт неограниченно, что прямо противоречит ADR-0004: «Error tests must prove: … no unbounded growth». Чистка по таймауту/периодическая нужна.

### 10. BufferOverflow.latest == dropOldest — подтверждён

В `_bufferEvent` ([event_subscription.dart:383-398](lib/src/event_subscription.dart#L383-L398)) обе ветки — `case latest:` и `case dropOldest:` — выполняют `_buffer.removeFirst()`, после switch — `addLast` (строка 400). `resize` ([event_subscription.dart:332-338](lib/src/event_subscription.dart#L332-L338)) тоже трактует их одинаково (`dropNewest` vs всё остальное). Поведенчески значения идентичны; API из четырёх политик фактически предлагает три. Не ошибка поведения, но вводящая в заблуждение поверхность; Scope использует `latest(1)`, так что удаление значения потребует миграционной оговорки.

### 11. Мутабельная конфигурация после регистрации — подтверждён фактически, статус разный

- `defaultTopicPathSeparator` — публичное изменяемое поле ([event_bus.dart:281](lib/src/event_bus.dart#L281)), используется как fallback во всех адресных методах. Смена после регистрации действительно делает старые узлы недостижимыми для вызовов без явного separator. **Но** это прямо задокументированное поведение и пример в doc/06-api-reference.md:391-402.
- `TopicImpl.paths` — `final`-поле со ссылкой на переданный список, без копирования ([topic.dart:80-87](lib/src/topic.dart#L80-L87)). Мутация меняет `topic`/`hashCode`/`==` после вставки в Map. **Задокументировано** как запрет: doc/06-api-reference.md:105 («Do not mutate the list you handed in»). Это контракт, а не скрытый баг, но защита (`List.unmodifiable`) отсутствует.
- `EventDTOImpl.topic/data/arguments` — публичные изменяемые поля ([event_dto.dart:55-65](lib/src/event_dto.dart#L55-L65)), также отражены в API-документе. Риск для DTO в полёте есть, но это осознанная форма API.

### 12. NoHandlerException при отмене/диспоузе подписки — подтверждён фактически

`_failQueuedRequests` ([event_subscription.dart:249-255](lib/src/event_subscription.dart#L249-L255)) завершает очередь через `NoHandlerException(topic.topic)`; вызывается из `cancel()` ([event_subscription.dart:349](lib/src/event_subscription.dart#L349)) и `_close()` ([event_subscription.dart:363](lib/src/event_subscription.dart#L363)). `fail()` классифицирует это как `RequestOutcome.noHandler` ([event_subscription.dart:623-627](lib/src/event_subscription.dart#L623-L627)). Семантически «отменено» ≠ «нет обработчика»; `RequestCanceledException` точнее и уже существует. **Однако** поведение задокументировано (doc/06-api-reference.md:300) и закреплено тестом (`test/handler_subscription_test.dart:403-429`), то есть это осознанный контракт, а не случайность. Менять — только с решением о совместимости.

## Прогоны

```
dart test test/_defect_verification_test.dart
00:00 +0: leastBusy sends sequential work to slot 0 only
00:00 +1: a handler StateError arrives as BusyException
00:00 +2: a throwing handler leaves the machine stuck
00:00 +3: All tests passed!

dart test test/_defect_verification_test.dart   # transport package
00:00 +0: defect verification fire publishes twice when an exact and a pattern node both have a serializer
00:00 +1: defect verification an offline fire throws before local delivery and currentData
00:00 +2: All tests passed!
```

Временные тестовые файлы после прогона удалены; рабочее дерево не содержит изменений кода.

## Итоговая оценка

- Требуют исправления как дефекты: 1, 3, 5, 6, 7, 8, 9 (утечка ключей `_errorWindows`), 10 (избыточность API).
- Подтверждены фактически, но являются задокументированным дизайном/контрактом: 2, 4 (свойство алгоритма), 11, 12. Их изменение — продуктовое/совместимостное решение, не баг-фикс.
