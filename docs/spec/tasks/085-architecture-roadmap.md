# 085 — Architecture roadmap (layers, abstractions, decomposition)

| Поле | Значение |
|------|----------|
| Статус | In progress — реализуется инкрементально по roadmap |
| Дата | 2026-06-08 |
| Тип | architecture / refactor roadmap |
| Метод | Multi-agent arch-analysis: 7 срезов × (анализатор Explore + verify high-impact рекомендаций). 28 агентов, 1.7M токенов. Факты верифицированы против кода. |
| Зависимости | поверх всего кода; связан с §084 (code-audit), §077/§079/§080 (tag-prefix bug class). |

## Контекст

Запрос: «подумать про организацию архитектуры, уровни абстракций и слои».
Анализ — системный взгляд поверх точечной чистки §084. Цель документа:
зафиксировать состояние + дать приоритизированный roadmap для
инкрементального движения. Не «переписать всё», а закрыть конкретные
структурные долги с доказанным payoff.

## Текущая слоевая модель

```
   screens/ (UI, ~30 файлов плоско; home_screen 2639 — God-object)
      │  ChangeNotifier + AnimatedBuilder
   controllers/  HomeController (1089, God-controller) · SubscriptionController (чище)
      │
   services/  parser · builder · subscription · debug · storage · traffic_profiler
      │
   models/  sealed NodeSpec/ServerList/SingboxEntry · HomeState · validation
      │  MethodChannel/EventChannel
   vpn/ → native Kotlin (§049 F1 split)
```

## Что организовано ХОРОШО (не трогать)

- **`EmitContext`** — sealed model↔builder протокол. Чистый шов.
- **Debug API contract** (`contract/errors.dart` 9 typed errors + handlers + transport + middleware) — transport-agnostic.
- **Sealed `NodeSpec`/`ServerList`/`SingboxEntry`** — exhaustive, без runtime `type==` чеков.
- **`BuildResult` + `validation`** — typed boundary билдера.
- **Native split (§049 F1)** — `BoxVpnService` тонкий → `BoxService` владеет libbox.
- **`SubscriptionController`** — хорошо scoped (~20 public методов, чёткие CRUD/generate/utils границы). Эталон для контроллеров.

## Observations (верифицированы против кода)

### Слоевые зависимости
- **Models не чисты**: ~5 реальных импортов services в models (`custom_rule.dart`→uri_utils `newUuidV4`; `emit_context.dart`→`RuleSetRegistry`; `server_list.dart`→`body_decoder`/`parse_all`; `node_spec_emit.dart`→parser/transport). NB: `home_state.dart`→`clash_api_client` — **dead import** (verifier нашёл, не используется). `node_spec_emit.dart` — намеренный «emit layer» (gray area, не баг).
- **Circular `services → controllers`**: `auto_updater.dart`→`subscription_controller`; debug-слой держит ссылки на оба контроллера (`debug_registry` singleton). Debug — намеренно (диагностика), задокументировать.
- **Screens минуют контроллеры**: 14+ экранов прямо импортят `SettingsStorage`/`BoxVpnClient`/`ClashApiClient`. (Verifier: полный provider/getIt-рефактор — **flawed**, оверкилл для проекта.)
- **Widgets→screens**: `wifi_manual_add_dialog`→`custom_rule_edit/validators`; `core_logs_hint_banner`→`app_settings_screen`. Мелкая связанность.

### home_screen God-object (2639)
- 4 кластера: rendering (~880-2623), config-introspection business logic (1915-2064: `_viewOutboundJson`/`_copyNodeJson`/`_countNodesInConfig`/`_findNodeByDisplayTag`), view-state (64-104: 14 filter полей + `_filtersByChannel` + sort-cache), lifecycle (56-166).
- Verifier поправил аналитика: filter-полей **14** (не 45); извлекаемо ~600-800 строк (не 1439).

