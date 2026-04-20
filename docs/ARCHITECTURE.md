# Архитектура L×Box

Документ описывает структуру Flutter-приложения L×Box, зоны ответственности, потоки данных и ключевые решения.

Текущая версия парсер/билдера — **v2** (spec 026, phase 5 completed в v1.3.0). Подробности см. в [spec/features/026 parser v2](./spec/features/026%20parser%20v2/spec.md).

---

## Supported platforms

| Параметр | Значение |
|----------|----------|
| Android minSdk | **30** (Android 11) |
| Android targetSdk | `flutter.targetSdkVersion` (актуальная target, обычно API 34/35) |
| Android compileSdk | `flutter.compileSdkVersion` |
| JVM | Java 17 |
| NDK | 28.2.13676358 |

**Android <11 (API <30) — вне scope проекта.** Не тестируется, не поддерживается, не оптимизируется. Обоснование:

- **`ActivityManager.getHistoricalProcessExitReasons`** — нужен для silent-kill detection (см. `docs/spec/tasks/007-silent-kill-handling.md`), доступен с API 30.
- **Foreground-service lifecycle на Android 11+** — стабильнее, чище доз-state transitions.
- **VpnService API** (`setMetered`, `setUnderlyingNetworks`) — современные поля и callback'и доступны с API 29+.
- **Scoped Storage** — по умолчанию на API 30+, старые workaround'ы не нужны.
- **`RECEIVER_NOT_EXPORTED` flag** — обязателен с API 33, мы и так его выставляем.

Поднятие minSdk до 30 зафиксировано в `app/android/app/build.gradle.kts` (`minSdk = 30`). Legacy `Build.VERSION.SDK_INT` checks в nativе оставлены как есть (часть libbox-adjacent кода) — очистка в отдельном рефакторинг-коммите после стабилизации 1.4.0.

---

## Обзор

L×Box — Android VPN-клиент на базе **sing-box** (через **libbox**). Полный цикл: подписки → парсинг → конфиг → VPN-туннель → управление через **Clash API**.

```
┌─────────────────────────────────────────────────────────────────┐
│                         Flutter UI                               │
│  HomeScreen · RoutingScreen · SubscriptionsScreen                │
│  AppSettingsScreen · StatsScreen (Overview + Connections tabs)   │
│  SubscriptionDetail · NodeSettingsScreen · NodeFilterScreen      │
│  SpeedTestScreen · ConfigScreen · CustomRuleEditScreen           │
│  DebugScreen · AboutScreen · DnsSettingsScreen                   │
├─────────────────────────────────────────────────────────────────┤
│                       Controllers                                │
│     HomeController              SubscriptionController           │
│     (VPN, Clash API,            (подписки, entries,              │
│      nodes, ping, traffic,       refreshEntry, persist,          │
│      heartbeat, haptic)          generateConfig)                 │
├─────────────────────────────────────────────────────────────────┤
│                    Services — Parser v2                          │
│  services/parser/       — uri_parsers, json_parsers, ini_parser, │
│                           transport, body_decoder, parse_all     │
│  services/builder/      — build_config, server_list_build,       │
│                           rule_set_registry, post_steps (DPI/DNS/│
│                           custom rules — §030), validator        │
│  services/subscription/ — sources (fetch/parse), http_cache,     │
│                           auto_updater, input_helpers            │
│  services/migration/    — proxy_source_migration (one-shot v1→v2)│
│  services/debug/        — Debug API server (§031): transport     │
│                           (middleware: host-check/auth/timeout), │
│                           handlers (/state, /device, /clash,     │
│                           /action, /files, /logs, /config, /ping)│
├─────────────────────────────────────────────────────────────────┤
│                    Services — Infrastructure                     │
│  clash_api_client · settings_storage · app_info_cache            │
│  rule_set_downloader · selectable_to_custom · template_loader    │
│  haptic_service · get_free_loader · app_log · download_saver     │
│  dump_builder · url_launcher                                     │
├─────────────────────────────────────────────────────────────────┤
│                         Models                                   │
│  NodeSpec (sealed 9 вариантов) · node_spec_emit · emit_context   │
│  node_entries · node_warning · tls_spec · transport_spec         │
│  ServerList (sealed: SubscriptionServers, UserServer)            │
│  CustomRule (unified routing model — §030)                       │
│  SubscriptionMeta · SingboxEntry · TemplateVars · ValidationResult│
│  HomeState · TunnelStatus · DebugEntry · parser_config           │
├─────────────────────────────────────────────────────────────────┤
│                   Native (Kotlin)                                │
│  vpn/VpnPlugin         MethodChannel/EventChannel bridge         │
│  vpn/BoxVpnService     Android VpnService + libbox;              │
│                        companion.currentStatus (volatile mirror) │
│  vpn/ConfigManager     File-based config storage                 │
│  vpn/BoxApplication    Context + libbox initialization           │
│  vpn/ServiceNotification  Foreground notification                │
│  vpn/PlatformInterfaceWrapper  libbox PlatformInterface          │
│  vpn/DefaultNetworkMonitor/Listener  Network detection           │
├─────────────────────────────────────────────────────────────────┤
│                      Dart ↔ Native                               │
│  BoxVpnClient          Typed Dart wrapper: startVPN/stopVPN,     │
│                        getVpnStatus (pull), onStatusChanged      │
│                        (broadcast stream), getInstalledApps,     │
│                        getAppInfo, setNotificationTitle,         │
│                        auto-start/keep-on-exit toggles,          │
│                        battery-optimization navigation           │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3-слойный Parser v2 pipeline

```
UI / Controller
  │  paste / URL / QR / file  →  SubscriptionSource
  ▼
