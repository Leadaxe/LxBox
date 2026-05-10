# Архитектура L×Box

Документ описывает структуру Flutter-приложения L×Box, зоны ответственности, потоки данных и ключевые решения.

Текущая версия парсер/билдера — **v2** (spec 026, phase 5 completed в v1.3.0). Подробности см. в [spec/features/026 parser v2](./spec/features/026%20parser%20v2/spec.md).

---

## Supported platforms

| Параметр | Значение |
|----------|----------|
| Android minSdk | **26** (Android 8.0) |
| Android targetSdk | `flutter.targetSdkVersion` (актуальная target, обычно API 34/35) |
| Android compileSdk | `flutter.compileSdkVersion` |
| JVM | Java 17 |
| NDK | 28.2.13676358 |

### Поддержка по тирам

| Tier | Android | Статус |
|------|---------|--------|
| **Primary** | 11+ (API 30+) | Тестируется, все фичи работают, production-ready |
| **Best-effort** | 8.0–10 (API 26–29) | Compile OK, install OK, базовый VPN-функционал должен работать. Фичи требующие API 30+ (например, silent-kill detection через `getHistoricalProcessExitReasons`) деградируют к no-op. Не тестируется регулярно; жалобы принимаются, но fix'ы на best-effort основе. |
| **Unsupported** | <8 (API <26) | Установка заблокирована `minSdk=26` |

### Почему именно 26 как minSdk

- **Исторически** в release notes 1.3.x и draft 1.4.0 заявлено «Android 8.0+» — не закрываем дверь пользователям которые видели эту декларацию.
- **VpnService API** (`setMetered`, `setUnderlyingNetworks`) доступны с API 29+, для старых есть fallback-пути (без setMetered — vpn работает нормально, просто не маркируется как non-metered).
- **`ActivityManager.getHistoricalProcessExitReasons`** (API 30+) — нужен для silent-kill detection в task 007. В коде обёрнут в `if (Build.VERSION.SDK_INT >= 30)` — на старых просто не триггерит snackbar.
- **Foreground-service lifecycle** на API 26+ достаточно стабилен для наших целей.

### Legacy `Build.VERSION.SDK_INT` проверки

В Kotlin (DefaultNetworkMonitor, ServiceNotification, BoxApplication, etc.) остались старые version guards — часть libbox-adjacent кода. С `minSdk=26` некоторые из них (`>= M (23)`, `>= N (24)`) всегда true, их можно упростить. Отдельный cleanup-pass после стабилизации 1.4.0, чтобы не мешать с другими изменениями.

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
│  NodeSpec (sealed 10 вариантов) · node_spec_emit · emit_context  │
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
  │ post-steps (в порядке выполнения):
  │   1. server_list_build   → outbounds/endpoints из ServerList
  │   2. applyPresetBundles  → expansion CustomRule(kind: preset),
  │                            merge → registry + extra DNS (spec 033)
  │   3. applyCustomRules    → inline + local-SRS правила (spec 030)
  │   4. flush registry      → config.route.{rule_set, rules}
  │   5. applyTlsFragment, applyMixedCaseSni  → TLS-обфускация (spec 028)
  │   6. applyCustomDns      → dns.servers/rules из template + bundle-extras
  │   7. validator → ValidationResult{ fatal[], warnings[] }
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

## Wizard template (`assets/wizard_template.json`)

Asset-шаблон, который читается один раз через `TemplateLoader.load()` (синглтон, deep-copy на каждый билд). Определяет скелет sing-box конфига, глобальные переменные, preset-группы (VPN tiers) и selectable-правила (каталог routing-пресетов).

### Секции шаблона

| Секция | Роль | Пример / где используется |
|---|---|---|
| `parser_config` | sing-box `version` + reload interval | прямой emit в корень |
| `dns_options.servers` | Canonical DNS-серверы (system/google/cloudflare/quad9/adguard). Storage хранит kind-refs `{enabled, kind: inline\|preset\|template, tag, description?, body?}` (§043 + §044). Body для kind:inline — partial sing-box shape **без** tag/description/enabled (они на ref-level; tag синтезируется на build-time). Резолвится в bodies через `resolveDnsServersBodies`. | `applyCustomDns` через `resolveDnsServersList` |
| `dns_options.rules` | Дефолтные DNS-rules. Storage — kind-refs (§041) (`inline\|srs\|preset\|template`). Catch-all удалён в §039 — fall-through идёт через `dns.final`. | `applyCustomDns`: bundle-rules через `resolveDnsRulesList` |
| `ping_options`, `speed_test_options` | UI-фичи (HomeScreen, SpeedTest) | не попадают в sing-box конфиг |
| `preset_groups` | Группы outbound'ов (`vpn-1`/`vpn-2`/`vpn-3`, `@auto`) | `_buildPresetGroups` в `build_config.dart` |
| `config` | База sing-box конфига: log, inbounds, route-skeleton | deep-copy'ится в начале `buildConfig` |
| `sections[].vars[]` | Глобальные переменные UI — chapter: `core` / `routing` / `dns` | `TemplateVarListView` рендерит в SettingsScreen/RoutingScreen; `@name` подставляется в config через `_substituteVars` |
| `selectable_rules` | Каталог пресет-правил (legacy inline + bundle — spec 033) | вкладка Presets в `RoutingScreen` |

