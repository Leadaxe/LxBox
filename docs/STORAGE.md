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
├─ server_lists[]                list          §033 — sealed (subscription / user / folder §234)
│   └─ <ServerList>              object          discriminator: type
│       ├─ type                  "subscription"|"user"|"folder"
│       ├─ id                    uuid          стабильный
│       ├─ name                  string        UI display
│       ├─ enabled               bool
│       ├─ tag_prefix            string        префикс для node tags
│       ├─ detour_policy         object{5 keys}       {register_detour_servers, register_detour_in_auto,
│       │                                       use_detour_servers, override_detour, replace_detour_chain}
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
│       ├─ update_interval_hours int           default 24; §129 спец: -1=никогда, 0=respect server, N>0=каждые N ч
│       ├─ last_node_count       int
│       ├─ consecutive_fails     int           для UI "(N fails)"
│       ├─ disabled_hashes       map?          §283 — {identity-хеш ноды: ISO-8601 lastSeen}; per-node disable
│       ├─ identity              object?       §289 — per-sub override идентичности фетча (null=глоб.);
│       │                                      {user_agent?, send_hwid, hwid?, device_os?, ver_os?, device_model?}
│       │                        — user only —
│       ├─ origin                "paste"|"file"|"qr"|"manual"
│       ├─ created_at            ISO-8601
│       ├─ raw_body              string        оригинал для reparse
│       │                        — folder only (§234) —
│       ├─ created_at            ISO-8601
│       └─ members[]             list          {raw, enabled, detour?} — по фрагменту на члена (member ↔ нода 1:1; §237 detour = личный тег)
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
│       ├─ dns                   object? {enabled, serverTag, forceIpv4?}  §117/§256 — mirror DNS-rule + AAAA-глушилка
│       ├─ resolve               object? {only, strategy, …}   §247 — resolve-опция (route action resolve)
│       │                        — srs (CustomRuleSrs) —
│       ├─ srsUrl                string        URL .srs-бинаря
│       ├─ ports / portRanges / packages / protocols / ipIsPrivate / outbound / dns
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
├─ route_idle_suspend            string        §215/§128 — idle-suspend threshold (route.lx_idle_suspend);
│                                                duration ("30s"/"5m"), default "30s" (ВКЛючено), "" = off; config-significant
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
│           ├─ interrupt_exist_connections  bool  urltest.interrupt_exist_connections
│           ├─ mode              string        §208 — 'least_test' (default) | 'round_robin'
│           └─ balancer          object{3 keys}  §208 — {pool, pool_tolerance, sticky_hash[]}
├─ channels_migrated             bool          §125 — guard one-shot миграции enabled_groups→channels
├─ last_global_update            ISO-8601      timestamp последнего auto-refresh
├─ presets_migrated              bool          §159 — guard «дефолтные пресеты засеяны» (fresh-install seed)
├─ preset_ids_remapped           bool          §228 — guard one-shot ремапа переименованных preset_id (bittorrent-direct→bittorrent, private-ip-direct→private-ip, block_unknown→unknown-traffic)
├─ interrupt_connections_on_switch  bool       §143 — рвать соединения переключаемой группы при смене ноды (default false, НЕ config-significant)
├─ node_sort_mode                string        §100 — выбранный режим сортировки нод ('' = template-default)
├─ node_manual_order[]           list          §100 — ручной порядок node tags (для mode=manual)
├─ profiler_retention_sec        int           §044 — окно Live-журнала профайлера, default 600 (10 мин); НЕ config-significant
├─ warp_account                  object?       §025 — кеш WARP-аккаунта (см. раздел ниже)
├─ masque_account                object?       §130 — кеш MASQUE-WARP аккаунта (см. раздел ниже)
├─ tun_apps                      object        §046 — split-tunneling (см. раздел ниже)
├─ vpn_mode                      object?       §119 — режим inbound (см. раздел ниже)
└─ native_prefs                  object        §189 — ЗЕРКАЛО Android-prefs (`boxvpn_boot.*`).
    │                                            JSON = источник истины (диск); native = рабочая копия.
    ├─ auto_start                bool          default false  — auto-start VPN на boot
    ├─ keep_on_exit              bool          default true   — §188: не глушить tun при swipe-kill
    ├─ background_mode           string        default "never" — never|lazy|always (Doze-поведение)
    ├─ core_logs_enabled         bool          default false  — forward sing-box-логов
    ├─ allow_bypass              bool          default false  — Allow VPN bypass (§069)
    ├─ auto_redirect             bool          default false  — auto-redirect
    └─ memory_limit              string        default "auto" — §271: лимит памяти ядра
                                                 (auto|off|"200"|"384"|"512"|"768" МБ)

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
| `corelog.txt` | `AppLog` (Dart) | Sing-box warn/error лог. Строки приходят из Kotlin через `EventChannel lxbox/coreLog` (`BoxService.coreLogDrainer`, батчи `List<String>`); `ClashLogPump` (легаси-имя, НЕ Clash API — тот выпилен в §122) их принимает и `AppLog.add(source: core)` пишет сюда тем же ring-buffer-механизмом, что и `applog.txt`. TRACE/DEBUG отфильтрованы на native-стороне. 200 строк / 64 KB. | [§043][043-applog] |
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
  "route_idle_suspend": "30s",     // §215/§128 — idle-suspend threshold (default "30s"; "" = off)
  "excluded_nodes":     [ … ],     // §125-cleanup DEPRECATED (глобальный node-filter удалён)
  "enabled_groups":     [ … ],     // §125 DEPRECATED (читается только миграцией channels[])
  "channels":           [ … ],     // §125 — каналы роутинга (template→storage)
  "channels_migrated":  true,      // §125 — guard миграции enabled_groups→channels
  "last_global_update": "ISO-8601",// последняя auto-refresh подписок
  "presets_migrated":   true,      // §159 — guard «дефолты засеяны» (fresh-install seed)
  "interrupt_connections_on_switch": false, // §143 — рвать conns группы при смене ноды (НЕ config-significant)
  "node_sort_mode":     "",        // §100
  "node_manual_order":  [ … ],     // §100
  "profiler_retention_sec": 600,   // §044 — окно Live-журнала профайлера (НЕ config-significant)
  "warp_account":       { … },     // §025 — кеш WARP-аккаунта (секреты)
  "masque_account":     { … },     // §130 — кеш MASQUE-WARP аккаунта (секреты)
  "tun_apps":           { … },     // §046 — split-tunneling
  "vpn_mode":           { … },     // §119 — режим inbound
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
| `probe_ms_green` | `'250'` | §236 | Test servers (папки): верхняя граница «зелёной» задержки, мс. НЕ config-var (dirty не поднимает). |
| `probe_ms_yellow` | `'500'` | §236 | Test servers: верхняя граница «жёлтой» задержки, мс. |
| `probe_ms_orange` | `'700'` | §236 | Test servers: верхняя граница «оранжевой» задержки, мс; выше — красная. |
| `wifi_history` | `'[]'` | [§051] Phase 3 | JSON-encoded `[{ssid, bssid, last_seen}]` (см. отдельный раздел ниже). |
| `automation_receive_enabled` | `'false'` | §047 | Public Intent API: приём broadcast/Tasker. Default OFF. |
| `automation_emit_lifecycle` | `'false'` | §047 | Эмит lifecycle-событий наружу. Default OFF. |
| `automation_emit_state` | `'false'` | §047 | Эмит state-событий. Default OFF. |
| `automation_emit_subs` | `'false'` | §047 | Эмит событий подписок. Default OFF. |
| `automation_emit_health` | `'false'` | §047 | Эмит health-событий. Default OFF. |
| `automation_explainer_shown_v1` | `'false'` | §047 | One-shot: explainer-диалог автоматизации показан. |
| `subscription_user_agent` | — | identity headers | User-Agent для fetch подписок. |
| `subscription_send_hwid` | — | identity headers | Слать ли hwid-заголовки при fetch. |
| `subscription_hwid` | — | identity headers | HWID (потенциально идентифицирующий). |
| `subscription_device_os` | — | identity headers | OS-заголовок подписки. |
| `subscription_ver_os` | — | identity headers | Версия OS-заголовка. |
| `subscription_device_model` | — | identity headers | Модель устройства-заголовок. |
| `haptic_enabled` | `'true'` | §029 | Тактильный отклик UI. Живёт в `vars` (`HapticService.prefsKey`), НЕ в SharedPreferences. |
| `notif_perm_prompted_v1` | `'false'` | §128 | One-shot: промпт разрешения уведомлений показан. |
| `allow_rotation` | `'false'` | [§220] | Снятие портретной фиксации: `'true'` → пустой preferred-orientations (ориентацию решает системный auto-rotate). Default — жёсткий портрет. Toggle в App Settings → General → Behavior. |
| `resolve_enabled` | template | §263/§265 | Гейт route-resolve-правила пресета `traffic-processing`. Var секции `internal` (в VPN Settings не видна), редактируется в правиле через ref-var. Гасится on_change при вкл. FakeIP (§266). |
| `resolve_strategy` | template | §249/§265 | IP-версия route-resolve (`ipv4_only`/`prefer_ipv4`/…). Var секции `internal`, ref-var в `traffic-processing`. Пишется on_change тумблера IPv6. |
| `app_language` | `'system'` | §279 | Язык приложения: `system` \| `en` \| `ru`. **Единственный источник истины** — эта var; неизвестное значение (hand-edited бэкап) валидируется в `system`. НЕ config-var (не грязнит sing-box-конфиг). Все пути записи сходятся в `LocaleController` (picker, Debug API side-effect hook, restore, смена системного языка) — голого `setVar` нет by construction. Копии `boxvpn_boot.app_language` + `boxvpn_boot.last_pushed_locale` — **derived cache** для Dart-less нативных поверхностей (шторка/тайл/shortcuts при мёртвом Flutter); пере-пушатся `setAppLanguage` и `bootstrapAndSyncNativePrefs`. **Явно НЕ член `NativePrefsKeys`** (§189): членство продублировало бы настройку в `vpn_settings`-блоке бэкапа — единственный backup-дом = `vars` (guard-тест рядом с §221-сьютом). |
| `<custom>` | — | — | Любые юзерские template-vars, выставленные через UI / `PUT /settings/vars/<key>`. |

