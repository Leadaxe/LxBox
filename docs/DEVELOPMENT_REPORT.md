# Отчёт о разработке L×Box

**Дата:** 19 апреля 2026 (подробный нарратив — до v1.3.1; хроника ниже — до v1.9.0)
**Период:** Эволюция от MVP до полноценного приложения + Parser v2 landmark-рефакторинг

---

## Резюме

L×Box прошёл путь от MVP (один экран: Read config → Start/Stop VPN → список нод) до полнофункционального Android VPN-клиента с:
- Полным парсером подписок (порт из singbox-launcher).
- Генератором конфигов на основе wizard template.
- Управлением подписками и настройками через UI.
- Mass ping, сортировкой, quick start, авто-обновлением.
- Dark theme и улучшенным UX.

Ниже — детальное описание каждого этапа.

---

## Этап 1: Реструктуризация спецификаций

### Проблема
Документация была разделена на `docs/spec/features/` и `docs/spec/tasks/` — неудобно, задачи оторваны от фич.

### Решение
- Перенесены все задачи из `docs/spec/tasks/` в `tasks.md` внутри соответствующих feature-папок.
- Удалена отдельная папка `tasks/`.
- Обновлены README и внутренние ссылки.

### Результат
Каждая фича — самодостаточная папка: `spec.md` + `plan.md` (опционально) + `tasks.md`.

---

## Этап 2: Subscription Parser (Feature 004)

### Задача
Перенести логику парсера подписок из Go-кодовой базы singbox-launcher в Dart.

### Реализация

**Файлы:**
- `services/subscription_fetcher.dart` — HTTP fetch с User-Agent, timeout 30s, лимит 10MB.
- `services/subscription_decoder.dart` — детектирование и декодирование: Base64 (standard, URL-safe, padded/unpadded), Xray JSON array, plain text.
- `services/node_parser.dart` (973 строки) — парсинг URI для 8 протоколов:
  - **VLESS** — `vless://uuid@host:port?...#fragment`
  - **VMess** — `vmess://base64json` (формат v2rayN)
  - **Trojan** — `trojan://password@host:port?...#fragment`
  - **Shadowsocks** — `ss://base64(method:password)@host:port#fragment` + SIP002
  - **Hysteria2** — `hy2://auth@host:port?...#fragment`
  - **SSH** — `ssh://user:pass@host:port#fragment`
  - **SOCKS** — `socks://user:pass@host:port#fragment`
  - **WireGuard** — `wireguard://...`
- `services/source_loader.dart` — оркестратор: Source → fetch → decode → parse → tag transform → uniqueness.

**Модели:**
- `models/parsed_node.dart` — `ParsedNode`: tag, scheme, server, port, uuid, flow, query, outbound (sing-box JSON).
- `models/proxy_source.dart` — `ProxySource`: source URL, connections, tagPrefix/Postfix/Mask, filters, excludeFromGlobal.

### Ключевые решения
- Каждый `ParsedNode` сразу содержит готовый `outbound` JSON — не нужен второй проход для генерации.
- Tag uniqueness: `tagCounts` map, дубликаты получают суффикс `#2`, `#3`, ...
- `isSubscriptionURL` / `isDirectLink` — эвристика для автоматического определения типа ввода.

---

## Этап 3: Config Generator (Feature 005)

### Задача
Из wizard template + пользовательских переменных + распарсенных нод сгенерировать полный sing-box JSON.

### Реализация

