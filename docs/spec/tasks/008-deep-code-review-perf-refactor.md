# 008 — Deep code review: performance, упрощения, кандидаты на рефакторинг

| Поле | Значение |
|------|----------|
| Статус | Done (отчёт) |
| Дата старта | 2026-04-20 |
| Дата завершения | 2026-04-20 |
| Коммиты | — (только документация) |
| Связанные spec'ы | [`003 home screen`](../features/003%20home%20screen/spec.md), серия [001](./001-reconnect-sink-leak.md)–[007](./007-peer-review-tasks-001-006.md) |
| Объём ревью | `app/lib/**/*.dart` (фокус: hot path Home, контроллеры, Clash, таймеры, JSON); Android Kotlin не входил в глубину |

## Проблема

После серии задач **001–006** и правок по **007** нужна свежая картина: где ещё тратятся CPU/аллокации, что усложняет сопровождение, что имеет смысл отложить до появления метрик.

## Диагностика

Статический обход: `grep` по `notifyListeners`, `jsonDecode`, `Timer.periodic`, `AnimatedBuilder` / `Listenable.merge`; чтение фрагментов `home_screen.dart`, `home_controller.dart`, `home_state.dart`, `clash_api_client.dart`, `subscription_controller.dart`, `app_log.dart`, `auto_updater.dart`, `speed_test_screen.dart`, `settings_storage.dart`.

**Профилирование (Flutter DevTools / systrace) в этом отчёте не выполнялось** — приоритеты ниже по «силе сигнала» кода и опыту типичных Flutter/Android узких мест.

## Резюме

| Категория | Вердикт |
|-----------|---------|
| Главный экран после **005** | База здоровая: `ConfigCache`, memo `sortedNodes`, батч `_emit` по статусу |
| Риск роста техдолга | Крупные монолиты (`home_screen`, `home_controller`) — главный рефакторинг-кандидат |
| Сеть / JSON | На hot path в основном осознанные decode после HTTP; дублирующий parse `configRaw` в редких UI-действиях |

---

## Performance — рекомендации

### P1 — Массовый пинг: частые `_emit` под параллельными воркерами

**Файл:** `app/lib/controllers/home_controller.dart` (`pingAllNodes`, воркеры с `_pingConcurrency`).

На **каждый** завершённый `delay` делается `Map.from` + `_emit` → новый `HomeState` → пересчёт `late final sortedNodes` + `notifyListeners` → полный rebuild `AnimatedBuilder` на Home с `Listenable.merge([_controller, _subController])`.

При 50 нодах и concurrency 10 это до **десятков emit’ов в секунду** в пике. Раньше в **005** уже отмечали «batched emit для ping» как возможный следующий шаг.

**Рекомендации (на выбор):**

1. **Батчинг:** накапливать `lastDelay`/`pingBusy` в локальной мапе в воркере-координаторе и вызывать `_emit` раз в 100–200 ms или после пачки из K завершений (с финальным emit в конце эпохи).
2. **Throttling notify:** реже дергать UI при том же обновлении данных (осторожно с финальным консистентным state).

**Риск:** сложнее отлаживать отмену (`_massPingEpoch`); нужны тесты на cancel mid-flight.

### P2 — `pingNode` (одиночный): два `_emit` подряд

Сначала `pingBusy`, потом результат — два rebuild подряд. Низкий приоритет; можно слить в один `copyWith`, если заметят микролаг на слабых устройствах.

### P3 — Повторный `jsonDecode(state.configRaw)` в Home UI

**Файл:** `app/lib/screens/home_screen.dart`.

- `_viewOutboundJson` / `_copyNodeJson` при пользовательском действии парсят весь `configRaw` заново.
- `_countNodesInConfig` после rebuild вызывается из snackbar-пути — не hot path каждые 20 s, но лишний полный parse большого JSON.

**Рекомендация:** для «посмотреть JSON ноды» достаточно редко — ок как есть. Если появятся частые вызовы — вынести «индекс tag → outbound map» в `ConfigCache` / отдельный lazy-кэш на `HomeState` (по аналогии с detour/proto).

### P4 — `ClashApiClient`: новый `http.Client()` по умолчанию

Каждый `ClashApiClient(...)` без внешнего клиента создаёт свой `http.Client`. Сейчас жизненный цикл привязан к `HomeController` (`_rebuildClashEndpoint`) — обычно один клиент на сессию. Если когда-нибудь начнут плодить клиенты в цикле — стоит явный **singleton / пул** или передача shared `Client` из DI.

### P5 — `AppLog`: `notifyListeners` на каждую строку лога