parseFromSource(source)  ─┐
  │ HTTP fetch (UrlSource)│  → ParseResult{ nodes, meta, rawBody, headers }
  │ body_decoder + parsers│
  └───────────────────────┘
  ▼
ServerList (sealed)  —  SubscriptionServers | UserServer
  │ .build(ctx: EmitContext)
  │   ├─ applies tagPrefix + allocateTag
  │   ├─ per-node emit(vars) → SingboxEntry (Outbound | Endpoint)
  │   ├─ applies detour policy (register/use/override)
  │   └─ registers in selector / auto-proxy-out groups
  ▼
buildConfig(lists, settings)
  │ template (assets/wizard_template.json)
  │ post-steps: applyCustomRules (inline + local-SRS, см. spec 030),
  │             applyTlsFragment, applyMixedCaseSni, applyCustomDns
  │ validator → ValidationResult{ fatal[], warnings[] }
  ▼
BuildResult{ config, configJson, validation, emitWarnings, generatedVars }
  │
  ▼
HomeController.saveParsedConfig(configJson)  →  native VpnService
```

**Invariants:**
- Each `NodeSpec` has round-trip `parseUri(spec.toUri()) ≈ spec`.
- Polymorphic `emit(vars)` — WireGuard → Endpoint, others → Outbound.
- `EmitContext.allocateTag(baseTag)` guarantees global uniqueness across all lists.
- Warnings bubble up: parse-time → `NodeSpec.warnings`, emit-time → appended by emit (e.g. XHTTP fallback).

---

## Дерево исходников

```
app/lib/
├── main.dart                             # Entry point, ThemeNotifier, MaterialApp
├── vpn/
│   └── box_vpn_client.dart               # Dart wrapper: MethodChannel/EventChannel
├── config/
│   ├── clash_endpoint.dart               # Extract Clash API endpoint from config
│   └── config_parse.dart                 # JSON5 → canonical JSON
├── controllers/
│   ├── home_controller.dart              # VPN lifecycle, Clash API, ping, heartbeat, haptic
│   └── subscription_controller.dart      # entries, refreshEntry, persist, generateConfig
├── models/
│   ├── node_spec.dart                    # sealed NodeSpec + 9 variants
│   ├── node_spec_emit.dart               # emit() impls per variant
│   ├── emit_context.dart                 # abstract interface for builder ctx
│   ├── node_entries.dart                 # NodeEntries{ main, detours[] }
│   ├── node_warning.dart                 # sealed NodeWarning + severity
│   ├── server_list.dart                  # sealed ServerList + SubscriptionServers/UserServer
│   ├── tls_spec.dart, transport_spec.dart # sealed TLS / Transport
│   ├── subscription_meta.dart            # profile-title, userinfo, update-interval
│   ├── singbox_entry.dart                # sealed Outbound | Endpoint
│   ├── template_vars.dart                # @vars resolution
│   ├── validation.dart                   # ValidationResult + ValidationIssue
│   ├── home_state.dart                   # Immutable state + NodeSortMode + configStaleSinceStart
│   ├── tunnel_status.dart, debug_entry.dart, parser_config.dart
├── screens/                              # UI screens (see Navigation section)
├── services/
│   ├── parser/                           # Parser v2 — URI/JSON/INI → NodeSpec
│   │   ├── uri_parsers.dart              # vless/vmess/trojan/ss/hy2/tuic/ssh/socks/wg URIs
│   │   ├── json_parsers.dart             # parseSingboxEntry, parseXrayOutbound
│   │   ├── ini_parser.dart               # WireGuard INI → wireguard:// URI → parser
│   │   ├── transport.dart                # TransportSpec parser, XHTTP fallback
│   │   ├── body_decoder.dart             # base64/json/plain auto-detect
│   │   ├── parse_all.dart                # orchestrator (list → List<NodeSpec>)
│   │   ├── uri_parsers.dart (utils)      # tagFromLabel, decodeFragment, etc.
│   ├── builder/                          # NodeSpec → sing-box config
│   │   ├── build_config.dart             # orchestrator; returns BuildResult
│   │   ├── server_list_build.dart        # ServerList.build(ctx) extension
│   │   ├── validator.dart                # dangling refs, empty urltest, etc.
│   │   └── post_steps.dart               # TLS fragment, mixed-case SNI, DNS, rules, app rules
│   ├── subscription/
│   │   ├── sources.dart                  # UrlSource/InlineSource/QrSource/File + parseFromSource
│   │   ├── http_cache.dart               # body + headers on disk; offline rehydrate
│   │   ├── auto_updater.dart             # 4 triggers + gates (spec 027)
│   │   └── input_helpers.dart            # isSubscriptionUrl/isDirectLink/isWireGuardConfig
│   ├── migration/
│   │   └── proxy_source_migration.dart   # v1 proxy_sources → v2 server_lists (one-shot)
│   ├── clash_api_client.dart             # Clash API: proxies, delay, select, connections
│   ├── settings_storage.dart             # Persistent JSON (server_lists, vars, rules, app_rules)
│   ├── haptic_service.dart               # Event-based haptic (spec 029)
│   ├── template_loader.dart              # wizard_template.json loader
│   ├── get_free_loader.dart              # Built-in free VPN preset
│   ├── rule_set_downloader.dart          # Download + cache remote .srs rule sets (parallel)
│   ├── app_log.dart                      # AppLog singleton, 4 severities
│   ├── download_saver.dart               # Save config/log to /sdcard/Download
│   ├── dump_builder.dart                 # Debug dump: config + vars + logs + server_lists
│   └── url_launcher.dart                 # External link opening
└── widgets/
    └── node_row.dart                     # Node row: ACTIVE pill, proto label, ping right-aligned