> Полный код-список app-флагов — `SettingsStorage._appFeatureFlagVars`; держать таблицу в синхроне с ним.

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
  "url":                   "https://…",       // online-подписка. §129: файловая
                                              // подписка → "file:<uuid>" (снапшот
                                              // нод в HttpCache по этому ключу;
                                              // не путь к файлу, доступ не хранится)
  "meta":                  { … }?,            // SubscriptionMeta — HTTP-headers
  "last_updated":          "ISO-8601"?,       // успех
  "last_update_attempt":   "ISO-8601"?,       // любая попытка
  "last_update_status":    "never|ok|failed|inProgress",
  "update_interval_hours": 24,                 // §129 спец-значения: -1 = никогда
                                               // (игнор серверного header, ставится
                                               // авто для file:-подписок), 0 = не по
                                               // расписанию, но серверный интервал
                                               // принимаем, N>0 = каждые N ч.
                                               // AutoUpdater пропускает interval ≤ 0.
  "last_node_count":       0,
  "consecutive_fails":     0,                 // для UI "(N fails)"; freezing — in-memory
  "disabled_hashes": {                        // §283 — per-node disable (опционален,
    "<sha256-hex>": "2026-07-18T10:00:00Z"    // пустой не пишется). Ключ = identity-хеш
  },                                          // сути ноды (emit − tag − detour, см.
                                              // services/node_hash.dart); значение =
                                              // lastSeen для TTL-GC (clamp(3×interval,
                                              // 24ч, месяц)) на успешном сетевом refresh.
  "identity": {                               // §289 — per-sub override идентичности фетча.
    "user_agent": "MyPanel/1.0",              // Опционален: null/отсутствует = режим Default
    "send_hwid": true,                        // (глобальный SubscriptionIdentity). Объект =
    "hwid": "550e8400-...",                   // режим Custom: фетч использует ТОЛЬКО эти
    "device_os": "android",                   // значения. Пустые строки (user_agent/hwid/
    "ver_os": "14",                           // device_*) не сериализуются. Включается копией
    "device_model": "Pixel 7"                 // глобальных; отбрасывается при возврате в Default.
  }
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

