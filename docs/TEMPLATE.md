# Wizard Template

Полная схема `app/assets/wizard_template.json` — единственного **catalog'а** L×Box: какие preset'ы, DNS-серверы, ping-настройки, секции Wizard UI и ноды роутинга существуют в приложении out-of-the-box. Документ — источник правды для shape'а файла и vars-substitution syntax. `ARCHITECTURE.md` ссылается сюда.

## Что это

Файл `app/assets/wizard_template.json` bundled в APK через `flutter assets`. Загружается через `rootBundle.loadString` в `app/lib/services/template_loader.dart` (async singleton). Содержит **catalog** (что вообще существует), **defaults** (с какими значениями стартует новая установка) и **substitution shape** (нативная sing-box-секция с `@var`-плейсхолдерами).

В runtime билдер (`app/lib/services/builder/build_config.dart`) сливает:
- `config` (нативная sing-box-секция шаблона) +
- `selectable_rules[*]` (preset'ы выбранные юзером в `custom_rules`) +
- `dns_options.{servers,rules}` (текущее состояние storage) +
- `group_templates` + `default_channels` (шаблоны сборки каналов, §267) +
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
│       └─ {id, name, url}         object        id — stable machine-id (§279)
│
├─ speed_test_options              object{3 keys}       (§015)
│   ├─ servers[]                   list[10]      Cloudflare, Selectel, Hetzner, OVH, etc.
│   │   └─ {id, name, download_url, upload_url, upload_method, ping_url}
│   ├─ stream_options              list[3]       parallel-streams choices (e.g. [1,4,10])
│   └─ default_streams             int           default 4
│
├─ group_templates                 object        шаблоны сборки каналов (§267)
│   ├─ magic_nodes                  object        реестр служебных нод по role-ключу
│   │   └─ <role>                   object        role ∈ {auto, direct, block}
│   │       ├─ title                string        UI-label ("Auto"/"Direct"/"Block")
│   │       ├─ source               "generate"|"preset"  как рождается нода
│   │       ├─ tag                  string?       (preset) ссылка на config.outbounds
│   │       └─ tpl                  string?       (generate) шаблон тега ("{parent_tag}-auto")
│   ├─ channel                      object        шаблон обычного канала (selector)
│   │   ├─ type                     "selector"
│   │   ├─ include[]                list[role]    role-ключи magic_nodes (["direct","auto"])
│   │   └─ options                  object          sing-box selector options (interrupt_exist_connections)
│   └─ auto                         object        шаблон auto-подгруппы (urltest)
│       ├─ type                     "urltest"
│       └─ options                  object          url / interval / tolerance (сырые @var)
│
├─ default_channels[]               list          сид каналов первого запуска (§267)
│   └─ <DefaultChannel>             object
│       ├─ tag                      string        "vpn-1".."vpn-10"
│       ├─ label                    string        UI display ("VPN ①")
│       └─ default_enabled          bool          вкл в новой установке?
│
├─ sections[]                      list[8]       Wizard UI chapters (§022)
│   └─ <Section>                   object
│       ├─ id                      string        stable machine-id, kebab-case (§279: "general", "auto-proxy", …)
│       ├─ name                    string        "General", "DNS", "TUN", etc. — внутренний join-ключ vars↔section
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
│   │   ├─ rules[]                 list[0]       [] — §264: sniff/hijack-dns/resolve
│   │   │                                         ПЕРЕЕХАЛИ в locked-пресет traffic-processing
│   │   │                                         (pinned:0 → первые в route.rules).
│   │   │                                         В шаблоне route.rules пуст.
│   │   ├─ rule_set[]              list          (в шаблоне ключа НЕТ — создаётся билдером
│   │   │                                         из selectable_rules[].rule_set)
│   │   ├─ final                   tag           default selector ("vpn-1")
│   │   └─ auto_detect_interface   "@auto_detect_interface"
│   └─ experimental                object{1 keys}
│       └─ cache_file              object          {enabled:true, path:"cache.db"}
│                                                  (clash_api УДАЛЁН в §122 — блок в кастомном шаблоне
│                                                   роняет старт ядра: "clash api is not included in this build")
│
└─ selectable_rules[]              list[8]       КАТАЛОГ preset'ов
    └─ <Preset>                    object
        ├─ preset_id               string        id для ссылки из custom_rules (§030)
        ├─ ui                      object          §264 — метаданные пресета (плоские
        │   ├─ label               string        UI display                label/description/
        │   ├─ description         string        тултип                     default УБРАНЫ,
        │   ├─ default             bool?         вкл у новых юзеров?         fallback СНЯТ):
        │   ├─ locked              bool?         §264 — нельзя выкл/удалить/двигать
        │   └─ pinned              int?          §264 — фикс-позиция в списке и route.rules
        ├─ vars[]                  list?         переменные видимые когда preset enabled
        │                                        (тот же shape что sections[*].vars[*];
        │                                         §265: элемент может быть {"ref":"<global>"})
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
        ├─ dns_rule                object?         DNS-уровень rule — legacy single (Map)
        ├─ dns_rules               list?           §253: массив DNS-rules (канонический
        │                                          ключ; побеждает `dns_rule`)
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
  "group_templates":     { … },     // §267 — magic_nodes реестр + channel/auto шаблоны
  "default_channels":    [ … ],     // §267 — сид каналов первого запуска (vpn-1, vpn-2)
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

Currently empty. После [§039](./spec/tasks/039-empty-template-dns-rules.md) — намеренно пусто, юзер строит DNS-rules через preset'ы (`selectable_rules[*].dns_rules`). Если template хочет пушнуть default DNS-rule, она пойдёт сюда.

См. полный shape ref-уровня — [`STORAGE.md` § dns_options](./STORAGE.md#dns_options--§061-rules--§043043-dns--§044-servers).

---

## `ping_options` — §040

Default URL/timeout для ping/mass-URLTest. Storage может override через `ping_options` ([STORAGE.md §ping_options](./STORAGE.md#ping_options--§040)).

```jsonc
{
  "url":        "https://www.gstatic.com/generate_204",   // global default
  "timeout_ms": 5000,
  "presets": [
    {"id": "google-204", "name": "Google 204",   "url": "https://www.gstatic.com/generate_204"},
    {"id": "cloudflare", "name": "Cloudflare",   "url": "..."},
    …
  ]
}
```

| Ключ | Назначение |
|---|---|
| `url` | Default endpoint для ping. Юзер может override globally / per-group. |
| `timeout_ms` | Default timeout. Bump'ится для slow networks. |
| `presets[]` | Pre-configured options в Ping Settings UI dropdown — `{id, name, url}`. `id` — стабильный machine-id (§279, адрес для l10n); display-поле — `name`. |

---

## `speed_test_options` — §015

Endpoints для speed-test screen. Не override'ится юзером (но юзер может переключить активный server).

```jsonc
{
  "servers": [
    {
      "id":            "cloudflare",
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
`id` — стабильный machine-id (§279): runtime-выбор сервера на speed-test-экране
ключуется по нему (не по индексу); неизвестный id → default (первый сервер).

---

## `group_templates` + `default_channels` — шаблоны сборки каналов (§267)

> **§125/§267 — каналы живут в storage, шаблон только сеет.** Каналы переехали
> в storage (`channels[]`, см. [STORAGE.md](STORAGE.md#channels--125)). На первом
> запуске one-shot миграция засевает `channels[]` из `default_channels` +
> `group_templates.channel`; дальше состав каналов живёт в storage и редактируется
> юзером. Билдер читает `channels[]`, а не шаблон. `auto` — не канал, а
> подгруппа: каждый канал делает свой `<tag>-auto`-двойник (urltest), когда
> `channel.include ∋ auto`.
>
> **§267 заменил плоский `preset_groups[]`** (три разнородные записи + фейковая
> переменная `@auto_proxy_tag`) на три части:
> - `magic_nodes` — реестр служебных нод (auto/direct/block) по role-ключу;
> - `channel`/`auto` — шаблоны сборки канала и его urltest-подгруппы;
> - `default_channels` — плоский список каналов для сида.
>
> **Маппинг seed → `channels[i]`** (one-shot миграция):
>
> | шаблон | channels[] |
> |---|---|
> | `default_channels[i].tag` | `tag` (vpn-1 форсится `enabled=true`) |
> | `default_channels[i].label` | `label` (пусто → `tag`) |
> | `default_channels[i].default_enabled` / legacy `enabled_groups[]` | `enabled` |
> | `channel.include` ∋ `direct` | `include_direct` |
> | `channel.include` ∋ `auto` | `auto` (ChannelAuto из `auto`-шаблона + `@urltest_*` vars) |
> | `channel.include` ∋ `block` | `include_block` (в дефолте нет → false) |
> | `channel.options.interrupt_exist_connections` | `interrupt_exist_connections` |
> | (не из template) | `node_filter`/`default_filter` = `''` |
>
> Все каналы собираются из **общего** `channel`-шаблона (единый `include`);
> различаются только `tag`/`label`/`default_enabled` из `default_channels`.

### `magic_nodes` — реестр служебных нод

Служебные ноды (auto/direct/block) объявлены по role-ключу. `magic_nodes.*.tag` —
source of truth для тегов; const-зеркала `kAuto/Direct/BlockOutboundTag` в
`consts.dart` сверяются с ним на load (`assertMagicNodeMirrors` — расхождение =
`StateError`, чтобы переименование tag в шаблоне не ломало роутинг молча).

```jsonc
"magic_nodes": {
  "auto":   { "title": "Auto",   "source": "generate", "tpl": "{parent_tag}-auto" },
  "direct": { "title": "Direct", "source": "preset",   "tag": "direct-out" },
  "block":  { "title": "Block",  "source": "preset",   "tag": "block" }
}
```

| Ключ | Тип | Назначение |
|---|---|---|
| `title` | string | UI-label служебной ноды (Home → node display). |
| `source` | `"generate"` \| `"preset"` | Как рождается нода: `generate` — билдер синтезирует per-channel (urltest, статического тега нет); `preset` — готовый объект уже в `config.outbounds`. |
| `tag` | string? | (preset) ссылка на существующий outbound в `config.outbounds`. У `generate` отсутствует. |
| `tpl` | string? | (generate) шаблон тега синтезируемой ноды. `{parent_tag}` → tag родительского канала (`vpn-1` → `vpn-1-auto`). У `preset` отсутствует. |

### `channel` — шаблон обычного канала (selector)

```jsonc
"channel": {
  "type": "selector",
  "include": ["direct", "auto"],   // role-ключи magic_nodes, показываемые в selector
  "options": { "interrupt_exist_connections": true }
}
```

`include` — role-ключи `magic_nodes` (не теги!). `block` в дефолт не входит.

### `auto` — шаблон auto-подгруппы (urltest)

```jsonc
"auto": {
  "type": "urltest",
  "options": {
    "url":       "@urltest_url",
    "interval":  "@urltest_interval",
    "tolerance": "@urltest_tolerance",
    "interrupt_exist_connections": true
  }
}
```

`options` — сырой template (`@urltest_*`-плейсхолдеры резолвятся позже, в
билдере/seed'е). Параметры уходят в `<tag>-auto`-двойник каждого канала с
`channel.include ∋ auto`.

### `default_channels[]` — сид каналов первого запуска

```jsonc
"default_channels": [
  { "tag": "vpn-1", "label": "VPN ①", "default_enabled": true  },
  { "tag": "vpn-2", "label": "VPN ②", "default_enabled": false }
]
```

В шаблоне только **2 seed-канала** (`vpn-1`, `vpn-2`). Дальнейшие каналы (до
`vpn-10`, `kMaxChannels = 10`) юзер создаёт сам в storage (`channels[]`).

| Ключ | Тип | Назначение |
|---|---|---|
| `tag` | string | Immutable id канала (`vpn-1`..`vpn-10`). |
| `label` | string | UI display name (пусто → `tag`). |
| `default_enabled` | bool | Влияет только на seed первого запуска. После миграции включённость живёт в `channels[].enabled`, редактируется в Routing → Channels. |

Storage source-of-truth: `channels[]` в `lxbox_settings.json` (§125). Legacy `enabled_groups[]` **DEPRECATED** — читается только one-shot миграцией в `channels[]` и как fallback-seed при пустом `channels[]` (см. [STORAGE.md](STORAGE.md#channels--125) и callout выше).

---

## `sections[]` — Wizard UI chapters (§022)

Группировка template-vars в Wizard UI (App Settings → Configuration). Каждая секция — отдельная карточка/экран с inputs.

```jsonc
[
  {
    "id":          "general",               // stable machine-id (§279, адрес l10n)
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

8 секций в текущем template'е: `General`, `Network`, `Internal`, `Auto Proxy`, `DNS`, `TUN`, `VPN Mode`, `DPI Bypass`. Расфасованы по **4 chapter'ам** (`core`, `routing`, `dns`, `internal`).

`id` — стабильный kebab-case machine-id (§279): `general`, `network`, `internal`,
`auto-proxy`, `dns`, `tun`, `vpn-mode`, `dpi-bypass`. Служит адресом l10n-overlay
для display-полей (`name`/`description`). Внутренним join-ключом секция↔vars
остаётся `name` (`parser_config.dart`, `settings_screen.dart`) — `id` его не заменяет.

### `chapter` — кто рендерит секцию

`chapter` — категория экрана-владельца. Экран запрашивает свои секции через
`WizardTemplate.sectionsFor(chapter)` / `varsFor(chapter)` (`parser_config.dart`).
Секция, чей chapter не запрашивает ни один экран, **в UI не появляется вообще**
(но её vars остаются в `template.vars` — билдер и ref-резолв их видят).

| `chapter` | Рендерится на | Секции |
|---|---|---|
| `core` | VPN Settings (App Settings → Configuration) | General, Network, TUN, VPN Mode, DPI Bypass |
| `routing` | Routing screen | Auto Proxy |
| `dns` | DNS Settings screen | DNS |
| `internal` | **нигде** (§265) | Internal |

### `internal` — служебная секция (§265)

Секция `Internal` (chapter `internal`) — vars, которые **не должны** показываться
в VPN Settings, но должны существовать глобально: билдер их подставляет, а
пресеты ссылаются на них через **ref-var** `{"ref":"<name>"}` (§265, см. `selectable_rules`).
Ни один экран не запрашивает chapter `internal` → секция в UI не рендерится; при
этом vars лежат в `template.vars`, поэтому `@name`-подстановка и ref-резолв
работают. Правит их юзер **через пресет-владелец** (напр. `resolve_enabled`/
`resolve_strategy` — в правиле `traffic-processing`, куда они втянуты ref-vars).

| Var | Тип | Назначение |
|---|---|---|
| `resolve_enabled` | bool | §263 — гейт route-resolve-правила пресета `traffic-processing` (off для FakeIP). Меняется on_change-механикой §266 (см. ниже) и вручную в правиле пресета. |
| `resolve_strategy` | enum | IP-версия для route-resolve (`ipv4_only`/`prefer_ipv4`/…). Пишется on_change тумблера IPv6 (§249). |

> **Почему `internal`, а не `wizard_ui: hidden`.** `hidden` прячет var внутри
> секции своего chapter'а, но секция всё равно принадлежит рендерящемуся экрану
> (VPN Settings). `internal`-chapter выводит var из-под любого экрана целиком —
> её единственная точка редактирования — пресет, который на неё ссылается.

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
| `on_change` | object? | §232 — декларативный side-effect при переключении var (in-memory, `VarValuesModel`). На **vars пресета** — §266-вариант (пишет глобальный `userVars`, триггер = вкл/выкл пресета). См. раздел ниже. |

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

### `on_change` — декларативный side-effect var'а (§232 / §266)

Переключение var может ставить производные var'ы. Синтаксис — на существующем
`#if` (value/else), условие видит УЖЕ НОВОЕ значение переключённой var. Ниже —
секционный вариант (§232, in-memory); пресетный (§266, глобальный `userVars`) — в
подразделе «`on_change` пресета».

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

> **§264/§265 — `resolve_strategy` живёт глобально в секции `internal`**, но
> route-resolve-правило переехало в locked-пресет `traffic-processing` (см.
> §264 ниже). Пресет ссылается на неё через ref-var `{"ref": "resolve_strategy"}`
> (§265): метаданные и значение — из этой глобали, `@resolve_strategy` в правиле
> резолвится глобально. `on_change` выше (тумблер IPv6, chapter `core`) по-прежнему
> пишет её глобально в `userVars`, эффект виден пресету. Var `sniff_enabled` стала
> собственной var пресета `traffic-processing`; `resolve_enabled` переехала в
> `internal` (§265) — её `§263`-тумблер редактируется в правиле пресета, а не в
> `Network`.

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

### `on_change` пресета — реакция на вкл/выкл (§266)

`on_change` живёт не только на секционных vars, но и на **vars пресета**. Отличие
от §232 — в источнике и приёмнике:

| | §232 (секция) | §266 (пресет) |
|---|---|---|
| **Триггер** | клик по var в Wizard-экране | смена состояния пресета (свич on/off, dns_enable-тумблер) |
| **Источник** | значение самой var (`VarValuesModel`) | **состояние пресета** — псевдо-vars `@rule_enable`/`@dns_enable` |
| **Приёмник** | in-memory `VarValuesModel` экрана | **глобальный `userVars`** (`SettingsStorage.setVar` — сразу на диск) |
| **Движок** | `settings_screen._applyOnChange` | `preset_on_change.dart::applyPresetOnChange` |

**Псевдо-vars пресета** (не хранятся — вычисляются из состояния):

- `@rule_enable` = `cr.enabled` (пресет включён свичем).
- `@dns_enable` = §257 `presetDnsEnableVar` (DNS-аспект пресета — мастер-тумблер
  DNS-блока).

Обе несут **идентичную** on_change-формулу — любая из них триггерит пересчёт цели
(так формула срабатывает и когда меняют routing-свич, и когда — dns-тумблер).
Резолв идёт в namespace `{...userVars, rule_enable, dns_enable}` (псевдо перекрывают
`userVars` — их значение «живое»), через тот же `evalIfScalar`.

Пример — FakeIP-пресет глушит route-resolve, пока сам активен (route-resolve —
это ВТОРОЙ резолвер мимо FakeIP через `default_domain_resolver`; при активном
FakeIP он должен молчать, §263):

```jsonc
// оба var пресета fakeip несут это; @resolve_enabled — var секции internal
"on_change": {
  "set": {
    "@resolve_enabled": {"#if": {"and": ["@rule_enable", "@dns_enable"], "value": "false", "else": "true"}}
  }
}
```

Читается: «FakeIP включён (`@rule_enable`) И его DNS-аспект включён (`@dns_enable`)
→ `resolve_enabled = false`; иначе `true`».

Семантика:

- **Пишет в `userVars` сразу** (не in-memory) — цель `@resolve_enabled` живёт в
  секции `internal` (глобальная var), её storage — `userVars`, не `varsValues`
  пресета. Событийная, не декларативно-постоянная: срабатывает в момент смены,
  юзер потом волен переопределить в правиле `traffic-processing`.
- **Зовётся из ВСЕХ 5 точек** смены `rule_enable`/`dns_enable`: создание пресета
  (`routing_screen._copyPreset`), toggle routing-свича (`routing_screen`
  + редактор `edit_controller.onBoolVarToggle`), dns_enable-тумблер в редакторе
  правила и **в DNS Settings** (`dns_settings_screen._togglePresetDnsEnable`).
  Пропуск любой точки → цель не пересчитается при этом пути изменения.
- **Идемпотентна** — `setVar` перезаписывает; повторный вызов с тем же состоянием
  даёт то же значение.

> **Грабля §266 (ловил на устройстве).** Псевдо-var (`rule_enable`/`dns_enable`)
> **обязана** иметь `default_value` + `required: false`. Var без `default_value` в
> sing-box-схеме = **required**; при пустом значении `expandPreset` выходит рано
> («required var … unset») и **весь DNS-блок пресета молча не эмитится** (FakeIP
> не прописал `dns_rules` → DNS не заворачивался). Симптом тихий — пресет в UI на
> месте, но не работает. См. `29fe61c`.

---

## `config` — нативная sing-box-секция

База финального sing-box config'а. Содержит `@var`-плейсхолдеры — substitution происходит на build time. После расширения `selectable_rules[*]` и каналы (`channels[]`, seeded из `group_templates`) мерджатся в эту базу.

```jsonc
{
  "log": {
    "level":     "@log_level",
    "timestamp": true
  },
  "dns": {
    "servers":  [],                              // пусто; заполняется из dns_options.servers + selectable_rules[].dns_servers
    "rules":    [],                              // пусто; заполняется из dns_options.rules + selectable_rules[].dns_rules
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
      // §264: route.rules в шаблоне ПУСТ. Базовые sniff/hijack-dns/resolve
      // ПЕРЕЕХАЛИ в locked-пресет traffic-processing (первый в selectable_rules,
      // pinned:0 → билдер ставит его правила первыми в финальном route.rules).
      // Порядок (sniff ПЕРЕД resolve) критичен для FakeIP: sniff извлекает домен
      // до resolve (resolve по фейк-IP 198.18.x.x бессмыслен). Каждое из трёх
      // правил обёрнуто в #if внутри пресета: @sniff_enabled / (протокол dns —
      // hijack-dns) / @resolve_enabled (off для FakeIP — real-lookup идёт мимо
      // FakeIP через default_domain_resolver). См. § selectable_rules ниже.
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
- `config.outbounds[+]` ← node-outbounds из enabled `server_lists[]`, плюс selector/urltest на каждый канал (`channels[]`, seeded из `group_templates`)
- `config.dns.servers[+]` ← `dns_options.servers[*]` (resolved через [§044]) + `selectable_rules[*].dns_servers[*]`
- `config.dns.rules[+]` ← `dns_options.rules[*]` ([§061]) + `selectable_rules[*].dns_rules`
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
  "ui": {                               // §264 — метаданные пресета. ОБЯЗАТЕЛЕН.
    "label":       "<UI display>",      //   Плоские label/description/default на
    "description": "<тултип>",          //   top-level УБРАНЫ; fallback в
    "default":     <bool>?,             //   SelectableRule.fromJson СНЯТ — читается
    "locked":      <bool>?,             //   ТОЛЬКО ui.
    "pinned":      <int>?               //   locked/pinned — см. ниже.
  },
  "vars": [ <Var> | {"ref":"<global>"}, … ]?, // vars видимые только при включении preset'а;
                                        //   §265: элемент-ссылка {"ref":"<имя глобали>"}
  "rule_set": [ <SingboxRuleSet>, … ]?, // rule_set'ы которые должны быть зарегистрированы
  "rule":     <SingboxRoutingRule>?,    // routing rule — legacy single (Map)
  "rules":    [ <SingboxRoutingRule>, … ]?, // §246: массив routing rules (канонический ключ; побеждает `rule`)
  "dns_rule": <SingboxDnsRule>?,        // DNS-уровень rule — legacy single (Map)
  "dns_rules": [ <SingboxDnsRule>, … ]?, // §253: массив DNS-rules (канонический ключ; побеждает `dns_rule`)
  "dns_servers": [ <FlatDnsServer>, … ]?  // ПЛОСКИЕ sing-box DNS-тела (не обёртка §117; top-level tag)
}
```

### `ui` — метаданные пресета (§264)

С §264 label/description/default/locked/pinned живут в объекте `ui` (**ОБЯЗАТЕЛЕН**;
плоские top-level `label`/`description`/`default` из шаблона убраны, fallback в
`SelectableRule.fromJson` снят — читается только `ui`). Все 8 пресетов переведены на `ui`.

| `ui.*` | Тип | Назначение |
|---|---|---|
| `label` | string | UI display. |
| `description` | string | Тултип. |
| `default` | bool? | default true → включён в новой установке. |
| `locked` | bool? | §264 — пресет **нельзя выключить** (свич disabled), **нельзя удалить**, **нельзя двигать** (нет drag-handle). Единственный locked-пресет — `traffic-processing`. |
| `pinned` | int? | §264 — **фиксированная позиция** в списке пресетов И в финальном `config.route.rules`. `pinned:0` = всегда позиция 0 (критично: sniff обязан быть первым). Нормализация `normalize_pinned_presets.dart` гарантирует наличие+позицию pinned-пресета (fresh/restore/upgrade-safe). Debug API (`serializers/rules.dart`) сериализует `locked`/`pinned`. |

### Полевая матрица текущих 8 preset'ов

Метаданные — из `ui.*` (§264): `default`/`locked`/`pinned`. `traffic-processing` —
первый в каталоге (locked, pinned:0), несёт базовые sniff/hijack-dns/resolve.

| `preset_id` | `ui.default` | `ui.locked` | `ui.pinned` | `vars` | `rule_set` | `rule(s)` | `dns_rule(s)` | `dns_servers` |
|---|---|---|---|---|---|---|---|---|
| `traffic-processing` | true | true | 0 | ✓ (sniff_enabled, sniff_timeout §264 enum 100ms/300ms/500ms/1s/3s, hijack_dns_enabled §264 bool WARNING-тултип, `{"ref":"resolve_enabled"}` + `{"ref":"resolve_strategy"}` §265 — обе ref на секцию `internal`) | — | ✓ массив: `[sniff #if @sniff_enabled, hijack-dns, resolve strategy:@resolve_strategy #if @resolve_enabled]` | — | — |
| `block-ads` | false | — | — | — | ✓ (remote ads-all) | ✓ (action: reject) | — | — |
| `ru-direct` | true | — | — | ✓ (outbound, dns_enable §257, dns_server, dns_ip, geoip_enabled, force_ipv4) | ✓ (inline `.ru` suffixes) | ✓ массив: `[resolve ipv4_only #if @force_ipv4, @outbound]` (§246) | ✓ массив: `[predefined-NOERROR ip_version:6 #if @force_ipv4, → @dns_server]` (§253) | ✓ (yandex_udp/doh/dot) |
| `fakeip` | false | — | — | ✓ (rule_enable §266 псевдо + on_change, dns_enable §257 + on_change, dns_server — **hidden**) | — | — | ✓ (`query_type: [A,AAAA]` → `@dns_server`) | ✓ (type `fakeip`, ranges 198.18/15 + fc00::/18) |
| `ru-inside` | (false) | — | — | ✓ (outbound, force_ipv4) | ✓ (remote ru-inside) | ✓ массив: `[resolve ipv4_only #if @force_ipv4, @outbound]` (§246) | — | — |
| `bittorrent` | true | — | — | ✓ (outbound) | — | ✓ (`protocol: bittorrent` → `@outbound`) | — | — |
| `private-ip` | (false) | — | — | ✓ (outbound) | — | ✓ (`ip_is_private` → `@outbound`) | — | — |
| `unknown-traffic` | false | — | — | ✓ (`outbound`=reject) | ✓ (inline `unknown-apps`, invert `package_name_regex: "^"`) | ✓ (`@outbound`) | — | — |

**`traffic-processing` (§264)** — locked/pinned пресет, ПЕРВЫЙ в `selectable_rules`. Несёт базовые route-правила `sniff` / `hijack-dns` / `resolve`, которые до §264 жили прямо в `config.route.rules` (теперь пуст). `pinned:0` гарантирует, что его правила идут первыми в финальном `config.route.rules` (sniff обязан быть первым — извлекает домен до resolve, критично для FakeIP). `locked:true` — свич disabled, нельзя удалить/двигать. Каждое из трёх правил гейтится собственным `#if` (array-element form): `sniff #if @sniff_enabled` / `hijack-dns` (безусловно) / `resolve #if @resolve_enabled`. Vars пресета: `sniff_enabled` (bool), `sniff_timeout` (enum 100ms/300ms/500ms/1s/3s — НОВАЯ, дефолт `300ms`, раньше был хардкод `timeout:"1s"`), `hijack_dns_enabled` (bool — НОВАЯ, WARNING-тултип: off ломает FakeIP), `{"ref":"resolve_enabled"}` + `{"ref":"resolve_strategy"}` (§265 ref-vars — значение и метаданные из глобалей `resolve_enabled`/`resolve_strategy`, обе живут в секции `internal`, редактируются прямо здесь). Отключение `hijack_dns_enabled` убирает hijack-dns-правило; ⚠ без hijack-dns DNS-запросы не перехватываются → FakeIP не работает. `resolve_enabled=false` нужен для FakeIP (real-lookup идёт мимо FakeIP через `default_domain_resolver`, §263) — при включении FakeIP этот флаг гасится **автоматически** через on_change пресета `fakeip` (§266, см. «`on_change` пресета» выше). Нормализация `normalize_pinned_presets.dart` держит пресет в наличии и на позиции 0 при fresh install / restore / upgrade.

`unknown-traffic` — reject/direct для трафика в туннеле, не атрибутированного ни одному установленному приложению (фоновые/чужие процессы). Инлайн `rule_set` `unknown-apps` матчит «всё, что НЕ приложение» через `invert: true` + `package_name_regex: "^"`.

**Backstop `reject`→`action`.** У `unknown-traffic` var-дефолт `outbound: "reject"`, и `rule.outbound: "@outbound"`. `reject` в sing-box — это `action`, а НЕ outbound-tag: литерал `{outbound: "reject"}` валидатор реджектит как dangling ref → fatal, ядро не стартует. Поэтому `preset_expand.dart` БЕЗУСЛОВНО нормализует финальный результат: `outbound == "reject"` → снять `outbound`, поставить `action: "reject"`. Это инвариант билдера (контракт sing-box), а не забота автора шаблона — работает и когда юзер выбрал reject явно в пикере, и когда просто включил пресет с дефолтом.

**`fakeip` (§228)** — FakeIP-DNS: `dns_servers` даёт сервер `type: fakeip` (диапазоны 198.18.0.0/15 + fc00::/18), `dns_rule` заворачивает все `A`/`AAAA`-запросы на него. Приложение получает placeholder-IP мгновенно (0 latency, нет pre-tunnel DNS-утечки), реальный резолв доменов происходит внутри туннеля. **Порядок в каталоге критичен:** `fakeip` стоит ПОСЛЕ `ru-direct` — билдер сохраняет порядок пресетов в `dns.rules[]`, поэтому ru-dns-правило матчится раньше и русские домены резолвятся по-настоящему (иначе они ушли бы в fakeip и `geoip-ru` по фейк-IP не сматчил бы → RU-трафик через VPN). Сервер вливается через **hidden-var** `dns_server` (см. «Магические переменные» ниже — без неё сервер не эмитится). Персистентность фейк-маппинга между реконнектами — `experimental.cache_file.store_fakeip: true` в базовом config (не пресетом; статичный флаг). `dns.independent_cache` НЕ ставим — deprecated в sing-box 1.14.

### Магические переменные пресетов (§033, §228, §257, §264, §265, §266)

Имена preset-vars **не произвольны**: несколько имён имеют специальную семантику — билдер и UI смотрят на них по имени/типу, а не только подставляют `@name`. Пропуск нужной «магической» переменной приводит к тому, что часть пресета **молча не работает** (регрессия §228 с FakeIP — сервер не вливался, потому что не было var `dns_server`).

| Var (имя / тип) | Кто смотрит | Что делает | Пропустишь → |
|---|---|---|---|
| `dns_server` (`type: dns_servers`) | `preset_expand.dart` | **Селектор** какой из `dns_servers[]` пресета влить в `config.dns.servers`. Билдер эмитит РОВНО ОДИН сервер — тот, чей `tag == varsValues['dns_server']` (или `default_value`). `dns_rules[*].server` ссылается на него через `@dns_server`. | `dns_servers[]` **не вливается вообще** (цикл гейтится наличием этой var). DNS-правило повиснет на несуществующий сервер → dangling → guard молча дропнет правило. Пресет ничего не делает для DNS. |
| `outbound` (`type: outbound`) | `preset_expand.dart` + Routing UI | Значение для `@outbound` в `rule`/`dns_servers.detour`. UI рисует outbound-picker в строке пресета (см. `hasOutboundAffordance`). Дефолт `"reject"` → backstop-нормализация в `action:reject`. | Нет var:outbound И нет `rule` → `hasOutboundAffordance == false` → outbound-picker в строке **не рисуется** (DNS-only пресет — роутить нечего, picker был бы мёртвым). Это корректно, а не баг. |
| `dns_enable` (`type: bool`) | `custom_rules.dart` (`presetDnsEnableVar`) + DNS Settings UI | §257: **мастер-тумблер DNS-блока** пресета (dns_servers + dns_rules + mirror-группа). Билдер гейтит DNS-аспект значением var (юзерский выбор → default_value → on); DNS Settings рисует свитч пресетной строки этим же предикатом и пишет var обратно. Заменил `isPresetDnsEnabled` из `dns_options.rules` (то поле `enabled` теперь мёртвое, запись — только позиционный якорь §117). | DNS-блок пресета **не тумблится** (всегда on, пока routing on); строка в DNS Settings — без свитча (нейтральная иконка). Норма для пресетов, которым тумблер не нужен. |
| `rule_enable` (`type: bool`, псевдо) | `preset_on_change.dart` | §266: **псевдо-var** on_change-формулы. НЕ хранится — резолвер подставляет `cr.enabled` (пресет включён свичем). Носитель `on_change`, которая при вкл/выкл пишет цель в `userVars` (см. «`on_change` пресета» выше). У FakeIP: `@rule_enable AND @dns_enable → resolve_enabled=false`. | ⚠ **`default_value` обязателен + `required:false`.** Без `default_value` var = required → `expandPreset` выходит рано → **весь DNS-блок пресета молча не эмитится** (грабля `29fe61c`). |

**§265 — ref-vars (`{"ref": "<global>"}`).** Элемент `vars[]` пресета может быть **ссылкой** на глобальную var вместо декларации: `{"ref": "resolve_strategy"}`. Метаданные (`type`/`options`/`title`/`tooltip`/`default_value`) **не дублируются** — берутся из целевой глобали (`WizardTemplate.globalVar(name)`; ищется по всем секциям, включая `internal`). Значение живёт в **глобальном** `userVars` (не в `rule.varsValues` пресета) — единый источник; `@resolve_strategy` в теле пресета резолвится глобально. В модели: `WizardVar` получил поле `ref` + геттер `isRef`, `WizardVar.fromJson` парсит `{"ref":…}`. В билдере: `expandPreset` получил параметр `globalVars` — ref-vars пропускаются в `varsValues`-цикле и подмешиваются из `globalVars`.

В UI: ref-var **рендерится** в редакторе правила (`preset_params_tab.dart`) с метаданными из глобали — но читает/пишет `userVars` (`edit_controller.setGlobalVar`), не `varsValues`. Применение (§264): `traffic-processing` ссылается на `resolve_strategy` и `resolve_enabled` (обе в секции `internal`) через `{"ref":"…"}` — так они правятся прямо в правиле, оставаясь скрытыми из VPN Settings.

> **§265 — data-cleanup: ref-var НЕ в `varsValues`.** Значение ref-var принадлежит
> `userVars`; если оно осело в `varsValues` пресета (миграция, старый storage) —
> это «застрявшая» копия, которая расходится с глобалью (subtitle показывал
> `resolve_enabled: true`, когда глобаль уже `false`). `stripRefVarsFromVarsValues`
> (`normalize_pinned_presets.dart`) вычищает ref-ключи из `varsValues` на загрузке
> Routing-экрана; все читатели `varsValues` по имени var **обязаны** пропускать
> `v.isRef` (subtitle, Debug-сериализатор, rule_set.enabled-гейт — см. `366beec`).

**§264 — новые vars пресета `traffic-processing`.** `sniff_timeout` (enum 100ms/300ms/500ms/1s/3s) заменил хардкод `timeout:"1s"` у sniff-правила. `hijack_dns_enabled` (bool) — тумблер hijack-dns-правила; ⚠ WARNING-тултип: выключение ломает FakeIP (DNS не перехватывается). Обе — обычные preset-vars (не «магические» — билдер только подставляет `@name` через `#if`), перечислены здесь для полноты каталога.

**Правила при добавлении пресета:**

1. **Пресет несёт `dns_servers[]`** → обязателен var `dns_server` (`type: dns_servers`, `default_value` = tag нужного сервера), а `dns_rules[*].server` = `@dns_server`. Иначе сервер не эмитится (§228). Если сервер один и выбирать не из чего (как у FakeIP) — пометь var **`wizard_ui: "hidden"`**: значение всё равно придёт из `default_value`, но мёртвый dropdown-из-одного-пункта в редакторе не рисуется. (Редактор `preset_params_tab.dart` фильтрует hidden-vars; sections тоже.)
2. **Пресет роутит трафик** (есть `rule` с `outbound`/`action` или var:outbound) → outbound-picker в строке появится автоматически. **DNS-only пресет** (только DNS-правила, как FakeIP) → picker сам скрывается через `hasOutboundAffordance`.
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

### `selectable_rules[*].dns_rule(s)` / `dns_servers`

Аналогично routing rule, но для DNS pipeline. Канонический ключ — `dns_rules` (массив, §253); `dns_rule` (single Map) — legacy-форма (fakeip). Элемент направляет matched-domains на DNS-сервер из `dns_servers[]` (или ссылку на основной `dns_options.servers[]` сервер по tag), либо отвечает сам serverless-действием (`predefined`/`reject` — `server` не нужен).

Массивная форма поддерживает **array-element `#if`** (§246-механика): `#if` false без else → элемент выпадает из массива целиком. Пример из `ru-direct` (Force IPv4, §253): первым идёт `#if @force_ipv4`-гейт `{ip_version: 6, action: predefined, rcode: NOERROR}` (AAAA-запросы к RU-доменам получают пустой успешный ответ — приложение чисто берёт A; НЕ `reject`: он отвечает REFUSED и после 50 срабатываний/30с переходит в drop), вторым — безусловный маршрут `{server: @dns_server}`. **Порядок критичен:** гейт первым, маршрут безусловным — иначе не-A/AAAA-запросы (HTTPS type 65 и пр.) уйдут мимо `@dns_server` (`ip_version` матчит только A/AAAA; прочие типы не матчатся ни `4`, ни `6`).

⚠ Легаси `strategy` в DNS-правиле **запрещён** (deprecated в ядре 1.14 и несовместим с `query_type`/`ip_version` в том же конфиге — fatal на старте; билдер снимает его heal'ом, §246). Ограничение семейства адресов — только через `ip_version`-matcher + `predefined`.

⚠ В отличие от `dns_options.servers[*]` (обёртка `{description, enabled, vars?, server}` §117), preset-`dns_servers[*]` — это **плоские sing-box-тела** (`{type, tag, detour, …}` без обёртки, tag на top-level). `preset_expand.dart` фильтрует их по top-level `s['tag']`. Пример из `ru-direct`: `{"type":"udp","tag":"yandex_udp","detour":"@outbound",…}`.

### `vars` substitution

Vars, объявленные в preset'е, **видны только когда preset enabled**. UI рендерит их в Routing → preset detail. При expansion `@varname` в `rule(s)` / `dns_rule(s)` / `dns_servers` подставляется текущим значением (`varsValues[name]` из `CustomRulePreset` storage entry, fallback на `default_value`).

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

## Formatting style (оформление `wizard_template.json`)

Editorial-конвенции для **бандл**-шаблона (`app/assets/wizard_template.json`). Порядок
ключей и переносы **не влияют** на loader/билдер — это читаемость для maintainer'ов.
Семантика (`#if`, magic-vars, порядок правил) обязательна; оформление — нет, но держим
единообразно. Кастомные/импортированные шаблоны эту секцию могут игнорировать.

### Общий принцип

**Компактно** (одна строка) — литералы и мелкие metadata-объекты. **Развёрнуто**
(multiline) — выражения (`@…`, `#if`) и длинные списки. Критерий: строка с `@`-плейсхолдером
или вложенным `#if` разворачивается; чистые литералы можно жать.

### Vars (`sections[*].vars[]` и `selectable_rules[*].vars[]`)

| Часть var | Оформление |
|---|---|
| «Шапка» — `name`, `type`, `wizard_ui`, `title`, `tooltip` | **Строка 1** (вместе) |
| `default_value` | **Отдельная строка** с отступом |
| `options[]` | **Multiline** — каждый элемент на своей строке (`{title,value}` или голая строка) |
| ref-var (§265) `{"ref": "<name>"}` | **Одна строка** целиком (метаданных не несёт) |
| Простой bool-var без options | **Одна строка** целиком |

```jsonc
{ "name": "resolve_strategy", "type": "enum", "wizard_ui": "edit", "title": "Resolve strategy", "tooltip": "IP version preference for DNS resolution",
  "default_value": "ipv4_only",
  "options": ["prefer_ipv4", "prefer_ipv6", "ipv4_only", "ipv6_only"]
},
{ "name": "sniff_enabled", "type": "bool", "default_value": "true", "wizard_ui": "edit", "title": "Packet sniffing", "tooltip": "..." },
{ "ref": "resolve_strategy" }
```

### `ui`-объект пресета (§264)

Метаданные пресета (`label`/`description`/`default`/`locked`/`pinned`) — **одна строка**,
если влезает; иначе `label`/`description` на строке 1, флаги (`default`/`locked`/`pinned`) —
строкой ниже. Флаги-`false`/`pinned:null` НЕ пишем (дефолты модели).

```jsonc
"ui": {"label": "Traffic Processing", "description": "...", "default": true, "locked": true, "pinned": 0}
```

### JSON payload (`config`, `dns_servers`, `rule_set`)

| Контекст | Правило |
|---|---|
| Поля с `@`-плейсхолдером | **одно поле — одна строка** |
| Литералы (`type`, `tag`, `auto_route`, `server_port`) | можно вместе на одной строке |
| Мелкие struct'ы ≤2–3 литерала (`direct-out`, hijack-dns) | **одна строка** |
| Крупные объекты (`dns_options.servers[]`, preset `dns_servers[]`) | **multiline** — одно поле на строку |
| `options`/`filters` **без** `@` | **одна строка** |

### `#if`-конструкт (§120)

| `value` / `else` | Оформление |
|---|---|
| **Скаляр** | `{"#if": {"and": [...], "value": "..."}}` — одна строка |
| **Объект** | условие + `"value": {` на строке 1; тело ниже; закрытие `}}}` |

```jsonc
{"#if": {"and": ["@force_ipv4"], "value": {
  "rule_set": ["ru-domains", "ru-services"], "ip_version": 6,
  "action": "predefined", "rcode": "NOERROR"
}}}
```

### Правила пресета (`rule`/`rules`, `dns_rule`/`dns_rules`)

| Случай | Оформление |
|---|---|
| Одиночное правило-литерал (без `#if`, без `@`) | **одна строка** |
| Правило под `#if` со скаляром | одна строка |
| Правило под `#if` с объектом-`value` | multiline (условие → тело → `}}}`) |
| `rule_set[]` inline/remote | строка 1: metadata (`tag`/`type`/`format`); строка 2: `rules`/`url` |
| Длинные inline-suffix списки | одна строка если влезает; иначе переносы в массиве |

```jsonc
"dns_rules": [
  {"#if": {"and": ["@force_ipv4"], "value": {
    "query_type": ["HTTPS", "SVCB"], "action": "predefined", "rcode": "NOERROR"
  }}},
  {"rule_set": ["ru-domains", "ru-services"], "server": "@dns_server", "action": "route"}
]
```

### Шпаргалка

| | Одна строка | Multiline |
|---|---|---|
| var-шапка (`name`/`type`/`title`/`tooltip`) | ✓ | — |
| `default_value` | — | ✓ |
| `options[]` элементы | — | ✓ |
| ref-var `{"ref":...}` | ✓ | — |
| `ui`-объект пресета | ✓ (если влезает) | флаги ниже |
| `@`-поле в payload | — | ✓ (по полю) |
| `#if` + object `value` | условие | тело |
| `#if` + скаляр | ✓ | — |
| литеральное правило пресета | ✓ | — |

> **Грабля:** НЕ вставлять коммент-ключи (`"//": "..."`) в `config`-блок — sing-box
> strict-decode их не знает → fatal старт ядра (§264). Пояснения — в этом файле или спеке,
> не в JSON конфига. В мета-секциях (`vars`/`sections`/`ui`) можно любые поля — они не идут
> в config.

---

## Когда что ломается

### Добавляем новый top-level ключ

Update этого файла (раздел top-level + новый section per-key) + добавляем читалку в builder/loader. Проверяем что `template_loader.dart` парсит без ошибок (текущий парсер permissive — игнорирует unknown keys).

### Меняем shape preset'а / vars

Если breaking — bump `parser_config.version` (это сигнал для миграционного кода). Описать миграцию в [§026 parser v2 spec](./spec/features/026%20parser%20v2/spec.md) или новой спеке.

### Добавляем var с новым `type`

Update var.type таблицу в этом файле + добавить рендерер в `settings_screen.dart`.

### Меняем `config.route.rules` базовые правила

С §264 базовых правил в `config.route.rules` **больше нет** (ключ пуст) — sniff/hijack-dns/resolve переехали в locked-пресет `traffic-processing` (`pinned:0`). Правь их **там**, не в `config.route.rules`. Порядок первых правил критичен (sniff первым) — `pinned:0` + `normalize_pinned_presets.dart` держат пресет на позиции 0. Любое новое базовое route-правило для всех юзеров либо кладётся в этот пресет, либо (если условное) — как preset-rule. Может сломать routing для существующих юзеров — **проверять** порядок относительно auto-discovery preset-rules. См. order matters в [§030].

### Добавляем ref-var в пресет (§265)

Кладёшь `{"ref":"<global>"}` в `vars[]` пресета. Целевая глобаль **обязана
существовать** в какой-то секции (`WizardTemplate.globalVar` ищет по всем, вкл.
`internal`) — иначе метаданные не резолвятся. Если var не должна светиться в VPN
Settings — заводи её в секции `internal` (chapter не рендерится). Значение живёт
в `userVars`; **не** дублируй его в `varsValues` (страгглер разойдётся с
глобалью — см. `stripRefVarsFromVarsValues`). Все читатели `varsValues` по имени
пропускают `v.isRef`.

### Добавляем on_change на пресет (§266)

Магическая псевдо-var (`rule_enable`/`dns_enable`) несёт `on_change: {"set":{...}}`.
Обязательно: (1) `default_value` + `required:false` на псевдо-var (иначе пресет
молча не эмитится, грабля `29fe61c`); (2) цель — существующая глобаль (обычно в
`internal`); (3) вызвать `applyPresetOnChange` из **всех** точек смены состояния
пресета (routing-свич, dns-тумблер, редактор, DNS Settings — сейчас 5 мест). Если
формула зависит и от routing-, и от dns-состояния — вешай **идентичный** on_change
на обе псевдо-vars (`rule_enable` И `dns_enable`), чтобы срабатывало по любому пути.

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