### Контроллеры
- HomeController — 6 независимых осей: VPN lifecycle / Clash API / ping (10-concurrent worker, 228 LOC) / heartbeat (88 LOC) / traffic / haptic. 27 public + 50+ private. Всё через единый `_emit(copyWith)` (17 параметров).
- Shared-state hazard: ping-ось читает `_state.selectedGroup` (Clash-ось) — extraction требует осторожности.
- SubscriptionController **не** имеет этой проблемы — образец.

### State management
- `HomeState` смешивает: runtime (tunnel/proxiesJson/lastError) + UI-prefs (sortMode/pinDirect/pinAuto) + derived caches (`configCache`, `sortedNodes` memoized).
- Sort-опции — в `HomeState`; фильтры — в `_HomeScreenState`. Одна природа (UI-state), два дома. Нет принципа размещения.
- Singletons непоследовательны: `HapticService.I`/`AppLog.I`/`TrafficProfiler.I` (static `.I`) vs `ThemeNotifier()` (local instance) vs injected контроллеры.

### Tag-prefix domain (доказанный класс багов §077/§079/§080)
- Паттерн `prefix.isEmpty ? n.tag : '$prefix ${n.tag}'` — в 3+ местах идентично + 8 `prefix.isEmpty` хитов. `_withPrefix` (forward, builder), `subscriptionsOfTag` (reverse + collision heuristic), `isDetourDisplayTag` (consts), `_findNodeByDisplayTag` (strip), `allocateTag` (collision-suffix).
- **Все три бага — один корень**: нет единого владельца «display-tag». Каждый фикс локален в своём файле. Verifier: **TagResolver закрыл бы §077/§079/§080 структурно** (sound).

### Persistence §076
- Lazy-машинерия (`initState`/`dispose`/`didChangeAppLifecycleState`/`_markDirty`/`_persist`/`_pendingChanges`) **byte-for-byte идентична** в 4 экранах (dns/routing/tun/settings). Drift только в `_persist` теле (screen-specific saves) + `settings_screen` использует `_pendingVars` Map вместо bool.
- Zero reuse: нет mixin/base. Grep `*lazy*`/`*persist*` в screens/ — пусто.

### Абстракции/швы
- **ConfigIntrospection MISSING**: 15 `['outbounds'] as List` traversal-сайтов; detour-chain **дублируется 3×** (stats:109-118 vs home:1947-1955 vs builder). `ConfigCache` (home_state:43-82) — уже частичный prototype.
- **Leaky**: `proxiesJson: Map<String,dynamic>` протянут через screens/controllers; нет typed Clash-API модели; нет config-schema типов.

---

## Roadmap (приоритет = verified impact / risk)

### 🟢 Делаю сейчас (HIGH/sound, low-risk, доказанный payoff)

**R1 — `TagResolver`** (закрывает класс багов §077/§079/§080). Pure stateless модуль `lib/services/tag_resolver.dart`: forward `bare→display`, reverse `display→bare + subscriptions`, `isDetourMarker`, collision-suffix awareness. Рефактор call-sites (`_withPrefix`, `subscriptionsOfTag`, `isDetourDisplayTag`, `_findNodeByDisplayTag`). Co-located unit tests. **Структурно невозможен новый §077-класс баг.**

**R2 — `ConfigIntrospection`** service (read-only над configRaw). Унифицирует detour-chain (3 дубля), node-queries, protocol skip-list (2 дубля), outbound JSON для view/copy. Расширяет/поглощает `ConfigCache`. Выносит `_viewOutboundJson`/`_copyNodeJson`/`_countNodesInConfig` из home_screen → тестируемо.

### 🟡 После (HIGH/sound, moderate-risk — с adversarial review)

**R3 — `NodeFilterViewModel`** (ChangeNotifier). 14 filter-полей + `_filtersByChannel` + capture/restore + debounce timers из home_screen → отдельный ViewModel со своим `dispose`. ⚠ setState coupling — осторожно, review перед коммитом.

**R4 — `LazyPersistMixin`**. Общая §076 lazy-машинерия (pendingChanges + flush-on-dispose/paused + configDirty sync) в mixin. `_persist` тело остаётся screen-specific.

