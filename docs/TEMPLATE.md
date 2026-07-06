# Wizard Template

Полная схема `app/assets/wizard_template.json` — единственного **catalog'а** L×Box: какие preset'ы, DNS-серверы, ping-настройки, секции Wizard UI и ноды роутинга существуют в приложении out-of-the-box. Документ — источник правды для shape'а файла и vars-substitution syntax. `ARCHITECTURE.md` ссылается сюда.

## Что это

Файл `app/assets/wizard_template.json` bundled в APK через `flutter assets`. Загружается через `rootBundle.loadString` в `app/lib/services/template_loader.dart` (async singleton). Содержит **catalog** (что вообще существует), **defaults** (с какими значениями стартует новая установка) и **substitution shape** (нативная sing-box-секция с `@var`-плейсхолдерами).

В runtime билдер (`app/lib/services/builder/build_config.dart`) сливает:
- `config` (нативная sing-box-секция шаблона) +
- `selectable_rules[*]` (preset'ы выбранные юзером в `custom_rules`) +
- `dns_options.{servers,rules}` (текущее состояние storage) +
- `preset_groups` (selector/urltest группы с активными нодами) +
- `vars` substitution (template-vars из storage)

→ финальный `<docs>/singbox_config.json` для libbox.

`wizard_template.json` НЕ модифицируется юзером — это catalog. Юзерский state живёт в `lxbox_settings.json` (см. [`STORAGE.md`](./STORAGE.md)).

## `wizard_template.json` — full tree

> **Нотация**:
> - `object{N keys}` — объект с N ключами
> - `list[N]` — массив с N элементами; `list` без числа — массив переменной длины
> - `<TypeName>` — element-type для массива (показано отдельно ниже)
> - `?` после типа — поле опциональное
> - `"@varname"` — substitution-плейсхолдер; на build-time подставляется значение из `vars`

```
wizard_template.json
│
├─ parser_config                   object{2 keys}
│   ├─ version                     int           § схема parser-pipeline'а (§026)
│   └─ parser                      object{1 keys}
│       └─ reload                  duration      auto-refresh subscriptions interval (Go-style "12h")
│
├─ dns_options                     object{2 keys}       default DNS shape для билдера
│   ├─ servers[]                   list          template-level DNS servers (7 default'ов)
│   │   └─ <DnsServerRef>          object          обёртка §117 (tag живёт в server.tag):
│   │       ├─ description         string?       UI label
│   │       ├─ enabled             bool?         default true (default-enabled для auto-discovery)
│   │       ├─ vars[]              list?         те же определения, что preset-vars (§033)
│   │       └─ server              object          sing-box DNS server body + @placeholders:
│   │           ├─ type            "udp"|"https"|"tls"|"local"
│   │           ├─ tag             string        unique id для ссылки
│   │           ├─ server          string?       IP/host (udp/tls/h3)
│   │           ├─ server_port     int?
│   │           ├─ path            string?       (https) "/dns-query"
│   │           ├─ tls             object?         {enabled, server_name}
│   │           ├─ detour          tag?          через какой outbound резолвить
│   │           └─ domain_resolver tag?          какой DNS используется для host'а сервера
│   └─ rules[]                     list          template-level DNS rules (§061, бывший feature §041), сейчас пусто
│
├─ ping_options                    object{3 keys}       (§040)
│   ├─ url                         string        global default (e.g. gstatic.com/generate_204)
│   ├─ timeout_ms                  int           default 5000
│   └─ presets[]                   list          dropdown options в Ping Settings UI
│       └─ {name, url}             object
│
├─ speed_test_options              object{3 keys}       (§015)
│   ├─ servers[]                   list[10]      Cloudflare, Selectel, Hetzner, OVH, etc.
│   │   └─ {name, download_url, upload_url, upload_method, ping_url}
│   ├─ stream_options              list[3]       parallel-streams choices (e.g. [1,4,10])
│   └─ default_streams             int           default 4
│
├─ preset_groups[]                 list[3]       seed-группы (✨auto, vpn-1, vpn-2) → channels[] (§125)
│   └─ <PresetGroup>               object
│       ├─ tag                     string|@var   sing-box outbound tag (e.g. "vpn-1", "@auto_proxy_tag")
│       ├─ type                    "selector"|"urltest"
│       ├─ label                   string        UI display ("VPN ①")
│       ├─ default_enabled         bool          вкл в новой установке?
│       ├─ options                 object          sing-box selector/urltest options:
│       │   ├─ default             tag?          default selected
│       │   ├─ interrupt_exist_connections  bool?
│       │   ├─ url                 string?       (urltest) test endpoint
│       │   ├─ interval            duration?     (urltest) test period
│       │   └─ tolerance           int?          (urltest) ms
│       └─ add_outbounds[]         list[tag]     дополнительные tags для UI dropdown'а
│
├─ sections[]                      list[7]       Wizard UI chapters (§022)
│   └─ <Section>                   object
│       ├─ name                    string        "General", "DNS", "TUN", etc.
│       ├─ chapter                 string        grouping ("core"|"routing"|"dns")
│       ├─ description             string
│       └─ vars[]                  list          переменные секции
│           └─ <Var>               object
│               ├─ name            string        @имя для substitution
│               ├─ type            string        "text"|"int"|"bool"|"enum"|"secret"|"outbound"|"dns_servers"
│               ├─ default_value   any
│               ├─ required        bool?
│               ├─ options[]       list?         для enum: ["a","b"] или [{title,value}, ...]
│               ├─ wizard_ui       string?       "edit"|"fix"|"hidden"
│               ├─ title           string?       UI label
│               └─ tooltip         string?       help text
│
├─ config                          object{7 keys}       НАТИВНАЯ sing-box-секция; база финального config'а
│   ├─ log                         object{2 keys}
│   │   ├─ level                   "@log_level"
│   │   └─ timestamp               bool
│   ├─ dns                         object{4 keys}       пустой shell, заполняется builder'ом
│   │   ├─ servers[]               list          [] — заполняется из dns_options + selectable_rules
│   │   ├─ rules[]                 list          [] — то же
│   │   ├─ final                   "@dns_final"
│   │   └─ strategy                "@dns_strategy"
│   ├─ inbounds[]                  list[1]       tun definition
│   │   └─ <SingboxTunInbound>     object
│   │       ├─ type                "tun"
│   │       ├─ tag                 "tun-in"
│   │       ├─ interface_name      "@tun_name"
│   │       ├─ address             ["@tun_address", {#if @ipv6_enabled → "@tun_address6"}]  §227/§232 — v6 за галкой (дефолт OFF)
│   │       ├─ {#if @route_address_enable → route_address: ["0.0.0.0/1","128.0.0.0/1","::/1","8000::/1"]}  §232 — заворот v4+v6 opt-in (дефолт OFF → авто 0.0.0.0/0)
│   │       ├─ mtu                 "@tun_mtu"
│   │       ├─ auto_route          "@tun_auto_route"
│   │       ├─ strict_route        "@tun_strict_route"
│   │       └─ stack               "@tun_stack"
│   ├─ endpoints[]                 list          wireguard endpoints (заполняется из server_lists)
│   ├─ outbounds[]                 list[2]       base — direct-out + block; остальное добавляется builder'ом
│   │   ├─ {type:"direct", tag:"direct-out"}
│   │   └─ {type:"block",  tag:"block"}        §201 — drop-out, опция селектора канала + route_final (красный)
│   ├─ route                       object{5 keys}
│   │   ├─ find_process            bool          true → package_name detection включён
│   │   ├─ default_domain_resolver "@dns_default_domain_resolver"
│   │   ├─ rules[]                 list[3]       base routing rules
│   │   │   ├─ {action:"sniff",   inbound:"tun-in", timeout:"1s"}   §228 — sniff ПЕРЕД resolve (FakeIP)
│   │   │   ├─ {protocol:"dns",   action:"hijack-dns"}
│   │   │   └─ {action:"resolve", inbound:"tun-in", strategy:"@resolve_strategy"}
│   │   ├─ rule_set[]              list          (в шаблоне ключа НЕТ — создаётся билдером
│   │   │                                         из selectable_rules[].rule_set)
│   │   ├─ final                   tag           default selector ("vpn-1")
│   │   └─ auto_detect_interface   "@auto_detect_interface"
│   └─ experimental                object{1 keys}
│       └─ cache_file              object          {enabled:true, path:"cache.db"}
│                                                  (clash_api УДАЛЁН в §122 — блок в кастомном шаблоне
│                                                   роняет старт ядра: "clash api is not included in this build")
│
└─ selectable_rules[]              list[7]       КАТАЛОГ preset'ов
    └─ <Preset>                    object
        ├─ preset_id               string        id для ссылки из custom_rules (§030)
        ├─ label                   string        UI display
        ├─ description             string
        ├─ default                 bool?         вкл у новых юзеров?
        ├─ vars[]                  list?         переменные видимые когда preset enabled
        │                                        (тот же shape что sections[*].vars[*])
        ├─ rule_set[]              list?         sing-box rule-set definitions
        │   └─ <SingboxRuleSet>    object
        │       ├─ tag             string
        │       ├─ type            "inline"|"local"|"remote"
        │       ├─ format          "binary"|"source"?     (local/remote)
        │       ├─ rules[]         list?                  (inline) match-условия
        │       ├─ url             string?                (remote)
        │       ├─ download_detour tag?                   (remote) обычно "direct-out"
        │       └─ update_interval duration?              (remote) "168h"
        ├─ rule                    object?         single routing rule:
        │   └─ <SingboxRoutingRule>                {rule_set?, domain[]?, domain_suffix[]?,
        │                                           ip_cidr[]?, ip_is_private?, port[]?,
        │                                           package_name[]?, protocol[]?,
        │                                           outbound:"@var"?, action:"reject"?}
        ├─ dns_rule                object?         DNS-уровень rule, аналогично rule
        └─ dns_servers[]           list?         DNS servers видимые когда preset enabled
                                                 (ПЛОСКИЕ sing-box-тела, shape = внутренность
                                                  `dns_options.servers[*].server`, БЕЗ обёртки;
                                                  фильтруются по top-level `tag`)
```

Каждый ключ описан подробно в разделах ниже.

---

## Top-level (annotated)

```jsonc
{
  "parser_config":       { … },     // §026 parser version + reload interval
  "dns_options":         { … },     // §043+§044 (servers) + §061 (rules) — defaults
  "ping_options":        { … },     // §040 — ping/test URL + presets
  "speed_test_options":  { … },     // §015 — speed-test endpoints
  "preset_groups":       [ … ],     // selector/urltest группы (vpn-1, vpn-2, ✨auto)
  "sections":            [ … ],     // Wizard UI chapters (variables grouped by topic)
  "config":              { … },     // нативные sing-box секции (log/dns/inbounds/outbounds/route/...)
  "selectable_rules":    [ … ]      // §033 catalog of preset'ов
}
```

---

## `parser_config` — §026

```jsonc
{
  "version": 5,
  "parser":  { "reload": "12h" }
}
```

| Ключ | Тип | Назначение |
|---|---|---|
| `version` | int | Версия parser-pipeline'а ([§026]). Bump'ится на breaking-changes parser'а. |
| `parser.reload` | duration string | Periodic auto-refresh interval подписок ([§027]). Go-style: `12h`, `30m`, etc. Override per-subscription через `update_interval_hours` в `server_lists[]`. |

---

## `dns_options` — §043+§044 (servers) + §061 (rules)

Default DNS-конфигурация для новой установки. Stockpiled в storage `dns_options` при первом запуске; auto-discovery в [`resolveDnsServersList`] заполняет storage из template'а на каждый rebuild.

```jsonc
{
  "servers": [ <ServerRef>, … ],   // kind-refs (template-side: kind=template implicit)
  "rules":   [ <RuleRef>, … ]      // template-defined DNS rules (если есть)
}
```

### `dns_options.servers[i]` — DNS-сервер catalog entry (§117)

Обёртка `{description, enabled, vars?, server}` — `server` это sing-box body с
`@var`-плейсхолдерами, `vars` — те же определения, что у preset-vars (§033).
Tag живёт в `server.tag` (top-level `tag` больше нет — `templateDnsServerTag`).
Builder (`resolveTemplateDnsServerBody`) подставляет vars значениями юзера
(`varValues` из storage-ref'а) или `default_value`:

```jsonc
{
  "description": "Google DNS (direct)",
  "enabled":     true,               // default-enabled для auto-discovery
  "vars": [                          // optional (local_dns_resolver — без vars)
    {"name": "outbound", "type": "outbound", "default_value": "direct-out",
     "title": "Outbound", "tooltip": "Which channel carries DNS queries…"},
    {"name": "dns_ip", "type": "enum", "default_value": "8.8.8.8",
     "title": "UDP server IP", "options": [ {"title": "…", "value": "8.8.8.8"}, … ]}
  ],
  "server": {                        // sing-box DNS server body + @placeholders
    "type": "udp", "tag": "google_udp", "server_port": 53,
    "server": "@dns_ip",
    "detour": "@outbound"            // direct-out / пропавший канал → ключ стирается
  }
}
```

Конвенции (§117):

- `detour: "@outbound"` + var default `direct-out` → по умолчанию ключ
  **не пишется** (normalizeDnsDetour: `direct-out`, пустой и неизвестный
  builder'у канал → ключ стирается; «нет detour» = и дефолт, и fallback).
- Доменные серверы (адрес = hostname): `domain_resolver: "@dom_resolver"` +
  var `{type: dns_servers, default_value: "google_udp"}` — чем резолвить имя
  самого DNS-сервера.

7 default-серверов в текущем template'е:

| Tag | Type | Description |
|---|---|---|
| `local_dns_resolver` | local | System DNS (через Android getaddrinfo), без vars |
| `google_udp` | udp | 8.8.8.8:53 (`dns_ip` enum v4/v6) |
| `google_dot` | tls | 8.8.8.8:853 |
| `google_doh` | https | IP-based DoH, SNI пришпилен `dns.google` |
| `cloudflare_udp` | udp | 1.1.1.1:53 |
| `cloudflare_dot` | tls | 1.1.1.1:853 |
| `safe_dns_dot` | tls | Safe DNS: Quad9 / AdGuard / AdGuard Family (`safe_profile` enum) + `dom_resolver` |

### `dns_options.rules[]` — template DNS rules (опционально)

Currently empty. После [§039](./spec/tasks/039-empty-template-dns-rules.md) — намеренно пусто, юзер строит DNS-rules через preset'ы (`selectable_rules[*].dns_rule`). Если template хочет пушнуть default DNS-rule, она пойдёт сюда.

См. полный shape ref-уровня — [`STORAGE.md` § dns_options](./STORAGE.md#dns_options--§061-rules--§043043-dns--§044-servers).

---

## `ping_options` — §040

Default URL/timeout для ping/mass-URLTest. Storage может override через `ping_options` ([STORAGE.md §ping_options](./STORAGE.md#ping_options--§040)).

```jsonc
{
  "url":        "https://www.gstatic.com/generate_204",   // global default
  "timeout_ms": 5000,
  "presets": [
    {"name": "Google 204",   "url": "https://www.gstatic.com/generate_204"},
    {"name": "Cloudflare",   "url": "..."},
    …
  ]
}
```

| Ключ | Назначение |
|---|---|
| `url` | Default endpoint для ping. Юзер может override globally / per-group. |
| `timeout_ms` | Default timeout. Bump'ится для slow networks. |
| `presets[]` | Pre-configured options в Ping Settings UI dropdown — `{name, url}` пары. |

---

## `speed_test_options` — §015

Endpoints для speed-test screen. Не override'ится юзером (но юзер может переключить активный server).

```jsonc
{
  "servers": [
    {
      "name":          "Cloudflare",
      "download_url":  "https://speed.cloudflare.com/__down?bytes=25000000",
      "upload_url":    "https://speed.cloudflare.com/__up",
      "upload_method": "POST",
      "ping_url":      "https://speed.cloudflare.com/__down?bytes=0"
    },
    …
  ],
  "stream_options":  [1, 4, 10],   // parallel streams choices в UI
  "default_streams": 4
}
```

10 серверов в текущем template'е (Cloudflare, Selectel, Hetzner, OVH, etc.).

---

## `preset_groups[]` — selector/urltest группы

> **§125 — `preset_groups[]` стал SEED'ом, не source-of-truth.** Каналы
> переехали в storage (`channels[]`, см. [STORAGE.md](STORAGE.md#channels--125)).
> На первом запуске one-shot миграция засевает `channels[]` из `preset_groups[]`;
> дальше состав каналов живёт в storage и редактируется юзером. Билдер читает
> `channels[]`, а не `preset_groups[]`. Глобальный `✨auto`-preset больше **не**
> канал — каждый канал делает свой `<tag>-auto`-двойник через галку auto.
> Эта секция описывает структуру seed'а (что попадает в `channels[]` при первом
> запуске).
>
> **Маппинг seed `preset_groups[i]` → `channels[i]`** (one-shot миграция):
>
> | preset_groups | channels[] |
> |---|---|
> | `tag` | `tag` (vpn-1 форсится `enabled=true`) |
> | `label` | `label` (пусто → `tag`) |
> | `default_enabled` / legacy `enabled_groups[]` | `enabled` |
> | `add_outbounds` ∋ `direct-out` | `include_direct` |
> | `add_outbounds` ∋ ✨auto | `auto` (ChannelAuto из `@urltest_*` vars) |
> | `options.interrupt_exist_connections` | `interrupt_exist_connections` |
> | (не из template) | `node_filter`/`default_filter` = `''`; `include_block` = false |
>
> Глобальный `✨auto`-preset (urltest) сам каналом не становится — пропускается.

Catalog of routing-groups: какие selector'ы/urltest'ы создавать при assembly финального config'а. На каждый enabled группу builder добавляет sing-box outbound в `config.outbounds[]`.

```jsonc
[
  {
    "tag":             "@auto_proxy_tag",   // → "✨auto" (через vars-substitution)
    "type":            "urltest",
    "label":           "Include Auto",
    "default_enabled": true,
    "options": {
      "url":                          "@urltest_url",
      "interval":                     "@urltest_interval",
      "tolerance":                    "@urltest_tolerance",
      "interrupt_exist_connections":  true
    },
    "add_outbounds": []
  },
  {
    "tag":             "vpn-1",
    "type":            "selector",
    "label":           "VPN ①",
    "default_enabled": true,
    "options": {
      "default":                     "@auto_proxy_tag",     // by default vpn-1 → ✨auto
      "interrupt_exist_connections": true
    },
    "add_outbounds": [ "direct-out", "@auto_proxy_tag" ]    // что показать в selector UI помимо node tags
  },
  {"tag": "vpn-2", "type": "selector", "label": "VPN ②", "default_enabled": false,
   "options": {"default": "direct-out", …}, … }
]
```

В шаблоне только **3 seed-группы** (`✨auto`, `vpn-1`, `vpn-2`). Дальнейшие каналы (до `vpn-10`, `kMaxChannels = 10`) юзер создаёт сам в storage (`channels[]`), а не в шаблоне.

| Ключ | Тип | Назначение |
|---|---|---|
| `tag` | string | sing-box outbound tag. Может быть `@var`-плейсхолдером. |
| `type` | `"selector"` \| `"urltest"` | sing-box тип группы. |
| `label` | string | UI display name (Home → group dropdown). |
| `default_enabled` | bool | Влияет только на seed первого запуска (что засеять в `channels[]`). После миграции включённость живёт в `channels[].enabled`, редактируется в Routing → Channels. |
| `options` | object | Прокидывается в финальный sing-box config (selector/urltest options). |
| `add_outbounds[]` | list[string] | Дополнительные tags которые показываются в selector помимо node-tag'ов из `server_lists`. |

Storage source-of-truth: `channels[]` в `lxbox_settings.json` (§125). Legacy `enabled_groups[]` **DEPRECATED** — читается только one-shot миграцией в `channels[]` и как fallback-seed при пустом `channels[]` (см. [STORAGE.md](STORAGE.md#channels--125) и §125-callout выше).

---

## `sections[]` — Wizard UI chapters (§022)

Группировка template-vars в Wizard UI (App Settings → Configuration). Каждая секция — отдельная карточка/экран с inputs.

```jsonc
[
  {
    "name":        "General",
    "chapter":     "core",                  // grouping тэг (UI tabs)
    "description": "Logging and core settings",
    "vars": [
      {
        "name":          "log_level",
        "type":          "enum",
        "default_value": "warn",
        "options":       ["trace","debug","info","warn","error","fatal","panic"],
        "wizard_ui":     "edit",            // edit | hidden | fix
        "title":         "Log level",
        "tooltip":       "Verbosity of sing-box logs"
      },
      …
    ]
  },
  …
]
```

7 секций в текущем template'е: `General`, `Network`, `Auto Proxy`, `DNS`, `TUN`, `VPN Mode`, `DPI Bypass`. Расфасованы по 3 chapter'ам (`core`, `routing`, `dns`).

Секция `VPN Mode` — целиком `wizard_ui: hidden` (build-time vars, не показывается в UI). Её 7 переменных питают `#if`-гейтинг inbounds/route-rules (§119/§120), значения проставляются из `VpnModeConfig` на этапе сборки, а не редактируются юзером в Wizard:

| Var | Тип | Назначение |
|---|---|---|
| `vpn_mode` | enum | `vpn` / `proxy` / `vpn_proxy` — какие inbounds поднимать |
| `proxy_type` | enum | тип proxy-inbound (`mixed`/...) |
| `proxy_listen` | text | listen-адрес proxy |
| `proxy_port` | int | listen-порт proxy |
| `proxy_user` | text | имя пользователя (при auth) |
| `proxy_pass` | secret | пароль (при auth; `secret` — никогда не коэрсится) |
| `proxy_auth` | bool | включить `users[]` в proxy-inbound |

### `vars[i]` — описание template-переменной

| Ключ | Тип | Назначение |
|---|---|---|
| `name` | string | Имя переменной. `@name` в `config` блоке шаблона будет подставлено значением из storage `vars[name]` или `default_value`. |
| `type` | enum | Тип input'а — определяет UI-control и валидацию. См. ниже. |
| `default_value` | any | Default если юзер не override'нул через UI / `PUT /settings/vars/...`. |
| `required` | bool? | Если true — пустое значение запрещено. |
| `options[]` | list? | Для `enum` type'а — варианты. Может быть `[string,...]` или `[{title, value}, ...]`. |
| `wizard_ui` | `"edit" \| "fix" \| "hidden"`? | Display mode в Wizard UI. `hidden` — internal var (not shown). `fix` — read-only display. `edit` (default) — editable. |
| `title` | string? | Display label в UI. |
| `tooltip` | string? | Help-text при tap на info-иконку. |
| `on_change` | object? | §232 — декларативный side-effect при переключении var (см. раздел ниже). |

### `var.type` values

Заметил в template'е:

| Type | Coerce в config (§120) | UI-control |
|---|---|---|
| `text` | **строка дословно** | TextField |
| `int` | `int.tryParse` (не-число → строка) | TextField |
| `bool` | `'true'`→true, иначе false | Switch |
| `enum` | **строка** (∈ `options[]` — advisory) | Dropdown |
| `secret` | **строка дословно** (никогда не коэрсить) | TextField (masked) |
| `outbound` | **строка** (tag selector/node) | Dropdown заполняется runtime |
| `dns_servers` | **строка** (tag из `dns_options.servers`) | Dropdown заполняется runtime |

> **§120 — coerce по объявленному типу, НЕ по содержимому.** `if_engine.dart::coerceVarValue` коэрсит **только** `bool`/`int`, и только по `node.type`. Все строковые типы (`text`/`secret`/`enum`/`outbound`/`dns_servers`) остаются строкой, даже если значение выглядит как `123`/`true` — критично для паролей/секретов (`1234` не должен стать int). Var без объявленной ноды (legacy `clash_secret`, build-time `proxy_*`) → coerce как `text`.

При расширении (добавляешь новый type) — обновлять Wizard UI рендерер в `app/lib/screens/settings_screen.dart` и (если коэрсящийся) `coerceVarValue` в `app/lib/services/builder/if_engine.dart`.

### `on_change` — декларативный side-effect var'а (§232)

Переключение var может ставить производные var'ы. Синтаксис — на существующем
`#if` (value/else), условие видит УЖЕ НОВОЕ значение переключённой var:

```jsonc
{
  "name": "ipv6_enabled", "type": "bool", "default_value": "false",
  "on_change": {
    "set": {
      "@dns_strategy":     {"#if": {"and": ["@ipv6_enabled"], "value": "prefer_ipv4", "else": "ipv4_only"}},
      "@resolve_strategy": {"#if": {"and": ["@ipv6_enabled"], "value": "prefer_ipv4", "else": "ipv4_only"}}
    }
  }
}
```

Актуальная семантика тумблера IPv6 (§249): дефолт обеих strategy-vars —
`ipv4_only` (IPv6 на tun выключен по умолчанию — AAAA приложениям не нужен);
включение IPv6 переводит резолв в `prefer_ipv4` (v6 доступен, но v4-first —
`prefer_ipv6` на сетях с полурабочим v6 давал мёртвые direct-коннекты, см.
§246), выключение — форсит `ipv4_only`. Тонкая настройка — DNS Settings →
Strategy (тумблер — разовый эффект, не форс).

Семантика:

- **Разовый эффект переключения, не форс** — целевые var записываются в момент
  клика; юзер потом волен переопределить вручную.
- **Только in-memory** — цели пишутся в реактивную `VarValuesModel` экрана
  (per-key `ValueNotifier`; поля `TemplateVarListView` подписаны каждое на свой
  ключ и обновляются мгновенно). Storage трогается ТОЛЬКО общим write-on-exit
  (`_persist` по `dirtyKeys`) — юзер, ушедший до выхода с экрана (force-kill),
  ничего не «сохранил». См. ARCHITECTURE.md → «VarValuesModel».
- **Цепочки** — если целевая var сама имеет `on_change`, он применяется
  рекурсивно; fixpoint-guard: запись неизменившегося значения обрывает цикл.
- **Значения — литералы-строки.** `#if`-узел вычисляется движком через
  `evalIfScalar` (`if_engine.dart`) — НЕ через `walk` напрямую: bare-Map
  `{"#if":…}` в `walk` уходит в map-spread режим и схлопывает скаляр в `{}`.
- **Кросс-экранные цели** (напр. `dns_strategy` — chapter `dns`, рендерится на
  DNS Settings): live-обновления на другом экране НЕТ (модель — per-экран);
  значение доедет через cache при следующем открытии того экрана. Экраны не
  co-mounted → рассинхрон юзеру не виден.

---

## `config` — нативная sing-box-секция

База финального sing-box config'а. Содержит `@var`-плейсхолдеры — substitution происходит на build time. После расширения `selectable_rules[*]` и `preset_groups` мерджатся в эту базу.

```jsonc
{
  "log": {
    "level":     "@log_level",
    "timestamp": true
  },
  "dns": {
    "servers":  [],                              // пусто; заполняется из dns_options.servers + selectable_rules[].dns_servers
    "rules":    [],                              // пусто; заполняется из dns_options.rules + selectable_rules[].dns_rule
    "final":    "@dns_final",
    "strategy": "@dns_strategy"
  },
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "interface_name": "...", "address": "...", "mtu": ..., "auto_route": ..., "strict_route": ..., "stack": "..."}
  ],
  "endpoints": [],                               // wireguard endpoints (from server_lists user nodes)
  "outbounds": [
    {"type": "direct", "tag": "direct-out"},     // base
    {"type": "block",  "tag": "block"}           // §201 drop-out; остальное добавляется builder'ом
  ],
  "route": {
    "find_process":            true,
    "default_domain_resolver": "@dns_default_domain_resolver",
    "rules": [
      // §228: sniff ПЕРЕД resolve — sniff извлекает домен до того, как resolve
      // сработает; критично для FakeIP (resolve по фейк-IP 198.18.x.x бессмыслен).
      // sniff-правило обёрнуто в #if по @sniff_enabled (см. § #if ниже) — здесь
      // показано резолвнутым (true-ветка); при false элемент выпадает.
      {"action": "sniff",   "inbound": "tun-in", "timeout": "1s"},
      {"protocol": "dns", "action": "hijack-dns"},
      {"action": "resolve", "inbound": "tun-in", "strategy": "@resolve_strategy"}
    ],
    "final":                  "vpn-1",
    "auto_detect_interface":  "@auto_detect_interface"
  },
  "experimental": {
    // clash_api УДАЛЁН в §122 (CommandClient-миграция). Управление идёт через
    // libbox CommandClient, а не HTTP Clash API. Ядро собрано БЕЗ with_clash_api:
    // блок experimental.clash_api в кастомном шаблоне = ФАТАЛЬНЫЙ отказ старта
    // ("clash api is not included in this build"). Не добавлять.
    "cache_file": {"enabled": true, "path": "..."}
  }
}
```

Что builder добавляет в эту базу:
- `config.outbounds[+]` ← node-outbounds из enabled `server_lists[]`, плюс selectors/urltest из `preset_groups`
- `config.dns.servers[+]` ← `dns_options.servers[*]` (resolved через [§044]) + `selectable_rules[*].dns_servers[*]`
- `config.dns.rules[+]` ← `dns_options.rules[*]` ([§061]) + `selectable_rules[*].dns_rule`
- `config.route.rules[+]` ← `selectable_rules[*].rule` (после `selectable_rules[*]` enabled-проверки) + `custom_rules[*]` user routing rules
- `config.route.rule_set[+]` ← `selectable_rules[*].rule_set[*]` (см. § ниже)
- `config.inbounds[*]` + route-rules `inbound` ← **декларативны через `#if`** ([§120]): `tun-in` и `mixed-in` — array-element `#if` по `@vpn_mode` (`vpn`/`proxy`/`vpn_proxy`); `users` внутри `mixed-in` — map-spread `#if` по `@proxy_auth`. `applyVpnMode` удалён. Значения (`@proxy_type`/`@proxy_port`/`@proxy_pass`/…) пробрасываются в `vars` из `VpnModeConfig` на этапе сборки. Раньше `mixed-in` строился императивно, т.к. подстановка коэрсила тип по содержимому (пароль `1234`→int); §120 ввёл coerce **по объявленному `node.type`** (`secret`/`text` — всегда строка), что и сделало `mixed-in`-в-шаблоне безопасным. `inbound` в route-rules теперь `Listable[string]`-массив (`["tun-in"]`/`["mixed-in"]`/`["tun-in","mixed-in"]`) — тождественно скаляру для sing-box.

`config.route.rule_set[]` в template **сам по себе пуст** — все rule-set'ы регистрируются через preset'ы. Если бы хотелось всем юзерам всегда одно rule-set'а — пишем сюда.

---

## `selectable_rules[]` — catalog preset'ов (§033)

Каждый элемент — bundle, который юзер включает/выключает в Routing screen. При expansion преобразуется в N изменений в финальном `config.route.{rules,rule_set}` + опционально `config.dns.{rules,servers}`.

```jsonc
{
  "preset_id":   "<unique-id>",        // referenced from custom_rules[].presetId
  "label":       "<UI display>",
  "description": "<тултип>",
  "default":     <bool>?,              // default true → включён в новой установке
  "vars": [ <Var>, … ]?,                // vars видимые только при включении этого preset'а
  "rule_set": [ <SingboxRuleSet>, … ]?, // rule_set'ы которые должны быть зарегистрированы
  "rule":     <SingboxRoutingRule>?,    // routing rule — legacy single (Map)
  "rules":    [ <SingboxRoutingRule>, … ]?, // §246: массив routing rules (канонический ключ; побеждает `rule`)
  "dns_rule": <SingboxDnsRule>?,        // DNS-уровень routing rule
  "dns_servers": [ <FlatDnsServer>, … ]?  // ПЛОСКИЕ sing-box DNS-тела (не обёртка §117; top-level tag)
}
```

### Полевая матрица текущих 6 preset'ов

| `preset_id` | `default` | `vars` | `rule_set` | `rule` | `dns_rule` | `dns_servers` |
|---|---|---|---|---|---|---|
| `block-ads` | false | — | ✓ (remote ads-all) | ✓ (action: reject) | — | — |
| `ru-direct` | true | ✓ (outbound, dns_server, dns_ip, geoip_enabled, force_ipv4) | ✓ (inline `.ru` suffixes) | ✓ массив: `[resolve ipv4_only #if @force_ipv4, @outbound]` (§246) | ✓ (`@dns_server`) | ✓ (yandex_udp/doh/dot) |
| `fakeip` | false | ✓ (dns_server — **hidden**) | — | — | ✓ (`query_type: [A,AAAA]` → `@dns_server`) | ✓ (type `fakeip`, ranges 198.18/15 + fc00::/18) |
| `ru-inside` | (false) | ✓ (outbound, force_ipv4) | ✓ (remote ru-inside) | ✓ массив: `[resolve ipv4_only #if @force_ipv4, @outbound]` (§246) | — | — |
| `bittorrent` | true | ✓ (outbound) | — | ✓ (`protocol: bittorrent` → `@outbound`) | — | — |
| `private-ip` | (false) | ✓ (outbound) | — | ✓ (`ip_is_private` → `@outbound`) | — | — |
| `unknown-traffic` | false | ✓ (`outbound`=reject) | ✓ (inline `unknown-apps`, invert `package_name_regex: "^"`) | ✓ (`@outbound`) | — | — |

`unknown-traffic` — reject/direct для трафика в туннеле, не атрибутированного ни одному установленному приложению (фоновые/чужие процессы). Инлайн `rule_set` `unknown-apps` матчит «всё, что НЕ приложение» через `invert: true` + `package_name_regex: "^"`.

**Backstop `reject`→`action`.** У `unknown-traffic` var-дефолт `outbound: "reject"`, и `rule.outbound: "@outbound"`. `reject` в sing-box — это `action`, а НЕ outbound-tag: литерал `{outbound: "reject"}` валидатор реджектит как dangling ref → fatal, ядро не стартует. Поэтому `preset_expand.dart` БЕЗУСЛОВНО нормализует финальный результат: `outbound == "reject"` → снять `outbound`, поставить `action: "reject"`. Это инвариант билдера (контракт sing-box), а не забота автора шаблона — работает и когда юзер выбрал reject явно в пикере, и когда просто включил пресет с дефолтом.

**`fakeip` (§228)** — FakeIP-DNS: `dns_servers` даёт сервер `type: fakeip` (диапазоны 198.18.0.0/15 + fc00::/18), `dns_rule` заворачивает все `A`/`AAAA`-запросы на него. Приложение получает placeholder-IP мгновенно (0 latency, нет pre-tunnel DNS-утечки), реальный резолв доменов происходит внутри туннеля. **Порядок в каталоге критичен:** `fakeip` стоит ПОСЛЕ `ru-direct` — билдер сохраняет порядок пресетов в `dns.rules[]`, поэтому ru-dns-правило матчится раньше и русские домены резолвятся по-настоящему (иначе они ушли бы в fakeip и `geoip-ru` по фейк-IP не сматчил бы → RU-трафик через VPN). Сервер вливается через **hidden-var** `dns_server` (см. «Магические переменные» ниже — без неё сервер не эмитится). Персистентность фейк-маппинга между реконнектами — `experimental.cache_file.store_fakeip: true` в базовом config (не пресетом; статичный флаг). `dns.independent_cache` НЕ ставим — deprecated в sing-box 1.14.

### Магические переменные пресетов (§033, §228)

Имена preset-vars **не произвольны**: несколько имён имеют специальную семантику — билдер и UI смотрят на них по имени/типу, а не только подставляют `@name`. Пропуск нужной «магической» переменной приводит к тому, что часть пресета **молча не работает** (регрессия §228 с FakeIP — сервер не вливался, потому что не было var `dns_server`).

| Var (имя / тип) | Кто смотрит | Что делает | Пропустишь → |
|---|---|---|---|
| `dns_server` (`type: dns_servers`) | `preset_expand.dart` | **Селектор** какой из `dns_servers[]` пресета влить в `config.dns.servers`. Билдер эмитит РОВНО ОДИН сервер — тот, чей `tag == varsValues['dns_server']` (или `default_value`). `dns_rule.server` ссылается на него через `@dns_server`. | `dns_servers[]` **не вливается вообще** (цикл гейтится наличием этой var). `dns_rule` повиснет на несуществующий сервер → dangling → guard молча дропнет правило. Пресет ничего не делает для DNS. |
| `outbound` (`type: outbound`) | `preset_expand.dart` + Routing UI | Значение для `@outbound` в `rule`/`dns_servers.detour`. UI рисует outbound-picker в строке пресета (см. `hasOutboundAffordance`). Дефолт `"reject"` → backstop-нормализация в `action:reject`. | Нет var:outbound И нет `rule` → `hasOutboundAffordance == false` → outbound-picker в строке **не рисуется** (DNS-only пресет — роутить нечего, picker был бы мёртвым). Это корректно, а не баг. |

**Правила при добавлении пресета:**

1. **Пресет несёт `dns_servers[]`** → обязателен var `dns_server` (`type: dns_servers`, `default_value` = tag нужного сервера), а `dns_rule.server` = `@dns_server`. Иначе сервер не эмитится (§228). Если сервер один и выбирать не из чего (как у FakeIP) — пометь var **`wizard_ui: "hidden"`**: значение всё равно придёт из `default_value`, но мёртвый dropdown-из-одного-пункта в редакторе не рисуется. (Редактор `preset_params_tab.dart` фильтрует hidden-vars; sections тоже.)
2. **Пресет роутит трафик** (есть `rule` с `outbound`/`action` или var:outbound) → outbound-picker в строке появится автоматически. **DNS-only пресет** (только `dns_rule`, как FakeIP) → picker сам скрывается через `hasOutboundAffordance`.
3. `outbound`-var с дефолтом `reject` → билдер сам превратит `{outbound:reject}` в `{action:reject}` (backstop, см. `unknown-traffic` выше).

### `selectable_rules[*].rule_set[i]` — sing-box rule-set definition

```jsonc
{
  "tag":              "<string>",                // unique id внутри финального config.route.rule_set
  "type":             "inline" | "local" | "remote",
  "format":           "binary" | "source"?,       // для local/remote
  "rules":            [ … ]?,                      // для inline — список match-условий
  "url":              "https://..."?,              // для remote
  "path":             "<filesystem>"?,             // для local — путь к .srs (в финальном config ставит билдер)
  "download_detour":  "<outbound-tag>"?,           // декларативное поле каталога — стрипается билдером
  "update_interval":  "<duration>"?                // декларативное поле каталога — стрипается билдером
}
```

⚠ **sing-box сам НИЧЕГО не скачивает.** В финальный config `remote`-форма не попадает никогда: билдер (`preset_expand.dart`) подменяет `remote` → `{type: "local", path: <кэш>}` и стрипает `url`/`download_detour`/`update_interval`. Кэш = `<docs>/rule_sets/<id>.srs`, где `id` — `CustomRule.id` (UUID), а для пресетов — `cachedPathForPreset(presetId, tag)` (по id пресета/правила, НЕ по `tag`).

Скачивание — только вручную через кнопку **Download** в UI (`RuleSetDownloader`). Если кэша нет, rule_set пропускается с warning («download first») — sing-box не увидит remote-URL и не полезет в сеть. `download_detour`/`update_interval` в текущем pipeline не используются (декларативные поля каталога).

### `selectable_rules[*].rule` / `rules` — routing rule(s)

`rule` — Map (один rule, legacy); `rules` — **массив** (§246, канонический ключ; при обоих ключах побеждает `rules`). Каждый rule — sing-box routing rule с support'ом всех его полей:

```jsonc
{
  "rule_set":    "<tag>"?,
  "domain":      ["..."]?,
  "domain_suffix": ["..."]?,
  "domain_keyword": ["..."]?,
  "ip_cidr":     ["..."]?,
  "ip_is_private": <bool>?,
  "port":        [<int>, ...]?,
  "package_name": ["..."]?,
  "protocol":    [ "bittorrent" | "tls" | "http" | ... ]?,

  "outbound":    "<tag-or-@var>"?,    // куда роутить
  "action":      "reject" | "..."?     // shorthand вместо outbound
}
```

В template'е стандартный pattern: ссылка на `rule_set` + outbound. См. примеры в `selectable_rules[]` существующего template'а.

**Массивная форма (§246, ключ `rules`).** Пресет может эмитить несколько route-правил — порядок элементов сохраняется в финальном `config.route.rules`. Семантика expansion (`preset_expand.dart`):

- элемент с `action ∈ {resolve, sniff, route-options}` — **промежуточный** (non-terminal): outbound-override юзера и reject-backstop к нему НЕ применяются; его присутствие в конфиге контролируется `#if`-гейтом (§120, array-element form: false без `else` → элемент выпадает);
- остальные элементы — **терминальные**: override/backstop работают как для одиночного rule (к каждому);
- dangling-rule_set guard — поэлементный: битый элемент дропается с warning, остальные живут;
- substitute гоняется по массиву целиком (иначе array-element `#if` не сработал бы).

Мотивирующий пример — `ru-direct`: на устройствах без глобального IPv6 direct-трафик на AAAA-адреса умирает (`network is unreachable`), поэтому RU-домены резолвятся `ipv4_only`. Управляется bool-var `force_ipv4` (default `true`) — юзер может выключить, если у сети рабочий IPv6:

```jsonc
"rules": [
  {"#if": {"and": ["@force_ipv4"],
           "value": {"rule_set": ["ru-domains", "ru-services"],
                     "action": "resolve", "server": "@dns_server", "strategy": "ipv4_only"}}},
  {"rule_set": ["ru-domains", "ru-services", "geoip-ru"], "outbound": "@outbound"}
]
```

⚠ `server` в resolve-элементе ссылается на DNS-сервер, который эмитится **DNS-аспектом** пресета (галка DNS, §033/§121): при выключенном DNS-аспекте тег повиснет (dangling) → fatal у ядра. Использовать `server` в resolve только если пресет надёжно эмитит сервер, либо не указывать `server` вовсе (internal-резолв пойдёт через DNS-роутинг / `default_domain_resolver`).

Для UI outbound-picker'а дефолт берётся из **терминального** элемента (`SelectableRule.terminalRule` — последний не-промежуточный).

### `selectable_rules[*].dns_rule` / `dns_servers`

Аналогично routing rule, но для DNS pipeline. `dns_rule` — single object, направляющий matched-domains на DNS-сервер из `dns_servers[]` (или ссылку на основной `dns_options.servers[]` сервер по tag).

⚠ В отличие от `dns_options.servers[*]` (обёртка `{description, enabled, vars?, server}` §117), preset-`dns_servers[*]` — это **плоские sing-box-тела** (`{type, tag, detour, …}` без обёртки, tag на top-level). `preset_expand.dart` фильтрует их по top-level `s['tag']`. Пример из `ru-direct`: `{"type":"udp","tag":"yandex_udp","detour":"@outbound",…}`.

### `vars` substitution

Vars, объявленные в preset'е, **видны только когда preset enabled**. UI рендерит их в Routing → preset detail. При expansion `@varname` в `rule` / `dns_rule` / `dns_servers` подставляется текущим значением (`varsValues[name]` из `CustomRulePreset` storage entry, fallback на `default_value`).

Универсальный `outbound`-override (spec [§033] Expansion §5): если `varsValues['outbound']` задан непустой — заменяет любое template-решение (`@outbound`-substitution / hardcoded outbound / `action: reject`).

---

## Vars-substitution syntax

Везде в `config` блоке (и в expansion preset'ов) подставляется **только whole-string** value вида `"@varname"` (строка целиком начинается с `@`, имя = всё после `@`) из:
1. `lxbox_settings.json` `vars[varname]` (если override'нуто)
2. `default_value` соответствующего var в `sections[*].vars[*]` или `selectable_rules[*].vars[*]`

Inline-подстановка **не поддерживается**: `"prefix-@varname-suffix"` не строка-`@var`, поэтому остаётся литералом как есть (молча, без warning). А `"@varname-suffix"` будет искаться как var с именем `varname-suffix` — не тем, что ожидалось. Если var-имя не объявлено, плейсхолдер остаётся как есть (контракт `build_config`).

Результат **типизирован по объявленному `var.type`** (§120): `bool`/`int` коэрсятся `coerceVarValue`, строковые типы (`text`/`secret`/`enum`/`outbound`/`dns_servers`) — дословно. Сам шаблон использует и типизированные `@var`: `"@tun_mtu"` (int), `"@tun_auto_route"` (bool).

См. примеры:
- `"final": "@dns_final"` — подставится `cloudflare_udp` или то что юзер выбрал
- `"@auto_proxy_tag"` — подставится `✨auto`
- `"server": "@dns_ip"` (внутри ru-direct preset) — подставится IP выбранный в dropdown'е

См. реализацию в `app/lib/services/builder/build_config.dart` + `preset_expand.dart`. Общее ядро подстановки и `#if` — `app/lib/services/builder/if_engine.dart` (§120), используется обоими движками.

## `#if`-конструкт (§120)

Декларативная условность прямо в `config`/preset-телах. Резолвится в substitution-фазе (до post-steps). Дизайн заимствован у десктопного лаунчера (SPEC 067), подмножество v1.

```jsonc
"#if": {
  "and":   [<predicate>, ...],   // взаимоисключающе с or; все true
  "or":    [<predicate>, ...],   // хотя бы один true
  "value": <any JSON>,           // then-ветка (обязательно)
  "else":  <any JSON>            // else-ветка (опционально)
}
```

**Два режима:**
- **map-spread** — `#if` как ключ объекта: true → поля `value` (объект) мерджатся в родителя; false+else → поля `else`; false без else → ничего. Ключ `#if` снимается.
- **array-element** — `#if` как единственный ключ элемента массива: true → элемент = `value`; false+else → `else`; false без else → элемент выпадает.

**Предикаты:** `"@var"` (bool), `{"@var":"literal"}` (equality), `{"@var":"#notEmpty"/"#isEmpty"}`, `{"@var":{"#in":[...]}}` / `{"#notIn":[...]}` / `{"#matches":"re"}`, `{"#not":predicate}`.

**Naming:** `#` — конструкт/предикат; `@` — var-ref; bare — inner-ключи тела `#if`. Неизвестный `#*`-сиблинг **молча отбрасывается** (`if_engine.dart::_walkMap` делает `obj.remove(k)` без warning — forward-compat); неизвестный inner-ключ/предикат-оператор → ошибка (валидация на template-load).

Пример (§119 inbounds, см. `wizard_template.json`):
```jsonc
{"#if": {"and": [{"@vpn_mode": {"#in": ["proxy", "vpn_proxy"]}}], "value": {
  "type": "@proxy_type", "tag": "mixed-in", "listen_port": "@proxy_port",
  "#if": {"and": ["@proxy_auth"], "value": {
    "users": [{"username": "@proxy_user", "password": "@proxy_pass"}]
  }}
}}}
```

---

## Когда что ломается

### Добавляем новый top-level ключ

Update этого файла (раздел top-level + новый section per-key) + добавляем читалку в builder/loader. Проверяем что `template_loader.dart` парсит без ошибок (текущий парсер permissive — игнорирует unknown keys).

### Меняем shape preset'а / vars

Если breaking — bump `parser_config.version` (это сигнал для миграционного кода). Описать миграцию в [§026 parser v2 spec](./spec/features/026%20parser%20v2/spec.md) или новой спеке.

### Добавляем var с новым `type`

Update var.type таблицу в этом файле + добавить рендерер в `settings_screen.dart`.

### Меняем `config.route.rules` базовые правила

Может сломать routing для существующих юзеров — **проверять**: добавляется ли правило перед или после auto-discovery preset-rules. См. order matters в [§030].

---

## Связанные документы

- [`STORAGE.md`](./STORAGE.md) — user-state в `lxbox_settings.json` (то что меняется юзером, в т.ч. override template-vars и `custom_rules[].presetId` ссылки на этот catalog)
- [§058 config generator v1 (superseded)](./spec/tasks/058-config-generator-wizard-v1-superseded/spec.md) — substitution и expansion (бывший feature §005x, заменён §026)
- [§026 parser v2](./spec/features/026%20parser%20v2/spec.md) — `parser_config.version`
- [§033 preset bundles](./spec/features/033%20preset%20bundles/spec.md) — `selectable_rules[]` и expansion
- [§030 custom routing rules](./spec/features/030%20custom%20routing%20rules/spec.md) — `selectable_rules[*].rule` shape, order matters
- [§061 dns rules refactor](./spec/tasks/061-dns-rules-refactor/spec.md) — `dns_options.rules[]` (бывший feature §041)
- [§043 dns servers refs by kind](./spec/tasks/043-dns-servers-refs-by-kind.md) + [§044 clean schema](./spec/tasks/044-dns-servers-clean-schema.md) — `dns_options.servers[]` и template-vs-storage отношения
- [§040 per-group ping settings](./spec/tasks/040-per-group-ping-test-settings.md) — `ping_options`
- [§015 speed test](./spec/features/015%20speed%20test/spec.md) — `speed_test_options`
- [§022 app settings](./spec/features/022%20app%20settings/spec.md) — Wizard UI и `sections[]`
