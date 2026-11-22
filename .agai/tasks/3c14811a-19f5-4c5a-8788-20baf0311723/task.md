---
level: task
role: dev
local: true
estimate:
  effort_days: 10.0
  duration_days: 10
parallel: true
pending: update
---

# Implement ADR-0009: event address and key model

Локальная запись (YouGile не подключён). Реализация E по `doc/decisions/0009-event-key-and-address.md`.

## Как реализуем
**Владелец: разработчик**

Этапы:

1. **Core foundation** — `EventAddress`, `EventPattern`, `EventKey<T>`, `EventPatternKey<T>`,
   `EventSelector<T>` (Type-идентичность, фиксированная грамматика, паттерны) + тесты.
2. **Core bus** — `EventDTO.key`, узлы `(address, Type)`, диспетчеризация веером, `EventBus` API,
   `currentData`/`have*`/`remove`, ошибки/метрики.
3. **Patterns package** — FSM/Scope/Command на ключах.
4. **Transport** — address-only subjects, типизированные codec'и, без `typeTags`/`wireTypes`,
   правило «публикует только точный ключ», один subscription на адрес.
5. **Isolate/pool/layers** — address interest, ключи, без separator.
6. **Observability/errors** — ключ метрики = адрес, `EventBusError.address`.
7. **Docs/examples/migration** — переписать адресную модель, doc/15, README, CHANGELOG.

## Критерии приёмки
**Владелец: QA**

### AC-1: Адрес и ключ
Дано `EventKey<T>('orders.placed')` и `EventPatternKey<T>('orders.*')`
Когда создаются и сравниваются
Тогда адрес валидируется, паттерн матчится по токенам без типа, `Type`-идентичность стабильна.

### AC-2: Шина на ключах
Дано события на одном адресе с разными `T`
Когда выполняется `fire`/`request`/`subscribe`
Тогда типизированные узлы получают событие и фильтруют `data is T`, `currentData` — по ключу,
публикует только точный ключ.

### AC-3: Пакеты и тесты
Дано core, patterns, transport, NATS, MQTT
Когда прогоняются analyze и тесты
Тогда всё зелёное; obfuscation-check для transport проходит.

## Журнал работы агента
# Запись о работе над задачей

### Задача

- Репозиторий: e:/workspace/dart/event_bus_arch
- ID и ссылка: 3c14811a-19f5-4c5a-8788-20baf0311723 (локальная запись, YouGile не подключён)
- Название: Implement ADR-0009: event address and key model
- Статус до / после: in progress / in progress (этап 1 из 7)
- Сессия: 8bf51fbe-78ce-4a9f-892c-cae0d060cd75

### Участники

| Плагин | Агент или скил | Участие |
|---|---|---|
| agai-sdlc | records, task-sync | учёт и журнал |
| agai-dev | backend-developer | core foundation: адрес/ключ/паттерн + тесты |

### Время и использование

- Начало / завершение: 2026-11-22T19:30+04:00 / 2026-11-22T19:45+04:00
- Активное время: ~15 минут (оценка)
- Токены: недоступны в этой сессии
- Стоимость: недоступна
- Источники метрик: .agai/metrics/sessions/ (если хост предоставит)

### Итог и доказательства

Этап 1 (core foundation) выполнен:

- `lib/src/event_address.dart` — `EventAddress`, `EventPattern`, `EventKey<T>`,
  `EventPatternKey<T>`, `EventSelector<T>`; фиксированная грамматика `.`, `*`, `>`;
  `Type` захватывается через `Type _typeOf<T>() => T;`; равенство ключей по (address, Type),
  паттернов — по строке; `accepts` = `data is T`.
- `lib/event_bus_arch.dart` — файл подключён как part.
- `test/event_address_key_test.dart` — 22 теста: валидация адресов/паттернов, матчинг `*`/`>`,
  равенство/хеши, подтипы, различие exact/pattern ключей.
- Прогоны: новый файл 22 passed; полный core 257 passed; `dart analyze` — 17 info,
  ошибок/предупреждений нет. Старый API не тронут.
- Код не коммитился.

### Открытые вопросы и дальнейшие действия

- Этап 2: core bus — `EventDTO.key`, узлы `(address, Type)`, веерная диспетчеризация,
  `EventBus` API на ключах, `currentData`/`have*`/`remove`, ошибки/метрики. Это ломающее
  изменение; старые тесты будут переписаны в том же этапе.