app/android/app/src/main/kotlin/com/leadaxe/lxbox/
├── MainActivity.kt                       # FlutterActivity + VpnPlugin registration
└── vpn/
    ├── VpnPlugin.kt                      # Flutter ↔ Android bridge
    ├── BoxVpnService.kt                  # VpnService + libbox + serviceScope
    ├── ConfigManager.kt                  # File-based config storage
    ├── BoxApplication.kt                 # Context holder + libbox init
    ├── ServiceNotification.kt            # Foreground notification
    ├── VpnStatus.kt                      # Enum: Stopped/Starting/Started/Stopping
    ├── PlatformInterfaceWrapper.kt       # libbox PlatformInterface impl
    ├── DefaultNetworkMonitor.kt          # Network change monitor
    ├── DefaultNetworkListener.kt         # ConnectivityManager callback actor
    ├── LocalResolver.kt                  # Local DNS transport for libbox
    └── Extensions.kt                     # Kotlin extensions
```

---

## Потоки данных

### 1. Запуск VPN

```
User tap Start (toggle button)
  │  HapticService.onConnectTap()
  ↓
HomeScreen._startWithAutoRefresh()
  │  (no HTTP fetch — auto-update is a separate concern, spec 027)
  ↓
HomeController.start()
  ↓
BoxVpnClient.startVPN() → MethodChannel → VpnPlugin
  ↓
