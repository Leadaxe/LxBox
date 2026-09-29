[English](config-template.md) · [Русский](config-template.ru.md)

# Config template — the shipped template that defines settings, skeleton and presets

One template file shipped with the app declares every config setting with its type and screen, the
core config skeleton and the preset catalog.

| Field | Value |
|------|----------|
| Feature | [003-CONFIG_BUILD](../FEATURE.md) |
| Promises | P4 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Gives the build a single source of structure and defaults: the file
`wizard_template.json` shipped inside the app. It declares which
settings exist, what type they are and where they are shown, what the
core config skeleton looks like and which presets can be enabled. Settings screens and
the build read the same template — the default on the screen and in the config
match by construction.

## Parameters

Top-level template sections:

| Section | What it carries | Whose feature fills it |
|---|---|---|
| `sections[]` | Variable cards: `id`, `name`, `chapter`, `description`, `vars[]` | this one (the mechanism), section owners |
| `config` | The core config skeleton with `@var` and conditions | this one |
| `selectable_rules[]` | The preset catalog | [004-ROUTING](../../004-ROUTING/FEATURE.md) |
| `dns_options` | The catalog of DNS servers and rules | [005-DNS](../../005-DNS/FEATURE.md) |
| `group_templates`, `default_directions` | Direction group templates, the starting set | [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md) |
| `ping_options`, `speed_test_options`, `parser_config` | Probe and parse parameters | 009, 002 |

A section's `chapter` decides which screen draws it: `core` — VPN Settings,
`routing` — the routing screen, `dns` — the DNS screen, `internal` — nowhere
(global variables edited only via a preset by reference).
A variable's `wizard_ui`: `edit` — a field, `fix` — read-only in the shared
list (edited on its own screen), `hidden` — not shown.

Current sections: General, Network, Internal, Auto Proxy, DNS, TUN, VPN Mode,
TLS Fragmentation. There are 11 presets; the first is `traffic-processing` (pinned,
cannot be disabled or moved, its rules go first in `route.rules`).

Preset metadata is the `ui` object: `label`, `description`, `default`
(enabled on a clean install), `locked`, `num` (place on the order axis),
`isSortable`. Preset body: `vars`, `rule_set`, `rule`/`rules`,
`dns_rule`/`dns_rules`, `dns_servers`, `for_each`.

## Inputs / Outputs

**Inputs:** the template file from the shipment; an overlay of display texts for
the active language.
**Outputs:** the loaded template model for screens and the build; a load error
on a malformed construct.

## Rules and invariants

- The template is loaded once per language; changing the language does not poison the cache of another
  language. English is the template itself, there is no overlay for it.
- The overlay changes only display fields (`name`, `description`, `title`,
  `tooltip`, option and preset labels), not data. A key missing in the
  overlay — silently the English text; an unreadable overlay file as a whole —
  an error in the log and the English template instead of a crash.
- At load all conditional constructs (`#if`, `#enable`,
  `#on_change`, `for_each.filter`, DNS server body placeholders) are checked against the
  declared variables. A violation is a load error: it is a defect of the
  shipment, not of user data.
- Exception: a preset whose `for_each` has no `node_type` or `as`
  is removed from the list alone, with a log entry; the template works.
- A template DNS server's variable is visible only to its body; global
  variables are not visible to the server body.
- The `internal` section does not appear on screens, but its variables take part
  in substitution and are available to presets by reference.

## Boundaries

- The language of constructs inside the template — [template language](template-language.md).
- The contents of specific presets, the DNS catalog, group templates — the owning
  features from the table above.
- There is no user template: the template comes only with an app
  update.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [058](../../../tasks/058-config-generator-wizard-v1-superseded/spec.md) | Superseded as to the build | The wizard template as the config source |
| 2 | [120F](../../../tasks/120F-template-engine-typed-vars-and-if/spec.md) | Implemented | Checking conditional constructs at template load |
| 3 | [264](../../../tasks/264-traffic-processing-preset.md) | DEVICE-VERIFIED | The pinned `traffic-processing` preset, preset metadata in `ui` |
| 4 | [265](../../../tasks/265-ref-vars.md) | DEVICE-VERIFIED | The `internal` section, variables by reference only |
| 5 | [279F](../../../tasks/279F-localization/spec.md) | — | Overlay of template display texts by language |
| 6 | [370](../../../tasks/370-rule-order-num-axis.md) | Spec (implementation in the task) | The order axis `ui.num` and `ui.isSortable` |
| 7 | [555](../../../tasks/555-template-lang-spec143-parity.md) | Done (items 1–6) | Template language parity with the launcher |
| 8 | [578](../../../tasks/578-tailscale-preset-template-for-each.md) | Spec. Implementation started | An incomplete `for_each` removes only its own preset |
| 9 | [580](../../../tasks/580-dns-cache-settings.md) | Done | DNS cache variables with bounds |
