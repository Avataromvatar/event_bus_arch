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

## Ссылки
Вверх: нет (локальная задача). ADR: doc/decisions/0009-event-key-and-address.md
