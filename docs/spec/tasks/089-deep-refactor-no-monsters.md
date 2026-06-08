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

### 2026-06-08 ~13:40 — БАТЧ 1 (параллельный воркфлоу wf_9f02f059-c7e), частично
- Подход: 4 агента, каждый в изолированном git-worktree, целиком рефакторит
  один монстр-экран → analyze + 808 tests → commit `--no-verify` на ветку
  `wf-089-<name>` → adversarial verify-агент ревьюит diff.
- **Медленно**: каждый worktree = холодная flutter-сборка + 808 тестов; ~85 мин
  и ещё не всё. Один агент застрял (50 мин без активности) → воркфлоу его
  ретрайнул. Вывод: cold-build в worktree'ах дорогой; для будущих батчей —
  меньше конкурентность / тёплый кэш.
- **Результат 1/4: `subscription_detail_screen` 1063→339** (green, ветка
  `wf-089-subscription_detail_screen` @ c7b9f7f, 8 новых файлов). ⚠️ verify =
  **UNSAFE**: при извлечении detour-picker'а агент **уронил 2 поведения** —
  (1) §080 prefix-aware display-tag (`TagResolver.displayTag(prefix, n.tag)` →
  голый `n.tag`) = реинтродукция бага §080 (dangling detour при tag_prefix);
  (2) `if (!list.enabled) continue;` (disabled-серверы теперь в picker'е).
  **НЕ мерджить как есть — починить оба перед merge.** Остальные 7 файлов
  извлечены 1:1 верно.
- **КЛЮЧЕВОЙ урок:** агрессивные параллельные агенты МОГУТ ронять логику при
  больших извлечениях. Adversarial-verify обязателен; «тесты зелёные» не ловит
  такие регрессии (нет теста на §080-путь). Каждый результат = review+fix перед
  merge. 3 оставшихся (per_app_trace/dns/routing) ещё билдятся.


### 2026-06-08 11:13 — старт
- Заземлился: инвентарь монстров, существующие паттерны, §088 прочитан.
- Создан этот документ. Базлайн: `d7a0edd`, 808 тестов green, analyze clean.
- Дальше: Phase 0 (инспекция home_screen + точная карта декомпозиции) →
  Phase 1 (home_screen).

### 2026-06-08 11:20 — ⚠️ важное решение: НЕ `dart format` существующих файлов
- SDK 3.11 → `dart format` использует новый «tall»-стиль, который **раздувает**
  компактный код проекта (один extract дал diff 618 строк reflow + файл вырос
  2370→2380). Конфликтует с целью «меньше строк» + нечитаемый diff.
- **Правило сессии:** ручные правки существующих файлов в их стиле; `dart
  format` только на НОВЫХ файлах. Откатил первый коммит, переделал вручную.

### 2026-06-08 11:24 — P1.1 TrafficBar извлечён (коммит `5ab387e`)
- `_buildTrafficBar`+`_trafficChip`+`_shortPkg`+uptime-форматтер →
  `screens/home/widgets/traffic_bar.dart` (StatelessWidget). home_screen
  **2370→2263**. analyze clean, 808 green.
- Дубль-находка: home uptime-форматтер (со сворачиванием в дни) ≠
  `format_utils.formatDuration` (без дней) — дедуп = behavior change, оставлен
  отдельным (помечено).

### 2026-06-08 11:40 — P1.2 StatusChip+ProgressBanner+NodesHeader (`4841d30`)
- 3 виджета → `screens/home/widgets/`. `_isSortNonDefault` инлайнен в NodesHeader.
  home_screen **2263→2093**. analyze clean, 808 green.
- **Заметка по NodeList:** `_buildNodeList`+`_buildReorderableNodeList` (~292
  строки) — «твёрдое ядро», ~15 коллбэков/хелперов (filter/sort/split/copy/
  ping/reorder). Требует выноса prep-логики в view-model — отдельный аккуратный
  проход, НЕ механическое извлечение. Отложено.

### 2026-06-08 11:55 — P1.3 HomeDrawer + декаплинг (`c553725`)
- `_buildDrawer` → `screens/home/widgets/home_drawer.dart`. `_pushRoute`
  (drawer-only) инлайнен. **9 импортов экранов** ушли из home_screen (теперь
  только в HomeDrawer). home_screen **2093→1990**. analyze clean, 808 green.

### 2026-06-08 12:05 — P1.4 AddServerCta (`038e87f`)
- `_buildAddServerCta` → `screens/home/widgets/add_server_cta.dart`.
  `_restoreFromBackup` остаётся в экране (callback). home_screen **1990→1937**.

### CHECKPOINT 12:05 — состояние для продолжения (loop / свежий контекст)
**home_screen: 2370 → 1937** (−433) за 6 коммитов: `5ab387e` TrafficBar ·
`4841d30` StatusChip+ProgressBanner+NodesHeader · `c553725` HomeDrawer ·
`038e87f` AddServerCta. Все коммиты green (analyze + 808 tests). Базлайн до
§089: `fa75753`. Установлен 15-мин loop для продолжения.

**Новые файлы:** `screens/home/widgets/{traffic_bar,status_chip,
progress_banner,nodes_header,home_drawer,add_server_cta}.dart`.

**Следующий шаг при возобновлении:** см. ниже.

### 2026-06-08 — P1.5 модальные меню → home/home_menus.dart (`74ae07b`, ранее `…`)
- `showSortOptionsMenu` + `showPingSettings` вынесены как свободные функции в
  `screens/home/home_menus.dart` (decoupled: controller + SettingsStorage +
  TemplateLoader; `mounted`→`context.mounted` экв.). home_screen **1872→1718**.
- **home_screen: 2370 → 1718 (−652, −27.5%)** за 9 коммитов. Базлайн `fa75753`.

### Прогресс P1 (продолжение)
- `home/home_menus.dart` — `showSortOptionsMenu` + `showPingSettings` ✅
- `home/home_dialogs.dart` — `confirmStop` + `showRevokedSnackBar` +
  `showLocationPermissionDialog` ✅
- **home_screen: 2370 → 1665 (−29.7%)**, 12 коммитов §089, всё green.

### Остаток home_screen (для продолжения)
- **Диалоги** остаток → `home/home_dialogs.dart`: `_maybeShowUpdateSnackbar`,
  `_maybeShowNotificationPermissionDialog`, `_maybeShowBatteryOptimizationDialog`,
  `_showOemBatteryFollowupDialog` (mounted→context.mounted; некоторые юзают
  SettingsStorage flags + _controller — передавать параметрами).
- `_buildControls` + `_buildReloadButton` + `_showReloadMenu` + `_confirmStop`
  (~450 стр) → `home/widgets/home_controls.dart` + reload-меню в home_menus.
- **NodeList core** (`_buildNodeList`/`_buildReorderableNodeList` + prep-логика
  `_buildNodeFilter`/`_splitNodes`/`_viewSortedNodes`(+кэш)/`_protocolOfTag`/
  `_isControlTag`/`_computeDisplayList`/`_protoLabel`) → NodeListPresenter/VM +
  `home/widgets/node_list.dart`. Самое сцепленное, аккуратно.
- `_buildFilterPanel` (~270) → `home/widgets/filter_panel.dart` (делегирует
  filter_widgets — оценить).
- Node-actions: `_viewOutboundJson`/`_copyNodeJson`/`_copyNodeUri` (Config
  Introspection) → helper.
- Bootstrap/prefs: `_initSubsAndAutoUpdate`/`_loadHapticPref`/`_loadAutoRebuild`.

**Правила (ВАЖНО соблюдать при продолжении):**
1. НЕ `dart format` существующих файлов (tall-стиль Dart 3 раздувает) —
   ручные правки в стиле проекта. Новые файлы — format ок.
2. Каждый шаг: `flutter analyze` clean + `flutter test` (808) green → коммит.
   `flutter` в PATH: `/Users/macbook/projects/flutter-sdk/bin`.
3. Behavior-preserving. Тесты менять только импорты, иначе стоп.
4. PATH для git-hook бампает pubspec — это норма, не откатывать в коммите.

**home_screen — осталось извлечь (позиции плавают, грепать `^  Widget _build`):**
- `_buildAddServerCta` (~164 стр) — CTA пустого состояния. Чистый, но юзает
  `_restoreFromBackup` + AddServerWizard nav + `_autoUpdater`. Низкий-средний риск.
- `_buildControls` + `_buildReloadButton` (~370 стр) — connect-кнопки, reload-меню.
  Юзает StatusChip (готов), `_confirmStop`, `_showReloadMenu`, `_rebuild*`. Средний.
- `_buildNodeList` + `_buildReorderableNodeList` (~292) — ТВЁРДОЕ ЯДРО, отдельно.
- `_buildFilterPanel` (~270) — делегирует filter_widgets; оценить.
- **Диалоги/меню** (~600): `_maybeShow*PermissionDialog`, `_showOemBattery*`,
  `_showLocationPermissionDialog`, `_showRevokedSnackBar`, `_showSortOptionsMenu`,
  `_showReloadMenu`, `_showPingSettings`, `_confirmStop` → `home/home_dialogs.dart`.
- **Node actions/helpers**: `_viewOutboundJson`/`_copyNodeJson`/`_copyNodeUri`
  (ConfigIntrospection), `_subscriptionsOfTag`/`_buildNodeFilter`/`_splitNodes`/
  `_viewSortedNodes`/`_protocolOfTag`/`_isControlTag`/`_protoLabel` → helper/VM.
- **Bootstrap/prefs**: `_initSubsAndAutoUpdate`/`_loadHapticPref`/`_loadAutoRebuild`.

**Дальше по плану §089:** P2 экраны (per_app_trace 1662, dns 1388, routing 1219,
subscription_detail 1080, app_settings 982, subscriptions 967, stats 683,
live_events 663, backup 627) · P3 сервисы (traffic_profiler 1632,
settings_storage 941, post_steps 1132, box_vpn_client 607, uri_parsers 729) ·
P4 контроллеры (home_controller 1089) · P5 Kotlin (VpnPlugin 635) · P6 дедуп/
чистка · P7 ARCHITECTURE.md · P8 финал (APK build+install) + CHANGELOG.