BoxVpnService.onStartCommand()
  ├─ resetScope() → fresh serviceScope
  ├─ startForeground notification
  └─ serviceScope.launch {
       startCommandServer()
       DefaultNetworkMonitor.start(serviceScope)
       Libbox.newService(config) → libbox creates tunnel
     }
  ↓
Broadcast STATUS_CHANGED → "Started"
  ↓
EventChannel → Dart: HomeController._handleStatusEvent()
  ├─ state.configStaleSinceStart = false
  ├─ HapticService.onVpnConnected() — medium impact
  └─ AutoUpdater.onVpnConnected() — triggers refresh after 2 min
  ↓
ClashApiClient.fetchProxies() → groups (selector only), nodes
  ↓
UI updates: group dropdown, node list, traffic bar
```

### 2. Subscription добавление + авто-конфиг

```
Paste/QR/file → SubscriptionsScreen._add() | _pasteFromClipboard()
  ↓
SubscriptionController.addFromInput(text)
  ├─ isSubscriptionUrl → add SubscriptionServers entry + _fetchEntry
  ├─ isWireGuardConfig → parseWireguardIni → UserServer entry
  ├─ isDirectLink → parseUri → UserServer entry
  └─ isJsonOutbound → parseAll(decode(json)) → UserServer entries
  ↓
_persist() — writes to lxbox_settings.json
  ↓
_regenerateAndSave() — auto (v1.3.1+)
  ├─ generateConfig() — no HTTP, local assembly only
  └─ homeController.saveParsedConfig(config)
        └─ state.configStaleSinceStart = tunnelUp  (sticky flag)
  ↓
UI refreshes row (subtitle: "<PROTOCOL> server") + snackbar
  ↓
If tunnelUp: pink "Config changed — restart VPN" banner (spec 003 §8a)
```

### 3. Subscription auto-update (spec 027)

```
Trigger: appStart | vpnConnected+2min | periodic(1h) | vpnStopped | manual(force)
  ↓
AutoUpdater.maybeUpdateAll(trigger, force)
  ├─ if _running → skip (dedup)
  ├─ candidates = entries.filter(_shouldUpdate)
  │   └─ _shouldUpdate: enabled ∧ !frozen(fails>=5) ∧ !minRetry(15min) ∧ (force ∨ interval elapsed)
  └─ for entry in candidates:
       ├─ _inFlight.contains(url) → skip
       ├─ refreshEntry(entry, trigger)  → _fetchEntryByRef
       │    ├─ lastUpdateStatus==inProgress → skip (crash-safe guard)
       │    ├─ mark inProgress + persist
       │    ├─ parseFromSource(UrlSource)
       │    ├─ HttpCache.save(url, body, headers)
       │    └─ copyWith(lastUpdated, lastUpdateStatus, nodes, consecutiveFails)
       └─ sleep 10s ± 2s (between subs)
```

### 4. Subscription metadata

```
HTTP Response Headers:
  profile-title: base64:...           → subscription display name
  subscription-userinfo: upload=N; ...→ traffic quota + expire
  profile-update-interval: 24         → updateIntervalHours
  support-url: https://t.me/...
  profile-web-page-url: https://...
  content-disposition: filename="..." → fallback for title (v1.3.0+)
  ↓
Stored in SubscriptionMeta → SubscriptionServers.{name, meta, updateIntervalHours}
  ↓
Displayed in:
  - Subscription list row: "124 nodes · 🔄 24h · 🕐 3h ago · (2 fails)"
  - Subscription detail → Subscription block (URL, interval picker, status, refresh)
  - Source tab: live GET with headers view
```

### 5. Persistent storage

```
lxbox_settings.json (path_provider documents dir)
  ├─ vars: { "log_level": "warn", "clash_api": "127.0.0.1:52341", ... }
  ├─ server_lists: [                           # v2 (was proxy_sources in v1)
  │     { type: "subscription", url, name, tag_prefix, detour_policy,
  │       last_updated, last_update_attempt, last_update_status,
  │       update_interval_hours, last_node_count, consecutive_fails, meta },
  │     { type: "user", origin, created_at, raw_body, detour_policy }
  │  ]
  ├─ enabled_rules: [ "Russian domains direct", ... ]
  ├─ enabled_groups: [ "vpn-1", "auto-proxy-out" ]
  ├─ rule_outbounds: { "BitTorrent direct": "direct-out" }
  ├─ route_final: "vpn-1"
  ├─ app_rules: [ { name, packages, outbound } ]
  └─ last_global_update: "2026-04-15T..."