**Файл:** `app/lib/services/app_log.dart`.

В шумном логировании (core + app) `DebugScreen` может перестраиваться очень часто. В **005** сознательно не батчили.

**Рекомендация (низкий приоритет):** при открытом DebugScreen — coalesce через `SchedulerBinding.scheduleFrameCallback` или debounce 32–50 ms; при закрытом экране listeners часто нет — оставить как есть.

### P6 — `AutoUpdater`: `Timer.periodic` раз в час всегда

**Файл:** `app/lib/services/subscription/auto_updater.dart`.

Таймер живёт, пока жив контроллер, **независимо от lifecycle приложения** (в отличие от Stats/Connections после **005**).

**Рекомендация:** по желанию согласовать с продуктом — пауза при `AppLifecycleState.paused` (как у опроса Clash), если не хотят фоновых `maybeUpdateAll` пока пользователь не в приложении. Иначе оставить: интервал большой, нагрузка низкая.

### P7 — `SpeedTestScreen`: `Timer.periodic` 500 ms на время download-теста

**Файл:** `app/lib/screens/speed_test_screen.dart` (`_multiStreamDownload`).

Таймер **короткоживущий** и отменяется по завершении теста — нормально. Если пользователь уходит с экрана во время теста — имеет смысл `dispose`/`RouteAware` отменять тест и таймер (защита от утечек и лишних setState); проверить наличие отмены при `pop`.

### P8 — `settings_storage.dumpCache`

**Файл:** `app/lib/services/settings_storage.dart` — `jsonDecode(jsonEncode(data))` для глубокой копии.

Дорого на больших кэшах; вызывается с debug API, не в user hot path. Оставить до появления жалоб или заменить на структурную копию по allow-list.

---

## Упрощения и читаемость

1. **`home_screen.dart`** — очень большой файл (Drawer + ноды + диалоги + ping settings + JSON viewer). Имеет смысл поэтапно вынести: панель нод, chip статуса, меню действий, bottom sheets — в `widgets/` или `screens/home/` без смены поведения.
2. **`home_controller.dart`** — много ответственности (VPN события, Clash, heartbeat, ping, auto ping, clash reload, debug). Возможные границы выделения: **туннель/VPN**, **Clash+прокси**, **ping/mass ping** — с узким публичным API для UI.
3. **`routing_screen.dart`**, **`custom_rule_edit_screen.dart`** — много `setState`; при следующем касании экрана — вынести секции в `StatelessWidget` + колбэки, чтобы уменьшить пересборки (локальный рефакторинг без ValueNotifier там, где не нужно).
4. **Дублирование логики «parse config for tags»** между `ConfigCache`, `_countNodesInConfig`, `_viewOutboundJson` — единая утилита или расширение кэша снизит риск расхождения фильтров типов outbounds.

---

## Кандидаты на рефакторинг (архитектура)

| Область | Зачем | Риск |
|---------|--------|------|
| Разбиение `HomeScreen` | Тестируемость, code review, меньше конфликтов в git | Средний — нужна дисциплина не менять UX |
| Выделение сервиса «Tunnel state machine» из `HomeController` | Явные переходы, проще тесты на 001/002/004 сценарии | Высокий — трогает много call site’ов |
| `SubscriptionController` + множественные `notifyListeners` | При росте списка подписок — debounce/coalesce persist | Средний — не сломать сохранение |

---

## Риски и edge cases

- Любой **батчинг emit** для ping должен уважать `_massPingEpoch` и `cancelMassPing`, иначе гонки UI.
- Пауза `AutoUpdater` в background может **задерживать** обновление подписок до следующего resume — продуктовое решение.
- Рефакторинг без метрик может быть **преждевременной оптимизацией**; для P1 имеет смысл снять один профиль на реальном девайсе с 50+ нодами и mass ping.

## Верификация

- Обход исходников и сопоставление с отчётом **005** (уже сделанные оптимизации не дублировать как «новые»).
- Сборка/тесты для этого task-файла не запускались (документация только).

## Нерешённое / follow-up

| Приоритет | Действие |
|-------------|----------|
| Высокий | P1: профиль + при необходимости batched emit при mass ping |
| Средний | Разрезать `home_screen` на подвиджеты (инкрементально) |
| Средний | P6: решить, нужна ли пауза `AutoUpdater` в background |
| Низкий | P2, P3, P5, P8 — по сигналу от профиля или жалоб |
| Долгий | Выделение подсистем из `HomeController` (VPN vs Clash vs ping) |

После реализации любого пункта — отдельный task в `docs/spec/tasks/` с коммитами и критериями приёмки, по стилю [README](./README.md).
