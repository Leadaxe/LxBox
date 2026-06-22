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

> **Рендерер (§131).** На `Build.VERSION.SDK_INT < 31` (Android ≤11) Flutter
> принудительно переключается с Impeller на **Skia** (`getFlutterShellArgs` →
> `--enable-impeller=false` в [`MainActivity`](../app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt)).
> Impeller-шейдеры валят старые GPU-драйверы (Adreno 3xx → SIGSEGV в `libsc-a3xx.so`).
> На Android 12+ Impeller сохранён. Гейт по версии ОС, не по GPU — у Flutter нет
> чистого рантайм-детекта GPU. Подробности — [§131](spec/tasks/131-impeller-adreno-gpu-crash.md).

### Почему именно 26 как minSdk

- **Исторически** в release notes 1.3.x и draft 1.4.0 заявлено «Android 8.0+» — не закрываем дверь пользователям которые видели эту декларацию.
- **VpnService API** (`setMetered`, `setUnderlyingNetworks`) доступны с API 29+, для старых есть fallback-пути (без setMetered — vpn работает нормально, просто не маркируется как non-metered).
- **`ActivityManager.getHistoricalProcessExitReasons`** (API 30+) — нужен для silent-kill detection в task 007. В коде обёрнут в `if (Build.VERSION.SDK_INT >= 30)` — на старых просто не триггерит snackbar.
- **Foreground-service lifecycle** на API 26+ достаточно стабилен для наших целей.

### Legacy `Build.VERSION.SDK_INT` проверки

В Kotlin (DefaultNetworkMonitor, ServiceNotification, BoxApplication, etc.) остались старые version guards — часть libbox-adjacent кода. С `minSdk=26` некоторые из них (`>= M (23)`, `>= N (24)`) всегда true, их можно упростить. Отдельный cleanup-pass после стабилизации 1.4.0, чтобы не мешать с другими изменениями.

---

## Обзор

L×Box — Android VPN-клиент на базе **sing-box** (через **libbox**). Полный цикл:
подписки → парсинг → конфиг → VPN-туннель → управление через **Clash API**.

### Ядро: fork `sing-box-lx` (§097 / §104)