singbox_config.json (files dir, native)
  └─ Full sing-box JSON config (written by ConfigManager)

http_cache/<sha1(url)>.{body,headers} (documents dir)
  └─ Subscription raw body + headers (offline rehydrate on app start)

rule_sets/<tag>.srs (documents dir)
  └─ Cached binary rule set files (parallel download)

SharedPreferences:
  ├─ app_theme_mode: "system" | "light" | "dark"
  └─ haptic_enabled: "true" | "false"
```

Migration from v1 (`proxy_sources`) runs once on first read in `SettingsStorage.getServerLists` via `migrateProxySources`.

---

## Native Architecture (Kotlin)

### Structured Concurrency

```
BoxVpnService
  └─ serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
       ├─ resetScope() on each onStartCommand (cancel is terminal)
       ├─ All coroutines tied to service lifecycle
       ├─ DefaultNetworkMonitor receives serviceScope
       │    └─ checkUpdate() uses scope.launch — dies with service
       └─ onDestroy() calls serviceScope.cancel() as safety net
```

### Channel Contract

**MethodChannel** `com.leadaxe.lxbox/methods`:

| Method | Input | Output |
|--------|-------|--------|
| saveConfig | config: String | bool |
| getConfig | — | String |
| startVPN | — | bool |
| stopVPN | — | bool |
| getVpnStatus | — | "Started" \| "Starting" \| "Stopped" \| "Stopping" |
| setNotificationTitle | title: String | bool |
| getInstalledApps | — | List<Map> (package/appName/isSystemApp) |
| getAppIcon | packageName: String | String (base64 PNG) |
| getAppInfo | packageName: String | Map (name+icon+isSystem) \| null |
| getAutoStart/setAutoStart | bool | bool |
| getKeepOnExit/setKeepOnExit | bool | bool |
| isIgnoringBatteryOptimizations | — | bool |
| openBatteryOptimizationSettings | — | bool |
| openAppDetailsSettings | — | bool |
| showToast | msg: String, duration: "short"\|"long" | bool |

**EventChannel** `com.leadaxe.lxbox/status_events`:

```json
{ "status": "Started" | "Starting" | "Stopped" | "Stopping", "error": "..." }
```

---

### VPN Lifecycle & Status Sync

Модель туннеля: **`BoxVpnService` — это Android foreground-service, живущий **отдельно от Flutter-процесса**. Это даёт три состояния проекта которые надо координировать:

1. **Flutter-процесс живой, сервис живой** — нормальная работа. `setStatus(new)` в сервисе отправляет broadcast `BROADCAST_STATUS`, `VpnPlugin.statusReceiver` ловит и толкает в EventChannel sink → `HomeController._handleStatusEvent`. Всё в реальном времени.

2. **Flutter-процесс умер, сервис жив** — случается при `keep-on-exit = true` + swipe из recents / OOM-kill / system trimming. Android завершает Flutter activity + engine, но foreground-service (START_STICKY для touch-like policy) продолжает крутить sing-box и гнать трафик. Юзер возвращается → новый процесс, новый `HomeController.init`, новый listener. Broadcast'ы идут только на **transition**, а сервис уже в steady-state — никто не шлёт "I'm Started" повторно.

3. **Сервис умер системой** — OOM, краш libbox, revoked другим VPN. `setStatus(Stopped, error=...)` уходит в broadcast (если плагин ещё жив) или просто в `companion.currentStatus = Stopped` (если плагин мёртв вместе с процессом).

#### Pull-sync механика

Источник правды — `BoxVpnService.companion.currentStatus: VpnStatus` (`@Volatile`, обновляется в каждом `setStatus`). `VpnPlugin` выставляет его через MethodChannel `getVpnStatus`.

```
HomeController.init()
  ├─ _loadSavedConfig()
  ├─ _statusSub = _vpn.onStatusChanged.listen(_handleStatusEvent)  ← подписка на delta
  └─ raw = await _vpn.getVpnStatus()                               ← pull текущего
     └─ _handleStatusEvent({status: raw})  ← тот же handler, он сам решит что emit'ить
