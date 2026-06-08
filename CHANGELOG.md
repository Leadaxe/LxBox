# Changelog

Все заметные изменения в проекте L×Box документируются здесь.

Формат основан на [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added

- **§083 — Per-channel match-filter memory (in-session)** ([task spec](docs/spec/tasks/083-per-channel-filter-memory.md), [channel_filters.dart](app/lib/screens/home/channel_filters.dart), [home_screen.dart](app/lib/screens/home_screen.dart)). Match-фильтры (regex / протоколы / подписки / ping) теперь запоминаются **отдельно для каждого канала** (selector group). Переключил канал → его набор фильтров восстанавливается; вернулся обратно → снова виден. Раньше фильтры были одни глобальные на все каналы. Реализация: `Map<channel → ChannelFilters>` snapshot в памяти, save/restore в `_onControllerChange` при смене `selectedGroup` (покрывает все пути — dropdown, connect-time resolve, applyGroup). `show-detour` / `show-dimmed` остаются глобальными (они про отображение, не про поиск). Без записи на диск (per-session, по запросу юзера). Pending debounce отменяется при смене канала (старый ввод не протекает). +12 unit tests на `ChannelFilters`.

### Changed

- **§085 R3 — `NodeFilterViewModel` (разбор God-object home_screen)** ([roadmap](docs/spec/tasks/085-architecture-roadmap.md), [node_filter_view_model.dart](app/lib/screens/home/node_filter_view_model.dart)). Весь node-filter state (regex / протоколы / подписки / ping + show-detour / show-non-matching + §083 per-channel память + debounce-таймеры) — 17 полей + 11 методов — вынесен из `_HomeScreenState` в отдельный `ChangeNotifier`. **home_screen похудел 2639 → 2370 строк** (−269). Бонус: хелперы `_buildNodeFilter` + `_splitNodes` убрали дублированную NodeFilter-конструкцию (был §078). +17 unit-tests (filter-логика раньше не была покрыта вообще). Adversarial review по 3 осям (behavioral equivalence / listener wiring / split helpers) — 0 findings. Поведение без изменений.

- **§085 R4 — `LazyPersistMixin` (общая §076 lazy write-on-exit машинерия)** ([roadmap](docs/spec/tasks/085-architecture-roadmap.md), [lazy_persist_mixin.dart](app/lib/screens/lazy_persist_mixin.dart)). Из arch-анализа: lazy-persist скелет (`_pendingChanges` + flush-on-dispose/paused + `configDirty` sync) был byte-for-byte продублирован в 4 экранах. Вынесен в mixin (`markDirty`/`persistChanges`). Применён к `tun_apps_tab`, `dns_settings_screen`, `routing_screen`. `settings_screen` (Map-семантика) оставлен с пометкой. +4 widget-tests (lazy-persist раньше не покрыт). Поведение без изменений.

- **§085 R2 — `ConfigIntrospection` (единый config-traversal service)** ([roadmap](docs/spec/tasks/085-architecture-roadmap.md), [config_introspection.dart](app/lib/services/config_introspection.dart)). Из arch-анализа: detour-chain traversal был продублирован 3× (home/stats/builder) + 15 ad-hoc `jsonDecode(configRaw)` сайтов. Создан on-demand query value-object (`outboundByTag`/`detourOf`/`detourChain`/`outboundChain`/`nodeCount`, cycle-safe). Заменены дубли в `home_screen` (count + view-JSON + copy-JSON) и `stats_screen` (detour-map + chain). `ConfigCache` (render hot-path) оставлен отдельно — иная цель. +9 unit tests. Поведение без изменений.

- **§085 R1 — `TagResolver` (единый владелец display-tag logic)** ([roadmap](docs/spec/tasks/085-architecture-roadmap.md), [tag_resolver.dart](app/lib/services/tag_resolver.dart)). Из 28-агентного архитектурного анализа: логика «display-tag ↔ bare-tag» (subscription prefix, detour-маркер `⚙`, collision-suffix) была размазана по 6+ местам, что породило класс багов §077/§079/§080. Вынесена в pure-static `TagResolver` (`displayTag`/`isDetourMarker`/`stripPrefix`/`matchesAllocated`). Рефакторены все call-sites: `server_list_build._withPrefix` (удалён), `subscription_lookup`, home_screen detour-hide + `_findNodeByDisplayTag`, node_filter_screen, detour-picker'ы. Структурно невозможен новый баг этого класса. +30 unit tests. Поведение без изменений.

### Fixed

- **§084 — Code-audit cleanup: High-блок** ([task spec](docs/spec/tasks/084-code-audit-cleanup.md)). Из 46-агентного аудита кода исправлены все 6 high-находок:
  - **H1 / §081** — `validateConfig` теперь проверяет `outbounds[]/endpoints[].detour` ссылки → `DanglingDetourRef` (fatal). Раньше dangling detour (см. §080) не ловился на Dart-уровне. [validator.dart](app/lib/services/builder/validator.dart), +3 теста.
  - **H2** — удалено мёртвое поле `VlessSpec.encryption` (нигде не читалось/эмитилось).
  - **H3** — hysteria2 `up_mbps`/`down_mbps` теперь round-trip'ятся через URI (`toUriHysteria2` писал в JSON, но не в URI; `parseHysteria2` не читал обратно). +2 теста.
  - **H4** — форматтеры bytes/duration/time вынесены в [format_utils.dart](app/lib/services/format_utils.dart) (были продублированы 3× в stats/live/per_app_trace с расходящимся выводом). +15 тестов.
  - **H5** — `traffic_profiler`: `tcpClose` теперь пишется в global rolling buffer **всегда** (симметрично `tcpOpen`); раньше под `if (_globalRecordingActive)` → при active session без global recording connection lifecycle был неполным.
  - **H6** — `TrafficEvent.copyWith` вместо ручного копирования 20+ полей в hot-path `_pollConnections` (убирает риск дрейфа при добавлении поля).
  - **Medium «консистентность»**: M7 — `isValidNaiveHeaderName`/regex → `uri_utils.dart` (был дубль parser↔emit); M9 — profiler Debug API возвращает единый error-envelope через `Conflict`/`NotFound` (было 4× raw `JsonResponse({'error':...})`); M10 — `auto_updater` docstring (5 триггеров, §027); M14 — уточнён §076-комментарий про native VPN toggles; M16 — удалён мёртвый `_legacyEventSummary`. (M13 оказался false-positive — `persistSources` уже ставит `configDirty`.)

- **§080 — Detour-override picker ломал конфиг при непустом `tag_prefix`** ([task spec](docs/spec/tasks/080-detour-override-picker-prefix-aware.md), [subscription_detail_screen.dart](app/lib/screens/subscription_detail_screen.dart), [node_settings_screen.dart](app/lib/screens/node_settings_screen.dart)). Audit §077 (finding #13) обнаружил баг того же класса что §077/§079, но ломающий **сборку конфига целиком**. Detour-override picker'ы сохраняли **bare** `node.tag`, а `server_list_build._withPrefix` эмитит целевой outbound с prefixed-тэгом (`'$tagPrefix $base'`). `overrideDetour` подставляется builder'ом прямо в `main.detour` без prefix-трансформации → при непустом `tag_prefix` detour ссылался на несуществующий outbound (sing-box reject `'unknown outbound'` / VPN не стартует). Фикс: оба picker'a строят и сохраняют display-form. Graceful degradation для старых bare-сохранёнок (dropdown показывает None → юзер перевыбирает). Empty-prefix — regression-free. +3 builder теста (display-form valid / bare dangling / empty-prefix).

- **§079 — Detour-серверы с `tag_prefix` не скрывались** ([task spec](docs/spec/tasks/079-detour-prefix-aware-tag-detection.md), [consts.dart](app/lib/config/consts.dart), [home_screen.dart](app/lib/screens/home_screen.dart), [node_filter_screen.dart](app/lib/screens/node_filter_screen.dart)). Тот же класс что §077: `tag.startsWith(kDetourTagPrefix)` (`'⚙ '`) для детекции detour-серверов фейлит на display-form тэгах подписок с непустым `tag_prefix` (`'🇷🇺 RU ⚙ Hop'` → `⚙` в середине строки). Detour-сервера протекали в основной пул нод (home «Hide detour» не скрывал их; node_filter_screen показывал в auto-proxy exclusion list). Фикс: helper `isDetourDisplayTag(tag)` ловит `⚙` и в начале, и в середине (`startsWith || contains(' ⚙ ')`). +unit tests `consts_test.dart`.

- **§078 — Control outbounds always visible + ping в порядке отображения** ([task spec](docs/spec/tasks/078-control-outbound-and-display-order-ping.md), [home_screen.dart](app/lib/screens/home_screen.dart), [home_controller.dart](app/lib/controllers/home_controller.dart)). Два UX-фикса на главной экране:
  - **Control outbounds (direct-out / ✨auto / любой selector / urltest group) теперь всегда matching** независимо от активного filter. До §078 любой включённый chip-filter (subscription / protocol) dim'ил их вместе с не-matching нодами — юзер терял быстрый switch на direct. Фикс: `_isControlTag(tag, state)` короткозамыкает filter pass через `state.proxiesJson.type ∈ {selector, urltest, direct, block, dns}`. NodeFilter pure helper не знает про control — special-case в caller'е.
  - **'Custom' chip** теперь отображается **только** при наличии реальных UserServer'ов. До §078 control outbounds с `subscriptionsOf() == {}` триггерили chip даже без custom servers (см. §077 audit finding #14).
  - **Ping all** теперь iterates `displayList` (sort + manual + pinned + filter) вместо raw `_state.nodes`. UI button передаёт текущий display-order в `runMassUrltest(order: ...)`. При активном filter + `showNonMatching=false` пинг идёт только по видимым нодам в порядке отображения — юзер видит прогресс сверху вниз. Backward-compat: без `order` параметра — старое поведение.

- **§077 — Node filter: subscription chip не мэтчил подписки с `tagPrefix` + ambiguity-aware lookup** ([task spec](docs/spec/tasks/077-subscription-filter-with-prefix.md), [home_screen.dart](app/lib/screens/home_screen.dart), [node_filter.dart](app/lib/screens/home/node_filter.dart), [subscription_lookup.dart](app/lib/screens/home/subscription_lookup.dart) NEW). На главной в `Icons.tune` panel выбор chip'а подписки с непустым `tag_prefix` приводил к тому что **все** её ноды отмечались как non-matching (dim) — фильтр не находил ни одной. Root cause: `_subscriptionsOfTag` сравнивал bare `n.tag` со state.nodes тэгом, который через `server_list_build.dart::_withPrefix` уже несёт prefix (`'$tagPrefix $base'`). 
  - **Primary fix**: сравнение prefixed-form + best-effort handle collision-suffix (`-1`/`-2`/... от `_BuildCtx.allocateTag`). При пустом prefix поведение без изменений (regression-free).
  - **NodeFilter contract rename** (breaking для прямых consumer'ов helper'а): `subscriptionOf: String? Function(String)` → `subscriptionsOf: Set<String> Function(String)`. Predicate теперь intersection-based (`effective.any(subscriptions.contains)`). При коллизии (две подписки с одинаковым prefix+name → builder addочит `-N`) lookup honestly возвращает **все** entries у которых пара мэтчит — нода видна во всех chip'ах подписок которые могли её создать (ambiguity-aware, без deceptive disambiguation).
  - **Pure helper extracted**: `subscriptionsOfTag(tag, entries)` в `home/subscription_lookup.dart` — 18 unit tests покрывают prefix reconstruction, collision-suffix (digit-only), multi-match, UserServer empty, disabled subs skip. Audit blocker «load-bearing logic completely untested» resolved.

## [1.9.0] — 2026-06-07

### Added

- **§076 — Settings and config lifecycle (write-on-exit + lazy rebuild + universal NavigatorObserver)** ([feature spec](docs/spec/features/076%20settings-and-config-lifecycle/spec.md)). Унификация UI настроек, storage (`lxbox_settings.json`), saved config (`singbox_config.json`) и running tunnel в один прозрачный lifecycle. Два паттерна как design choice:
  - **Lazy (write-on-exit)** для toggle-flood editing screens (`tun_apps_tab`, `routing_screen`, `dns_settings_screen`, `settings_screen` Core VPN tab): mutations только in-memory + sync `_markDirty` (configDirty=true), storage flush на `dispose()` + `AppLifecycleState.paused`, rebuild lazy на возврат к home. **1 settings write + 1 config write per editing session** независимо от количества toggle'ов.
  - **Eager (immediate-write)** для discrete-event screens (`subscriptions_screen`, `app_settings_screen`, `custom_rule_edit_screen`, `node_filter_screen`): immediate save + snackbar feedback. Подходит для add/remove/Save button workflows.
  - **Global `HomeReturnObserver`** ([home_return_observer.dart](app/lib/services/nav/home_return_observer.dart)): универсальный `NavigatorObserver` зарегистрирован в `MaterialApp.navigatorObservers`. Срабатывает на любой `didPop` когда home (root route) становится top. Покрывает все навигационные пути (drawer, long-press, system back, swipe, programmatic pop, cross-navigation между settings screens). Раньше rebuild trigger был в `_pushRoute.then()` callback — терялся при опен через long-press на Nodes header.
  - **`HomeController.markConfigChangedNeedRestart()`** — external mark для настроек применяемых вне config pipeline (native VPN System toggles: `allow_bypass` / `keep_on_exit` / `background_mode`). Gated на `tunnelUp` (если tunnel down — значение применится на следующем start без restart prompt). Home banner показывает «Restart VPN» — единый source-of-truth, локальные snackbar'ы про restart удалены.
  - **mtime-based bootstrap** ([config_dirty_check.dart](app/lib/services/config_dirty_check.dart)): на launch `subController.init` сравнивает `lxbox_settings.json.mtime > singbox_config.json.mtime` → восстанавливает `configDirty` после kill mid-edit. `home_screen._initSubsAndAutoUpdate` триггерит тихий bootstrap rebuild → юзер не видит banner на старте, всё применилось.
  - **Banner gate переписан**: синий «Settings changed» показывается при `configDirty=true` **всегда** (без `tunnelUp` gate). Розовый «Restart VPN» показывается при `tunnelUp && configChangedNeedRestart && !configDirty` — mutually exclusive с синим (два banner'а одновременно не появляются).
  - **Rename**: `HomeState.configStaleSinceStart` → `configChangedNeedRestart` (in 5 files). Debug API `/state` JSON key `config_stale_since_start` → `config_changed_need_restart` — **breaking** для external consumers. Добавлен computed `config_dirty: bool` для диагностики.
  - **Race fixes**: `_markDirty` синхронно set'ит `configDirty=true` (race-safe для observer handler'а который читает сразу после dispose). `_persist` НЕ set'ит `configDirty` после await'ов (исправлен blink pink→blue после rebuild).

- **§074 — Add server wizard (SOCKS5 form + Paste URI + Paste JSON)** ([feature spec](docs/spec/features/074%20add-server-wizard/spec.md), [add_server_wizard_screen.dart](app/lib/screens/add_server_wizard_screen.dart), [subscription_controller.dart](app/lib/controllers/subscription_controller.dart), [subscriptions_screen.dart](app/lib/screens/subscriptions_screen.dart)). Long-press на «+» в Subscriptions screen → full-screen route с 3 tabs:
  - **SOCKS5** — структурированная форма: tag (default `local-socks5-out`), host (`127.0.0.1`), port (`1080`), username/password (optional), display name (optional → `UserServer.name`, отображается как entry title в Subscriptions list). Form validation (port 1..65535, host non-empty). Default values заточены под locally hosted SOCKS5 / DPI bypass tooling. Submit → constructs `SocksSpec(label = tag)` directly, persisted **как sing-box outbound JSON** в `rawBody` (не URI — URI fragment round-trip ломает tag т.к. `parseSocks` derive'ит tag из label-fragment'а), wraps в `UserServer(origin: manual)`, добавляется через новый `subController.addUserServer(...)` helper. Regression test: `socks_wizard_roundtrip_test.dart`.
  - **Paste URI** — multiline text area для `vless://…` / `vmess://…` / `trojan://…` / `socks5://…` / `wireguard://…` etc. Routes через существующий `addFromInput` (тот же путь что у tap-«+»).
  - **Paste JSON** — multiline outbound JSON ({type:vless,…}). Single object или array. WireGuard auto-routes в `endpoints[]` через builder pipeline.
  - Cancel + Add buttons в AppBar (Material standard для full-screen modals).
  - Tab switch сохраняет поля. Snackbar после add показывает tag который юзер ввёл (builder'овская суффиксация при collision видна в node list).
  - Tap на «+» = existing paste-clipboard / parse-text-input flow без изменений. Wizard также доступен через «Add server…» в overflow menu (три точки в AppBar) — explicit affordance для discoverability.

### Changed

- **§073 — Detour: `Override` → `Add detour` с режимом append (default) и checkbox replace** ([task spec](docs/spec/tasks/073-detour-append-vs-replace.md), [server_list.dart](app/lib/models/server_list.dart), [server_list_build.dart](app/lib/services/builder/server_list_build.dart), [subscription_detail_screen.dart](app/lib/screens/subscription_detail_screen.dart)). До §073 mode `Override` в Subscription detail полностью **заменял** нативную detour-цепочку из конфига одним выбранным outbound'ом. Юзер запросил режим **append**: ноды идут по своей родной цепочке, а в конец добавляется выбранный hop (jumphost ladder с дописываемым последним exit).
  - **Renamed**: radio item `Override` → `Add detour`. Subtitle разводит «Append → X» (default) и «Replace chain → X» (toggle ON).
  - **Added**: `SwitchListTile` «Replace existing chain» под outbound picker. OFF (default) = append; ON = старое replace.
  - **Builder**: `ServerListBuild.build` — новая ветка для append: `skipDetour=false`, `main.detour = detours.first.tag`, `detours.last.map['detour'] = overrideDetour` (override спайс'ится хвостом). Пустая native chain → 1-hop как раньше.
  - **Storage**: `DetourPolicy.replaceDetourChain: bool` (default false). JSON key `replace_detour_chain`. Старые backup'ы без ключа → default append. ⚠ **Поведение для existing юзеров с override меняется** — была implicit replace, стала append. Toggle ON чтобы вернуть старое поведение.

### Fixed

- **§075 — Tunnel apps: regenerate config + единый restart flow** ([task spec](docs/spec/tasks/075-tun-apps-restart-regen-config.md), [tun_apps_tab.dart](app/lib/screens/tun_apps_tab.dart)). Incident 2026-06-06: юзер выбрал Mode=Deny-list + добавил Internet (`com.heytap.browser`), tap Restart → Internet всё равно ходил через VPN. Verified via Debug API: storage `{mode:deny, packages:[com.heytap.browser]}` ✅, applied config inbound[tun] — НЕТ `exclude_package` ❌. Root cause: `_persist` обновлял только storage, `_restartVpn` делал `stop()→start()` без regenerate, native читал **last saved config** который не пересобран. Фикс приводит tun_apps_tab к pattern'у `routing_screen._apply`: `_persist` теперь делает `setTunApps → generateConfig → saveParsedConfig`. Локальный «Restart needed» banner + локальный «Restart now» button + `_appliedCfg` snapshot удалены — единый source-of-truth через `configStaleSinceStart` flag и глобальный home banner. То же поведение что у routing changes.

- **§072 — `SettingsStorage` атомарная запись + восстановление из `.bak`** ([task spec](docs/spec/tasks/072-settings-storage-atomic-write.md), [settings_storage.dart](app/lib/services/settings_storage.dart), [settings_storage_test.dart](app/test/services/settings_storage_test.dart)). Раз в пару дней на Xiaomi/HyperOS (воспроизведено на Pad 8 Pro) у юзера **полностью** сбрасывались все настройки — vars, подписки, server lists, custom rules, DNS. Root cause: `_save()` использовал `File.writeAsString` без `flush` (truncate-then-write); kill между truncate и записью → пустой/обрезанный JSON; `_load()` ловил `FormatException` в немом `catch (_) {}` и проваливался в `_cache = {}`; первый же `setVar` после этого фиксировал потерю. Фикс:
  - **Атомарная запись**: `_save()` теперь делает (1) `copy(main → .bak)` если main валиден, (2) `write(.tmp, flush: true)`, (3) `tmp.rename(main)` — POSIX `rename(2)` атомарен в пределах одной FS. Kill между copy и tmp-write оставляет main + старый .bak. Kill между tmp-write и rename — то же.
  - **Decision tree в `_load()`**: main отсутствует → `{}` (fresh install); main парсится → return; main битый + `.bak` валиден → recovery (`AppLog.warning`); main битый + bak нет → return `{}` + sticky-флаг `_mainIsCorrupted` + `AppLog.error` (раз за сессию). Critical: при corruption main файл **не перезаписывается** автоматически — оставляется для ручной диагностики. Sticky-флаг сбрасывается на первой успешной atomic-записи (юзер начал заново вводить данные).
  - **Cleanup**: stale `.tmp` от прошлого crashed save удаляется в начале `_load()`.
  - +12 unit tests (`settings_storage_test.dart`): round-trip, recovery из .bak, drop без bak, empty file truncate, .tmp cleanup, migrate proxy_sources, .bak только из валидного main, fresh после drop.

### Added

- **§070 — Sort options long-press menu** ([feature spec](docs/spec/features/070%20sort-options/spec.md), [home_state.dart](app/lib/models/home_state.dart), [home_controller.dart](app/lib/controllers/home_controller.dart), [home_screen.dart](app/lib/screens/home_screen.dart)). На главной у sort-кнопки в node header добавлен long-press → popup `CheckedPopupMenuItem`×3:
  - **Pin DIRECT to top** (default ON) — `direct-out` в pinned section.
  - **Pin AUTO to top** (default ON) — `✨auto` в pinned section.
  - **Re-sort on manual ping** (default ON) — пересчитывать порядок при `runNodeUrltest(tag)` (single ping). OFF → manual ping обновляет число, но **ряд не прыгает**; UI-cache (`_viewSortedNodes`) держит frozen sort до `state.pingBatchGen` bump.
  - `pingBatchGen` — passive counter, bump'ается в `runMassUrltest` финале, `runGroupUrltest`, `setSelectedGroup`, `saveParsedConfig` — четыре «легитимных re-sort» точки. Single manual ping → cache hit → frozen order.
  - **Yellow dot indicator** на sort-кнопке когда хоть одна опция non-default.
  - Toggles per-session in-memory (consistency с §048 filter state), не persist'ятся.
  - Default behaviour bit-exact: все 3 toggle = ON → старый sort.

- **§071 — Manual node reorder via drag** ([feature spec](docs/spec/features/071%20manual-node-reorder/spec.md), [home_state.dart](app/lib/models/home_state.dart), [home_controller.dart](app/lib/controllers/home_controller.dart), [home_screen.dart](app/lib/screens/home_screen.dart)). Четвёртый sort mode `NodeSortMode.manual` (icon `⠿ Icons.drag_indicator`), активируется **только** через drag — в `cycleSortMode` не входит (`NodeSortMode.next` обходит manual: default → ping → A-Z → default).
  - **8% от ширины row, transparent strip** на левом крае каждого non-pinned ряда (Stack + Positioned overlay) с `ReorderableDragStartListener` — long-press + drag начинает reorder. Текст и иконки внутри `NodeRow` не сдвигаются.
  - Drag → `commitManualReorder` переключает sortMode в `manual` + сохраняет порядок в `state.manualOrder`. Per-session in-memory.
  - **Exit:** короткий tap по sort-кнопке (cycle) выходит из `manual` → `defaultOrder`, `manualOrder` **сбрасывается**. Юзер опять начал drag → manual mode re-enter с fresh порядком.
  - **Pinned (direct/auto)** — non-draggable; drop в pinned зону clamped под pinned (`onReorder` guard).
  - **Новые ноды** (subscription update / add server) → в конец manual order. Удалённые → автоматически отфильтрованы.
  - +18 unit tests (`home_state_sort_test.dart`): `next` cycle exit, pin toggles в `latencyAsc`/`nameAsc`, manual order applied, новые в конец, удалённые отфильтрованы, pinDirect ON/OFF под manual, copyWith new fields.

- **§048 — Home node filters: regex + emoji + protocol + subscription + test (ping)** ([feature spec](docs/spec/features/048%20home-node-filters/spec.md), [node_filter.dart](app/lib/screens/home/node_filter.dart), [filter_widgets.dart](app/lib/screens/home/filter_widgets.dart), [home_screen.dart](app/lib/screens/home_screen.dart)). На главной у списка нод есть icon-кнопка `Icons.tune` справа в header (раньше открывала popup с одним пунктом «Show detour servers» — теперь expand toggle для filter panel). Panel содержит:
  - **Regex** text field с двумя toggle: левый checkbox — on/off filter без потери pattern (auto-on при вводе валидного pattern); `[!]` внутри suffix перед `✕` — invert/NOT (`!regex.hasMatch(tag)`, OR-семантика alternations сохраняется — `!(a|b)`). Debounce 300ms; invalid pattern → red `Invalid regex` hint.
  - **Emoji chips** в горизонтальной полоске — extracted из всех node tags (включая detour), отсортированы по частоте + alphabetical tiebreak. Tap chip → emoji appended в regex field как OR-pattern (`🇷🇺` потом `🇺🇸` → `🇷🇺|🇺🇸`).
  - **Protocol chips** (multi-select FilterChip, horizontal scroll row) — unique protocols из current pool (vless / vmess / trojan / shadowsocks / hysteria2 / ...). Empty selection = all allowed.
  - **Subscription chips** (multi-select, horizontal scroll) — display names enabled подписок с непустым `nodes` (`SubscriptionServers.nodes.isNotEmpty`) + special «Custom» если есть `UserServer`'ы.
  - **Test ≤ N ms** numeric input с собственным checkbox — debounced 300ms; untested nodes (`delay==null`) всегда matching (locked decision #11). Checkbox позволяет временно выключить filter не теряя значение.
  - **Show detour servers** checkbox — existing toggle переехал из popup в panel.
  - **Show non-matching (dimmed)** checkbox (default ON) — non-matching ноды рендерятся внизу с opacity 0.4 вместо скрытия. Юзер видит весь pool, понимает что подходит под фильтр. OFF → классический filter behaviour.
  - **Двухфазная модель**: detour show/hide — pool filter (caller), regex / protocol / subscription / test — match filter (`NodeFilter.passes`). NodeFilter не знает про detour — clean separation.
  - All filters AND-комбинируются. Per-session in-memory state (как `_showDetourNodes`).
  - Visual hint: `Icons.tune` color = primary когда есть active match-filter, даже когда panel collapsed.
  - +27 unit tests на `NodeFilter` (extractEmojis с RIS flags, regex case-insensitive, regex invert ON/OFF, protocol exclusive, untested ping pass, AND combine, detour не в predicate).

- **§068 — `NodeViewItem` view-model class extracted** ([spec](docs/spec/tasks/068-node-view-item-extract.md), [node_view_item.dart](app/lib/widgets/node_view_item.dart), [node_row.dart](app/lib/widgets/node_row.dart)). `NodeRow` widget раньше принимал 14+ explicit args через конструктор — partial view-model в форме arguments-bag. Extract сделан **внутри** PR §048 (closes §068) потому что добавление `matches: bool` для filter feature раздуло itemBuilder и стало естественно отделить «собрали snapshot строки» от «нарисовали». `NodeRow(item: NodeViewItem, ...callbacks)` — single source data shape. `Opacity(opacity: item.matches ? 1.0 : 0.4)` wrapper внутри `NodeRow.build` — single source of opacity, magic 0.4 не утекает в caller.

- **OEM battery restrictions follow-up dialog** ([home_screen.dart](app/lib/screens/home_screen.dart)). После того как юзер тапнул «Allow» в нашем rationale и затем «Разрешить» в системном `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` dialog'е → app в AOSP whitelist, но **OEM (ColorOS/MIUI/MagicOS на OnePlus/OPPO/Realme/Xiaomi/Honor) имеют proprietary battery toggles поверх AOSP**, которые наш intent НЕ контролирует. Показывается follow-up dialog «Disable battery restrictions» с инструкцией («Battery usage → Don't optimize» + «On OnePlus/OPPO/Realme: Stop activity when idle → OFF») и deep-link на App Info через `ACTION_APPLICATION_DETAILS_SETTINGS`. Cooldown 24h на rationale убран — спрашиваем при каждом запуске пока permission не дан.
- **«Restore from backup» link в empty state главного экрана** ([home_screen.dart::_buildAddServerCta](app/lib/screens/home_screen.dart)). Если у юзера нет server_lists/custom_rules (после fresh install) — под FAB «Add a server» появляется ненавязчивая кнопка «🔄 Restore from backup». Тап → SAF native file picker (`Intent.ACTION_OPEN_DOCUMENT` через `file_picker` plugin) — юзер выбирает `lxbox-backup-*.json`. После `applyImport` сразу триггерится `_subController.init()` + `AutoUpdater.maybeUpdateAll(manual, force: true)` — подписки fetch'аются в фоне без необходимости restart app'а. Snackbar «Imported: ... · fetching subscriptions…».

### Removed

- **Legacy `SelectableRule` режим без `preset_id`** ([§067 spec](docs/spec/tasks/067-selectable-rule-legacy-cleanup.md)). До §033 (v1.4.x) `SelectableRule` мог быть в шаблоне без `preset_id` — конвертировался в `CustomRule(kind: inline/srs)` копированием полей. С §033 (v1.5+) все рулы в `wizard_template.json` имеют `preset_id`, конвертер `selectableRuleToCustom` для empty presetId возвращал null silently — dead code.
  - `SelectableRule.presetId` теперь `required` (default `''` удалён).
  - `SelectableRule.fromJson` бросает `FormatException` если в шаблоне отсутствует `preset_id`.
  - `selectableRuleToCustom` возвращает `CustomRulePreset` (non-nullable, был `?`).
  - Убраны 2 null-check'а в `routing_screen.dart` (`_migrateLegacyRules` + `_copyPreset`).
  - Docstring `parser_config.dart::SelectableRule` упрощён — упоминания «Legacy (1.4.x)» режима убраны.
  - Test «без preset_id → null» переписан в «`fromJson` без preset_id → FormatException».

---

## [1.8.3] — 2026-05-12

«Pre-commit hook auto-sync» release. Завершает рефакторинг версионирования начатый в v1.8.2: теперь pubspec обновляется автоматом при каждом `git commit`, никаких manual шагов.

### Changed

- **Pre-commit hook автоматически синхронизирует `app/pubspec.yaml` с git state** ([§066 spec](docs/spec/tasks/066-pubspec-sync-hook.md), [.githooks/pre-commit](.githooks/pre-commit), [scripts/sync-pubspec-version.sh](scripts/sync-pubspec-version.sh)).
  - `versionName` = `${last_tag#v}` (clean release) или `${last_tag#v}-dev.${commits_since}` (между тегами).
  - `versionCode` = `git rev-list --count HEAD + 1` (monotonic).
  - Setup: один раз после clone `./scripts/setup-hooks.sh` → `git config core.hooksPath .githooks`.
  - На tag push CI override'ит pubspec из tag'а (hook не triggers на `git tag`) — production APK получает чистую `X.Y.Z`.
- **UpdateChecker skip для `-dev` версий** ([update_checker.dart](app/lib/services/update_checker.dart)). `_isDevBuild(version)` → если version содержит `-dev` или начинается с `0.0.0` → `hydrate()` и `maybeCheck()` exit early. Никаких snackbar'ов «X.Y.Z available» в dev сессиях. `forceCheck()` (manual «Check now») не skip — юзер явно нажал.
- **`scripts/build-local-apk.sh` упрощён** — убраны `--dart-define BUILD_LOCAL / BUILD_GIT_DESC / BUILD_LAST_TAG / BUILD_COMMITS_SINCE_TAG / BUILD_TIME`. Pubspec.yaml — единственный источник, читается через `PackageInfo.fromPlatform()`.
- **`about_screen.dart` упрощён** — удалены 5 `String.fromEnvironment('BUILD_*')` const'ов и `_LocalBuildBadge` widget. Остаётся только `v${VersionInfo.I.version}` (уже включает `-dev.N` если dev build).

### Removed

- `--dart-define BUILD_*` pass-through между local build script ↔ Dart code.
- `_LocalBuildBadge` widget в About screen.
- pubspec.yaml comment block про «placeholder» — теперь pubspec не placeholder, hook поддерживает живую версию.

---

## [1.8.2] — 2026-05-12

«Version from tag — single source of truth» release. Финальный fix дублирования версии (v1.8.0 hotfix → v1.8.1 guard → v1.8.2 elimination). Tag теперь единственный источник правды, никаких bump-коммитов в репо при release-flow.

### Changed

- **Версия — derived from git tag, не hardcoded в коде** ([§065 spec](docs/spec/tasks/065-version-from-tag.md), [version_info.dart](app/lib/services/version_info.dart), [.github/workflows/ci.yml](.github/workflows/ci.yml), [scripts/build-local-apk.sh](scripts/build-local-apk.sh)).
  - `app/pubspec.yaml` навсегда удерживается на placeholder `version: 0.0.0-dev+0`. CI и local build script переписывают line перед `flutter build`, не commit'ят в репо.
  - `versionName` = `${tag#v}` (например `v1.8.2 → 1.8.2`).
  - `versionCode` = `git rev-list --count HEAD` (monotonic).
  - About screen + UpdateChecker используют `VersionInfo.I.version` (load из `PackageInfo.fromPlatform()` в `main()` перед `runApp`). Sync-доступ, single source.
  - **Удалена** `static const _version` в `about_screen.dart` + `AboutScreen.versionString` alias. Удалён CI «Version consistency check» step (нечего сверять — один источник).
  - **Release commit message теперь `docs(release): vX.Y.Z notes`**, без `bump to X.Y.Z+N`. Bump-коммиты больше не нужны.
  - [`docs/RELEASE_PROCESS.md`](docs/RELEASE_PROCESS.md) §2.2 переписан под новый flow.

### Fixed

- **Local dev: `flutter run` показывал старую версию** — теперь `0.0.0-dev` (placeholder) или `X.Y.Z-dev.N` если запущен через `scripts/build-local-apk.sh` (derive'ит из `git describe`).

---

## [1.8.1] — 2026-05-12

Hotfix для v1.8.0: hardcoded UI-версия не была поднята при release-bump'е.

### Fixed

- **About screen и UpdateChecker показывали `v1.7.0` на v1.8.0 build** ([about_screen.dart:13](app/lib/screens/about_screen.dart:13)). При bump'е v1.8.0 поднял `pubspec.yaml` version и весь release-docs набор, но забыл `static const _version = '1.7.0'` в About screen — она читается `UpdateChecker.checkForUpdate()` через `AboutScreen.versionString` и показывается в Settings → About. Эффект: app собран как 1.8.0 (Android `versionName=1.8.0`), но в UI «v1.7.0» + snackbar «v1.8.0 available» сразу после установки.
- Backup-файлы записывают `source_app_version` через `PackageInfo.fromPlatform()` (= pubspec) — там было корректно 1.8.0; UI был единственным affected surface.

### Added

- **CI version consistency check** ([.github/workflows/ci.yml](.github/workflows/ci.yml) → `checks` job, новый step «Version consistency check»). Сверяет `pubspec.yaml` `version:`, `about_screen.dart` `_version`, и git tag (на release run). Mismatch → CI fail до сборки APK, release-tag не уйдёт с расхождением.
- **Release process docs обновлены** ([docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md) §2.2). Теперь явно перечислены **два** места куда записывается версия + why необходимы оба, со ссылкой на CI guard.

---

## [1.8.0] — 2026-05-11

«Backup overhaul + routing order fix» release. Главное — **§063/§040 backup format переписан** под полный snapshot (старый формат терял `custom_rules`, `tun_apps`, `enabled_groups` и т.д.); **§062 — fix custom_rules cross-kind order** (storage order теперь end-to-end управляемый между preset/inline/srs); **§053 — `custom_rule_edit_screen.dart` split** Stage 1+2+3 (2060 → 456 LOC, −77%); plus tooltip on Allow VPN bypass и View tab preview fix для disabled-правил.

**Breaking:** backup-файлы старого формата (`{vars, server_lists}` на корне, `version: 1`) reject'ятся при import. Пере-export после обновления.

### Fixed

- **Custom rule editor — View tab показывал пустой preview для disabled правил** ([view_tab.dart](app/lib/screens/custom_rule_edit/tabs/view_tab.dart), [post_steps.dart](app/lib/services/builder/post_steps.dart)). Юзер открывал editor disabled-правила, переходил на View → видел `{rule_set: [], rules: []}` потому что `applyCustomRules` фильтровал по `cr.enabled`. Семантика «что родит в реальном конфиге» уместна для production pipeline, **но не для editor preview** — юзер открыл editor именно для inspect'а формы. Фикс: добавлен parameter `skipDisabled` на `applyCustomRules` (default `true` для backward-compat; production pipeline `applyAllCustomRules` поведение не меняется). `ViewTab` зовёт с `skipDisabled: false` — preview показывает «что родит при включении» независимо от Switch.

- **§062 — custom_rules order был broken между kind-ами (preset/inline/srs)** ([§062 spec](docs/spec/tasks/062-custom-rules-unified-order.md)). `SettingsStorage.custom_rules` это **один список** с mixed `kind`, и UI/Debug API (`POST /rules/reorder`) предполагали что storage order = order matching в sing-box `route.rules[]`. Builder ломал это: вызывал `applyPresetBundles` (только preset) → `applyCustomRules` (только inline/srs) последовательно, поэтому в финальном config все preset правила оказывались **перед** всеми inline/srs независимо от storage order. Юзер ставил `RU apps inline` между `Private IPs preset` и `Russian domains preset`, но в sing-box config inline всегда уезжал в самый конец. Reorder API «провёртывался вхолостую».
  - **Фикс** — новый `applyAllCustomRules` обходит rules в одном цикле с dispatch по kind. Per-rule logic вынесена в private `_applyPresetSingle` / `_applyInlineSingle` / `_applySrsSingle`. Старые public `applyPresetBundles` / `applyCustomRules` остались как **shim** через те же private — backward-compat для тестов.
  - **Cross-preset rule_set dedup** переехал с `mergeFragments` на `RuleSetRegistry.tryRegisterRuleSet` (identical-skip / first-wins warning) — работает естественно при per-rule обходе.
  - **Verified on device**: storage `[Block Ads, Private IPs, RU apps inline, Russian domains preset, ...]` теперь даёт config `[ads-all, ip_is_private, RU apps, ru-domains, ...]` — порядок 1-к-1 (за вычетом 3 system rules `resolve`/`sniff`/`dns hijack` в голове).
  - Tests: 614 → 620, +6 в `test/services/builder/apply_all_custom_rules_test.dart` покрывают cross-kind order, mixed kinds, identical-skip + cross-kind, DNS aspect.

### Added

- **Info tooltip на `Allow VPN bypass` toggle** ([settings_screen.dart](app/lib/screens/settings_screen.dart)). Tap-trigger `Tooltip` с `info_outline` icon рядом с заголовком — объясняет: что делает (`ConnectivityManager.bindProcessToNetwork()` bypass), когда полезно (банкинг, captive portal, системные сервисы), что значит off (strict tunnel), что применяется на next VPN connect. Тот же паттерн что в DNS settings (`triggerMode: tap`, 12-сек показ).

### Refactor

- **§053 Stage 2 + Stage 3 — sections + tabs + state controller выделены из `custom_rule_edit_screen.dart`** ([§053 spec](docs/spec/tasks/053-custom-rule-editor-split.md)).
  - **Stage 2 (v14090)** — 7 секций + 2 shared widgets вынесены в `screens/custom_rule_edit/sections/` и `widgets/`. Sections — dumb `StatelessWidget` с props (controllers + callbacks); `ItemsField` — единственный `StatefulWidget` (подписан на controller через `addListener` для self-rebuild). Editor: 1795 → 1330 LOC.
  - **Stage 3 (v14100)** — выделен **`CustomRuleEditController extends ChangeNotifier`** ([edit_controller.dart](app/lib/screens/custom_rule_edit/edit_controller.dart)): владеет всеми 8 `TextEditingController`-ами, флагами (`enabled`, `kind`, `outbound`, `ipIsPrivate`), коллекциями (`protocols`, `packages`, `wifiNetworks`, `varsValues`), async state (`srsState`, `boolVarDownloading`, `presetSrsPaths`) + mutator'ами + `snapshot()` / `isDirty()` + pure async (`downloadSrs` / `clearSrsCache` / `onBoolVarToggle`). Раздаётся вниз через `CustomRuleEditScope` (plain `InheritedNotifier` — без новых deps). Tabs — отдельные widgets: `tabs/params_tab.dart` (inline/srs ветка), `tabs/preset_params_tab.dart` (preset §033 + bool-toggle §045 download), `tabs/view_tab.dart` (storage shape + sing-box preview, наследует `presetSrsPaths` из controller). Editor scaffold: 1330 → 456 LOC (−65%; от исходных 2060 — −77%). Save-icon выделен в `_SaveIconButton` через `AnimatedBuilder` чтобы dirty-rebuild не дёргал весь AppBar.
  - `widgets/wifi_entry.dart`, `widgets/wifi_saved_picker_sheet.dart`, `widgets/wifi_manual_add_dialog.dart` — extracted в Stage 1 (v14080); `screens/custom_rule_edit/wifi_zip.dart` — Stage 3 (top-level zip/unzip helpers вместо file-private). На screen State остались только UI-actions требующие BuildContext: save/back/delete dialog'и, cloud-menu, picker-вызовы, snackbar'ы. Save flow unchanged — `snapshot().withName(finalName)` тот же. **Тесты: 620 pass; analyzer clean.**

### Changed

- **Backup format переписан под полный snapshot — single-format, no legacy support** ([§040 spec](docs/spec/features/040%20backup%20restore%20ui/spec.md), [backup_service.dart](app/lib/services/backup_service.dart), [debug/handlers/backup.dart](app/lib/services/debug/handlers/backup.dart), [settings_storage.dart](app/lib/services/settings_storage.dart)). Старый формат `{vars, server_lists}` на корне **не сохранял большую часть пользовательских данных** — `custom_rules`, `tun_apps`, `enabled_groups`, `enabled_rules`, `route_final`, `rule_outbounds`, `dns_options` живут как top-level ключи `lxbox_settings.json`, а export'ил только `data['vars']`. Inline rule_set'ы вида «Ru Apps» (57 пакетов через `CustomRule.inline`) **исчезали при restore**.
  - Новый wire-format: `{app, kind, created_at, source_app_version, storage: <lxbox_settings.json целиком>, vpn_settings: {auto_start, keep_on_exit, background_mode, core_logs_enabled, allow_bypass}}`. `version` поле убрано — single-format, файлы старого образца reject'ятся с message «Unsupported backup format. Re-export from a recent app version.»
  - **`storage` блок** = deep-clone всего `lxbox_settings.json` через новый `SettingsStorage.exportRaw()`. Restore — через `SettingsStorage.replaceRaw(map, merge: bool)`: при `merge=false` overwrite целиком, при `merge=true` top-level merge с recursive vars upsert.
  - **`vpn_settings` блок** — отдельный native-side state из `boxvpn_boot` SharedPreferences (BootReceiver читает at boot-time когда Flutter ещё не запущен; не перенесён в `lxbox_settings.json` ради simplicity). 5 toggles read через `BoxVpnClient` getters / write через сеттеры.
  - **Категории UI — 5** (было 4): Server lists, Routing, App settings, **VPN system toggles** (новая), Debug API. Filter работает на уровне keys в `storage` map (а не split на vars-сегменты). Добавление новой top-level настройки в storage → автоматически в backup, без правок allowlist'ов.
  - Debug API `/backup/export|import` синхронизирован с UI — symmetric round-trip.
  - **Тест round-trip** ([backup_service_test.dart](app/test/services/backup_service_test.dart), 13 cases): export (все категории) → wipe → import → diff(restored, original) == 0; selective categories, merge vs replace, legacy reject.

### Docs

- **§054 — spec reorg: features vs tasks classification audit** ([§054 spec](docs/spec/tasks/054-spec-reorg-features-vs-tasks.md)). `docs/spec/features/` теперь содержит **только живые** продуктовые / архитектурные концепции. Семь демотированных в `docs/spec/tasks/`: ~~001~~ mobile stack → [`055`](docs/spec/tasks/055-mobile-stack-decision/spec.md) (historical architectural decision), ~~002~~ MVP scope → [`056`](docs/spec/tasks/056-mvp-scope-historical/spec.md) (historical milestone), ~~004x~~ subscription parser → [`057`](docs/spec/tasks/057-subscription-parser-v1-superseded/spec.md) (superseded by §026), ~~005x~~ config generator → [`058`](docs/spec/tasks/058-config-generator-wizard-v1-superseded/spec.md) (superseded by §026), ~~013~~ routing → [`059`](docs/spec/tasks/059-routing-v1-superseded/spec.md) (superseded by §030), ~~039~~ libbox 1.13 migration → [`060`](docs/spec/tasks/060-libbox-1-13-migration/spec.md) (one-shot, Done), ~~041~~ DNS rules refactor → [`061`](docs/spec/tasks/061-dns-rules-refactor/spec.md) (live spec — §014). Освобождённые номера (001/002/004/005/013/039/041) **не переиспользуются**. Все cross-refs обновлены в `docs/**/*.md`, `CHANGELOG.md`, `app/lib/**/*.dart`, `app/test/**/*.dart`; grep на retired numbers — 0 hits; `flutter analyze` — 0 errors.

- **`docs/ARCHITECTURE.md` Feature Specs map синхронизирован с реоргом** + **`CHANGELOG.md` chronological order** ([commit `24558a5`](https://github.com/Leadaxe/LxBox/commit/24558a5)). В ARCHITECTURE убраны 7 демотированных из live-таблицы, добавлена явная "Демотированные через §054" секция с маппингом старый→новый. В CHANGELOG: блок `[1.2.0]` ошибочно стоял между `[1.4.0]` и `[1.3.1]` — переставлен в правильный newest-first порядок.

- **§047 — Public Intent API spec расширен** ([§047 spec](docs/spec/features/047%20public%20intent%20api/spec.md)). Outgoing events (broadcast intents от LxBox в эфир: `VPN_STATE_CHANGED`, `CONFIG_RELOAD`, `RULE_FIRED` опционально) + 2 incoming actions (`SET_RULE_ENABLED`, `SWITCH_PRESET_GROUP`) + symmetric input/output pattern. Status остаётся **Draft** — не имплементировано.

---

## [1.7.3] — 2026-05-10

«UX rework + perf» release. Главное — **§052 VPN Settings reorganisation** (System/Core tabs), **§051 Phase 2-3 wifi rules editor + auto-record history**, **F22 part 2 logging pipeline production-grade**, **CoreLogsHintBanner** общий widget с deep-link на Diagnostics, и Live tab tap-to-filter через row identifiers.

### Changed

- **§052 — VPN Settings reorganisation: System / Core tabs + reshuffle** ([§052 spec](docs/spec/tasks/052-vpn-settings-system-service-tabs.md)). Drawer → VPN Settings теперь 2 tab'а с чёткой семантикой:
  - **System** — Android-side VPN controls через `VpnService.Builder` API. Сейчас: `Allow VPN bypass` (§049 F15), `Keep VPN on exit`, `Tunnel sleep mode` (`BackgroundMode.never|lazy|always`).
  - **Core** — sing-box engine vars (`chapter: 'core'` в template — `mtu` / `log_level` / `dns_final` / …). Routing- и DNS-специфичные vars (chapter: routing/dns) живут на своих экранах.
  - **App Settings → Background tab удалён** (TabBar 3→2: General + Diagnostics). `Keep on exit` + `Tunnel sleep mode` переехали в VPN Settings → System; permissions block (Battery / Notifications / Location / NearbyWifi / App info) — в App Settings → Diagnostics в interactive виде (как был в Background, целиком копируется блок).
  - **Tunnel apps mode + packages — остаётся в Routing → Tunnel apps** (4-я вкладка). Не переезжает: юзеру привычно искать «куда роутится app» в Routing.
  - Bonus fix: `DebugScreen → ⋮ → Diagnostics settings` использовал `AppSettingsScreen(initialTab: 2)`. После удаления Background tab indices сместились (Diagnostics: 2→1), `clamp(0, 1)` молча клипало 2 → 1, но семантика была сломана. Поправлен `2 → 1`.
- **Deep-links between dependent tabs and settings**. Tab'ы которые depend на глобальном toggle (core_logs_enabled / VPN settings) теперь умеют open соответствующий screen с правильно открытым tab'ом. Общий `initialTab: int` parameter pattern на `AppSettingsScreen` / `SettingsScreen` (`DefaultTabController.initialIndex` + clamp). Реализация:
  - **Statistics → Live + Per-app → contextual `CoreLogsHintBanner`** ([core_logs_hint_banner.dart](app/lib/widgets/core_logs_hint_banner.dart), [live_events_tab.dart](app/lib/screens/live_events_tab.dart), [per_app_trace_tab.dart](app/lib/screens/per_app_trace_tab.dart)). Inline banner widget показывается **только когда `core_logs_enabled=false`**; self-hides при включении (auto-refresh на `AppLifecycleState.resumed`). Split hit-zone: левая (i + «DNS / router events off») → tooltip с объяснением что без core logs DNS resolves пропадают и process attribution ухудшается; правая («turn on Forward sing-box logs» + chevron) → deep-link в App Settings → Diagnostics с auto-scroll и подсветкой нужного toggle'а. Это лучше чем PopupMenu (⋮) overflow item: явно виден когда нужен и pulls user's attention.
  - **Routing → Tunnel apps → ⋮ → "VPN settings (Core)"** ([tun_apps_tab.dart](app/lib/screens/tun_apps_tab.dart)) → `SettingsScreen(initialTab: 1)`. Юзер настраивает Tunnel apps mode и хочет рядом mtu / log_level / dns_final — overflow deep-link уместен (state-independent, не «toggle off-warning»).
  - **Drawer → Debug → ⋮ → "Diagnostics settings"** ([debug_screen.dart](app/lib/screens/debug_screen.dart)) → `AppSettingsScreen(initialTab: 1)` — fast-path на «Forward sing-box logs» toggle + Quit&reopen.

### Added

- **Debug API — `/settings/vpn/*` endpoints** для §052 System toggles ([settings.dart](app/lib/services/debug/handlers/settings.dart), [debug-api-reference.md](docs/api/debug-api-reference.md)). Закрывают gap «UI есть, API нет». Все три — GET / PUT, `body {"enabled": bool}` или `{"mode": "never|lazy|always"}`:
  - `GET|PUT /settings/vpn/allow_bypass` — `VpnService.Builder.allowBypass()`. Apply at next `establish()` (start или reload VPN).
  - `GET|PUT /settings/vpn/keep_on_exit` — keep VPN running когда app закрывается. Live-effect не нужен.
  - `GET|PUT /settings/vpn/background_mode` — foreground-service tunnel sleep mode. Apply at next VPN connect.
  - `GET /state/vpn` расширен — теперь включает `allow_bypass` + `background_mode` (одним запросом snapshot всех VPN-system флагов).
- **§051 Phase 2 — Wi-Fi rule editor UI** ([§051 spec](docs/spec/tasks/051-custom-rule-wifi-conditions.md), [custom_rule_edit_screen.dart](app/lib/screens/custom_rule_edit_screen.dart)). Editor `CustomRule` теперь содержит секцию **WI-FI NETWORK** между Protocol и Save:
  - Chip list `_wifiNetworks: List<_WifiEntry>` — каждая chip = одна сеть `(ssid, bssid?)`. Дедуп при add (composite key).
  - **Add current** — читает текущий SSID/BSSID через `MainActivity.getCurrentWifiInfo` MethodChannel (defensive try/catch SecurityException + RuntimeException; placeholder BSSID `02:00:00:00:00:00` ловится как `unknown_ssid`). Permission missing → shared `WifiPermissionDialog`. `no_wifi` / `unknown_ssid` → snackbar.
  - **Pick saved** — bottom sheet с двумя секциями:
    - **USED IN YOUR RULES** — networks из других custom_rules с указанием rule names.
    - **HISTORY (last seen)** — `wifi_history` storage entries с relative time. Per-row 🗙 button (right-aligned, explicit hit-area) удаляет одну запись.
  - **Manual** — dialog с SSID + BSSID inputs (BSSID regex `xx:xx:xx:xx:xx:xx` inline-validated).
  - **Save flow** — preflight permission check если есть wifi conditions (`BACKGROUND_LOCATION + NEARBY_WIFI_DEVICES`). При missing → shared `WifiPermissionDialog`, save проходит в любом случае (юзер мог нажать «Allow Wi-Fi info» runtime prompt).
  - **Zip/unzip semantics**: `_zipWifiEntries(chips) → (ssids, bssids)` для модели. Sing-box AND-ит списки независимо (cross-product). `_unzipWifiEntries` обратно при load (best-effort pairing by index).
- **§051 Phase 3 — Auto-record visited Wi-Fi networks** ([§051 spec Phase 3](docs/spec/tasks/051-custom-rule-wifi-conditions.md), [WifiNetworkObserver.kt](app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/WifiNetworkObserver.kt), [wifi_history_listener.dart](app/lib/services/wifi_history_listener.dart)). Opt-in toggle в `Settings → Diagnostics` (default OFF — silent network logging это privacy след). При ON `WifiNetworkObserver` регистрирует `ConnectivityManager.NetworkCallback(TRANSPORT_WIFI)`. Pending tracker записывает в `wifi_history` сети **на которых юзер пробыл ≥ 5 минут** (`STICKINESS_THRESHOLD_MS=300_000`) — отсекает drive-by кафе/магазины. Native → Dart bridge через `MethodChannel "com.leadaxe.lxbox/wifi_history"` event `onWifiSeen`. Pick saved bottom sheet показывает persistent info-banner «Auto-record is off — Open Settings» когда toggle OFF (visible сверху всегда). Existing history НЕ удаляется при OFF (user data). Cap 50, LRU evict по `last_seen`. Phase 4 (`WifiStateCache` для hot-path `readWIFIState`) — deferred до bench `dumpsys binder_calls_stats`, не оптимизируем вслепую.
- **Debug API — `/wifi_history/*` endpoints** ([wifi_history.dart](app/lib/services/debug/handlers/wifi_history.dart)) для CRUD над `wifi_history` без UI flow:
  - `GET /wifi_history` → list `[{ssid, bssid, last_seen}]`.
  - `POST /wifi_history` body `{"ssid":"...","bssid":"..."}` → upsert (BSSID auto lower-cased).
  - `DELETE /wifi_history` body `{"ssid":"...","bssid":"..."}` → remove specific entry (composite key match; idempotent).
  - `DELETE /wifi_history/all` → clear all.
  Same write-path что и UI (`SettingsStorage.addToWifiHistory` / `removeFromWifiHistory` / `clearWifiHistory`).

### Fixed

- **§051 Phase 2 — `wifi_history` not refreshing in Pick saved after row delete** ([settings_storage.dart](app/lib/services/settings_storage.dart)). `getWifiHistory` возвращал `toList(growable: false)`; `removeWhere` в setState callback'е молча кидал `UnsupportedError` на fixed-length list → UI rebuild не триггерился. Storage write проходил (entry удалена), но visible row оставалась до reopen sheet. Fix: `toList()` (growable).

### Refactor

- **§053 Stage 1 — extract pure functions + dialogs из `custom_rule_edit_screen.dart`** ([§053 spec](docs/spec/tasks/053-custom-rule-editor-split.md)). Editor разбух до 2060 LOC после §051. Stage 1 — низкорисковая extract'ция без architecture change:
  - **Pure functions**: `lib/screens/custom_rule_edit/validators.dart` (isValidDomain / isValidKeyword / isValidCidr / isValidPort / isValidPortRange / isValidUrl / isValidBssid) + `lib/screens/custom_rule_edit/normalizers.dart` (splitRaw / normalizedDomains / normalizedKeywords / normalizedCidrs / normalizedPorts / normalizedPortRanges). Были private методы на State — не тестируемы.
  - **Public `WifiEntry` model** ([wifi_entry.dart](app/lib/widgets/wifi_entry.dart)) — был private `_WifiEntry`.
  - **`showWifiSavedPickerSheet`** ([wifi_saved_picker_sheet.dart](app/lib/widgets/wifi_saved_picker_sheet.dart)) — self-contained: грузит other-rules + history + auto-record flag, показывает modal, возвращает `Future<List<WifiEntry>?>`. ~300 LOC inline `showModalBottomSheet` build'а уехали из editor.
  - **`showWifiManualAddDialog`** ([wifi_manual_add_dialog.dart](app/lib/widgets/wifi_manual_add_dialog.dart)) — same idea для Manual dialog.
  - **Editor**: 2060 → 1795 LOC (−265). Stage 2 (section widgets) + Stage 3 (state controller + tab split) — отдельные итерации.
  - **Tests**: +53 unit tests (validators + normalizers); 548 → 601 pass.
- **§051 closeout — consolidate wifi-read + permission-check** (`commit 20a4a51`). Three call-sites одной и той же defensive read logic (`PlatformInterfaceWrapper.readWIFIState` + `MainActivity.getCurrentWifiInfoMap` + `WifiNetworkObserver.readWifi`) consolidated в `WifiInfoReader` singleton с sealed `Result` type. Four copies permission-check (`if (SDK_INT >= X) checkSelfPermission(...) == GRANTED`) → `PermissionUtils.has(ctx, name, minSdk)` one-liner. Bonus: `_humanLastSeen` proper fallbacks, `WifiHistoryListener` `dispose()` lifecycle, `SettingsStorage` header convention note про growable lists.

### Performance

- **F22 part 2 — sing-box log forwarding pipeline production-grade** ([BoxService.kt](app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt), [app_log.dart](app/lib/services/app_log.dart), [clash_log_pump.dart](app/lib/services/clash_log_pump.dart)). К drainer-pattern из v1.7.1 добавили back-pressure / yield / batching / O(1) deque / 60Hz throttle. На heavy traffic (100+ строк/сек) toggle «Forward sing-box logs» теперь почти free.
  - `@Synchronized` снят с `writeDebugMessage` — `LinkedBlockingQueue.offer` thread-safe, mutex только сериализовал producer-thread'ы Go runtime'а.
  - **Back-pressure cap** `LOG_QUEUE_MAX = 4096`: при slow Dart consumer'е drop newest вместо unbounded growth (counter `coreLogDrops`).
  - **Drainer yield** — до `DRAIN_BATCH_MAX = 200` строк за один main-looper run, потом re-post если queue не пуст. Длинный burst не блочит main looper > frame'а.
  - **EventChannel batching** — один `sink.success(List<String>)` за drain вместо per-line JNI marshal. На 200 строк/burst — 1 marshall вместо 200.
  - **AppLog ring buffer** — `List.insert(0)` (O(n)) → `ListQueue.addFirst` (O(1)). `logBatch()` — N entries за один проход + один `_scheduleNotify`.
  - **Notify throttle** 16ms (60Hz max) leading-edge — UI не ребилдится с frequency write'ов на busy traffic.

### UX (Statistics — Live tab tap-to-filter)

- **Tap по event row → in-place filter** ([live_events_tab.dart](app/lib/screens/live_events_tab.dart)). Раньше long-press открывал bottom sheet «Open in Per-app session» — юзер не хотел переключения на отдельный tab. Теперь:
  - Каждое поле строки кликабельное независимо: domain, IP:port, process. Tap → существующий search field заполняется выбранным значением, в-place фильтр.
  - Comma-list процессов разбит на индивидуальные tappable элементы (для multi-process events).
  - Повторный tap по тому же ключу — clear (escape hatch без отдельной кнопки).
- **Removed dead code**: `_handleJumpFromLiveTab` + `StatsScreen.requestPerAppSession` static helper удалены после снятия bottom sheet.

### UX (overflow menus cleanup)

- **Live tab + Per-app trace — 3-dot `Diagnostics settings` overflow удалена**. `CoreLogsHintBanner` (см. Changed выше) покрывает use-case с лучшей discoverability — visible когда нужен, без скрытия за overflow.
- **Tunnel apps — overflow link исправлен на System tab** ([tun_apps_tab.dart](app/lib/screens/tun_apps_tab.dart)). Раньше `VPN settings (Core)` вёл на `SettingsScreen(initialTab: 1)`. Per-app split-tunneling — это System-level фича (`VpnService.Builder` toggles), не Core (sing-box engine vars). Renamed to `VPN settings (System)`, ведёт на `initialTab: 0`.

---

## [1.7.2] — 2026-05-10

«§050 wifi-state closeout + Live tab fix» release. Главное — **закрыта §050**: F12.3 `readWIFIState` теперь полноценно работает, найден и исправлен real root cause `Unknown reference: 42` crash'а (unhandled `SecurityException` через JNI), плюс добавлены недостающие permissions для Android 13+ и runtime UX. Параллельно — фикс Live tab system-wide stats (раньше показывал 0 events) и UI toggle для §037 config lock.

### Fixed

- **§050 — F12.3 `readWIFIState` real root cause + final fix** ([§050 spec](docs/spec/tasks/050-libbox-debug-build/spec.md), [findings.md](docs/spec/tasks/050-libbox-debug-build/findings.md)). После 9 неудачных attempt'ов в §049 (различные констукторы / pinning / R8-keep-rules — все `Unknown reference: 42` cold-start) истинная причина оказалась проще, чем `Seq` ref-tracker race: **unhandled `SecurityException` propagating через JNI**.
  - Sing-box (Go) → cgo → `cproxy_PlatformInterface_ReadWIFIState` → Java callback `readWIFIState()` → `WifiManager.connectionInfo` → **`SecurityException`** при отсутствии location permission на API 29+ → exception проходит через JNI границу без handler в cproxy code → `Seq$RefTracker.incRefnum` пытается cleanup → **JNI env corrupted** → `ClassLinker::FindClass` fails → `Runtime::Abort` с misleading `"Unknown reference: 42"` (refnum 42 = follow-up effect, не cause).
  - **Defensive try/catch** `SecurityException + RuntimeException → return null` в `PlatformInterfaceWrapper.readWIFIState`. Sing-box graceful'но получает null (как было раньше когда метод всегда возвращал null) — как минимум не падает.
  - **Permission gate** в `BoxService.startSingbox` после `startOrReloadService` (port из reference SagerNet): `cs.needWIFIState() && !permission` → `stopAndAlert("alert:permission_location:...")`. Sing-box не запускается без permission'а если config реально использует `wifi_ssid`/`wifi_bssid` правила — Flutter показывает actionable alert вместо silent crash'а.
- **§050 — `<unknown ssid>` на Android 13+ (targetSdk≥33)**. Даже после grant'а `ACCESS_FINE_LOCATION` / `ACCESS_BACKGROUND_LOCATION`, `WifiInfo.ssid` возвращал `"<unknown ssid>"` → wifi rules не матчились. Google в API 33 отделил Wi-Fi info от location: для apps с `targetSdk≥33` нужен **отдельный `NEARBY_WIFI_DEVICES`** permission ([Android docs](https://developer.android.com/develop/connectivity/wifi/wifi-permissions)).
  - Manifest: `<uses-permission NEARBY_WIFI_DEVICES neverForLocation>` (declared as not-for-location → Google Play политика).
  - `BoxService.startSingbox`: на API 33+ проверяются обе permission (`ACCESS_BACKGROUND_LOCATION` + `NEARBY_WIFI_DEVICES`); alert содержит comma-list missing permissions для UI.
  - Verified on OnePlus / Android 15 / API 36: после grant'а wifi rule с `wifi_ssid:["lexRouter"], outbound: direct-out` корректно матчится — chrome → api.ipify.org идёт через direct, минуя VPN.

### Added

- **§050 — permission UX flows** ([home_screen.dart](app/lib/screens/home_screen.dart), [url_launcher.dart](app/lib/services/url_launcher.dart), [MainActivity.kt](app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt)).
  - **Notification permission explainer** при cold start: показывает explainer dialog ДО system POST_NOTIFICATIONS prompt'а — юзер понимает зачем VPN'у нужны notifications (foreground service / status indicator).
  - **Wi-Fi permissions dialog** при запуске VPN с wifi rules: parsит comma-list missing permissions, показывает кнопку `Allow Wi-Fi info` (runtime prompt для NEARBY_WIFI_DEVICES — one tap) и `Open Settings` (для BACKGROUND_LOCATION который нельзя выдать через runtime prompt; идёт через `MANAGE_APP_PERMISSIONS` intent с тремя fallback стратегиями для разных OEM).
  - **Battery optimization — one-tap prompt**: primary action поменян с `ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS` (список всех apps) на `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (системный диалог конкретно про L×Box). Список apps остаётся как fallback для OEM (ColorOS / MIUI / HyperOS) где direct-prompt молча отбрасывается.
- **§048 — Live tab system-wide events fix**. Раньше при тапе START в Live tab без per-app session показывалось 0 events — `_pollConnections()` имел early-return `if (_active == null) return`, и system-wide recording получал только DNS строки из core logs (TCP/UDP open/close — никогда). Теперь global recording тоже запускает `_startConnectionPoll()`, события через `_emitGlobalStream`. Closed connections тоже эмитятся в global buffer когда recording on. Idle profiler по-прежнему ничего не делает.
- **§037 — config_locked toggle в Diagnostics tab** ([app_settings_screen.dart](app/lib/screens/app_settings_screen.dart)). UI-эквивалент `PUT /settings/config_locked` Debug API endpoint'а: юзер может pin'нуть текущий sing-box config (например, после debug-API edit'а с экспериментальной фичей) от перезаписи UI-rebuild'ом, и снять lock сам. Auto-unlocks при отключении Debug API (иначе lock остаётся unactionable — toggle спрятан под Debug API блоком).

### Deferred

- **F22 part 2** — back-pressure cap (`LOG_QUEUE_MAX = 4096`) + drainer yield каждые 200 iterations + EventChannel batching (один `sink.success(list)` на batch вместо per-line) + AppLog ring buffer на deque вместо `List.insert(0)` + notifyListeners throttle до 60Hz. Текущий drainer pattern достаточен для production load, но на heavy debug-mode traffic возможно OOM risk при slow Dart consumer'е. Не release-blocker.

---

## [1.7.1] — 2026-05-09

«Stabilization» release. Главное — **§049 sing-box wrapper deep audit + atomic CAS lifecycle fix**: устранена main suspect race condition по `fileDescriptor`, обнаруженная при диагностике §047 (TCP-deterioration после ~8 часов uptime). Параллельно — **§048 inclusive observer** для Per-app trace и **§046 tunnel apps split-tunneling**.

### Fixed

- **§049 sing-box wrapper deep audit + atomic CAS lifecycle fix** ([§049 spec](docs/spec/tasks/049-singbox-wrapper-deep-audit/spec.md), диагностика [§047](docs/spec/tasks/047-tun-tcp-deterioration-diagnosis.md)). Многочасовой side-by-side diff нашего Kotlin wrapper'а vs reference SagerNet/sing-box-for-android (correct commit `3b3883e` для libbox 1.13.11) → 25 findings, 9 применены как fix'ы. Главный — race condition в lifecycle `fileDescriptor`: `@Volatile` гарантирует publish, но не атомарность compound «read-then-close-then-null», и mutations из 5 call-site'ов (`openTun` / `cleanupStaleResources` / `onRevoke` / `doStop` / scope.cancel) могли привести к double-close → kernel переиспользует fd-int → sing-box пишет в чужой fd → silent ENXIO → TCP-traffic via tun перестаёт работать через 15-30 минут после старта.
  - **F2** Replaced `@Volatile var fileDescriptor` → `AtomicReference<ParcelFileDescriptor?>`. Helper `closeFileDescriptor()` использует `getAndSet(null)?.close()` — единственный поток получает non-null PFD, остальные no-op. Same для `commandServer`.
  - **F3** Удалён `cleanupStaleResources()` — superfluous 5-й mutation site, аналога в reference нет. AtomicReference helper'ы защищают от double-close без pre-cleanup'а. Также убрана `delay(500)` (была компенсацией для удалённого cleanup'а).
  - **F5** `onRevoke` cleanup переведён на atomic helpers (раньше мутировал поля inline на binder thread, race с `openTun` на libbox thread).
  - **F4** `serviceReload` без status-flap (Started→Starting→Started → без промежуточного broadcast'а), reference так и делает.
  - **F26** LocalResolver полностью переписан на `DnsResolver.getInstance().query(defaultNetwork, ...)` (port 1:1 из reference). Старый `InetAddress.getAllByName()` шёл через system resolver, который при `tun.auto_route=true` мог рекурсивно пройти ЧЕРЕЗ tun. Now bound к underlying network, мимо tun.
  - **F9** `Libbox.setLocale(Locale.getDefault())` в init — sing-box error messages теперь локализованы.
  - **F12.1** `userName` поле в `findConnectionOwner` — Clash API `/connections` теперь видит package name юзера.
  - **F17** `getSystemProxyStatus()` возвращает реальный state (раньше всегда empty `SystemProxyStatus()`) — Clash dashboard'ы видят корректные available/enabled флаги.
  - **F1 split** — `BoxVpnService` оставлен только как Android `VpnService + PlatformInterfaceWrapper` (PI), весь state и `CommandServerHandler` impl переехал в новый класс `BoxService` (plain Kotlin). `CommandServer(this, platformInterface)` создаётся теперь с **двумя разными Java instance** (port 1:1 из reference). Раньше `CommandServer(this, this)` шёл с одним объектом (CSH+PI шарили refnum=42 с refcnt=2), что увеличивало вероятность gomobile refcount race.
  - **Phase H — `BoxApplication` как зарегистрированный Android Application class** (`android:name=".vpn.BoxApplication"` в манифесте). Был `object BoxApplication` инициализирующийся лениво — теперь Android создаёт Application **до** Service/Activity, гарантируя что `Libbox.setup` отрабатывает до первого `CommandServer` ctor. Backward-compat callsite'ы `BoxApplication.X` работают через companion proxy на `instance`.
  - **Phase H — match reference deltas в init**: `Seq.setContext(this)` закомментирован (как в reference `Application.kt:41` — native libbox init сам устанавливает контекст; явный вызов делал двойной-set ломая `Seq$RefTracker`); `SetupOptions.logMaxLines = 3000` (без лимита sing-box копит логи unbounded).

#### Deferred / not applied

- **F12.3** `readWIFIState()` остаётся `null` (deferred). 9 attempts на нашем environment'е (Android 15 OnePlus + libbox 1.13.11 stripped) — constructor `WIFIState(s,b)`, factory `Libbox.newWIFIState`, cached singleton, Java strong-ref pin, drop `Seq.setContext`, drop `setMemoryLimit`, R8 keep rules, Phase H baseline — **все** падают `'Unknown reference: 42'` cold-start через 1-12 секунд. Java instrumentation patched `Seq$RefTracker` показал: refcnt не падает до 0 — Java side OK. Crash в native `libbox.so` cproxy который имеет собственный jobject hashmap отдельно от Java RefMap. Reference SagerNet с identical Java code на той же libbox 1.13.11 stable у людей. Без debug symbols (требует rebuild через `gomobile bind -ldflags="-w=false -s=false"` из sing-box source) диагностировать дальше нельзя — задача §050 на отдельную session. Practical impact: `wifi_ssid:` / `wifi_bssid:` правила в sing-box не работают (у нас в wizard их нет, юзеры не используют).
- **F22 coalesced log dispatch** — пробовали bounded queue + single-pending drainer вместо per-line `coreLogMainHandler.post`. Build 10104 (Lambda inline) работал; build 10106/10107 (тот же код по сути) — крашит refnum 42. Race-condition в interaction между Kotlin Lambda capture и gomobile/seq tracker. Не стабильно для prod — оставлен per-line dispatch.

### Added

- **§049 F15 — Allow VPN bypass toggle** (App Settings → «Allow VPN bypass»). Default off (strict tunnel — наш default behavior). Включает `Builder.allowBypass()` для VPN — apps могут explicit'но через `ConnectivityManager.bindProcessToNetwork(network)` обойти tun. Применяется при следующем `openTun()` (старт VPN или reload). Reference (`Settings.allowBypass`) имеет identical toggle.
- **Per-app trace — inclusive observer with confidence** ([§048 spec](docs/spec/tasks/048-perapp-trace-attribution-gaps.md)). Закрывает 13 attribution gap'ов в Per-app traffic profiler, выявленных в live-диагностической сессии 2026-05-09. Концепт: `TrafficProfiler` теперь не drop'ает события — каждое попадает в session с одним из 4 уровней `ConfidenceLevel` (`verified` / `secondary` / `inferred` / `unattributed`). Юзер видит **всё что произошло**, и видит **что точно его app, а что возможно**.
  - **Defensive DNS regex** — `_dnsRe` / `_dnsFailRe` принимают любой record type (HTTPS / SVCB / SOA / MX / TXT / unknown), любой формат timing'а (5ms / 10.0s), с/без trailing dot. Раньше `HTTPS` queries Chrome'а (HTTP/3 alt-svc discovery) silently дропались.
  - **Secondary packages** — `Session.secondaryPackages: Set<String>` configurable per session. Решает Tinkoff-WebView сценарий: target=`ru.tinkoff.investing` + secondary={`com.google.android.webview`} → WebView traffic попадает в session с `confidence=secondary`. UI: `Edit secondary` button под header'ом, multi-select picker.
  - **Multiple matching strategies** — direct package match → secondary packages → UID-stripped variants → recent DNS IP inference (10s window). Multi-package UID `com.google.android.gms, com.google.android.gsf` теперь split-and-contains, не equals.
  - **Pre-session backfill** — `_globalRollingBuffer` 60s × 3000 events always-running. На `start()` события за last 60s резолвятся через session matching и backfill'ятся в `session.events` с marker `〽 backfilled from pre-recording`. Решает «юзер ставит recording после того как заметил проблему — теряет первые 60s».
  - **Live system-wide tab** — 4-й tab в Statistics («Overview · Connections · Per-app · Live»). Discovery без выбора target: видно всё что происходит на устройстве в real-time. Filter chips (kind / unattributed-only / app multi-select / search by domain/IP/process), pause/resume, long-press → «Open in Per-app session for <pkg>» quick-discovery flow.
  - **Per-app Live sub-tab** — additional «System-wide events (no owner detected)» section внизу + красный banner «N unattributed events / 30s» когда detected attribution gaps (>5 за 30s).
  - **Time-based correlation cleanup** — `_connIdToMeta` / `_dnsByConnId` GC через `Timer.periodic(5s)` с TTL=30s, не count-based threshold (256). Закрывает conn-id reuse race window.
  - **Streaming primary, polling supplement** — polling interval 2s → 5s. Каждый `inbound packet connection` log line == event сразу; polling только enrich'ит open conn'ы (bytes / state) и эмитит close events.
  - **Debug API расширен**: `GET /profiler/live?seconds=60` (snapshot global rolling buffer), `GET /profiler/live/stream` (SSE без session filter'а), `GET /profiler/live/unattributed` (recent unattributed + banner state), `PATCH /profiler/secondary-packages` (live mutation), `POST /profiler/start { secondary_packages }` (initial set).
  - **API contract**: TrafficEvent JSON теперь включает `confidence`, `matched_via`, `shown_because`, `dns_record_type`, `backfilled` поля.
- **Tunnel apps — OS-level split-tunneling** ([§046 spec](docs/spec/features/046%20tunnel%20apps%20split-tunneling/spec.md)). Четвёртая вкладка в `Routing` для управления стандартным Android-механизмом split-tunneling: какие apps идут через VPN-tun, а какие — direct по cellular/wifi (минуя sing-box полностью).
  - **3 mode'а через SegmentedButton**: `Off` (все apps через tun, default) / `Allow-list` (только перечисленные через tun) / `Deny-list` (все КРОМЕ перечисленных). Mutually exclusive, как требует Android `VpnService.Builder` API.
  - **Storage** `tun_apps: {mode, packages}` в `lxbox_settings.json`. Default для existing юзеров: `{mode: "off", packages: []}` — backward-compat. Migration unconditional one-shot на первом load.
  - **Builder** `applyTunPackages()` в `post_steps.dart` (последний step pipeline'а): `mode: allow` → `inbound[tun].include_package`, `mode: deny` → `exclude_package`, `mode: off` → ничего не пишем.
  - **Native слой не трогали** — `BoxVpnService.kt:557-560` уже умеет читать `options.includePackage`/`excludePackage` от libbox и звать `VpnService.Builder.addAllowedApplication`/`addDisallowedApplication`. applies на `builder.establish()`.
  - **Restart banner** показывается при modified state + tunnel up (`addAllowedApplication` applies только при создании tun fd; light reload не помогает — нужен full VPN stop+start). Кнопка `[Restart now]` делает stop+start.
  - **Конфликт-tooltip ⓘ** на header'е tab'а: apps в Allow-list идут через tun → routing rules применяются нормально; apps вне Allow-list (или внутри Deny-list) bypass'ят VPN entirely → sing-box их не видит, custom rules с `package_name` не сматчатся.
  - **AppPicker reuse** — тот же multi-select picker что в §030/§044. Show-system-apps по default OFF.
  - **Uninstalled apps** помечаются greyed-icon + label `(uninstalled — auto-skipped)` (native ловит `NameNotFoundException`).
  - **Debug API** `GET /settings/tun_apps` / `PUT /settings/tun_apps` ({mode, packages}, replace целиком, package-name validation regex, dedup idempotent). Response `rebuild_needed: true` как hint клиенту.

### Tests

- `app/test/builder/tun_packages_test.dart` — 9 случаев `applyTunPackages` (off / off+pkgs / allow+empty / allow+pkgs / deny+pkgs / no tun / no inbounds / multiple tuns / TunAppsConfig predicates).
- `app/test/services/traffic_profiler_test.dart` — 16 новых тестов §048: defensive DNS regex (HTTPS / SVCB / SOA / `10.0s` time format / fail без owner), multi-package UID matching, WebView secondary, UID-suffix matching, non-target drop, secondary mutation, pre-session backfill, confidence in JSON, global snapshot, banner threshold, time-based GC.
- §049 — local APK build success, `flutter analyze` clean, **535 / 535 flutter tests pass**. On-device retest §047 race — pending (требует ~30+ min прогона на устройстве).

---

## [1.7.0] — 2026-05-08

«Observability» release. Главное — **Per-app traffic profiler** (§044): inline-инструмент диагностики «куда конкретное приложение ходит и как роутится» прямо в Stats. Дополнено расширением `ru-direct` preset'а 4-слойной защитой (TLD + service-CDN suffix-list + GeoIP-ranges) — §045.

### Added

- **Per-app traffic profiler** ([§044 spec](docs/spec/features/044%20per-app%20traffic%20profiler/spec.md), [user guide](docs/features/per-app-trace.md)). Третий tab в Statistics: pick app → record → see DNS resolves (с CNAME chain'ом), connections (хост, IP, порт, outbound chain, bytes) и connection-issue markers ⚠ (DNS timeout, TCP RST early — locale-агностичные).
  - 4 sub-tab'а: **Live** (newest-first stream), **Domains** (aggregated, expandable с CNAME/IPs/outbound/issues), **IPs** (per-IP stats, ↗ jump к Domains), **Connections** (timeline с inline-expand).
  - In-memory only — никакого persist'а. 3h sliding window + 50k events count fallback. Ring-buffer 5 завершённых sessions.
  - **Recording indicator** ⚡: chip в `_buildTrafficBar` на HomeScreen с short package name, плюс ⚡ возле «Per-app» tab title в StatsScreen. Tap всей строки на Home → `StatsScreen(initialTab: perApp)`.
  - **Overflow menu** (⋮) Per-app tab'а: verbose toggle (debug-level core logs), copy/share session JSON, clear all, help.
  - **Debug API** (`/profiler/start`, `/profiler/stop`, `/profiler/active`, `/profiler/sessions`, `/profiler/session/<id>`, `/profiler/stream` SSE) для CLI-driven trace-flow'ов и автоматизации.
  - Connection-issue detection: 2 locale-агностичных типа — `dnsTimeout` (прямой engine-сигнал из `dns: exchange failed` лога) + `tcpReset` (heuristic «TCP закрылся <1с с 0 bytes»).
  - Process inference fallback: если sing-box не нашёл `package_name` для conn'а (webview, system process), атрибутируем по prior DNS resolved IP (10s window), помечаем 〽.
- **`docs/features/per-app-trace.md`** — полный user guide для Per-app traffic profiler: TL;DR, UI tour, 5 use cases (Tinkoff §045 / privacy audit / slow-app debug / preset catalog / dogfooding), Debug API curl-рецепты, edge cases, limits.
- **`docs/DIAGNOSTICS.md`** + **`scripts/lxbox-diag.sh`** — playbook диагностики на устройстве и one-command snapshot всего runtime-state'а (Debug API + Clash API + adb-state) в `/tmp/lxbox-debug-<datetime>/` за 2-3 секунды. Для post-mortem'ов и pre-destructive-op baseline'ов.
- **`docs/TEMPLATE.md`** — полная схема `wizard_template.json` (catalog of presets/vars/sections) + vars-substitution syntax.

### Changed

- **`ru-direct` preset extended** ([§045 spec](docs/spec/tasks/045-ru-direct-geoip-fallback.md)). Теперь четыре слоя матчинга вместо одного:
  - **`ru-domains`** (TLD-based, было) — `.ru` / `.su` / IDN / `.moscow` / `.tatar`.
  - **`ru-services`** (новый inline rule_set) — 18 service-CDN suffix'ов российских компаний на не-RU TLD: `userapi.com` (VK), `avito.st`, `yandex.{net,com}`, `yastatic.net`, `2gis.com`, `okko.tv`, `premier.one`, `lenta.com`, `vk.com`, `vk-portal.net`, `gismeteo.com`, `lmru.tech`, `mradx.net`, `wbstatic.net`, `wildberries.by`, `trbcdn.net` (общий CDN Тинькофф+Сбер), `sberbank.com`. Проанализированы по WHOIS/AS — все RU-родные.
  - **`Ru Apps`** (package_name match, было) — для российских приложений у которых трафик может идти на любые TLD.
  - **`geoip-ru`** (новый remote `.srs` от runetfreedom) — IP-range fallback для CDN/QUIC/ECH/short-lived TCP, где первые три слоя могут пропустить (sniff race / package detection race / TLS 1.3 ECH). Гейтится через `geoip_enabled` var (default `true`); auto-download `.srs` через `RuleSetDownloader` (~150 KB, обновление 168h). Spec compliance §011.
  - `expandPreset` поддерживает `enabled: "@var"` гейтинг для rule_set entries (фрагмент пропускается при `false`) и `List<String>` форму `routing_rule.rule_set` (даунгрейд до single string при одном expanded tag'е, drop rule + warning при empty filtered list).
  - Existing v1.6.1 юзеры с включённым `ru-direct` preset получают `geoip_enabled = true` по default'у на ребилде → новый layer автоматически активируется без миграции storage.
- **README** + **README_RU**: feature card для Per-app traffic profiler в Features секции, screenshot `docs/screenshots/per_app_trace.jpg`.
- **`AppInfoCache`**: новый `loadAllApps()` (lightweight installed-apps list, populate per-package cache без иконок) + smart `ensure(pkg)` (если AppInfo в cache без icon'а — догружает только icon, а не полный info). Унифицирует icon-cache между Custom Rules и Per-app picker'ами.
- **`SseResponse`** в `debug/transport/response.dart` — primitive для Server-Sent Events через Debug API (используется `/profiler/stream`).

### Tests

- `app/test/services/traffic_profiler_test.dart` — session lifecycle (start/stop/auto-finalize), log-stream parsing (UID strip, CNAME chain, dns:cached + dns:exchanged), aggregation (DomainStats / IpStats), process inference (10s post-DNS window), connection-issue detection (2 types), session ring-buffer eviction.
- `app/test/services/builder/preset_expand_test.dart` — расширен под §045: 4 case'а для `geoip_enabled` × `geoip-ru` cache state (on+downloaded / on+not-downloaded / off+downloaded / off+not-downloaded), List form для `rule_set`, dangling-rule_set guard.
- `flutter analyze` чистый, **510 tests passed**.

### Release / CI

- Per-ABI APK split (продолжается с v1.6.1): `LxBox-v1.7.0-{arm64-v8a,armeabi-v7a,x86_64,universal}.apk`.

---

## [1.6.1] — 2026-05-08

DNS-серверы перевели на kind-discriminated refs (симметрия с DNS rules §061 dns-rules-refactor, бывший feature §041) с чистым разделением meta-полей и sing-box body — фиксит баги выявленные на v1.6.0 в эксплуатации.

### Changed

- **DNS servers: kind-discriminated refs + clean schema** ([§043](docs/spec/tasks/043-dns-servers-refs-by-kind.md) + [§044](docs/spec/tasks/044-dns-servers-clean-schema.md)). Storage `dns_options.servers[i]` хранит refs шейпа `{enabled, kind: inline|preset|template, tag, description?, body?}` — точно по образцу §061 DNS rules refactor (бывший feature §041).
  - **`tag` — single source of truth**: на ref-level. Для inline body **partial sing-box shape без** `tag`/`description`/`enabled` (они на ref-level, а sing-box эти meta-поля не использует). На build-time `body['tag'] = ref.tag` синтезируется в `config.dns.servers[i]` (запротоколированная магия в `resolveDnsServersBodies`).
  - **`description` на ref-level**: для inline — primary, для template/preset — optional override (если отсутствует, fallback на canonical's description).
  - **Body для template/preset берётся из canonical** by tag at render/build time. `kind: template` ref'ы автоматически подхватывают template-обновления (e.g. tag rename'ы от §060 libbox migration, бывший feature §039); orphan-cleanup на load удаляет ref'ы с несуществующими tag'ами.
  - **Override = `kind: inline` для tag'а с canonical** — без shape-comparison через `jsonEncode` (раньше order-sensitive фрагильно). Тривиальная classification по kind.
- **Короткие односложные badge'ы**: **Template** / **Preset** / **User** / **Overridden**. Раньше длинные «User (overrides template)» / «Preset · Russian domains direct» ломали title-wrap (живой баг на Yandex UDP — title разрывался на 4 строки).
- **Edit dialog: 3 явных input'а** — `Tag` / `Description` / `Enabled (Switch)` сверху, body JSON внизу (только sing-box-relevant поля **без** `tag`/`description`/`enabled`). Раньше юзер видел «магические» поля среди sing-box-полей.
- **Auto-discovery + orphan cleanup** в `resolveDnsServersList` — для каждого template/active-preset server'а tag которого нет в storage append'ится ref (с template's enabled default'ом / preset's default true); template/preset ref'ы с несуществующими tag'ами удаляются. Симметрично `resolveDnsRulesList` (§033 / §061 dns-rules-refactor, бывший feature §041).
- **UI: edit body на template/preset переводит entry в `kind: inline`** (copy-on-write). Reset (↺) убирает inline и возвращает kind на canonical; body+description удаляются. Add custom server создаёт `kind: inline` с user'овским body.
- **Builder consequences**: `applyCustomDns` теперь использует `resolveDnsServersList` (refs) + `resolveDnsServersBodies` (refs → final bodies для sing-box config). Старая XOR-логика «userServers OR templateServers» удалена.
- **Render layer typed**: новый `ResolvedServer` class в `dns_settings_screen.dart` — никаких underscore-полей в Map'ах (`_kind`/`_overrides`/`_preset_label`/`_origin` удалены полностью; компилятор гарантирует что они не протекут в JSON dump'ы).
- **One-shot migration** для existing v1.6.0 юзеров (one-shot, lossless). Auto-detect по presence/absence of `kind` field на entries:
  - **Pre-§043** (legacy full-body snapshot): classify by canonical match → kind-ref + peeled description на ref-level + partial body.
  - **§043 inline** (с tag/description в body, intermediate state): peel `body.description` → `ref.description`; drop `body.tag`/`body.enabled`/UI-annotations.
  - **§044 already-migrated**: no-op.
- **Debug API `PUT /settings/dns_options/servers`** принимает любой из трёх форматов (pre-§043 / §043 / §044). Detection auto'тический; legacy форматы конвертируются в §044 на ближайший resolver tick.
- **About screen — все 3 GitHub-tile теперь clickable** (Source Code → LxBox repo, VPN core → sing-box upstream, singbox-launcher Credits → upstream). Раньше копировали URL в clipboard — менее очевидно. Trailing `open_in_new` иконка для visual cue.

### Fixed

- **JSON viewer protokol leak** — `_showServerBodyDialog` показывал `_kind`/`_overrides` underscore-поля у одних tile'ов, не у других. Теперь `ResolvedServer.body` физически не содержит underscore-полей.
- **DNS Settings — Yandex/long-name preset tile разорван на 4 строки** (live-баг v1.6.0). Длинный badge `Preset · Russian domains direct` ломал title-wrap. Теперь badge короткий `Preset`, имя preset'а в subtitle.
- **Toggle enabled на template-сервере помечал его как Overridden** (live-баг). Storage хранил copy-on-write template-shape с изменённым `enabled`, override-detection через shape compare ошибочно классифицировала это как override. С refs-by-kind: toggle меняет только `enabled` ref'а, kind остаётся `template`, badge остаётся `Template`.
- **После §060 (libbox migration, бывший feature §039) tag rename `direct_dns_resolver` → `google_udp`** existing-юзеры не видели нового tag'а в DNS Final dropdown'е. Теперь auto-discovery подтягивает новый tag, orphan cleanup убирает старый.

### Tests

- `test/services/builder/dns_servers_resolver_test.dart` — `resolveDnsServersList` (orphan cleanup, auto-discovery, legacy migration); `resolveDnsServersBodies` (refs → bodies, enabled filter).

### Docs

- **`docs/STORAGE.md`** (новый) — единый источник правды по схеме `lxbox_settings.json`: top-level shape, per-key семантика, migration history (proxy_sources → server_lists, app_rules → custom_rules, dns_options.rules_json → rules[], pre-§043 → §043 → §044), SharedPreferences boot flags, Debug API exposure allow-list. `ARCHITECTURE.md` §5 свёрнут до tldr со ссылкой.

### Release / CI

- **Per-ABI + universal APKs** — релиз публикует 4 артефакта вместо одного fat-APK: `LxBox-vX.Y.Z-arm64-v8a.apk` (~32 MB, default для 95%+ устройств), `LxBox-vX.Y.Z-armeabi-v7a.apk` (старые / Android Go), `LxBox-vX.Y.Z-x86_64.apk` (эмуляторы / Chromebook), `LxBox-vX.Y.Z-universal.apk` (fat fallback ~95 MB). Уменьшает размер скачиваемого APK для большинства юзеров на ~3×. CI-инфраструктура запилена в `ci.yml` под этот релиз; v1.6.1 — первый релиз, который реально публикует все 4. Closes #4.

---

## [1.6.0] — 2026-05-07

«Диагностика + восстановление + DNS-cleanup» релиз. Под капотом — миграция на sing-box 1.13.x с переработкой нативного VPN-сервиса; видимое для юзера — light-recovery (Reload-кнопка / reset-network), per-group ping/test settings, понятные ошибки в banner'ах, починка DNS-маршрутов в РФ через ru-direct, backup/restore UI и всё, что ниже.

### Added

- **Backup & restore UI** ([§040 backup spec](docs/spec/features/040%20backup%20restore%20ui/spec.md), commit b332b21). Новый экран — экспорт/импорт пользовательских данных (server lists / routing rules / app settings / debug config) в JSON. 4 toggleable категории, dry-run preview перед применением, merge vs replace mode. Экспорт через `share_plus`, импорт через `file_picker`. Debug API: `GET /backup/export?include=...`, `POST /backup/import?merge=...`.
- **Reload-кнопка в AppBar** (commits 3f4cac7 / d5c709e / 23ff55b). Default tap = light reload core (`commandServer.startOrReloadService`) вместо полного reconnect — TUN не закрывается, in-place restart sing-box runtime'а с тем же config'ом. В long-press menu — отдельный пункт Reload как первый, recovery-фокус. Cooldown 3s между нажатиями (`canReload` getter в HomeController).
- **`/action/reset-network` Debug API** ([§031](docs/spec/tasks/031-reset-network-api.md)). Light recovery — `commandServer.resetNetwork()` без recreate'а box runtime / Service / TUN. Делает `connectionManager.CloseAll()` + DNS cache flush (`r.ClearCache()` + `transports.Reset()`) + interface refresh у inbound/outbound/endpoints. Spec обновлена с разбором по строкам исходника sing-box v1.13.11 (изначальная гипотеза «БЕЗ drop'а in-flight TCP» опровергнута — в реале all connections рвутся, но Service/TUN остаются стабильны).
- **Per-group ping/test settings + persist** ([§040](docs/spec/tasks/040-per-group-ping-test-settings.md)). Каждая VPN-группа может иметь свои `url` + `timeout_ms` для ping / mass-URLTest / group URLTest. Storage shape `ping_options: {url?, timeout_ms?, groups: {<groupTag>: {url?, timeout_ms?}}}` симметричен template'у. Resolve chain: per-group override → global storage → template default. Global `pingUrl`/`pingTimeout` теперь тоже **persist'ятся** (раньше жили только в памяти controller'а — на restart сбрасывались). UI dialog «Ping settings» с SegmentedButton «All groups | <currentGroup>» + Reset-to-global. Debug API endpoints: `GET/PUT /settings/ping_options`, `GET/PUT/DELETE /settings/ping_options/groups/{tag}`. Use-case: VPN-1 (foreign-routed) — gstatic 204; VPN-2 (РФ-direct) — ya.ru.
- **Sing-box internal logs в Debug API** ([§043](docs/spec/features/043%20applog%20per-source%20quotas/spec.md)). `GET /logs/core` показывает router/dns/inbound/outbound события sing-box'а — для диагностики bug-репортов («после wake direct/auto не работает» и т.п.). Source delivery: `PlatformInterface.writeDebugMessage` → `EventChannel("lxbox/coreLog")` → `ClashLogPump` (новый `lib/services/clash_log_pump.dart`) → `AppLog` как `DebugSource.core`. Уровень парсится regex'ом (`\bWARN\b`/`\bERROR\b` etc.) — TRACE/DEBUG отбрасываются на native (volume reduction). ANSI escape codes стрипаются. **Toggle:** `PUT /settings/core_logs_enabled {"enabled":true}` (default false; storage в SharedPreferences `boxvpn_boot.core_logs_enabled` потому что `Libbox.setup` читает значение до Flutter engine; изменение применяется только после force-stop приложения). UI-toggle единственный — App Settings → Diagnostics. Shortcut в DebugScreen: ⋮ menu → "Diagnostics settings".
- **AppLog per-source quotas** ([§043](docs/spec/features/043%20applog%20per-source%20quotas/spec.md)). Раньше единый ring-buffer на 500 entries — sing-box (verbose, сотни строк/мин) вытеснял app-сообщения за минуты. Теперь `Map<DebugSource, List>`: `app=300`, `core=500`, независимые ring-buffer'ы. K-way merge на чтении (insert O(1) amortized), `entriesForSource(s)` direct lookup. Persistent split: `applog.txt` + `corelog.txt`, по 200 lines / 64KB каждый — `initPersistent()` грузит оба. Debug API: `GET /logs/app`, `GET /logs/core` aliases; `POST /logs/clear?source=app|core` per-source clear.
- **Debug API: write `config.json` direct + lockable rebuild** ([§037](docs/spec/tasks/037-debug-api-write-config-and-lock-rebuild.md)). `PUT /config` с raw sing-box JSON — sing-box reload'ится. `PUT /settings/config_locked {"locked": true}` — pin'ит config от UI-rebuild'ов (`SubscriptionController.generateConfig()` возвращает null silently пока lock держится). Use-case: тестировать sing-box фичи которые наш parser/builder не понимает (Tailscale outbound и т.п.). Endpoints: `PUT /config`, `GET /state/config_locked`, `PUT /settings/config_locked`. Storage: `config_locked_for_debug`, default false.
- **Core version в About** (commit 3f4cac7). About dialog показывает версию sing-box core (`commandServer.coreVersion()`) рядом с app version — сразу видно какой libbox прошит.
- **Universal error format helper** ([§041](docs/spec/tasks/041-user-error-format-helper.md)). Новый `lib/services/error_format.dart` с `formatUserError(Object e)` — превращает Dart exception toString'ы в человекочитаемый текст. Поддерживает `TimeoutException` → `timeout Ns`, `SocketException`/`FileSystemException` → `osError.message`, `FormatException` → `e.message`, `ClashHttpException` → `HTTP <code>`, `PlatformException` → `e.message ?? "platform error: <code>"`, fallback strip+truncate. Применено в 7 user-visible callsite'ах HomeController (file pick, start/stop/reconnect VPN, Clash API refresh, switch node) + snackbar'ах 6 экранов. 12 unit-тестов. Примеры:
  - `PlatformException(start_failed, "vpn_service.prepare returned false", null, null)` → `vpn_service.prepare returned false`
  - `SocketException("Failed lookup", OSError("Connection refused", 61), ...)` → `Connection refused`
  - `FileSystemException("Cannot open file", "/p", OSError("No such file or directory", 2))` → `No such file or directory`

### Changed

- **libbox: 1.12.12 → 1.13.11** ([§060 libbox migration](docs/spec/tasks/060-libbox-1-13-migration/spec.md), commit 913530b). Перешли на актуальный major-релиз sing-box. Ключевые архитектурные перемены подкапотом:
  - **`BoxService` класс удалён в 1.13** — всё его API поглощено в `CommandServer`. Единый `CommandServer` владеет runtime'ом через `startOrReloadService(config, opts)`. Two-phase shutdown (`closeService()` → `close()`).
  - **`PlatformInterface` упрощён**: убраны `writeLog`, `packageNameByUid`, `uidByPackageName` — sing-box сам ведёт UID→package mapping и отдаёт через richer `ConnectionOwner` struct (`userId`, `userName`, `processPath`, `androidPackageNames[]`).
  - **`Seq.destroyRef` больше не вызываем** — Go runtime в 1.13 self-cleans refnum'ы; manual destroyRef = double-free.
  - **Two-phase shutdown на `Dispatchers.IO`** — `closeService()` (остановить runtime; throwing → `setError`), потом `close()` (закрыть Unix-socket; non-throwing). Перепутать = Go callbacks могут зависнуть → ANR.
- **Dart wrapper cleanup** (`box_vpn_client.dart`):
  - `getVpnStatus()`/`onStatusChanged` возвращают типизированный `TunnelStatus`/`TunnelStatusEvent` вместо `String`/`Map<String,dynamic>`.
  - `BackgroundMode` enum (был `String`).
  - `AppInfo` model — типизированный класс в `lib/models/app_info.dart`.
  - **MethodChannel timeouts** на критических вызовах — `getVpnStatus` (3s), `startVPN` (30s), `stopVPN` (10s), `getInstalledApps` (15s).
  - `BoxVpnClient.I` singleton + `BoxVpnClient.forTest()` factory.
  - Method-name константы (`_Methods.saveConfig` etc.).
- **Empty template DNS catch-all** ([§039 task](docs/spec/tasks/039-empty-template-dns-rules.md)). Убрали template-level правило `{name: "Default → Google DoH", server: google_doh}` — всё что не матчится preset/inline DNS-правилами теперь идёт через `dns.final` (= `@dns_final`, default `local_dns_resolver` = system resolver через PlatformInterface; юзер может override'нуть в wizard'е). Причина: `google_doh` (HTTPS/443) на long-idle деградирует — DoH connection pool stale → re-dial фейлится → fall-through DNS умирает (наблюдалось 2× за неделю). System resolver state-less, не подвержен. Tooltip `dns_final` обновлён. Existing-юзеры с записью «Default → Google DoH» — orphan cleanup в `resolveDnsRulesList` сам уберёт. Также: tag `direct_dns_resolver` → `google_udp` (симметрия с `cloudflare_udp`).
- **DNS settings dropdown'ы видят preset-серверы** ([§039 task](docs/spec/tasks/039-empty-template-dns-rules.md)). `_enabledServerTags` getter в `dns_settings_screen.dart` объединяет два источника: template/user-saved (`_servers`) + preset-expanded (`_presetServersWithLabel`, e.g. `yandex_udp` от ru-direct). До fix'а dropdown показывал только template+user; preset-добавленные теги не появлялись. Затронутые dropdown'ы: DNS Final / Default Domain Resolver / per-rule server selector.
- **`ru-direct` preset: DNS defaults сменили на UDP/Base** ([§038](docs/spec/tasks/038-ru-direct-dns-defaults.md)). Был `yandex_doh` (HTTPS/443) с IP `77.88.8.88` (Safe-tier). Стал `yandex_udp` (UDP/53) с IP `77.88.8.8` (Base-tier). Причина: у части юзеров (особенно `outbound = direct-out` или WG-router в РФ) Yandex DoH endpoint на `:443` режется ISP/router-DPI: TLS handshake до `safe.dot.dns.yandex.net` зависает, ICMP/UDP при этом работают. Все `.ru` lookups через `ru-direct` failed → `ERR_CONNECTION_REFUSED` в браузере и mobile-apps на ya.ru / t-bank-app.ru. UDP/53 на 77.88.8.8 универсально пропускается. Tooltip `dns_server` укоротили; options в `dns_ip` и `dns_servers` упорядочили — Base/UDP идут первыми. **Существующие установки не затронуты**: явно сохранённые `vars_values` приоритетнее template-default'а.
- **DNS rules: schema cleanup** ([§061 dns rules refactor](docs/spec/tasks/061-dns-rules-refactor/spec.md) + [§032](docs/spec/tasks/032-dns-rules-schema-symmetry.md) + [§033](docs/spec/tasks/033-unified-kind-vocabulary.md)). Унификация discriminator: `dns_options.rules[i].type` → `kind`. Унификация vocabulary: `inline | srs | preset | template` для DNS rules — общая лексика с `custom_rules`. Для `kind: preset` хранится `presetId` вместо mutable `title=preset.label`. Field rename `title` → `name` для kind=inline/template — симметрия с `custom_rules.name`. Auto-link при создании / mandatory link при удалении: добавление `custom_rules.kind:preset` автоматически создаёт соответствующую `dns_options.rules.kind:preset` запись. **Independent enable** route-aspect ↔ DNS-aspect. **No migration** — legacy ключи silently dropped, auto-discovery восстанавливает fresh state.
- **Action endpoints: unified `/action/urltest`** ([§040](docs/spec/tasks/040-per-group-ping-test-settings.md)). Раньше три endpoint'а: `/action/ping-node?tag=`, `/action/ping-all`, `/action/run-urltest?group=`. Теперь один `/action/urltest` со scope-dispatch'ем через query: `?tag=` (single node), `?group=` (group urltest), `?all=true` (mass urltest). HomeController методы: `pingNode` → `runNodeUrltest`, `pingAllNodes` → `runMassUrltest`, `runGroupUrltest` без изменений. **Breaking** для adb-скриптов которые звали старые endpoints — alias'ы не оставлены.
- **URLTest error format: human-readable** ([§040](docs/spec/tasks/040-per-group-ping-test-settings.md)). `runNodeUrltest` / `runGroupUrltest` форматируют ошибки через `_formatProbeError` (built on top of `formatUserError` из §041):
  - Было: `Ping: TimeoutException after 0:00:10.000000: Future not completed`
  - Стало: `direct-out → ya.ru — timeout 5.8s` / `direct-out → ya.ru — HTTP 503` / `direct-out → ya.ru — connection refused`
- **Clash delay/groupDelay timeout sync** ([§040](docs/spec/tasks/040-per-group-ping-test-settings.md)). Раньше Dart-side wrapper использовал hardcoded `_timeout = 10s` независимо от `timeoutMs` query-param'а. Если юзер ставил `timeout_ms=5000` — dart-сторона всё равно ждала 10s, ловила TimeoutException вместо нормального clash response. Теперь `Duration(milliseconds: timeoutMs) + _delayResponseBuffer` где `_delayResponseBuffer = 750ms` (cleanup-buffer на стороне sing-box). Применено в `delay()` и `groupDelay()`.
- **`wizard_template.json`**: убрано невалидное поле `"format": "domain_suffix"` из inline rule_set'а `ru-domains`. Sing-box тихо обнулял его и в 1.12, и в 1.13, но в `option/rule_set.go` для inline-варианта это поле не определено — будущий sing-box 1.14+ может ужесточить и сделать hard reject.

### Fixed

- **Clash delay endpoint hang после ~27 минут аптайма** (root-cause [§060 libbox migration](docs/spec/tasks/060-libbox-1-13-migration/spec.md)). Симптом: все ноды в server-list show "err" в UI после 28-30 минут активной VPN-сессии, при том что трафик через выбранную ноду продолжает работать. Root cause — DNS cache dedup-lock goroutine leak в sing-box `dns/client.go:144-164`: per-question wait канал блокировался **без** `ctx.Done()`-awareness; первый раз когда upstream DNS-transport замёрз, все последующие waiter'ы парковались навсегда. Fix — upstream commit `aba8346b`, вошёл в sing-box `v1.12.21+` и `v1.13.0+`.
- **Mass ping cancel actually cancels** ([§034](docs/spec/tasks/034-mass-ping-cancel-actually-cancels.md)). Раньше Stop во время mass ping'а оставлял три side-effect'а: спиннеры висели до timeout'а у нод которые не успели ответить (worker break без cleanup pingBusy state'а); `_runAllUrltestGroups` после workers крутил `auto`-группу до конца независимо от cancel'а; in-flight HTTP delay/groupDelay запросы продолжали выполняться. Fix: `cancelMassPing` теперь (1) очищает `pingBusy` целиком; (2) `_runAllUrltestGroups(epoch)` проверяет epoch на каждой итерации; (3) `ClashApiClient` имеет отдельный `_delayHttp` клиент — `cancelDelays()` его close'ит, in-flight HTTP-сокеты рвутся.

### Build / CI

- **APK размер: ~73 MB → ~56 MB** (commit da709a3). CI собирает **arm64-v8a single-arch** APK (`flutter build apk --release --target-platform android-arm64`) — то же что и локальная сборка через `scripts/build-local-apk.sh`. Раньше CI собирал fat-APK с тремя ABI; `libbox.so` (~17 MB) дублировался на каждую ABI.
  - Покрытие: arm64-v8a — 95%+ современных Android-устройств. Android 14+ Google запретил 32-bit-only платформы.
  - Не покрывает: `armeabi-v7a` only Android Go бюджет — вне целевой аудитории VPN-клиента.
  - **v1.5.0 (предыдущий)** — последний релиз с fat APK ~73 MB. v1.6.0+ — arm64-only ~56 MB.

### Documentation

- **Постоянная карта обновления документации** ([`docs/spec/README.md`](docs/spec/README.md)). Каждая спека (фича/задача) теперь должна явно перечислять раздел `## Docs to update` со списком конкретных entries: какие из стандартных файлов (`debug-api-reference.md`, `CHANGELOG.md`, `ARCHITECTURE.md`, `RELEASE_NOTES.md` + `releases/vX.Y.Z.md`, `pubspec.yaml`, `DEVELOPMENT_REPORT.md`) обновляются вместе с кодом. Backfill в spec'ах §035-§041, §043. Имплементационная фаза не считается завершённой пока соответствующие docs-обновления не сделаны.

---

## [1.5.0] — 2026-04-29

### Added

- **NaïveProxy** ([§037](docs/spec/features/037%20naive%20proxy/spec.md), [#2](https://github.com/Leadaxe/LxBox/issues/2)) — парсер `naive+https://` URIs (DuckSoft), генератор sing-box `type: "naive"` outbound'а, share-URI round-trip. 10-й протокол в Parser v2. Cronet/`with_naive_outbound` уже в `libbox.aar` — без APK-size impact. +36 тестов; suite 373 → 409 ✓.
- **Quick Connect: QS tile + home-screen shortcut** ([§032](docs/spec/features/032%20quick%20connect/spec.md), [#1](https://github.com/Leadaxe/LxBox/issues/1)) — две точки toggle VPN без открытия app'а. Tile синхронизирован с `BoxVpnService.currentStatus`, shortcut на launcher-иконке. Первый раз app коротко открывается ради `VpnService.prepare(...)` consent — Android API ограничение. См. [task 014](docs/spec/tasks/014-quick-connect-tile-shortcut.md).
- **Crash diagnostics** ([§038](docs/spec/features/038%20crash%20diagnostics/spec.md)) — четыре независимых канала post-mortem диагностики:
  - **A. stderr-redirect** — `Libbox.redirectStderr` пишет Go panic-stacktrace в `filesDir/stderr.log` до SIGABRT'а. Условная вкладка `stderr` в Debug-экране (только если файл непустой), кнопка Share. [task 018](docs/spec/tasks/018-stderr-viewer-debug-tab.md).
  - **B. ApplicationExitInfo** (API 30+) — `getHistoricalProcessExitReasons` lazy-читается в `DumpBuilder`. Reason + tombstone (для CRASH_NATIVE) или JVM stacktrace (для CRASH). [task 029](docs/spec/tasks/029-application-exit-info.md).
  - **C. Persistent AppLog** — `warning` + `error` уровни пишутся в `filesDir/applog.txt` (ring-buffer 200 строк / 64KB). На старте `main()` подгружаются с `fromPreviousSession=true`. Pre-crash JVM-events переживают рестарт. [task 028](docs/spec/tasks/028-persistent-applog.md).
  - **D. Logcat tail** — `Runtime.exec("logcat", "-d", "-t", 1000, "*:E")` через `ProcessBuilder` (без `READ_LOGS` permission, logd UID-фильтрует сам). Ловит `AndroidRuntime FATAL EXCEPTION`, `libc`/`DEBUG`/`tombstoned`, `art`/`linker` — особенно когда AEI не приложил trace (Samsung One UI quirk на REASON_CRASH). [task 022](docs/spec/tasks/022-logcat-tail-in-dump.md).
  - `DumpBuilder` отдаёт все 4 канала одним JSON-pack'ом (поля `stderr_log`, `exit_info`, `logcat_tail`, plus `debug_log` с persistent-маркером).
- **Debug API: `/diag/*` endpoints group** ([§031](docs/spec/features/031%20debug%20api/spec.md)) — `/diag/dump`, `/diag/exit-info`, `/diag/logcat`, `/diag/stderr`, `/diag/applog`. Всё что отдаётся в UI ⤴ Share, доступно через HTTP без UI.
- **Debug API: `/backup/*` group** ([task 026](docs/spec/tasks/026-backup-export-import.md)) — `GET /backup/export?include=config,vars,subs` и симметричный `POST /backup/import?merge=&rebuild=`. Pure-data snapshot (без diag-шума), совместим с форматом `/diag/dump`. Кеши (cache.db, stderr.log, SRS, runtime nodes) не входят — restore их пересоздаст из подписок.
- **Debug API: `POST /action/preview-empty-state?on=true|false`** ([task 025](docs/spec/tasks/025-preview-empty-state.md)) — UI-only override: `HomeScreen` рендерит empty-state как при чистой инсталляции, реальные данные не трогаются. Полезно для скриншотов / regression-теста UX без `pm clear`.

### UX

- **Home empty-state guide** ([task 024](docs/spec/tasks/024-home-empty-state-cta.md)). Два состояния:
  - **Нет конфига** (`configRaw.isEmpty`): «Add a server» + крупная круглая `+`-кнопка → `SubscriptionsScreen`. `_buildControls` скрыт — стартовать нечего, disabled-кнопка только запутывала.
  - **Конфиг есть, не подключены**: вместо пассивного «Tap Start to connect» — большая кликабельная зона с иконкой play (64dp, primary color) и текстом «Tap to connect». Тап стартует VPN тем же путём что и FilledButton в _buildControls.

### Fixed

- **`CHANGE_NETWORK_STATE` permission на Android 9-11** ([task 023](docs/spec/tasks/023-change-network-state-permission.md)). `DefaultNetworkListener` на API 28-30 зовёт `ConnectivityManager.requestNetwork(...)`, который требует `CHANGE_NETWORK_STATE`. Без него — `SecurityException` → `REASON_CRASH` сразу после VPN-consent OK на A50/A10/Y9. На API 31+ используется `registerBestMatchingNetworkCallback` (без этого требования) — поэтому регрессия проявлялась только на 9-11.
- **VLESS `packetEncoding` allow-list** — xray-style подписки кладут в URI `packetEncoding=none`, что выдаёт `"packet_encoding": "none"` в outbound JSON; sing-box `vless.NewOutbound` принимает только `xudp`/`packetaddr`/omitted, для прочего зовёт `E.New("unknown packet encoding: …")` и крашит libbox через апстрим-баг в `format.ToString`. Парсер нормализует на входе: `xudp`/`XUDP` → `xudp`, `PacketAddr` → `packetaddr`, `none` дропается, прочее → warning + дроп. См. [task 012](docs/spec/tasks/012-vless-packet-encoding-libbox-panic.md), [PROTOCOLS.md](docs/PROTOCOLS.md).
- **Race: `Libbox.newService` до завершения `Libbox.setup`** ([task 027](docs/spec/tasks/027-libbox-init-race-fix.md)) — `BoxApplication.libboxReady: CompletableDeferred<Unit>` барьер; `serviceScope.launch` в `BoxVpnService` ждёт его до любого libbox-вызова. Параллельно: `workingDir` libbox переехал из external (`getExternalFilesDir(null)`) в internal (`context.filesDir`) — там же где SettingsStorage и подписки; убирает Knox/SELinux edge-case'ы.
- **Quick Connect class-verification на Android 9-11** ([task 015](docs/spec/tasks/015-android-9-11-quickconnect-regression.md)) — `Tile.subtitle` (API 29+) в `@RequiresApi(Q)` helper, `LxBoxTileService.refreshTile` / `QuickShortcuts.refresh` gated на API 30+ с outer `try { Throwable }`, все callsites в `setStatus`/`onDestroy`/`initialize` обёрнуты в `runCatching`. `FOREGROUND_SERVICE_SPECIAL_USE` permission гейтнут `minSdkVersion="34"`; typed `startForeground` на API 34+.

### Reliability

- **`Libbox.newService` / `svc.start` / `serviceScope.launch` ловят `Throwable`** ([task 016](docs/spec/tasks/016-libbox-newservice-throwable-catch.md)) — не только `Exception`; `Error`-наследники (OOM, NoClassDefFoundError, VerifyError) теперь идут через понятный `stopAndAlert(...)` вместо тихого вылета.

### Earlier in v1.5.0 cycle (2026-04-23 carryover)

#### Breaking

- **Tunnel sleep mode default: `lazy` → `never`.** Раньше tunnel поведение было захардкожено: `pause()` на deep Doze + `wake()` при выходе (паттерн sing-box-for-android). При Doze ломались длинные TCP-сокеты и push-уведомления — юзеры жаловались «интернет отваливается пока не открою app». Новый дефолт `never` держит тоннель всегда активным, что увеличивает расход батареи (ориентировочно +1–3% за ночь) в обмен на стабильность push'ей и SIP/VoIP. Кто хочет старое поведение — Settings → Background → Tunnel sleep mode → **Lazy sleep**. Миграция silent: существующие установки получают новый дефолт без диалога, настройка доступна из UI.

#### Reliability

- **Tunnel sleep mode (3-way setting)** — App Settings → Background → «Tunnel sleep mode». Три режима: `never` (default, tunnel всегда активен), `lazy` (pause только при deep Doze), `always` (pause при каждом screen-off, максимум экономии батареи). Хранение в `BootReceiver` SharedPreferences (`background_mode`), применяется при следующем подключении VPN. Реализация: [BoxVpnService.kt](app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt), [BootReceiver.kt](app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BootReceiver.kt), [VpnPlugin.kt](app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt), [box_vpn_client.dart](app/lib/vpn/box_vpn_client.dart), [app_settings_screen.dart](app/lib/screens/app_settings_screen.dart).

#### UX

- **Tabbed App Settings** — 3 таба: **General** (appearance, behavior, subscriptions, feedback), **Background** (keep-on-exit, battery opt, notifications, OEM, sleep mode), **Diagnostics** (permissions summary, Debug API). Keep-on-exit перенесён из Startup в Background.
- **Battery-optimization попап на старте** — если `isIgnoringBatteryOptimizations == false`, HomeScreen показывает AlertDialog «Разрешите работу в фоне» с кнопкой перехода в системные настройки. Rate-limit: не чаще 1 раза в 24 часа (`battery_opt_last_prompt_ms` в SettingsStorage). Реализация: [home_screen.dart](app/lib/screens/home_screen.dart).
- **Notifications-status индикатор** в App Settings → Background. Если нотификации запрещены — красная иконка + tap открывает per-app notification settings. Важно для Android 13+ где `POST_NOTIFICATIONS` runtime-permission: без неё foreground service работает, но notification не рендерится → OS охотнее throttle'ит FGS. Native API: `NotificationManagerCompat.areNotificationsEnabled()` + `Settings.ACTION_APP_NOTIFICATION_SETTINGS`.

- **Update check on launch** ([§036](docs/spec/features/036%20update%20check/spec.md)) — `UpdateChecker` сервис: через 5s после старта app'а пингует `api.github.com/repos/Leadaxe/LxBox/releases/latest` (24h cap, default ON, single-line disclosure). Если новый релиз → `SnackBar` в HomeScreen с кнопками **View** (открывает release page в браузере) / **Not now** (dismiss per-tag). Sideload flow без in-app installer. About screen: блок «Latest available» с manual `[Check now]`. App Settings → General → Updates: toggle + last-check + manual button.

#### Debug API

- **`GET /help[?format=text|json]`** — self-documenting capability map. Без auth (как `/ping`). Markdown-text для LLM-агентов, structured JSON для auto-tooling. Hand-maintained в `handlers/help.dart` — single source of truth для wrappers / шпаргалок.

#### Process

- **Night-work autonomous process** (`docs/spec/processes/night-work/`) — canonical spec, startup-prompt, report-template, morning-review, scripts/session-start.sh. Anti-pattern'ы из 2026-04-22 retro зашиты в spec (no silent pivot, no megacommit WIP rescue, no hallucinated marketer stats).
- **MCP server design** ([§035](docs/spec/features/035%20mcp%20server/spec.md), draft) — план обёртки Debug API в MCP server (stdio, TS+Node, tools/resources/prompts). Implementation отложена до момента когда Claude Desktop станет primary tooling surface.

#### Tests

- `test/vpn/box_vpn_client_test.dart` — MethodChannel contract tests для новых обёрток (`setBackgroundMode`, `getBackgroundMode`, `areNotificationsEnabled`, `isIgnoringBatteryOptimizations`). 4 теста.
- `test/services/update_checker_test.dart` — 10 unit-тестов на pure-function `isNewer` (semver compare, malformed input, suffix stripping).

#### Scripts

- `scripts/install-apk.sh` — auto-detect устройство (wifi > USB), install + force-stop + launch + restore Debug API forward (port 9269).
- `scripts/ensure-wifi-adb.sh` — check / bootstrap wifi-adb (tcpip + connect from USB device).

---

## [1.4.2] — 2026-04-22

### Design

- **Новая иконка приложения** — W1 "routing cross" вместо generic Flutter-иконки. Android (adaptive foreground/background + themed mono для Android 13+), iOS, macOS, web favicon, Windows — все платформы единовременно. Концепт отражает метафору маршрутизации по правилам. Источники SVG в `docs/design/icon/W1_pack/` (см. [spec 034](docs/spec/features/034%20app%20icon/spec.md)).

### Cleanup

- Удалён `docs/design/icon-exploration/` — прочие отклонённые концепты (W2 Lx-monogram, W3 iso-cube, 10 черновиков). История в git, финальный winner перемещён в `docs/design/icon/W1_pack/`.

---

## [1.4.1] — 2026-04-22

### Reliability

- **Retry + exponential backoff** для subscription fetch (`sources.dart`) и rule_set download (`rule_set_downloader.dart`): 3 попытки с задержками 1s → 3s. `4xx` — permanent (без ретраев), `5xx` / timeout / `SocketException` — retry. Снимает основную массу жалоб "подписка не обновляется" у юзеров с флапающей сетью.
- **Top-level error boundary** — `FlutterError.onError` + `PlatformDispatcher.instance.onError` → `AppLog`. Uncaught-ошибки видны на Debug → Logs. Красный экран заменён на компактный `ErrorBoundary` fallback-widget.
- **Auto-updater spam-gate tests** (§027) — покрыто тестами: `consecutiveFails`, `minRetryInterval`, `maxFailsPerSession`, `inProgress` crash-safe reset при старте app.

### Security

- **URL masking audit** — subscription URL больше не попадают в `AppLog` целиком. Везде `maskSubscriptionUrl` (`scheme://host/***`). Полный URL доступен только в Debug API с `reveal=true`. Закрыты 4 leak-сайта: hydrate-fail, `inProgress` skip warning, shortUrl truncation, `addFromInput`.

### UX

- **Human-readable errors** (`humanizeError`) — все user-visible сообщения приведены к человеческому виду. Было: `Exception: HTTP 503 for https://…`. Стало: `Server error (503) — provider is down, try later`. `TimeoutException` сообщает длительность. Покрыт топ-5: subscription fetch, rule-set download, parse, config build, VPN start.
- **Parse hints** — если подписка загружена но распарсилась в 0 нод, показываем причину (HTML-страница, Clash YAML, full sing-box config, plain-text error).
- **Pull-to-refresh** на Subscriptions screen (`RefreshIndicator` → `updateAll`).
- **Getting Started card** — карточка для пустого списка подписок: варианты URL / paste clipboard / file.
- **Unsaved-input guard** — Add Subscription: введённый текст + back → диалог "Discard input?".
- **Relative time** — `2h ago / yesterday / 3d ago / 2w ago / 2mo ago / 2y ago` вместо абсолютных timestamp'ов.
- **Reset fail-count & retry** — long-press на подписке → action размораживает `consecutiveFails` и сразу обновляет.
- **Share URL (masked / full)** — long-press → диалог с выбором masked/full URL.
- **Debug logs search** — `/logs` endpoint поддерживает `q=` substring search и `level=` multi-filter (`error,warn`). `/action/emulate-error` для demo `humanizeError`.

### Testing

- **262 → 359 тестов** (+97). Новые модули покрыты полностью: `error_humanize`, `url_mask`, `parse_hints`, `relative_time`, `input_helpers`, `http_cache`, `rule_set_downloader`, `auto_updater`, `body_decoder`, validator edge cases, preset-expand.

### Cleanup

- `flutter analyze`: 20 info/warning → **0**. `@override` аннотации на subclass fields, удалены избыточные `!`.
- Dispose + dead-code audit — чисто (без правок). `setDebugLastError` leak устранён в `/action/emulate-error`.

### Changed — `CustomRule` sealed-split (spec 030 §v1.4.1, task 011)

- **`CustomRule` разделён на sealed-иерархию** с тремя подклассами:
  - `CustomRuleInline` — юзерские match-поля (domain/suffix/keyword/cidr/port/package/protocol/private-ip + outbound).
  - `CustomRuleSrs` — локально закэшированный `.srs` бинарь по URL + доп-фильтры на routing-rule level (outbound).
  - `CustomRulePreset` — тонкая ссылка `{presetId, varsValues}` на шаблонный пресет. Outbound живёт в `varsValues['outbound']` (поля `outbound` нет — подставляется через `@outbound`).

  Компилятор теперь exhaustive-проверяет pattern-match `switch (cr)` в builder / UI. Общие методы — `withEnabled` / `withName` / `withOutbound` на base-class (type-preserving), плюс convenience-getters (`domains`/`srsUrl`/`presetId`/…) для read-only доступа из кода, не заботящегося о подтипе.
- **`CustomRule.fromJson` dispatch** по `kind` → `CustomRuleInline.fromJson` / `CustomRuleSrs.fromJson` / `CustomRulePreset.fromJson`. Backward-compat: старое поле `target` читается как `outbound` (pre-1.4.1 переименование).
- **Rename `target → outbound` + `kRejectTarget → kOutboundReject`** — везде (модель, builder, UI, Debug API, шаблон). Совпадает с sing-box JSON-schema и UI-лейблом.
- **Preset var `out → outbound`** в шаблоне и `varsValues` — убирает недоразумение между тремя именами одного концепта.

### Added — SRS cache для bundle-пресетов (spec 011 compliance)

До 1.4.1 `CustomRulePreset` с remote rule_set'ом в шаблоне (Block Ads, Russia-only services) пропускал `type: "remote"` прямо в конфиг, и sing-box качал сам при старте — нарушение принципа spec 011 «local-only, ручной download через ☁».

Теперь:
- `RuleSetDownloader.{presetCacheId, cachedPathForPreset, downloadForPreset, deleteForPreset}` — новый namespace ключей `preset__<presetId>__<tag>` для кэша preset-owned .srs файлов.
- `expandPreset` при обнаружении `type: "remote"` в `preset.ruleSets` проверяет cached path — есть → заменяет на `{type: "local", path: "<кэш>"}`, нет → rule_set skip + warning (правило всё равно попадает в конфиг с headless-routing, но match не работает до первого download'а).
- `buildConfig` pre-resolve'ит cache-paths для preset-правил перед вызовом `applyPresetBundles` (ключ `<presetId>|<rule_set_tag>`).
- **UI ☁-кнопка у preset-правил с remote rule_set'ами** — в списке Rules рядом с preset-правилом появляется та же cloud-иконка что у srs. Tap → скачивает все remote rule_set'ы пресета в cache. Long-press → menu Refresh / Clear. Switch auto-download — toggle-on при отсутствующем кэше триггерит скачивание, затем enable. "Cached" = все remote rule_set'ы пресета имеют локальный .srs (если хоть один отсутствует → ☁ иконка download, switch auto-download'ит).

### Fixed — VPN startup / preset-rule corner cases (task 011)

- **`Failed to start service: rule-set not found`** — когда preset имел `type: "remote"` rule_set без кэша, expansion дропал rule_set, но `routing_rule.rule_set: "<tag>"` оставался в `route.rules`, и sing-box падал при парсинге конфига. Добавлен **dangling-rule_set guard** в `expandPreset`: если `routing_rule.rule_set` ссылается на tag, которого нет среди expanded rule-sets (rule_set skip'нулся из-за missing cache) → routing_rule тоже drop'ается + warning.
- **☁-кнопка preset-правила не срабатывала на tap** — в `_presetSrsStatusButton` GestureDetector с `HitTestBehavior.opaque` перехватывал tap ДО `IconButton.onPressed`. Заменён на `InkWell` с `onTap` + `onLongPress` — один виджет ловит оба жеста.
- **Preset с remote rule_set'ами добавляется через «Add to Rules» disabled** — по аналогии с `CustomRuleSrs` (spec §011: без кэша правило не работает, не вводим юзера в заблуждение). Switch OFF + ☁-кнопка download; toggle-on auto-download'ит и включает.
- **Auto-disable preset-правил без кэша на load** — `_refreshSrsCache` теперь при отсутствии локальных `.srs` выставляет `rule.withEnabled(false)` + persist. Ранее `_template` устанавливался **после** `_refreshSrsCache`, из-за чего `_presetFor` возвращал null и auto-disable не срабатывал — исправлено (template set before cache refresh).

### Added — Preset bundles: self-contained parametrized rules (spec 033, task 010)

- **Новый `CustomRuleKind.preset`** — тонкая ссылка `{presetId, varsValues}` на `SelectableRule` в `wizard_template.json`. В отличие от `inline/srs` (data-копия), preset-правило разворачивается из шаблона при каждом build'е → обновление шаблона автоматически меняет поведение всех preset-правил пользователя (никаких миграций данных).
- **Bundle-формат пресета**: self-contained `rule_set` + `dns_rule` + `routing rule` + `dns_servers` с типизированными переменными (`@var`). Пресет несёт собственные DNS-серверы и DNS-правило, которые попадают в конфиг **только когда он активен** — отключил пресет → его `yandex_doh` уходит из `dns.servers`.
- **Типизированные переменные** (в `SelectableRule.vars`): `outbound` (picker outbound-групп), `dns_servers` (picker из `preset.dns_servers[].tag`), плюс существующие `enum`/`text`/`bool`/`number`. Новый флаг `required: bool = true` — для optional переменных в UI появляется пункт "— (default/none)", фрагменты с unresolved `@var` выкидываются целиком при expansion'е.
- **Merge-стратегия bundle-фрагментов** (`lib/services/builder/preset_expand.dart`): identical-skip по tag + first-wins с warning для реальных конфликтов. DNS-rules инжектируются **перед** fallback-правилом template'а, DNS-серверы добавляются после template-baseline. Порядок детерминирован по индексу CustomRule в UI-списке.
- **UI редактора** (`custom_rule_edit_screen.dart`): для `kind: preset` показывается "Based on preset" бэйдж + форма vars + JSON-preview expanded bundle. Match-поля (domain/port/package/ip/protocol) скрыты — содержимое пресета правится только через шаблон. Broken preset (presetId не найден в шаблоне) → error-card с Delete.
- **Russian domains direct** переведён на bundle-формат. Три типизированные переменные:
  - `out` — OutboundPicker, дефолт `direct-out`.
  - `dns_server` — dropdown `yandex_doh`/`yandex_dot`/`yandex_udp`, `required: false`, дефолт `yandex_doh`.
  - `dns_ip` — enum из 10 IP (Safe/Base/Family, IPv4+IPv6 primary+alt) с human-readable `title`; применяется только к UDP.

  Три DNS-сервера в bundle: `yandex_doh` и `yandex_dot` хардкодят `server: "77.88.8.88"` + `tls.server_name: "safe.dot.dns.yandex.net"` (Safe-режим Yandex, bootstrap не нужен — IP напрямую); `yandex_udp` берёт IP из `@dns_ip`. Список TLD: `.ru/.su/.рф/.рус/.москва/.moscow/.tatar/.дети/.онлайн/.сайт/.орг/.ком`.
- **`WizardOption`** — `options` у `WizardVar` расширен с `List<String>` до `List<WizardOption>` с полями `{title, value}`. Legacy-совместимо: строка `"foo"` парсится как `{title: "foo", value: "foo"}`. UI показывает `title`, в `varsValues` / substitution идёт `value`. Нужно для human-readable меток в dropdown'ах пресетных правил (например, `"77.88.8.88 · Safe" → 77.88.8.88`).
- **Broken preset recovery** — если в будущей версии `presetId` удалён/переименован, в UI появляется broken-card "Preset not found" с кнопкой Delete; при сборке правило пропускается + warning в `emitWarnings`.

### Changed — Russian & Cyrillic TLDs expanded
- Wizard template: DNS rule (Yandex DoH) и `ru-domains` rule-set расширены с 4 до 12 суффиксов — добавлены `xn--p1acf` (.рус), `xn--80adxhks` (.москва), `moscow`, `tatar`, `xn--d1acj3b` (.дети), `xn--80aswg` (.сайт), `xn--c1avg` (.орг), `xn--j1aef` (.ком). Пресет «Russian domains direct» теперь описан как "Route Russian & Cyrillic TLDs directly."

---

## [1.4.0] — 2026-04-21

Major release: unified routing rules, local-only SRS, Stats tabs + Top apps, Debug API, VPN reliability overhaul, per-server detour toggles, perf pass, Flutter correctness fixes. Полные заметки — `RELEASE_NOTES.md`, детальные отчёты задач — `docs/spec/tasks/001..009`.

### Added — Unified routing rules model (spec 030)

- **`CustomRule` заменяет 3 параллельных механизма**: `AppRule` (per-package), `SelectableRule` (template пресеты), `CustomRule v1.3.x` (per-rule matcher). Теперь одна модель с полями domain/IP/port/package/protocol/private-IP/srs в одной форме.
- **Один редактор** с табами `Params` / `View`. Params сгруппирован APPS → Source (inline/srs) → MATCH / RULE-SET URL → PORT → PROTOCOL → Delete. Dirty-aware save, unsaved back → «Discard changes?».
- **Reorder** через drag-handle, long-press → Delete с подтверждением.
- **JSON preview** (вкладка View) показывает готовый sing-box фрагмент конфига (rule_set + routing rule) + warnings.
- **Presets → каталог**: вкладка Presets стала read-only каталогом, кнопка «Copy to Rules» клонирует пресет в твой реестр.
- **Миграции one-shot**:
  - `AppRule → CustomRule.packages` (`SettingsStorage._absorbLegacyAppRules` при первом `getCustomRules`).
  - `enabled_rules + rule_outbounds → CustomRule` (`RoutingScreen._migrateLegacyPresets` при первой load'е, флаг `presets_migrated`).
  - Fresh installs получают seed из `template.selectableRules.where(r => r.defaultEnabled)`.
- **`AppRule` и `applyAppRules` удалены** — функциональность через `CustomRule.packages`.

### Added — SRS local-only (spec 011)

- Sing-box больше ничего не качает сам. Ручной download через ☁ в UI, никаких скрытых auto-update / TTL-refetch.
- **Cloud icon states**: ☁ (not cached) / ✅ (cached, green) / ❌ (failed) / spinner. Tap = download/retry.
- **Enable gate** — switch правила disabled пока нет cached файла.
- **Long-press на ☁ в editor** → menu: Refresh SRS / Clear cached file.
- **Cleanup** — Delete rule удаляет cached файл, URL change на save стирает старый кэш.
- `RuleSetDownloader` переписан: id-based API (вместо tag), удалены `maxAge` / `cacheAll` (auto-refresh убран).

### Added — Debug API (spec 031)

- **Локальный HTTP-сервер** для dev-introspection/control (`localhost:9269`). Runtime-toggle в App Settings → Developer (default OFF).
- **Endpoints** (read): `/state`, `/device`, `/clash/*` (proxy с auto-auth), `/logs`, `/config`, `/files/*`, `/ping`.
- **Action endpoints** (triggers): `/action/ping-all`, `/action/ping-node`, `/action/run-urltest`, `/action/switch-node`, `/action/set-group`, `/action/start-vpn`, `/action/stop-vpn`, `/action/rebuild-config`, `/action/refresh-subs`, `/action/download-srs`, `/action/clear-srs`, `/action/toast`.
- **CRUD endpoints** (домнетные мутации): `/rules` (POST/PATCH/DELETE + reorder), `/subs` (POST/PATCH/DELETE + refresh), `/settings` (scoped writes), `/config` override.
- **Middleware pipeline**: `errorMapper → accessLog → hostCheck (127.0.0.1 only) → auth (Bearer token) → timeout → router`. Token генерится на первое включение, хранится в SettingsStorage, показывается с кнопкой Copy (единственный канал передачи).
- **Bind строго на 127.0.0.1** — сеть не достанет, adb-forward обязателен.

### Added — Stats redesign

- **Statistics-экран с табами** `Overview` / `Connections` — больше не нужен отдельный navigate.
- **Карточка Top apps** с иконкой + display name + packageName + byte counters.
- **Карточка By routing rule**.
- **Чип sing-box memory**.
- Refresh каждые 3с, pause в background (см. Performance).

### Added — Template vars UX

- Формы в Settings / Routing перерисованы: label сверху, описание во всю ширину, поле — тоже.
- **`Test URL` / `Test interval` / `Tolerance (ms)`** получили preset-дропдауны с пресетами.
- **URLTest interval default поднят с `1m` до `5m`** под invariant spam-avoidance.
- **Nested sections** в `wizard_template.json` — `sections[].vars[]` с chapter (core/routing/dns). Новые chapter'ы — без правок в Dart.
- **`options` на `type: text`** — combo-dropdown: свободный ввод + suffix-▾ popup с пресетами.

### Added — Auto-update subscriptions toggle

- **Глобальный выключатель** в App Settings → Subscriptions (+ дубль в `SubscriptionsScreen` PopupMenu). Default ON.
- Off → автоматические триггеры (appStart / vpnConnected / periodic / vpnStopped) скипаются; ручное ⟳ работает всегда.
- См. spec 027 §Global toggle.

### Added — Background / Battery UX (spec 022)

- **App Settings → Battery optimization whitelist status** — показывает whitelist-ли наш app.
- **App info (OEM toggles)** с hint-диалогом — направляет на per-app settings страницу, где OEM-специфичные «Autostart», «Background activity», «Battery saver» toggle'ы.
- **Auto-ping after connect** — через 5с после connected пингуем ноды активной группы (default ON, toggle в App Settings).

### Added — Keep-on-exit status sync

- Фикс: при `Keep VPN on exit = true` + swipe из recents + возврат в app UI застревал в Disconnected хотя туннель активен.
- Реализация: `BoxVpnService.Companion.currentStatus: VpnStatus` — `@Volatile` mirror; MethodChannel `getVpnStatus`; `HomeController.init()` pull'ит статус сразу после подписки.

### Added — Clash API reference docs

- Новый `docs/api/clash-api-reference.md` — полный разбор sing-box 1.12.12 Clash API: структура `/proxies`, поля `connections[].metadata` (включая `processPath` с uid-суффиксом, `dnsMode`, `rule`+`rulePayload`, chains ordering), `/group/<tag>/delay` с pitfall'ом "force-urltest не обновляет `.now` персистентно", `/traffic` streaming vs snapshot.

### Added — Per-server detour toggles (UserServer)

- Две новые галки в Node Settings (появляются когда `⚙ ` префикс ON): **Register in VPN groups**, **Register in auto group**. Default обе OFF.
- Detour-сервер по умолчанию скрыт в selector и ✨auto, остаётся доступен только как звено цепочки. Override через явные галки.
- Используется существующий `UserServer.detourPolicy` — никаких новых моделей. Builder детектит `kDetourTagPrefix` в `main.tag`.
- Scope: только UserServer (1 server = 1 node). См. `docs/spec/tasks/006`.

### Added — Revoke UX

- **SnackBar «VPN taken by another app»** с action Start (5 сек) когда другое VPN захватывает туннель. Раньше — пугающая красная пилюля «Revoked by another VPN».
- Chip показывает нейтральный Disconnected. Internal `state.tunnel == revoked` сохраняется для side-effect detection.
- **Unified cleanup**: heartbeat-driven `_onTunnelDead` теперь сбрасывает те же поля что broadcast-driven `_handleStatusEvent` (`_clash=null`, `traffic=zero`, `connectedSince=null`, `configStaleSinceStart=false`).
- См. `docs/spec/tasks/003`.

### Added — Lifecycle resume re-sync

- На `AppLifecycleState.resumed` — one-shot pull `getVpnStatus()` с сравнением; при divergence прогон raw через `_handleStatusEvent`. Покрывает случаи Doze/OOM-kill service в background без broadcast'а.
- Никакого polling'а — event-driven. См. `docs/spec/tasks/004`.

### Added — Reload button (right of status chip)

- **Short tap** — smart default: `Connect` (VPN off) / `Reconnect` (on, clean) / `Rebuild config + reconnect` (on, dirty).
- **Long-press** — меню из 3 действий: `Reconnect`, `Rebuild config only`, `Rebuild config + reconnect`.
- Dirty-подсветка (primary-container фон).
- **Fix**: Flutter `Tooltip` на Android использовал long-press как свой trigger — перехватывал `InkWell.onLongPress`. Tooltip → `Semantics(label: ...)` (accessibility сохранена).

### Added — Blocking `stopVPN` + intent-based reset

- **`BoxVpnService.stopAwait`** возвращает `Deferred<Unit>`, completes в `setStatus(Stopped)`. `VpnPlugin.stopVPN` handler на `pluginScope.launch` + `withTimeout(5s).await`.
- **`_stopInternal` / `_startInternal`** — single-intent примитивы с intent-based reset `configStaleSinceStart=false`. `reconnect()` = композиция обоих, без Dart-side координации.
- См. `docs/spec/tasks/002`.

### Added — Diagnostic logging pipeline

- Полный `[vpn]` prefix logging для VPN lifecycle: `onStartCommand`, `doStop`, `setStatus`, `receiver.onReceive`, `statusReceiver.onReceive` с `sink` флагом, Dart `_handleStatusEvent` / `reconnect` / `saveParsedConfig`.
- `StackTrace.current` в `saveParsedConfig` в `kDebugMode` guard.

### Fixed — VPN reconnect reliability

- **Root cause: sink leak** в `BoxVpnClient.onStatusChanged`. Каждое обращение к getter'у создавало новый `receiveBroadcastStream()` → новый `onListen` на native → перезаписывал shared `statusSink`; следующий `onCancel` обнулял его. Основной `_statusSub` в HomeController становился зомби, все последующие transition events терялись. Фикс — `late final _statusStream` + `asBroadcastStream()`. Заодно починило потерю heartbeat/traffic updates и ревоке-detection после первого reconnect'а. См. `docs/spec/tasks/001`.
- **`TunnelStatus.unknown`** — default для неизвестного raw вместо `disconnected`. Убирает ложные срабатывания `firstWhere(disconnected|revoked)` predicate'ов на мусорных events. UI маппит unknown → Disconnected label.

### Fixed — прочие критичные

- **`ip_is_private` unknown field** — sing-box отклонял конфиг с `ip_is_private` в headless rule. Поле не поддерживается в rule_set inline, работает только на routing-rule level. Перенесено, где per sing-box formula становится OR с `rule_set`.
- **Protocol-only rules skip'ались** — когда в rule только `protocol: [bittorrent]` (без domain/ip_cidr), `match` был пустой → skip. Теперь эмитится routing rule без rule_set, всё работает.
- **AppPicker crashed при parallel tap** — `setState` без `mounted` guard'а + double `Navigator.pop`.

### Fixed — Flutter correctness (P0 code-review fixes)

По результатам глубокого code review (`docs/spec/tasks/008` §A) закрыты три анти-паттерна Flutter в `home_screen.dart`. Это корректность, не оптимизации — затрагивают устойчивость анимации, таймеров и dispose-контракта. Fix в коммите `2593152`, отчёт — `docs/spec/tasks/009`.

- **Side-effects в `build` убраны.** Управление `_connectingAnim.repeat/stop/reset` жило в `_buildStatusChip` (вызывается из `AnimatedBuilder` — т.е. в build-фазе). Hot path из heartbeat (каждые 20с) и mass ping (десятки emit/sec) дёргал контроллер анимации лишний раз. Перенесено в listener `_onControllerChange`, триггерится только при реальной смене tunnel state.
- **`Timer` не создаётся из build.** Auto-dismiss таймер для `lastError` жил в `Builder` внутри build (`if (_errorTimerFor != state.lastError) { cancel + new Timer }`) — хрупко при агрессивных rebuild'ах. Перенесён в тот же listener с явным transition detection через `_prevError`.
- **`HomeScreen.dispose()` теперь полный.** Добавлены `_controller.dispose()` (отменяет `_statusSub`, heartbeat, transient timer), `_subController.dispose()`, `_connectingAnim.dispose()`. Раньше пропускались — production ОС убивала процесс, но hot reload / тесты / смена root widget'а давали бы утечку.

### Performance

- **ConfigCache** в `HomeState`: парсинг outbound JSON (`detourTags` + `protoByTag`) делается один раз при `saveParsedConfig`, не на каждый rebuild ListView. С 50+ нодами и сортировкой по ping — убирает заметный jank в node list hot-path'е.
- **`sortedNodes` memoize** через `late final` — один sort на HomeState instance, не на каждый getter access.
- **Batched `_emit`** в `_handleStatusEvent` — 2-3 последовательных notifyListeners на один status event схлопнуты в один.
- **Single safety-timer** для transient-фазы (Starting/Stopping): переиспользуемый `Timer?` вместо плодящихся `Future.delayed` на каждое transient event.
- **Background-paused timers** в Stats/Connections screens (`WidgetsBindingObserver`): polling Clash API останавливается когда app в background; возобновляется на resume. Экономит battery + method-channel round-trips.
- **Lint cleanup**: unused `dart:typed_data` import, `?proto` null-aware marker, docstring escapes.

См. `docs/spec/tasks/005`.

### Changed — Build: Android 11+ primary, 8.0+ best-effort

- `minSdk = 26` (Android 8.0) в `app/android/app/build.gradle.kts`. Tiered support:
  - **Primary (11+, API 30+)** — тестируется, все фичи, production-ready.
  - **Best-effort (8.0–10, API 26–29)** — compile/install OK, фичи требующие API 30+ деградируют к no-op через runtime SDK_INT check.
  - **Unsupported (<8, API <26)** — install blocked.
- Раньше было `minSdk = flutter.minSdkVersion` = 24 по default'у (факт), в release notes декларировалось 8.0+ (доки). Теперь код соответствует реальному тестированию.

### Changed — прочее

- **`auto-proxy-out` → `✨auto`** — переименование urltest-группы, единая константа `kAutoOutboundTag`. `Icons.speed` в UI.
- **AppPicker lazy icons** — `getInstalledApps` возвращает только metadata (pkg/name/isSystem) за сотни мс, иконки lazy per-tile через `getAppIcon(pkg)` с session-cache. Раньше 500 apps × PNG-compress + base64 = ~10s блокировка UI.
- **Local build speed** — `./scripts/build-local-apk.sh` с `--target-platform android-arm64`: 38 мин → ~1.5 мин. CI продолжает собирать все три (arm + arm64 + x64).
- **Subscription User-Agent** — `LxBox Android subscription client`.

### Refactored

- **Template**: flat `vars: [маркеры + var'ы]` → nested `sections: [{name, chapter, description, vars: [...]}]`. Парсер больше не держит state-переменную «текущая секция». `chapter` на каждой секции (`core` / `routing` / `dns`) позволяет добавлять новые chapter'ы без Dart-правок.
- **Public test servers** manifest вынесен в remote repo — не жжёт bundle.
- `applySelectableRules` удалён — пресеты копируются явно через `selectableRuleToCustom`.
- `AppPickerScreen` — убран editable title (не нужен внутри `CustomRuleEditScreen`).
- `IP Filters` → `Rules` (tab rename).

### Process

- Новая папка **`docs/spec/tasks/`** — журнал выполненных задач с развёрнутыми отчётами (проблема → диагностика → решение → риски → верификация → follow-up). 8 задач в 1.4.0 (001–008). README с форматом.
- **Peer review** получен от внешнего агента ([007](docs/spec/tasks/007-peer-review-tasks-001-006.md)) — отловлен критичный bug в task 006 (`persistSources()` не вызывался после per-node toggle'ов — настройки терялись после рестарта app'а). Закрыто в `e0e7213`.
- **Deep code review** ([008](docs/spec/tasks/008-deep-code-review-perf-refactor.md)) — независимая оценка состояния кода после 001-007, кандидаты на будущий рефакторинг.

---

---

## [1.3.1] — 2026-04-19

### Fixed — `UserServer.fromJson` теряла `nodes`
- `toJson` хранит только `rawBody`, но `fromJson` не парсил его обратно — после рестарта app узлы UserServer пропадали → `NodeSettingsScreen._load()` видел пустой `nodes` → бесконечный спиннер.
- Теперь `fromJson` зовёт `parseAll(decode(rawBody))` для восстановления nodes. `rawBody` остаётся источником истины, nodes — derivable.

### Fixed — Detour dropdown в Node Settings не сохранялся
- Раньше писал `detour` в JSON ноды через `_jsonCtrl`, но `parseSingboxEntry` это поле не восстанавливает → save → reparse → detour терялся.
- Теперь сохраняется в `entry.detourPolicy.overrideDetour` (которое builder уже умеет применять). `persistSources()` сразу при выборе в dropdown'е, без отдельного Save.

### Fixed — XHTTP warning перекрывался TLS-insecure
- `node.warnings.first` бралось безусловно, и `InsecureTlsWarning` (parse-time) затмевал `UnsupportedTransportWarning('xhttp')` (emit-time).
- Теперь `_NodeWarningRow` сортирует по severity (error → warning → info), показывает первый по приоритету. XHTTP-fallback отображается оранжевым, TLS-insecure — серым (info severity).
- TLS-insecure понижен до `info`: провайдеры часто намеренно ставят флаг (REALITY, IP-литералы, self-signed). Banner вверху detail-экрана теперь считает только actionable warning'и.

### Added — Auto-regenerate config после `addFromInput`
- Раньше после paste/QR/file подписки/нода — нужно было вручную нажать ⟳ для применения. Теперь после успешного `addFromInput` автоматом `generateConfig` + `saveParsedConfig` + snackbar `Config regenerated: N nodes`.

### Added — Empty `+` button = paste from clipboard
- Если поле ввода пустое и пользователь жмёт `+` — открывается поток `paste-from-clipboard` (анализ типа + диалог подтверждения). Без поля — экономит шаг.

### Added — Editable Tag field в `NodeSettingsScreen`
- Отдельное поле `Tag` под секцией `Server` (раньше тег был зашит в JSON-редакторе и неудобно правился).
- AppBar title обновляется live при редактировании.
- На save идёт в `tag` outbound JSON-а.

### Added — "Mark as detour server" switch
- Toggle в `NodeSettingsScreen` — добавляет/убирает префикс `⚙ ` к tag'у. Префикс хранится в самом tag'е (никаких отдельных флагов в JSON), визуально отделяет detour-серверы в списках и в Override-detour picker'е.

### Added — Long-press → "Copy URI"
- Ранее long-press по ноде на главном давал только `Copy server (JSON)`. Теперь есть `Copy URI` — оригинальный `vless://` / `wireguard://` / etc через `node.toUri()` (round-trip parser v2). Для control-узлов (`direct-out`, `auto-proxy-out`) показывает snackbar "No source URI for this node".
- `Copy server` переименован в `Copy server (JSON)` для ясности.

### Added — Subtitle на главном: `[ACTIVE] [PROTOCOL]   [50MS →]`
- ACTIVE — зелёный pill (вместо текстовой "ACTIVE · 50MS"), протокол слева серым, ping справа цветом по latency.
- Протокол берётся из outbound JSON: `VLESS`, `Hy2`, `WG`, `TUIC`, `SS` etc. TLS-суффикс убран — у большинства протоколов TLS дефолт, метить каждый = шум.
- Для `auto-proxy-out` (urltest) показывает proto **выбранной** ноды: `→ BL: Frankfurt   VLESS`.

### Changed — `UserServers` → `UserServer` (rename)
- Названо во множественном числе исторически, но всегда ровно один node (paste/QR/file/manual). Sealed-класс переименован в singular для ясности. JSON discriminator `'type': 'user'` сохранён — миграции не нужны.
- 10 файлов затронуто (1 модель, 2 контроллера, 4 экрана, 4 теста, миграция).

### Changed — Subtitle для UserServer: `WIREGUARD server` / `VLESS server`
- Раньше: разные строки в зависимости от формы импорта (`WireGuard config` / `Direct link` / `JSON outbound`) — описывало форму копипасты, не суть. После рестарта (когда `entry.status` теряется) показывало "1 node" — бессмысленно для single-node entries.
- Теперь единообразно: `<PROTOCOL> server` для любых UserServer независимо от формы добавления.

---

## [1.3.0] — 2026-04-19

### Added — Subscription auto-update (spec 027)
- **4 триггера** автообновления подписок: app start, через 2 мин после VPN connected, periodic 1 час, сразу по VPN disconnected. Manual refresh (⟳) — пятый, force.
- **Жёсткие gates** против спама: `minRetryInterval=15min` (per-subscription, переживает рестарт через persisted `lastUpdateAttempt`), `maxFailsPerSession=5` (in-memory, размораживается при рестарте app), `perSubscriptionDelay=10s ± 2s jitter` между подписками внутри прохода, `_running`/`_inFlight` dedup-флаги, `lastUpdateStatus==inProgress` guard защищает от двойных кликов.
- **Crash-safe init sweep**: при старте app залипший `inProgress` (после `kill -9`) сбрасывается в `failed`, fetch возможен после 15-min cooldown.
- **Persisted state** в `server_lists.json`: `lastUpdated`, `lastUpdateAttempt`, `lastUpdateStatus` (`never`/`ok`/`failed`/`inProgress`), `consecutiveFails`.
- **UI в строках подписок** (Servers): `124 nodes · 🔄 24h · 🕐 3h ago · (2 fails)` — interval, время с последнего успеха, счётчик подряд-фейлов (красным).
- **Subscription block в detail screen** (Settings tab): URL (tap=copy), Update interval (picker `[1, 3, 6, 12, 24, 48, 72, 168]h`), Status row с иконкой + last success/attempt/node count, Refresh now кнопка.
- Manual refresh "Update all" → роутинг через `AutoUpdater.maybeUpdateAll(manual, force:true)` с `resetAllFailCounts()`. Per-entry ⟳ → прямой `_fetchEntryByRef` + `resetFailCount(url)` (размораживает подписку из session-cap).
- **Rebuild config (⟳ на Home) НЕ триггерит HTTP** — только локальная сборка из уже-загруженных nodes.

### Added — Restart warning sticky flag (spec 003 §8a)
- Розовая плашка **«Config changed — restart VPN to apply»** под кнопкой Stop теперь показывается надёжно при любом сценарии: routing Apply, settings change, debug import, manual rebuild. Раньше пропадала при отмене Stop-диалога.
- Реализация: derived getter `_needsRestart` поверх sticky-флага `state.configStaleSinceStart` в `HomeState`. Флаг ставится в `saveParsedConfig` при `tunnelUp`, сбрасывается **только** на реальном tunnel transition (connected ↔ disconnected/revoked).

### Added — AntiDPI: Mixed-case SNI (spec 028)
- Toggle **Mixed-case SNI** в Settings → DPI Bypass. Рандомизирует регистр букв в `server_name` (`WwW.gOoGle.CoM`). По RFC 6066 SNI case-insensitive — сервер обязан принять любой регистр; ломает наивный exact-match DPI у региональных провайдеров и корпоративных firewall'ов.
- First-hop only (консистентно с TLS Fragment), per-outbound независимая рандомизация. Punycode-метки (`xn--…`) не трогаем (сохраняем DNS-валидность).
- Help-текст честный: «Bypasses simple exact-match DPI; ineffective against GFW-class filtering». Default off.
- 10 unit-тестов: RFC compliance, IP-литералы, punycode, detour skip, independent randomization.

### Added — Haptic feedback on VPN events (spec 029)
- Toggle **Haptic feedback** в App Settings → Feedback (default **on**). Уважает системную настройку Android Touch feedback.
- Маппинг событий: tap Start/Stop → лёгкий tick; VPN connected → средний impact; user disconnect → лёгкий impact; revoked / heartbeat fail → тяжёлый impact (heartbeat-fail только **первый раз**, не на каждый tick); manual subscription fetch success → лёгкий, fail → средний.
- Auto/periodic события (subscription auto-update, ping, scroll) — **не** триггерят haptic.
- Throttle 100мс между импульсами защищает от спама.

### Added — Subscription title fallback via `Content-Disposition`
- Если у подписки нет `profile-title` header, имя берётся из `Content-Disposition: filename=...`. Поддержка quoted/unquoted filename и RFC 5987 `filename*=UTF-8''<percent-encoded>`. Стрипает `.txt`/`.yaml`/`.yml`/`.json`/`.conf` расширения.

### Changed — Subscription User-Agent
- HTTP к подпискам теперь идёт с UA `LxBox Android subscription client` (был `SubscriptionParserClient`). Если провайдер начнёт отдавать default response без `subscription-userinfo` headers — откатывайте.

### Changed — DNS rules: inline `.ru` domain_suffix
- DNS правило для Yandex DoH теперь содержит `domain_suffix: [ru, xn--p1ai, su]` напрямую, вместо `rule_set: ru-domains` reference. Поведение идентичное; читается прозрачнее в DNS settings UI.
- `route.rule_set.ru-domains` остаётся (используется selectable rule "Russian domains direct").

### Added — Local build marker
- Скрипт `scripts/build-local-apk.sh` собирает APK с `--dart-define`'ами `BUILD_LOCAL=true`, `BUILD_GIT_DESC`, `BUILD_LAST_TAG`, `BUILD_COMMITS_SINCE_TAG`, `BUILD_TIME`.
- В About screen появляется розовая плашка «🧪 LOCAL BUILD · 7 commits since v1.2.0» с git describe и временем сборки. CI builds (через `flutter build` напрямую) не помечаются.

### Added / Removed — Parser v2 (internal rewrite, спека 026, все 5 фаз)
- Типизированная sealed-иерархия `NodeSpec` (9 протоколов: VLESS, VMess, Trojan, Shadowsocks, Hysteria2, **TUIC v5 (новый)**, SSH, SOCKS, WireGuard).
- Полиморфный `emit(vars)`: WireGuard → Endpoint, остальные → Outbound, без рантайм-проверок типа.
- Round-trip `parseUri(spec.toUri()) ≈ spec` с тестами для каждого варианта.
- XHTTP fallback через sealed `TransportSpec` — компилятор не даёт забыть.
- `ServerList` (sealed: `SubscriptionServers` / `UserServers`) — заменяет плоский `ProxySource`. Одноразовая миграция `proxy_sources` → `server_lists` при первом чтении `SettingsStorage`.
- Функциональный pipeline: `parseFromSource(SubscriptionSource) → ServerRegistry → buildConfig(...) → BuildResult(config, ValidationResult, warnings)`.
- `ValidationResult` с типизированными `ValidationIssue`: dangling outbound refs, empty urltest, invalid selector default.
- **Удалено**: `lib/services/node_parser.dart` (~1100 LOC), `config_builder.dart` (~550), `source_loader.dart`, `subscription_fetcher.dart`, `subscription_decoder.dart`, `xray_json_parser.dart`, `models/parsed_node.dart`, `models/proxy_source.dart`. `SubscriptionController` и `SettingsStorage` переведены на v2.
- 103 теста в v2-юните (models, parser, round-trip, builder, validator, migration, subscription pipeline, e2e). Debug + release APK собираются.

### Added — TLS Fragment (DPI bypass)
- **TLS Fragment**: фрагментация TLS ClientHello для обхода DPI. Record fragment support.
- Настраивается в VPN Settings.

### Added — WireGuard Endpoint Support
- **WireGuard endpoint**: поддержка WireGuard endpoint в подписках (не outbound).
- **WireGuard INI auto-detection**: автоматическое определение INI-формата WireGuard конфигов при импорте.

### Added — JSON Outbound Import
- **Paste dialog**: вставка JSON outbound через диалог (Smart Paste). Автоопределение формата.

### Added — Node Settings Screen
- **Node Settings**: экран с JSON-редактором outbound'а и dropdown для выбора detour.

### Added — Per-Subscription Settings
- **Register / Use / Override**: настройки detour-серверов на уровне подписки.
- Register — зарегистрировать detour-серверы из подписки.
- Use — использовать detour-серверы для нод этой подписки.
- Override — принудительно назначить detour для всех нод подписки.

### Added — Detour Server Naming
- **⚙ prefix**: detour-серверы отображаются с префиксом ⚙ вместо `_jump_server`.

### Added — Tune Button
- **Tune button**: кнопка для управления видимостью detour-серверов в списке нод.

### Changed — UX (since v1.1.1)
- **Servers**: «Subscriptions» переименовано в «Servers».
- **Speed test**: 10 серверов, upload через PUT.
- **Connections screen**: отображение process/app name.
- **Animated VPN status chip**: анимированный индикатор статуса VPN.
- **Copy menu**: server/detour/both; detour убран из копирования по умолчанию.
- **Settings with sections**: настройки разбиты на секции.
- **Compact + button**: компактная кнопка добавления, smart paste dialog.
- **Ping timeout**: увеличен до 10 секунд.

## [1.2.0] — 2026-04-18

### Changed — Outbound groups overhaul
- Переименование: **proxy-out → vpn-1**, добавлен **vpn-3** (VPN ①/②/③).
- **VPN ①** всегда генерируется, галочка заблокирована.
- **auto-proxy-out** теперь управляется галочкой **Include Auto**: при включении генерируется как urltest и добавляется в `vpn-*`; при выключении секция не создаётся вовсе.

### Changed — Node list UX
- **direct-out** и **auto-proxy-out** всегда вверху списка (в любом режиме сортировки, сначала direct, потом auto), с лёгкой подсветкой.
- Контекстное меню (long-press):
  - Copy-действия скрыты для `direct-out` / `auto-proxy-out`.
  - *Copy detour* и *Copy server + detour* скрыты, если у ноды нет detour.

### Changed — Defaults
- `urltest_tolerance` по умолчанию 30 ms (было 100).

---

## [1.1.1] — Previous release

### Added — Native VPN Service (Feature 013)
- **Удалён плагин `flutter_singbox_vpn`**: вся нативная логика перенесена напрямую в `android/app/`.
- Новый пакет `com.leadaxe.lxbox.vpn`: VpnPlugin, BoxVpnService, ConfigManager, ServiceNotification, PlatformInterfaceWrapper, DefaultNetworkMonitor/Listener.
- **Конфиг в файле**: хранение в `files/singbox_config.json` вместо SharedPreferences.
- **BoxVpnClient** Dart-обёртка с MethodChannel/EventChannel — идентичный API.
- Убраны неиспользуемые компоненты: TileService, BootReceiver, ProxyService, per-app tunneling, traffic EventChannel.

### Added — Subscription Detail View (Feature 014)
- **Тап по подписке** → полноэкранный detail screen с метаинформацией (URL, дата обновления, кол-во нод).
- **Список нод**: загружается при открытии через SourceLoader, отображается с иконками протоколов.
- **Inline rename**: кнопка Edit в AppBar → TextField для переименования.
- **Delete с подтверждением**: кнопка Delete → confirm dialog → удаление + pop.
- **Refresh**: кнопка обновления нод прямо из detail screen.
- Убраны: swipe-to-delete и long press bottom sheet на основном списке.

### Added — Rule Outbound Selection (Feature 015)
- **Дропдаун outbound** рядом с каждым routing rule (direct/proxy/auto/vpn-1/vpn-2).
- Варианты динамически зависят от включённых proxy groups.
- Action-based правила (Block Ads) — без дропдауна.
- **Route final**: настройка fallback outbound для неизвестного трафика.
- Backend уже был реализован ранее (SettingsStorage + ConfigBuilder).

### Added — Routing Screen (Feature 016)
- **Отдельный экран Routing**: Proxy Groups + Routing Rules + outbound dropdowns + route.final.
- **Settings упрощён**: остались только технические переменные (log level, Clash API, DNS и т.д.).
- Routing добавлен в drawer навигации.
- Long-press на заголовке Nodes теперь ведёт на Routing вместо Settings.

### Added — App Routing Rules (Feature 017)
- **App Rules**: именованные группы приложений с выбором outbound (direct/proxy/vpn-X).
- Каждое правило генерирует sing-box routing rule с `package_name`.
- **AppPickerScreen**: выбор приложений с иконками, поиск, select all, invert, clipboard import/export, show/hide system apps.
- `QUERY_ALL_PACKAGES` permission для полного списка приложений на Android 11+.

### Added — App Settings
- **Отдельный экран App Settings**: выбор темы (Light / Dark / System).
- ThemeNotifier с персистентностью через SharedPreferences.
- Drawer: разделены "VPN Settings" (config vars) и "App Settings" (тема).

### Changed — UX Improvements
- **Start/Stop** — одна toggle кнопка вместо двух (зелёный Start / красный Stop).
- **Get Free VPN** перенесён из главного экрана в Subscriptions (empty state).
- **Mass Ping** — 20 параллельных пингов (было последовательно), сброс результатов при старте.
- **Clash API**: рандомный порт (49152-65535) вместо 9090, секрет автогенерируется если пустой.
- **Secret поля**: кнопка-глаз для toggle видимости.
- **Portrait lock**: экран не поворачивается.
- **Diagnostic snackbar**: показывает причину ошибки при неудачном Start.
- **Empty config guard**: кнопка Start disabled если нет конфига.

### Fixed
- Outbound tag desync: `_makeUnique` менял `node.tag` но не `outbound['tag']` → дубли тегов при одинаковых именах нод.
- `ACCESS_NETWORK_STATE` permission для DefaultNetworkMonitor.
- `QUERY_ALL_PACKAGES` для полного списка приложений.
- libbox 1.12.12 API: `LocalResolver` с `ExchangeContext`, `writeLog` override.
- `serviceScope` вместо `GlobalScope` — structured concurrency, нет orphaned coroutines.
- `startForeground` перед `stopSelf` в error paths.
- TextEditingController leak в Settings (создавался в build без dispose).

### Added — Connections Screen
- **Тап на traffic bar** → живой список активных соединений (destination, chain, network, duration, traffic).
- Закрытие отдельного соединения или всех.
- Автообновление каждые 2 секунды.

### Added — Ping Settings
- **Long press на кнопку пинга** → bottom sheet: test URL, timeout (ms).
- Настройки передаются в Clash API delay.

### Added — Config Editor Improvements
- Popup menu (3 точки): Paste from clipboard, Load from file, Copy, Share.
- Drawer упрощён: Config Editor — один пункт вместо expansion tile.

### Added — Subscription Metadata Display
- **Traffic bar** в detail screen: upload/download/total (progress bar + текст).
- **Expire date**: "N days left" или "Expired".
- **Support chip**: иконка телеграма для t.me, help для остальных. Tap → copy URL.
- **Web page chip**: ссылка на страницу подписки.
- **Support icon** в списке подписок рядом с node count.

### Changed — UX
- **Sort icons**: уникальная иконка для каждого режима (Ping↑, Ping↓, A→Z, Z→A, Default).
- **Z→A сортировка** добавлена.
- **Stop button**: одинаковый стиль с Start (без красного).
- **Rebuild config button** на главном экране.
- **URLTest** убран из dropdown групп, показывает `→ auto-selected` в subtitle.
- **Routing rules layout**: title + dropdown на одной строке, subtitle full width.
- **SRS indicator**: иконка облака для правил с remote rule sets.
- **App Groups**: переименовано из App Rules, название редактируется в picker'е.
- **App picker**: мгновенное открытие с прелоадером (addPostFrameCallback).

### Fixed — VPN Revoke Handling
- **onRevoke** шлёт Stopped + error мгновенно (не через doStop).
- **doStop** разрешён из любого состояния (было только Started).
- **10с таймаут**: если зависли на Stopping/Connecting — принудительный disconnect.

### Fixed — Wizard template TUN inbound
- **`inbounds` больше не пустой**: обязательный `tun` inbound (`tag: tun-in`), `auto_route`, MTU, `stack`.
- **Совместимость с рабочими libbox-конфигами**: `address` — одна строка CIDR (не массив), по умолчанию `172.16.0.1/30`; MTU **1492**; `strict_route` по умолчанию **false** (true часто ломает трафик на Android).
- **DNS**: сервер `cloudflare_udp` (1.1.1.1:53), `route.default_domain_resolver` по умолчанию `cloudflare_udp`.
- **Маршрутизация**: перед `hijack-dns` добавлены `resolve` и `sniff` для `inbound: tun-in` (как в конфигах, собранных лаунчером).
- Переменные: `tun_address`, `tun_mtu`, `tun_auto_route`, `tun_strict_route`, `tun_stack`.

### Added — Xray JSON Array + Chained Proxy (Feature 012)
- **XrayJsonParser**: парсинг подписок в формате JSON-массив полных Xray/v2ray конфигов (protocol/vnext/streamSettings → sing-box outbound). Автоматическое определение формата.
- **Chained proxy (Jump)**: поддержка `dialerProxy` / `sockopt.dialer` — SOCKS/VLESS jump-серверы. Генерация отдельного jump outbound + `detour` в основном outbound.
- **ParsedJump** модель + поле `jump` в ParsedNode.
- Reality TLS, transport (ws/grpc/http), tag slug из `remarks` с emoji-флагами.

### Added — Subscription & Config Pipeline
- **Subscription Parser** (Feature 004): полный порт парсера подписок из singbox-launcher (Go → Dart). Поддержка форматов: Base64 (standard, URL-safe, padded/unpadded), Xray JSON array, plain text. Протоколы: VLESS, VMess, Trojan, Shadowsocks, Hysteria2, SSH, SOCKS, WireGuard.
- **Config Generator** (Feature 005): wizard template + user vars + parsed nodes → sing-box JSON. 3-pass outbound generation: node outbounds, selector/urltest groups с regex-фильтрами, selectable routing rules.
- **Wizard Template** (`assets/wizard_template.json`): встроенный шаблон конфига с переменными (`@log_level`, `@clash_api`, etc.), outbound-группами (proxy-out, auto-proxy-out, ru VPN) и selectable routing rules (Block Ads, Russian domains direct, BitTorrent direct, Games direct, Private IPs direct).
- **Settings Storage** (`lxbox_settings.json`): persistent хранилище через `path_provider` для user vars, proxy sources, enabled rules, last update timestamp.

### Added — Subscription & Settings UI (Feature 006)
- **Subscriptions Screen**: добавление подписок по URL или direct link, отображение списка с node count и статусом, swipe-to-delete, кнопки "Update All & Generate" и "Generate Config".
- **Settings Screen**: редактирование wizard vars (log level, Clash API, DNS strategy, etc.), вкл/выкл selectable routing rules, кнопка Apply с автоматической перегенерацией конфига.
- **Drawer Integration**: пункты Subscriptions и Settings в навигационном drawer главного экрана.

### Added — Config Editor (Feature 007)
- Pretty JSON display: конфиг в редакторе отображается с 2-space indentation. Сохранение в compact JSON для sing-box.

### Added — Ping & Node Management (Feature 008)
- **Mass Ping**: кнопка рядом с селектором группы запускает последовательный пинг всех нод. Иконка меняется на Stop — отмена в любой момент. Epoch-based guard против race condition.
- **Расширенное Long-press меню** на ноде: Ping, Use this node, Copy name.
- **Цветовая индикация задержки**: зелёный (<200ms), оранжевый (<500ms), красный (>500ms / ошибка).

### Added — Dark Theme & UX (Feature 009)
- **Dark Theme**: `ThemeMode.system` — автоматическое переключение по системным настройкам.
- **Node Sorting**: циклическое переключение Default → Latency ↑ → Latency ↓ → Name A→Z. Кнопка в заголовке Nodes.
- **Pull-to-refresh** на списке нод (RefreshIndicator → reloadProxies).
- **Node count** в заголовке Nodes.
- **Reload groups** перемещён в строку заголовка Nodes.
- **Long-press на заголовке Nodes** → быстрый переход в Settings.

### Added — Quick Start / Get Free VPN (Feature 010)
- **Get Free preset** (`assets/get_free.json`): встроенный пресет с двумя бесплатными подписками (@igareck) и рекомендованными правилами роутинга.
- **Quick Start card** на главном экране: появляется при отсутствии конфига и подписок. Один тап → загрузка пресета → fetch подписок → генерация конфига → готово к запуску.

### Added — Auto-refresh Subscriptions
- При нажатии Start проверяется `parser.reload` интервал (по умолчанию 12h). Если прошло достаточно времени — автоматическое обновление подписок и перегенерация конфига перед запуском VPN.
- Парсинг Go-style duration (`"12h"`, `"4h"`, `"30m"`).

### Added — Subscription Metadata
- Поля `name`, `lastUpdated`, `lastNodeCount` в ProxySource с persistent-сериализацией.
- Умный `displayName`: имя → hostname из URL → raw URL.
- Отображение "2h ago", "just now" в списке подписок.

### Added — Traffic Stats & Connection Info
- **Traffic bar** на главном экране: upload/download total, количество активных соединений, uptime (время с момента подключения).
- Heartbeat теперь запрашивает `/connections` вместо `/version` (двойное назначение: мониторинг + статистика).

### Added — Subscription Editing
- **Long-press** на подписке → bottom sheet: переименование и удаление.
- `renameAt()`, `moveEntry()` в SubscriptionController для управления порядком.

### Added — App Lifecycle
- `WidgetsBindingObserver` на HomeScreen: при возврате из фона немедленная проверка heartbeat для быстрого обнаружения revoke.

### Added — Config Export
- Кнопка Share в Config Editor → экспорт JSON через system share sheet (share_plus, XFile temp).
- Кнопка Share в Debug Screen → экспорт логов в .log файл.

### Added — Stop Confirmation
- Диалог подтверждения перед Stop VPN если > 3 активных соединений.

### Added — About Screen
- Версия, ссылки на репозиторий и sing-box, кредиты, tech stack.

### Improved — Empty States
- Контекстные placeholder-ы с иконками: нет конфига, нет нод в группе, VPN не запущен.

### Added — Local Rule Set Cache (Feature 011)
- **RuleSetDownloader**: при генерации конфига все remote `.srs` rule sets (ads, ru-domains и др.) скачиваются в `<app_dir>/rule_sets/` и подставляются как `"type": "local"` в конфиг. Повторная загрузка только по истечении `parser.reload` интервала.
- Ускорение первого запуска: sing-box не ждёт скачивания rule sets — всё уже на диске.
- Graceful fallback: при ошибке скачивания запись остаётся `"type": "remote"`.

### Changed — Preset Groups (replaces Outbound Constructor)
- **Outbound constructor удалён**: regex-фильтры, per-source outbound configs, skip rules — всё убрано.
- **Preset groups**: фиксированные группы `auto-proxy-out`, `proxy-out`, `vpn-1`, `vpn-2` определены в `wizard_template.json`.
- Все ноды подписок идут в каждую включённую группу — без фильтрации.
- **ProxySource упрощён**: удалены `skip`, `outbounds`, `tagMask`, `tagPostfix`, `excludeFromGlobal`.
- **Settings**: новая секция «Proxy Groups» для включения/отключения пресетных групп.
- Чистое сокращение: -139 строк кода.

### Changed — Spec Structure
- Миграция `docs/spec/tasks/` в `docs/spec/features/` (tasks.md внутри каждой фичи).
- Удалена отдельная папка задач.

---

## [1.0.0] — MVP

### Added
- Flutter-приложение L×Box — Start/Stop VPN через libbox.
- Импорт конфига: чтение из файла, вставка из буфера обмена, JSON-редактор.
- JSON5/JSONC поддержка (комментарии в конфигах).
- Clash API: выбор группы (Selector/URLTest), список узлов, переключение, одиночный ping.
- Debug-экран: последние 100 событий.
- CI: GitHub Actions (analyze + test, optional APK build).
- Android release signing (keystore bootstrap scripts).
