# Wizard Template

The complete schema of `app/assets/wizard_template.json` — L×Box's single **catalog**: which presets, DNS servers, ping settings, Wizard UI sections and routing nodes exist in the app out of the box. This document is the source of truth for the file's shape and for the vars-substitution syntax. `ARCHITECTURE.md` links here.

## What it is

`app/assets/wizard_template.json` is bundled into the APK through `flutter assets`. It is loaded with `rootBundle.loadString` in `app/lib/services/template_loader.dart` (an async singleton). It holds the **catalog** (what exists at all), the **defaults** (the values a fresh install starts with) and the **substitution shape** (the native sing-box section with `@var` placeholders).

At runtime the builder (`app/lib/services/builder/build_config.dart`) merges:
- `config` (the template's native sing-box section), plus
- `selectable_rules[*]` (the presets the user picked in `custom_rules`), plus
- `dns_options.{servers,rules}` (the current state of storage), plus
- `group_templates` and `default_channels` (the channel assembly templates, §267), plus
- the `vars` substitution (the template vars from storage)

→ into the final `<docs>/singbox_config.json` for libbox.

`wizard_template.json` is NEVER modified by the user — it is a catalog. The user's state lives in `lxbox_settings.json` (see [`STORAGE.md`](./STORAGE.md)).

## `wizard_template.json` — full tree

> **Notation**:
> - `object{N keys}` — an object with N keys
> - `list[N]` — an array of N elements; a bare `list` is variable-length
> - `<TypeName>` — the element type of an array (shown separately below)
> - a `?` after the type means the field is optional
> - `"@varname"` — a substitution placeholder; at build time the value from `vars` is put in its place

```
wizard_template.json
│
├─ parser_config                   object{2 keys}
│   ├─ version                     int           the parser pipeline's schema (§026)
│   └─ parser                      object{1 keys}
│       └─ reload                  duration      auto-refresh subscriptions interval (Go-style "12h")
│
├─ dns_options                     object{2 keys}       the default DNS shape for the builder
│   ├─ servers[]                   list          template-level DNS servers (7 defaults)
│   │   └─ <DnsServerRef>          object          the §117 wrapper (the tag lives in server.tag):
│   │       ├─ description         string?       UI label
│   │       ├─ enabled             bool?         default true (default-enabled for auto-discovery)
│   │       ├─ vars[]              list?         the same definitions as preset vars (§033)
│   │       └─ server              object          sing-box DNS server body + @placeholders:
│   │           ├─ type            "udp"|"https"|"tls"|"local"
│   │           ├─ tag             string        a unique id for references
│   │           ├─ server          string?       IP/host (udp/tls/h3)
│   │           ├─ server_port     int?
│   │           ├─ path            string?       (https) "/dns-query"
│   │           ├─ tls             object?         {enabled, server_name}
│   │           ├─ detour          tag?          which outbound to resolve through
│   │           └─ domain_resolver tag?          which DNS resolves the server's own host
│   └─ rules[]                     list          template-level DNS rules (§061, formerly feature §041); currently empty
│
├─ ping_options                    object{3 keys}       (§040)
│   ├─ url                         string        global default (e.g. gstatic.com/generate_204)
│   ├─ timeout_ms                  int           default 5000
│   └─ presets[]                   list          the dropdown options in the Ping Settings UI
│       └─ {id, name, url}         object        id — stable machine-id (§279)
│
├─ speed_test_options              object{3 keys}       (§015)
│   ├─ servers[]                   list[10]      Cloudflare, Selectel, Hetzner, OVH, etc.
│   │   └─ {id, name, download_url, upload_url, upload_method, ping_url}
│   ├─ stream_options              list[3]       parallel-streams choices (e.g. [1,4,10])
│   └─ default_streams             int           default 4
│
├─ group_templates                 object        the channel assembly templates (§267)
│   ├─ magic_nodes                  object        a registry of service nodes, keyed by role
│   │   └─ <role>                   object        role ∈ {auto, direct, block}
│   │       ├─ title                string        UI-label ("Auto"/"Direct"/"Block")
│   │       ├─ source               "generate"|"preset"  how the node comes into being
│   │       ├─ tag                  string?       (preset) a reference into config.outbounds
│   │       └─ tpl                  string?       (generate) the tag template ("{parent_tag}-auto")
│   ├─ channel                      object        the template of an ordinary channel (a selector)
│   │   ├─ type                     "selector"
│   │   ├─ include[]                list[role]    the role keys of magic_nodes (["direct","auto"])
│   │   └─ options                  object          sing-box selector options (interrupt_exist_connections)
│   └─ auto                         object        the template of the auto subgroup (a urltest)
│       ├─ type                     "urltest"
│       └─ options                  object          url / interval / tolerance (raw @vars)
│
├─ default_channels[]               list          the first-launch channel seed (§267)
│   └─ <DefaultChannel>             object
│       ├─ tag                      string        "vpn-1".."vpn-10"
│       ├─ label                    string        UI display ("VPN ①")
│       └─ default_enabled          bool          enabled in a fresh install?
│
├─ sections[]                      list[8]       Wizard UI chapters (§022)
│   └─ <Section>                   object
│       ├─ id                      string        stable machine-id, kebab-case (§279: "general", "auto-proxy", …)
│       ├─ name                    string        "General", "DNS", "TUN", etc. — the internal join key between vars and sections
│       ├─ chapter                 string        grouping ("core"|"routing"|"dns")
│       ├─ description             string
│       └─ vars[]                  list          the section's variables
│           └─ <Var>               object
│               ├─ name            string        the @name used for substitution
│               ├─ type            string        "text"|"int"|"bool"|"enum"|"secret"|"outbound"|"dns_servers"
│               ├─ default_value   any
│               ├─ required        bool?
│               ├─ options[]       list?         for an enum: ["a","b"] or [{title,value}, ...]
│               ├─ wizard_ui       string?       "edit"|"fix"|"hidden"
│               ├─ title           string?       UI label
│               └─ tooltip         string?       help text
│
├─ config                          object{7 keys}       the NATIVE sing-box section; the base of the final config
│   ├─ log                         object{2 keys}
│   │   ├─ level                   "@log_level"
│   │   └─ timestamp               bool
│   ├─ dns                         object{4 keys}       an empty shell, filled in by the builder
│   │   ├─ servers[]               list          [] — filled in from dns_options plus selectable_rules
│   │   ├─ rules[]                 list          [] — the same
│   │   ├─ final                   "@dns_final"
│   │   └─ strategy                "@dns_strategy"
│   ├─ inbounds[]                  list[1]       tun definition
│   │   └─ <SingboxTunInbound>     object
│   │       ├─ type                "tun"
│   │       ├─ tag                 "tun-in"
│   │       ├─ interface_name      "@tun_name"
│   │       ├─ address             ["@tun_address", {#if @ipv6_enabled → "@tun_address6"}]  §227/§232 — v6 behind a checkbox
│   │       ├─ {#if @route_address_enable → route_address: ["0.0.0.0/1","128.0.0.0/1","::/1","8000::/1"]}  §232 — behind a checkbox
│   │       ├─ mtu                 "@tun_mtu"
│   │       ├─ auto_route          "@tun_auto_route"
│   │       ├─ strict_route        "@tun_strict_route"
│   │       └─ stack               "@tun_stack"
│   ├─ endpoints[]                 list          the wireguard endpoints (filled in from server_lists)
│   ├─ outbounds[]                 list[2]       the base — direct-out plus block; the rest is added by the builder
│   │   ├─ {type:"direct", tag:"direct-out"}
│   │   └─ {type:"block",  tag:"block"}        §201 — the drop-out; a channel selector option and a route_final
│   ├─ route                       object{5 keys}
│   │   ├─ find_process            bool          true enables package_name detection
│   │   ├─ default_domain_resolver "@dns_default_domain_resolver"
│   │   ├─ rules[]                 list[0]       [] — §264: sniff/hijack-dns/resolve
│   │   │                                         MOVED into the locked traffic-processing preset
│   │   │                                         (num:0 → first in route.rules).
│   │   │                                         In the template route.rules is empty.
│   │   ├─ rule_set[]              list          (the key is ABSENT from the template — the builder creates it
│   │   │                                         from selectable_rules[].rule_set)
│   │   ├─ final                   tag           default selector ("vpn-1")
│   │   └─ auto_detect_interface   "@auto_detect_interface"
│   └─ experimental                object{1 keys}
│       └─ cache_file              object          {enabled:true, path:"cache.db"}
│                                                  (clash_api was REMOVED in §122 — the block in a custom template
│                                                   kills the core's startup: "clash api is not included in this build")
│
└─ selectable_rules[]              list[8]       the preset CATALOG
    └─ <Preset>                    object
        ├─ preset_id               string        the id referenced from custom_rules (§030)
        ├─ ui                      object          §264 — the preset's metadata (the flat
        │   ├─ label               string        UI display                label/description/
        │   ├─ description         string        the tooltip            defaults were REMOVED,
        │   ├─ default             bool?         on for new users?       the fallback is GONE):
        │   ├─ locked              bool?         §264 — cannot be disabled or deleted
        │   ├─ num                 int?          §370 — the position on the rule ordering axis
        │   └─ isSortable          bool?         §370 — whether it can be dragged
        ├─ vars[]                  list?         the variables visible while the preset is enabled
        │                                        (the same shape as sections[*].vars[*];
        │                                         §265: an element may be {"ref":"<global>"})
        ├─ rule_set[]              list?         sing-box rule-set definitions
        │   └─ <SingboxRuleSet>    object
        │       ├─ tag             string
        │       ├─ type            "inline"|"local"|"remote"
        │       ├─ format          "binary"|"source"?     (local/remote)
        │       ├─ rules[]         list?                  (inline) the match conditions
        │       ├─ url             string?                (remote)
        │       ├─ download_detour tag?                   (remote) usually "direct-out"
        │       └─ update_interval duration?              (remote) "168h"
        ├─ rule                    object?         single routing rule:
        │   └─ <SingboxRoutingRule>                {rule_set?, domain[]?, domain_suffix[]?,
        │                                           ip_cidr[]?, ip_is_private?, port[]?,
        │                                           package_name[]?, protocol[]?,
        │                                           outbound:"@var"?, action:"reject"?}
        ├─ dns_rule                object?         a DNS-level rule — the legacy single form (a Map)
        ├─ dns_rules               list?           §253: an array of DNS rules (the canonical
        │                                          key; it beats `dns_rule`)
        └─ dns_servers[]           list?         the DNS servers visible while the preset is enabled
                                                 (FLAT sing-box bodies, shaped like the inside of
                                                  `dns_options.servers[*].server`, with NO wrapper;
                                                  filtered by the top-level `tag`)
```

Every key is described in detail in the sections below.

---

## Top-level (annotated)

```jsonc
{
  "parser_config":       { … },     // §026 parser version + reload interval
  "dns_options":         { … },     // §043+§044 (servers) + §061 (rules) — defaults
  "ping_options":        { … },     // §040 — ping/test URL + presets
  "speed_test_options":  { … },     // §015 — speed-test endpoints
  "group_templates":     { … },     // §267 — the magic_nodes registry plus the channel/auto templates
  "default_channels":    [ … ],     // §267 — the first-launch channel seed (vpn-1, vpn-2)
  "sections":            [ … ],     // Wizard UI chapters (variables grouped by topic)
  "config":              { … },     // the native sing-box sections (log/dns/inbounds/outbounds/route/...)
  "selectable_rules":    [ … ]      // §033 — the preset catalog
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

| Key | Type | Purpose |
|---|---|---|
| `version` | int | The parser pipeline's version ([§026]). It is bumped on breaking parser changes. |
| `parser.reload` | a duration string | The periodic auto-refresh interval for subscriptions ([§027]). Go style: `12h`, `30m`, and so on. It is overridden per subscription. |

---

## `dns_options` — §043+§044 (servers) + §061 (rules)

The default DNS configuration for a fresh install. It is stockpiled into the `dns_options` storage on the first launch.

```jsonc
{
  "servers": [ <ServerRef>, … ],   // kind-refs (template-side: kind=template implicit)
  "rules":   [ <RuleRef>, … ]      // template-defined DNS rules (if any)
}
```

### `dns_options.servers[i]` — a DNS server catalog entry (§117)

The wrapper is `{description, enabled, vars?, server}`, where `server` is a sing-box body carrying
`@var` placeholders, and `vars` holds the same definitions as preset vars (§033).
The tag lives in `server.tag` (there is no top-level `tag` any more — see `templateDnsServerTag`).
The builder (`resolveTemplateDnsServerBody`) substitutes the vars with the user's values
(`varValues` from the storage ref) or with `default_value`:

```jsonc
{
  "description": "Google DNS (direct)",
  "enabled":     true,               // default-enabled for auto-discovery
  "vars": [                          // optional (local_dns_resolver has none)
    {"name": "outbound", "type": "outbound", "default_value": "direct-out",
     "title": "Outbound", "tooltip": "Which channel carries DNS queries…"},
    {"name": "dns_ip", "type": "enum", "default_value": "8.8.8.8",
     "title": "UDP server IP", "options": [ {"title": "…", "value": "8.8.8.8"}, … ]}
  ],
  "server": {                        // sing-box DNS server body + @placeholders
    "type": "udp", "tag": "google_udp", "server_port": 53,
    "server": "@dns_ip",
    "detour": "@outbound"            // direct-out, or a vanished channel, erases the key
  }
}
```

The conventions (§117):

- `detour: "@outbound"` with a var default of `direct-out` means the key is **not**
  written by default (`normalizeDnsDetour`: `direct-out`, an empty value and a channel
  unknown to the builder all erase the key; “no detour” is both the default and the fallback).
- For domain-addressed servers (the address is a hostname): `domain_resolver: "@dom_resolver"` plus
  the var `{type: dns_servers, default_value: "google_udp"}` decides what resolves the
  DNS server's own hostname.

The seven default servers in the current template:

| Tag | Type | Description |
|---|---|---|
| `local_dns_resolver` | local | The system DNS (through Android's getaddrinfo), with no vars |
| `google_udp` | udp | 8.8.8.8:53 (`dns_ip` enum v4/v6) |
| `google_dot` | tls | 8.8.8.8:853 |
| `google_doh` | https | IP-based DoH, with the SNI pinned to `dns.google` |
| `cloudflare_udp` | udp | 1.1.1.1:53 |
| `cloudflare_dot` | tls | 1.1.1.1:853 |
| `safe_dns_dot` | tls | Safe DNS: Quad9 / AdGuard / AdGuard Family (`safe_profile` enum) + `dom_resolver` |

### `dns_options.rules[]` — template DNS rules (optional)

Currently empty. Since [§039](./spec/tasks/039-empty-template-dns-rules.md) this is deliberate — the user builds their DNS rules themselves.

For the full ref-level shape see [`STORAGE.md` § dns_options](./STORAGE.md#dns_options--061-rules--043043-dns--044-servers).

---

## `ping_options` — §040

The default URL and timeout for a ping or a mass URLTest. Storage can override them through `ping_options` ([STORAGE.md § ping_options](./STORAGE.md#ping_options--040)).

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

| Key | Purpose |
|---|---|
| `url` | The default ping endpoint. The user can override it globally or per group. |
| `timeout_ms` | The default timeout. Raise it for slow networks. |
| `presets[]` | The pre-configured options in the Ping Settings dropdown — `{id, name, url}`. `id` is a stable machine id (§279, so that the name can be localized). |

---

## `speed_test_options` — §015

The endpoints for the speed-test screen. The user does not override them (though they can switch the active server).

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
  "stream_options":  [1, 4, 10],   // the parallel-stream choices in the UI
  "default_streams": 4
}
```

The current template holds ten servers (Cloudflare, Selectel, Hetzner, OVH and others).
`id` is a stable machine id (§279): the runtime choice of server on the speed-test screen
is keyed by it rather than by index; an unknown id falls back to the default (the first server).

---

## `group_templates` and `default_channels` — the channel assembly templates (§267)

> **§125/§267 — the channels live in storage; the template only seeds them.** The
> channels moved into storage (`channels[]`, see
> [STORAGE.md](STORAGE.md#channels--125-the-routing-channels-templatestorage)). On the
> first launch a one-shot migration seeds `channels[]` from `default_channels` plus
> `group_templates.channel`; after that the set of channels lives in storage and is
> edited by the user. The builder reads `channels[]`, not the template. `auto` is not a
> channel but a subgroup: each channel produces its own `<tag>-auto` twin (a urltest)
> whenever `channel.include ∋ auto`.
>
> **§267 replaced the flat `preset_groups[]`** (three heterogeneous entries plus the
> fake variable `@auto_proxy_tag`) with three parts:
> - `magic_nodes` — a registry of the service nodes (auto/direct/block), keyed by role;
> - `channel` and `auto` — the templates for assembling a channel and its urltest subgroup;
> - `default_channels` — a flat list of channels for the seed.
>
> **The seed → `channels[i]` mapping** (the one-shot migration):
>
> | template | channels[] |
> |---|---|
> | `default_channels[i].tag` | `tag` (vpn-1 is forced to `enabled=true`) |
> | `default_channels[i].label` | `label` (empty falls back to `tag`) |
> | `default_channels[i].default_enabled` / legacy `enabled_groups[]` | `enabled` |
> | `channel.include` ∋ `direct` | `include_direct` |
> | `channel.include` ∋ `auto` | `auto` (a ChannelAuto built from the `auto` template plus the `@urltest_*` vars) |
> | `channel.include` ∋ `block` | `include_block` (absent from the default → false) |
> | `channel.options.interrupt_exist_connections` | `interrupt_exist_connections` |
> | (not from the template) | `node_filter` and `default_filter` are `''` |
>
> Every channel is assembled from the **shared** `channel` template (one `include`);
> they differ only in `tag`, `label` and `default_enabled` from `default_channels`.

### `magic_nodes` — the registry of service nodes

The service nodes (auto/direct/block) are declared by role key. `magic_nodes.*.tag` is the
source of truth for the tags; the const mirrors `kAuto/Direct/BlockOutboundTag` in
`consts.dart` are checked against it on load (`assertMagicNodeMirrors` — a divergence is a
`StateError`, so that renaming a tag in the template cannot break routing silently).

```jsonc
"magic_nodes": {
  "auto":   { "title": "Auto",   "source": "generate", "tpl": "{parent_tag}-auto" },
  "direct": { "title": "Direct", "source": "preset",   "tag": "direct-out" },
  "block":  { "title": "Block",  "source": "preset",   "tag": "block" }
}
```

| Key | Type | Purpose |
|---|---|---|
| `title` | string | The UI label of the service node (the Home node display). |
| `source` | `"generate"` \| `"preset"` | How the node comes into being: `generate` means the builder synthesizes one per channel, `preset` means it references an existing outbound. |
| `tag` | string? | (preset) A reference to an existing outbound in `config.outbounds`. Absent for `generate`. |
| `tpl` | string? | (generate) The tag template of the synthesized node. `{parent_tag}` expands to the parent channel's tag. |

### `channel` — the template of an ordinary channel (a selector)

```jsonc
"channel": {
  "type": "selector",
  "include": ["direct", "auto"],   // the magic_nodes role keys shown in the selector
  "options": { "interrupt_exist_connections": true }
}
```

`include` holds `magic_nodes` role keys, not tags. `block` is not part of the default.

### `auto` — the template of the auto subgroup (a urltest)

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

`options` is a raw template (the `@urltest_*` placeholders are resolved later, in the
builder or the seed). The parameters go into every channel's `<tag>-auto` twin that has
`channel.include ∋ auto`.

### `default_channels[]` — the first-launch channel seed

```jsonc
"default_channels": [
  { "tag": "vpn-1", "label": "VPN ①", "default_enabled": true  },
  { "tag": "vpn-2", "label": "VPN ②", "default_enabled": false }
]
```

The template holds only **two seed channels** (`vpn-1` and `vpn-2`). Further channels (up to
`vpn-10`, `kMaxChannels = 10`) are created by the user in storage (`channels[]`).

| Key | Type | Purpose |
|---|---|---|
| `tag` | string | The channel's immutable id (`vpn-1`..`vpn-10`). |
| `label` | string | The UI display name (empty falls back to `tag`). |
| `default_enabled` | bool | Affects only the first-launch seed. After the migration, being enabled is decided by `channels[i].enabled` in storage. |

The storage source of truth is `channels[]` in `lxbox_settings.json` (§125). The legacy `enabled_groups[]` is **DEPRECATED** — it is read only by the one-shot migration into `channels[]` and as a fallback seed when `channels[]` is empty (see [STORAGE.md](STORAGE.md#channels--125-the-routing-channels-templatestorage) and the callout above).

---

## `sections[]` — Wizard UI chapters (§022)

How the template vars are grouped in the Wizard UI (App Settings → Configuration). Each section is a separate card.

```jsonc
[
  {
    "id":          "general",               // a stable machine id (§279, the l10n address)
    "name":        "General",
    "chapter":     "core",                  // the grouping tag (the UI tabs)
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

The current template has eight sections: `General`, `Network`, `Internal`, `Auto Proxy`, `DNS`, `TUN`, `VPN Mode` and `DPI Bypass`. How they are distributed across screens is described below.

`id` is a stable kebab-case machine id (§279): `general`, `network`, `internal`,
`auto-proxy`, `dns`, `tun`, `vpn-mode`, `dpi-bypass`. It serves as the l10n overlay's
address for the display fields (`name` and `description`). The internal join key between
a section and its vars remains `name` (`parser_config.dart`, `settings_screen.dart`) —
`id` does not replace it.

### `chapter` — who renders the section

`chapter` is the category of the owning screen. A screen requests its sections through
`WizardTemplate.sectionsFor(chapter)` / `varsFor(chapter)` (`parser_config.dart`).
A section whose chapter no screen requests **never appears in the UI at all** (but its
vars stay in `template.vars`, so the builder and the ref resolution still see them).

| `chapter` | Rendered on | Sections |
|---|---|---|
| `core` | VPN Settings (App Settings → Configuration) | General, Network, TUN, VPN Mode, DPI Bypass |
| `routing` | Routing screen | Auto Proxy |
| `dns` | DNS Settings screen | DNS |
| `internal` | **nowhere** (§265) | Internal |

### `internal` — the service section (§265)

The `Internal` section (chapter `internal`) holds vars that **must not** be shown in VPN
Settings but must exist globally: the builder substitutes them, and presets reference them
through a **ref-var** `{"ref":"<name>"}` (§265, see `selectable_rules`). No screen requests
the `internal` chapter, so the section is never rendered; meanwhile the vars sit in
`template.vars`, so `@name` substitution and ref resolution work. The user edits them
**through the owning preset** (for example `resolve_enabled` and `resolve_strategy` live in
the `traffic-processing` rule, which pulls them in as ref-vars).

| Var | Type | Purpose |
|---|---|---|
| `resolve_enabled` | bool | §263 — the gate for the route-resolve rule of the `traffic-processing` preset (turn it off for FakeIP). Changed through the rule. |
| `resolve_strategy` | enum | The IP version for route-resolve (`ipv4_only` / `prefer_ipv4` / …). Written by the toggle's on_change. |

> **Why `internal` rather than `wizard_ui: hidden`.** `hidden` conceals a var inside its
> chapter's section, but the section still belongs to a screen that renders (VPN
> Settings). The `internal` chapter takes the var out from under every screen entirely —
> its only editing point is the preset that references it.

The `VPN Mode` section is entirely `wizard_ui: hidden` (build-time vars, not shown in the UI). Its seven variables are edited on their own screen (VPN Mode), not through the Wizard.

| Var | Type | Purpose |
|---|---|---|
| `vpn_mode` | enum | `vpn` / `proxy` / `vpn_proxy` — which inbounds to raise |
| `proxy_type` | enum | The type of the proxy inbound (`mixed`, …) |
| `proxy_listen` | text | The proxy's listen address |
| `proxy_port` | int | The proxy's listen port |
| `proxy_user` | text | The username (when auth is on) |
| `proxy_pass` | secret | The password (when auth is on; a `secret` is never coerced) |
| `proxy_auth` | bool | Include `users[]` in the proxy inbound |

### `vars[i]` — the description of a template variable

| Ключ | Тип | Назначение |
|---|---|---|
| `name` | string | The variable's name. An `@name` inside the template's `config` block is replaced by its value. |
| `type` | enum | The input type — it decides the UI control and the validation. See below. |
| `default_value` | any | The default when the user has not overridden it through the UI or `PUT /settings/vars/...`. |
| `required` | bool? | When true, an empty value is forbidden. |
| `options[]` | list? | For the `enum` type, the choices. Either `[string, ...]` or `[{title, value}, ...]`. |
| `wizard_ui` | `"edit" \| "fix" \| "hidden"`? | The display mode in the Wizard UI. `hidden` is an internal var (not shown); `fix` is read-only. |
| `title` | string? | The display label in the UI. |
| `tooltip` | string? | The help text shown when the info icon is tapped. |
| `on_change` | object? | §232 — a declarative side effect when the var is toggled (in memory, `VarValuesModel`). |

### `var.type` values

Seen in the template:

| Type | Coerced into the config (§120) | UI control |
|---|---|---|
| `text` | **the string verbatim** | TextField |
| `int` | `int.tryParse` (a non-number stays a string) | TextField |
| `bool` | `'true'` becomes true, anything else false | Switch |
| `enum` | **a string** (membership in `options[]` is advisory) | Dropdown |
| `secret` | **the string verbatim** (never coerce it) | TextField (masked) |
| `outbound` | **a string** (a selector or node tag) | A dropdown filled at runtime |
| `dns_servers` | **a string** (a tag from `dns_options.servers`) | A dropdown filled at runtime |

> **§120 — coercion follows the declared type, NOT the content.** `if_engine.dart::coerceVarValue` coerces a value by the `var.type` from the template; the string `"true"` in a `text` var stays a string, while `"1"` in an `int` var becomes a number. That way the value in the config is predictable from the declaration rather than from how it happens to look.

When extending it (adding a new type), update the Wizard UI renderer in `app/lib/screens/settings_screen.dart` and the coercion logic in `if_engine.dart`.

### `on_change` — a var's declarative side effect (§232 / §266)

Toggling a var can set derived vars. The syntax reuses the existing `#if` (value/else),
and the condition already sees the NEW value of the toggled var. What follows is the
section-level variant (§232, in memory); the preset-level one (§266, the global
`userVars`) is described under “A preset's `on_change`”.

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

> **§264/§265 — `resolve_strategy` lives globally in the `internal` section**, while
> the route-resolve rule moved into the locked `traffic-processing` preset (see §264
> below). The preset references it through the ref-var `{"ref": "resolve_strategy"}`
> (§265): both the metadata and the value come from that global, and `@resolve_strategy`
> inside the rule resolves globally. The `on_change` above (the IPv6 toggle, chapter
> `core`) still writes it globally into `userVars`, and the preset sees the effect. The
> `sniff_enabled` var became a var of the `traffic-processing` preset itself, and
> `resolve_enabled` moved into `internal` (§265) — its §263 toggle is edited inside the
> preset's rule rather than in a section.

The current semantics of the IPv6 toggle (§249): both strategy vars default to
`ipv4_only` (IPv6 on the tun is off by default — applications do not need AAAA); enabling
IPv6 moves resolution to `prefer_ipv4` (v6 is available, but v4 first — on networks with
half-working v6, `prefer_ipv6` produced dead direct connections, see §246); disabling it
forces `ipv4_only`. Fine tuning lives in DNS Settings → Strategy (the toggle is a one-off
effect, not a lock).

The semantics:

- **A one-off effect of the toggle, not a lock** — the target vars are written at the
  moment of the click; afterwards the user is free to override them by hand.
- **In memory only** — the targets are written into the screen's reactive `VarValuesModel`
  (a per-key `ValueNotifier`; each `TemplateVarListView` field subscribes to its own key
  and updates instantly). Storage is touched ONLY by the shared write-on-exit
  (`_persist` over `dirtyKeys`) — a user who leaves before exiting the screen (a
  force-kill) has saved nothing. See ARCHITECTURE.md → “VarValuesModel”.
- **Chains** — if a target var has its own `on_change`, it is applied recursively; a
  fixpoint guard breaks the cycle: writing an unchanged value stops it.
- **The values are string literals.** An `#if` node is evaluated by the engine through
  `evalIfScalar` (`if_engine.dart`) and NOT through `walk` directly: a bare map
  `{"#if":…}` sent through `walk` falls into map-spread mode and collapses the scalar to `{}`.
- **Cross-screen targets** (for example `dns_strategy`, chapter `dns`, rendered on the
  DNS Settings screen): there is NO live update on the other screen (the model is
  per-screen); the value arrives through the cache the next time that screen opens. The
  screens are never co-mounted, so the user never sees the divergence.

### A preset's `on_change` — reacting to being enabled or disabled (§266)

`on_change` lives not only on section vars but on a **preset's vars** too. The difference
from §232 is in the source and the sink:

| | §232 (a section) | §266 (a preset) |
|---|---|---|
| **Trigger** | a click on a var in the Wizard screen | a change of the preset's state (the on/off switch, the dns_enable toggle) |
| **Source** | the var's own value (`VarValuesModel`) | **the preset's state** — the pseudo-vars `@rule_enable` / `@dns_enable` |
| **Sink** | the screen's in-memory `VarValuesModel` | **the global `userVars`** (`SettingsStorage.setVar` — straight to disk) |
| **Engine** | `settings_screen._applyOnChange` | `preset_on_change.dart::applyPresetOnChange` |

**The preset's pseudo-vars** (never stored — computed from its state):

- `@rule_enable` = `cr.enabled` (the preset is on, via the switch).
- `@dns_enable` = the §257 `presetDnsEnableVar` (the preset's DNS aspect — the master
  toggle of the DNS block).

Both carry an **identical** on_change formula, so either of them triggers a recomputation
of the targets (that way the formula fires both when the routing switch changes and when
the DNS toggle does). Resolution happens in the namespace
`{...userVars, rule_enable, dns_enable}` (the pseudo-vars shadow `userVars`, since their value is the live one), through the same `evalIfScalar`.

An example — the FakeIP preset silences route-resolve while it is active (route-resolve is
a SECOND resolver that bypasses FakeIP through `default_domain_resolver`; with FakeIP
active it must stay quiet, §263):

```jsonc
// both vars of the fakeip preset carry this; @resolve_enabled is a var of the internal section
"on_change": {
  "set": {
    "@resolve_enabled": {"#if": {"and": ["@rule_enable", "@dns_enable"], "value": "false", "else": "true"}}
  }
}
```

Read it as: “FakeIP is on (`@rule_enable`) AND its DNS aspect is on (`@dns_enable`)
→ `resolve_enabled = false`; otherwise `true`.”

The semantics:

- **It writes into `userVars` immediately** (not in memory) — the target
  `@resolve_enabled` lives in the `internal` section (a global var), and its storage is
  `userVars` rather than the preset's `varsValues`. It is event-driven rather than
  declaratively permanent: it fires at the moment of the change, and the user is then free
  to override it inside the `traffic-processing` rule.
- **It is called from ALL five places** where `rule_enable` / `dns_enable` change:
  creating a preset (`routing_screen._copyPreset`), the routing switch toggle
  (`routing_screen` plus the editor's `edit_controller.onBoolVarToggle`), the dns_enable
  toggle in the rule editor, and the one **in DNS Settings**
  (`dns_settings_screen._togglePresetDnsEnable`). Miss any of them and the target is not
  recomputed along that path.
- **It is idempotent** — `setVar` overwrites, so calling it again with the same state
  yields the same value.

> **A §266 gotcha (caught on a device).** A pseudo-var (`rule_enable` / `dns_enable`)
> **must** carry a `default_value` plus `required: false`. In the sing-box schema a var
> with no `default_value` is **required**; with an empty value `expandPreset` returns early
> (“required var … unset”) and **the preset's entire DNS block is silently not emitted**
> (FakeIP never wrote its `dns_rules`, so DNS was not intercepted). The symptom is quiet —
> the preset is there in the UI but does nothing. See `29fe61c`.

---

## `config` — the native sing-box section

The base of the final sing-box config. It carries `@var` placeholders; the substitution happens at build time in `build_config.dart`.

```jsonc
{
  "log": {
    "level":     "@log_level",
    "timestamp": true
  },
  "dns": {
    "servers":  [],                              // empty; filled in from dns_options.servers plus selectable_rules[].dns_servers
    "rules":    [],                              // empty; filled in from dns_options.rules plus selectable_rules[].dns_rules
    "final":    "@dns_final",
    "strategy": "@dns_strategy"
  },
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "interface_name": "...", "address": "...", "mtu": ..., "auto_route": ..., "strict_route": ..., "stack": "..."}
  ],
  "endpoints": [],                               // wireguard endpoints (from server_lists user nodes)
  "outbounds": [
    {"type": "direct", "tag": "direct-out"},     // base
    {"type": "block",  "tag": "block"}           // the §201 drop-out; the rest is added by the builder
  ],
  "route": {
    "find_process":            true,
    "default_domain_resolver": "@dns_default_domain_resolver",
    "rules": [
      // §264: route.rules is EMPTY in the template. The base sniff/hijack-dns/resolve
      // rules MOVED into the locked traffic-processing preset (first in selectable_rules,
      // num:0 → the builder puts its rules first in the final route.rules).
      // The order (sniff BEFORE resolve) is critical for FakeIP: sniff extracts the domain
      // before resolve (resolving a fake 198.18.x.x IP is meaningless). Each of the three
      // rules is wrapped in an #if inside the preset: @sniff_enabled / (the dns protocol
      // for hijack-dns) / @resolve_enabled (off for FakeIP — the real lookup bypasses
      // FakeIP through default_domain_resolver). See the selectable_rules section below.
    ],
    "final":                  "vpn-1",
    "auto_detect_interface":  "@auto_detect_interface"
  },
  "experimental": {
    // clash_api was REMOVED in §122 (the CommandClient migration). Control goes through
    // the libbox CommandClient, not an HTTP Clash API. The core is built WITHOUT
    // with_clash_api: an experimental.clash_api block in a custom template is a FATAL
    // startup failure ("clash api is not included in this build"). Do not add it.
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
    "num":         <int>?,              //   §370 — ось порядка, см. ниже.
    "isSortable":  <bool>?              //
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

С §264 label/description/default/locked (+ §370 num/isSortable) живут в объекте
`ui` (**ОБЯЗАТЕЛЕН**;
плоские top-level `label`/`description`/`default` из шаблона убраны, fallback в
`SelectableRule.fromJson` снят — читается только `ui`). Все 8 пресетов переведены на `ui`.

| `ui.*` | Тип | Назначение |
|---|---|---|
| `label` | string | UI display. |
| `description` | string | Тултип. |
| `default` | bool? | default true → включён в новой установке. |
| `locked` | bool? | §264 — пресет **нельзя выключить** (свич disabled) и **нельзя удалить**. Ортогонален `isSortable` (тот про drag). Единственный locked-пресет — `traffic-processing`. |
| `num` | int? | §370 — позиция на **разреженной оси порядка правил**. Раскладка: `0` голова (traffic-processing), `950..990` специфичные пресеты, `1000..1100` зона пользовательских правил, `1110..1150` широкие перехватчики. Шаг 10 между шаблонными — зазор под будущие вставки. Это **стартовая** позиция: юзер двигает drag'ом, `num` пересчитывается и живёт в storage (`custom_rules[].num`). Дефолт при отсутствии — `1000`. |
| `isSortable` | bool? | §370 — можно ли двигать правило drag'ом. `false` = позиция закреплена, drag-handle скрыт; такой пресет ещё и **сидится принудительно** (`seedRequiredPresets`), т.к. его присутствие — продуктовый инвариант. Единственный несортируемый — `traffic-processing` (`num:0`): он несёт `sniff`, который обязан быть первым правилом `route.rules`. Дефолт — `true`. |

### Полевая матрица текущих 8 preset'ов

Метаданные — из `ui.*` (§264/§370): `default`/`locked`/`num`/`isSortable`.
`traffic-processing` — первый в каталоге (locked, num:0, isSortable:false), несёт
базовые sniff/hijack-dns/resolve.

| `preset_id` | `ui.default` | `ui.locked` | `ui.num` | `vars` | `rule_set` | `rule(s)` | `dns_rule(s)` | `dns_servers` |
|---|---|---|---|---|---|---|---|---|
| `traffic-processing` | true | true | 0 | ✓ (sniff_enabled, sniff_timeout §264 enum 100ms/300ms/500ms/1s/3s, hijack_dns_enabled §264 bool WARNING-тултип, `{"ref":"resolve_enabled"}` + `{"ref":"resolve_strategy"}` §265 — обе ref на секцию `internal`) | — | ✓ массив: `[sniff #if @sniff_enabled, hijack-dns, resolve strategy:@resolve_strategy #if @resolve_enabled]` | — | — |
| `block-ads` | false | — | — | — | ✓ (remote ads-all) | ✓ (action: reject) | — | — |
| `ru-direct` | true | — | — | ✓ (outbound, dns_enable §257, dns_server, dns_ip, geoip_enabled, force_ipv4) | ✓ (inline `.ru` suffixes) | ✓ массив: `[resolve ipv4_only #if @force_ipv4, @outbound]` (§246) | ✓ массив: `[predefined-NOERROR ip_version:6 #if @force_ipv4, → @dns_server]` (§253) | ✓ (yandex_udp/doh/dot) |
| `fakeip` | false | — | — | ✓ (rule_enable §266 псевдо + on_change, dns_enable §257 + on_change, dns_server — **hidden**) | — | — | ✓ (`query_type: [A,AAAA]` → `@dns_server`) | ✓ (type `fakeip`, ranges 198.18/15 + fc00::/18) |
| `ru-inside` | (false) | — | — | ✓ (outbound, force_ipv4) | ✓ (remote ru-inside) | ✓ массив: `[resolve ipv4_only #if @force_ipv4, @outbound]` (§246) | — | — |
| `bittorrent` | true | — | — | ✓ (outbound) | — | ✓ (`protocol: bittorrent` → `@outbound`) | — | — |
| `private-ip` | (false) | — | — | ✓ (outbound) | — | ✓ (`ip_is_private` → `@outbound`) | — | — |
| `unknown-traffic` | false | — | — | ✓ (`outbound`=reject) | ✓ (inline `unknown-apps`, invert `package_name_regex: "^"`) | ✓ (`@outbound`) | — | — |

**`traffic-processing` (§264/§370)** — locked + несортируемый пресет, ПЕРВЫЙ в `selectable_rules`. Несёт базовые route-правила `sniff` / `hijack-dns` / `resolve`, которые до §264 жили прямо в `config.route.rules` (теперь пуст). `num:0` + `isSortable:false` гарантируют, что его правила идут первыми в финальном `config.route.rules` (sniff обязан быть первым — извлекает домен до resolve, критично для FakeIP). `locked:true` — свич disabled, нельзя удалить; `isSortable:false` — нельзя двигать. Каждое из трёх правил гейтится собственным `#if` (array-element form): `sniff #if @sniff_enabled` / `hijack-dns` (безусловно) / `resolve #if @resolve_enabled`. Vars пресета: `sniff_enabled` (bool), `sniff_timeout` (enum 100ms/300ms/500ms/1s/3s — НОВАЯ, дефолт `300ms`, раньше был хардкод `timeout:"1s"`), `hijack_dns_enabled` (bool — НОВАЯ, WARNING-тултип: off ломает FakeIP), `{"ref":"resolve_enabled"}` + `{"ref":"resolve_strategy"}` (§265 ref-vars — значение и метаданные из глобалей `resolve_enabled`/`resolve_strategy`, обе живут в секции `internal`, редактируются прямо здесь). Отключение `hijack_dns_enabled` убирает hijack-dns-правило; ⚠ без hijack-dns DNS-запросы не перехватываются → FakeIP не работает. `resolve_enabled=false` нужен для FakeIP (real-lookup идёт мимо FakeIP через `default_domain_resolver`, §263) — при включении FakeIP этот флаг гасится **автоматически** через on_change пресета `fakeip` (§266, см. «`on_change` пресета» выше). Нормализация `rule_order.dart` (§370) держит пресет в наличии и на позиции 0 при fresh install / restore / upgrade.

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
> (`rule_order.dart`) вычищает ref-ключи из `varsValues` на загрузке
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

Метаданные пресета (`label`/`description`/`default`/`locked`/`num`/`isSortable`) —
**одна строка**, если влезает; иначе `label`/`description` на строке 1, флаги —
строкой ниже. Флаги-`false` и `isSortable:true` НЕ пишем (дефолты модели); `num`
пишем всегда — это часть раскладки оси.

```jsonc
"ui": {"label": "Traffic Processing", "description": "...", "default": true, "locked": true, "num": 0, "isSortable": false}
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

## Локализация display-текста — l10n overlay (§279)

`wizard_template.json` остаётся **единственным структурным шаблоном** с
английским display-текстом. Переводы не форкают структуру — это плоские
overlay-файлы, патчащие декодированный JSON **до парсинга и до
preset_expand-снапшотов** (`TemplateOverlay.apply`, зовётся из
`TemplateLoader`; кэш loader'а ключуется тегом локали):

```
app/assets/l10n/ru/template.json   # ручной перевод (тот же shape, что UI-словарь)
```

Английский display-текст живёт в самом `wizard_template.json` (базовый язык, в
коде) — отдельного en-файла нет. Ключ overlay = **сам английский текст**
display-поля (тот же принцип, что natural-key UI-словарь
`assets/l10n/<tag>/ui.json`), а не структурный адрес.
`TemplateOverlay.apply` ходит по whitelist-схеме шаблона, читает английское
значение узла и подменяет его переводом по этому тексту.

- Английские ключи — базовый язык, в коде: коммитнутого/генерируемого en-файла
  нет. `template_check` извлекает их живьём из `wizard_template.json` через
  `TemplateOverlay.extract()` на каждом прогоне и валидирует каждый overlay
  локали против этой экстракции. Повторяющийся один и тот же английский текст в
  разных местах шаблона схлопывается в один ключ (фича, не конфликт).
- `template.json` (и любой будущий `<lang>/template.json`) — тот же объектный shape, что
  UI-словарь: `{ "<english>": { "value": "<перевод>" } }`:

  ```json
  "DNS server": { "value": "DNS-сервер" }
  ```

  Изменился en-текст → сменился ключ: старая запись становится unknown-key (fail
  `template_check`), новый английский ключ — missing (warn, strict→fail).
  Workflow идентичен UI-строке: переименовать ключ, пересмотреть перевод.

**Схема обхода** (полная таблица — [§279 spec, §3.2](./spec/features/279%20localization/spec.md)):
applier посещает display-поля секций, глобальных и rule-локальных vars, magic-нод,
каналов, dns-серверов, ping/speed-пресетов. Не посещается (whitelist applier'а):
всё под `config`/`parser_config`, `name`/`tag`/`value`/`default_value`/`preset_id`,
bare-string enum-опции, `dns_options.rules[].name` (латентный identity-ключ) —
поэтому эти строки в overlay не попадают.

**Load-bearing запреты**: перевод, начинающийся с `@`, был бы интерпретирован
как var-ссылка (overlay применяется до `substituteVars`); `{` ломает parsing —
оба запрещены `template_check` безусловно. Fallback per-key тихий (нет ключа →
английское значение); отказ целого файла — громкий (`AppLog.error` +
debug-assert + flutter-тест rootBundle-загрузки каждого overlay).

### Добавляем display-поле в шаблон

Новое user-visible поле обязано попасть в **экстрактор + whitelist**
`TemplateOverlay` (`template_overlay.dart`) — иначе оно тихо шипится
английским во всех локалях. Self-check `template_check` следит, чтобы whitelist
покрывал каждое display-поле экстрактора (английский ключ извлекается живьём из
`wizard_template.json`, отдельного en-файла нет); после добавления — перевод в
`ru/template.json`, `flutter test` (applier-тесты).

---

## Когда что ломается

### Добавляем новый top-level ключ

Update этого файла (раздел top-level + новый section per-key) + добавляем читалку в builder/loader. Проверяем что `template_loader.dart` парсит без ошибок (текущий парсер permissive — игнорирует unknown keys).

### Меняем shape preset'а / vars

Если breaking — bump `parser_config.version` (это сигнал для миграционного кода). Описать миграцию в [§026 parser v2 spec](./spec/features/026%20parser%20v2/spec.md) или новой спеке.

### Добавляем var с новым `type`

Update var.type таблицу в этом файле + добавить рендерер в `settings_screen.dart`.

### Меняем `config.route.rules` базовые правила

С §264 базовых правил в `config.route.rules` **больше нет** (ключ пуст) — sniff/hijack-dns/resolve переехали в locked-пресет `traffic-processing` (`num:0`). Правь их **там**, не в `config.route.rules`. Порядок первых правил критичен (sniff первым) — `num:0` + `isSortable:false` + `rule_order.dart` держат пресет на позиции 0. Любое новое базовое route-правило для всех юзеров либо кладётся в этот пресет, либо (если условное) — как preset-rule. Может сломать routing для существующих юзеров — **проверять** порядок относительно auto-discovery preset-rules. См. order matters в [§030].

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
- [§279 localization](./spec/features/279%20localization/spec.md) — l10n-overlay display-текста шаблона; ключ overlay = сам английский текст (принцип `ui/`-словаря, `{value}`-формат, без адресов и `src`-hash — §285); translator-guide — [`l10n.md`](./l10n.md)
