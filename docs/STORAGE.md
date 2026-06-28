# Persistent Storage

Полная схема того, что L×Box хранит на диске между запусками. Документ — источник правды для shape'а файлов и migration history. `ARCHITECTURE.md` ссылается сюда.

User-state живёт в `lxbox_settings.json`; catalog of presets/vars/sections — в template'е (см. [`TEMPLATE.md`](./TEMPLATE.md)).

## `lxbox_settings.json` — full tree

> **Нотация**:
> - `object{N keys}` — объект с N ключами
> - `list[N]` — массив с N элементами; `list` без числа — массив переменной длины
> - `<TypeName>` — element-type для массива (показано отдельно ниже)
> - `?` после типа — поле опциональное

```
lxbox_settings.json                          # SettingsStorage (Dart), главный файл state
│
├─ vars                          object          template-vars override + app feature flags
│   └─ <key>: string                           ─ напр. log_level, dns_final, debug_token,
│                                                auto_update_subs, last_known_version, ...
│
├─ server_lists[]                list          §033 — sealed (subscription / user)
│   └─ <ServerList>              object          discriminator: type
│       ├─ type                  "subscription"|"user"
│       ├─ id                    uuid          стабильный
│       ├─ name                  string        UI display
│       ├─ enabled               bool
│       ├─ tag_prefix            string        префикс для node tags
│       ├─ detour_policy         object{4 keys}       {register_detour_servers, register_detour_in_auto,
│       │                                       use_detour_servers, override_detour}
│       │                        — subscription only —
│       ├─ url                   string?       подписочный URL
│       ├─ meta                  object?         SubscriptionMeta из HTTP-headers (§027):
│       │   ├─ upload_bytes / download_bytes / total_bytes  int?
│       │   ├─ expire_timestamp  int?          unix seconds
│       │   ├─ support_url / web_page_url      string?
│       │   ├─ profile_title     string?
│       │   └─ update_interval_hours           int?
│       ├─ last_updated          ISO-8601?     успех
│       ├─ last_update_attempt   ISO-8601?     любая попытка
│       ├─ last_update_status    "never"|"ok"|"failed"|"inProgress"
│       ├─ update_interval_hours int           default 24
│       ├─ last_node_count       int
│       ├─ consecutive_fails     int           для UI "(N fails)"
│       │                        — user only —
│       ├─ origin                "paste"|"file"|"qr"|"manual"
│       ├─ created_at            ISO-8601
│       └─ raw_body              string        оригинал для reparse
│
├─ custom_rules[]                list          §030 — sealed (inline / srs / preset)
│   └─ <CustomRule>              object          discriminator: kind
│       ├─ kind                  "inline"|"srs"|"preset"
│       ├─ id                    uuid
│       ├─ name                  string        пользовательский (для preset — read-only snapshot)
│       ├─ enabled               bool
│       │                        — inline (CustomRuleInline) —
│       ├─ domains[]             list?         OR-группа #1: domain (full match)
│       ├─ domainSuffixes[]      list?         OR-группа #1: ".ru" etc.
│       ├─ domainKeywords[]      list?         OR-группа #1: substring match
│       ├─ ipCidrs[]             list?         OR-группа #1: "10.0.0.0/8"
│       ├─ ports[]               list?         OR-группа #2: "443"
│       ├─ portRanges[]          list?         OR-группа #2: "8000:9000"
│       ├─ packages[]            list?         OR-группа #3: package_name
│       ├─ protocols[]           list?         routing-rule level: bittorrent/tls/http/...
│       ├─ ipIsPrivate           bool?         routing-rule level
│       ├─ outbound              tag           "<outbound-tag>" или "reject" sentinel
│       │                        — srs (CustomRuleSrs) —
│       ├─ srsUrl                string        URL .srs-бинаря
│       ├─ ports / portRanges / packages / protocols / ipIsPrivate / outbound
│       │                        — preset (CustomRulePreset) —
│       ├─ presetId              string        ссылка на selectable_rules[].preset_id
│       └─ varsValues            object          юзерские vars override (включая 'outbound')
│
├─ dns_options                   object          §061 (rules) + §043+§044 (servers)
│   ├─ servers[]                 list          §044 kind-discriminated refs:
│   │   └─ <DnsServerRef>        object
│   │       ├─ kind              "template"|"preset"|"inline"
│   │       ├─ enabled           bool
│   │       ├─ tag               string        single source of truth (НЕ дублируется в body)
│   │       ├─ description       string?       optional override / для inline — primary
│   │       └─ body              object?         только inline; partial sing-box server
│   │                                          БЕЗ tag/description/enabled
│   ├─ rules[]                   list          §061 origin-discriminated:
│   │   └─ <DnsRuleRef>          object
│   │       ├─ enabled           bool
│   │       ├─ type              "user"|"template"|"rule"
│   │       ├─ title             string        display
│   │       └─ rule              object?         sing-box rule body (для type=user)
│   └─ rules_json                string        DEPRECATED legacy single-string (§061)
│
├─ ping_options                  object          §040
│   ├─ url                       string?       global default URL
│   ├─ timeout_ms                int?          global default timeout
│   ├─ presets[]                 list?         pre-built URL options (template-side)
│   └─ groups                    object?         per-group override
│       └─ <groupTag>            object          {url?, timeout_ms?}
│
├─ route_final                   string        override sing-box route.final
├─ excluded_nodes[]              list          §125-cleanup DEPRECATED — глобальный node-filter (§048) удалён; safe-мусор
├─ enabled_groups[]              list          §125 DEPRECATED — читается только миграцией channels[]. Safe-мусор.
├─ channels[]                    list          §125 — каналы роутинга (template→storage). См. ниже.
│   └─ <item>                    object
│       ├─ tag                   string        системный immutable id 'vpn-1'..'vpn-10' (автоген; vpn-1 неудаляем)
│       ├─ label                 string        отображаемое имя (юзер вводит)
│       ├─ enabled               bool          вкл/выкл (vpn-1 всегда true)
│       ├─ include_direct        bool          direct-out опцией селектора
│       ├─ include_block         bool          §201 — block (дроп трафика) опцией селектора; default false
│       ├─ node_filter           string        regex по итоговому tag ноды; '' = все
│       ├─ node_filter_invert    bool          §197 — инверсия node_filter (ноды НЕ матчащие); default false
│       ├─ default_filter        string        regex; первая matched → default; '' = нет
│       ├─ interrupt_exist_connections  bool   selector.interrupt_exist_connections
│       └─ auto                  object?       null = галка ВЫКЛ; object → urltest-двойник <tag>-auto (tag производный, не хранится)
│           ├─ url               string        urltest test endpoint
│           ├─ interval          string        duration ("5m")
│           ├─ tolerance         int           ms, uint16 (§161 — clamp 0..65535)
│           ├─ idle_timeout      string        duration ("30m")
│           └─ interrupt_exist_connections  bool  urltest.interrupt_exist_connections
├─ channels_migrated             bool          §125 — guard one-shot миграции enabled_groups→channels
├─ last_global_update            ISO-8601      timestamp последнего auto-refresh
├─ presets_migrated              bool          §159 — guard «дефолтные пресеты засеяны» (fresh-install seed)
├─ interrupt_connections_on_switch  bool       §143 — рвать соединения переключаемой группы при смене ноды (default false, НЕ config-significant)
├─ node_sort_mode                string        §100 — выбранный режим сортировки нод ('' = template-default)
├─ node_manual_order[]           list          §100 — ручной порядок node tags (для mode=manual)
└─ native_prefs                  object        §189 — ЗЕРКАЛО шести Android-prefs (`boxvpn_boot.*`).
    │                                            JSON = источник истины (диск); native = рабочая копия.
    ├─ auto_start                bool          default false  — auto-start VPN на boot
    ├─ keep_on_exit              bool          default true   — §188: не глушить tun при swipe-kill
    ├─ background_mode           string        default "never" — never|lazy|always (Doze-поведение)
    ├─ core_logs_enabled         bool          default false  — forward sing-box-логов
    ├─ allow_bypass              bool          default false  — Allow VPN bypass (§069)
    └─ auto_redirect             bool          default false  — auto-redirect

# §159 — все legacy-ключи (proxy_sources / app_rules / enabled_rules /
# rule_outbounds / node_overrides / show_detour_servers / vars.auto_rebuild)
# больше НЕ обрабатываются: миграции и DENY-`.remove()` удалены. Если такой
# ключ ещё лежит на диске — он безвреден (никем не читается) и будет отброшен
# allowlist'ом при первом импорте бэкапа.
```

