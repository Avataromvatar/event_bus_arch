---
brief:
  schema: 1
  id: BR-2026-11-26-4f8971a6-0afb-44b1-b6b9-f336b0f127f0-dev-reviewer
  kind: work
  created_at: '2026-11-26T13:23:49+05:00'
  from: agai-sdlc:coordinator
  to: agai-dev:reviewer
  task:
    record: 4f8971a6-0afb-44b1-b6b9-f336b0f127f0
    short_id: 4f8971a6-0afb-44b1-b6b9-f336b0f127f0
    column: ''
    revision: 9a0cb35
  goal: Ранжированный список производственных рисков ядра event_bus_arch (маршрутизация,
    подписки, DTO, ошибки, наблюдаемость) с доказательствами файл:строка и сценариями отказа.
  scope:
    in:
    - lib/src/event_bus.dart, event_subscription.dart, event_dto.dart, event_address.dart
    - lib/src/event_probe.dart, event_bus_error.dart, observability.dart, error_window_store.dart, exception.dart
    - публичная точка входа lib/event_bus_arch.dart и её контракт
    - корректность жизненного цикла и API-эргономика для сторонних пользователей
    out:
    - изоляты, WorkerPool, Layers (отдельный обзор конкурентности)
    - transport/NATS/MQTT (отдельный обзор конкурентности)
    - правки кода и тестов
    - стиль и форматирование
  done:
    - Каждая находка содержит file:line и конкретный сценарий отказа (вход/состояние → неверное поведение)
    - Находки разделены на реальные дефекты и проектные предпочтения и ранжированы по серьёзности
    - Названо, что не проверялось
  constraints:
    - Только чтение; ни один файл не изменяется и не создаётся
    - Не запускать публикацию и не трогать git-историю
    - Не повторять уже известные результаты dart analyze и тестов
  commit: false
  inputs:
  - kind: diff
    tier: critical
    ref: 'git:9a0cb35 (полный код, без diff)'
    why: обзор всей поверхности, а не одного изменения
    excerpt: 'Ядро: event_bus.dart 1326 строк, event_subscription.dart 723, observability.dart 461,
      event_dto.dart, event_probe.dart, exception.dart; точка входа lib/event_bus_arch.dart.'
  - kind: spec
    tier: critical
    ref: doc/06-api-reference.md
    why: публичный контракт, который увидит пользователь библиотеки
    excerpt: 'Публичные типы и сигнатуры; fire/request/listen/subscribe, EventKey/EventAddress,
      EventSubscription, model bus, ошибки и метрики.'
  - kind: record
    tier: critical
    ref: .agai/tasks/4f8971a6-0afb-44b1-b6b9-f336b0f127f0/task.md
    why: границы задачи и критерии приёмки
    excerpt: 'Нужны находки с доказательствами и оценка готовности кода к применению; отчёт
      идёт в doc/artifacts/analysis/2026-11-26-product-readiness.md.'
  - kind: test-evidence
    tier: important
    ref: doc/artifacts/analysis/2026-11-26-test-evidence.md
    why: что уже проверено, чтобы не повторять прогоны
    when: если хочешь сослаться на пробел покрытия или проверить, не повторяешь ли известное
    excerpt: '280 тестов ядра зелёные; analyze — 19 info, 0 warn/error; покрытие lib 87.0%;
      event_dto.dart 50%, event_probe.dart 55.6%, observability.dart 84.2%.'
  - kind: standards
    tier: important
    ref: analysis_options.yaml
    why: принятый стандарт анализа и линтов репозитория
    when: если находка касается линтов, анализатора или стиля кода
    excerpt: 'include: package:lints/recommended.yaml; дополнительных правил нет.'
  budget:
    tokens_max: 12000000
  gaps:
    - Нет спецификации или требований уровня продукта; контракт берётся из doc/06-api-reference.md
    - Нет истории изменений по каждому дефекту, кроме плана remediation и CHANGELOG
  sources_checked:
    - .agai/tasks/4f8971a6-0afb-44b1-b6b9-f336b0f127f0/task.md@9a0cb35
    - doc/06-api-reference.md@9a0cb35
    - doc/artifacts/analysis/2026-11-26-test-evidence.md@working-tree
---

# Бриф: обзор ядра event_bus_arch

Проведи read-only обзор производственной готовности ядра библиотеки. Пользователь — сторонний
Dart/Flutter-разработчик, который поставит пакет из pub.dev и будет полагаться на доставку
событий, подписки, request-цикл и наблюдаемость.

Ответ верни списком находок, отсортированным по серьёзности. По каждой: файл:строка, что не так,
сценарий отказа, серьёзность (блокер / высокий / средний / низкий). Отдельно — что не проверял.
Без правок кода.