- Затем: patterns package → transport → isolate/pool/layers → observability → docs/tests.

# Запись о работе над задачей

### Задача

- Репозиторий: e:/workspace/dart/event_bus_arch
- ID и ссылка: 3c14811a-19f5-4c5a-8788-20baf0311723 (локальная запись, YouGile не подключён)
- Название: Implement ADR-0009: event address and key model
- Статус до / после: in progress / in progress (этап 2 из 7 — core E internals)
- Сессия: 8bf51fbe-78ce-4a9f-892c-cae0d060cd75

### Участники

| Плагин | Агент или скил | Участие |
|---|---|---|
| agai-sdlc | records, task-sync | учёт и журнал |
| agai-dev | backend-developer | core E internals, compatibility layer, тесты |

### Время и использование

- Начало / завершение: 2026-11-22T19:45+04:00 / 2026-11-22T20:40+04:00
- Активное время: ~55 минут (оценка)
- Токены: недоступны в этой сессии
- Стоимость: недоступна
- Источники метрик: .agai/metrics/sessions/ (если хост предоставит)

### Итог и доказательства

Этап 2 (core E internals) выполнен в режиме совместимости:

- `EventDTO` теперь хранит `EventKey<T> key`; есть `address`, `EventDTO.withKey`, а
  совместимые `topic`/`paths`/`separator` остаются для старого API.
- `EventBus` хранит узлы как `Map<EventAddress, Map<Type, EventNode>>` и
  `Map<EventPattern, Map<Type, EventNode>>`; диспетчеризация идёт веером по всем типизированным
  узлам, каждый фильтрует `data is T`.
- Добавлен E API: `fireKey`, `requestKey`, `listenKey`, `subscribeKey`, `subscribeEventsKey`,
  `currentDataKey`, `haveListenerKey`, `haveHandlerKey`, `haveAvailableHandlerKey`, `removeKey`,
  `removePatternKey`, `removeAddress`.
- Старые методы (`fire<T>(data, paths:)`, `subscribeEvents<T>(paths:)`, …) стали
  compatibility-слоем: они строят `EventKey`/`EventPatternKey` из старого topic-стринга и
  вызывают новый API. Это временно; финальный E удалит старые методы.
- Handler-диспетчеризация переписана на кандидатов `(node, subscription)`; exact-адрес
  выигрывает у паттерна; `acceptsData` фильтрует по типу.
- `EventSubscription` хранит `selector` и даёт `topic` как совместимый view.
- Observability collection адаптирован к bucket-картам.
- `EventPattern.specificity` добавлен.

Новые тесты:
- `test/event_key_bus_test.dart` — 11 тестов: exact/pattern, два типа на одном адресе,
  подтипы, exact-vs-pattern handler, type mismatch, removeKey/removeAddress, have*, model bus,
  `EventDTO.withKey`.

Прогоны:
- `dart test` — **268 passed** (core);
- `dart analyze` — 17 info, ошибок/предупреждений нет.
- Код не коммитился.

### Открытые вопросы и дальнейшие действия

- Этап 3: patterns package — FSM/Scope/Command на `EventKey`/`EventPatternKey`.
- Этап 4: transport — address-only subjects, typed codecs, no typeTags, exact-key publish.
- Этап 5: isolate/pool/layers — address interest, E API; сейчас они работают через
  compatibility-слой, и новые `*Key` методы на них пока не бриджатся.
- Этап 6: observability/errors — метрики по адресу, `EventBusError.address`.
- Этап 7: удалить compatibility-слой и переименовать `*Key` в финальные имена; docs/tests.

# Запись о работе над задачей

### Задача

- Репозиторий: e:/workspace/dart/event_bus_arch
- ID и ссылка: 3c14811a-19f5-4c5a-8788-20baf0311723 (локальная запись, YouGile не подключён)
- Название: Implement ADR-0009: event address and key model
- Статус до / после: in progress / in progress (этап 3 из 7 — patterns package)
- Сессия: 8bf51fbe-78ce-4a9f-892c-cae0d060cd75

### Участники

| Плагин | Агент или скил | Участие |
|---|---|---|
| agai-sdlc | records, task-sync | учёт и журнал |
| agai-dev | backend-developer | Scope/Command/FSM на ключах, тесты, примеры |

### Время и использование