### `type: "folder"` — `FolderServers` (§234)

Папка ручных серверов: контейнер членов с общим toggle/`tag_prefix`/`detour_policy`.
Подписка в папку не кладётся; вложенности нет.

```jsonc
{
  "type":          "folder",
  "id":            "<uuid>",
  "name":          "<display>",
  "enabled":       true,                        // toggle всей папки
  "tag_prefix":    "<str>",
  "detour_policy": { … },
  "created_at":    "ISO-8601",
  "ping_url":         "<url>",                  // §284 — опц. override URL теста
  "ping_timeout_ms":  3000,                     // §284 — опц. override таймаута
  "members": [                                  // порядок = порядок в UI
    { "raw": "vless://…#Alpha", "enabled": true,
      "detour": "Jump" },                            // §237 — личный detour (опц.)
    { "raw": "wg://…#Beta",     "enabled": false }   // per-member toggle
  ]
}
```

`ping_url` / `ping_timeout_ms` (§284) — **опции теста самой папки**, перекрывают
глобальные `ping_options` при нажатии Test в папке. Отсутствуют → берётся
глобальное значение. Хранятся в объекте папки (едут в backup автоматически).
Папка «WARP GENERATOR» ставит сюда IP-URL (`1.1.1.1/cdn-cgi/trace`) — тест по IP
без DNS.

`raw` — самодостаточный парсируемый фрагмент (URI / WG-INI / outbound-JSON);
ноды реконструируются re-parse'ом каждого `raw` при загрузке (как `raw_body`
у user). `nodes` в памяти = только включённые члены — builder работает без
folder-ветвлений. Битый `raw` → член без ноды (виден в UI, правится/удаляется).

