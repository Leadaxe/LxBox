# Changelog

Все заметные изменения в проекте L×Box документируются здесь.

Формат основан на [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
