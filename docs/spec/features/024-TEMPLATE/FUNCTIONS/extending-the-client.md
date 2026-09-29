[English](extending-the-client.md) · [Русский](extending-the-client.ru.md)

# Extending the client — adding a capability through the template

A new preset, DNS server, variable or rule set is added to LxBox by editing the shipped template;
code is written only when the template language itself needs a new construct or a screen needs
a new kind of field.

| Field | Value |
|------|----------|
| Feature | [024-TEMPLATE](../FEATURE.md) |
| Promises | — (a process; the behaviour it relies on is promised by the other functions) |
| State | ✅ written from code, 2026-09-29 |

## What it does

Fixes the procedure "a new capability through the template": what is added
without code, what requires code, in which order the work goes and which
documents change. The template text is shared with the desktop launcher, so
the procedure has two sides: the app repository and the launcher contract.

## Parameters

**Added without code** (a template edit, tests and localization only):

| Capability | What goes into the template | Real example |
|---|---|---|
| A preset | a `selectable_rules[]` entry: `preset_id`, `ui`, `vars`, `rule`/`rules`, `rule_set`, DNS parts | [371](../../../tasks/371-vowifi-direct.md) VoWiFi — "the code is not touched"; [364](../../../tasks/364-fcm-push-bypass-preset.md) Google push (FCM) — template, ru overlay, three expansion tests |
| A rule set inside a preset with a switch | `rule_set[]` entry with `#enable: ["@flag"]`, a `bool` variable, the rule referring to the set | [531](../../../tasks/531-ru-app-list-ruleset-in-ru-preset.md) Russian apps by package in Ru internet segment |
| A DNS catalog server | a `dns_options.servers[]` entry with `server` body and optional `vars` | [527](../../../tasks/527-dns-shield-yandex-dot-base.md) `yandex_dot` as a base record |
| A variable with a field on a generic screen | a `sections[].vars[]` entry with `wizard_ui: edit` and a `@var` or `#if` in the skeleton or a preset | the `tun_*`, `log_level` variables |
| A ref variable in a preset | `{"ref": "<global>"}` in the preset's `vars[]`; the global exists (an `internal` section if it must not be shown) | [264](../../../tasks/264-traffic-processing-preset.md) `resolve_strategy` in Traffic Processing |
| An `on_change` reaction | `#on_change: {#set: {...}}` on a variable or on the preset pseudo-variables `rule_enable` / `dns_enable` | `ipv6_enabled` → strategies; FakeIP → `resolve_enabled` |
| A per-node preset | `for_each{node_type, as, filter}`, `@node`, `#tpl` in the body | the `tailscale` preset ([578](../../../tasks/578-tailscale-preset-template-for-each.md)) |
| A changed default or text | `default_value`, `title`, `tooltip`, `ui.label`; the overlay keys follow the English text | — |

**Requires code** (the template edit is only part of the change):

| Need | Why code | Real example |
|---|---|---|
| A new language construct | engine, load-time validator, model, corpus, the launcher norm | [578](../../../tasks/578-tailscale-preset-template-for-each.md) `for_each`/`@node`/`#tpl`; [265](../../../tasks/265-ref-vars.md) `ref`; [264](../../../tasks/264-traffic-processing-preset.md) the `ui` object, locked/pinned |
| A variable on a dedicated screen or with bounds | `wizard_ui: fix` is rendered by that screen; `int` bounds are not in the template | [580](../../../tasks/580-dns-cache-settings.md) DNS cache variables on the DNS tab, 1024..65535 |
| A variable of a new `type` | a renderer on the settings screen, coercion | — |
| A new top-level template key | a reader in the build | — |
| A variable that must mark the config stale | the list of config variable names is fixed in code (audit 588: 18 variables are missing from it) | — |
| A preset that must reach users with saved state | the late-defaults list | [578](../../../tasks/578-tailscale-preset-template-for-each.md) `tailscale` |
| A new record field (a node field a preset reads) | storage, backup, Debug API, transfer | `skip_presets` ([578](../../../tasks/578-tailscale-preset-template-for-each.md)) |
| A core config key | the installed core must accept it; checked against the core sources or the contract registry | [580](../../../tasks/580-dns-cache-settings.md) `dns.cache_capacity`, `dns.optimistic`, `store_dns` |

## Inputs / Outputs

**Inputs:** the owner's decision in a task; the current template; the
launcher norm and registry; the current overlay files.
**Outputs:** the edited template of both sides; a contract bump (norm,
registry, corpus) when the language or the shared preset text changes;
updated overlays, tests, golden fixtures and documents.

## Rules and invariants

The checklist, in order:

1. **Task first.** The owner's decision is recorded in `tasks/NNN-…` with the
   template fragment spelled out; the preset text is the same on both sides.
