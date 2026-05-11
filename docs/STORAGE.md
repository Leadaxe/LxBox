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
├─ excluded_nodes[]              list          node tags выкинутые юзером из group resolve / mass-ping
├─ enabled_groups[]              list          включённые preset-группы (selector membership)
├─ last_global_update            ISO-8601      timestamp последнего auto-refresh
├─ presets_migrated              bool          one-shot guard (legacy enabled_rules+rule_outbounds → custom_rules)
│
└─ (legacy)
    ├─ enabled_rules[]                          мигрируется → обнуляется
    ├─ rule_outbounds            object           мигрируется → обнуляется
    ├─ proxy_sources[]                          (v1) → server_lists (v2), one-shot, удаляется
    ├─ app_rules[]                              (до v1.3.2) → custom_rules.kind=inline, удаляется
    ├─ node_overrides                           удаляется на каждом _save()
    └─ show_detour_servers                      удаляется на каждом _save()
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
  "excluded_nodes":     [ … ],     // tags выкинутые юзером из mass-ping
  "enabled_groups":     [ … ],     // включённые preset-группы (selector membership)
  "last_global_update": "ISO-8601",// последняя auto-refresh подписок
  "presets_migrated":   true,      // one-shot guard (legacy → custom_rules)

  // Legacy — мигрируются и обнуляются на первом чтении.
  "enabled_rules":      [],
  "rule_outbounds":     {}
}
```

Кэш в памяти: `SettingsStorage._cache` (lazy-loaded). Запись atomic'ом через `JsonEncoder.withIndent('  ')`. На каждом `_save()` удаляются легаси-ключи `node_overrides` и `show_detour_servers`.

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

Список источников нод. Был `proxy_sources` (v1) — мигрирует one-shot через `migrateProxySources` при первом чтении.

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
  "outbound":       "<tag>"        // или "reject" (sentinel → action: reject)
}
```

`name` — пользовательский, mutable.

OR-семантика внутри category, AND между. `protocols` и `ipIsPrivate` не headless'ятся, выносятся в routing-rule level.

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
  "outbound":    "<tag>"
}
```

Сам бинарь `.srs` лежит отдельно в `rule_sets/<tag>.srs` (см. [таблицу файлов](#disk-layout) выше).

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
- Отдельный legacy-ключ `app_rules` (отдельная таба до v1.3.2) → one-shot absorb в `custom_rules` с `packages` через `_absorbLegacyAppRules`. Старый ключ удаляется.

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
  "body":        { … }?              // только inline; partial sing-box server БЕЗ tag/description/enabled
}
```

**Семантика kind:**

- `template` — ссылка на сервер из шаблона. Юзер может оверрайднуть `enabled` / `description`, body берётся из шаблона.
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

## Прочие top-level ключи

| Ключ | Тип | Назначение |
|---|---|---|
| `route_final` | `String` | Override `route.final` поверх template (выбранный default outbound). `''` = template-default. |
| `excluded_nodes` | `List<String>` | Node tags выкинутые юзером — пропускаются в group resolve и mass-ping. |
| `enabled_groups` | `List<String>` | Включённые preset-группы (selector membership). |
| `last_global_update` | `String` (ISO-8601) | Timestamp последнего успешного auto-refresh всех подписок. |
| `presets_migrated` | `bool` | One-shot guard для legacy-миграции `enabled_rules + rule_outbounds → custom_rules`. После одного прохода `RoutingScreen._load` ставит true. |

---

## Legacy / удалённые ключи

| Ключ | Жил | Замена | Migration |
|---|---|---|---|
| `proxy_sources` | до v1.3.x | `server_lists` ([§033]) | `migrateProxySources` — one-shot, удаляется после конверсии. |
| `app_rules` | до v1.3.2 | `custom_rules` (kind=inline, c `packages`) — [§030] | `_absorbLegacyAppRules` — one-shot, удаляется. |
| `enabled_rules` | до [§030] | `custom_rules` | One-shot в `RoutingScreen._load`, обнуляется (`saveEnabledRules({})`). Гард: `presets_migrated`. |
| `rule_outbounds` | до v1.3.2 | `custom_rules.outbound` (или `varsValues.outbound` для preset) | См. выше, обнуляется (`saveRuleOutbounds({})`). |
| `dns_options.rules_json` | [§061] (intermediate) | `dns_options.rules[]` | Поле остаётся для downgrade-friendliness, builder/UI больше не читают. |
| `node_overrides` | удалённое | — | Удаляется на каждом `_save()`. |
| `show_detour_servers` | удалённое | — | Удаляется на каждом `_save()`. |

---

## SharedPreferences (Android)

Не часть `lxbox_settings.json`. Используется для двух категорий: **pre-Flutter boot flags** (читаются в `BoxApplication.initialize()` до того, как Flutter engine стартует) и **UI prefs** через `shared_preferences`-плагин.

| Ключ | Тип | Источник | Спека | Назначение |
|---|---|---|---|---|
| `app_theme_mode` | `"system"` / `"light"` / `"dark"` | Flutter | — | UI theme. |
| `haptic_enabled` | `"true"` / `"false"` | Flutter | [§029] | Haptic feedback toggle. |
| `boxvpn_boot.auto_start_vpn` | `Boolean` | Kotlin | — | Auto-start VPN на boot (если разрешено). |
| `boxvpn_boot.keep_vpn_on_exit` | `Boolean` | Kotlin | — | Не глушить tun при swipe-kill app. |
| `boxvpn_boot.background_mode` | `String` | Kotlin | — | Foreground-service режим. |
| `boxvpn_boot.core_logs_enabled` | `Boolean` | Kotlin | [§043][043-applog] | Читается в `BoxApplication.initialize()` ДО Flutter, поэтому здесь, а не в `lxbox_settings.json`. |

---

## Debug API exposure

`SettingsStorage.dumpCache()` возвращает deep-copy всего `_cache`. `GET /state/storage` ([§031]) использует через сериализатор `services/debug/serializers/storage.dart`, который **фильтрует по allow-list** — чтобы не утекли:

- `vars.debug_token`
- subscription URLs (`server_lists[].url`)
- `meta.support_url` / `meta.web_page_url`

См. конкретный allow-list в `serializers/storage.dart`. Любое новое sensitive-поле — добавлять в фильтр.

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
[043-applog]: ./spec/features/043%20applog%20per-source%20quotas/spec.md
[043-dns]: ./spec/tasks/043-dns-servers-refs-by-kind.md
