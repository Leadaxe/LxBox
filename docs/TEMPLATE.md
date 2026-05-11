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
│   ├─ servers[]                   list          template-level DNS servers (10 default'ов)
│   │   └─ <SingboxDnsServer>      object          shape элемента:
│   │       ├─ type                "udp"|"https"|"tls"|"local"
│   │       ├─ tag                 string        unique id для ссылки
│   │       ├─ description         string?       UI label
│   │       ├─ enabled             bool?         default true
│   │       ├─ server              string?       IP/host (udp/tls/h3)
│   │       ├─ server_port         int?
│   │       ├─ path                string?       (https) "/dns-query"
│   │       ├─ tls                 object?         {enabled, server_name}
│   │       ├─ detour              tag?          через какой outbound резолвить
│   │       └─ domain_resolver     tag?          какой DNS используется для host'а сервера
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
├─ preset_groups[]                 list[4]       selector/urltest группы → config.outbounds[]
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
│               ├─ type            string        "text"|"bool"|"enum"|"secret"|"outbound"|"dns_servers"
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
│   │       ├─ address             "@tun_address"
│   │       ├─ mtu                 "@tun_mtu"
│   │       ├─ auto_route          "@tun_auto_route"
│   │       ├─ strict_route        "@tun_strict_route"
│   │       └─ stack               "@tun_stack"
│   ├─ endpoints[]                 list          wireguard endpoints (заполняется из server_lists)
│   ├─ outbounds[]                 list[1]       base — direct-out; остальное добавляется builder'ом
│   │   └─ {type:"direct", tag:"direct-out"}
│   ├─ route                       object{5 keys}
│   │   ├─ find_process            bool          true → package_name detection включён
│   │   ├─ default_domain_resolver "@dns_default_domain_resolver"
│   │   ├─ rules[]                 list[3]       base routing rules
│   │   │   ├─ {action:"resolve", inbound:"tun-in", strategy:"@resolve_strategy"}
│   │   │   ├─ {action:"sniff",   inbound:"tun-in", timeout:"1s"}
│   │   │   └─ {protocol:"dns",   action:"hijack-dns"}
│   │   ├─ rule_set[]              list          [] — заполняется из selectable_rules[].rule_set
│   │   ├─ final                   tag           default selector ("vpn-1")
│   │   └─ auto_detect_interface   "@auto_detect_interface"
│   └─ experimental                object{2 keys}
│       ├─ clash_api               object          {external_controller:"@clash_api", secret:"@clash_secret"}
│       └─ cache_file              object          {enabled:true, path:"cache.db"}
│
└─ selectable_rules[]              list[5]       КАТАЛОГ preset'ов
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
                                                 (тот же shape что dns_options.servers[*])
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

### `dns_options.servers[i]` — DNS-сервер catalog entry

В template **shape sing-box-сервера напрямую** — без `kind`/`enabled` ref-обёртки. Builder при resolve конвертирует в `kind: template` ref-форму на ходу. Поля:

```jsonc
{
  "type":        "udp" | "https" | "tls" | "local" | "h3",
  "tag":         "<string>",         // unique id, ссылается из dns.final / dns.rules / vars dns_server type
  "description": "<string>"?,         // показывается в UI
  "enabled":     <bool>?,             // default true; false = в catalog'е есть, но пользователю не показываем
  "server":      "<ip|host>"?,        // для udp/tls/h3
  "server_port": <int>?,
  "path":        "<string>"?,         // для https
  "tls":         { "enabled": true, "server_name": "..." }?,  // для https/tls/h3
  "detour":      "<outbound-tag>"?,   // через какой outbound резолвить (e.g. yandex_udp через ru-direct VPN)
  "domain_resolver": "<tag>"?         // для https/tls — каким DNS резолвить host'а сервера (chicken-egg)
}
```

10 default-серверов в текущем template'е:

| Tag | Type | Description |
|---|---|---|
| `local_dns_resolver` | local | System DNS (через Android getaddrinfo) |
| `google_udp` | udp | 8.8.8.8:53 |
| `cloudflare_udp` | udp | 1.1.1.1:53 |
| `google_doh` | https | dns.google/dns-query |
| `cloudflare_dot` | tls | 1.1.1.1:853 |
| `google_dot` | tls | dns.google:853 |
| `quad9_dot` | tls | dns.quad9.net:853 |
| `adguard_dot` | tls | DNS AdGuard |
| `adguard_family` | tls | DNS AdGuard Family (ad+adult block) |
| `google_doh_vpn` | https | Google DoH через bypass-VPN — для случая когда плоский DoH блокируется |

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
  {"tag": "vpn-2", "type": "selector", "label": "VPN ②", "default_enabled": false, … },
  {"tag": "vpn-3", "type": "selector", "label": "VPN ③", "default_enabled": false, … }
]
```

| Ключ | Тип | Назначение |
|---|---|---|
| `tag` | string | sing-box outbound tag. Может быть `@var`-плейсхолдером. |
| `type` | `"selector"` \| `"urltest"` | sing-box тип группы. |
| `label` | string | UI display name (Home → group dropdown). |
| `default_enabled` | bool | Включена в новой установке? Юзер может toggle через App Settings → Auto Proxy. |
| `options` | object | Прокидывается в финальный sing-box config (selector/urltest options). |
| `add_outbounds[]` | list[string] | Дополнительные tags которые показываются в selector помимо node-tag'ов из `server_lists`. |

Storage override: `enabled_groups` в `lxbox_settings.json` контролирует кто реально включён.

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

7 секций в текущем template'е: `General`, `Clash API`, `Network`, `Auto Proxy`, `DNS`, `TUN`, `DPI Bypass`. Расфасованы по 3 chapter'ам (`core`, `routing`, `dns`).

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

### `var.type` values

Заметил в template'е:

| Type | Что | UI-control |
|---|---|---|
| `text` | произвольная строка | TextField |
| `bool` | true/false | Switch |
| `enum` | выбор из `options[]` | Dropdown |
| `secret` | password / token | TextField (masked) |
| `outbound` | tag из доступных outbound'ов (selector/node tag) | Dropdown заполняется runtime |
| `dns_servers` | tag из `dns_options.servers` | Dropdown заполняется runtime |

При расширении (добавляешь новый type) — обновлять Wizard UI рендерер в `app/lib/screens/settings_screen.dart`.

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
    {"type": "direct", "tag": "direct-out"}      // base; остальное добавляется builder'ом
  ],
  "route": {
    "find_process":            true,
    "default_domain_resolver": "@dns_default_domain_resolver",
    "rules": [
      {"action": "resolve", "inbound": "tun-in", "strategy": "@resolve_strategy"},
      {"action": "sniff",   "inbound": "tun-in", "timeout": "1s"},
      {"protocol": "dns", "action": "hijack-dns"}
    ],
    "final":                  "vpn-1",
    "auto_detect_interface":  "@auto_detect_interface"
  },
  "experimental": {
    "clash_api":  {"external_controller": "...", "secret": "..."},
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
  "rule":     <SingboxRoutingRule>?,    // routing rule (single)
  "dns_rule": <SingboxDnsRule>?,        // DNS-уровень routing rule
  "dns_servers": [ <SingboxDnsServer>, … ]?  // DNS-серверы которые должны существовать когда preset enabled
}
```

