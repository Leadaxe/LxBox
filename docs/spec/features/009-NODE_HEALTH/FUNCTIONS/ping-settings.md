[English](ping-settings.md) · [Русский](ping-settings.ru.md)

# Ping settings

| Field | Value |
|-------|-------|
| Feature | [009-NODE_HEALTH](../FEATURE.md) |
| Promises | P5 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Sets where and with what time budget nodes are pinged: a shared address and
timeout for all Directions, or their own for a particular Direction. Opened by
a long tap on the ping button on the home screen; the shared address can also
be edited from the test settings in a folder.

## Parameters

| Parameter | Values | Default |
|-----------|--------|---------|
| Test URL | any URL; presets Google 204, Cloudflare, Apple, Firefox, Yandex | `https://www.gstatic.com/generate_204` |
| Timeout (ms) | integer > 0 | 5000 |
| Scope | All directions / current Direction | override exists → Direction, otherwise All |
| Reset to global | removes the Direction override | — |

Presets and defaults come from the template (`ping_options.url`,
`ping_options.timeout_ms`, `ping_options.presets`), preset names are in the
interface language.

## Inputs / Outputs

**Inputs:** user input in the sheet; Debug API (reading and writing the
section).

**Outputs:** the effective URL and timeout for single and mass ping
([node-ping](node-ping.md)); for the server test
([server-list-test](server-list-test.md)) and the layered chain probe — only
the global values.

## Rules and invariants

- **Resolution chain** for the home-screen ping: override of the current
  Direction → global value → template default. An empty URL and a non-positive
  timeout count as unset.
- The override stores the URL and timeout independently: setting one field
  does not require setting the other.
- The sheet opens in Direction mode if the Direction already has an override,
  and shows its values; otherwise — the global ones.
- **Deleting a Direction** removes its override; overrides of other Directions
  are not touched. An empty override set is removed entirely rather than left
  empty.
- Direction overrides go into the backup together with the Directions.
- The server test in a folder and subscription does not see Direction
  overrides: there the URL and timeout are global, and a folder has its own if
  set (the WARP scanner sets them).
- Changing the settings does not rebuild the core config: the values are read
  on every measurement.

## Boundaries

- The test address of a core URLTest group (the group's `url`) is a separate
  group setting, see [urltest-group](urltest-group.md); ping settings do not
  affect the group test.
- Export and import — 017-BACKUP_AND_STORAGE.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [008F](../../../tasks/008F-ping-and-node-management/spec.md) | Implemented | Configurable ping parameters |
| 2 | [040](../../../tasks/040-per-group-ping-test-settings.md) | ✅ Implemented | Global settings are saved; per-Direction override |
| 3 | [408](../../../tasks/408-ping-options-groups-heal.md) | Done | Orphaned overrides are removed together with the Direction |
| 4 | [409](../../../tasks/409-direction-ping-options-backup.md) | Done | Direction overrides in the backup |