### `detour_policy` (общий)

```jsonc
{
  "register_detour_servers":  false,
  "register_detour_in_auto":  false,
  "use_detour_servers":       true,
  "override_detour":          "",              // '' = no override
  "replace_detour_chain":     false            // §178 — false=append override как tail, true=replace всей цепочки
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
  "dns":            { "enabled": true, "serverTag": "<dns-server tag>", "forceIpv4": true? }?,  // §117 задача 3 + §256
  "resolve":        { "only": false, "strategy": "ipv4_only", "serverTag": ""?,
                      "disableCache": true?, "disableOptimisticCache": true?,
                      "rewriteTtl": 60?, "timeout": "5s"?, "clientSubnet": "…"? }?  // §247
}
```

`name` — пользовательский, mutable.

OR-семантика внутри category, AND между. `protocols` и `ipIsPrivate` не headless'ятся, выносятся в routing-rule level.

`dns` ([§117] задача 3, «DNS follows the rule») — опционально: builder эмитит mirror DNS-rule `{rule_set: <тот же headless>, server: serverTag}` в атомарной mirror-группе (порядок = routing-правила). Отсутствует в старых записях → null → старое поведение. Гейт: при непустых `ports`/`protocols` mirror не эмитится.

`dns.forceIpv4` ([§256], Force IPv4) — опционально: гасит AAAA (IPv6) для матча правила serverless-правилом `{rule_set|match, ip_version: 6, action: predefined, rcode: NOERROR}` (приложение чисто берёт A). **Ортогонально** `enabled`/`serverTag` — глушилка отвечает локально, DNS-серверу не нужна: правило может нести только `forceIpv4` (`enabled: false`, `serverTag: ""`). Эмитится ПЕРЕД server-mirror'ом (порядок §253). Тот же port/protocol-гейт (DNS-слой слеп к порту/протоколу). Старые записи → false.

`resolve` ([§247]) — опционально: builder эмитит нетерминальное route-правило `{rule_set: <тот же headless>, action: resolve, …}` ПЕРЕД терминальным route (`only: false`, флагман — форс `ipv4_only` для direct-веток) либо ВМЕСТО него (`only: true`, advanced — fall-through). Отсутствует в старых записях → null. Гейт: у inline эмитится только при непустой domain-группе (`resolveEligible`); srs — всегда (домены в `.srs` возможны).

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
  "dns":         { "enabled": true, "serverTag": "<dns-server tag>", "forceIpv4": true? }?,  // §117 задача 3 + §256
  "resolve":     { "only": false, "strategy": "ipv4_only", … }?          // §247 (как у inline)
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

> **§265 — ref-var значения НЕ в `varsValues`.** Если пресет объявляет var как
> `{"ref":"<global>"}` (напр. `traffic-processing` → `resolve_enabled`/
> `resolve_strategy`), её значение живёт в **глобальном** `vars`
> (top-level, `setVar`/`getAllVars`), а НЕ в `varsValues` пресета — единый
> источник, чтобы правка в правиле и в секции-владельце не расходились.
> `varsValues` не должен содержать ref-имён; `stripRefVarsFromVarsValues`
> (`normalize_pinned_presets.dart`) вычищает застрявшие копии на загрузке Routing
> (иначе subtitle/Debug показывали устаревшее значение — `366beec`). См.
> TEMPLATE.md § «ref-vars».

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

⚠ §257: у записи `kind: preset` поле `enabled` — **мёртвое**: тумблер
DNS-блока пресета переехал в магическую var `dns_enable`
(`custom_rules[].varsValues`, см. TEMPLATE.md «Магические переменные»).
Запись остаётся только **позиционным якорем** mirror-группы (§117) —
определяет место DNS-правил пресета в `dns.rules`. Билдер и UI её
`enabled` не читают; auto-discovery продолжает писать `enabled: true`
(безвредно). Миграции нет — у всех пресетов с var DNS-блок после
обновления включён (default true), «кто надо — сам вырубит».

### Migration history