- Начало / завершение: 2026-11-22T20:45+04:00 / 2026-11-22T21:05+04:00
- Активное время: ~20 минут (оценка)
- Токены: недоступны в этой сессии
- Стоимость: недоступна
- Источники метрик: .agai/metrics/sessions/ (если хост предоставит)

### Итог и доказательства

Этап 3 (patterns package) выполнен:

- `Scope.initScope(EventBus bus, EventKey<T> key, {...})` — ключ обязателен, `paths` удалён;
  подписка идёт через `subscribeEventsKey`, команда — через `Command(bus, key)`.
- `Command(EventBus bus, EventKey<T> key, {int maxLen})`; `Command.key` вместо `paths`;
  `execute` использует `haveHandlerKey`/`requestKey`/`fireKey`.
- `FSM.addFSMTransition<E>(from, to, {required EventSelector<E> selector, ...})` — exact или
  pattern ключ; переходы матчатся по адресу и `data is E`, exact выигрывает у паттерна,
  специфичность паттерна учитывается; повторная регистрация того же selector+fromState
  заменяет переход.
- `FSM` по-прежнему слушает `allEventStream`, использует `dto.key`; try/finally от залипания
  сохранён.
- Обновлены тесты (20), примеры и README пакета.

Прогоны:
- `dart analyze` (patterns) — **No issues found**;
- `dart test` (patterns) — **20 passed**;
- `fsm_example.dart` и `migration_target_example.dart` — отработали.
- Код не коммитился.

### Открытые вопросы и дальнейшие действия

- Этап 4: transport — address-only subjects, типизированные codec'и, без `typeTags`/`wireTypes`,
  публикация только с точного ключа, один subscription на адрес.
- Затем isolate/pool/layers, observability/errors, удаление compatibility-слоя и docs.

# Запись о работе над задачей

### Задача

- Репозиторий: e:/workspace/dart/event_bus_arch
- ID и ссылка: 3c14811a-19f5-4c5a-8788-20baf0311723 (локальная запись, YouGile не подключён)
- Название: Implement ADR-0009: event address and key model
- Статус до / после: in progress / in progress (этап 4 из 7 — E transport)
- Сессия: 8bf51fbe-78ce-4a9f-892c-cae0d060cd75

### Участники

| Плагин | Агент или скил | Участие |
|---|---|---|
| agai-sdlc | records, task-sync | учёт и журнал |
| agai-dev | backend-developer | E transport, NATS/MQTT keyed factories, obfuscation-check |

### Время и использование

- Начало / завершение: 2026-11-22T21:10+04:00 / 2026-11-22T22:05+04:00
- Активное время: ~55 минут (оценка)
- Токены: недоступны в этой сессии
- Стоимость: недоступна
- Источники метрик: .agai/metrics/sessions/ (если хост предоставит)

### Итог и доказательства

Этап 4 (E transport) выполнен:

- Core-хуки `createNodeForKey`, `createPatternNodeForKey`, `shouldCreateNodeOnSendKey`; старый
  путь делегирует через `Topic`-view.
- `EventAddressMapper`: локальный адрес ↔ wire subject, префикс, грамматика NATS/MQTT, без
  type-token/typeTags.
- `EventCodec` + `EventCodecRegistry` (exact → most-specific pattern).
- `TransportKeyEventNode<T>`: инбаунд через codec, локальная типизированная доставка, публикация
  только когда `dto.key == selector`; pattern/супертипные узлы не публикуют.
- `TransportEventBus.keys(...)`: E-режим, E-узлы, `requestKey` через broker с codec.
- `EventBusNats.keys(...)`, `EventBusMqtt.keys(...)`, `NatsAddressMapper`, `MqttAddressMapper`;
  публичные ре-экспорты `EventAddressMapper`/`EventCodec`/`EventCodecRegistry`.

Тесты:
- transport: 28 старых + 9 новых E = **37 passed**;
- NATS: 42 старых + 2 новых = **44 passed** (+10 skipped);
- MQTT: 32 старых + 1 новый = **33 passed** (+7 skipped);
- core 268, patterns 20 — passed;
- `dart analyze` — 19 info, ошибок/предупреждений нет.

Obfuscation-check (`dart compile js -O2` + Node) для E transport:
```
address: orders.placed
accepted: true
publishes: 1
subject: orders.placed
data: A-1
```
То есть typed codec'и и стабильный адрес работают после минификации; старый путь с
`typeTags` для доменного класса публиковал 0.

### Открытые вопросы и дальнейшие действия

