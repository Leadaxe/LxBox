# Changelog

Все заметные изменения в проекте L×Box документируются здесь.

Формат основан на [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