- v1.5.x: `dns_options.rules_json` — single JSON-string (`@Deprecated`). Сейчас игнорится; поле остаётся на диске для downgrade-friendliness.
- v1.6.0 ([§061]): `dns_options.rules[]` — структурированный список с `type`/`enabled`/`title`/`rule`.
- v1.6.0 ([§043][043-dns]): `dns_options.servers[]` — kind-refs впервые. Tag/description/enabled тогда жили в `body`.
- v1.6.1 ([§044]): `dns_options.servers[]` — clean schema. Tag/description/enabled подняты на ref-level. Underscore-аннотации (`_kind`, `_overrides`, `_origin`, `_preset_label`) удалены. Builder синтезирует tag в body. One-shot migration в `_migrateLegacyDnsServers`.
- v1.7.x ([§117]): template-серверы в шаблоне — обёртки `{description, enabled, vars?, server}`; ref-запись `kind: template` получила `varValues`. Миграции нет (не нужна): kind-ref'ы валидны как есть, удалённые из шаблона теги (`quad9_dot`, `adguard_dot`, `adguard_family`, `google_doh_vpn`) орфан-чистятся, vars применяют дефолты; inline-серверы юзера не трогаются.
- §228: ремап переименованных `preset_id` в `custom_rules` — `bittorrent-direct`→`bittorrent`, `private-ip-direct`→`private-ip`, `block_unknown`→`unknown-traffic` (сняли суффикс `-direct` т.к. outbound стал выбираемым + kebab-case). One-shot `_migrateRenamedPresetIds` (guard `preset_ids_remapped`), зовётся из `main.dart` до seed'а дефолтов. Переписывает ТОЛЬКО `presetId`; `varsValues` (выбранный юзером outbound) не трогается → выбор канала переживает ремап. Без миграции правила стали бы «Preset not found».

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
  "proxy_listen": "127.0.0.1",           // любой валидный IPv4; невалид → 127.0.0.1
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

**Builder** (§120). Императивный `applyVpnMode`/`post_steps/vpn_mode.dart` **удалён** — вся inbound-структура теперь декларативна в `wizard_template.json` (`tun-in`/`mixed-in`/route-rules гейтятся `#if`-конструкциями по `@vpn_mode`/`@proxy_*`). `build_config.dart` пробрасывает `VpnModeConfig` в плоские vars (`vpn_mode`, `proxy_port`, `proxy_listen`, `proxy_user`, `proxy_pass`, …) до substitution-фазы; `#if`-walker выбирает нужные inbound'ы и re-tag'ит resolve/sniff. К моменту `applyTunPackages` `inbounds[]` уже финальный.
- `proxy` → только `mixed-in` (без `tun-in`); `vpn_proxy` → `tun-in` + `mixed-in`.
- `mixed-in` = `{type:mixed, tag:mixed-in, listen, listen_port, users?}`.

**Auth.** `users:[{username,password}]` пишется только при `effectiveAuth && password != ""`. Для любого **не-loopback** listen (не `127.x` — `0.0.0.0` или конкретный LAN-IP) auth **форсится on** (снять нельзя — `effectiveAuth` игнорирует `proxy_auth_enabled`); на loopback — опционально. Пароль/username в §120 идут через vars-подстановку (secret-тип держит строку — числовой/«true»-пароль не искажается). Пароль генерится в UI при первом включении auth (`generateProxyPassword`, 32-hex, образец `clash_secret`).

**Смена режима меняет inbounds → full VPN restart** (наследуется от config-dirty машинерии: home banner Apply/Restart). `markConfigChangedNeedRestart()` дёргается при touch'е.

**Default для existing юзеров:** ключ отсутствует → `mode=vpn` (= текущее поведение, `#if`-ветка отдаёт tun-only). **Миграция не нужна** — отсутствие ключа эквивалентно дефолту.

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