- Этап 5: isolate/pool/layers — address interest и E API; сейчас они работают через
  compatibility-слой, а `*Key` методы на них не бриджатся.
- Этап 6: observability/errors — метрики по адресу, `EventBusError.address`.
- Этап 7: удалить compatibility-слой, переименовать `*Key` в финальные имена, docs/tests.

# Запись о работе над задачей

### Задача

- Репозиторий: e:/workspace/dart/event_bus_arch
- ID и ссылка: 3c14811a-19f5-4c5a-8788-20baf0311723 (локальная запись, YouGile не подключён)
- Название: Implement ADR-0009: event address and key model
- Статус до / после: in progress / in progress (этап 5 из 7 — isolate/pool/layers)
- Сессия: 8bf51fbe-78ce-4a9f-892c-cae0d060cd75

### Участники

| Плагин | Агент или скил | Участие |
|---|---|---|
| agai-sdlc | records, task-sync | учёт и журнал |
| agai-dev | backend-developer | E isolate bridge, pool key API, тесты |

### Время и использование

- Начало / завершение: 2026-11-22T22:10+04:00 / 2026-11-22T23:05+04:00
- Активное время: ~55 минут (оценка)
- Токены: недоступны в этой сессии
- Стоимость: недоступна
- Источники метрик: .agai/metrics/sessions/ (если хост предоставит)

### Итог и доказательства

Этап 5 (isolate/pool/layers) выполнен:

- Проверено, что `EventKey` и `EventDTO` (включая `Type`) пересекают границу изолята.
- Interest-протокол переведён на строковые route'ы (address/pattern); `_RemoteInterest`
  матчит exact/pattern по адресу, без type-token; это сохраняет и старый topic-путь
  (адрес = старый topic string).
- `EventBusIsolate` и `_EventBusForIsolate` получили E-оверрайды:
  `fireKey`, `requestKey`, `removeKey`, `removePatternKey`, `removeAddress`;
  новые сообщения `_IsolateDeleteSelector`/`_IsolateDeleteAddress`.
- `WorkerPool.fireKey`/`requestKey`, keyed-dispatch использует `dto.address`;
  старые методы сохранены.
- `Layers` работает через E-bridge без отдельного API.

Новые тесты:
- `test/event_isolate_key_test.dart` — 5: main→worker fire, worker→main fire,
  requestKey, pattern key, removeKey/removeAddress через bridge;
- `test/worker_pool_key_test.dart` — 3: requestKey, fireKey, keyed dispatch.

Прогоны:
- core — **276 passed**;
- patterns 20, transport 37, NATS 44 (+10 skipped), MQTT 33 (+7 skipped);
- `dart analyze` — 19 info, ошибок/предупреждений нет.
- Код не коммитился.

### Открытые вопросы и дальнейшие действия

- Этап 6: observability/errors — ключ метрики = адрес, `EventBusError.address`.
- Этап 7: удалить compatibility-слой, переименовать `*Key` в `fire`/`request`/…,
  обновить docs/examples/tests.

# Запись о работе над задачей

### Задача

- Репозиторий: e:/workspace/dart/event_bus_arch
- ID и ссылка: 3c14811a-19f5-4c5a-8788-20baf0311723 (локальная запись, YouGile не подключён)
- Название: Implement ADR-0009: event address and key model
- Статус до / после: in progress / in progress (этап 6 из 7 — observability/errors)
- Сессия: 8bf51fbe-78ce-4a9f-892c-cae0d060cd75

### Участники

| Плагин | Агент или скил | Участие |
|---|---|---|
| agai-sdlc | records, task-sync | учёт и журнал |
| agai-dev | backend-developer | метрики по адресу, EventBusError.address, тесты |

### Время и использование

- Начало / завершение: 2026-11-22T23:10+04:00 / 2026-11-22T23:35+04:00
- Активное время: ~25 минут (оценка)
- Токены: недоступны в этой сессии
- Стоимость: недоступна
- Источники метрик: .agai/metrics/sessions/ (если хост предоставит)

### Итог и доказательства

Этап 6 (observability/errors) выполнен:

- `MetricKeyBuilder` теперь `String Function(String address)`; ключ метрики по умолчанию — адрес.
- `EventBusMetrics`: `recordFire`/`recordRequestStarted`/`recordRequestOutcome`/`recordOverflow`
  принимают строковый адрес; `_entryFor`/`_keyFor` — по адресу.
