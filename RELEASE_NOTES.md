# L×Box v1.9.0

Большой UX-релиз главного экрана: фильтры списка нод, ручная сортировка drag-and-drop, опции pinning, режим append для detour, исправление data-loss бага у Xiaomi/HyperOS юзеров.

**Кому актуально**: всем. Главный экран существенно меняется — node list получает 4 новые секции UI; режим `Override` в подписках переименован и default behaviour поменяно.

**Quick links:**
[🎯 Highlights](#-highlights) ·
[🆕 New features](#-new-features) ·
[🔧 Behavior changes](#-behavior-changes) ·
[🐛 Fixes](#-fixes) ·
[🛠 Tools / internals](#-tools--internals) ·
[🔬 Verified](#-verified) ·
[📲 Install](#-install) ·
[🇷🇺 На русском](#-lxbox-v190-на-русском)

---

## 🎯 Highlights

- **Node list filters** (§048): regex / emoji / protocol / subscription / test (ping) — все собрано в один collapse-panel под иконкой `Icons.tune` справа от sort.
- **Manual node reorder** (§071): long-press за левый край ноды → ⠿ drag mode + custom order сохраняется до конца сессии.
- **Sort options menu** (§070): long-press на иконку sort'а открывает bottom sheet с тремя toggle'ами — pin DIRECT, pin AUTO, re-sort on manual ping.
- **Add server wizard** (§074): long-press на «+» в Subscriptions → full-screen wizard с 3 tabs (SOCKS5 form / Paste URI / Paste JSON). Default values для local SOCKS5 (`127.0.0.1:1080`) подходят для locally hosted proxy / DPI bypass tooling.
- **Subscription detour: `Add detour` mode** (§073) — раньше `Override` полностью заменял родную detour-цепочку. Теперь default = append (chain + новый exit), а replace доступен через checkbox.
- **Settings & config lifecycle унификация** (§076) — единый home banner для restart UX, lazy rebuild на возврат из editing screens, mtime-based bootstrap после kill, global NavigatorObserver покрывает все навигационные пути. **1 settings write + 1 config write per editing session** (раньше до 10 writes на rapid toggle'ах).
- **Data loss fix для Xiaomi/HyperOS** (§072) — раз в пару дней у юзеров `lxbox_settings.json` обнулялся. Fixed через atomic write + `.bak` recovery.

---

## 🆕 New features

### §048 — Home node filters

[Feature spec](docs/spec/features/048%20home-node-filters/spec.md).

На главной у списка нод появилась icon-кнопка `Icons.tune` справа в header. Tap → expand toggle для filter panel (раньше была popup с одним пунктом «Show detour servers» — теперь полноценная панель).

В панели:

- **Regex** text field с двумя toggle:
  - Левый Checkbox — on/off filter, не теряя pattern (auto-on при вводе валидного pattern).
  - `[!]` суффикс — invert/NOT: `!regex.hasMatch(tag)`. OR-семантика alternations сохраняется как `!(a|b)`.
  - Debounce 300ms, invalid pattern → red `Invalid regex` hint.
- **Emoji chips** в горизонтальной полоске — extracted из всех tags (включая detour), отсортированы по частоте + alphabetical tiebreak. Tap chip → emoji appended в regex field как OR-pattern (`🇷🇺` потом `🇺🇸` → `🇷🇺|🇺🇸`).
- **Protocol chips** (multi-select FilterChip, horizontal scroll) — unique protocols из current pool (vless / vmess / trojan / shadowsocks / hysteria2 / ...).
- **Subscription chips** (multi-select) — display names enabled подписок с непустым `nodes` + special «Custom» для UserServer'ов.
- **Test ≤ N ms** numeric input с собственным checkbox — debounced 300ms; untested nodes (`delay==null`) всегда matching.
- **Show detour servers** checkbox (переехал из popup).
- **Show non-matching (dimmed)** checkbox (default ON) — non-matching ноды рендерятся внизу с opacity 0.4.

Двухфазная модель: detour show/hide — pool filter (caller), regex/protocol/subscription/test — match filter (`NodeFilter.passes`). All filters AND-combine. Per-session in-memory state. `Icons.tune` подсвечивается primary color когда любой match-filter активен.

+27 unit tests на `NodeFilter` (extractEmojis с RIS flag pairs, invert ON/OFF, AND combine, untested ping passes).

### §074 — Add server wizard

[Feature spec](docs/spec/features/074%20add-server-wizard/spec.md).

Long-press на «+» IconButton в Subscriptions screen → full-screen route с 3 tabs:

- **SOCKS5 form** — структурированная форма для locally hosted SOCKS5 (DPI bypass tooling и другой local proxy). Defaults: tag `local-socks5-out`, host `127.0.0.1`, port `1080`. Username / password / display name optional. Display name отображается как entry title в Subscriptions list (persisted в `UserServer.name`). Constructs `SocksSpec` напрямую + persisted **как sing-box outbound JSON** — иначе URI fragment round-trip ломает tag (parser derive'ит tag из label-fragment'а).
- **Paste URI** — multiline text area для `vless://…` / `vmess://…` / `trojan://…` / `socks5://…` / `wireguard://…` etc. Routes через тот же `addFromInput` что и tap-«+».
- **Paste JSON** — multiline outbound JSON. Single object или array of outbounds. WireGuard auto-routes в `endpoints[]` через builder pipeline.

Tab switch сохраняет поля. Cancel + Add buttons в AppBar. Открывается двумя путями: long-press на «+» (accidental discovery) или «Add server…» в overflow menu (три точки в AppBar — explicit affordance).

### §068 — `NodeViewItem` view-model class extracted

[Task spec](docs/spec/tasks/068-node-view-item-extract.md).

`NodeRow` widget принимал 14+ explicit args через конструктор. С добавлением `matches:bool` для §048 это разрослось — extract `NodeViewItem` immutable class. `NodeRow(item: NodeViewItem, ...callbacks)`. `Opacity(opacity: item.matches ? 1.0 : 0.4)` wrapper внутри `NodeRow.build` — single source of opacity, magic constant не утекает в caller.

### §070 — Sort options long-press menu

[Feature spec](docs/spec/features/070%20sort-options/spec.md).

У sort button в node header добавлен long-press → bottom sheet (тот же pattern что у ping settings — long-press на ping icon у ноды). 3 Material Checkbox toggle'а:

- **Pin DIRECT to top** (default ON).
- **Pin AUTO to top** (default ON).
- **Re-sort on manual ping** (default ON, было implicit поведение).

Pin теперь работает во всех modes включая `↕ Default`: pinned section сверху + остальное в pristine config order. До §070 в Default mode pin игнорировался — это исправили после first APK feedback.

«Re-sort on manual ping = OFF» → manual single-node URLtest обновляет число, но ряд **не прыгает**. Mass URLtest / group switch / config rebuild сбрасывают frozen sort через `pingBatchGen` counter — re-sort после batch финиша.

**Yellow dot indicator** появляется на sort button когда хотя бы одна из 3 опций non-default.

Sheet остаётся открытым → можно тоггать несколько опций подряд без re-open.

### §071 — Manual node reorder via drag

[Feature spec](docs/spec/features/071%20manual-node-reorder/spec.md).

Четвёртое значение `NodeSortMode.manual` (icon `⠿ Icons.drag_indicator`), активируется **только** через drag, не через cycle. Tap по sort cycle'ит `↕ Default → 📶 Ping → Aa↓ A-Z → ↕` (обходит manual).

Drag-handle: **8% от ширины ряда, transparent strip слева** (Stack + Positioned overlay поверх NodeRow). Текст и иконки внутри NodeRow не сдвигаются. Long-press на strip + drag начинает reorder (`ReorderableDelayedDragStartListener` — иначе vertical drag конфликтует с Scrollable gesture arena).

После drop → mode переключается в `manual`, `manualOrder` сохраняется (per-session in-memory). Pinned section (direct / auto если pin ON) — non-draggable; drop в pinned зону клампится под pinned.

Exit: короткий tap по sort-кнопке → cycle переходит в `↕ default`, `manualOrder` **сбрасывается**. Снова drag → manual mode re-enter с fresh порядком. Новые ноды (subscription update / add server) → в конец manual order. Удалённые — автоматически отфильтрованы.

+18 unit tests (cycle exit, pin toggles, manual order applied, новые в конец, удалённые отфильтрованы, defaultOrder pin).

### §069 — Current session allowBypass tracking + Stats warning

[Task spec](docs/spec/tasks/069-current-session-allow-bypass.md).

Incident 2026-06-05: юзер уверял что `allow_bypass` toggle off, но runtime applied значение было `true` (backup restore set'нул persisted=true, юзер не открывал Settings → System чтобы заметить). WhatsApp пытался обойти tun через `bindProcessToNetwork()` → blocked РКН на ISP, сообщения застряли в pending.

Два разных state'а:
- **persisted** (`BootReceiver.isAllowBypass`) — current SharedPreferences setting.
- **runtime applied** (`VpnService.Builder.allowBypass()`) — что реально в эффекте у Android. Set ровно один раз per `establish()`.

Без VPN reload эти два значения расходятся, и юзер не знает что именно действует. Теперь:

- `BoxVpnService.companion.currentSessionAllowBypass: @Volatile Boolean` — snapshot значения `BootReceiver.isAllowBypass()` в момент `establish()`. Reset в `onDestroy()`.
- Debug API `/state/vpn` → новое поле `current_session_allow_bypass: bool`.
- Stats screen AppBar: жёлтый warning icon (`Icons.warning_amber`) — visible iff `currentSessionAllowBypass == true`. Tap → tooltip «VPN bypass is active in this session… Disable in VPN Settings → System and reload VPN». Видно на всех 4 tabs.

---

### §076 — Settings and config lifecycle

[Feature spec](docs/spec/features/076%20settings-and-config-lifecycle/spec.md).

Унификация всего lifecycle от UI editing screen через persistent storage (`lxbox_settings.json`) → собранный sing-box config → running tunnel. Сделано как design choice — два паттерна работы со storage, каждый screen выбирает свой осознанно.

**Lazy pattern (write-on-exit)** для toggle-flood editing screens:
- `tun_apps_tab`, `routing_screen`, `dns_settings_screen`, `settings_screen` Core VPN tab.
- Mutations только in-memory + sync mark `configDirty=true`.
- Storage flush на `dispose()` + `AppLifecycleState.paused`.
- Rebuild lazy на возврат к home через global `HomeReturnObserver` (NavigatorObserver зарегистрирован в `MaterialApp.navigatorObservers`).
- **1 settings write + 1 config write per editing session** независимо от количества toggle'ов внутри session.

**Eager pattern (immediate-write)** для discrete-event screens:
- `subscriptions_screen` (add/remove subscription), `app_settings_screen` (UI prefs), `custom_rule_edit_screen` (Save button), `node_filter_screen` (Apply button).
- Каждое user action → inline save + snackbar feedback.

**Global `HomeReturnObserver`**: универсальный NavigatorObserver. Срабатывает на любой `didPop` когда home становится top route (`previousRoute.isFirst == true`). Покрывает все способы возврата — drawer, long-press, system back, swipe, programmatic pop, cross-navigation между settings screens. Раньше rebuild trigger был привязан к `_pushRoute.then()` callback и терялся при опен screen через альтернативные callsite'ы.

**`HomeController.markConfigChangedNeedRestart()`**: external mark для настроек применяемых вне config pipeline. Native VPN System toggles (Allow Bypass / Keep on Exit / Background Mode) после save вызывают этот метод → home banner показывает «Restart VPN» если tunnelUp. Локальные snackbar'ы про restart удалены — единый source-of-truth.

**Self-healing после kill mid-edit**: на launch `subController.init` сравнивает mtime'ы `lxbox_settings.json > singbox_config.json` → восстанавливает `configDirty` → `home._initSubsAndAutoUpdate` триггерит тихий bootstrap rebuild → юзер не видит banner на старте, config уже свежий.

**Banner UX**:
- Синий «Settings changed — tap to rebuild» при `configDirty=true` всегда (без `tunnelUp` gate). Юзер видит pending changes даже когда VPN off.
- Розовый «Config changed — restart VPN» при `tunnelUp && configChangedNeedRestart && !configDirty`. Mutually exclusive с синим.
- Auto-rebuild config setting в App Settings (default ON) контролирует автоматичность rebuild'а на возврат. OFF → только banner, юзер тапает сам.

**Renames**:
- In-memory field `HomeState.configStaleSinceStart` → `configChangedNeedRestart` (sweep across home_state, home_controller, home_screen, debug serializer).
- Debug API JSON key `config_stale_since_start` → `config_changed_need_restart` (**breaking** для external consumers Debug API).
- Добавлен computed `config_dirty: bool` в `/state` response для диагностики.

---

## 🔧 Behavior changes

### §073 — Subscription detour: `Add detour` mode (append by default)

[Task spec](docs/spec/tasks/073-detour-append-vs-replace.md).

**До v1.9.0**: в Subscription detail mode `Override` полностью **заменял** родную detour-цепочку из конфига одним выбранным outbound'ом.

**Теперь**:
- Radio item переименован `Override` → **Add detour**.
- Default behaviour = **append**: нативная цепочка из конфига сохраняется, выбранный outbound подставляется как **новый последний хоп**. `node → native[0] → ... → native[N-1] → newDetour → internet`.
- Новый toggle **«Replace existing chain»** под Outbound picker (OFF default). Включить чтобы вернуть старое replace-поведение.

⚠ **Поведение существующих юзеров с `override_detour != ''` меняется**: была implicit replace, стала append. Если у тебя в подписке нет нативного detour — поведение не изменится (1-hop). Если был многоhop chain — теперь chain сохранится + tail. Toggle ON чтобы вернуться к старому.

Storage migration: backup'ы без ключа `replace_detour_chain` → default false (append).

Builder splice новой цепочки: `detours.last.map['detour'] = overrideDetour` для последнего нативного hop'а; main → first native detour. Когда native chain пустая — 1-hop как раньше.

### §067 — Removed: SelectableRule legacy (no-preset_id) path

[Task spec](docs/spec/tasks/067-selectable-rule-legacy-cleanup.md).

До §033 (v1.4.x) `SelectableRule` мог быть в шаблоне без `preset_id` — конвертировался копированием полей. С §033 (v1.5+) все рулы в `wizard_template.json` имеют `preset_id`. Конвертер `selectableRuleToCustom` для empty presetId возвращал null silently — dead code.

- `SelectableRule.presetId` теперь `required` (default `''` удалён).
- `SelectableRule.fromJson` бросает `FormatException` если в шаблоне отсутствует `preset_id`.
- `selectableRuleToCustom` возвращает `CustomRulePreset` (non-nullable, был `?`).
- Убраны 2 null-check'а в `routing_screen.dart`.

---

## 🐛 Fixes

### §075 — Tunnel apps: regenerate config перед restart VPN

[Task spec](docs/spec/tasks/075-tun-apps-restart-regen-config.md).

Incident 2026-06-06: юзер выбрал `Mode = Deny-list` + добавил Internet (`com.heytap.browser`) в Tunnel apps tab → tap «Restart» → Internet всё ещё ходил через VPN.

Verified via Debug API:
- `GET /settings/tun_apps` → `{mode: "deny", packages: ["com.heytap.browser"]}` ✅
- `GET /config` → inbound[type=tun] — НЕТ `exclude_package` ❌

**Root cause**: `_persist` обновлял только storage shape, `_restartVpn` делал `stop() → start()` без regenerate. Native side подхватывает **last saved config** — а тот не пересобран после изменения tun_apps. `applyTunPackages` post-step применяется только во время `subController.generateConfig`.

**Fix**: `_persist` теперь приведён к pattern'у `routing_screen._apply` — `setTunApps → generateConfig → saveParsedConfig`. Локальный «Restart now» banner / button удалены — единый source-of-truth через `configStaleSinceStart` flag и глобальный home banner. То же UX что у routing changes.

### §072 — `SettingsStorage`: atomic write + `.bak` recovery

[Task spec](docs/spec/tasks/072-settings-storage-atomic-write.md).

Симптом: на Xiaomi/HyperOS (воспроизведено на Pad 8 Pro) раз в пару дней у юзера **полностью** сбрасывались все настройки — vars, подписки, server lists, custom rules, DNS. На «чистом» Android не воспроизводится.

Root cause — три бага складываются:

1. `_save()` использовал `File.writeAsString` без `flush=true` (truncate-then-write). HyperOS агрессивно убивает фоновые/свёрнутые процессы — kill между truncate и завершением записи оставлял пустой / обрезанный JSON.
2. `_load()` ловил `FormatException` на битом файле в немом `catch (_) {}` и проваливался в `_cache = {}`. «Файл повреждён» и «файла нет» обрабатывались одинаково.
3. Первый же последующий `setVar` писал пустой кэш обратно → потеря становится постоянной.

Фикс:

- **Атомарная запись**: `_save()` теперь делает (1) `copy(main → .bak)` если main валиден, (2) `write(.tmp, flush: true)`, (3) `tmp.rename(main)` — POSIX `rename(2)` атомарен в пределах одной FS.
- **Decision tree в `_load()`**: main отсутствует → `{}` (fresh install); main парсится → return; main битый + `.bak` валиден → recovery (`AppLog.warning`); main битый + bak нет → return `{}` + sticky-флаг `_mainIsCorrupted` + `AppLog.error` (раз за сессию). Critical: при corruption main файл **не перезаписывается** автоматически — оставляется для ручной диагностики.
- **Cleanup**: stale `.tmp` от прошлого crashed save удаляется в начале `_load()`.

+12 unit tests: round-trip, recovery из .bak, drop без bak, empty file truncate, .tmp cleanup, .bak только из валидного main.

### OEM battery follow-up + Restore from backup

- **OEM battery restrictions follow-up dialog** ([home_screen.dart](app/lib/screens/home_screen.dart)). После того как юзер тапнул «Allow» в нашем rationale и затем «Разрешить» в системном `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` dialog'е → app в AOSP whitelist, но OEM (ColorOS/MIUI/MagicOS на OnePlus/OPPO/Realme/Xiaomi/Honor) имеют proprietary battery toggles поверх AOSP. Показывается follow-up dialog «Disable battery restrictions» с инструкцией и deep-link на App Info. Cooldown 24h убран — спрашиваем при каждом запуске пока permission не дан.
- **«Restore from backup» link в empty state** ([home_screen.dart](app/lib/screens/home_screen.dart)). Если нет server_lists/custom_rules — под FAB «Add a server» появляется кнопка «🔄 Restore from backup». SAF native file picker, после `applyImport` сразу триггерится fetch подписок без необходимости restart app'а.

---

## 🛠 Tools / internals

### §066 — Pre-commit hook auto-syncs `app/pubspec.yaml`

[Task spec](docs/spec/tasks/066-pubspec-sync-hook.md). Изначально планировался для v1.8.3 (не выпущен), ships в v1.9.0.

После §065 `flutter run` на dev машине показывал `v0.0.0-dev` (pubspec placeholder). Теперь pre-commit hook автоматически синхронизирует pubspec с git state:

- `versionName` = `${last_tag#v}` (clean release) или `${last_tag#v}-dev.${commits_since}` (между тегами).
- `versionCode` = `git rev-list --count HEAD` + 1.

Каждый `git commit` → pubspec правильный без manual шагов. CI release builds override pubspec из tag ещё раз (потому что hook не triggers на `git tag`).

**Setup для нового clone**: `./scripts/setup-hooks.sh` (one-shot включает `git config core.hooksPath .githooks`).

**UpdateChecker `-dev` skip**: dev builds не получают snackbar «X.Y.Z available» — всегда выглядит как «обновитесь до latest».

---

## 🔬 Verified

- `flutter analyze` clean на touched files (685 tests including 27 NodeFilter + 18 sort/manual mode + 4 detour append/replace + 12 SettingsStorage).
- Local smoke на Android 14 (Pixel-class) — все 5 фич живые, drag-handle 8% strip удобный, popup menu опции применяются immediate.
- §072 fix verified: crashed save (mid-tmp-rename) теперь leaves main + .bak intact.
- §073 builder verified: append с пустой chain = 1-hop как раньше; replace toggle ON воспроизводит старое поведение.

---

## 📲 Install

```bash
adb install -r app-release.apk
```

Без uninstall! Поверх существующей установки. Все настройки и подписки сохранятся.

Если впервые — на Android 14+ дай в Settings → Battery → Don't optimize, иначе VPN отключится в Doze.

---

## 🇷🇺 L×Box v1.9.0 на русском

Большой UX-релиз главного экрана:

- **Фильтры списка нод** (§048): regex с invert toggle, emoji-чипсы стран, фильтры по протоколу / подписке / ping. Иконка `Icons.tune` справа от сортировки → expand-panel.
- **Add server wizard** (§074): long-press на «+» в Subscriptions screen → wizard с 3 tabs (SOCKS5 form для locally hosted SOCKS5 / DPI bypass + Paste URI + Paste JSON).
- **Ручное перетягивание нод** (§071): long-press за левый край ноды (~8% ширины) → ⠿ drag mode + custom порядок до конца сессии.
- **Опции сортировки** (§070): long-press на иконку sort'а → bottom sheet с pin DIRECT / pin AUTO / Re-sort on manual ping. Yellow dot подсвечивается если хоть одна опция non-default.
- **`Add detour` в подписках** (§073): раньше mode `Override` полностью заменял родной detour. Теперь default = append (chain + новый exit), а replace доступен через checkbox.
- **Fix data loss на Xiaomi/HyperOS** (§072): раз в пару дней пользователи теряли все настройки — vars, подписки, server lists, custom rules. Fixed через atomic write `.tmp + rename` + recovery из `.bak`.

⚠ **Поведение для тех кто использовал mode `Override` в подписке** меняется: была implicit replace, стала append. Если был многоhop chain — теперь chain сохранится + новый tail. В Subscription detail включи toggle «Replace existing chain» чтобы вернуться к старому.

Предыдущий релиз: [v1.8.2](docs/releases/v1.8.2.md).