```

Без `getVpnStatus`-pull'а кейс №2 ломался: UI вечно "Disconnected" пока не случится следующий transition (а его может и не случиться, пока юзер не нажмёт Stop).

#### Broadcast vs pull — когда что

| Событие | Механика |
|---------|----------|
| Транзит (`Starting` → `Started`) | broadcast → EventChannel |
| App reattach (новый Flutter-процесс, сервис жив) | pull `getVpnStatus` в `init` |
| Heartbeat failed (`/traffic` timeout'ит) | `HomeController._onTunnelDead` → `TunnelStatus.revoked` |
| Safety-timeout (застряли в Starting/Stopping 10s) | `Future.delayed` в `_handleStatusEvent` форс'ит disconnected |

#### Reconnect flow (v1.4.0+)

`HomeController.reconnect()` — композиция `_stopInternal + _startInternal` с blocking семантикой на native:

```
1. Если tunnel уже down — просто start() и выход.
2. busy=true.
3. _stopInternal: await _vpn.stopVPN() — native блокирует до
   setStatus(Stopped) или 5с timeout. Intent-based reset sticky флага.
4. Если stop timed out — abort, lastError="Stop timed out".
5. _startInternal: setNotificationTitle + startVPN + intent-based reset.
6. busy=false в finally.
```

Никакого `firstWhere`/timeout на Dart стороне. Blocking `stopVPN` на native через `BoxVpnService.stopAwait` (Completer, сompletes в `setStatus(Stopped)`) гарантирует `status=Stopped` до `startVPN` — race в `onStartCommand` guard исключён.

До v1.4.0 reconnect строился на Dart-side координации через `firstWhere(disconnected|revoked)` и был уязвим к sink-leak в `BoxVpnClient.onStatusChanged` (исправлен через `asBroadcastStream`). Детали — `docs/spec/tasks/001-reconnect-sink-leak.md`, `002-blocking-stopvpn-intent-reset.md`.

#### Keep-on-exit настройка

Toggle в App Settings. Персистится в `SettingsStorage.keep_on_exit`, передаётся в native через `setKeepOnExit(bool)` (`BootReceiver.setKeepOnExit` — имя исторически от BootReceiver, но флаг используется и для keep-on-exit).

При значении `true` и killе Flutter-процесса система не обязана останавливать foreground-service, а на `onTaskRemoved` service сам стоп не делает. Значение `false` → service слушает task-removed и вызывает `doStop()`.

Pull-sync работает независимо от значения keep-on-exit: если сервис как-то пережил процесс, UI всё равно синхронизируется.

---

## State Management

| Controller | Responsibility |
|-----------|---------------|
| `HomeController` | VPN lifecycle, Clash API, nodes, ping (20 concurrent), heartbeat, traffic, configStaleSinceStart, autoUpdater wiring, haptic on transitions |
| `SubscriptionController` | CRUD entries (server_lists), `refreshEntry`/persist, `generateConfig` (no HTTP), `bindAutoUpdater`, init sweep (inProgress→failed) |
| `ThemeNotifier` | Theme mode, SharedPreferences persistence |
| `HapticService` (singleton) | Event-based haptic with 100 ms throttle, respects system setting (spec 029) |
| `AutoUpdater` | Owned by HomeScreen; wraps SubscriptionController for 4-trigger auto-update with spam gates (spec 027) |

Pattern: `ChangeNotifier` + `AnimatedBuilder`. `HomeState` is immutable with `copyWith` (sentinel `_unset` for nullable fields).

`_needsRestart` in HomeScreen is a derived getter — returns `true` when `state.tunnelUp && (state.configStaleSinceStart || _subController.configDirty)`. Sticky until tunnel up↔down transition (see spec 003 §8a).

---

## Navigation

```
HomeScreen
  ├─ Drawer:
  │   ├─ Servers → SubscriptionsScreen
  │   │              ├─ onTap UserServer → NodeSettingsScreen (editable Tag, Mark as detour)
  │   │              └─ onTap SubscriptionServers → SubscriptionDetailScreen
  │   │                     (Nodes / Settings / Source tabs)
  │   ├─ Routing → RoutingScreen
  │   ├─ DNS Settings → DnsSettingsScreen
  │   ├─ VPN Settings → SettingsScreen (wizard_template vars)
  │   ├─ App Settings → AppSettingsScreen (theme, autostart, haptic)
  │   ├─ Speed Test → SpeedTestScreen
  │   ├─ Statistics → StatsScreen (via traffic bar tap)
  │   ├─ Config: Editor / File / Clipboard
  │   ├─ Debug → DebugScreen (share all dump button)
  │   └─ About → AboutScreen (local build badge + git describe)
  ├─ Start/Stop toggle + sticky restart warning
  ├─ Traffic bar → tap → StatsScreen
  ├─ Group dropdown (selector groups only)
  └─ Node list:
       ├─ NodeRow layout: [ACTIVE pill] [PROTOCOL] ... [ping →]
       └─ long-press: Ping · Use · View JSON · Copy URI · Copy server/detour/both