- Call sites обновлены: core, isolate (legacy — `topic.topic`, E — `key.address.value`),
  transport (legacy — `topic.topic`, E remote request — `key.address.value`).
- Snapshot подписок использует `subscription.selector` (строка + pattern flag).
- `EventBusError.address` добавлен как E-имя; `topic` остаётся совместимым полем.
- `transport_observability_test` обновлён под адресные ключи (`int.a`/`int.b`).

Прогоны:
- core **276**, patterns 20, transport 37, NATS 44 (+10 skipped), MQTT 33 (+7 skipped);
- `dart analyze` — 19 info, ошибок/предупреждений нет.
- Код не коммитился.

### Открытые вопросы и дальнейшие действия

- Этап 7 (финальная очистка, отдельный крупный проход):
  1. Переименовать `*Key`-методы в финальные `fire`/`request`/`listen`/`subscribe`/
     `subscribeEvents`/`currentData`/`have*`/`remove*`.
  2. Переименовать старые методы в `*Legacy` (или удалить) и мигрировать ~780 старых
     call sites в тестах/примерах.
  3. Удалить `Topic`/`TopicPattern`/`defaultTopicPathSeparator`/`paths`/`separator`-совместимость
     и старые тесты; переписать docs/00–15, README, CHANGELOG, примеры.
  4. Финальный прогон + obfuscation-check.

### Этап 7a: финальные имена API, документация и obfuscation-check

Выполнено:

- Новые E-методы переименованы в финальные имена: `fire`, `request`, `listen`, `subscribe`,
  `subscribeEvents`, `currentData`, `haveListener`, `haveHandler`, `haveAvailableHandler`,
  `remove`, `removePattern` (плюс `removeAddress`). Старые методы переименованы в `*Legacy`
  (`fireLegacy`, `requestLegacy`, `listenLegacy`, `subscribeLegacy`, `subscribeEventsLegacy`,
  `currentDataLegacy`, `have*Legacy`, `removeTopicLegacy`).
- Все call sites в тестах, примерах, пакетах и `tool/` мигрированы на новые имена; старые
  вызовы используют `*Legacy` и продолжают компилироваться.
- `EventBusError` принимает `address:` (приоритетнее `topic:`), `address` — E-имя;
  `NoHandlerException`, `BusyException`, `RequestTimeoutException`, `RequestCanceledException`
  получили геттер `address`.
- Примеры ядра, patterns, NATS и MQTT переписаны на ключи (`EventKey`/`EventPatternKey`) и
  keyed-транспорты; `dart analyze` по примерам чист.
- Документация переписана на E-модель: README, `doc/00`–`doc/15`, README пакетов
  `event_bus_arch_transport`, `_nats`, `_mqtt`; CHANGELOG 4.0 дополнен.
- Obfuscation-check: `dart compile js -O2` + Node на `packages/event_bus_arch_transport/build/
  obfuscation_check.dart`; пользовательский класс в `Type.toString()` даёт `minified:bp`, но
  `EventKey<UserOrder>('orders.placed')` разрешает кодек и публикует ровно один раз:
  `accepted=true publishes=1 subject=orders.placed`.

Прогоны:

- core 278, patterns 20, transport 37, NATS 44 (+10 skipped), MQTT 33 (+7 skipped) — все зелёные;
- `dart analyze` — 19 info, ошибок и предупреждений нет;
- код не коммитился.

Осталось (этап 7b, отдельный крупный проход):

1. Удалить legacy-слой: `Topic`/`TopicPattern`/`paths`/`separator`, `*Legacy`-методы,
   `EventDTO.topic`/legacy-фабрики, `EventSubscription.topic`.
2. Удалить legacy-транспорт (`serializers`/`deserializers`/`typeTags`, `TopicSubjectMapper`,
   `TransportEventNode`, `TopicRegistryIndex`) и мигрировать ~2.8 тыс. строк тестов
   transport/NATS/MQTT на keyed-режим.
3. Переписать ~560 старых call sites в 20 core-тестах на E-ключи (тесты поведения isolate,
   pool, backpressure и observability при этом сохранить).
4. Обновить `tool/migrate_3_to_4.dart` под адресную модель (сейчас он умеет только
   `handlers.setHandler` → `subscribeEvents`).

## Ссылки
Вверх: нет (локальная задача). ADR: doc/decisions/0009-event-key-and-address.md
