---
level: task
role: dev
local: true
estimate:
  effort_days: 2.0
  duration_days: 2
parallel: true
pending: update
---

# Finalize the separator and extract FSM/Scope/Command into event_bus_arch_patterns

Локальная запись (YouGile не подключён). Решения человека 2026-11-22: проект не опубликован,
совместимость с 3.x не нужна, поэтому изменения делаются сейчас.

## Как реализуем
**Владелец: разработчик**

1. `defaultTopicPathSeparator` — параметр конструктора `EventBus` / `EventBusImpl` /
   `EventBusIsolate` (и `WorkerPool`), поле `final`; убрать изменяемое поле из `EventBusMixin`;
   пробросить сепаратор на worker-сторону изолята, иначе interest-ключи разойдутся.
2. Новый workspace-пакет `event_bus_arch_patterns`: `FSM`, `Scope`, `Command` переезжают из
   `lib/src/` ядра вместе со своими тестами, примерами и README; ядро больше их не экспортирует.
3. Обновить документацию, CHANGELOG, примеры, ссылки в doc/.
4. Прогнать `dart analyze` и тесты ядра и всех пакетов.

## Критерии приёмки
**Владелец: QA**

### AC-1: Сепаратор неизменяем
Дано `EventBus(separator: '/')`
Когда созданы узлы и вызываются методы без явного separator
Тогда используется '/', изменить значение после создания нельзя; `EventBusIsolate` с
нестандартным сепаратором работает на обеих сторонах.

### AC-2: Паттерны в отдельном пакете
Дано `packages/event_bus_arch_patterns`
Когда импортируется `package:event_bus_arch_patterns/event_bus_arch_patterns.dart`
Тогда доступны `FSM`, `Scope`, `Command`; ядро их не экспортирует, тесты ядра и пакета зелёные.

## Журнал работы агента
# Запись о работе над задачей

### Задача

- Репозиторий: e:/workspace/dart/event_bus_arch
- ID и ссылка: 32cb6728-c6fc-48cf-8ca2-e7c16163186c (локальная запись, YouGile не подключён)
- Название: Finalize the separator and extract FSM/Scope/Command into event_bus_arch_patterns
- Статус до / после: in progress / done (локальная задача)
- Сессия: 8bf51fbe-78ce-4a9f-892c-cae0d060cd75

### Участники

| Плагин | Агент или скил | Участие |
|---|---|---|
| agai-sdlc | task-sync, records | учёт задачи, журнал |
| agai-dev | backend-developer | правки ядра, новый пакет, тесты, документация |

### Время и использование

- Начало / завершение: 2026-11-22T17:22+04:00 / 2026-11-22T17:55+04:00
- Активное время: ~33 минуты (оценка по интервалам активности)
- Токены: недоступны в этой сессии
- Стоимость: недоступна
- Источники метрик: .agai/metrics/sessions/ (если хост предоставит)

### Итог и доказательства

1. `defaultTopicPathSeparator` финализирован:
   - `EventBus`, `EventBusImpl`, `EventBusIsolate`, `WorkerPool` принимают `separator:`;
   - поле в `EventBusMixin` удалено, в `EventBusImpl` — `final`;
   - `EventBusIsolate` пробрасывает сепаратор в worker-сторону (data[4] → `_EventBusForIsolate`), иначе interest-ключи расходятся;
   - `WorkerPool` использует свой сепаратор в `fire`/`request` и в дочерних `EventBusIsolate`;
   - `TransportEventBus` остаётся на '.', т.к. этого требует wire-грамматика.
2. Новый пакет `packages/event_bus_arch_patterns` 0.1.0:
   - `FSM`, `Scope`, `Command` перенесены из `lib/src/`, ядро их больше не экспортирует;
   - тесты перенесены (fsm, command/scope, naming-группы), примеры перенесены;
   - FIX-03 применён при переносе: `try/finally`, очистка ignored, удалено мёртвое `_FSM.bus`;
   - добавлен регрессионный тест «throwing handler does not leave the machine stuck».
3. Новые регрессионные тесты на сепаратор: `EventBusIsolate(separator: '/')` и `WorkerPool(separator: '/')`.
4. Документация обновлена: README, doc/README, doc/01–07, doc/14, doc/15, CHANGELOG, RELEASE, ROADMAP, plan-документ; новый README/CHANGELOG пакета.
5. `dart format` применён к изменённым файлам.

Прогоны:
- `dart analyze` — 14 info, ошибок и предупреждений нет;
- core `dart test` — 235 passed;
- patterns `dart test` — 20 passed;
- Chrome smoke — 6 passed;
- transport 28, NATS 42 (+10 skipped), MQTT 32 (+7 skipped) — passed;
- примеры `fsm_example.dart` и `migration_target_example.dart` — отработали.

### Открытые вопросы и дальнейшие действия

- Имя пакета `event_bus_arch_patterns` можно поменять до первой публикации; ядро от имени не зависит.
- `Layers` и `TransportEventBus` используют '.'; для Layers сепаратор можно добавить отдельной задачей.
- Остальные баги Part I (FIX-01, 05, 06, 07, 08, 09, 10) не трогались.

## Ссылки
Вверх: нет (локальная задача)