**Wizard Template** (`assets/wizard_template.json`, 206 строк):
- `parser_config`: outbound-группы (auto-proxy-out/urltest, vpn-1/vpn-2/vpn-3 selector'ы), regex-фильтры по тегам.
- `vars`: 10 переменных (log_level, clash_api, clash_secret, resolve_strategy, auto_detect_interface, dns_strategy, dns_independent_cache, dns_default_domain_resolver, dns_final). Типы: enum, text, secret, bool.
- `config`: базовый sing-box JSON с плейсхолдерами `@var_name`.
- `selectable_rules`: 5 предустановленных правил (Block Ads, Russian domains direct, BitTorrent direct, Games direct, Private IPs direct) со ссылками на remote SRS rule sets.

**ConfigBuilder** (`services/config_builder.dart`):
1. `loadTemplate()` — загрузка и кэширование из asset bundle.
2. `_substituteVars()` — рекурсивная подстановка `@var_name` с type coercion (`"true"` → `true`, `"9090"` → `9090`).
3. `_generateOutbounds()` — 2-pass:
   - Pass 1: все node outbounds.
   - Pass 2: selector/urltest groups из template, фильтрация нод по `_matchesFilter` (literal, regex с `/.../i`, negation `!`), merge с `addOutbounds`, валидация тегов.
4. `_applySelectableRules()` — добавление rule_set и rules по enabled-списку.

**SettingsStorage** (`services/settings_storage.dart`):
- JSON-файл `lxbox_settings.json` через `path_provider`.
- Секции: `vars`, `proxy_sources`, `enabled_rules`, `last_global_update`.
- In-memory cache для быстрого доступа.

### Модели
- `models/parser_config.dart`:
  - `WizardTemplate` — корневая структура.
  - `ParserConfigBlock` — parser_config с outbounds и reload interval.
  - `WizardVar` — переменная с типом, default, options, wizard_ui.
  - `SelectableRule` — правило роутинга с rule_set и rule.

---

## Этап 4: Subscription & Settings UI (Feature 006)

### Subscriptions Screen
- **Input bar**: TextField + Paste + Add.
- **Subscription list**: Dismissible (swipe-to-delete), ListTile с displayName, node count chip.
- **Actions**: "Update All & Generate" (appbar), "Generate Config" (bottom bar).
- **Progress**: CircularProgressIndicator + текст статуса.

### Settings Screen
- **Vars section**: SwitchListTile (bool), DropdownButton (enum), TextField (text), obscured TextField + Random (secret).
- **Rules section**: SwitchListTile для каждого SelectableRule.
- **Apply**: сохранение vars и rules → перегенерация конфига → SnackBar. Подсказка "Restart VPN" если туннель активен.

### Drawer Integration
- Пункты Subscriptions и Settings в navigation drawer HomeScreen.
- Оба экрана получают `SubscriptionController` и `HomeController` для cross-controller взаимодействия.

---

## Этап 5: Config Editor Improvements (Feature 007)

### Решение
- `prettyJsonForDisplay(String raw)` в `config_parse.dart` — JSON5 parse → JsonEncoder.withIndent('  ').
- Graceful fallback: если парсинг не удался, возвращает raw строку.
- ConfigScreen использует prettyJsonForDisplay в `initState` для TextEditingController.
- При сохранении — compact JSON (`canonicalJsonForSingbox`).

---

## Этап 6: Ping & Node Management (Feature 008)

### Mass Ping
- `HomeController.pingAllNodes()` — последовательный обход всех нод.
- `_massPingEpoch` — counter, инвалидирующий старые циклы при cancel/restart.
- Проверка `_state.tunnelUp` в каждой итерации — остановка при разрыве VPN.
- `cancelMassPing()` — устанавливает `_massPingRunning = false`, инкрементирует epoch, вызывает `notifyListeners()`.

### Расширенное контекстное меню
- `showMenu` с 4 пунктами: Ping, Use this node, разделитель, Copy name.
- `Clipboard.setData` + SnackBar для Copy.
- `canPing` и `canActivate` — условия доступности пунктов.

### Цветовая индикация
- `_delayColor(context)` — `< 200ms` green, `< 500ms` orange, else error color.

---

## Этап 7: Dark Theme & UX (Feature 009)

### Dark Theme
- `darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark))`.
- `themeMode: ThemeMode.system`.

### Сортировка нод
- `NodeSortMode` enum: `defaultOrder`, `latencyAsc`, `latencyDesc`, `nameAsc`.
- `sortedNodes` getter в `HomeState`:
  - Latency sort: null → внизу, negative (error) → после позитивных.
  - Name sort: case-insensitive.
- `cycleSortMode()` в HomeController — циклическое переключение.

### Pull-to-refresh
- `RefreshIndicator(onRefresh: _controller.reloadProxies)` вокруг ListView.

### Улучшения HomeScreen
- `Listenable.merge([_controller, _subController])` — UI реагирует на оба контроллера.
- Node count `(N)` в заголовке.
- Reload groups button в строке заголовка Nodes.
- Long-press на заголовке → SettingsScreen. `HitTestBehavior.opaque` для reliable gesture detection.
- Progress banner при busy `_subController`.

---

## Этап 8: Quick Start & Auto-refresh (Feature 010)

### Quick Start
- `assets/get_free.json`: 2 бесплатные подписки (@igareck VLESS Reality Mobile), 4 enabled rules.
- `GetFreeLoader` — load + cache из asset bundle.
- `SubscriptionController.applyGetFreePreset()`: replace sources → save rules → fetch → generate.
- Quick Start card: `Card` с `rocket_launch_outlined` icon, описание, `FilledButton.icon` "Set Up Free VPN".
- Показывается когда: `configRaw.isEmpty && entries.isEmpty && !busy`.

### Auto-refresh
- `parseReloadInterval(String)`: regex `^(\d+)\s*(h|m|s)$` → Duration.
- `shouldRefreshSubscriptions(interval)`: сравнение `last_global_update` + interval vs now.
- `_startWithAutoRefresh()` в HomeScreen: если есть подписки и прошёл interval → updateAllAndGenerate → saveParsedConfig → start. Non-blocking: ошибки refresh не мешают запуску.

### Subscription Metadata
- `ProxySource.name`, `lastUpdated` (DateTime?), `lastNodeCount` (int) — persistent.
- `displayName`: name → hostname from URI → truncated URL.
- `SubscriptionEntry.subtitle`: status + `_formatAgo()` ("2h ago", "just now", "3d ago").

---

## Статистика

### Файлы

| Категория | Файлов | Примерно строк |
|-----------|--------|----------------|
| Controllers | 2 | ~700 |
| Models | 6 | ~450 |
| Screens | 12 | ~2500 |
| Services | 10 | ~2100 |
| Config | 2 | ~100 |
| Widgets | 1 | ~150 |
| Assets | 2 | ~310 |
| **Итого (lib/)** | **35** | **~6300** |

### Документация

| Документ | Строк |
|----------|-------|
| `docs/ARCHITECTURE.md` | ~200 |
| `CHANGELOG.md` | ~100 |
| `README.md` | ~80 |
| Feature specs (008-010) | ~300 |
| Этот отчёт | ~300 |

### Поддержанные протоколы (парсер)

| Протокол | URI scheme |
|----------|-----------|
| VLESS | `vless://` |
| VMess | `vmess://` (v2rayN base64) |
| Trojan | `trojan://` |
| Shadowsocks | `ss://` (SIP002 + legacy) |
| Hysteria2 | `hy2://` / `hysteria2://` |
| SSH | `ssh://` |
| SOCKS | `socks://` / `socks5://` |
| WireGuard | `wireguard://` |

### Wizard Template — routing rules

| Правило | По умолчанию | Источник |
|---------|-------------|---------|
| Block Ads | ✓ | geosite-category-ads-all.srs (remote) |
| Russian domains direct | ✓ | **bundle** (spec 033): ru-domains inline + Yandex DNS servers + vars `@out`/`@dns_server`. TLDs: .ru, .su, .рф, .рус, .москва, .moscow, .tatar, .дети, .онлайн, .сайт, .орг, .ком |
| BitTorrent direct | ✓ | protocol: bittorrent |
| Games direct | ✓ | geosite-category-games.srs (remote) |
| Private IPs direct | ○ | ip_is_private: true |

---

## Этап 7: Нативный VPN и Routing (Features 013–016)

### Native VPN Service (013)
- Удалён сторонний плагин `flutter_singbox_vpn` (0 звёзд, непопулярный).
- Весь нативный код перенесён в `android/app/.../vpn/`: VpnPlugin, BoxVpnService, ConfigManager и др.
- Конфиг хранится в файле (`singbox_config.json`), а не SharedPreferences.
- Dart-обёртка BoxVpnClient с MethodChannel/EventChannel.

### Subscription Detail View (014)
- Тап по подписке → полноэкранный detail screen (URL, ноды, дата обновления).
- Inline rename, delete с подтверждением, refresh.
- Убраны swipe-to-delete и bottom sheet из основного списка.

### Rule Outbound Selection (015)
- Дропдаун outbound (direct/proxy/auto/vpn-X) рядом с каждым правилом.
- Настройка route.final для fallback трафика.

### Routing Screen (016)
- Отдельный экран Routing: Proxy Groups + Rules + outbound dropdowns.
- Settings упрощён — только технические vars.

---

## Этап 8: Per-App Routing, UX, безопасность (Features 017–018)

### App Routing Rules (017)
- Именованные группы приложений (App Rules) с выбором outbound (direct/proxy/vpn-X).
- Каждое правило → sing-box routing rule с `package_name`.
- AppPickerScreen: иконки приложений, поиск, select all/invert, clipboard import/export.
- `QUERY_ALL_PACKAGES` для полного списка на Android 11+.

### Custom Nodes — спека (018)
- Дизайн `custom_nodes`: ручные ноды + override-патчи поверх подписочных.
- `override` поле привязывает патч к подписочной ноде по тегу.
- Планируется: JSON editor для нод, переименование тегов, индикация в UI.

### UX Improvements
- **Start/Stop** — одна toggle кнопка (зелёный/красный).
- **Get Free VPN** перенесён в Subscriptions.
- **Mass Ping** — 20 параллельных, сброс при старте.
- **Clash API** — рандомный порт 49152-65535, автогенерация секрета.
- **Portrait lock**, diagnostic snackbar, empty config guard.
- **App Settings** — отдельный экран: тема light/dark/system.
- **VPN Settings** — MTU, packet sniffing, preferred IP version, TUN stack.
- **Profile-title** — автоимя подписки из HTTP заголовка.
- **Copy outbound JSON** в контекстном меню ноды.
- **Secret visibility toggle** — кнопка-глаз.

### Рефакторинг и баги
- Outbound tag desync (дубли тегов при одинаковых именах нод).
- serviceScope вместо GlobalScope (structured concurrency).
- startForeground перед stopSelf в error paths.
- TextEditingController leak.
- libbox 1.12.12 API alignment.
- ACCESS_NETWORK_STATE permission.

---

## Этап 9: UX polish, Connections, Ping settings

### Connections Screen
- Тап на traffic bar → живой список соединений (destination, chain, network, duration).
- Закрытие отдельного или всех соединений через Clash API.

### UX Improvements
- Sort icons: уникальная иконка для каждого режима + Z→A.
- Long press пинг → настройки (URL, timeout).
- Rebuild config кнопка (sync icon).
- Config Editor: popup menu (paste/file/copy/share), drawer упрощён.
- Stop button без красного — одинаковый стиль с Start.
- Routing rules: title + dropdown на одной строке, SRS cloud icon.
- App Groups: переименование внутри picker'а.
- App picker: мгновенное открытие (100ms delay перед загрузкой).
- URLTest: case-insensitive проверка, now в subtitle.
- VPN revoke: полная остановка libbox + 10с таймаут на Stopping.

---

## Этап 10: UX overhaul, Speed Test, Node Filter, Subscription Toggles (16 апреля 2026)

### Autosave вместо Apply
- **Routing Screen** — убрана кнопка Apply, автосохранение с debounce 500мс.
- **VPN Settings** — аналогично.
- **Subscriptions** — убрана кнопка "Generate Config", конфиг пересобирается при выходе с экрана.

### Subscription Management
- **Enable/Disable** — switch на каждой подписке. Отключённые не попадают в конфиг и не фетчатся при обновлении.
- **Long-press context menu** — Copy URL, Update, Delete с подтверждением.
- **Telegram иконка** — `Icons.telegram` с фирменным синим (#2AABEE) рядом с заголовком подписки.
- **Ссылки открываются** через Intent.ACTION_VIEW (не копируются в буфер).
- **Subscription detail** — без автозагрузки при открытии, refresh по кнопке.
- **Кэширование подписок на диск** — при ошибке сети используются закэшированные данные, nodeCount не обнуляется.

### Node Filter (Spec 022)
- Экран с чекбоксами нод — include/exclude из конфига.
- Читает ноды из configRaw (offline, мгновенно).
- Кнопка "Manage Nodes" внизу экрана подписок.
- Select All / Deselect All, поиск, счётчик.
- Исключённые теги хранятся в settings, новые ноды включены по умолчанию.

### Speed Test (Spec 021)
- 4 параллельных потока download (streamed response).
- Real-time обновление скорости каждые 500мс.
- Ping: 5 замеров, trimmed mean, fallback серверы.
- **Настройки**: выбор сервера (Cloudflare, Hetzner, OVH, Yandex), количество потоков (1/4/10).
- Proxy индикатор — показывает через какой прокси идёт тест или "Direct".
- История за сессию — до 10 записей, не хранится между запусками.

### Statistics Screen
- Outbound-карточки раскрываются по тапу → список соединений с деталями.
- Каждое соединение: host:port, протокол, rule, трафик, длительность, chain.
- Клик на Connections → полноценный ConnectionsScreen с возможностью закрытия.

### Сортировка нод
- 3 режима: Default (↕), Ping (signal), A–Z (sort_by_alpha).
- Убраны Ping↓ и Z→A для простоты.

### Прочие улучшения
- **App picker** — задержка 300мс, иконка карандаша для rename title.
- **Ping settings** — long press работает корректно (убран конфликт с Tooltip).
- **Node context menu** — убран пункт "Copy name", оставлен "Copy outbound JSON".
- **UrlLauncher** — вынесен в отдельный сервис, убрано дублирование.
- **Android MainActivity** — MethodChannel для открытия URL через Intent.
- **Stop VPN on app swipe** + keep on exit setting.

---

## Конкурентный анализ

### Наши преимущества перед SFA / Hiddify / NekoBox / v2rayNG:
- Multi-subscription в одних группах (у конкурентов один профиль = одна подписка)
- Enable/disable подписок без удаления
- Node filter — включение/исключение отдельных нод
- App Groups с per-group outbound (у конкурентов только include/exclude)
- Wizard template с auto-генерацией конфига
- Profile-title/userinfo из HTTP заголовков
- SRS download on-demand
- Parallel mass ping (20)
- Built-in speed test с настройками серверов и потоков
- Statistics с drill-down по соединениям
- Connections screen с live данными и закрытием
- Subscription caching — работа offline
- Autosave — без кнопок Apply

### Чего у конкурентов есть, а у нас нет:
- QR code scan/generate (v2rayNG)
- WebDAV backup/sync (v2rayNG)
- Geo asset manager — geoip/geosite updates (SFA, NekoBox)
- Multi-hop / chained proxy UI (Hiddify)
- Export/import settings

---

## Этап 11: Parser v2 landmark-рефакторинг (v1.3.0 — 18 апреля 2026)

Полная переработка внутреннего парсер/билдер pipeline согласно [spec 026](./spec/features/026%20parser%20v2/spec.md). 5 фаз за 1 день, ~9.5k/-3.8k LOC.

### Что сделано

- **Типизированная sealed `NodeSpec`** — 9 вариантов (VLESS, VMess, Trojan, SS, Hy2, TUIC v5 новый, SSH, SOCKS, WireGuard) с полиморфным `emit(vars)` и `toUri()`.
- **Round-trip invariant** — `parseUri(spec.toUri()) ≈ spec` протестирован per variant.
- **Sealed `TransportSpec`** — TcpTransport, WsTransport, GrpcTransport, HttpTransport, HttpUpgradeTransport, XhttpTransport. Компилятор enforc'ит fallback для XHTTP (→ httpupgrade + `UnsupportedTransportWarning`).
- **3-слойный pipeline** — `parseFromSource(source) → ServerList.build(ctx) → buildConfig(lists, settings) → BuildResult{config, validation, warnings}`.
- **`ServerList` sealed** — `SubscriptionServers` vs `UserServer` (в v1.3.1 singular после rename).
- **`EmitContext` + `NodeEntries{main, detours[]}`** — замена плоского `ServerRegistry` (v1) на named struct с чётким контрактом.
- **`ValidationResult`** — типизированные `ValidationIssue`: dangling refs, empty urltest, invalid selector default.
- **Миграция v1→v2** — one-shot `migrateProxySources` в `SettingsStorage.getServerLists`: `proxy_sources` → `server_lists` при первом чтении.
- **Удалено** — `node_parser.dart` (~1100 LOC), `config_builder.dart` (~550), `source_loader.dart`, `subscription_decoder.dart`, `subscription_fetcher.dart`, `xray_json_parser.dart`, `parsed_node.dart`, `proxy_source.dart`. Суммарно ~2700 LOC.
- **116 тестов** покрывают models, parser, round-trip, builder, validator, migration, subscription pipeline, e2e.

### Подтестовые фичи

- **Subscription auto-update** (spec 027) — 4 триггера (appStart, vpnConnected+2min, periodic 1h, vpnStopped) + manual force. Жёсткие gates: `minRetryInterval=15min` (persisted), `maxFailsPerSession=5` (in-memory), `perSubscriptionDelay=10s±2s`, `_running`/`_inFlight` dedup, `inProgress` crash-safe guard. Rebuild config **не** триггерит HTTP.
- **AntiDPI mixed-case SNI** (spec 028) — `applyMixedCaseSni` post-step рандомизирует `server_name` (`WwW.gOoGle.CoM`). First-hop only, punycode-метки не трогаем. RFC 6066 compliance. 10 unit-тестов.
- **Haptic feedback** (spec 029) — `HapticService` singleton, event-based API, throttle 100ms, respects system Touch feedback. Wired в HomeController transitions + tap Start/Stop + manual fetch success/fail + heartbeat fail (только первый).
- **Restart warning sticky flag** (spec 003 §8a) — `HomeState.configStaleSinceStart` флаг, derived getter `_needsRestart`. Показывается надёжно после Routing Apply / Settings / Debug import / Rebuild; не пропадает при отмене Stop-диалога. Сбрасывается только на реальном tunnel up↔down.
- **Subscription title fallback** — из `Content-Disposition: filename=...` (RFC 5987) если нет `profile-title` header. Стрип `.txt`/`.yaml`/`.json`/`.conf`.
- **Local build marker** — `scripts/build-local-apk.sh` оборачивает `flutter build` с `--dart-define`'ами (git describe + commits since tag). About screen показывает розовую плашку «🧪 LOCAL BUILD · N commits since vX.Y.Z». CI не маркирует.

### Результат

- **v1.3.0** зарелизен, CI собирает release APK на тег. 116 тестов зелёные.
- Архитектура стала принципиально проще: UI → controller → функциональный pipeline → sing-box JSON. Никаких mutable registry.

---

## Этап 12: UX polish + critical fixes (v1.3.1 — 19 апреля 2026)

Патч-релиз через ~сутки после v1.3.0, фокус на UX и багфиксы.

### Critical fixes
- **`UserServer` показывал infinite spinner после рестарта** — `toJson` хранил только `rawBody`, `fromJson` не парсил обратно → NodeSettingsScreen._load() видел пустые `nodes` → `_originalTag` не сетился → спиннер. Фикс: `fromJson` реконструирует nodes через `parseAll(decode(rawBody))`.
- **Detour dropdown в Node Settings не сохранялся** — писал `detour` в JSON ноды, `parseSingboxEntry` это поле не восстанавливает → при save→reparse detour терялся. Фикс: persist через `entry.detourPolicy.overrideDetour`, сразу при выборе.
- **XHTTP warning перекрывался TLS-insecure** — `node.warnings.first` бралось безусловно, `InsecureTlsWarning` (parse-time) затмевал `UnsupportedTransportWarning('xhttp')` (emit-time). Фикс: сортировка по severity, `_NodeWarningRow` widget.
- **TLS-insecure severity → info (grey)** — провайдеры часто намеренно ставят флаг (REALITY, IP-литералы, self-signed), не должен кричать. Banner вверху detail-экрана теперь считает только actionable.

### UI polish
- **NodeRow новый layout** — `[ACTIVE green pill] PROTOCOL · · · 50MS →`. ACTIVE зелёная пилюля; протокол серый (VLESS, Hy2, WG, TUIC, SS); ping справа цветом по latency. Для urltest-группы показывает proto **выбранной** ноды.
- **Long-press → Copy URI** — оригинальный `vless://` / `wireguard://` / etc через `node.toUri()`. `Copy server` → `Copy server (JSON)` для ясности.
- **Editable Tag field в NodeSettingsScreen** — отдельный TextField (раньше тег правился через JSON-редактор).
- **Mark as detour server** switch — добавляет/убирает префикс `⚙ ` к tag'у. Хранится прямо в `tag`, без отдельных флагов.
- **Empty input + tap `+` = paste from clipboard** — экономит тап.
- **Auto-regenerate config после addFromInput** — paste/QR/file автоматом пересобирают config + saveParsedConfig.
- **Subscription row subtitle** — для UserServer единообразно `<PROTOCOL> server` (раньше разнобой `WireGuard config` / `Direct link` / `JSON outbound` / "1 node").

### Rename: `UserServers` → `UserServer`
Исторически plural, но всегда 1 node. 10 файлов. JSON discriminator `'type': 'user'` сохранён — миграция не нужна.

### Docs sweep
003 (NodeRow layout, Copy URI), 006 (UserServer subtitle, paste-on-empty-+), 017 (editable Tag, Mark as detour, overrideDetour persistence), 026 (UserServer rename + rehydrate invariant).

---

## Текущая статистика (v1.3.1 snapshot)

- **Тесты:** 128/128 зелёные
- **Спецификации:** 001–029 (29 feature-специфик)
- **Релизы:** v0.0.1, v1.1.1, v1.1.2, v1.2.0, v1.3.0, v1.3.1 (6)
- **LOC:** `lib/` ≈ 14k, удалено v1 ≈ 2.7k при parser v2 landmark
- **Release APK:** 71.3 MB

---

## После v1.3.1 — краткая хроника (без подробного нарратива)

Подробные изменения смотри в [`CHANGELOG.md`](../CHANGELOG.md) и [`docs/spec/tasks/`](spec/tasks/) / [`docs/spec/features/`](spec/features/). Здесь — указатель.

| Релиз | Дата | Headline |
|---|---|---|
| **v1.4.0** | апрель 2026 | Reconnect lifecycle stabilization (atomic teardown, Completer-based stopVPN, sticky `configStaleSinceStart`); ConfigCache; sealed `NodeSpec` (parser v2); shared `asBroadcastStream` для status events; intent-based sticky reset |
| **v1.4.1 / v1.4.2** | апрель 2026 | UX patches |
| **v1.5.0** | апрель 2026 | Quick Connect tile (§014) — Android QS tile для Start/Stop |
| **v1.6.0** | апрель–май 2026 | DNS revamp ([§042](spec/tasks/042-dns-servers-merge-and-cleanup.md) + [§044](spec/tasks/044-dns-servers-clean-schema.md)); ru-direct geoip fallback ([§045](spec/tasks/045-ru-direct-geoip-fallback.md)); per-group ping settings ([§040](spec/tasks/040-per-group-ping-test-settings.md)); humanizeError; Debug API ([§031](spec/features/031%20debug%20api/spec.md)) |
| **v1.6.1** | май 2026 | Patch — UX polish + bug fixes |
| **v1.7.0** | 8 мая 2026 | Per-app traffic profiler ([§044](spec/features/044%20per-app%20traffic%20profiler/spec.md)); commercial license clarification |
| **v1.7.1** | 9 мая 2026 | sing-box wrapper deep audit ([§049](spec/tasks/049-singbox-wrapper-deep-audit/spec.md)) — atomic CAS lifecycle race fix (closing §047 TCP deterioration); F1 split (BoxVpnService → BoxService); inclusive observer ([§048](spec/tasks/048-perapp-trace-attribution-gaps.md)) — 4 confidence levels + Live tab; tunnel apps split-tunneling ([§046](spec/features/046%20tunnel%20apps%20split-tunneling/spec.md)) |
| **v1.7.2** | 10 мая 2026 | wifi_state closeout ([§050](spec/tasks/050-libbox-debug-build/spec.md)) — real root cause `Unknown reference: 42` (unhandled `SecurityException` через JNI) + `NEARBY_WIFI_DEVICES` для Android 13+; `config_locked` UI toggle (§037); Live tab system-wide events fix; tri-mode detour servers UI |
| **v1.7.3** | май 2026 | Wi-Fi-aware routing ([§051](spec/tasks/051-custom-rule-wifi-conditions.md) Phase 1+2+3) — `wifi_ssid` / `wifi_bssid` в `CustomRule` + auto-record opt-in + `/wifi_history` Debug API; VPN Settings reorg ([§052](spec/tasks/052-vpn-settings-system-service-tabs.md)) — System / Core tabs; `CoreLogsHintBanner` UX rework; F22 part 2 perf (back-pressure, batching, deque, throttle) |
| **v1.8.0** | 11 мая 2026 | Backup format переписан под полный snapshot `lxbox_settings.json` + `vpn_settings` блок ([§063](spec/tasks/063-backup-format-snapshot-rewrite.md) / [§040](spec/features/040%20backup%20restore%20ui/spec.md)) — старый формат silently терял custom_rules/tun_apps/enabled_groups, **breaking** change для legacy backup'ов; custom_rules cross-kind order fix ([§062](spec/tasks/062-custom-rules-unified-order.md)) — storage order теперь end-to-end управляемый между preset/inline/srs; editor split Stage 1+2+3 ([§053](spec/tasks/053-custom-rule-editor-split.md)) — `custom_rule_edit_screen.dart` 2060 → 456 LOC через секции/tabs/`ChangeNotifier`; spec reorg ([§054](spec/tasks/054-spec-reorg-features-vs-tasks.md)) — 7 stale features → tasks; ViewTab preview fix для disabled-правил ([§064](spec/tasks/064-view-tab-preview-independent-of-enabled.md)); Allow VPN bypass tooltip |
| **v1.8.1** | 12 мая 2026 | Hotfix v1.8.0: hardcoded `_version = '1.7.0'` в `about_screen.dart` не был поднят при release-bump → UI показывал v1.7.0 на v1.8.0 build + UpdateChecker рекомендовал «обновитесь до 1.8.0». Поднят до 1.8.1 + добавлен CI `Version consistency check` (сверяет pubspec ↔ about_screen ↔ tag, fail до build при mismatch) + обновлён [`docs/RELEASE_PROCESS.md`](RELEASE_PROCESS.md) §2.2 с явным указанием двух мест для bump'а. |
| **v1.8.2** | 12 мая 2026 | Tag = single source of truth для версии ([§065](spec/tasks/065-version-from-tag.md)). Удалён `static const _version` в `about_screen.dart` + `AboutScreen.versionString` alias; pubspec.yaml = placeholder `0.0.0-dev+0`; CI sed'ит `version: ${tag#v}+${git rev-list --count HEAD}` перед `flutter build` (раньше — consistency check, теперь — injection); `scripts/build-local-apk.sh` derive'ит из `git describe` с `trap EXIT` revert. About screen + UpdateChecker → новый `VersionInfo` service (load из `PackageInfo.fromPlatform()` в `main()` перед `runApp`). Release-flow: больше нет bump-коммитов в репо. |
| **v1.8.3** | 12 мая 2026 | Pre-commit hook auto-sync для pubspec.yaml ([§066](spec/tasks/066-pubspec-sync-hook.md)). `.githooks/pre-commit` → `scripts/sync-pubspec-version.sh` (derive `versionName` + `versionCode` из `git describe` + `rev-list --count`). Setup: `scripts/setup-hooks.sh` (one-shot после clone). UpdateChecker skip для `-dev` версий (no snackbar в dev sessions). Удалены `--dart-define BUILD_*` pass-through + `_LocalBuildBadge` widget. `flutter run` теперь показывает realistic `X.Y.Z-dev.N` без extra шагов. |
| **v1.9.0** | 6 июня 2026 | Главный экран UX: node filters ([§048](spec/features/048%20home-node-filters/spec.md)), sort options menu ([§070](spec/features/070%20sort-options/spec.md)) + manual reorder ([§071](spec/features/071%20manual-node-reorder/spec.md)), Add-server wizard ([§074](spec/features/074%20add-server-wizard/spec.md)), subscription detour `Add detour`/append ([§073](spec/tasks/073-detour-append-vs-replace.md)), settings & config lifecycle ([§076](spec/features/076%20settings-and-config-lifecycle/spec.md)); atomic settings write + `.bak` — data-loss fix Xiaomi/HyperOS ([§072](spec/tasks/072-settings-storage-atomic-write.md)) |

Текущее состояние (после v1.9.0; в develop готовится **v2.0.0** — §089–§104: deep-refactor «монстров», ConfigNode, filter mode, смена ядра на **sing-box-lx** — постоянно, пин `v1.13.13-lx.5` + fetch-скрипт в local-build и CI (§104) — AWG2, нативный XHTTP):
- **Тесты:** 860+ зелёных
- **Спецификации:** 001–103 (features + tasks)
- **Релизы:** 17 stable tags
- **LOC:** `app/lib/` ≈ 45k, native Kotlin ≈ 3.3k

## Что дальше

Большая часть «Высокий» и «Средний» приоритетов из v1.3.1 roadmap — закрыты:

- ✅ Custom Nodes UI (rename, bulk ops) — done в v1.3+
- ✅ QR scan/generate — done в v1.4+
- ✅ Export/Import settings — `/backup/*` Debug API + Backup screen в v1.6
- ✅ Quick Settings Tile — done в v1.5.0
- ✅ Background subscription update — AutoUpdater (4-trigger model) в v1.6
- 🔵 **Load Balance** ([§024](spec/features/024%20loadbalance/spec.md)) — ready spec, не реализовано (PuerNya fork или кастомный post-step)
- 🔵 **Profile Management** — несколько конфигов + быстрое переключение, не реализовано
- 🔵 **WARP integration** ([§025](spec/features/025%20warp/spec.md)) — ready spec, не реализовано

Открытые направления ведутся в [`docs/spec/tasks/README.md`](spec/tasks/README.md) и [`docs/spec/features/`](spec/features/) — фильтр по статусу `Draft` / `In progress` / `Deferred`.
