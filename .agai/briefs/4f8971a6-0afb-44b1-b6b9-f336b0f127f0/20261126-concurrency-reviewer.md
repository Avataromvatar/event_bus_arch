---
brief:
  schema: 1
  id: BR-2026-11-26-4f8971a6-0afb-44b1-b6b9-f336b0f127f0-dev-reviewer
  kind: work
  created_at: '2026-11-26T13:30:00+05:00'
  from: agai-sdlc:coordinator
  to: agai-dev:reviewer
  task:
    record: 4f8971a6-0afb-44b1-b6b9-f336b0f127f0
    short_id: 4f8971a6-0afb-44b1-b6b9-f336b0f127f0
    column: ''
    revision: 9a0cb35
  goal: Ранжированный список производственных рисков изолятов, WorkerPool, Layers и
    transport/NATS/MQTT с доказательствами файл:строка и сценариями отказа.
  scope:
    in:
    - lib/src/event_bus_isolate.dart, worker_pool.dart, layers.dart, capabilities.dart
    - packages/event_bus_arch_transport/lib/src/*
    - packages/event_bus_arch_nats/lib/src/* и packages/event_bus_arch_mqtt/lib/src/*
    - жизненный цикл, гонки, переподключение, гарантии доставки, ограничения адаптеров
    out:
    - ядро маршрутизации и подписок вне изолятов (отдельный обзор)
    - правки кода, тестов и конфигурации
    - стиль и форматирование
  done:
    - Каждая находка содержит file:line и конкретный сценарий отказа (вход/состояние → неверное поведение)
    - Находки разделены на реальные дефекты и проектные предпочтения и ранжированы по серьёзности
    - Названы ограничения, которые обязательно должны быть в документации до принятия библиотеки
    - Названо, что не проверялось
  constraints:
    - Только чтение; ни один файл не изменяется и не создаётся
    - Не запускать брокеры и не публиковать пакеты
    - Не повторять уже известные результаты dart analyze и тестов
  commit: false
  inputs:
  - kind: diff
    tier: critical
    ref: 'git:9a0cb35 (полный код, без diff)'
    why: обзор всей поверхности, а не одного изменения
    excerpt: 'event_bus_isolate.dart 1052 строки, worker_pool.dart 716, layers.dart 456;
      transport_event_bus.dart 324, transport_key_event_node.dart 265,
      reconnecting_transport_connection.dart 392; адаптеры NATS и MQTT.'
  - kind: spec
    tier: critical
    ref: doc/04-isolates-and-workers.md
    why: обещанный пользователю контракт изолятов, слоёв и пула
    excerpt: 'EventBusIsolate, Layers, WorkerPool, стратегии диспетчеризации, супервизия и
      перезапуск; гарантии, на которые рассчитывает пользователь.'
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
    excerpt: 'Все наборы зелёные; NATS 10 и MQTT 7 тестов пропущены без брокеров; покрытие
      isolate 86.8%, worker pool 85.4%, layers 86.8%.'
  - kind: standards
    tier: important
    ref: analysis_options.yaml
    why: принятый стандарт анализа и линтов репозитория
    when: если находка касается линтов, анализатора или стиля кода
    excerpt: 'include: package:lints/recommended.yaml; дополнительных правил нет.'
  budget:
    tokens_max: 12000000
  gaps:
    - Нет спецификации уровня продукта; контракт берётся из doc/04-isolates-and-workers.md
    - Брокерные интеграционные тесты в этой среде не запускались
  sources_checked:
    - .agai/tasks/4f8971a6-0afb-44b1-b6b9-f336b0f127f0/task.md@9a0cb35
    - doc/04-isolates-and-workers.md@9a0cb35
    - doc/artifacts/analysis/2026-11-26-test-evidence.md@working-tree
---

# Бриф: обзор конкурентности и транспорта

Проведи read-only обзор производственной готовности изолятов, пула воркеров, слоёв и
транспортного слоя с адаптерами NATS и MQTT. Пользователь — команда, которая запустит это в
нескольких изолятах и/или через брокер.

Ответ верни списком находок, отсортированным по серьёзности. По каждой: файл:строка, что не так,
сценарий отказа, серьёзность (блокер / высокий / средний / низкий). Отдельно — что не проверял.
Без правок кода.
