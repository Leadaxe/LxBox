[English](template-lifecycle.md) · [Русский](template-lifecycle.ru.md)

# Template lifecycle — what a new template does to saved settings

An app update brings a new template on top of the user's saved state; LxBox seeds what is new,
keeps the user's overrides by name and stores nothing that equals a template default, so the
template and the overrides meet again on every build.

| Field | Value |
|------|----------|
| Feature | [024-TEMPLATE](../FEATURE.md) |
| Promises | P10 P11 P13 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Keeps the shipped template and the user's stored overrides consistent across
app updates. The template is not versioned by itself: whatever template the
installed build carries is the current one. Storage never holds a copy of the
template — only the user's deviations from it, keyed by the template's names
(variable names, `preset_id`, DNS server tags). On every read and build the
current template is applied to those deviations.

## Parameters

| Marker in the settings document | Meaning |
|---|---|
| `presets_migrated` | "default presets were seeded once" (a fresh install) |
| `late_presets_seeded[]` | ids of presets that became default after users had state and were offered once |
| `directions_migrated` | the default Directions were seeded once from the template |
| `storage_version` | the form of the document itself — [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.md) |

`parser_config.version` (5) inside the template is read into the model but
nothing keys on it. There are no user knobs.

## Inputs / Outputs

**Inputs:** the template of the installed build; the settings document
(`vars`, `rules[]`, `dns{}`, `directions[]`, the markers above); a backup or
a Workspaces slot with the same document.
**Outputs:** the same document with seeded entries and cleaned overrides; log
lines "default preset X added once"; import counters of dropped keys.

## Rules and invariants

**Where the overrides live.**

| What the user changed | Where it is stored | What the template still supplies |
|---|---|---|
| A section variable (VPN Settings, Routing, DNS) | `vars.<name>` — the value only | type, default, options, bounds, screen, texts |
| A preset: enabled, position, variables, target | `rules[]` record `kind: preset` with `ref = preset_id`, `num`, `vars` (only non-default values; the target is `vars.outbound`) | the body, rule sets, DNS parts, `ui` texts |
| A template DNS server: on/off, variables | `dns.servers[]` record `kind: template` with `tag`, `enabled`, `vars` | the server body |
| A preset DNS server: on/off | `dns.servers[]` record `kind: preset` with `ref = <preset_id>:<tag>`, `enabled` | the server body |
| A Direction | `directions[]` — a full record | only the first seed and the group templates |

**A clean install.** Presets with `ui.default: true` are added once (the
marker `presets_migrated`), the default Directions from `default_directions`
once (`directions_migrated`), DNS Final/Resolver/Strategy start at the
template's `default_value` ([005-DNS · P8](../../005-DNS/FEATURE.md#promises)).

**An update with a new template on top of saved state.**

- A new variable: no stored value, the default applies; nothing is migrated
  (§580).
- A changed default: everyone who did not change the value follows the new
  default, because an equal value was never stored; a user's different value
  stays (P11). Pinning the current default against a future change is
  impossible by design (§441).
- A variable moved between a section and a preset (via `ref`) keeps the
  user's value: storage is keyed by name, not by place (§264).
- A removed variable: the stored value lingers harmlessly until the next
  backup import, where the allowlist drops it (§159); no one-time cleanups
  run at start.
- A new default preset does not reach saved state by `default: true` alone:
  the first seed ran once. It is added once through the late-defaults list
  (today: `tailscale`), enabled, at the template's `num`; a user who deletes
  it does not get it back (P10). A non-sortable preset (Traffic Processing)
  is re-seeded at every build if missing.
- A renamed or removed `preset_id`: the record stays and the list shows
  "Preset not found — tap to fix"; the old one-shot id remap was removed
  (§229), a user who skipped v2.10.0..v2.17.x sees this for three old ids.
- A new template DNS server appears with the template's `enabled`; a record
  whose template or preset server vanished is deleted; custom servers are
  never touched ([005-DNS](../../005-DNS/FUNCTIONS/dns-servers.md)).
- Preset tags: the config tag is `<preset_id>:<tag>`; a document of the
  2.23.2 form, a slot or an old backup that still holds a bare tag is read
  into the same namespace by the storage migration (P12).
- Copies of the same preset (an old rule import) collapse at load, the last
  one stays.

**Backup, transfer and slots.**

- The backup carries the document, not the template. On import, `vars` keys
  are accepted only for names the template of the importing build declares
  plus the app flags; unknown ones are dropped and counted (P13,
  [017 · P5](../../017-BACKUP_AND_STORAGE/FEATURE.md#promises)).
  So a backup from a newer build loses the variables the older template does
  not know — visibly.
- The seed markers travel in the "App settings" category, so a restored
  installation does not re-seed defaults.
- LX transfer to the desktop moves only variables marked `portable` in the
  contract registry; the rest are skipped with `backup_var_skipped`
  ([017 · P15](../../017-BACKUP_AND_STORAGE/FEATURE.md#promises)).
- A Workspaces slot is a copy of the document; the template is shared by all
  slots and an old-form slot is migrated at load ([018-WORKSPACES · P13](../../018-WORKSPACES/FEATURE.md#promises)).

## Boundaries

- The storage document form, its migration from 2.23.2 and atomic writes —
  [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.md).
- Direction seeding and group templates — [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).
- Rolling the app back to an older template is not supported by the OS; a
  document written by a newer build is read as current.
- There is no template version and no per-template migration table: a
  breaking change of the template shape is a storage-form change.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [159](../../../tasks/159-backup-allowlist-strict-filter.md) | Done | One-time cleanups removed; the allowlist at import is the only cleanup; the seed marker reuses `presets_migrated` |
| 2 | [229](../../../tasks/229-remove-preset-id-migration.md) | Done | The one-shot `preset_id` remap removed; old ids degrade to "Preset not found" |
| 3 | [264](../../../tasks/264-traffic-processing-preset.md) | DEVICE-VERIFIED | Variables moved into a preset keep their values by name; the pinned preset is re-seeded at build |
| 4 | [267](../../../tasks/267-group-templates-magic-nodes.md) | — | Directions seeded from `default_directions` |
| 5 | [327](../../../tasks/327-dns-resolver-defaults-from-template.md) | — | DNS defaults come from the template, one place |
| 6 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released v2.24.0 | Storage form 1.0; preset DNS server references migrated into the preset namespace |
| 7 | [441](../../../tasks/441-template-preset-vars-in-record.md) | Released v2.24.0 | A value equal to the default is not stored; an undeclared name is dropped |
| 8 | [527](../../../tasks/527-dns-shield-yandex-dot-base.md) | Released v2.25.3 | The preset tag namespace `<preset_id>:<tag>` |
| 9 | [578](../../../tasks/578-tailscale-preset-template-for-each.md) | Spec. Implementation started | Late seeding of a preset that became default after install |
| 10 | [580](../../../tasks/580-dns-cache-settings.md) | Done | New variables need no migration: the default applies |