2. **Template edit** in `wizard_template.json` following the formatting style
   in `docs/TEMPLATE.md`; display texts in English; every new conditional
   construct refers only to declared variables, otherwise the shipped
   template is rejected at load ([P4](../FEATURE.md#promises)).
3. **Contract, if shared text or language changed:** a request to the
   launcher (a `TEMPLATE_LANG.md` section for a construct, `registry/vars.json`
   with `portable` for a variable that travels in transfer, a corpus case for
   engine behaviour); then `app/tool/sync_contract.sh` bumps the copy and the
   lock. A construct without a fixture is not done
   ([021-CORE_CONTRACT](../../021-CORE_CONTRACT/FEATURE.md)).
4. **Localization:** new or renamed display texts get keys in
   `assets/l10n/<tag>/template.json` for every shipped language; the key is
   the English text itself, so a changed text is a new key.
5. **Tests:** the shipped template passes load validation; an expansion test
   for a preset; golden storage and config fixtures when the emitted config
   changes; `on_change` and seeding tests when those are touched.
6. **Existing users:** decide seeding (late defaults for a new default
   preset; a non-sortable preset is re-seeded by itself), value migration
   (none — storage is keyed by name), the backup allowlist (template
   variables are accepted automatically; a new top-level key must be added
   to the allowlist and a backup category) and the Workspaces slot
   classification ([template lifecycle](template-lifecycle.md)).
7. **Documents:** `docs/TEMPLATE.md` (always: the section, the field matrix,
   the variable table); `TEMPLATE_LANG.md` in the launcher when the language
   changes; `docs/STORAGE.md` when a record field is added; the owning
   feature's revisions (this feature for language and catalog, 004/005/006
   for behaviour); an `F` spec marked superseded when the change replaces
   it; `CHANGELOG.md` Unreleased.
8. **Verification:** the emitted rule decodes with the core; behaviour on
   traffic is device-verified where an emulator cannot show it (FCM pushes,
   VoWiFi calls stay pending until then).

Invariants:

- A preset pseudo-variable with `#on_change` carries `default_value` and
  `required: false`; without them the preset silently emits nothing.
- A ref variable's target must exist in some section; a variable that must
  not be shown lives in `internal`.
- `reject` as a preset target is written as `outbound: "reject"` in the
  template and becomes `action: reject` in the build; no other pseudo-target
  exists.
- A `#if` on an object that already has one uses a suffix (`#if1`,
  `#if tun-only`).

## Boundaries

- Behaviour of what was added — the owning features (004, 005, 006, 016).
- The launcher side of the contract is edited in the launcher repository;
  this feature describes only the request and the sync.
- A user cannot extend the template: no user template, no user presets.

## Documentation

- [`docs/TEMPLATE.md`](../../../../TEMPLATE.md) — "What breaks when" and the
  formatting style; the target of every template change.
- `contract/docs/TEMPLATE_LANG.md` and `contract/corpus/template/` in the
  launcher repository — the language norm and fixtures (a copy arrives via
  `app/tool/sync_contract.sh`, not committed).
- [021-CORE_CONTRACT](../../021-CORE_CONTRACT/FEATURE.md) — how the contract
  is versioned and synced.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [264](../../../tasks/264-traffic-processing-preset.md) | DEVICE-VERIFIED | A preset with code: the `ui` object, locked/pinned, variables moved from a section |
| 2 | [265](../../../tasks/265-ref-vars.md) | DEVICE-VERIFIED | A language construct with code: `ref` |
| 3 | [364](../../../tasks/364-fcm-push-bypass-preset.md) | implemented; device pending | A preset without code: template, overlay, tests |
| 4 | [371](../../../tasks/371-vowifi-direct.md) | implemented; device pending | A preset without code: "the code is not touched" |
| 5 | [527](../../../tasks/527-dns-shield-yandex-dot-base.md) | Released v2.25.3 | A DNS catalog entry without code |
| 6 | [531](../../../tasks/531-ru-app-list-ruleset-in-ru-preset.md) | Done | A rule set with a switch inside a preset; overlay keys renamed with the text |
| 7 | [555](../../../tasks/555-template-lang-spec143-parity.md) | Done (items 1–6) | Parity campaign: the norm, the registry and the corpus are kept in step |
| 8 | [578](../../../tasks/578-tailscale-preset-template-for-each.md) | Spec. Implementation started | Constructs with code, a record field, late seeding, a contract bump |
| 9 | [580](../../../tasks/580-dns-cache-settings.md) | Done | Variables with bounds and a dedicated screen; portable in the registry |
| 10 | [588](../../../tasks/588-spec-kit-revision-audit.md) | Open | Audit: `docs/TEMPLATE.md` drift, stale-flag variable list |