### Полевая матрица текущих 5 preset'ов

| `preset_id` | `default` | `vars` | `rule_set` | `rule` | `dns_rule` | `dns_servers` |
|---|---|---|---|---|---|---|
| `block-ads` | false | — | ✓ (remote ads-all) | ✓ (action: reject) | — | — |
| `ru-direct` | true | ✓ (outbound, dns_server, dns_ip) | ✓ (inline `.ru` suffixes) | ✓ (`@outbound`) | ✓ (`@dns_server`) | ✓ (yandex_udp/doh/dot) |
| `ru-inside` | (false) | — | ✓ (remote ru-inside) | ✓ | — | — |
| `bittorrent-direct` | true | — | — | ✓ (`protocol: bittorrent`) | — | — |
| `private-ip-direct` | (false) | — | — | ✓ (`ip_is_private`) | — | — |

### `selectable_rules[*].rule_set[i]` — sing-box rule-set definition

```jsonc
{
  "tag":              "<string>",                // unique id внутри финального config.route.rule_set
  "type":             "inline" | "local" | "remote",
  "format":           "binary" | "source"?,       // для local/remote
  "rules":            [ … ]?,                      // для inline — список match-условий
  "url":              "https://..."?,              // для remote
  "path":             "<filesystem>"?,             // для local — обычно sing-box runtime ставит автоматически после download'а .srs
  "download_detour":  "<outbound-tag>"?,           // для remote — через что качать .srs (default: direct-out)
  "update_interval":  "<duration>"?                // для remote — period auto-update (e.g. "168h")
}
```

`download_detour` обычно = `direct-out` чтобы bootstrap'ить .srs до того как VPN поднимется.

`update_interval` — sing-box сам fetch'ит обновления .srs с этой периодичностью; кэш в `<docs>/rule_sets/<tag>.srs`.

### `selectable_rules[*].rule` — routing rule

Single object (НЕ массив) — sing-box routing rule с support'ом всех его полей:

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

### `selectable_rules[*].dns_rule` / `dns_servers`

Аналогично routing rule, но для DNS pipeline. `dns_rule` — single object, направляющий matched-domains на DNS-сервер из `dns_servers[]` (или ссылку на основной `dns_options.servers[]` сервер по tag).

### `vars` substitution

Vars, объявленные в preset'е, **видны только когда preset enabled**. UI рендерит их в Routing → preset detail. При expansion `@varname` в `rule` / `dns_rule` / `dns_servers` подставляется текущим значением (`varsValues[name]` из `CustomRulePreset` storage entry, fallback на `default_value`).

Универсальный `outbound`-override (spec [§033] Expansion §5): если `varsValues['outbound']` задан непустой — заменяет любое template-решение (`@outbound`-substitution / hardcoded outbound / `action: reject`).

---

## Vars-substitution syntax

Везде в `config` блоке (и в expansion preset'ов) value-строка вида `"@varname"` или с inline-substitution `"prefix-@varname-suffix"` подставляется из:
1. `lxbox_settings.json` `vars[varname]` (если override'нуто)
2. `default_value` соответствующего var в `sections[*].vars[*]` или `selectable_rules[*].vars[*]`

Только string-подстановка. Для `bool`/`int` template обычно содержит конкретный default, не `@var`.

См. примеры:
- `"final": "@dns_final"` — подставится `cloudflare_udp` или то что юзер выбрал
- `"@auto_proxy_tag"` — подставится `✨auto`
- `"server": "@dns_ip"` (внутри ru-direct preset) — подставится IP выбранный в dropdown'е

См. реализацию в `app/lib/services/builder/build_config.dart` + `expand_preset.dart`.

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
