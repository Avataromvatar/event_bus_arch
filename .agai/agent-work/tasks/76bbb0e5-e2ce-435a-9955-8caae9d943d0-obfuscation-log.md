# Запись о работе над задачей

### Задача

- Репозиторий: e:/workspace/dart/event_bus_arch
- ID и ссылка: 76bbb0e5-e2ce-435a-9955-8caae9d943d0 (локальная запись, YouGile не подключён)
- Название: Проверка дефектов сторонней проверки event_bus_arch
- Статус до / после: done / done (добавлена проверка обфускации)
- Сессия: 8bf51fbe-78ce-4a9f-892c-cae0d060cd75

### Участники

| Плагин | Агент или скил | Участие |
|---|---|---|
| agai-sdlc | records, task-sync | учёт и журнал |
| agai-dev | backend-developer | эксперимент dart2js -O2, анализ E/A после обфускации |

### Время и использование

- Начало / завершение: 2026-11-22T18:50+04:00 / 2026-11-22T19:03+04:00
- Активное время: ~13 минут (оценка)
- Токены: недоступны в этой сессии
- Стоимость: недоступна
- Источники метрик: .agai/metrics/sessions/ (если хост предоставит)

### Итог и доказательства

Дополнен `doc/artifacts/plans/2026-11-22-event-address-analysis.md` разделом 7.

Эксперимент `dart compile js -O2` + Node:
- `Type`-равенство выживает: `EventKey<int> == EventKey<int>` true, `int` vs `num` false,
  `EventKey<OrderPlaced> == EventKey<OrderPlaced>` true.
- `Type.toString()` для пользовательского класса: `minified:bd` — нестабильно.
- `Map<Type, String>` lookup работает; lookup по строке `'OrderPlaced'` → null.
- Текущий `TransportEventBus` с `serializers: {'OrderPlaced': ...}` и
  `typeTags: {'OrderPlaced': ...}`: локальный topic `minified:am`, `accepted: false`,
  `publishes: 0`.

Вывод: текущий `typeTags` и строковые registries сериализаторов не работают после обфускации для
пользовательских классов. A должен включать типизированные codecs (A+), а E — строиться на
`Type`/`is` и пользовательских адресах, без `'$T'` в identity/registries/wire. Оценка A+
поднята до 2–3 дней. Временные скрипты удалены; код проекта не менялся.

### Открытые вопросы и дальнейшие действия

- Обновить doc/08/09/10: текущая рекомендация `typeTags` неполна для доменных классов.
- Решение: A+ или E.
