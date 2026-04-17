# Архитектура L×Box

Документ описывает структуру Flutter-приложения L×Box, зоны ответственности, потоки данных и ключевые решения.

---

## Обзор

L×Box — Android VPN-клиент на базе **sing-box** (через **libbox**). Полный цикл: подписки → парсинг → конфиг → VPN-туннель → управление через **Clash API**.

```
┌─────────────────────────────────────────────────────────────┐
│                        Flutter UI                            │
│  HomeScreen · RoutingScreen · SubscriptionsScreen            │
│  AppSettingsScreen · ConnectionsScreen · SubscriptionDetail  │
│  AppPickerScreen · ConfigScreen · DebugScreen · AboutScreen  │
├─────────────────────────────────────────────────────────────┤
│                      Controllers                             │
│     HomeController              SubscriptionController       │
│     (VPN, Clash API,            (подписки, fetch,            │
│      nodes, ping, traffic)       config generation)          │
├─────────────────────────────────────────────────────────────┤
│                       Services                               │
│  ConfigBuilder · SourceLoader · NodeParser · ClashApiClient  │
│  SubscriptionFetcher · SubscriptionDecoder · XrayJsonParser  │
│  SettingsStorage · GetFreeLoader · RuleSetDownloader         │
├─────────────────────────────────────────────────────────────┤
│                       Models                                 │
│  HomeState · ProxySource · ParsedNode · ParserConfig         │
│  WizardTemplate · SelectableRule · AppRule · TunnelStatus    │
├─────────────────────────────────────────────────────────────┤
│                   Native (Kotlin)                            │
│  vpn/VpnPlugin         MethodChannel/EventChannel bridge     │
│  vpn/BoxVpnService     Android VpnService + libbox           │
│  vpn/ConfigManager     File-based config storage             │
│  vpn/BoxApplication    Context + libbox initialization       │
│  vpn/ServiceNotification  Foreground notification            │
│  vpn/PlatformInterfaceWrapper  libbox PlatformInterface      │
│  vpn/DefaultNetworkMonitor/Listener  Network detection       │
├─────────────────────────────────────────────────────────────┤
│                    Dart ↔ Native                             │
│  BoxVpnClient          Typed Dart wrapper over channels      │
└─────────────────────────────────────────────────────────────┘
```

---

## Дерево исходников

```
app/lib/
├── main.dart                          # Entry point, ThemeNotifier, MaterialApp
├── vpn/
│   └── box_vpn_client.dart            # Dart wrapper: MethodChannel/EventChannel
├── config/
│   ├── clash_endpoint.dart            # Extract Clash API endpoint from config
│   └── config_parse.dart              # JSON5 → canonical JSON
├── controllers/
│   ├── home_controller.dart           # VPN lifecycle, Clash API, ping, traffic
│   └── subscription_controller.dart   # CRUD subscriptions, config generation
├── models/
│   ├── home_state.dart                # Immutable state + NodeSortMode
│   ├── proxy_source.dart              # ProxySource (url, connections, metadata)
│   ├── parsed_node.dart               # ParsedNode + ParsedJump
│   ├── parser_config.dart             # WizardTemplate, PresetGroup, SelectableRule
│   ├── tunnel_status.dart             # Enum from native events
│   └── debug_entry.dart               # Debug log entry
├── screens/
│   ├── home_screen.dart               # Main: VPN toggle, groups, nodes, traffic
│   ├── routing_screen.dart            # Proxy Groups + Rules + App Groups + route.final
│   ├── app_picker_screen.dart         # App selection with icons, search, cache
│   ├── subscriptions_screen.dart      # Add/manage subscriptions + Get Free VPN
│   ├── subscription_detail_screen.dart # Nodes, traffic stats, support links
│   ├── connections_screen.dart        # Live connection list (tap traffic bar)
│   ├── settings_screen.dart           # VPN Settings (vars only)
│   ├── app_settings_screen.dart       # App Settings (theme)
│   ├── config_screen.dart             # JSON editor + share
│   ├── debug_screen.dart              # Debug events + export
│   └── about_screen.dart              # Credits, tech stack
├── services/
│   ├── config_builder.dart            # Template + vars + nodes → sing-box JSON
│   ├── source_loader.dart             # ProxySource → LoadResult (nodes + metadata)
│   ├── node_parser.dart               # URI → ParsedNode (vless, vmess, trojan, ss, hy2...)
│   ├── xray_json_parser.dart          # Xray JSON Array → ParsedNode (jump/detour)
│   ├── subscription_fetcher.dart      # HTTP fetch + profile-title/userinfo/support-url
│   ├── subscription_decoder.dart      # Base64/JSON/plain text decode
│   ├── clash_api_client.dart          # Clash API: proxies, delay, select, connections
│   ├── settings_storage.dart          # Persistent JSON + AppRule model
│   ├── get_free_loader.dart           # Built-in free VPN preset
│   └── rule_set_downloader.dart       # Download + cache remote .srs rule sets
└── widgets/
    └── node_row.dart                  # Node row: status, delay, urltest now, context menu

app/android/app/src/main/kotlin/com/leadaxe/lxbox/
├── MainActivity.kt                    # FlutterActivity + VpnPlugin registration
└── vpn/
    ├── VpnPlugin.kt                   # Flutter ↔ Android bridge (MethodChannel + EventChannel)
    ├── BoxVpnService.kt               # VpnService + libbox + serviceScope concurrency
    ├── ConfigManager.kt               # File-based config storage
    ├── BoxApplication.kt              # Context holder + libbox initialization
    ├── ServiceNotification.kt         # Foreground notification
    ├── VpnStatus.kt                   # Enum: Stopped/Starting/Started/Stopping
    ├── PlatformInterfaceWrapper.kt    # libbox PlatformInterface implementation
    ├── DefaultNetworkMonitor.kt       # Network change monitor (accepts serviceScope)
    ├── DefaultNetworkListener.kt      # ConnectivityManager callback actor
    ├── LocalResolver.kt               # Local DNS transport for libbox
    └── Extensions.kt                  # Kotlin extensions (toIpPrefix, toList)
```