### Selectable rules — два режима

Пресет в `selectable_rules[]` работает в одном из двух режимов:

**Legacy (до v1.4.x, без `preset_id`):**
```json
{
  "label": "BitTorrent direct",
  "default": true,
  "rule": { "protocol": ["bittorrent"], "outbound": "direct-out" }
}
```
Копируется юзером в `CustomRule(kind: inline | srs)` через `selectableRuleToCustom` — содержимое копируется **по значению**, дальнейшие правки шаблона не влияют на уже скопированное правило.

**Bundle (v1.5+, `preset_id` задан) — spec 033:**
```json
{
  "preset_id": "ru-direct",
  "label": "Russian domains direct",
  "default": true,

  "vars": [
    {"name": "out", "type": "outbound", "default_value": "direct-out", "title": "Outbound"},
    {"name": "dns_server", "type": "dns_servers", "required": false, "default_value": "yandex_doh", "title": "Transport"},
    {"name": "dns_ip", "type": "enum", "default_value": "77.88.8.88", "options": [
      {"title": "77.88.8.88 · Safe", "value": "77.88.8.88"}, ...
    ]}
  ],
  "rule_set":    [ { "tag": "ru-domains", "type": "inline", "format": "domain_suffix", "rules": [...] } ],
  "dns_rule":    { "rule_set": "ru-domains", "server": "@dns_server" },
  "rule":        { "rule_set": "ru-domains", "outbound": "@out" },
  "dns_servers": [
    {"type": "https", "tag": "yandex_doh", "server": "77.88.8.88", "port": 443, "path": "/dns-query", "tls": {"enabled": true, "server_name": "safe.dot.dns.yandex.net"}, "detour": "@out"},
    ...
    {"type": "udp",   "tag": "yandex_udp", "server": "@dns_ip", "server_port": 53, "detour": "@out"}
  ]
}
```
`CustomRule(kind: preset)` хранит **тонкую ссылку** — только `{presetId, varsValues}`. Expansion (`preset_expand.dart`) на каждый билд:
1. Резолвит переменные из `varsValues` (или `default_value` если ключ отсутствует; для `required: false` + отсутствие ключа + пустой default → `null` → фрагменты с `@var` выкидываются).
2. Рекурсивно подставляет `@var` в `rule_set`/`dns_rule`/`rule`/`dns_servers`.
3. Фильтрует `dns_servers` до одного с `tag == vars['dns_server']`.
4. Если `@out` резолвится в `"direct-out"` — удаляет `detour` из DNS-серверов (direct не требует forwarding).

Merge фрагментов от разных `CustomRule(kind: preset)` — identical-skip по tag + first-wins с warning для реальных конфликтов, детерминированный порядок по индексу в UI.

### Vars

`WizardVar` едина для глобальных `sections[].vars[]` и preset-local `selectable_rules[i].vars[]`. Поддерживаемые типы (`type`):

| `type` | UI | Substitution |
|---|---|---|
| `bool` | SwitchListTile | `"true"` / `"false"` → Dart bool |
| `text` | TextField (+ combo-popup если есть `options`) | строка |
| `enum` | Dropdown с `title → value` | строка (`value`) |
| `secret` | TextField с eye-toggle + Generate | строка |
| `outbound` (preset only) | OutboundPicker | строка (tag) |
| `dns_servers` (preset only) | Dropdown по `preset.dns_servers[].tag` | строка (tag) |

**`options`** принимает два формата (legacy-совместимо): строка-литерал (`"foo"` ≡ `{title: "foo", value: "foo"}`) или объект `{"title": "...", "value": "..."}`. UI показывает `title`, expansion/storage — `value`.