### 🔵 Backlog (medium, по случаю)
- Разбить HomeController (PingController/TrafficController) — shared-state hazard, осторожно.
- State placement principle (Runtime/Preference/Cache) + документация в ARCHITECTURE.md.
- Убрать dead import `home_state.dart`→clash_api_client.
- Унифицировать singleton pattern (ThemeNotifier → `.I`).
- Вынести `custom_rule_edit/validators` из screens (widget→screen coupling).
- typed Clash-API / config-schema модели.

### ⛔ Отвергнуто verifier'ом (НЕ делать)
- **provider/getIt для всех screen→service** (LOW/flawed) — оверкилл, текущий прямой доступ приемлем для масштаба.
- **Filter state → HomeState как FilterPreferences** (LOW/flawed) — фильтры per-session, не preference; смешает с runtime.
- **PingController как полностью независимый** (MEDIUM/flawed) — shared `selectedGroup`/`pingOptions`, extraction сложнее чем кажется.
- **«facade layer» для всех контроллеров** (partial) — оправдан только для SubscriptionController (18 импортов); HomeController (7) — нет.

## Принципы (зафиксировать)

1. **Pure domain logic → service/helper, не в widget/State.** Тестируемость = критерий.
2. **«Display-tag» — доменный концепт с одним владельцем** (TagResolver).
3. **Config JSON traversal — через один service** (ConfigIntrospection), не ad-hoc jsonDecode.
4. **Дублирование машинерии → mixin/base** (LazyPersist).
5. **Не плодить слои ради чистоты** — facade/DI только где реальный payoff (verifier-reality-check).

## Файлы

- `docs/spec/tasks/085-architecture-roadmap.md` (этот файл).
- Источник: workflow `architecture-analysis` (run `wf_7c42cec8-d18`), 28 агентов.
- Реализация R1–R4 — отдельные коммиты, отмечаются здесь по ходу.

## Прогресс

- [x] **R1 — TagResolver** ✅ `lib/services/tag_resolver.dart` (pure static:
      `displayTag`/`isDetourMarker`/`stripPrefix`/`matchesAllocated`).
      Рефактор 6 call-sites: `server_list_build._withPrefix` (удалён),
      `subscription_lookup` (collision inline → helper), home_screen
      ×2 detour-hide + `_findNodeByDisplayTag`, node_filter_screen,
      node_settings + subscription_detail picker. `isDetourDisplayTag`
      удалён из consts. +30 unit tests (`tag_resolver_test.dart`,
      поглотил consts_test). Класс багов §077/§079/§080 структурно закрыт.
- [x] **R2 — ConfigIntrospection** ✅ `lib/services/config_introspection.dart`
      (on-demand query value-object: `outboundByTag`/`kindOf`/`detourOf`/
      `detourChain`/`outboundChain`/`nodeCount`, cycle-safe). Заменил дубли:
      home `_countNodesInConfig` (удалён) + `_viewOutboundJson` +
      `_copyNodeJson`; stats `_parseDetourMap`+`_detourChain` (детур-chain
      был продублирован 3×). `ConfigCache` (hot-path render) оставлен —
      разные цели, задокументировано. +9 unit tests.
- [ ] R3 — NodeFilterViewModel — ⚠ **отложен**: самый рискованный (большой
      diff в home_screen 2639, setState coupling, `home_screen` не покрыт
      widget-тестами → регрессию render'а юнит-тесты не поймают). Делать
      когда юзер за рулём для device-verify фильтров. Не делал слепо ночью.
- [x] **R4 — LazyPersistMixin** ✅ `lib/screens/lazy_persist_mixin.dart`
      (`markDirty`/`persistChanges`/flush-on-dispose+paused/configDirty sync).
      Применён к 3 экранам с идентичным bool-скелетом: tun_apps_tab,
      dns_settings_screen, routing_screen (byte-for-byte дубль lifecycle
      убран). `settings_screen` (Map `_pendingVars`, иная семантика) —
      оставлен с пометкой (адаптация под bool-mixin рискованна ради 1
      экрана). +4 widget-tests (lazy-persist раньше **не** покрыт).