---

## Потоки данных

### 1. Запуск VPN

```
User tap "Start" (toggle button)
  ↓
HomeScreen._startWithAutoRefresh()
  ├─ shouldRefreshSubscriptions(reload interval)?
  │   └─ YES → SubscriptionController.updateAllAndGenerate()
  │              ├─ SubscriptionFetcher.fetchWithMeta(url)
  │              │    ├─ HTTP GET → decode content
  │              │    └─ Parse headers: profile-title, subscription-userinfo, support-url
  │              ├─ SourceLoader.loadNodesWithMeta()
  │              │    ├─ XrayJsonParser or NodeParser per line
  │              │    └─ _dedup() — sync tag in node + outbound
  │              └─ ConfigBuilder.generateConfig()
  │                   ├─ loadTemplate() → WizardTemplate
  │                   ├─ _ensureClashApiDefaults() → random port + auto secret
  │                   ├─ _substituteVars() → resolve @var references
  │                   ├─ Remove sniff rule if disabled
  │                   ├─ _buildPresetOutbounds() → node outbounds + groups
  │                   ├─ _applySelectableRules() → routing rules + user outbounds
  │                   ├─ _applyAppRules() → package_name routing rules
  │                   ├─ Apply route.final
  │                   └─ _cacheRemoteRuleSets() → download .srs locally
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
EventChannel → Dart: _handleStatusEvent()
  ↓
ClashApiClient.fetchProxies() → groups (selector only), nodes
  ↓
UI updates: group dropdown, node list
```

### 2. Subscription metadata

```
HTTP Response Headers:
  profile-title: base64:... → subscription display name
  subscription-userinfo: upload=N; download=N; total=N; expire=N
  support-url: https://t.me/...
  profile-web-page-url: https://...
  ↓
Stored in ProxySource: name, uploadBytes, downloadBytes,
  totalBytes, expireTimestamp, supportUrl, webPageUrl
  ↓
Displayed in:
  - Subscription list: support icon (telegram for t.me)
  - Subscription detail: traffic bar, expire, support/web chips
```

### 3. Persistent storage

```
lxbox_settings.json (path_provider)
  ├─ vars: { "log_level": "warn", "clash_api": "127.0.0.1:52341", ... }
  ├─ proxy_sources: [ { source, name, tag_prefix, last_updated, traffic stats, ... } ]
  ├─ enabled_rules: [ "Russian domains direct", ... ]
  ├─ enabled_groups: [ "proxy-out", "auto-proxy-out" ]
  ├─ rule_outbounds: { "BitTorrent direct": "direct-out" }
  ├─ route_final: "proxy-out"
  ├─ app_rules: [ { name, packages, outbound } ]
  └─ last_global_update: "2026-04-15T..."

singbox_config.json (files dir, native)
  └─ Full sing-box JSON config (written by ConfigManager)

SharedPreferences:
  └─ app_theme_mode: "system" | "light" | "dark"

rule_sets/<tag>.srs (documents dir)
  └─ Cached binary rule set files
```

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
| setNotificationTitle | title: String | bool |
| getInstalledApps | — | List<Map> |