**`required: bool`** (default `true`) — для optional var в UI появляется пункт "— (none)"; при выборе → `varsValues[name] = ""`. Expansion отличает `containsKey=false` (юзер не трогал → применяется `default_value`) от `value=""` (юзер явно выбрал none → `null`).

### Как связаны слои

```
wizard_template.json
  │  load (TemplateLoader)  →  WizardTemplate (в памяти, shared)
  │
  ├── config       ──► _substituteVars(@global vars)                          ──► base config
  ├── selectable_rules (bundle)
  │    └── + CustomRule(kind: preset).varsValues
  │         │  expandPreset (pure)                                            ──► PresetFragments
  │         │  mergeFragments (identical-skip / first-wins)                   ──► BundleMerge
  │         └─ applyPresetBundles  → rule_set/routes → registry; DNS → extras
  ├── selectable_rules (legacy)
  │    └── + CustomRule(kind: inline|srs)
  │         └─ applyCustomRules    → rule_set/routes → registry (auto-suffix)
  ├── dns_options  ──► applyCustomDns(template + extras)                      ──► config.dns
  └── preset_groups ──► _buildPresetGroups(vpn-1..3, @auto)                   ──► config.outbounds
```

**Почему DoH/DoT в bundle хардкодят `server: "77.88.8.88"` + `tls.server_name`:**
В sing-box 1.12 DNS-сервер типа `https`/`tls` с hostname-сервером требует `domain_resolver` (тег другого DNS-сервера для bootstrap resolve), иначе chicken-and-egg. Указывая IP напрямую + `tls.server_name` для SNI/cert verify — избавляемся от bootstrap dependency (не нужно ходить в 8.8.8.8 для резолва `safe.dot.dns.yandex.net`) и получаем Safe-профиль Yandex с корректной TLS проверкой.

`@dns_ip` применяется **только** к UDP-серверу — для DoH/DoT замена IP сломала бы TLS (cert mismatch с захардкоженным SNI). Для реально разных режимов Yandex (Safe/Base/Family) → отдельные пресеты, если понадобятся, чтобы не городить nested-lookup в substitution-движке.

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
│   ├── node_spec.dart                    # sealed NodeSpec + 10 variants (vless/vmess/trojan/ss/hy2/naive/tuic/ssh/socks/wg)
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
│   ├── app_log.dart                      # AppLog singleton, 4 severities + per-source quotas (§043)
│   ├── clash_log_pump.dart                # §043: pump sing-box logs из EventChannel "lxbox/coreLog" → AppLog (DebugSource.core)
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

Состояние L×Box живёт в двух местах с разной семантикой:

- **`wizard_template.json`** — **catalog**: что вообще существует (preset'ы, vars, sections, default DNS-серверы). Bundled в APK, меняется в коммите. Полная схема — [TEMPLATE.md](./TEMPLATE.md).
- **`lxbox_settings.json`** — **user-state**: что юзер выбрал/настроил (vars override, custom_rules, enabled_groups). Меняется в runtime через UI / Debug API. Полная схема — [STORAGE.md](./STORAGE.md).

#### Catalog (template, bundled in APK)

```
app/assets/wizard_template.json     # rootBundle.loadString(), template_loader.dart
├── parser_config           # §026 — version + reload interval
├── dns_options             # §043+§044 — default DNS servers + rules
├── ping_options            # §040 — default URL + presets
├── speed_test_options      # §015 — speed-test endpoints
├── preset_groups[]         # selector/urltest группы (vpn-1, vpn-2, vpn-3, ✨auto)
├── sections[]              # §022 — Wizard UI chapters (vars сгруппированы по темам)
├── config                  # нативная sing-box-секция с @var-плейсхолдерами
│   ├── log / dns / inbounds / endpoints / outbounds / experimental
│   └── route               #   rules[] / rule_set[] / final / default_domain_resolver
└── selectable_rules[]      # §033 — catalog preset'ов: block-ads, ru-direct,
                            #   ru-inside, bittorrent-direct, private-ip-direct
```

#### User-state (на устройстве)

```
<getApplicationDocumentsDirectory>/
├── lxbox_settings.json     # SettingsStorage (Dart) — главный файл состояния:
│                           #   vars / server_lists / custom_rules /
│                           #   dns_options / ping_options /
│                           #   route_final / excluded_nodes / enabled_groups /
│                           #   last_global_update / presets_migrated
├── singbox_config.json     # ConfigManager (Kotlin) — финальный sing-box JSON
├── http_cache/             # HttpCache — сырое тело + headers подписок
│   └── <sha1(url)>.{body,headers}
├── rule_sets/              # §011 — кэш бинарных .srs
│   └── <tag>.srs
├── applog.txt              # §038/§043 — JSON-lines, 200 строк / 64KB ring
└── corelog.txt             # §043 — JSON-lines, 200 строк / 64KB ring

SharedPreferences (Android):
├── app_theme_mode, haptic_enabled       # Flutter UI prefs
└── boxvpn_boot.{auto_start_vpn, keep_vpn_on_exit, background_mode,
                 core_logs_enabled}      # §043: core_logs_enabled здесь
                                         # потому что читается в
                                         # BoxApplication.initialize() ДО
                                         # Flutter engine'а
```

#### Builder (template + user-state → final config)

`build_config.dart` мерджит template `config`-секцию + `selectable_rules[*]` (через `expandPreset`) + `dns_options.{servers,rules}` (через resolvers §041/§044) + `preset_groups` (с активными node-tag'ами из `server_lists`) + `vars`-substitution → пишет финальный `singbox_config.json` для libbox.

One-shot миграции (`SettingsStorage`):
- `proxy_sources` → `server_lists` (v1 → v2, §033) — `migrateProxySources` на первом чтении.
- `app_rules` → `custom_rules` с `packages` (до v1.3.2 → §030) — `_absorbLegacyAppRules`.
- `enabled_rules + rule_outbounds` → `custom_rules` (до §030) — в `RoutingScreen._load`, гард `presets_migrated`.
- `dns_options.servers[]` shape: pre-§043 → §043 → §044 — `_migrateLegacyDnsServers` в builder post-steps.

Sensitive-поля при `GET /state/storage` фильтруются allow-list'ом в `services/debug/serializers/storage.dart` (`debug_token`, subscription URLs, support/web URLs из `meta`). Подробности — STORAGE.md §"Debug API exposure".

---

### 6.5. Per-app traffic profiler (§044)

`TrafficProfiler` — singleton ChangeNotifier, который держит **одну** active recording session + ring-buffer (cap=5) последних завершённых. Всё in-memory; persist принципиально не делается. Spec: [`docs/spec/features/044 per-app traffic profiler/spec.md`](./spec/features/044%20per-app%20traffic%20profiler/spec.md). User guide: [`docs/features/per-app-trace.md`](./features/per-app-trace.md).

```
              ┌────────────────────────────────────────┐
              │  TrafficProfiler (singleton)            │
              │   _active: Session? + _completed: Q[5]  │
              └────────────────────────────────────────┘
                     ▲                    ▲
                     │ events             │ events
                     │                    │
        ┌────────────┴────────┐  ┌────────┴──────────────────┐
        │ Source A: log stream│  │ Source B: /connections poll│
        │  AppLog (core src)  │  │  Clash API every 2s        │
        │  ts-diff drain      │  │  diff vs prev snapshot     │
        └─────────────────────┘  └────────────────────────────┘
                     │                    │
                     ▼                    ▼
        DNS resolves + CNAME       TCP/UDP open/close events
        attribution by conn-id     attribution by metadata.process
                                   (UID-stripped) или process inference

              ┌────────────────────────────────────────┐
              │ Session.events  (append-only)           │
              │  +  byDomain / byIp aggregates          │
              │     (computed on-demand)                │
              └────────────────────────────────────────┘
                     │
        ┌────────────┴───────────────────────────────────────────┐
        ▼                              ▼                         ▼
  PerAppTraceTab UI         Debug API /profiler/*          SSE /profiler/stream
  (Live/Domains/IPs/        (start, stop, active,          (live-push для
   Connections)              session/<id>, sessions,        external clients)
                             stream)
```

**Spawning rules:**
- Source A live-listen на `AppLog.I` (core source). Drain timestamp-diff'ом — не length, чтобы не залипать на ring-buffer cap=500. Regex'ы ловят `router: found package name`, `dns: exchanged|cached`, `dns: exchange failed`. Per-conn-id accumulator (`_DnsAccumulator`) держит первый-запрошенный domain + CNAME chain.
- Source B `Timer.periodic(2s)` пока есть active session **или** global recording on (§048). Connections фильтруются по `metadata.process` (с UID-strip) или `processPath` или process-inference (10s post-DNS window — IP должен быть в resolved-IPs prior session events).
- Connection-issue classifier per-event: 2 locale-агностичных типа — `dnsTimeout` (прямой engine-сигнал из `dns: exchange failed` лога) + `tcpReset` (heuristic: TCP закрылся <1с с 0 bytes, вероятный RST/firewall).

**Global / system-wide recording (§048).** Live tab в Statistics — **четвёртый mode** профайлера (рядом с per-app session): `startGlobalRecording()` подключает Source A + Source B без active session. События идут в `_globalRollingBuffer` (60s window) и `globalLiveStream()` SSE. `_pollConnections()` сделан session-agnostic: session-only блоки (`_resolveForSession`, `_appendEvent(s, ev)`) gated на `if (s != null)`, snapshot tracking `_connSnapshots[id]` unconditional (нужен для closed-detection в global-only режиме). `_maybeStopConnectionPoll()` останавливает таймер только когда **оба** off (session and global) — симметрично `_maybeDetachLogListener` и `_maybeStopGcTimer`. Idle profiler по-прежнему ничего не делает (нет timers, нет AppLog listener).

**Memory bounds:**
- `Session.events`: cap = 50000 events ИЛИ 3h sliding window (что раньше). `eventsDropped` в meta.
- `_completed`: ListQueue cap = 5 sessions, FIFO-evict.
- `_connIdToMeta` / `_dnsByConnId`: GC по 30s TTL, trigger когда map > 256 entries.

**UI plumbing:**
- HomeScreen `_buildTrafficBar` показывает ⚡-chip с short package name (`ru.tinkoff` для `ru.tinkoff.investing`) когда session active. Tap всей строки → `StatsScreen(initialTab: StatsTab.perApp)`.
- `StatsScreen` 3-й tab `Per-app` с ⚡ возле title.
- `PerAppTraceTab` 4 sub-tab'а: Live / Domains / IPs / Connections. Search-by-IP в Domains, inline expand на Connections, ↗ IP-jump иконки везде где рендерится IP — все три view связаны двусторонней навигацией.

---

### 6. AppLog (per-source ring buffers, §043)

`AppLog` хранит in-memory кольцевые буферы **per source** — `app=300`, `core=500`. Sing-box (verbose, сотни строк/мин на busy traffic) не вытесняет наши собственные app-сообщения.

```
HomeController/UI                    Sing-box (Go goroutines)
       │                                       │
       │ AppLog.I.info(...)                    │ writeDebugMessage(line)
       │   source: app                         │   ↓
       │                              [PlatformInterface override]
       │                              BoxVpnService.writeDebugMessage:
       │                                ├─ strip ANSI escapes
       │                                ├─ skip TRACE/DEBUG (volume reduction)
       │                                └─ coreLogSink.success(msg)  ← main thread post
       │                                       │
       │                              EventChannel "lxbox/coreLog"
       │                                       │
       │                              ClashLogPump.attach() listener
       │                                       │ parseLevel (regex \bWARN\b etc.)
       │                                       │ AppLog.I.log(level, msg, source: core)
       ▼                                       ▼
┌─────────────────────────────────────────────────────┐
│           AppLog (singleton)                          │
│                                                       │
│  Map<DebugSource, List<DebugEntry>> _entriesBySource  │
│   ├─ app:  [...] cap 300                              │
│   └─ core: [...] cap 500                              │
│                                                       │
│  log(level, msg, source) — O(1) amortized insert      │
│    + per-source trim                                  │
│  entries — O(n×k) k-way merge на чтении (k=2)         │
│  entriesForSource(s) — O(1) direct lookup             │
│                                                       │
│  Persistent (warn/error only):                        │
│    app  → applog.txt                                  │
│    core → corelog.txt                                 │
└─────────────────────────────────────────────────────┘
       │                                       │
       │ /logs?source=...&level=...&q=...      │ DebugScreen
       │ /logs/app   /logs/core                │ (segmented "All/Core/App",
       │ /logs/clear?source=...                │  level filter chips,
       ▼                                       ▼ search field)
   Debug API                            Flutter UI
```

**Key design rules:**
- `coreLogSink` (Volatile companion field в `BoxVpnService`) принимает sing-box callbacks из любого Go thread'а.
- `EventChannel.EventSink.success()` требует **main thread** — диспатчим через `coreLogMainHandler.post {...}`. Без этого openTun ловит `@UiThread` exception от Flutter, sing-box интерпретирует как "configure tun interface failed", VPN падает на старте.
- Forwarding gate'нут флагом `Libbox.setup(SetupOptions{debug: ...})` (читается из `BootReceiver.isCoreLogsEnabled(context)` в `BoxApplication.initialize`). Default false, юзер opt-in'ит через UI или Debug API. Изменение применяется только после restart Service'а — `Libbox.setup` зовётся один раз.

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
| openBatteryOptimizationSettings | — | bool — primary action one-tap REQUEST_IGNORE_BATTERY_OPTIMIZATIONS prompt; fallback на список apps для OEM где direct prompt молча отбрасывается (ColorOS / MIUI / HyperOS) |
| openAppDetailsSettings | — | bool |
| openAppSettings | — | bool — открывает App Permissions screen (MANAGE_APP_PERMISSIONS → MANAGE_PERMISSION_APPS → ACTION_APPLICATION_DETAILS_SETTINGS, три-уровневый OEM fallback). Для permissions которые нельзя выдать через runtime prompt (например, ACCESS_BACKGROUND_LOCATION на API 30+) |
| areNotificationsEnabled | — | bool |
| openNotificationSettings | — | bool |
| checkNotificationPermission | — | bool — POST_NOTIFICATIONS на API 33+, true на pre-33 (implicit grant) |
| requestNotificationPermission | — | null — async; UI должен re-check через checkNotificationPermission |
| checkNearbyWifiPermission | — | bool — NEARBY_WIFI_DEVICES на API 33+, true на pre-33 (covered ACCESS_FINE/BACKGROUND_LOCATION) |
| requestNearbyWifiPermission | — | null — async; UI должен re-check |
| showToast | msg: String, duration: "short"\|"long" | bool |

**EventChannel** `com.leadaxe.lxbox/status_events`:

```json
{ "status": "Started" | "Starting" | "Stopped" | "Stopping", "error": "..." }
```

---

### Permissions (Manifest + runtime)

**Manifest declarations** ([AndroidManifest.xml](../app/android/app/src/main/AndroidManifest.xml)):

| Permission | Зачем | Runtime grant? |
|---|---|---|
| `INTERNET` | sing-box egress | install-time |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_SYSTEM_EXEMPTED` | VPN service визибл foreground (FGS политика API 34+) | install-time |
| `RECEIVE_BOOT_COMPLETED` | auto-start on boot | install-time |
| `POST_NOTIFICATIONS` | foreground service notification (API 33+) | runtime, default off |
| `QUERY_ALL_PACKAGES` | per-app split-tunneling list, app-picker | install-time |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | one-tap battery whitelist prompt (API 23+) | install-time + system one-tap dialog |
| `ACCESS_WIFI_STATE` | sing-box wifi rules / WifiInfo helpers | install-time |
| `ACCESS_COARSE_LOCATION` / `ACCESS_FINE_LOCATION` | pre-API-29 fallback для WifiInfo SSID | runtime, default off |
| `ACCESS_BACKGROUND_LOCATION` | API 29+ требование для `WifiManager.connectionInfo` из background (foreground service это и есть «background») | runtime, granted **только через Settings** на API 30+ |
| `NEARBY_WIFI_DEVICES` (`neverForLocation`) | API 33+ обязательный для real SSID/BSSID; без него `WifiInfo.ssid` = `"<unknown ssid>"` | runtime, default off |

**`neverForLocation` flag** на `NEARBY_WIFI_DEVICES` декларирует Google Play, что permission используется **не для location tracking** — это снимает дополнительный compliance review. У нас он действительно нужен только для SSID/BSSID (sing-box wifi rules).

**Permission gating в `BoxService.startSingbox`** ([BoxService.kt:267](../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt:267)):

После `startOrReloadService` (это парсит config) sing-box exposes `commandServer.needWIFIState()` — `true` если в активном config'е есть `wifi_ssid:`/`wifi_bssid:` правила. Если нужен и хоть один permission missing — `stopAndAlert("alert:permission_location:<comma-list>")`. Иначе sing-box падает с misleading `Unknown reference: 42` (real cause — unhandled `SecurityException` через JNI; см. §050).

Permission matrix:

| API | Что нужно для `WifiInfo.ssid` |
|---|---|
| API 28- | `ACCESS_FINE_LOCATION` |
| API 29-32 | `ACCESS_BACKGROUND_LOCATION` |
| API 33+ | `ACCESS_BACKGROUND_LOCATION` + `NEARBY_WIFI_DEVICES` (без NEARBY → `<unknown ssid>`) |

**Defensive try/catch в `PlatformInterfaceWrapper.readWIFIState`** ([PlatformInterfaceWrapper.kt:139](../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/PlatformInterfaceWrapper.kt:139)) — backup для случая когда permission grants drift'ует (например, Android revoke after long idle). `SecurityException` / `RuntimeException` → `return null`. Sing-box graceful'но получает null, не валит процесс через JNI.

**Runtime grant flow** (Flutter side):

```
[Connect tap]
   ↓
BoxService.startSingbox detects needWIFIState() && missing permissions
   ↓
stopAndAlert("alert:permission_location:<perms>")
   ↓
HomeController.lastError = "Stopped: alert:permission_location:..."
   ↓
home_screen._handleStatusEvent ловит prefix → AlertDialog
   ↓
[Allow Wi-Fi info]               [Open Settings]
runtime prompt (NEARBY)          MANAGE_APP_PERMISSIONS intent
                                 → 3 fallback стратегии:
                                   1. MANAGE_APP_PERMISSIONS
                                   2. MANAGE_PERMISSION_APPS
                                   3. ACTION_APPLICATION_DETAILS_SETTINGS
   ↓                                    ↓
re-check via checkNearbyWifiPermission → user re-Connect
```

`POST_NOTIFICATIONS` идёт через **explainer flow** в `home_screen._maybeShowNotificationPermissionDialog` (вызывается из `init`): один раз на cold start показывается AlertDialog (пояснение "VPN runs as foreground service, system requires notification"), потом system runtime prompt. Persisted флаг `notif_perm_prompted_v1` — explainer не повторяется.

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

Toggle в **VPN Settings → System** (§052; до §052 жил в App Settings → Background). Персистится в native SharedPreferences (`boxvpn_boot.keep_vpn_on_exit`), передаётся через `setKeepOnExit(bool)` — имя исторически от BootReceiver, но флаг используется и для keep-on-exit. Также экспонирован в Debug API: `GET|PUT /settings/vpn/keep_on_exit`.

При значении `true` и killе Flutter-процесса система не обязана останавливать foreground-service, а на `onTaskRemoved` service сам стоп не делает. Значение `false` → service слушает task-removed и вызывает `doStop()`.

Pull-sync работает независимо от значения keep-on-exit: если сервис как-то пережил процесс, UI всё равно синхронизируется.

#### Deep-links между tab'ами и settings (§052)

Tab'ы которые depend на глобальном toggle в settings содержат в overflow (⋮) deep-link на соответствующий screen — юзер видит «0 events» / «mode off» и за 1 тап попадает туда где toggle включается:

- **Statistics → Live → ⋮ → "Diagnostics settings"** → `AppSettingsScreen(initialTab: 1)` — Live recording показывает 0 events если `core_logs_enabled=false`.
- **Statistics → Per-app → ⋮ → "Diagnostics settings"** → `AppSettingsScreen(initialTab: 1)` — DNS resolves в profile приходят только когда core forwarding ON.
- **Routing → Tunnel apps → ⋮ → "VPN settings (Core)"** → `SettingsScreen(initialTab: 1)` — открывает Core (не System): юзер настраивает Tunnel apps mode и хочет рядом mtu / log_level / dns_final.
- **Drawer → Debug → ⋮ → "Diagnostics settings"** → `AppSettingsScreen(initialTab: 1)` — fast-path на Quit&reopen после toggle Forward sing-box logs.

Реализация: `initialTab` parameter на `AppSettingsScreen` / `SettingsScreen`, `DefaultTabController.initialIndex: widget.initialTab.clamp(0, length-1)`.

---

## State Management

| Controller | Responsibility |
|-----------|---------------|
| `HomeController` | VPN lifecycle, Clash API, nodes, ping (10 concurrent — `_pingConcurrency`), heartbeat, traffic, configStaleSinceStart, autoUpdater wiring, haptic on transitions |
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
  │   ├─ VPN Settings → SettingsScreen — 2 tabs (§052):
  │   │       • System — Allow VPN bypass · Keep VPN on exit · Tunnel sleep mode (`BackgroundMode`)
  │   │       • Core   — sing-box engine vars (`chapter: core`, mtu / log_level / dns_final / …)
  │   ├─ App Settings → AppSettingsScreen — 2 tabs (§052 Phase 2):
  │   │       • General      — theme, autostart, haptic
  │   │       • Diagnostics  — system permissions block + verbose / share / wipe + Quit&reopen
  │   │       (Background tab удалён; `keep_on_exit` + `background_mode` переехали в VPN Settings → System,
  │   │        permissions block — в Diagnostics)
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
| 10 concurrent mass ping (`_pingConcurrency`) | Sequential was too slow for 50+ nodes; cap балансирует latency vs sing-box load |
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
| **Shared `asBroadcastStream` for status events** (v1.4.0) | `BoxVpnClient.onStatusChanged` cached as `late final` — один native `onListen`, `statusSink` стабилен. Раньше каждый вызов getter'а перезаписывал sink и ломал основной listener после первого reconnect'а. См. tasks/001. |
| **Blocking `stopVPN` через Completer** (v1.4.0) | Method channel ждёт `setStatus(Stopped)` на native (5с timeout) — caller получает control только после реального завершения. Убирает race в `onStartCommand` guard в reconnect'е. См. tasks/002. |
| **Intent-based sticky reset** (v1.4.0) | `configStaleSinceStart=false` в `_stopInternal`/`_startInternal` по факту применённого намерения, не только по transition event'у. Robust к Doze/OOM потерям broadcast'ов. |
| **`TunnelStatus.unknown`** (v1.4.0) | Default для неизвестного raw вместо `disconnected` — убирает ложные срабатывания `firstWhere` predicate'ов на мусорных events. UI маппит в Disconnected label. |
| **`ConfigCache` в HomeState** (v1.4.0) | Outbound JSON (detour tags + protocol labels) парсится один раз при `saveParsedConfig`, не в itemBuilder'е. Убирает hot-path jsonDecode при сортировке 50+ нод. |
| **`kDetourTagPrefix` single source of truth** (v1.4.0) | Константа `⚙ ` в `lib/config/consts.dart` — used by node_settings UI, builder, home filter, node_filter screen. Раньше литералы дублировались. |

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
| **libbox** (native) | sing-box core (JitPack: `com.github.singbox-android:libbox:1.13.11` — миграция из `io.github.sagernet:libbox` сделана в spec 039) |

---

## Known limitations

### Config Editor — one-way pipeline (issue [#3](https://github.com/Leadaxe/LxBox/issues/3))

Source of truth для всех экранов настроек (Subscriptions, Routing, DNS, VPN settings, App settings) — **structured app state** (`SubscriptionEntry[]`, `NodeSpec`, `CustomRule[]`, `SettingsStorage`). [`buildConfig`](../app/lib/services/builder/build_config.dart) собирает sing-box JSON из этого состояния, поток односторонний:

```
state ──buildConfig──▶ configRaw ──save──▶ libbox
```

Config Editor (`ConfigScreen.saveConfigRaw` → [`HomeController.saveConfigRaw`](../app/lib/controllers/home_controller.dart)) сохраняет введённый JSON в sing-box и в `state.configRaw`, но **не парсит его обратно в models**. Поэтому:

- Ручные правки в JSON не видны в menu screens — state о них не знает.
- Любое изменение в UI вызывает `buildConfig` поверх state и затирает manual edits.
- Connection statistics видят правки, потому что sing-box рантаймится с тем JSON'ом, что в editor'е сохранён.

Полноценный round-trip требует sing-box JSON → state parser'а покрывающего все формы outbound'ов / routing rules / DNS servers / inbound configs. Это эффективно вторая product surface, в near-term roadmap не входит. Mitigations для пользователей: выражать кастомизацию через **Routing → Custom rules** (state-bound, выживают пересборку); хранить «чистый» JSON-конфиг отдельно и переподавать его через editor после auto-update подписок.

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
| 030 | Custom routing rules (unified `CustomRule` model: inline + local-only SRS) |
| 031 | Debug API (localhost HTTP server для dev introspection) |
| 032 | Quick Connect (QS tile + home shortcut — спека, не имплементировано) |
| 033 | Preset bundles (selectable rules с `preset_id`, expansion + merge) |
| 034 | App icon |
| 035 | MCP server |
| 036 | Update check (GitHub Releases polling, sideload-flow) |
| 037 | Naive proxy support |
| 038 | Crash diagnostics (`getHistoricalProcessExitReasons`) |
| **039** | **libbox 1.13 migration** (1.12.12 → 1.13.11, single-CommandServer architecture) |
| 040 | Backup & restore UI (4 toggleable categories) |
| 041 | DNS rules refactor (named/toggleable/multi-source) |
| 042 | Health watchdog (heartbeat metrics + auto-recovery) — *Draft* |
| 043 | AppLog per-source quotas (in-memory: app=300, core=500) |
| **044** | **Per-app traffic profiler** (recording per-app DNS/connections/routing chain — Live/Domains/IPs/Connections sub-tabs, connection-issue detection, Debug API + SSE) |

Дополнительно — летопись отдельных рабочих циклов (баги, рефакторинги): [`docs/spec/tasks/`](./spec/tasks/). Процессы (например, ночная работа): [`docs/spec/processes/`](./spec/processes/).
