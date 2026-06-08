# 089 — Глубокий рефакторинг: убрать «монстров», навести архитектуру

| Поле | Значение |
|------|----------|
| Статус | **In progress** (автономная сессия, старт 2026-06-08 11:13 MSK) |
| Тип | refactor / architecture / docs |
| Скоуп | Весь `app/lib` + `app/android/.../kotlin` + `docs/ARCHITECTURE.md` |
| Жёсткий инвариант | **Zero behavior change.** Каждый шаг: `flutter analyze` clean + `flutter test` (808) green. Не коммитить red. Инкрементальные коммиты. |
| Связанные | §085 (architecture-roadmap — продолжаем его), §068/§048/§076/§083. |

> **Это living-документ + отчёт.** Раздел [Журнал](#журнал-выполнения) пополняется
> по ходу. Юзер ушёл до ~13:00, работа автономная.

---

## 1. Как понял задачу

Юзер: *«сделай полный глубокий аккуратный рефактор чтобы в проекте не осталось
монстров»*. Конкретно:

1. **Убрать монстров** — крупные файлы (God-objects), начиная с `home_screen.dart`
   (2370 строк, №1). Цель — ни одного «монстра».
2. **Слои абстракций** — аккуратно развести логику по слоям, понятные зоны
   ответственности.
3. **Убрать дубли** — общие механизмы вынести, не копировать.
4. **Подписные механизмы** — хорошие state/event-брокеры (ChangeNotifier/Stream),
   чистый data-flow.
5. **Разнести по файлам**, понятные имена, **убрать ненужные комментарии**,
   **почистить исторические особенности** (legacy-наслоения).
6. **Архитектура**: роутинг, брокеры событий, брокеры состояний, диаграммы
   данных, движение событий, известные качественные паттерны.
7. **Документация**: полный апдейт `docs/ARCHITECTURE.md` — схемы, зоны
   ответственности, **описание всех файлов проекта**, логика ключевых
   архитектурных решений. Если надо — вынести часть в отдельные файлы.
8. **Всё проинспектировать.** Автономно, не спрашивать, самому принимать решения,
   не останавливаться; 15-мин loop как страховка от случайной остановки.

### Главное архитектурное решение (моё, зафиксировано)
**Это behavior-preserving структурный рефактор + документация, НЕ переписывание.**
Приложение работает (808 тестов, прод-VPN). Не вводим новый state-management
фреймворк и не переписываем рабочую логику — **формализуем и извлекаем**
существующие паттерны (ChangeNotifier-контроллеры, Stream из `box_vpn_client`,
singleton-сервисы, `ConfigCache`, `home_return_observer`). Риск регрессии в
боевом VPN важнее косметики. Тесты — сеть безопасности на каждом шаге.

### Порог «монстра»
Целевой потолок одного файла — **≤ ~600 строк**, большинство **< 400**. Экраны
**композируют** (тонкие), логика живёт в контроллерах/сервисах/view-model'ях,
виджеты-поддеревья — в `screens/<area>/widgets/`. Легитимные исключения
(таблицы данных, протокол-парсеры, сгенерированный код) — помечаются явно.

### Очередь / приоритеты
- **§089 (этот рефактор) — primary.** Вся автономная сессия.
- **§088 (wake-heal escalation) — secondary**, queued. Design-док с открытыми
  вопросами (native+Dart recovery-логика). Беру после того как рефактор дойдёт
  до безопасной точки; если не успею — остаётся следующей задачей.

---

## 2. Текущая архитектура (как есть — инвентаризация)

**Слои (де-факто):**
- **Platform/VPN**: `vpn/box_vpn_client.dart` (MethodChannel мост, status-Stream),
  native Kotlin (`BoxService`/`VpnPlugin`/`DefaultNetworkMonitor`).
- **Services** (stateless/singleton): `parser/`, `builder/`, `subscription/`,
  `settings_storage`, `clash_api_client`, `traffic_profiler`, `debug/`, и пр.
- **State-брокеры** (ChangeNotifier): `HomeController`, `SubscriptionController`,
  `NodeFilterViewModel`, `custom_rule_edit/EditController`.
- **UI**: `screens/`, `widgets/`. Подписка через `AnimatedBuilder`/`ListenableBuilder`.
- **Cross-cutting**: `ConfigCache` (render hot-path), `AppInfoCache`, `http_cache`,
  `config_introspection`, `home_return_observer` (RouteObserver), `.I`-синглтоны.

**Event-flow (как есть):** native → `box_vpn_client` status `Stream<TunnelStatusEvent>`
→ `HomeController` → UI (`AnimatedBuilder`). Clash API polling → `traffic_profiler`
(`StreamController`) → stats/live UI.

## 3. Инвентарь монстров (>600 строк)

| Файл | Строк | План декомпозиции |
|---|---|---|
| `screens/home_screen.dart` | 2370 | **№1.** Извлечь поддеревья в `screens/home/widgets/` (app bar, node list section, server panel, connect button, dialogs, drawer/menu); остаток логики → `HomeController`/новые view-model. Экран → тонкий composition-root. |
| `screens/per_app_trace_tab.dart` | 1662 | Разбить на виджеты (header/controls/list/row/detail) + вынести форматирование/группировку в helper. |
| `services/traffic_profiler.dart` | 1632 | Split по ответственности: collector / rolling buffer / aggregation / Debug-API surface / models. |
| `screens/dns_settings_screen.dart` | 1388 | Секции-виджеты + form-state (LazyPersistMixin уже есть). |
| `screens/routing_screen.dart` | 1219 | Секции/виджеты + rule-list. |
| `services/builder/post_steps.dart` | 1132 | Разбить по шагам (каждый post-step — модуль). |
| `controllers/home_controller.dart` | 1089 | Разнести concerns: tunnel-lifecycle / node-actions / ping-orchestration / heartbeat. Формализовать брокеры. |
| `screens/subscription_detail_screen.dart` | 1080 | Виджеты + actions. |
| `screens/app_settings_screen.dart` | 982 | Секции-виджеты. |
| `screens/subscriptions_screen.dart` | 967 | Виджеты + list/row. |
| `services/settings_storage.dart` | 941 | Разрезать по доменам ключей (vpn/dns/ui/subscription/...) через part'ы или под-сторы. |
| `controllers/subscription_controller.dart` | 768 | По ответственности. |
| `services/parser/uri_parsers.dart` | 729 | По протоколам (возможно легитимный размер — оценить). |
| `screens/stats_screen.dart` | 683 | Виджеты. |
| `screens/live_events_tab.dart` | 663 | Виджеты. |
| `screens/backup_screen.dart` | 627 | Виджеты. |
| `models/custom_rule.dart` | 618 | Оценить (sealed-split §054 plan?). |
| `vpn/box_vpn_client.dart` | 607 | Method-группы / timeouts / status-parse. |
| `android/.../VpnPlugin.kt` | 635 | Split handler-группы. |
| `android/.../BoxService.kt` | 579 | На грани — оценить. |

## 4. Целевая архитектура (формализация)

Будет уточнена в Phase 0 и зафиксирована в `docs/ARCHITECTURE.md` со схемами:
- **Чёткие 4 слоя** (Platform → Services → State → UI), правила зависимостей
  (UI не лезет в Platform напрямую; логика не в `build()`).
- **State-брокеры**: каноничный паттерн ChangeNotifier-контроллер + извлечённые
  view-model'и для крупных экранов (как §085 R3 `NodeFilterViewModel`).
- **Event-брокеры**: status-Stream, profiler-Stream — задокументировать как
  единый event-bus pattern; убрать ad-hoc подписки.
- **Routing**: текущая навигация (`Navigator.push` + `home_return_observer`) —
  описать, при возможности централизовать route-таблицу.
- **Диаграммы данных**: build-pipeline, event-flow, state-ownership — ASCII в доке.

## 5. Протокол выполнения (на каждый шаг)

1. Извлечение — маленький coherent коммит.
2. `flutter analyze` → clean. `flutter test` → 808 green.
3. Коммит (`refactor(§089): ...`). Никогда red.
4. Обновить [Журнал](#журнал-выполнения).
5. В конце — `flutter analyze` + `flutter test` + release-APK build (Kotlin
   compile) + install на телефон; финальный отчёт; обновить ARCHITECTURE.md.

## 6. Зоны риска / контроль
- Боевой VPN — поведение неизменно; нет изменений публичных API/UX.
- Widget-extraction проверяется существующими widget-тестами + analyze.
- Если рефактор требует менять тесты сверх импортов — это сигнал пересмотреть
  (значит поведение поехало). Стоп, разобраться.
- Kotlin — компиляция только через APK build; native трогаю осторожно и в конце.

---

## Журнал выполнения

### 2026-06-08 11:13 — старт
- Заземлился: инвентарь монстров, существующие паттерны, §088 прочитан.
- Создан этот документ. Базлайн: `d7a0edd`, 808 тестов green, analyze clean.
- Дальше: Phase 0 (инспекция home_screen + точная карта декомпозиции) →
  Phase 1 (home_screen).