**EventChannel** `com.leadaxe.lxbox/status_events`:

```json
{ "status": "Started" | "Starting" | "Stopped" | "Stopping", "error": "..." }
```

---

## State Management

| Controller | Responsibility |
|-----------|---------------|
| `HomeController` | VPN lifecycle, Clash API, nodes, ping (20 concurrent), heartbeat, traffic |
| `SubscriptionController` | CRUD subscriptions, fetch with metadata, config generation |
| `ThemeNotifier` | Theme mode (light/dark/system), SharedPreferences persistence |

Pattern: `ChangeNotifier` + `AnimatedBuilder`. `HomeState` is immutable with `copyWith` (sentinel `_unset` for nullable fields).

---

## Navigation

```
HomeScreen
  ├─ Drawer:
  │   ├─ Subscriptions → SubscriptionsScreen
  │   │                    └─ onTap → SubscriptionDetailScreen
  │   │                    └─ empty state → Get Free VPN
  │   ├─ Routing → RoutingScreen
  │   │              ├─ Proxy Groups (switch)
  │   │              ├─ Routing Rules (switch + outbound dropdown + SRS download)
  │   │              ├─ App Groups (name + apps + outbound) → AppPickerScreen
  │   │              └─ Default traffic (route.final)
  │   ├─ VPN Settings → SettingsScreen (vars: MTU, sniff, IP, stack, log, clash...)
  │   ├─ App Settings → AppSettingsScreen (theme)
  │   ├─ Config: Editor / File / Clipboard
  │   ├─ Debug → DebugScreen
  │   └─ About → AboutScreen
  ├─ Start/Stop toggle (single button, red/green)
  ├─ Traffic bar → tap → ConnectionsScreen (live connections, close)
  ├─ Group dropdown (selector groups only, no urltest)
  └─ Node list (urltest nodes show "→ auto-selected", context menu with Copy JSON)
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
| profile-title from headers | Auto-name subscriptions instead of showing raw URL |
| URLTest hidden from dropdown | Users can't manually select in urltest — confusing UX |

---

## Dependencies

| Package | Purpose |
|---------|---------|
| `http` | Clash API + subscription fetch |
| `json5` | JSON5/JSONC config parsing |
| `file_picker` | Config import from filesystem |
| `path_provider` | Documents directory for persistent storage |
| `shared_preferences` | Theme mode persistence |
| `share_plus` | Config/log export via system share sheet |
| **libbox** (native) | sing-box core (JitPack: singbox-android:libbox:1.12.12) |

---

## Features Index

| # | Feature | Status |
|---|---------|--------|
| 001–010 | MVP → Quick Start | Implemented |
| 011 | Local Rule Set Cache | Implemented |
| 012 | Xray JSON Array + Chained Proxy | Implemented |
| 013 | Native VPN Service | Implemented |
| 014 | Subscription Detail View | Implemented |
| 015 | Rule Outbound Selection | Implemented |
| 016 | Routing Screen | Implemented |
| 017 | App Groups (Per-App Outbound) | Implemented |
| 018 | Custom Nodes (Manual + Override) | Spec ready |
| 019 | Load Balance (PuerNya fork) | Spec ready |
| 020 | Multi-Hop Chained Proxy | Implemented |
| 021 | Speed Test | Implemented |
| 022 | Node Filter | Implemented |
| 023 | Auto Connect on Boot | Implemented |
| 024 | Statistics and Connections | Implemented |
| 025 | DNS Settings | Implemented |
| 026 | Subscription Toggles | Implemented |
| 027 | Autosave | Implemented |
| 028 | Subscription Caching | Implemented |
| 029 | Subscription Context Menu | Implemented |
| 030 | URL Launcher | Implemented |
| 031 | Wizard Template Architecture | Implemented |
| 032 | Ping Settings | Implemented |
| 033 | URLTest Configuration | Implemented |
| 034 | Node Context Menu | Implemented |
| 035 | Traffic Bar and Navigation | Implemented |
| 036 | Sort Modes | Implemented |
| 037 | CI/CD Pipeline | Implemented |
| 038 | Subscription Detail Enhancements | Implemented |
| 039 | Security Hardening | Implemented |
| 040 | TLS Fragment (DPI bypass) | Implemented |
| 041 | WireGuard Support | Implemented |
| 042 | Node Settings | Implemented |
| 043 | Paste Dialog | Implemented |
| 044 | Jump Server Naming / WARP Integration | Implemented |