**Секреты.** `priv_key`/`token` — реальные секреты в локальном файле приложения. В логах маскируются (`WarpAccount.redacted()`). ВНИМАНИЕ: `GET /state/storage` сериализатор `warp_account` сейчас **не** скрабит (см. [Debug API exposure](#debug-api-exposure) — заведён долг). При добавлении новых diag-дампов — не включать сырой `warp_account`.

**`reserved`.** `client_id` (base64, 3 байта) доносится до sing-box endpoint как per-peer `reserved: [b0,b1,b2]`. Без него WARP-handshake проходит, но трафик не идёт. Парсинг/emit — `parseReserved` (`uri_utils.dart`) + `WireguardPeer.reserved`.

CRUD: `getWarpAccount()` / `setWarpAccount(account?)` (null = очистить). См. [features/025](spec/features/025%20warp%20integration/spec.md).

---

## `masque_account` — [§130]

Кеш зарегистрированного MASQUE-WARP аккаунта (Cloudflare QUIC/CONNECT-IP транспорт, флагман v2.9.0). **Отдельный** от `warp_account`: другая крипта (ECDSA-ключи в DER) и другой транспорт. `MasqueAccount` (`services/warp/masque_account.dart`).

```jsonc
{
  "priv_key_der":  "<base64 DER — СЕКРЕТ, не логировать>",
  "server_pub_der":"<base64 DER peer public>",
  "client_v4":     "…",
  "client_v6":     "…",
  "server":        "162.159.198.1",       // data-plane endpoint IP
  "port":          443,
  "device_id":     "…",
  "token":         "<bearer — СЕКРЕТ, не логировать>",
  "created_at":    "<ISO8601>",
  "network":       "…",
  "sni":           "…",
  "idle_timeout":  "…",
  "keep_alive":    "…"
}
```

**Секреты.** `priv_key_der`/`token` — реальные секреты локального файла; в логах маскируются (`MasqueAccount.redacted()`).

**Не config-significant** — MASQUE-узел попадает в конфиг через обычный `UserServer` (`type:masque` из `MasqueSpec`), не отсюда; при записи `markConfigDirty` не дёргается.

CRUD: `getMasqueAccount()` / `setMasqueAccount(account?)` (null = очистить, `.remove('masque_account')`). Входит в backup-allowlist (`backup_service.dart`).

> **Долг кода (на момент правки дока):** `masque_account` присутствует в `backup_service`, но **отсутствовал** в `SettingsStorage.allowedTopLevelKeys` — при импорте бэкапа `replaceRaw` его отбрасывал. Также сериализатор `GET /state/storage` не скрабит секреты (см. [Debug API exposure](#debug-api-exposure)). Оба — заведены отдельными задачами.

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

JSON-зеркало Android-prefs, которые исторически жили **только** в native
`SharedPreferences` (`boxvpn_boot.*`). Реализация — `lib/services/settings_storage/native_prefs.dart`.

```jsonc
{
  "auto_start":        false,    // auto-start VPN на boot
  "keep_on_exit":      true,     // §188 — не глушить tun при swipe-kill (default ON)
  "background_mode":   "never",  // never | lazy | always — Doze-поведение туннеля
  "core_logs_enabled": false,    // forward sing-box-логов в Dart
  "allow_bypass":      false,    // §069 — Allow VPN bypass
  "auto_redirect":     false,    // auto-redirect
  "memory_limit":      "auto"    // §271 — лимит памяти ядра: auto | off | МБ строкой
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
`setNativeBackgroundMode` / `setNativeMemoryLimit` (§271: native применяет
лимит к работающему ядру немедленно через `Libbox.reloadSetupOptions`).
Прямые native-записи в обход этого слоя эфемерны:
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

> **`app_language` + `last_pushed_locale` ([§279]) — ещё два native-ключа НЕ в
> JSON-секции.** `boxvpn_boot.app_language` — derived cache var'а
> [`vars.app_language`](#vars--template-vars--app-flags) (источник истины —
> JSON-var, кэш пере-пушится `setAppLanguage` / `bootstrapAndSyncNativePrefs`);
> нужен нативным поверхностям (шторка/QS-тайл/shortcuts) при мёртвом Flutter.
> `boxvpn_boot.last_pushed_locale` — зеркало последнего значения, которое
> приложение само запушило в `LocaleManager` (Android 13+), опора трёхстороннего
> reconciliation «система против стораджа». Оба — документированное исключение
> из состава `NativePrefsKeys`: членство экспортировало бы их в
> `vpn_settings`-блок бэкапа вторым представлением одной настройки
> (backup-дом `app_language` — только `vars`).

---

## `channels` — [§125] каналы роутинга (template→storage)

Каналы (`vpn-1..vpn-10`) переехали из статичного `wizard_template.json`
(§267 — `group_templates` + `default_channels`; до §267 — `preset_groups[]`) в
storage. Template стал **seed'ом** — значениями по умолчанию на первом запуске.
После миграции состав каналов живёт в `channels[]` и редактируется юзером
(Routing → таб Channels → редактор канала).

- `tag` — **системный immutable** id (`vpn-1`..`vpn-10`), автогенерируется при
  создании (первый свободный `vpn-N`), юзер правит только `label`. Стабильный
  ключ ссылок (`route_final` / `ping_options` / custom-rule outbound / detour).
  §274 — префикс `⚙ ` в `label` зарезервирован как маркер detour-канала (как
  ⚙-метка в тегах detour-серверов): смена флага `detour` переименовывает канал
  (set → `⚙ <label>`, unset → префикс срезается), нормализация — в
  `Channel.copyWith`/`fromJson` (покрывает редактор, Debug API, restore).
- `vpn-1` — продуктово-привилегированный: всегда `enabled`, неудаляем, дефолт
  `route_final`. Лимит каналов — **10**.
- `auto` (nullable) — параметры urltest-двойника. `null` = галка auto ВЫКЛ,
  `<tag>-auto` не эмитится. `auto.tag` НЕ хранится (производный `${tag}-auto`).
  Полный shape: `{url, interval, tolerance, idle_timeout,
  interrupt_exist_connections, mode, balancer:{pool, pool_tolerance,
  sticky_hash[]}}`. §208-поля `mode` (`least_test` default | `round_robin`) и
  `balancer` (`pool` ≥1 default 3, `pool_tolerance` uint16 default 0,
  `sticky_hash[]` из `process/domain/source_ip/dest_ip/dest_port`, default
  `[process,domain]`, `[]` = липкость off) сериализуются в storage **всегда**,
  но в config ядра билдер эмитит `mode`+`balancer` **только** при `round_robin`
  (`balancer` без round-robin роняет старт ядра). Пустой `sticky_hash` уходит в
  конфиг как sentinel `["none"]` (выключенная липкость, контракт ядра SPEC 019).
- `detour` (bool, default `false` — отсутствие ключа читается как false,
  миграции нет; §248/§274) — **разрешение** выбирать канал как detour-мишень
  для серверов/папок/подписок (значение ссылки = `tag`; в пикере §239 —
  только каналы с флагом). Роль в правилах ортогональна: канал с флагом
  остаётся валидной целью `route_final` / custom-rule outbound (§274 снял
  взаимоисключение ролей и инвариант `detour ⇒ include_block=false`).
  Единственный инвариант: `vpn-1` не бывает detour (главный канал, дефолтная
  мишень и heal-резерв) — принуждается при чтении (`Channel.fromJson`),
  restore из backup и ручная правка файла его не обходят.
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
  `template.groupTemplates` (§267) — `default_channels[i].default_enabled` /
  legacy `enabled_groups[]` → `enabled` (vpn-1 форсим true); `channel.include ∋
  direct` → `include_direct`; `channel.include ∋ auto` → `auto` из auto-шаблона
  (`@urltest_*` vars); `default_filter=''`.
  Глобальный `✨auto`-preset **не** мигрируется (он больше не канал — каждый
  канал делает свой двойник). `enabled_groups[]` после миграции депрекейтится.
- **Деградация ссылок** (heal): канал перестал быть валидной мишенью данного
  рода → ссылки этого рода лечатся сразу в storage, **необратимо** (§202
  Решение B, расширено §248, скорректировано §274): rules-ссылки
  (`route_final` / custom-rule outbound) → `vpn-1` при удалении / выключении
  (установка detour-флага НЕ heal-триггер — §274: канал остаётся целью
  правил); detour-ссылки (`override_detour` / `members[].detour`) → `''`
  (None) при удалении / выключении / снятии detour-флага. Ссылка «на канал» = его `tag`
  ИЛИ `<tag>-auto`; значение, совпадающее с bare-тегом члена той же папки, —
  интра-ссылка, heal её не трогает. Restore из backup heal не ре-гоняет
  (принятые деградации — билдер схлопывает dangling при сборке). Legacy
  `✨auto`-ссылки попадают под то же правило. Подробно:
  [`spec/features/248 detour-channels/`](spec/features/248%20detour-channels/).
- CRUD: `getChannels` / `setChannels` / `addChannel` (throws при 10) /
  `updateChannel` / `deleteChannel` (throws для vpn-1) / `migrateChannelsIfNeeded`.
- ⚠ **Мутации — через `services/channel_mutations.dart`**, не напрямую (§275):
  `ChannelMutations.add/update/delete` делают storage-heal и зеркальный ресинк
  in-memory `_entries` контроллера одной операцией — иначе следующий `_persist()`
  воскрешает вылеченные detour-ссылки. `addChannel`/`updateChannel`/`deleteChannel`
  помечены `@visibleForTesting`: вызов из `lib/` мимо сервиса — ошибка analyze.
  `setChannels` — сырой bulk-overwrite без heal'а (для persist'а списка целиком).

Спеки: [`docs/spec/features/125 configurable-channels/`](spec/features/125%20configurable-channels/),
[`docs/spec/features/248 detour-channels/`](spec/features/248%20detour-channels/)
(detour-прослойка).

---

## Прочие top-level ключи

| Ключ | Тип | Назначение |
|---|---|---|
| `route_final` | `String` | Override `route.final` поверх template (выбранный default outbound). `''` = template-default. Dangling-ссылка (удалённый канал / legacy ✨auto) → `vpn-1` при сборке (§125). |
| `route_idle_suspend` | `String` | §215/§128 — idle-suspend threshold (`route.lx_idle_suspend`, kernel SPEC 020). Duration-строка (`'30s'`/`'5m'`), **default `'30s'`** (включено с v2.8.2), `''` = off (поле не эмитится в route). **Config-significant** (`markConfigDirty`). CRUD: `getIdleSuspend`/`saveIdleSuspend`. |
| `excluded_nodes` | `List<String>` | §125-cleanup **DEPRECATED** — глобальный node-filter (§048) удалён вместе с экраном. Ключ остаётся в allowlist (безвредный legacy-мусор); per-channel `node_filter` (§125) покрывает фильтрацию. |
| `enabled_groups` | `List<String>` | §125 **DEPRECATED** — заменён на `channels[]`. Читается только one-shot миграцией; на диске остаётся безвредным мусором. |
| `last_global_update` | `String` (ISO-8601) | Timestamp последнего успешного auto-refresh всех подписок. |
| `presets_migrated` | `bool` | §159 — guard «дефолтные пресеты засеяны» (fresh-install seed). Имя ключа историческое (бывшая legacy-миграция); переиспользован, чтобы ранее мигрировавшие юзеры не получили повторный seed. `RoutingScreen._seedDefaultPresets` ставит true. |
| `interrupt_connections_on_switch` | `bool` | §143 — рвать активные соединения переключаемой группы при смене ноды (default `false`, НЕ config-significant). См. `getInterruptOnSwitch`/`setInterruptOnSwitch`. |
| `node_sort_mode` | `String` | §100 — выбранный режим сортировки нод. `''` = template-default. CRUD: `getNodeSort`/`setNodeSort` (пишутся парой с `node_manual_order`). |
| `node_manual_order` | `List<String>` | §100 — ручной порядок node tags (актуален для режима manual). Пишется вместе с `node_sort_mode`. |
| `profiler_retention_sec` | `int` | §044 — окно хранения Live-журнала профайлера (rolling buffer), в секундах. Default `600` (10 мин), опции UI 60/600/3600, валидные `> 0`. **НЕ** config-significant. CRUD: `getProfilerRetentionSec`/`setProfilerRetentionSec`. |

> Отдельные структурные ключи описаны в собственных разделах выше: [`tun_apps`](#tun_apps--046), [`vpn_mode`](#vpn_mode--119), [`warp_account`](#warp_account--025), [`masque_account`](#masque_account--130). Это исчерпывающий список актуальных top-level ключей `lxbox_settings.json` (см. также §159 — реестр для allowlist-фильтра бэкапа: `SettingsStorage.allowedTopLevelKeys`).

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
| `boxvpn_boot.app_language` | `String` | Kotlin (зеркало `vars.app_language`) | [§279] | `system` \| `en` \| `ru`. Derived cache для Dart-less нативных поверхностей: `L10n.kt` оборачивает контекст в момент рендера (шторка/тайл/shortcuts при мёртвом Flutter). Истина — [`vars.app_language`](#vars--template-vars--app-flags); **НЕ** член `NativePrefsKeys`, **НЕ** в backup-блоке. |
| `boxvpn_boot.last_pushed_locale` | `String` | Kotlin | [§279] | Последнее значение, которое приложение само запушило в `LocaleManager` (Android 13+; `""` = system). Опора трёхстороннего reconciliation на старте: смена в системных Settings побеждает сторадж, смена стораджа (restore/Debug API) пере-пушится в `LocaleManager`. **НЕ** в backup-блоке. |

---

## Debug API exposure

`SettingsStorage.dumpCache()` возвращает deep-copy всего `_cache`. `GET /state/storage` ([§031]) использует через сериализатор `services/debug/serializers/storage.dart`, который работает по **denylist**-модели (всё видно, скрабятся только секреты — см. §159-callout ниже). Реально скрабятся:

- `vars.debug_token` → `'***'`
- `server_lists[].url` → маскируется (`maskSubscriptionUrl`)
- `server_lists[].nodes` → заменяется на `nodes_count` (могут нести credentials в UUID/password)
- `server_lists[].rawBody` → заменяется на `raw_body_bytes` (длина)
- `server_lists[].members` → заменяется на `members_count` (§234 — raw членов несёт credentials)

Скраббер обрабатывает только ключи `vars` и `server_lists`; всё остальное (`meta.*`, `warp_account`, `masque_account`, …) проходит **как есть** через `default`-ветку. Любое новое sensitive-поле нужно явно добавлять в `_scrub`.

> **Долг:** `warp_account`/`masque_account` (`priv_key`/`token`/`priv_key_der`) и `meta.support_url`/`meta.web_page_url` в `GET /state/storage` сейчас **не** скрабятся (вопреки обещанию раздела `warp_account`, что секреты маскируются в diag-снапшотах). Заведено отдельной задачей.

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
[§279]: ./spec/features/279%20localization/spec.md
[§220]: ./spec/tasks/220-allow-rotation-setting.md
[043-applog]: ./spec/features/043%20applog%20per-source%20quotas/spec.md
[043-dns]: ./spec/tasks/043-dns-servers-refs-by-kind.md