```

---

## Key Decisions

| Decision | Reason |
|----------|--------|
| Native VPN service (no plugin) | flutter_singbox_vpn was unmaintained (0 stars), config in SharedPreferences |
| File-based config storage | Large JSON configs don't belong in SharedPreferences |
| serviceScope vs GlobalScope | Structured concurrency — coroutines die with service |
| Clash API for management | sing-box provides HTTP API, no need for custom libbox bindings |
| 20 concurrent mass ping | Sequential was too slow for 50+ nodes |
| Random Clash API port | Prevent port scanning (49152-65535) |
| Auto-generated secret | Never empty — security by default |
| SRS rules off by default | Require download, may fail offline |
| App list caching | getInstalledApps (~5s) called once, reused |
| profile-title from headers + content-disposition fallback | Auto-name subscriptions even without profile-title |
| URLTest hidden from dropdown | Users can't manually select in urltest — confusing UX |
| **Sealed `NodeSpec`** (Parser v2, v1.3.0) | Exhaustive switch at compile time; no runtime `type == 'vmess'` checks |
| **3-layer parser/builder** | Separation of concerns: parse ≠ build ≠ emit |
| **UserServer.toJson stores only rawBody** | `nodes` is derivable via `parseAll(decode(rawBody))` on fromJson; saves disk space, avoids NodeSpec serialization drift |
| **AutoUpdater gates** (spec 027) | `minRetryInterval=15min`, `maxFailsPerSession=5`, `_running`/`_inFlight` dedup — subscriptions never spam providers |
| **configStaleSinceStart sticky flag** | Restart warning doesn't disappear on Stop-dialog cancel |
| **TLS-insecure → info severity** | Providers set it intentionally (REALITY, self-signed); shouldn't crowd out genuine warnings |

---

## Dependencies

| Package | Purpose |
|---------|---------|
| `http` | Clash API + subscription fetch |
| `json5` | JSON5/JSONC config parsing |
| `file_picker` | Config import from filesystem |
| `path_provider` | Documents directory for persistent storage |
| `shared_preferences` | Theme mode, haptic toggle |
| `share_plus` | Config/log export via system share sheet |
| **libbox** (native) | sing-box core (JitPack: singbox-android:libbox:1.12.12) |

---

## Feature Specs

Живут в [`docs/spec/features/`](./spec/features/). Каждая фича — папка `NNN name/spec.md`:

| # | Feature |
|---|---------|
| 001 | Mobile stack |
| 002 | MVP scope |
| 003 | Home screen |
| 004 | Subscription parser (superseded by 026) |
| 005 | Config generator (superseded by 026) |
| 006 | Servers UI |
| 007 | Config editor |
| 008 | Ping and node management |
| 009 | UX and theme |
| 010 | Quick start and offline |
| 011 | Local ruleset cache |
| 012 | Native VPN service |
| 013 | Routing |
| 014 | DNS settings |
| 015 | Speed test |
| 016 | Statistics and connections |
| 017 | Custom nodes and node settings |
| 018 | Detour server management |
| 019 | WireGuard endpoint |
| 020 | Security and DPI bypass (TLS fragment) |
| 021 | CI/CD pipeline |
| 022 | App settings |
| 023 | Debug and logging |
| 024 | Load balance |
| 025 | WARP integration |
| **026** | **Parser v2** (sealed NodeSpec, 3-layer pipeline) |
| **027** | **Subscription auto-update** (4 triggers, spam gates) |
| **028** | **AntiDPI: mixed-case SNI** |
| **029** | **Haptic feedback** |