Каждый ключ описан подробно в разделах ниже.

## Disk layout

Все пути — относительно **Android internal documents directory** (`getApplicationDocumentsDirectory()`). На устройстве этот каталог недоступен без root или Debug API (`GET /state/storage`).

```
getApplicationDocumentsDirectory()/
├── lxbox_settings.json
├── singbox_config.json
├── http_cache/
│   ├── <sha1(url)>.body
│   └── <sha1(url)>.headers
├── rule_sets/
│   └── <tag>.srs
├── applog.txt
└── corelog.txt

Android SharedPreferences:
├── Flutter prefs                # app_theme_mode, haptic_enabled, …
└── boxvpn_boot.*                # pre-Flutter boot flags
```

| Файл / каталог | Кто пишет | Что внутри | Спека |
|---|---|---|---|
| `lxbox_settings.json` | `SettingsStorage` (Dart) | App settings, vars, server lists, custom rules, DNS, ping. **Главный файл этого документа.** | — |
| `singbox_config.json` | `ConfigManager` (Kotlin) | Финальный sing-box JSON, скармливаемый libbox. Перегенерируется на каждый `buildConfig`. Не входит в backup. | — |
| `http_cache/<sha1(url)>.body` + `.headers` | `HttpCache` (Dart) | Сырое тело + headers подписки для offline-rehydrate на старте. | [§027] |
| `rule_sets/<tag>.srs` | `RuleSetDownloader` (Dart) | Кэш бинарных `.srs` rule-set файлов. | [§011] |
| `applog.txt` | `AppLog` (Dart) | App-side warn/error лог, JSON-lines, ring-buffer 200 строк / 64 KB. | [§038], [§043][043-applog] |
| `corelog.txt` | `AppLog` (Dart) | Sing-box warn/error лог. Сообщения приходят в Dart через `ClashLogPump` (HTTP stream от Clash API libbox'а), затем `AppLog.add(source: core)` пишет их сюда тем же ring-buffer-механизмом, что и `applog.txt`. 200 строк / 64 KB. | [§043][043-applog] |
| Android `SharedPreferences` | Kotlin (`BoxApplication`) + Flutter (`shared_preferences`) | Pre-Flutter boot flags + UI prefs. См. раздел [«SharedPreferences»](#sharedpreferences-android) ниже. | — |

---

## `lxbox_settings.json` — top-level

```jsonc
{
  "vars":               { … },     // Map<String,String>
  "server_lists":       [ … ],     // subscription / user
  "custom_rules":       [ … ],     // sealed: inline / srs / preset
  "dns_options":        { … },     // rules + servers
  "ping_options":       { … },
  "route_final":        "<tag>",   // override route.final
  "excluded_nodes":     [ … ],     // §125-cleanup DEPRECATED (глобальный node-filter удалён)
  "enabled_groups":     [ … ],     // §125 DEPRECATED (читается только миграцией channels[])
  "channels":           [ … ],     // §125 — каналы роутинга (template→storage)
  "channels_migrated":  true,      // §125 — guard миграции enabled_groups→channels
  "last_global_update": "ISO-8601",// последняя auto-refresh подписок
  "presets_migrated":   true,      // §159 — guard «дефолты засеяны» (fresh-install seed)
  "interrupt_connections_on_switch": false, // §143 — рвать conns группы при смене ноды (НЕ config-significant)
  "node_sort_mode":     "",        // §100
  "node_manual_order":  [ … ],     // §100
  "native_prefs":       { … }      // §189 — зеркало boxvpn_boot.* (JSON = истина)
}
```

Кэш в памяти: `SettingsStorage._cache` (lazy-loaded). Запись atomic'ом через `JsonEncoder.withIndent('  ')`. §159 — на `_save()` ключи больше НЕ чистятся (DENY-`.remove()` удалён); единственная чистка мусора — allowlist на входе (`replaceRaw`).

Per-key спеки и shape — в разделах ниже.

---

## `vars` — template-vars + app flags

Плоский `Map<String, String>` (значения toString'ятся при чтении). Используется и для **template-substitution** (любое `@name` в `wizard_template.json` подставляется отсюда), и для **app feature-flags** (debug/auto-update/UI).

### Известные ключи

| Ключ | Default | Спека | Что делает |
|---|---|---|---|
| `auto_update_subs` | `'true'` | [§027] | Global gate auto-refresh подписок. Manual всегда работает. |
| `auto_check_updates` | `'true'` | [§036] | GitHub Releases polling на старте. |
| `last_update_check_at` | `''` | [§036] | UTC ISO-8601, last polling timestamp. |
| `last_known_version` | `''` | [§036] | Закэшированный latest tag. |
| `dismissed_update_version` | `''` | [§036] | Тег, который юзер закрыл — снэкбар не показываем пока не сменится. |
| `config_locked_for_debug` | `'false'` | [§037] | `generateConfig()` возвращает null silently. Юзер пинит свой config через `PUT /config`. |
| `debug_enabled` | `'false'` | [§031] | Debug API server runtime toggle. |
| `debug_token` | `''` | [§031] | Bearer token для всех `/api/*`. |
| `debug_port` | `'9269'` | [§031] | TCP-порт. Range 1024–49151. |
| `dns_final` | template | [§043][043-dns] | Финальный DNS-резолвер (`cloudflare_udp` / `google_udp` / `local_dns_resolver` / `yandex_udp` / любой tag из `dns_options.servers`). |
| `auto_record_wifi_history` | `'false'` | [§051] Phase 3 | Native `WifiNetworkObserver` пушит current SSID/BSSID в `wifi_history` если provel >5 минут на сети. Default off — privacy default. Toggle в App Settings → Diagnostics. |
| `wifi_history` | `'[]'` | [§051] Phase 3 | JSON-encoded `[{ssid, bssid, last_seen}]` (см. отдельный раздел ниже). |
| `<custom>` | — | — | Любые юзерские template-vars, выставленные через UI / `PUT /settings/vars/<key>`. |

`removeVar(k)` ≠ `setVar(k, '')` — пустая строка может быть legitimate value, отсутствие ключа возвращает default.

---

## `server_lists` — [§033] (v2)

Список источников нод. Был `proxy_sources` (v1) — §159 удалил миграцию; legacy-ключ игнорируется.

Sealed по полю `type`:

### `type: "subscription"` — `SubscriptionServers`

```jsonc
{
  "type":                  "subscription",
  "id":                    "<uuid>",          // стабильный
  "name":                  "<display>",
  "enabled":               true,
  "tag_prefix":            "<str>",           // префикс для node tags при сборке
  "detour_policy":         { … },             // см. ниже
  "url":                   "https://…",
  "meta":                  { … }?,            // SubscriptionMeta — HTTP-headers
  "last_updated":          "ISO-8601"?,       // успех
  "last_update_attempt":   "ISO-8601"?,       // любая попытка
  "last_update_status":    "never|ok|failed|inProgress",
  "update_interval_hours": 24,
  "last_node_count":       0,
  "consecutive_fails":     0                  // для UI "(N fails)"; freezing — in-memory
}
```

### `type: "user"` — `UserServer`

```jsonc
{
  "type":          "user",
  "id":            "<uuid>",
  "name":          "<display>",
  "enabled":       true,
  "tag_prefix":    "<str>",
  "detour_policy": { … },
  "origin":        "paste|file|qr|manual",
  "created_at":    "ISO-8601",
  "raw_body":      "<original input>"         // для reparse при багах
}
```

### `detour_policy` (общий)

```jsonc
{
  "register_detour_servers":  false,
  "register_detour_in_auto":  false,
  "use_detour_servers":       true,
  "override_detour":          ""               // '' = no override
}
```

### `meta` (опционально)

Из HTTP-headers подписки ([§027]):

```jsonc
{
  "upload_bytes":          0,
  "download_bytes":        0,
  "total_bytes":           0,
  "expire_timestamp":      <unix>?,
  "support_url":           "…"?,
  "web_page_url":          "…"?,
  "profile_title":         "…"?,
  "update_interval_hours": 24?
}
```

`nodes` массив **не хранится** — реконструируется из `raw_body` (для `user`) или из `http_cache/` (для `subscription`) на старте.

---

## `custom_rules` — [§030] sealed (inline / srs / preset)

Дискриминатор `kind`. Backward-compat: если в JSON нет `kind`, читается как `inline`.

### `kind: "inline"` — `CustomRuleInline`

```jsonc
{
  "kind":           "inline",
  "id":             "<uuid>",
  "name":           "<display>",
  "enabled":        true,
  "domains":        [ … ]?,        // OR-группа #1
  "domainSuffixes": [ … ]?,
  "domainKeywords": [ … ]?,
  "ipCidrs":        [ … ]?,
  "ports":          [ … ]?,        // OR-группа #2: "443"
  "portRanges":     [ … ]?,        //              "8000:9000", ":3000", "4000:"
  "packages":       [ … ]?,        // OR-группа #3
  "protocols":      [ … ]?,        // routing-rule level (subset of kKnownProtocols)
  "ipIsPrivate":    true?,         // routing-rule level
  "outbound":       "<tag>",       // или "reject" (sentinel → action: reject)
  "dns":            { "enabled": true, "serverTag": "<dns-server tag>" }?  // §117 задача 3
}
```

`name` — пользовательский, mutable.

OR-семантика внутри category, AND между. `protocols` и `ipIsPrivate` не headless'ятся, выносятся в routing-rule level.

`dns` ([§117] задача 3, «DNS follows the rule») — опционально: builder эмитит mirror DNS-rule `{rule_set: <тот же headless>, server: serverTag}` в атомарной mirror-группе (порядок = routing-правила). Отсутствует в старых записях → null → старое поведение. Гейт: при непустых `ports`/`protocols` mirror не эмитится.

### `kind: "srs"` — `CustomRuleSrs`

```jsonc
{
  "kind":        "srs",
  "id":          "<uuid>",
  "name":        "<display>",
  "enabled":     true,
  "srsUrl":      "https://…/something.srs",
  "ports":       [ … ]?,          // routing-rule-level доп-фильтры
  "portRanges":  [ … ]?,
  "packages":    [ … ]?,
  "protocols":   [ … ]?,
  "ipIsPrivate": true?,
  "outbound":    "<tag>",
  "dns":         { "enabled": true, "serverTag": "<dns-server tag>" }?  // §117 задача 3
}
```

Сам бинарь `.srs` лежит отдельно в `rule_sets/<tag>.srs` (см. [таблицу файлов](#disk-layout) выше).

`dns` ([§117] задача 3) — как у inline, но mirror ссылается на существующий `.srs`-тег + DNS-безопасные доп-фильтры (`packages`/wifi). Работает только если в rule-set есть домены (IP-only лист в DNS-контексте не матчит).

### `kind: "preset"` — `CustomRulePreset`

```jsonc
{
  "kind":       "preset",
  "id":         "<uuid>",
  "name":       "<display, snapshot of preset.label>",
  "enabled":    true,
  "presetId":   "<id from template>",
  "varsValues": { "<varName>": "<value>", "outbound": "<tag>" }?
}
```

`name` — read-only в UI (🔒), периодически синхронизируется с `preset.label` из шаблона. Содержимое разворачивается на каждом `buildConfig` через `expandPreset` ([§033]). `outbound` хранится в `varsValues['outbound']` как universal override ([§033] Expansion §5).

### Backward-compat

- Поле `target` (до v1.4.1) → `outbound`. Читается обоими названиями.
- `kind` отсутствует → `inline` (read-path).
- Legacy-ключ `app_rules` (отдельная таба до v1.3.2) — §159 удалил миграцию `_absorbLegacyAppRules`; ключ игнорируется (отбрасывается allowlist'ом на импорте).

---

## `dns_options` — [§061] (rules) + [§043][043-dns] + [§044] (servers)

```jsonc
{
  "servers":     [ <ServerRef>, … ],
  "rules":       [ <RuleRef>,   … ],
  "rules_json":  "<deprecated>"
}
```

### `dns_options.servers[i]` — kind-discriminated ref ([§044])

```jsonc
{
  "kind":        "template" | "preset" | "inline",
  "enabled":     <bool>,
  "tag":         "<string>",        // SINGLE source of truth, не дублируется в body
  "description": "<string>"?,        // optional override; для inline — primary
  "body":        { … }?,             // только inline; partial sing-box server БЕЗ tag/description/enabled
  "varValues":   { "<name>": "<value>", … }?  // §117, только template: выбранные значения vars
}
```

**Семантика kind:**

- `template` — ссылка на сервер из шаблона ([§117]: обёртка `{vars, server}`, tag в `server.tag`). Юзер может оверрайднуть `enabled` / `description` и выбрать значения vars (`varValues`: `outbound`-канал, IP-профиль, domain resolver — см. TEMPLATE.md); body резолвится из шаблона подстановкой `@var`'ов (`resolveTemplateDnsServerBody`).
- `preset` — то же, но из активного preset-bundle (`server_lists` тут не при чём, имеется в виду template preset).
- `inline` — пользовательский сервер. `body` обязателен. Если tag совпадает с template/preset И shape матчится → builder может схлопнуть в `template`/`preset` ref (см. `_serverShapesMatch`).

**Render order в UI:** `template` → `preset` → `inline` (сорт по `ServerKind.index`, stable внутри группы).

**Builder** синтезирует `body.tag` обратно при сборке финального sing-box-конфига. В storage tag живёт **только** на ref-level.

### `dns_options.rules[i]` — [§061]

```jsonc
{
  "enabled": <bool>,
  "type":    "user" | "template" | "rule",
  "title":   "<display>",
  "rule":    { … }?                  // sing-box rule body, для type=user
}
```

`type` — origin-discriminator (предшественник [§044] `kind`, исторически другое слово).

`type: template/rule` — orphan-cleanup: title не нашёлся в активном шаблоне/пресете → выбрасывается в `resolveDnsRulesList`.

### Migration history

- v1.5.x: `dns_options.rules_json` — single JSON-string (`@Deprecated`). Сейчас игнорится; поле остаётся на диске для downgrade-friendliness.
- v1.6.0 ([§061]): `dns_options.rules[]` — структурированный список с `type`/`enabled`/`title`/`rule`.
- v1.6.0 ([§043][043-dns]): `dns_options.servers[]` — kind-refs впервые. Tag/description/enabled тогда жили в `body`.
- v1.6.1 ([§044]): `dns_options.servers[]` — clean schema. Tag/description/enabled подняты на ref-level. Underscore-аннотации (`_kind`, `_overrides`, `_origin`, `_preset_label`) удалены. Builder синтезирует tag в body. One-shot migration в `_migrateLegacyDnsServers`.
- v1.7.x ([§117]): template-серверы в шаблоне — обёртки `{description, enabled, vars?, server}`; ref-запись `kind: template` получила `varValues`. Миграции нет (не нужна): kind-ref'ы валидны как есть, удалённые из шаблона теги (`quad9_dot`, `adguard_dot`, `adguard_family`, `google_doh_vpn`) орфан-чистятся, vars применяют дефолты; inline-серверы юзера не трогаются.

---

## `ping_options` — [§040]

```jsonc
{
  "url":        "https://…",          // global default URL
  "timeout_ms": <int>,                 // global default timeout
  "presets":   [ … ],                  // pre-built URL-options (template-side)
  "groups": {                          // per-group override (опционально)
    "<groupTag>": {
      "url":        "…"?,
      "timeout_ms": <int>?
    }
  }
}
```

Resolve chain в `HomeController`: `groups[tag]` → root → template default.

CRUD-helpers: `setGlobalPingUrl`, `setGlobalPingTimeout`, `setGroupPing`, `clearGroupPing`. Все — sugared над `getPingOptions`/`savePingOptions` (которые перетирают целиком).

---

## `tun_apps` — [§046]

OS-level split-tunneling: какие приложения идут через VPN-tun, а какие — direct через cellular/wifi (минуя sing-box полностью).

```jsonc
{
  "mode": "off" | "allow" | "deny",
  "packages": ["com.example.app", "ru.tinkoff.investing", ...]
}
```

| `mode` | Что попадает в `inbound[type=tun]` финального config | Эффект |
|---|---|---|
| `"off"` | (ничего не пишем) | Все apps через tun (Android-default) |
| `"allow"` | `"include_package": [...packages]` | Только перечисленные через tun. Остальные direct |
| `"deny"`  | `"exclude_package": [...packages]` | Все КРОМЕ перечисленных через tun |

**Native слой** (`BoxVpnService.kt:557-560`) читает `options.includePackage` / `excludePackage` от libbox и зовёт `VpnService.Builder.addAllowedApplication` / `addDisallowedApplication`. Применяется на `builder.establish()` — на изменение нужен **full VPN restart**, light reload (`startOrReloadService`) не пересоздаёт tun.

**Default для existing юзеров:** `{mode: "off", packages: []}` — backward-compat. Migration unconditional на первом `_load()` после upgrade, без guard'а.

**В `/state/storage` exposed без scrubber'а** — package-names не sensitive.

CRUD: `getTunApps()` / `setTunApps()` (replace целиком). API: `GET/PUT /settings/tun_apps` ([Debug API reference](api/debug-api-reference.md)).

**Конфликт с `package_name` rules в custom_rules:** apps в `Allow-list` (или вне `Deny-list`) идут через tun → routing rules (rule_set / package_name match / etc) применяются нормально. Apps вне `Allow-list` (или внутри `Deny-list`) **не попадают в tun вообще** — sing-box их не видит, custom rules с `package_name` для них не сматчатся.

---

## `vpn_mode` — [§119]

Режим работы VPN (inbound-трактовка): как ядро ловит трафик.

```jsonc
{
  "mode": "vpn" | "proxy" | "vpn_proxy",
  "proxy_protocol": "mixed" | "http" | "socks",
  "proxy_port": 2080,
  "proxy_listen": "127.0.0.1" | "0.0.0.0",
  "proxy_auth_enabled": true,
  "proxy_username": "user",
  "proxy_password": "<32-hex или пусто>"
}
```

`proxy_protocol` = sing-box inbound `type` локального прокси: `mixed` (HTTP+SOCKS5 на одном порту, default), `http` (только HTTP, без UDP), `socks` (только SOCKS5). У всех трёх одинаковая auth-структура `users:[{username,password}]`; tag всегда `mixed-in` (от протокола не зависит).

| `mode` | inbound'ы финального config | `VpnService.establish()` | Эффект |
|---|---|---|---|
| `"vpn"` | `tun-in` (auto_route) | да | весь трафик системы через tun (текущее поведение, **default**) |
| `"proxy"` | `mixed-in` (без tun) | **нет** (libbox не зовёт `openTun`) | локальный HTTP+SOCKS-порт; приложения настраиваются вручную; нет иконки ключа VPN |
| `"vpn_proxy"` | `tun-in` + `mixed-in` | да | системный перехват И локальный порт одновременно |

**Builder** (`applyVpnMode`, `post_steps/vpn_mode.dart`) трансформирует `config.inbounds` императивно из этой модели (ДО `applyTunPackages`):
- `proxy` — удаляет `tun-in`, добавляет `mixed-in`, re-tag'ит `tun-in` resolve/sniff правила на `mixed-in`.
- `vpn_proxy` — оставляет `tun-in`, добавляет `mixed-in` + отдельные resolve/sniff для него (sniff только если `sniff_enabled != false`).
- `mixed-in` = `{type:mixed, tag:mixed-in, listen, listen_port, users?}`.

**Auth.** `users:[{username,password}]` пишется только при `effectiveAuth && password != ""`. На `0.0.0.0` (LAN-exposed) auth **форсится on** (снять нельзя — `effectiveAuth` игнорирует `proxy_auth_enabled`); на `127.0.0.1` — опционально. Пароль/username идут **императивно**, НЕ через `@var`-substitution (type-coercion `_resolveVar` испортил бы числовой/«true»-пароль). Пароль генерится в UI при первом включении auth (`generateProxyPassword`, 32-hex, образец `clash_secret`).

**Смена режима меняет inbounds → full VPN restart** (наследуется от config-dirty машинерии: home banner Apply/Restart). `markConfigChangedNeedRestart()` дёргается при touch'е.

**Default для existing юзеров:** ключ отсутствует → `mode=vpn` (= текущее поведение, post-step no-op). **Миграция не нужна** — отсутствие ключа эквивалентно дефолту.

CRUD: `getVpnMode()` / `setVpnMode()` (replace целиком).

**Native:** изменений в Kotlin нет — proxy-режим достигается чисто конфигом (foreground/`protect`/override tun-agnostic). См. [features/119](spec/features/119%20vpn-mode/spec.md).

---

## `warp_account` — [§025]

Кеш зарегистрированного Cloudflare WARP-аккаунта (кнопка «Get WARP»). Приватный ключ генерится X25519 **на устройстве** и сюда же кешируется; в Cloudflare уходит только публичная часть.

```jsonc
{
  "priv_key": "<base64 X25519 — СЕКРЕТ, не логировать>",
  "peer_pub": "<base64 peer public key>",
  "client_v4": "172.16.0.2",
  "client_v6": "2606:4700:110::…",
  "client_id": "<base64, 3 байта → WireGuard reserved>",
  "account_id": "…",
  "device_id": "…",
  "token": "<bearer — СЕКРЕТ, не логировать>",
  "endpoint": "engage.cloudflareclient.com:2408",
  "created_at": "<ISO8601>",
  "license": "<WARP+ key или null>",
  "warp_plus": false
}
```

**Назначение — идемпотентность.** При повторном «Get WARP» (`reuse=true`, default) аккаунт переиспользуется вместо новой регистрации устройства в Cloudflare. «Re-register» (`forceNew`) чистит ключ → следующий вызов регистрирует заново. Сам WARP-узел в конфиг попадает **не** отсюда, а через обычный `UserServer` (собирается из `WarpAccount.toWireguardUri()` → `addFromInput` → endpoints[]). Поэтому ключ **не** config-significant: при его записи `markConfigDirty` не дёргается.

**Секреты.** `priv_key`/`token` — реальные секреты в локальном файле приложения. В логах/diag-снапшотах маскируются (`WarpAccount.redacted()`). При добавлении новых diag-дампов — не включать сырой `warp_account`.

**`reserved`.** `client_id` (base64, 3 байта) доносится до sing-box endpoint как per-peer `reserved: [b0,b1,b2]`. Без него WARP-handshake проходит, но трафик не идёт. Парсинг/emit — `parseReserved` (`uri_utils.dart`) + `WireguardPeer.reserved`.

CRUD: `getWarpAccount()` / `setWarpAccount(account?)` (null = очистить). См. [features/025](spec/features/025%20warp%20integration/spec.md).

---

## `wifi_history` — [§051] Phase 3

JSON-encoded array записей сетей которые юзер реально посетил — для editor'а custom rules (`Pick saved` picker когда пишешь правило с условием `wifi_ssid` / `wifi_bssid`). Хранится как **JSON-string** в `vars.wifi_history` (не отдельный top-level ключ — чтобы не плодить shape'ы), декодируется при чтении.

```jsonc
[
  {"ssid": "HomeWiFi", "bssid": "aa:bb:cc:dd:ee:ff", "last_seen": "2026-05-10T12:34:56.789Z"},
  {"ssid": "OfficeWiFi", "bssid": "11:22:33:44:55:66", "last_seen": "2026-05-09T08:15:32.000Z"},
  ...
]
```

| Поле | Тип | Notes |
|---|---|---|
| `ssid` | String | Required. Не нормализуется (case-sensitive — провайдеры могут так и эдак). |
| `bssid` | String | Может быть пустым. При upsert нормализуется к **lower-case** + trim. Composite-key `(ssid, bssid)` — `Home/aa:bb:..` и `Home/AA:BB:..` это одна запись (после normalize), `Home/aa:bb` и `Home/cc:dd` — разные. |
| `last_seen` | String (ISO-8601 UTC) | Время последнего observe. `addToWifiHistory` обновляет на upsert. |

**Cap 50 записей** (`_wifiHistoryCap` constant). LRU evict — newest-first (insert at index 0), oldest падает с tail при overflow.

**Источники наполнения:**
1. **Auto-record** (`auto_record_wifi_history=true`) — native `WifiNetworkObserver` через `NetworkCallback` listener. Stickiness debounce: записывается только если юзер сидит на сети ≥5 минут (фильтр от random transitions home/office/coffeeshop).
2. **Manual** — editor UI: `Add current` button (читает sing-box `readWIFIState` напрямую), `Pick saved` (выбирает из существующих записей).
3. **Debug API** — `POST /wifi_history` (для test fixtures, restore, etc) — см. [Debug API reference](api/debug-api-reference.md#wi-fi-history--wifi_history).

CRUD: `getWifiHistory()` / `addToWifiHistory(ssid, bssid)` / `removeFromWifiHistory(ssid, bssid)` / `clearWifiHistory()` в `SettingsStorage`.

**Privacy default** — `auto_record_wifi_history=false`. Юзер opt-in'ит в App Settings → Diagnostics. Silent network logging это privacy-след даже local-only.

**В `/state/storage` exposed без scrubber'а** — SSID/BSSID не sensitive в контексте настроек (если уже видны в `WifiInfo` системного уровня).

---

## `native_prefs` — [§189] зеркало `boxvpn_boot.*`

JSON-зеркало шести Android-prefs, которые исторически жили **только** в native
`SharedPreferences` (`boxvpn_boot.*`). Реализация — `lib/services/settings_storage/native_prefs.dart`.

```jsonc
{
  "auto_start":        false,    // auto-start VPN на boot
  "keep_on_exit":      true,     // §188 — не глушить tun при swipe-kill (default ON)
  "background_mode":   "never",  // never | lazy | always — Doze-поведение туннеля
  "core_logs_enabled": false,    // forward sing-box-логов в Dart
  "allow_bypass":      false,    // §069 — Allow VPN bypass
  "auto_redirect":     false     // auto-redirect
}
```

**Модель «диск = истина, оперативка = рабочая копия».** Эта секция в
`lxbox_settings.json` — **источник истины** (диск). Native `SharedPreferences`
(`boxvpn_boot.*`) — **рабочая копия в оперативке**, нужная для **Dart-less
моментов**, когда Flutter-движок недоступен: `BOOT_COMPLETED` (`BootReceiver`),
swipe `onTaskRemoved`, `openTun`/`establish`. native читает свою копию синхронно
и **никогда не пишет JSON** (единственное исключение — bootstrap-seed, см. ниже).

**Поток записи (write-through).** Любой `setX` → пишет в JSON (первично) →
зеркалит в native через method-channel. Все писатели — UI
(`vpn_mode_tab`/`settings_screen`/`app_settings_screen`), импорт (`backup_service`),
Debug API handlers — идут через единую дверь `SettingsStorage.setNativeBool` /
`setNativeBackgroundMode`. Прямые native-записи в обход этого слоя эфемерны:
старт-`sync` (ниже) откатит их на следующем запуске.

**Старт** (`SettingsStorage.bootstrapAndSyncNativePrefs()`, зовётся из `main.dart`
до UI):
- секции `native_prefs` нет (первый старт после §189) → **bootstrap**: seed
  native ⇒ JSON (единственный случай native⇒JSON-записи);
- секция есть → **sync**: JSON ⇒ native, диск перезаливает оперативку для
  расходящихся ключей — расхождение само чинится.

**Backup.** Единая сериализация блока — `SettingsStorage.exportNativePrefsBackup()`
/ `applyNativePrefsBackup()`: состав/дефолты/типы в одном месте
(`native_prefs.dart`). `backup_service` и Debug-handler делегируют сюда (раньше
дублировали). Wire-ключи стабильны (старые бэкапы импортируются). Производный
`has_tun` (см. ниже) **не** входит в backup-блок — это вычисляемое значение, не
настройка.

> **`has_tun` ([§192]) — седьмой native-ключ, НЕ в JSON-секции.**
> `boxvpn_boot.has_tun` (default `true`) — **производное** от [`vpn_mode`](#vpn_mode--119)
> (§119): `vpn`/`vpn_proxy` → `true`, `proxy` → `false`. Зеркалится при смене
> режима (`vpn_mode_tab._setMode` → `SettingsStorage.setNativeHasTun`) и на старте
> (`bootstrapAndSyncNativePrefs`). Гейтит `VpnService.prepare()`: в proxy-режиме
> `prepare` не зовётся (он зря забирает VPN-слот и отзывает чужой активный VPN).
> Гейт стоит на 6 точках входа (`BootReceiver.hasTun(...)`-чек). Так как это
> вычисляемое значение, оно живёт только в native (`boxvpn_boot.has_tun`) и **не**
> хранится в JSON-секции `native_prefs` — пересчитывается из `vpn_mode`.

---

## `channels` — [§125] каналы роутинга (template→storage)

Каналы (`vpn-1..vpn-10`) переехали из статичного `wizard_template.json`
(`preset_groups[]`) в storage. Template стал **seed'ом** — значениями по
умолчанию на первом запуске. После миграции состав каналов живёт в `channels[]`
и редактируется юзером (Routing → таб Channels → редактор канала).

- `tag` — **системный immutable** id (`vpn-1`..`vpn-10`), автогенерируется при
  создании (первый свободный `vpn-N`), юзер правит только `label`. Стабильный
  ключ ссылок (`route_final` / `ping_options` / custom-rule outbound / detour).
- `vpn-1` — продуктово-привилегированный: всегда `enabled`, неудаляем, дефолт
  `route_final`. Лимит каналов — **10**.
- `auto` (nullable) — параметры urltest-двойника. `null` = галка auto ВЫКЛ,
  `<tag>-auto` не эмитится. `auto.tag` НЕ хранится (производный `${tag}-auto`).
- **Резолюция в билдере**: каждый включённый канал эмитит selector `<tag>` с
  нодами после `node_filter` (regex по итоговому tag, §048-style) + опции
  `direct-out`/`block` (по `include_direct`/`include_block`, §201); если `auto !=
  null` и набор нод непуст — дополнительно urltest `<tag>-auto` (только ноды
  канала, без direct/block/auto). `default` = первая нода, чей tag матчит
  `default_filter`. Пустой/невалидный regex → все ноды.
- **Инверсия `node_filter_invert`** (§197): `true` → в канал попадают ноды, чей
  tag **НЕ** матчит `node_filter` (исключающий фильтр). Пустой `node_filter` →
  инверсия игнорируется (все ноды). Пример: `node_filter:"bypass",
  node_filter_invert:true` → все ноды кроме содержащих «bypass».
- **Пустой набор после фильтра** (regex/инверсия отсекли всё) → fallback selector
  `outbounds: ["block","direct-out"]`, `default: "block"` (§201 — безопаснее
  блокировать, чем выпускать мимо VPN; direct остаётся опцией). Билдер при этом
  пишет warning в баннер конфига (§200), если в подписке были ноды. `block`
  всегда присутствует в `config.outbounds[]` как системный outbound и валиден
  как `route_final`.
- **Миграция** (one-shot, guard `channels_migrated`): seed из
  `template.presetGroups` — `enabled_groups[]`/`default_enabled` → `enabled`
  (vpn-1 форсим true); `add_outbounds ∋ direct-out` → `include_direct`;
  `add_outbounds ∋ ✨auto` → `auto` из `@urltest_*` vars; `default_filter=''`.
  Глобальный `✨auto`-preset **не** мигрируется (он больше не канал — каждый
  канал делает свой двойник). `enabled_groups[]` после миграции депрекейтится.
- **Деградация ссылок**: при удалении канала любая ссылка на него (`route_final`
  / custom-rule outbound) переводится на `vpn-1` (storage + билдер). Legacy
  `✨auto`-ссылки попадают под то же правило.
- CRUD: `getChannels` / `setChannels` / `addChannel` (throws при 10) /
  `updateChannel` / `deleteChannel` (throws для vpn-1) / `migrateChannelsIfNeeded`.

Спека: [`docs/spec/features/125 configurable-channels/`](spec/features/125%20configurable-channels/).

---

## Прочие top-level ключи

| Ключ | Тип | Назначение |
|---|---|---|
| `route_final` | `String` | Override `route.final` поверх template (выбранный default outbound). `''` = template-default. Dangling-ссылка (удалённый канал / legacy ✨auto) → `vpn-1` при сборке (§125). |
| `excluded_nodes` | `List<String>` | §125-cleanup **DEPRECATED** — глобальный node-filter (§048) удалён вместе с экраном. Ключ остаётся в allowlist (безвредный legacy-мусор); per-channel `node_filter` (§125) покрывает фильтрацию. |
| `enabled_groups` | `List<String>` | §125 **DEPRECATED** — заменён на `channels[]`. Читается только one-shot миграцией; на диске остаётся безвредным мусором. |
| `last_global_update` | `String` (ISO-8601) | Timestamp последнего успешного auto-refresh всех подписок. |
| `presets_migrated` | `bool` | §159 — guard «дефолтные пресеты засеяны» (fresh-install seed). Имя ключа историческое (бывшая legacy-миграция); переиспользован, чтобы ранее мигрировавшие юзеры не получили повторный seed. `RoutingScreen._seedDefaultPresets` ставит true. |
| `interrupt_connections_on_switch` | `bool` | §143 — рвать активные соединения переключаемой группы при смене ноды (default `false`, НЕ config-significant). См. `getInterruptOnSwitch`/`setInterruptOnSwitch`. |
| `node_sort_mode` | `String` | §100 — выбранный режим сортировки нод. `''` = template-default. CRUD: `getNodeSort`/`setNodeSort` (пишутся парой с `node_manual_order`). |
| `node_manual_order` | `List<String>` | §100 — ручной порядок node tags (актуален для режима manual). Пишется вместе с `node_sort_mode`. |

> Отдельные структурные ключи описаны в собственных разделах выше: [`tun_apps`](#tun_apps--046), [`vpn_mode`](#vpn_mode--119), [`warp_account`](#warp_account--025). Это исчерпывающий список актуальных top-level ключей `lxbox_settings.json` (см. также §159 — реестр для allowlist-фильтра бэкапа: `SettingsStorage.allowedTopLevelKeys`).

---

## Legacy / удалённые ключи

> **§159 — все миграции и DENY-`.remove()` удалены.** Ни один из перечисленных
> ниже ключей больше не конвертируется и не вычищается на `_save()`. Если ключ
> ещё лежит на диске у старого юзера — он безвреден (никем не читается) и будет
> отброшен строгим allowlist'ом (`SettingsStorage.replaceRaw`) при первом
> импорте бэкапа. Кто застрял на доисторической версии без миграции — перенесёт
> настройки через экспорт/импорт или заново проставит галки.

| Ключ | Жил | Замена | Статус (§159) |
|---|---|---|---|
| `proxy_sources` | до v1.3.x | `server_lists` ([§033]) | миграция удалена, ключ игнорируется. |
| `app_rules` | до v1.3.2 | `custom_rules` (kind=inline, c `packages`) — [§030] | миграция удалена, ключ игнорируется. |
| `enabled_rules` | до [§030] | `custom_rules` | миграция + API удалены, ключ игнорируется. |
| `rule_outbounds` | до v1.3.2 | `custom_rules.outbound` (или `varsValues.outbound` для preset) | миграция + API удалены, ключ игнорируется. |
| `dns_options.rules_json` | [§061] (intermediate) | `dns_options.rules[]` | поле остаётся для downgrade-friendliness, builder/UI не читают. |
| `node_overrides` | удалённое | — | DENY-очистка удалена; игнорируется/отбрасывается на импорте. |
| `show_detour_servers` | удалённое | — | DENY-очистка удалена; игнорируется/отбрасывается на импорте. |
| `vars.auto_rebuild` | до §107 | — (rebuild всегда авто) | DENY-очистка удалена; отбрасывается на импорте. |

---

## SharedPreferences (Android)

Не часть `lxbox_settings.json`. Используется для двух категорий: **pre-Flutter boot flags** (читаются в `BoxApplication.initialize()` / `BootReceiver` до того, как Flutter engine стартует) и **UI prefs** через `shared_preferences`-плагин.

> **§189 — `boxvpn_boot.*` теперь ЗЕРКАЛО, не первоисточник.** Шесть native-prefs
> (`auto_start` / `keep_vpn_on_exit` / `background_mode` / `core_logs_enabled` /
> `allow_bypass` / `auto_redirect`) — **рабочая копия в оперативке** для Dart-less
> моментов (boot / swipe `onTaskRemoved` / `openTun`). **Источник истины — секция
> [`native_prefs`](#native_prefs--189-зеркало-boxvpn_boot) в `lxbox_settings.json`
> (диск)**: все writes идут write-through (JSON первично → зеркало в native), а на
> старте `sync` JSON⇒native выправляет расхождения. Единственное исключение —
> вычисляемый `has_tun` ([§192]), который живёт только здесь (производное от
> `vpn_mode`, в JSON не хранится).

> **Примечание (§159):** `haptic_enabled` ранее ошибочно числился здесь — по
> факту он живёт в `vars` (`lxbox_settings.json`), читается/пишется через
> `SettingsStorage.getVar/setVar` (см. `HapticService.prefsKey`). В разделе
> [`vars`](#vars--template-vars--app-flags) он учтён как app feature-flag.

| Ключ | Тип | Источник | Спека | Назначение |
|---|---|---|---|---|
| `app_theme_mode` | `"system"` / `"light"` / `"dark"` | Flutter | — | UI theme. |
| `boxvpn_boot.auto_start_vpn` | `Boolean` | Kotlin (зеркало JSON) | [§189] | Auto-start VPN на boot (если разрешено). Истина — `native_prefs.auto_start`. |
| `boxvpn_boot.keep_vpn_on_exit` | `Boolean` | Kotlin (зеркало JSON) | [§189]/§188 | Не глушить tun при swipe-kill app. Истина — `native_prefs.keep_on_exit` (default ON, §188). |
| `boxvpn_boot.background_mode` | `String` | Kotlin (зеркало JSON) | [§189] | Foreground-service режим (`never`/`lazy`/`always`). Истина — `native_prefs.background_mode`. |
| `boxvpn_boot.core_logs_enabled` | `Boolean` | Kotlin (зеркало JSON) | [§189], [§043][043-applog] | Forward sing-box-логов. Читается в `BoxApplication.initialize()` ДО Flutter — поэтому нужна native-копия. Истина — `native_prefs.core_logs_enabled`. |
| `boxvpn_boot.allow_bypass` | `Boolean` | Kotlin (зеркало JSON) | [§189]/§069 | Allow VPN bypass. Истина — `native_prefs.allow_bypass`. |
| `boxvpn_boot.auto_redirect` | `Boolean` | Kotlin (зеркало JSON) | [§189] | Auto-redirect. Истина — `native_prefs.auto_redirect`. |
| `boxvpn_boot.has_tun` | `Boolean` | Kotlin (зеркало `vpn_mode`) | [§192] | **Вычисляемое**, default `true`. Производное от `vpn_mode` (§119): proxy → `false`. Гейтит `VpnService.prepare()` (proxy не отзывает чужой VPN). **НЕ** в backup-блоке, **НЕ** в JSON-секции `native_prefs` — пересчитывается из `vpn_mode`. |

---

## Debug API exposure

`SettingsStorage.dumpCache()` возвращает deep-copy всего `_cache`. `GET /state/storage` ([§031]) использует через сериализатор `services/debug/serializers/storage.dart`, который **фильтрует по allow-list** — чтобы не утекли:

- `vars.debug_token`
- subscription URLs (`server_lists[].url`)
- `meta.support_url` / `meta.web_page_url`

См. конкретный allow-list в `serializers/storage.dart`. Любое новое sensitive-поле — добавлять в фильтр.

> **§159 — две РАЗНЫЕ модели фильтрации, не путать (намеренно):**
> - **выход** (`GET /state/storage`, `serializers/storage.dart`) — **denylist**
>   со scrubber'ом: всё видно разработчику, прячем только секреты. Новый ключ
>   виден автоматически.
> - **вход** (импорт бэкапа + Debug API `POST /backup/import`, через
>   `SettingsStorage.replaceRaw`) — **allowlist** default-deny: пишем только
>   известные ключи ([`allowedTopLevelKeys`] + app-флаги ∪ template-vars),
>   чужеродное отбрасывается. То же на `PUT /settings/ping_options` (strip
>   неизвестных subkeys).
>
> Разные задачи (показать всё vs не пустить чужое) → разные модели. НЕ
> «унифицировать» по ошибке.

`PUT /settings/dns_options/servers` принимает три исторических формата (legacy pre-[§043][043-dns], [§043][043-dns] и [§044]) — миграция происходит на следующий `resolveDnsServersList`. См. [`api/debug-api-reference.md`](./api/debug-api-reference.md).

---

[§011]: ./spec/features/011%20local%20ruleset%20cache/spec.md
[§027]: ./spec/features/027%20subscription%20auto%20update/spec.md
[§029]: ./spec/features/029%20haptic%20feedback/spec.md
[§030]: ./spec/features/030%20custom%20routing%20rules/spec.md
[§031]: ./spec/features/031%20debug%20api/spec.md
[§033]: ./spec/features/033%20preset%20bundles/spec.md
[§036]: ./spec/features/036%20update%20check/spec.md
[§037]: ./spec/tasks/037-debug-api-write-config-and-lock-rebuild.md
[§038]: ./spec/features/038%20crash%20diagnostics/spec.md
[§040]: ./spec/tasks/040-per-group-ping-test-settings.md
[§061]: ./spec/tasks/061-dns-rules-refactor/spec.md
[§044]: ./spec/tasks/044-dns-servers-clean-schema.md
[§046]: ./spec/features/046%20tunnel%20apps%20split-tunneling/spec.md
[§117]: ./spec/features/117%20dns-rework/spec.md
[§189]: ./spec/tasks/189-native-prefs-mirror-in-json.md
[§192]: ./spec/tasks/192-proxy-mode-prepare-revokes-foreign-vpn.md
[043-applog]: ./spec/features/043%20applog%20per-source%20quotas/spec.md
[043-dns]: ./spec/tasks/043-dns-servers-refs-by-kind.md