С §097 ядро — наш fork [`Leadaxe/sing-box-lx`](https://github.com/Leadaxe/sing-box-lx)
(ветка `lx`): upstream sing-box + AmneziaWG 2.0 (`with_awg`) + нативный XHTTP
(`with_xhttp`). Build-теги: `with_gvisor,with_quic,with_wireguard,with_utls,
with_naive_outbound,with_clash_api,with_xhttp,with_awg`.

С §104 fork — **единственное ядро для всех сборок** (local + CI + release;
готовится релиз v2.0.0):

- пин версии — `app/android/libbox.version` (**`v1.13.13-lx.5`**, single source
  of truth для local + CI);
- `scripts/fetch-libbox.sh` скачивает `libbox.aar` из GitHub Releases форка с
  проверкой SHA256 (идемпотентен — маркер `.libbox.version`); вызывается из
  `scripts/build-local-apk.sh` и из CI (`ci.yml` → android job → шаг
  «Fetch sing-box-lx core»);
- AAR не в git (~73MB, `libs/` в `.gitignore`); в `build.gradle.kts` —
  `implementation(files("libs/libbox.aar"))`, Maven-строка стокового
  `libbox 1.13.11` удалена.

### Слои и зоны ответственности

Четыре слоя с однонаправленными зависимостями: **UI → State → Services →
Platform** (никогда наоборот). Логика не живёт в `build()`; UI не дёргает
Platform напрямую — только через контроллеры.

```
┌──────────────────────────────────────────────────────────────────────┐
│  UI   lib/screens · lib/widgets                                        │
│  Тонкие экраны: композиция + lifecycle + setState; логика — в          │
│  presenter/view-model. Паттерн: <screen>.dart (StatefulWidget, владеет │
│  state + все Navigator.push) + <screen>/widgets|sections|tabs/ +       │
│  presenter/VM. Подписка через AnimatedBuilder / ListenableBuilder.     │
├──────────────────────────────────────────────────────────────────────┤
│  STATE   lib/controllers — ChangeNotifier-брокеры                      │
│  HomeController  — VPN/Clash/nodes/ping/heartbeat (split на 4 part'а:   │
│                    config_io · heartbeat · ping_orchestration)         │
│  SubscriptionController — entries, fetch, generateConfig (+ part)       │
│  view-model'и: NodeFilterViewModel · CustomRuleEditController           │
│  Иммутабельный HomeState + copyWith (_unset sentinel) + ParsedConfig.   │
├──────────────────────────────────────────────────────────────────────┤
│  SERVICES   lib/services · lib/models · lib/config                     │
│  Parser v2 (parser/) · Builder (builder/) · subscription/ ·            │
│  settings_storage/ · traffic_profiler/ · debug/ (HTTP Debug API) ·     │
│  clash_api_client · app_log · кэши (AppInfoCache·HttpCache) ·           │
│  ConfigNode/ParsedConfig (§091).                                        │
│  Sealed-модели: NodeSpec · SingboxEntry · CustomRule · ValidationIssue. │
├──────────────────────────────────────────────────────────────────────┤
│  PLATFORM / NATIVE                                                      │
│  Dart: vpn/box_vpn_client — MethodChannel + status/coreLog Stream.      │
│  Kotlin: VpnPlugin (мост) → BoxVpnService (Android VpnService) +        │
│  BoxService (libbox runtime, §049-split) + DefaultNetworkMonitor        │
│  (§087 network-reset) + LocalResolver + WifiInfoReader.                │
└──────────────────────────────────────────────────────────────────────┘
```

**Брокеры событий (push, снизу вверх):** native статус-`Stream<TunnelStatusEvent>`
и `lxbox/coreLog`-stream (→ `AppLog` → `TrafficProfiler`) — единственные
push-каналы. Всё остальное — pull (Clash API polling, 20s heartbeat) или
intent-вызовы сверху вниз. Подробные потоки — в разделе [Потоки данных](#потоки-данных).

### Принцип «cohesion over line-count» (§089)

Цель структурного рефактора §089 — **единая ответственность + связность**, не
число строк. ~600 строк легитимны, когда файл = одна cohesive ответственность.
Декомпозиция крупных файлов — через `part`/`mixin` (та же библиотека →
library-private доступ сохранён) либо вынос виджет-поддеревьев. Задокументированные
крупные исключения (split дал бы риск без пользы):

| Файл | Строк | Почему остаётся целым |
|---|---|---|
| `services/traffic_profiler.dart` | 1221 | Монолитный stateful singleton: log-ingest parser + conn-id correlation + confidence + dual SSE fan-out — всё через общий private state и один `ChangeNotifier`-контракт. Pure-типы (`models.dart`) и correlation-структуры (`internal.dart`) уже вынесены `part`'ом. |
| `models/custom_rule.dart` | 618 | Уже sealed `Inline`/`Srs`/`Preset`; объём присущ трём структурно разным вариантам. Дальнейший split + SRS-cache у Preset (spec 011) — **behavior-changing** → отложен в §090. |
| `android/.../VpnPlugin.kt` | 635 | Единый `MethodCallHandler`-контракт; split разнёс бы channel-контракт по файлам. |

### ConfigNode / ParsedConfig (§091 — реализовано)

`ConfigCache` + `ConfigIntrospection` + reverse-map `subscriptionsOfTag`
схлопнуты в `ParsedConfig` — `Map<tag, ConfigNode{tag, type, section, detour,
isMarkedDetour, detourRefCount, raw, transportLabel, securityLabel}>`,
парсится один раз на смену `configRaw` (поле `HomeState.configModel`);
пинги — отдельный динамик-слой, джойн на рендере (`NodeViewItem`).
Принадлежность подписке — **prefix-фильтр** по эмитированному тегу
(`home/subscription_lookup.dart`), без членства в node-списках. Убран целый
класс багов «UI reverse-парсит display-тег» (§077/§079/§080).

`transportLabel`/`securityLabel` (§102/§103) — eager-лейблы subtitle ноды
(протокол · транспорт · security: `tcp`/`ws`/`grpc`/`h2`/`httpupgrade`/`quic`/`xhttp`;
`TLS`/`Reality` + `+Vision` при `flow=xtls-rprx-vision`; для WireGuard —
уровень обфускации `awg`/`awg2`) — вычисляются один раз в `ParsedConfig.parse`,
не в getter'ах. См. [`spec/tasks/091`](./spec/tasks/091-config-node-model.md),
[`102`](./spec/tasks/102-subtitle-transport-variant.md),
[`103`](./spec/tasks/103-variant-filter-chips.md).

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
  │   2. applyAllCustomRules → единый проход по customRules в storage order
  │                            (dispatch по kind → preset/inline/srs handler);
  │                            registry получает rule_sets и routing rules
  │                            в порядке storage; DNS-аспекты — в UnifiedApplyResult
  │                            (spec 030 + 033 + 062)
  │   3. flush registry      → config.route.{rule_set, rules}
  │   4. applyTlsFragment, applyMixedCaseSni  → TLS-обфускация (spec 028)
  │   5. applyCustomDns      → dns.servers/rules из template + bundle-extras
  │   6. validator → ValidationResult{ fatal[], warnings[] }
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
- Warnings bubble up: parse-time → `NodeSpec.warnings`, emit-time → appended by emit. (XHTTP-фолбэк в `httpupgrade` убран в §097 — emit нативный, ядро `with_xhttp`.)

---

## Wizard template (`assets/wizard_template.json`)

Asset-шаблон, который читается один раз через `TemplateLoader.load()` (синглтон, deep-copy на каждый билд). Определяет скелет sing-box конфига, глобальные переменные, preset-группы (VPN tiers) и selectable-правила (каталог routing-пресетов).

### Секции шаблона

| Секция | Роль | Пример / где используется |
|---|---|---|
| `parser_config` | sing-box `version` + reload interval | прямой emit в корень |
| `dns_options.servers` | Canonical DNS-серверы (system/google/cloudflare/quad9/adguard). Storage хранит kind-refs `{enabled, kind: inline\|preset\|template, tag, description?, body?}` (§043 + §044). Body для kind:inline — partial sing-box shape **без** tag/description/enabled (они на ref-level; tag синтезируется на build-time). Резолвится в bodies через `resolveDnsServersBodies`. | `applyCustomDns` через `resolveDnsServersList` |
| `dns_options.rules` | Дефолтные DNS-rules. Storage — kind-refs (§061 dns-rules-refactor, бывший feature §041) (`inline\|srs\|preset\|template`). Catch-all удалён в task §039 (empty-template-dns-rules) — fall-through идёт через `dns.final`. | `applyCustomDns`: bundle-rules через `resolveDnsRulesList` |
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
  ├── customRules (один список, mixed kind — preset/inline/srs)
  │    │  applyAllCustomRules — единый проход в storage order
  │    │  с dispatch по kind. Cross-preset rule_set dedup через
  │    │  RuleSetRegistry.tryRegisterRuleSet (identical-skip / first-wins).
  │    │  (spec 062 — раньше preset/inline шли двумя проходами и cross-kind
  │    │  ordering между ними был потерян)
  │    ├── kind: preset
  │    │    └─ expandPreset (pure) ──► PresetFragments
  │    │       └─ register rule_sets in registry; routing rule (if route enabled);
  │    │           DNS aspect (if dns enabled) → UnifiedApplyResult.{dnsRules, dnsServers}
  │    ├── kind: inline
  │    │    └─ headless rule_set с непустыми match-полями + routing rule
  │    │       (auto-suffix tag через registry.addRuleSet) (spec 030)
  │    └── kind: srs
  │         └─ local rule_set по cached path + routing rule (spec 030)
  ├── dns_options  ──► applyCustomDns(template + extras)                      ──► config.dns
  └── preset_groups ──► _buildPresetGroups(vpn-1..3, @auto)                   ──► config.outbounds
```

**Почему DoH/DoT в bundle хардкодят `server: "77.88.8.88"` + `tls.server_name`:**
В sing-box 1.12 DNS-сервер типа `https`/`tls` с hostname-сервером требует `domain_resolver` (тег другого DNS-сервера для bootstrap resolve), иначе chicken-and-egg. Указывая IP напрямую + `tls.server_name` для SNI/cert verify — избавляемся от bootstrap dependency (не нужно ходить в 8.8.8.8 для резолва `safe.dot.dns.yandex.net`) и получаем Safe-профиль Yandex с корректной TLS проверкой.

`@dns_ip` применяется **только** к UDP-серверу — для DoH/DoT замена IP сломала бы TLS (cert mismatch с захардкоженным SNI). Для реально разных режимов Yandex (Safe/Base/Family) → отдельные пресеты, если понадобятся, чтобы не городить nested-lookup в substitution-движке.

---

## Дерево исходников

Структура после §089: тонкие экраны с под-папками `<screen>/`, контроллеры и
крупные сервисы разнесены `part`'ами по ответственности. Per-file роли ниже.

### `app/lib/`

```
main.dart                    # Entry point: ThemeNotifier, MaterialApp,
                             #   home: HomeScreen, navigatorObservers:[homeReturnObserver]
                             #   (named routes нет — навигация императивная)
```

#### `vpn/` — Dart-сторона native-моста

```
box_vpn_client.dart          # BoxVpnClient.I — типизированная обёртка над
                             #   MethodChannel/EventChannel; каждый вызов
                             #   timeout-wrapped + safe-default; onStatusChanged stream
box_vpn_client/method_names.dart  # part: _Methods — зеркало when(call.method) из VpnPlugin.kt
box_vpn_client/timeouts.dart      # part: _Timeouts — per-method Duration (status 3s, start 30s…)
```

#### `config/`

```
clash_endpoint.dart          # ClashEndpoint.fromConfigJson — Clash API base+secret+route.final из конфига
config_parse.dart            # JSON5/JSONC → canonical JSON (для libbox) + pretty-print (для editor)
consts.dart                  # kAutoOutboundTag (✨auto), kDetourTagPrefix (⚙) — зеркало wizard_template
```

#### `models/` — типизированные данные (sealed-иерархии, без I/O)

```
node_spec.dart               # sealed NodeSpec (10 вариантов: Vless/Vmess/Trojan/Shadowsocks/
                             #   Hysteria2/Naive/Tuic/Ssh/Socks + Wireguard); getEntries detour-chain;
                             #   Awg value-object (§097): AWG/AWG2-поля WireguardSpec (jc/jmin/jmax/
                             #   s1–s4/h1–h4/i1–i5), round-trip parse/emit; null = обычный WG
node_spec_emit.dart          # emit()/toUri() impl на вариант (NodeSpec → SingboxEntry); parity-tested
singbox_entry.dart           # sealed SingboxEntry = Outbound | Endpoint (WireGuard → Endpoint)
node_entries.dart            # NodeEntries{main, detours} — результат getEntries
emit_context.dart            # abstract EmitContext: allocateTag/addEntry/selector+auto регистрация
template_vars.dart           # TemplateVars — глобальные emit-флаги (tls_fragment/mux/sniOverride)
tls_spec.dart                # TlsSpec + RealitySpec (utls/reality/alpn) → toSingbox()
transport_spec.dart          # sealed TransportSpec (Ws/Grpc/Http/HttpUpgrade/Xhttp); XHTTP — нативный
                             #   emit (§097, ядро with_xhttp: mode/x_padding_bytes/no_grpc_header)
node_warning.dart            # sealed NodeWarning + WarningSeverity (parse/emit warnings)
validation.dart              # sealed ValidationIssue + ValidationResult (dangling refs/empty urltest → fatal)
parser_config.dart           # модели wizard_template.json: WizardTemplate/PresetGroup/SelectableRule/WizardVar
custom_rule.dart             # sealed CustomRule = Inline|Srs|Preset (routing rules; →§090, см. Обзор)
server_list.dart             # sealed ServerList = SubscriptionServers | UserServer
subscription_meta.dart       # SubscriptionMeta — userinfo-заголовки (traffic/expire/title/update-interval)
app_info.dart                # AppInfo — метаданные установленных приложений (native getInstalledApps)
background_mode.dart         # enum BackgroundMode (never|lazy|always) — Doze-поведение туннеля
tunnel_status.dart           # TunnelStatus enum + TunnelStatusEvent (native status mapping + errorReason)
debug_entry.dart             # DebugEntry + DebugSource/Level/Filter (унифицированная лог-строка)
home_state.dart              # immutable HomeState + copyWith; configModel: ParsedConfig (§091,
                             #   re-parse на смену configRaw); NodeSortMode (default/latency/name/
                             #   manual — §100: manual в карусели и меню, mode + manual order
                             #   персистятся в settings_storage); memoized sortedNodes
config_node.dart             # §091 ConfigNode + ParsedConfig — структурная мета нод собранного
                             #   конфига (type/section/detour/isMarkedDetour/detourRefCount/raw);
                             #   §102/§103 eager transportLabel/securityLabel (transport-слот +
                             #   TLS/Reality/+Vision, awg/awg2); parsed раз на смену configRaw
```

#### `controllers/` — ChangeNotifier-брокеры состояния

```
home_controller.dart         # главный VPN-брокер: _state/_vpn/_clash; статус-handler; start/stop/
                             #   reconnect/reload; Clash proxies/groups; selection-сеттеры; lifecycle
home_controller/config_io.dart          # part _ConfigIoMixin: load/saveParsedConfig, import, configChangedNeedRestart
home_controller/heartbeat.dart          # part _HeartbeatMixin: 20s Clash poll + dead-tunnel detection
home_controller/ping_orchestration.dart # part _PingMixin: single/group/mass URLTest, 10 worker'ов, epoch-cancel
subscription_controller.dart            # подписки: List<ServerList>, add/remove/rename/toggle/move
                                        #   (§098 drag-reorder), fetch, buildConfig; §101 — rehydrationDone
                                        #   (фикс стартовой гонки rehydrate↔bootstrap) + empty-fetch guard
                                        #   (HTTP 200 с 0 нод не затирает кэшированные ноды)
subscription_controller/subscription_entry.dart # part SubscriptionEntry: ChangeNotifier-обёртка над immutable ServerList
```

#### `screens/` — UI (тонкий экран + под-папка)

```
home_screen.dart             # композиционный корень (518): владеет брокерами, side-effects, rebuild/reconnect
home/node_list_presenter.dart   # §089 presenter: §048 фильтр/split + §070 frozen-sort cache +
                                #   chip-options; §103 variantsOfTag + канонич. порядок variant-чипов
home/node_filter_view_model.dart# ChangeNotifier VM: regex/protocol/variants(§103)/sub/ping фильтры,
                                #   единый !-negate на категорию (§096) + detour tri-state (чекбокс+!,
                                #   §096), §083 per-channel память
home/node_filter.dart           # pure NodeFilter helper (match-предикаты + inverts) + extractEmojis
home/node_actions.dart          # long-press действия ноды; §099 — copy-JSON варианты (node / server /
                                #   server+detours(N)) перенесены в dropdown внутри View JSON
home/home_menus.dart            # showSortOptionsMenu (+ Custom/manual §100) + showPingSettings
home/home_dialogs.dart          # top-level dialog/snackbar функции (update/permission/battery/revoked)
home/restore_backup.dart        # empty-state quick-restore flow (SAF)
home/subscription_lookup.dart   # §091 prefix-фильтр: нода принадлежит подписке ⇔ tag.startsWith
                                #   ('$prefix '); заменил §077 reverse-map по node-спискам
home/channel_filters.dart       # §083 immutable снимок match-фильтров канала (+ variants §103)
home/filter_widgets.dart        # filter chip/row виджеты (viz-toggle чипы §095, NegateToggle §096)
home/widgets/                   # node_list · home_controls · home_drawer (nav-хаб) · nodes_header ·
                             #   traffic_bar · status_chip · progress_banner · filter_panel (§095
                             #   Filter mode: табы Regex/Protocol/Subscribes/Settings + чипы-сводка)
                             #   · add_server_cta
routing_screen.dart          # routing-конфиг (598) + LazyPersistMixin + _RoutingSrsCacheMixin (part)
routing_screen/                 # widgets/ (custom_rule/preset_catalog/route_final/routing_group/srs_status) + menus
dns_settings_screen.dart     # DNS-настройки (592) + editor-sheets + dns_server_resolver + widgets/
custom_rule_edit_screen.dart # CustomRule editor (456) + custom_rule_edit/ (edit_controller, tabs/, sections/, widgets/)
subscription_detail_screen.dart # детали подписки (431, TabController) + widgets/ (settings/source/meta/node_list)
subscriptions_screen.dart    # список подписок (445) + widgets/ + helpers (clipboard/paste/share/context-menu)
stats_screen.dart            # хост TabBarView: Overview + Connections + PerAppTrace + LiveEvents
stats_screen/overview_tab.dart  # Overview-таб + overview_models
per_app_trace_tab.dart       # Stats-субтаб (446): live/connections/domains/ips views + dialogs
live_events_tab.dart         # Stats-субтаб (371): event_tile/recording_header/unattributed_banner
tun_apps_tab.dart            # per-app VPN routing субтаб (384) — шарится Stats/Routing
app_settings_screen.dart     # настройки приложения (516): General/Diagnostics табы + update_status_row
backup_screen.dart           # export/import снапшота (229) + export_card/import_card/preview
lazy_persist_mixin.dart      # LazyPersistMixin — отложенный persist на settings-экранах (flush на возврат)
# монолитные одиночные экраны (без под-папки, 60–505): about · add_server_wizard ·
#   app_picker · config · connections · debug · node_filter · node_settings ·
#   outbound_view · settings · speed_test
```

#### `services/` — сервисный слой

```
parser/                      # Parser v2 (text → NodeSpec)
  body_decoder.dart          #   Layer-1: raw body → sealed DecodedBody (base64 sniff + JSON-flavor)
  amnezia_link.dart          #   Amnezia vpn:// → WG/AWG INI-тексты (base64url+qCompress, §110)
  parse_all.dart             #   Layer-2: exhaustive switch DecodedBody → List<NodeSpec> (per-line null-skip)
  uri_parsers.dart           #   barrel + parseUri scheme-dispatcher
  uri_parsers/<proto>.dart   #   per-protocol URI→NodeSpec (vless/vmess/trojan/ss/hy2/naive/tuic/ssh/socks/wg)
  json_parsers.dart          #   parseXrayOutbound + parseSingboxEntry (round-trip)
  ini_parser.dart            #   WireGuard INI → wg:// URI → WireguardSpec
  transport.dart             #   parseTransport (query→TransportSpec) + transportToQuery
  uri_utils.dart             #   shared: base64-safe decode, newUuidV4, tagFromLabel, packet-encoding
                             #   allow-list; awgClampMtu (§097 — клиентский MTU AWG-нод ≤1280)
builder/                     # NodeSpec + template → sing-box config
  build_config.dart          #   buildConfig() orchestrator → BuildResult; _BuildCtx (EmitContext + tag allocator)
  server_list_build.dart     #   per-subscription emit: detour policy, tag allocation, selector/auto регистрация
  preset_expand.dart         #   expandPreset (CustomRulePreset → fragments, @var) + mergeFragments (§033)
  rule_set_registry.dart     #   реестр route.rule_set + route.rules; tag-уникальность
  validator.dart             #   validateConfig: dangling refs, empty urltest → ValidationResult
  post_steps.dart            #   barrel (part): пять post-обработок ниже
  post_steps/tls_transforms.dart  #   applyMixedCaseSni + applyTlsFragment (§028)
  post_steps/custom_rules.dart    #   applyAllCustomRules (preset/inline/srs в storage order, §062)
  post_steps/dns_rules.dart       #   applyCustomDns / resolveDnsRulesList (§061+§033)
  post_steps/dns_servers.dart     #   resolveDnsServersList/Bodies (§043+§044)
  post_steps/tun_packages.dart    #   applyTunPackages — OS split-tunnel (§046, последний шаг)
subscription/                # fetch/auto-update подписок
  sources.dart               #   sealed SubscriptionSource (Url/File/Clipboard/Inline/Qr) + fetch (3-try backoff)
  auto_updater.dart          #   5-триггерный refresh + per-sub interval + retry/fail-caps + dedup (§027)
  http_cache.dart            #   on-disk кэш последнего raw body + headers (offline rehydrate);
                             #   §101 — атомарная запись tmp→rename (kill-safe при unawaited save)
  input_helpers.dart         #   isSubscriptionUrl/isDirectLink (вкл. awg://, §097)/isWireGuardConfig (paste UX)
settings_storage.dart        # фасад над lxbox_settings.json — тонкие делегаты в part-файлы:
settings_storage/io.dart            #   атомарный load/save/recovery (main→.bak→{}, §072)
settings_storage/vars.dart          #   vars-домен + Wi-Fi history (§051)
settings_storage/sources_rules.dart #   server_lists (+v1 migration), rules/groups, custom_rules
settings_storage/network.dart       #   route_final/excluded/dns/ping_options (§040/§061)
settings_storage/backup_tun.dart    #   снапшот (§031) + tun-apps split-tunnel (§046)
traffic_profiler.dart        # TrafficProfiler singleton (1221, см. Обзор): сессии, rolling buffer, SSE
traffic_profiler/models.dart        #   part: TrafficEvent/Session + enums + JSON
traffic_profiler/internal.dart      #   part: _ConnMeta/_DnsAccumulator/_ConnSnapshot correlation-структуры
debug/                       # localhost HTTP Debug API (§031)
  bootstrap.dart             #   applyDebugApiSettings — строит DebugContext, рестартит сервер
  debug_registry.dart        #   нуллабельные refs на контроллеры (bind в HomeScreen.initState)
  context.dart               #   DebugContext — per-handler инъекция (requireHome/Sub, clock, log, config)
  contract/errors.dart       #   sealed DebugError (NotFound/Unauthorized/Conflict/…) — transport-agnostic
  transport/server.dart      #   DebugServer — HttpServer на 127.0.0.1, Router+pipeline, lifecycle
  transport/request.dart     #   DebugRequest — immutable snapshot, body read once (maxBodyBytes)
  transport/response.dart    #   sealed DebugResponse (Json/RawJson/Bytes/Stream/Error)
  transport/router.dart      #   longest-prefix mount/resolve
  transport/pipeline.dart    #   onion-chain middleware runner
  transport/config.dart      #   DebugServerConfig (port/token/timeout/maxBody/unauth-paths)
  transport/middleware/      #   error_mapper · access_log · host_check · auth · timeout
  handlers/                  #   /state /settings /action /profiler /rules /subs /clash /config /logs /device
                             #     /files /diag /backup /wifi_history /help /ping (+ _shared CRUD-хелперы)
  serializers/               #   home_state · storage (denylist scrubber) · rules · subs (URL-маскинг)
migration/proxy_source_migration.dart  # one-shot v1 proxy_sources → v2 server_lists
nav/home_return_observer.dart          # глобальный NavigatorObserver (§076): rebuild на возврат к home
clash_api_client.dart        # Clash REST (/proxies, /connections, delay/groupDelay); отдельный cancelable client
app_log.dart                 # AppLog ChangeNotifier-singleton: per-source ring buffers + persistent warn/error (§043)
app_info_cache.dart          # AppInfoCache — session-кэш AppInfo по package + revision ValueNotifier
json_clone.dart              # deepCopyJson/deepCloneJson/deepEqualsJson (§089 P6 — общий для builder/backup)
format_utils.dart            # formatBytes/formatDuration/formatTime (канонические форматтеры)
relative_time.dart           # relativeTime(now, past) — "2h ago" (pure, тестируемый)
url_mask.dart                # maskSubscriptionUrl — scheme://host/*** для логов/шеринга
tag_resolver.dart            # §085 TagResolver — единый владелец display-тега (displayTag/isDetourMarker/strip)
template_loader.dart         # wizard_template.json loader (singleton, deep-copy на билд)
rule_set_downloader.dart     # download+cache remote .srs (parallel, atomic tmp+rename, retry)
backup_service.dart          # export/import полного снапшота настроек (§031)
update_checker.dart          # GitHub-релиз check + dismissed-version guard (см. §090 по half-wired stub)
node_emoji.dart              # §094 emoji-теги: палитра + protocol-default emoji + вставка в rawBody/tag
haptic_service.dart · community_servers_loader.dart · dump_builder.dart · url_launcher.dart ·
config_dirty_check.dart · error_humanize.dart · error_format.dart · parse_hints.dart ·
clash_log_pump.dart · logcat_reader.dart · stderr_reader.dart · exit_info_reader.dart ·
selectable_to_custom.dart · version_info.dart · wifi_history_listener.dart  # вспомогательные
```

#### `widgets/` — кросс-экранные

```
node_row.dart                # строка ноды: ACTIVE pill + proto label + ping (принимает NodeViewItem, §068)
node_view_item.dart          # NodeViewItem — immutable view-row (статик-мета + динамика, §068)
emoji_picker_button.dart     # §094 — popup-палитра emoji (node_settings, add-server wizard)
reorder_grab_strip.dart      # §098 — единый grab-strip для drag-reorder (routing/DNS rules ·
                             #   subscriptions · node list в manual-sort mode §098/§100)
outbound_picker.dart · template_var_list.dart · core_logs_hint_banner.dart ·
wifi_entry.dart · wifi_manual_add_dialog.dart · wifi_permission_dialog.dart · wifi_saved_picker_sheet.dart
```

### `app/android/app/src/main/kotlin/com/leadaxe/lxbox/`

```
MainActivity.kt              # FlutterActivity: регистрирует VpnPlugin; /utils + /wifi_history каналы;
                             #   VPN-consent flow; QS-tile/shortcut quick actions
vpn/VpnPlugin.kt             # Flutter-плагин (635, см. Обзор): MethodCallHandler всех /methods;
                             #   status+coreLog EventChannel sinks; statusReceiver мост; app-icon encode
vpn/BoxVpnService.kt         # Android VpnService + PlatformInterface side (§049-split, тонкий):
                             #   openTun (Builder.establish, allowBypass §069, per-app routes); forwards в BoxService
                             #   §119: openTun зовётся libbox'ом ТОЛЬКО при наличии tun-inbound. Режим Proxy
                             #   (vpn_mode=proxy, config без tun) → нет openTun → нет establish → нет VPN-туннеля.
                             #   Foreground/protect/override tun-agnostic → proxy-режим = config-only, Kotlin не трогаем.
vpn/BoxService.kt            # CommandServerHandler — владеет libbox runtime (fileDescriptor/commandServer
                             #   AtomicReference, serviceScope); startSingbox/doStop/serviceReload; setStatus broadcast
vpn/BoxApplication.kt        # Application: async Libbox.setup (libboxReady barrier); singleton wifiObserver
vpn/PlatformInterfaceWrapper.kt # libbox PlatformInterface: localDNS→LocalResolver, findConnectionOwner, readWIFIState
vpn/DefaultNetworkMonitor.kt # §087: detect genuine iface switch (prev!=new), debounce 1500ms → resetNetwork
vpn/DefaultNetworkListener.kt# ConnectivityManager.NetworkCallback в coroutine-actor (порт SagerNet)
vpn/LocalResolver.kt         # LocalDNSTransport — DNS-запросы bound к underlying network (не tun)
vpn/ConfigManager.kt         # file-based config store (filesDir) + notificationTitle
vpn/ServiceNotification.kt   # foreground-service notification (typed SPECIAL_USE на API34+)
vpn/VpnStatus.kt             # enum Stopped/Starting/Started/Stopping (native-сторона статуса)
vpn/BootReceiver.kt          # BOOT_COMPLETED auto-start + SharedPreferences native-тогглов
vpn/LxBoxTileService.kt      # QS-tile toggle (§032) с оптимистичным рендером
vpn/QuickShortcuts.kt        # dynamic launcher shortcuts (Connect/Disconnect)
vpn/LxBoxIntentReceiver.kt   # §047 raw broadcast API: 9 incoming actions, опц. permission-gate, setEnabled
vpn/WifiInfoReader.kt        # §051 единый источник Wi-Fi SSID/BSSID (permission preflight, sealed Result)
vpn/WifiNetworkObserver.kt   # §051 auto-record: NetworkCallback → WifiHistoryBridge → Dart onWifiSeen
vpn/PermissionUtils.kt · Extensions.kt  # SDK-gated permission check; мелкие Kotlin-расширения

automation/                  # §047 Locale/Tasker plugin (FIRE_SETTING/QUERY_CONDITION) — см. ../docs/AUTOMATION.md
automation/LocaleApi.kt              #   константы стандарта twofortyfouram + JSON bundle (de)serialize + cachedNodes/Groups
automation/LocaleSettingReceiver.kt  #   FIRE_SETTING → shared action-handlers (start/stop/toggle напрямую, остальное → VpnPlugin.handleAutomationAction)
automation/LocaleConditionReceiver.kt#   QUERY_CONDITION → currentStatus/active-кеш → result code (SATISFIED/UNSATISFIED/UNKNOWN)
automation/LocaleQuickActionActivity.kt # one-tap Start/Stop/Toggle (Theme.NoDisplay, headless setResult+finish; команда по alias)
automation/LocaleSettingEditActivity.kt # «Custom…» edit-экран: RadioGroup команд + селектор нод/групп из native-кеша
automation/LocaleConditionEditActivity.kt # edit-экран условия (VPN up / active node= / active group=)
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
  ├─ state.configChangedNeedRestart = false
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
        └─ state.configChangedNeedRestart = tunnelUp  (sticky flag)
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

`build_config.dart` мерджит template `config`-секцию + `selectable_rules[*]` (через `expandPreset`) + `dns_options.{servers,rules}` (через resolvers §061/§044) + `preset_groups` (с активными node-tag'ами из `server_lists`) + `vars`-substitution → пишет финальный `singbox_config.json` для libbox.

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

**Coupling (важно для extraction):**
- **Sing-box log format** — Source A парсит конкретные log lines `router: found package name`, `dns: exchanged|cached`, `dns: exchange failed` regex'ами в `_dnsRe` / `_dnsFailRe` / `_routerRe`. Если sing-box изменит формат логов — TrafficProfiler сломается silent. Формат стабилен на текущем ядре (`sing-box-lx 1.13.13-lx.5`, §097/§104 — относительно стокового 1.13.11 формат не менялся), но при любой смене/апгрейде ядра это первое, что надо verify.
- **`AppLog` instance + `DebugSource.core` filter** — TrafficProfiler subscribe'ит на `AppLog.I.notifyListeners` и фильтрует по source. Зависимость двунаправленная: `core_logs_enabled=false` → core source пуст → TrafficProfiler видит только Source B (Clash poll), теряет DNS resolves и process attribution. UI показывает `CoreLogsHintBanner` чтобы юзер включил forwarding.
- **`ClashApiClient` instance** — Source B использует наш Clash API client. Поэтому профайлер не работает пока Clash endpoint не resolved (см. раздел Clash API client → wiring).

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

## Dart `BoxVpnClient` API surface

Тонкий клиент над тремя channel'ами (`com.leadaxe.lxbox/methods` + два EventChannel'а). Файл — [`app/lib/vpn/box_vpn_client.dart`](../app/lib/vpn/box_vpn_client.dart). Это **единственная** точка где Dart-side touches MethodChannel — все остальные вызовы идут через типизированный API клиента.

**Singleton + DI:**
- Production — `BoxVpnClient.I` (или `BoxVpnClient()` — alias на singleton, оставлен для обратной совместимости).
- Tests — `BoxVpnClient.forTest(methods: mock, events: mock)`. `@visibleForTesting`.

**Группы методов** (порядок повторяет `_Methods` constants):

| Группа | Методы | Notes |
|---|---|---|
| Config | `saveConfig` / `getConfig` | `getConfig` fallback `'{}'` чтобы builder мог parse без null-checks |
| VPN lifecycle | `startVPN` / `stopVPN` / `reloadVPN` / `resetNetwork` / `getVpnStatus` / `getCoreVersion` / `quitApp` | `stopVPN` блокирующий native до `setStatus(Stopped)` — позволяет `await stop; await start` без race |
| Settings (boot prefs / native toggles) | auto_start, keep_on_exit, core_logs_enabled, allow_bypass, background_mode | Storage native в `SharedPreferences boxvpn_boot.*`, не в `lxbox_settings.json` |
| Per-app routing | `getInstalledApps` / `getAppIcon` / `getAppInfo` | Icons lazy — `getInstalledApps` без icons (тяжело), `getAppIcon` per-package по запросу |
| System helpers | `isIgnoringBatteryOptimizations` / `open*Settings` / `*NotificationPermission` / `*NearbyWifiPermission` / `showToast` | Permission `request*` — async, UI делает re-check через паренный `check*` |
| Quick Settings | `requestAddTile` | API 33+ |

**Status stream design:**

```dart
late final Stream<TunnelStatusEvent> onStatusChanged = _events
    .receiveBroadcastStream()
    .map(...)
    .asBroadcastStream();
```

`late final` критично: до v1.4.0 каждый getter создавал новый stream, native `EventChannel.onListen` дёргался повторно, native перезаписывал `statusSink` — основной listener после первого reconnect ломался ([tasks/001](spec/tasks/001-reconnect-sink-leak.md)). Сейчас singleton broadcast stream — один native listener, любое количество Dart-подписчиков.

**Timeout policy:**

Каждый MethodChannel-вызов обёрнут в `.timeout()` с per-метода настроенным значением (см. `_Timeouts` constants):

| Категория | Timeout | Почему |
|---|---|---|
| status / settings | 3s | Lightweight read/write of preferences |
| config | 5s | File I/O |
| app metadata (per-package) | 5s | One PackageManager query |
| installed apps list | 15s | `PackageManager.getInstalledApplications` дорогой |
| startVPN | 30s | System dialog timing + libbox setup |
| stopVPN | 10s | Blocking до `setStatus(Stopped)` |
| reloadVPN / resetNetwork | 5-10s | Wait for `serviceReload` / `closeAll + DNS flush + dialer rebind` |
| requestAddTile | 10s | System dialog confirmation |

**На таймауте** — лог в `AppLog` + safe-default fallback (например `tunnel: disconnected` для `getVpnStatus`). Без таймаутов мы видели реальные deadlock'и где native не отвечал на запрос — Flutter UI блокировался без recovery path.

---

## Native Architecture (Kotlin)

### Class layout (§049 F1 split)

В §049 audit'е мы port'нули pattern из reference SagerNet (`bg/BoxService.kt` commit 3b3883e, libbox 1.13.11) — разделили **Android Service лейер** от **libbox runtime лейера**:

```
┌─────────────────────────────────────────┐  ┌────────────────────────────────────┐
│ BoxApplication : Application            │  │ VpnPlugin : MethodCallHandler      │
│  • onCreate (registered in Manifest)    │  │  • setMethodCallHandler            │
│  • Libbox.setup(SetupOptions) async     │  │  • EventChannel sinks (status/log) │
│  • libboxReady : CompletableDeferred    │  │  • static currentStatus mirror     │
│  • Singleton WifiNetworkObserver        │  │     (sync read by HomeController)  │
└─────────────────────────────────────────┘  └────────────────────────────────────┘
                                                           │ start/stop intent
                                                           ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ BoxVpnService : VpnService, PlatformInterfaceWrapper                            │
│  • Android lifecycle (onCreate/onStartCommand/onRevoke/onDestroy)               │
│  • PlatformInterface impl: defaultNetwork / processInfo / readWIFIState         │
│  • openTun()  ← libbox calls back через PlatformInterface                       │
│  • field: private val service = BoxService(this, this)  ← THIS line is the F1   │
│  • forwards lifecycle: onStartCommand → service.startSingbox(intent), etc.      │
└─────────────────────────────────────────────────────────────────────────────────┘
                                          │ owns
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ BoxService : CommandServerHandler   (plain class, NOT a Service)                │
│  • libbox state: AtomicReference<ParcelFileDescriptor> fileDescriptor           │
│                  AtomicReference<CommandServer>          commandServer          │
│  • serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)              │
│  • startSingbox(intent) / doStop() / serviceReload() / receiver{stop,reload,..} │
│  • CommandServer(this, platformInterface)  ← 2 different Java instances:        │
│       CSH=BoxService  PI=BoxVpnService  (mirrors reference; reduces refnum-42   │
│       JNI race surface compared with prior `CommandServer(this, this)`)         │
│  • status broadcasts via BROADCAST_STATUS → VpnPlugin.statusReceiver → sink     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Зачем split:** до §049 `BoxVpnService` имплементировал и `PlatformInterface`, и `CommandServerHandler` (один `this` передавался обоим libbox-сторонам). На стороне libbox это означало refcnt=2 на один `Seq.Ref` → расширенное окно gomobile refcount race (часть симптомов «refnum 42» в §050). После split два разных Java instance → libbox tracker'ы видят разные refnum'ы.

### Structured Concurrency

```
BoxService (per-instance, recreated с каждым new BoxVpnService)
  └─ serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
       ├─ resetScope() in startSingbox (cancel is terminal)
       ├─ All coroutines tied to service lifecycle
       ├─ DefaultNetworkMonitor receives serviceScope
       │    └─ checkUpdate() uses scope.launch — dies with service
       └─ doStop() calls serviceScope.cancel() as safety net
```

**`AtomicReference` для fileDescriptor / commandServer** (§049 F2/F3): `getAndSet(null)?.close()` гарантирует что только один поток выполнит close. Главный fix для §047 race condition на mutations `fileDescriptor` (5 call-site'ов могли double-close → kernel переиспользует fd-int → sing-box пишет в чужой fd → silent ENXIO → TCP перестаёт работать через 15-30 минут).

### Channel Contract

Three Flutter-Android channels live в `VpnPlugin.kt`:

| Channel | Type | Direction |
|---|---|---|
| `com.leadaxe.lxbox/methods` | MethodChannel | bidirectional (Dart → Native; Dart ← Native для `wifi_history`-promotion от `WifiNetworkObserver`) |
| `com.leadaxe.lxbox/status_events` | EventChannel | Native → Dart (TunnelStatus broadcasts) |
| `lxbox/coreLog` | EventChannel | Native → Dart (sing-box log lines) |

**MethodChannel methods** (groups follow `_Methods` constants в `box_vpn_client.dart`):

| Group | Method | Input | Output |
|---|---|---|---|
| **Config** | saveConfig | `config: String` | bool |
| | getConfig | — | String |
| **VPN lifecycle** | startVPN | — | bool (may trigger system VpnService dialog) |
| | stopVPN | — | bool — **блокирующий** native до `setStatus(Stopped)`, чтобы caller мог делать `await stopVPN(); await startVPN()` без race |
| | reloadVPN | — | bool — `box.serviceReload()` без status flap |
| | resetNetwork | — | bool — light recovery: `closeAllConnections + DNS flush + dialer rebind`. Tunnel must be up. |
| | getVpnStatus | — | "Started" \| "Starting" \| "Stopped" \| "Stopping" \| "Unknown" |
| | getCoreVersion | — | String — sing-box version + tags |
| | quitApp | — | bool (returns immediately, process dies ~250ms) — `finishAffinity + Process.killProcess` для применения `Libbox.setup(debug=…)` |
| **Settings (boot prefs / native toggles)** | getAutoStart / setAutoStart | bool | bool — auto-start VPN on boot (`BootReceiver`) |
| | getKeepOnExit / setKeepOnExit | bool | bool — keep VPN running когда Flutter-процесс убит |
| | getCoreLogsEnabled / setCoreLogsEnabled | bool | bool — §043 forward sing-box logs to Dart `AppLog`; требует full process restart |
| | getAllowBypass / setAllowBypass | bool | bool — §049 F15 `VpnService.Builder.allowBypass()`; apply на следующем `establish()` |
| | getBackgroundMode / setBackgroundMode | "never" \| "lazy" \| "always" | bool — §052 foreground-service tunnel sleep mode |
| **Notifications** | setNotificationTitle | `title: String` | bool — кастомный foreground notification title |
| **Per-app routing helpers** | getInstalledApps | — | List<Map> (`package` / `appName` / `isSystemApp`) — без icons (тяжело) |
| | getAppIcon | `packageName: String` | String (base64 PNG) |
| | getAppInfo | `packageName: String` | Map (name+isSystem, **без icon** — §109) \| `{notFound: true}` (подтверждённо не установлен) \| error (retryable) |
| **System helpers** | isIgnoringBatteryOptimizations | — | bool |
| | openBatteryOptimizationSettings | — | bool — primary `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` prompt; fallback на список apps для OEM где direct prompt молча отбрасывается (ColorOS / MIUI / HyperOS) |
| | openAppDetailsSettings | — | bool |
| | openAppSettings | — | bool — App Permissions screen (3-уровневый OEM fallback: `MANAGE_APP_PERMISSIONS` → `MANAGE_PERMISSION_APPS` → `ACTION_APPLICATION_DETAILS_SETTINGS`). Для permissions без runtime prompt (`ACCESS_BACKGROUND_LOCATION` API 30+) |
| | areNotificationsEnabled | — | bool |
| | openNotificationSettings | — | bool |
| | checkNotificationPermission | — | bool — `POST_NOTIFICATIONS` на API 33+, true на pre-33 |
| | requestNotificationPermission | — | null — async; UI должен re-check через `checkNotificationPermission` |
| | checkNearbyWifiPermission | — | bool — `NEARBY_WIFI_DEVICES` на API 33+, true на pre-33 |
| | requestNearbyWifiPermission | — | null — async; re-check |
| | showToast | `msg: String, duration: "short"\|"long"` | bool |
| **Quick Settings tile** | requestAddTile | — | bool — `StatusBarManager.requestAddTileService` (API 33+) |
| **Diagnostics** | getApplicationExitInfo | — | List<Map> (API 30+) |
| | getLogcatTail | `count?, level?` | String |

**EventChannel `status_events`** — `TunnelStatusEvent`:
```json
{ "status": "Started" | "Starting" | "Stopped" | "Stopping", "error": "..." }
```

**EventChannel `coreLog`** — sing-box log lines, по одной строке на event. Filter (skip TRACE/DEBUG) + ANSI-strip применяются в `BoxVpnService.writeDebugMessage` до отправки. Включается через `core_logs_enabled` toggle (`Libbox.setup(SetupOptions{debug: ...})`, читается в `BoxApplication.onCreate` один раз — изменение применяется только после restart процесса).

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

Tab'ы которые depend на глобальном toggle в settings (core_logs_enabled / VPN settings vars) умеют open соответствующий screen с правильно открытым tab'ом. Реализация: `initialTab` parameter на `AppSettingsScreen` / `SettingsScreen`, `DefaultTabController.initialIndex: widget.initialTab.clamp(0, length-1)`.

Два паттерна — **contextual banner** (state-зависимый hint) и **overflow item** (state-independent jump):

- **Statistics → Live + Per-app → contextual `CoreLogsHintBanner`** ([core_logs_hint_banner.dart](../app/lib/widgets/core_logs_hint_banner.dart)). Inline banner widget показывается **только когда `core_logs_enabled=false`**; self-hides при включении (auto-refresh на `AppLifecycleState.resumed`). Split hit-zone: левая зона (i + «DNS / router events off») → tooltip с объяснением что без core logs DNS resolves пропадают и process attribution ухудшается до Clash poll'а; правая («turn on Forward sing-box logs» + chevron) → deep-link в `AppSettingsScreen(initialTab: 1)` с auto-scroll и highlight нужного toggle'а. Это лучше чем PopupMenu overflow: явно виден когда нужен, исчезает когда не нужен.
- **Routing → Tunnel apps → ⋮ → "VPN settings (Core)"** → `SettingsScreen(initialTab: 1)`. State-independent jump (всегда полезно ходить из Tunnel apps к Core vars), overflow PopupMenu уместен. Открывает Core а не System — юзер настраивает Tunnel apps mode и хочет рядом mtu / log_level / dns_final.
- **Drawer → Debug → ⋮ → "Diagnostics settings"** → `AppSettingsScreen(initialTab: 1)` — fast-path на Quit&reopen после toggle Forward sing-box logs.

---

## Clash API client

Sing-box экспонирует **Clash-совместимый HTTP API** (`experimental.clash_api`) — мы используем его для всего management'а помимо start/stop/reload (они идут через `BoxVpnClient`). Файл — [`app/lib/services/clash_api_client.dart`](../app/lib/services/clash_api_client.dart).

### Endpoint discovery

`ClashEndpoint.fromConfigJson(configRaw)` парсит JSON5 (поддержка `//`-комментариев) и достаёт:

```json5
"experimental": {
  "clash_api": {
    "external_controller": "127.0.0.1:63130",   // host:port или http://...
    "secret": "<auto-generated>"                  // используется как Bearer token
  }
}
```

Default port если поле отсутствует — `127.0.0.1:9090` (Clash conventional). У нас sing-box генерирует random ephemeral port (49152-65535) при template build — защита от port-scan'а через DNS rebinding. Secret — auto-generated, никогда не пустой (security by default).

`ClashApiClient(endpoint)` принимает endpoint и держит **два HTTP-клиента**:
- `_http` — основной (`fetchProxies`, `selectInGroup`, `fetchConnections`, `fetchTraffic`, ...)
- `_delayHttp` — изолированный для `delay` / `groupDelay`. `cancelDelays()` закрывает только этот клиент → in-flight ping requests рвутся, но dashboard / selector switches не страдают.

### Используемые endpoints

| Endpoint | Метод client'а | Назначение |
|---|---|---|
| `GET /version` | `pingVersion` | Health-check (для `/state/clash` Debug API) |
| `GET /proxies` | `fetchProxies` | Список proxy + selector groups + chains. Фильтрация selectorGroupTags / urltestNow — static helpers. |
| `PUT /proxies/{tag}` | `selectInGroup(group, outbound)` | Selector switch. Body `{"name":"<child-tag>"}` |
| `GET /proxies/{tag}/delay` | `delay(proxyTag, timeoutMs, url)` | Single delay test (ms) |
| `GET /group/{tag}/delay` | `groupDelay(group, timeoutMs, url, onProgress)` | Force URLTest на группе |
| `GET /connections` | `fetchConnections` | List active TCP/UDP + bytes + metadata.process |
| `DELETE /connections` | `closeAllConnections` | Close all (используется в `resetNetwork`) |
| `DELETE /connections/{id}` | `closeConnection(id)` | Close one |
| `GET /traffic` (SSE) | `fetchTraffic` | Streaming traffic stats — мы читаем **только первый frame** (snapshot) |

### Gotchas

- **Emoji в URL path** (`✨auto`, `🇮🇹⚡Италия`) — обязательно URL-encode. `selectInGroup` / `delay` это делают автоматически (`Uri.parse`); внешние curl-вызовы — через `python3 urllib`.
- **Group `.now` quirk** — sing-box обновляет `now` только на первом `urltest_interval` tick, не от `/group/.../delay` ручного вызова. Мы это знаем и не пытаемся читать `.now` сразу после force-urltest'а.
- **Timeout buffer** — после `groupDelay(timeoutMs)` ждём ещё `_delayResponseBuffer = 750ms` для cleanup/JSON-encode на стороне sing-box. Без этого buffer'а Dart timing rare-falsely cancel'ил bona-fide responses.
- **No dashboards** — мы не даём подключаться сторонним клиентам (yacd / clash-meta-dashboard). Clash API только для self-fetch — порт ephemeral, secret не прокидывается наружу.

### Wiring

`HomeController._rebuildClashEndpoint()` вызывается на каждом `connected` event:
1. Парсит `state.configRaw` через `ClashEndpoint.fromConfigJson`.
2. Если endpoint валиден → создаёт новый `ClashApiClient(endpoint)`.
3. Старый client cancel'ит in-flight delays.

Endpoint становится невалидным когда tunnel down — secret и port были у убитого sing-box, port может быть переиспользован системой. Поэтому `_clash = null` на disconnect, recreate на next connect.

Debug API `/clash/*` — transparent proxy в наш `ClashApiClient.endpoint` с auto-injection `Authorization: Bearer <secret>` (caller не должен знать secret). См. [docs/api/clash-api-reference.md](api/clash-api-reference.md).

---

## State Management

| Controller | Responsibility |
|-----------|---------------|
| `HomeController` | VPN lifecycle, Clash API, nodes, ping (10 concurrent — `_pingConcurrency`), heartbeat, traffic, configChangedNeedRestart, autoUpdater wiring, haptic on transitions |
| `SubscriptionController` | CRUD entries (server_lists), `refreshEntry`/persist, `generateConfig` (no HTTP), `bindAutoUpdater`, init sweep (inProgress→failed) |
| `ThemeNotifier` | Theme mode, SharedPreferences persistence |
| `HapticService` (singleton) | Event-based haptic with 100 ms throttle, respects system setting (spec 029) |
| `AutoUpdater` | Owned by HomeScreen; wraps SubscriptionController for 4-trigger auto-update with spam gates (spec 027) |

Pattern: `ChangeNotifier` + `AnimatedBuilder`. `HomeState` is immutable with `copyWith` (sentinel `_unset` for nullable fields).

`_needsRestart` in HomeScreen is a derived getter — returns `true` when `_subController.configDirty || (state.tunnelUp && state.configChangedNeedRestart)`. **§076 update**: `configDirty` branch is no longer gated on `tunnelUp` — settings-changed banner shows whenever there are pending changes, independent of tunnel state. Two banners mutually exclusive: blue «Settings changed» for `configDirty`, pink «Restart VPN» for `tunnelUp && configChangedNeedRestart && !configDirty`. Sticky until tunnel up↔down transition (see spec 003 §8a).

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
       ├─ NodeRow layout: [ACTIVE pill] [PROTOCOL · transport · security (§102)] ... [ping →]
       └─ long-press: Ping · Use · View JSON · Copy URI
          (§099 — copy-JSON варианты в dropdown внутри View JSON:
           Copy node JSON / Copy server JSON / Copy server + detours(N))
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
| **configChangedNeedRestart sticky flag** | Restart warning doesn't disappear on Stop-dialog cancel |
| **TLS-insecure → info severity** | Providers set it intentionally (REALITY, self-signed); shouldn't crowd out genuine warnings |
| **Shared `asBroadcastStream` for status events** (v1.4.0) | `BoxVpnClient.onStatusChanged` cached as `late final` — один native `onListen`, `statusSink` стабилен. Раньше каждый вызов getter'а перезаписывал sink и ломал основной listener после первого reconnect'а. См. tasks/001. |
| **Blocking `stopVPN` через Completer** (v1.4.0) | Method channel ждёт `setStatus(Stopped)` на native (5с timeout) — caller получает control только после реального завершения. Убирает race в `onStartCommand` guard в reconnect'е. См. tasks/002. |
| **Intent-based sticky reset** (v1.4.0) | `configChangedNeedRestart=false` в `_stopInternal`/`_startInternal` по факту применённого намерения, не только по transition event'у. Robust к Doze/OOM потерям broadcast'ов. |
| **`TunnelStatus.unknown`** (v1.4.0) | Default для неизвестного raw вместо `disconnected` — убирает ложные срабатывания `firstWhere` predicate'ов на мусорных events. UI маппит в Disconnected label. |
| **`ConfigCache` в HomeState** (v1.4.0; superseded §091 → `ParsedConfig`) | Outbound JSON парсился один раз при `saveParsedConfig`, не в itemBuilder'е. §091 заменил пару `protoByTag`/`detourTags` полноценной моделью `ConfigNode` (см. строку §091 ниже). |
| **`kDetourTagPrefix` single source of truth** (v1.4.0) | Константа `⚙ ` в `lib/config/consts.dart` — used by node_settings UI, builder, home filter, node_filter screen. Раньше литералы дублировались. |
| **Two persist patterns: Lazy vs Eager** (v1.9.0, §076) | Editing screens с toggle-flood UX (`tun_apps_tab`, `routing_screen`, `dns_settings_screen`, `settings_screen` Core) используют **lazy** — mutations in-memory + `_markDirty` (sync `configDirty=true`), flush on `dispose()` + `paused`, rebuild lazy на возврат к home. Discrete-event screens (`subscriptions`, `app_settings`, `custom_rule_edit`, `node_filter`) — **eager** immediate-write + snackbar. 1 settings + 1 config write per editing session вместо до 10 (per-toggle eager). |
| **Global `HomeReturnObserver`** (v1.9.0, §076) | Universal `NavigatorObserver` в `MaterialApp.navigatorObservers`. Срабатывает при `previousRoute.isFirst == true` (home стал top). Покрывает все navigation пути — drawer, long-press, system back, swipe, programmatic pop, cross-nav. Раньше rebuild trigger был в `_pushRoute.then()` callback'е — терялся при опен screen через non-drawer пути. |
| **mtime-based bootstrap** (v1.9.0, §076; §113) | `ConfigDirtyCheck.isDirty()` сравнивает `lxbox_settings.json.mtime > singbox_config.json.mtime` (**секундная резолюция**, §113) на launch. Восстанавливает `configDirty` после kill mid-edit без persist'а флага. `subController.init` set'ит флаг, `home._initSubsAndAutoUpdate` триггерит тихий bootstrap rebuild. **§113**: после §107 порядок дисковых записей инвертирован (конфиг пишется на возврате к home, настройки — позже на `dispose`), из-за чего `settings>config` стало нормой → ложный «config changed» после kill. Фикс: (а) `configDirty` владеется `SettingsStorage` — config-значимые сейверы (typed + config-var allowlist, **не** `saveServerLists`) сами поднимают флаг (`SubscriptionController.configDirty` — делегат); (б) `_save()` при снятом флаге выравнивает mtime конфига к mtime настроек (`ConfigDirtyCheck.touchConfig`). |
| **`markConfigChangedNeedRestart` external mark** (v1.9.0, §076) | `HomeController` method для настроек применяемых вне config pipeline. Native VPN System toggles (allow_bypass / keep_on_exit / background_mode) после `_vpn.setX` вызывают этот метод → home banner вместо локального snackbar'а. Gated на `tunnelUp`. |
| **Cohesion over line-count + `part`/`mixin` декомпозиция** (§089) | Монстры (home_screen 2370, home_controller 1089, …) раздроблены не по числу строк, а по ответственности: тонкий экран + `<screen>/widgets/` + presenter/VM; контроллер + `part`-mixin'ы (та же библиотека → library-private доступ сохранён, поведение bit-identical). ~600 строк легитимны для cohesive-файла; крупные исключения задокументированы (см. [Обзор](#принцип-cohesion-over-line-count-089)). |
| **`ConfigNode` структурная мета вместо reverse-parse тега** (§091, реализовано) | `config-tag == нода в Clash`; протокол/detour достаются из конфига по тегу без reverse-map. Один `ParsedConfig` (parsed раз на `configRaw`, поле `HomeState.configModel`) заменил `ConfigCache.protoByTag/detourTags` + `ConfigIntrospection` + reverse-map `subscriptionsOfTag` (теперь prefix-фильтр, `home/subscription_lookup.dart`). Класс багов §077/§079/§080 устранён структурно. §102/§103 — eager `transportLabel`/`securityLabel` для subtitle и variant-фильтра. +14 тестов. |

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
| **libbox** (native) | sing-box core — fork [`Leadaxe/sing-box-lx`](https://github.com/Leadaxe/sing-box-lx) (`with_awg` + `with_xhttp`, §097/§104). Пин — `app/android/libbox.version` (`v1.13.13-lx.5`); AAR скачивает `scripts/fetch-libbox.sh` из GH Releases форка (SHA256-verify) в gitignored `libs/` — и локально (`build-local-apk.sh`), и в CI (`ci.yml` → «Fetch sing-box-lx core»). Maven-строка стокового `libbox 1.13.11` удалена из `build.gradle.kts` (исторически: JitPack `com.github.singbox-android:libbox:1.13.11`, миграция из `io.github.sagernet:libbox` — spec 039) |

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

Живут в [`docs/spec/features/`](./spec/features/). Каждая фича — папка `NNN name/spec.md`. Только **живые** продуктовые / архитектурные концепции; исторические / superseded / one-shot миграции — в [`docs/spec/tasks/`](./spec/tasks/) (см. [§054 spec reorg](./spec/tasks/054-spec-reorg-features-vs-tasks.md)).

| # | Feature |
|---|---------|
| 003 | Home screen |
| 006 | Servers UI |
| 007 | Config editor |
| 008 | Ping and node management |
| 009 | UX and theme |
| 010 | Quick start and offline |
| 011 | Local ruleset cache |
| 012 | Native VPN service |
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
| 024 | Load balance — *Draft* |
| 025 | WARP integration — *Draft* |
| **026** | **Parser v2** (sealed NodeSpec, 3-layer pipeline) |
| **027** | **Subscription auto-update** (4 triggers, spam gates) |
| **028** | **AntiDPI: mixed-case SNI** |
| **029** | **Haptic feedback** |
| 030 | Custom routing rules (unified `CustomRule` model: inline + local-only SRS) |
| 031 | Debug API (localhost HTTP server для dev introspection) |
| 032 | Quick Connect (QS tile + home shortcut) |
| 033 | Preset bundles (selectable rules с `preset_id`, expansion + merge) |
| 034 | App icon |
| 035 | MCP server — *Draft* |
| 036 | Update check (GitHub Releases polling, sideload-flow) |
| 037 | Naive proxy support |
| 038 | Crash diagnostics (`getHistoricalProcessExitReasons`) |
| 040 | Backup & restore UI (4 toggleable categories) |
| 042 | Health watchdog (heartbeat metrics + auto-recovery) |
| 043 | AppLog per-source quotas + diagnostics platform (Debug API + AppLog + Crash diagnostics) |
| **044** | **Per-app traffic profiler** (recording per-app DNS/connections/routing chain — Live/Domains/IPs/Connections sub-tabs, connection-issue detection, Debug API + SSE) |
| 045 | TLS ECH (Encrypted Client Hello) — anti-DPI extension прячущий SNI целиком — *Draft* |
| 046 | Tunnel apps split-tunneling (per-app include/exclude через VpnService.Builder) |
| 047 | Public Intent API (Tasker / Macrodroid automation через Android broadcast intents) — *Draft* |
| 048 | Home node filters (двухфазная pool/match модель — фундамент Filter mode §095/§096/§103) |
| 070 | Sort options (меню сортировки нод) |
| 071 | Manual node reorder (drag; §100 — manual в карусели + персист) |
| 074 | Add server wizard |
| 076 | Settings & config lifecycle (lazy/eager persist, HomeReturnObserver, mtime-bootstrap) |
| **097** | **AWG2 (AmneziaWG 2.0) + смена ядра на `sing-box-lx`** (`with_awg`/`with_xhttp`: AWG/AWG2 end-to-end, нативный XHTTP, MTU-кламп 1280; §104 — fork-ядро во всех сборках через `fetch-libbox.sh`) |

**Демотированные (через §054) — теперь в `tasks/`:**

| Был | Теперь |
|-----|--------|
| ~~001~~ Mobile stack | [`tasks/055-mobile-stack-decision/`](./spec/tasks/055-mobile-stack-decision/spec.md) — historical architectural decision |
| ~~002~~ MVP scope | [`tasks/056-mvp-scope-historical/`](./spec/tasks/056-mvp-scope-historical/spec.md) — historical milestone |
| ~~004x~~ Subscription parser | [`tasks/057-subscription-parser-v1-superseded/`](./spec/tasks/057-subscription-parser-v1-superseded/spec.md) — superseded by §026 |
| ~~005x~~ Config generator | [`tasks/058-config-generator-wizard-v1-superseded/`](./spec/tasks/058-config-generator-wizard-v1-superseded/spec.md) — superseded by §026 |
| ~~013~~ Routing | [`tasks/059-routing-v1-superseded/`](./spec/tasks/059-routing-v1-superseded/spec.md) — superseded by §030 |
| ~~039~~ libbox 1.13 migration | [`tasks/060-libbox-1-13-migration/`](./spec/tasks/060-libbox-1-13-migration/spec.md) — one-shot migration (Done) |
| ~~041~~ DNS rules refactor | [`tasks/061-dns-rules-refactor/`](./spec/tasks/061-dns-rules-refactor/spec.md) — refactor, live spec — §014 |

Освобождённые номера (001, 002, 004, 005, 013, 039, 041) **не переиспользуются** — archive-ссылки сохраняются.

Дополнительно — летопись отдельных рабочих циклов (баги, рефакторинги): [`docs/spec/tasks/`](./spec/tasks/). Процессы (например, ночная работа): [`docs/spec/processes/`](./spec/processes/).

---

## Reusable layers (extraction targets)

LxBox monolith — но архитектурно есть несколько self-contained слоёв, которые **в принципе** можно вынести в отдельные packages (Flutter pub.dev) или хотя бы в `packages/` подпапку monorepo. Этот раздел — чек-лист для будущей extraction'а: что reusable, что coupled с LxBox, что надо параметризовать перед публикацией.

### Layer 1 — Sing-box VPN engine (Kotlin + Dart channel)

**Что:** Native обёртка над libbox + Dart MethodChannel client. Без UI, без opinion'ов о config-формате.

| Файлы | Lines |
|---|---|
| `app/android/.../vpn/{BoxApplication, BoxVpnService, BoxService, PlatformInterfaceWrapper, VpnPlugin, ConfigManager, ServiceNotification, VpnStatus, DefaultNetworkMonitor, DefaultNetworkListener, LocalResolver, BootReceiver, Extensions}.kt` | ~3000 |
| `app/lib/vpn/box_vpn_client.dart` | ~600 |
| `app/lib/models/{tunnel_status, background_mode, app_info}.dart` | ~150 |

**Public API surface:** `BoxVpnClient.I` (см. раздел [Dart `BoxVpnClient` API surface](#dart-boxvpnclient-api-surface)) + EventChannel'ы status/coreLog.

**Coupling с LxBox (надо разорвать перед extraction):**
- **Channel names hardcoded** — `com.leadaxe.lxbox/methods`, `com.leadaxe.lxbox/status_events`, `lxbox/coreLog`. Параметризовать через plugin config.
- **SharedPreferences keys hardcoded** — `boxvpn_boot.{auto_start_vpn, keep_vpn_on_exit, background_mode, core_logs_enabled}`. Префикс должен быть configurable или общий fallback.
- **Notification icon / channel name** — `ServiceNotification.kt` ссылается на `R.drawable.ic_notification` + строки. Должно браться из host app.
- **Manifest declarations** — package должен **документировать** требуемые permissions (location, NEARBY_WIFI_DEVICES, FGS, etc.) и intent-filters (BootReceiver, TileService) для host app.
- **`WifiNetworkObserver` зависит от Dart-side `wifi_history` MethodChannel** — это §051 фича LxBox, не general-purpose. Извлекать **отдельно** или сделать optional.

**Quality gates пройдены:** §049 audit (atomic CAS, F1 split, F2-F26 fixes), §050 closeout (refnum 42 root cause = `SecurityException` через JNI). Wrapper зрелый.

**iOS:** отсутствует. Для cross-platform package — отдельная задача (Network Extension + Packet Tunnel Provider + Swift bridges).

### Layer 2 — Clash API client

**Что:** Pure-Dart HTTP client для Clash API (sing-box-compatible).

| Файлы | Lines |
|---|---|
| `app/lib/services/clash_api_client.dart` | ~320 |
| `app/lib/config/clash_endpoint.dart` | ~50 |

**Coupling с LxBox:** **минимальный**. Зависит только от `package:http` и `package:json5` (для `// comments` в config). Никакого `lxbox`-specific кода.

**API surface:** см. раздел [Clash API client](#clash-api-client). Уже generic — fetchProxies / selectInGroup / delay / groupDelay / fetchConnections / fetchTraffic.

**Готовность к extraction:** **высокая**. Можно опубликовать почти как есть. Нужно только тесты добавить (сейчас integration через `HomeController`).

### Layer 3 — Sing-box subscription parser / builder

**Что:** Sealed `NodeSpec` (10 protocol variants) + URI/JSON/INI parsers + builder NodeSpec → sing-box config JSON.

| Файлы | Lines |
|---|---|
| `app/lib/models/{node_spec, node_spec_emit, tls_spec, transport_spec, ...}.dart` | ~2000 |
| `app/lib/services/parser/*.dart` | ~1500 |
| `app/lib/services/builder/*.dart` | ~2000 |

**Coupling с LxBox:** **высокий**. Builder зависит от `wizard_template.json` shape (наш формат preset'ов / vars / sections), `SettingsStorage` (server_lists, vars, custom_rules), и от наших sealed моделей (`ServerList`, `CustomRule`).

**Готовность к extraction:** **низкая**. Нужен серьёзный refactor — отделить `NodeSpec` parser/emit (reusable) от builder pipeline (LxBox-specific). Имеет смысл только если есть конкретный re-use case.

### Layer 4 — TrafficProfiler

**Что:** Per-app + system-wide observer DNS/TCP/UDP events.

**Coupling:** **высокий** — см. coupling notes в [секции 6.5](#65-per-app-traffic-profiler-044). Зависит от `AppLog` instance, sing-box log format, `ClashApiClient` instance. Расцеплять для extraction нужно через 3 интерфейса (log source, log format adapter, connection poller).

**Готовность:** низкая. Имеет смысл только если LxBox VPN engine уже extracted и кто-то строит на нём свой profiler.

### Дорожная карта extraction (если решим идти)

1. **Phase 1** — Clash API client как самостоятельный package (`clash_api_dart`). Самый низкий риск, ~2 дня work. Верифицирует extraction процесс.
2. **Phase 2** — Sing-box VPN engine в `packages/flutter_singbox/` (path dependency monorepo). Refactor channel names + SharedPreferences keys + notification config. ~1 неделя work. Не публикуем на pub.dev пока — верифицируем что LxBox работает.
3. **Phase 3** — Решение про публикацию: GPLv3 viral от libbox = main blocker. Если ОК с GPLv3-only userbase — публикуем.
4. **Phase 4** — iOS support (если нужен).

**Текущий статус:** ничего не extracted. Есть смысл начать с Layer 2 (Clash API client) как trial extraction.
