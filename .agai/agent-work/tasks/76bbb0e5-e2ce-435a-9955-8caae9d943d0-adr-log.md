# Запись о работе над задачей

### Задача

- Репозиторий: e:/workspace/dart/event_bus_arch
- ID и ссылка: 76bbb0e5-e2ce-435a-9955-8caae9d943d0 (локальная запись, YouGile не подключён)
- Название: Проверка дефектов сторонней проверки event_bus_arch
- Статус до / после: done / done (зафиксировано решение E)
- Сессия: 8bf51fbe-78ce-4a9f-892c-cae0d060cd75

### Участники

| Плагин | Агент или скил | Участие |
|---|---|---|
| agai-sdlc | records, task-sync | учёт и журнал |
| agai-dev | backend-developer | ADR-0009, обновление плана и анализа |

### Время и использование

- Начало / завершение: 2026-11-22T19:15+04:00 / 2026-11-22T19:22+04:00
- Активное время: ~7 минут (оценка)
- Токены: недоступны в этой сессии
- Стоимость: недоступна
- Источники метрик: .agai/metrics/sessions/ (если хост предоставит)

### Итог и доказательства

- Создан `doc/decisions/0009-event-key-and-address.md`: адрес — явная строка, тип — локальный
  `EventKey<T>`/`EventPatternKey<T>`, `Topic` заменяется на `EventAddress`/`EventPattern`,
  `paths`/`separator` уходят из API, узлы `(address, Type)`, транспорт без `typeTags`, codec'и
  типизированы, правило публикации «только точный ключ», FSM/Scope/Command — на ключах,
  метрики/ошибки — по адресу.
- `doc/decisions/README.md` — добавлена строка 0009.
- В `2026-11-22-event-address-analysis.md` добавлен баннер о принятом E.
- В `2026-11-22-defect-remediation-plan.md` добавлен статус: CHG-11a superseded, FIX-01
  становится структурным, REF-01 остаётся, остальные FIX без изменений.
- Код не менялся.

### Открытые вопросы и дальнейшие действия

- Реализация этапами из ADR: core → patterns → transport → isolate/pool/layers →
  observability/errors → docs/tests. Оценка 8–12 человеко-дней.
- До кода: зафиксировать точные сигнатуры `EventSelector`/`EventCodec` и правила
  `haveListener`/`haveHandler` на адресном уровне.
