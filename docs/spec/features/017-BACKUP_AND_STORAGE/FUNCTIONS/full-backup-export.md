[English](full-backup-export.md) · [Русский](full-backup-export.ru.md)

# Full backup export — saving all app settings to a JSON snapshot

LxBox writes the settings of this installation, by category, to a JSON file that
restores them after a reset or on a new phone.

| Field | Value |
|-------|-------|
| Feature | [017-BACKUP_AND_STORAGE](../FEATURE.md) |
| Promises | P1–P3 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Saves a snapshot of this installation's settings to a JSON file, to restore
them here after a reset or on a new phone with LxBox. The user picks
categories and a save method; the file carries the settings document almost
as is, so new settings get into the backup without changing the format (the
full backup has no format version — it is a snapshot format).

## Parameters

| Category | What is included | Default |
|----------|------------------|---------|
| Server lists | All records of the source list: subscriptions, single servers, folders, auto-select nodes, chains | on |
| Routing | Rules, Directions and their migration marker, `route.final`, DNS, split tunneling, VPN/Proxy mode, idle-suspend thresholds, WG build budget, passive check | on |
| App settings | All vars except the Debug API: template vars, app flags (auto-update, language, region, haptics, rotation, subscription request identity including the HWID, automation, Wi-Fi history, config pinning for debugging §037, startup prompt flags); node test parameters, WARP and MASQUE accounts, node sorting and manual order, profiler window, dropping connections on node switch, preset seeding marks | on |
| VPN system toggles | Auto-start, keep on exit, background mode, core log and its verbosity, allow bypass, auto redirect, memory limit | on |
| Debug API config | Enabling, port, token of the Debug API | **off**, caption "Includes the access token. Sensitive — leave OFF unless you know why." |

Save methods — an action sheet: "to file" (system dialog), "to Downloads",
"share". Items unavailable on the device are not offered.

## Inputs / Outputs

**Inputs:** category checkboxes; the choice of save method.

**Outputs:** the file `lxbox-backup-v<version>-<YYYYMMDD-HHMM>.json`:

```json
{
  "app": "lxbox", "kind": "backup",
  "created_at": "<ISO-8601 UTC>",
  "source_app_version": "<version>+<build>",
  "storage": { …settings document sliced by category… },
  "vpn_settings": { …VPN toggles… }
}
```

Result — "Saved as … (N bytes)", "Saved to Downloads: … (N bytes)" or
"Backup exported (N bytes)"; the size is in file bytes.

## Rules and invariants

- No category — "Nothing to export — pick at least one category.", no file
  is created.
- The document form marker (`storage_version`) is written with any set of
  categories: without it the backup would be read as the 2.23.2 form.
- The source list travels as a whole with one checkbox, chains — together
  with the other records (§524).
- The category filter works only on known keys; an unknown key goes nowhere
  (garbage cleanup is at the import input).
- Every key import accepts belongs to some category (P2). The reverse is not
  guaranteed: `wizard_*` flags are exported with "App settings", but import
  does not accept them.
- The `storage` block is absent if it is empty after slicing; `vpn_settings`
  — only when the category is on.
- The file name and the time in it do not depend on the UI language.
- Cancelling the system save dialog — silently; a save error — a line with
  the reason; a build failure — "Export failed: …".
- Debug API `GET /backup/export[?include=storage,vpn_settings]` returns the
  same envelope, but with the whole settings document, without categories
  (including the Debug API); `from=v0_bak` — the 2.23.2-form original saved
  by the migration (for rollback test benches, no button).

## Boundaries

- The backup is not encrypted; where to keep the file is the user's call.
- Not included: core cache, logs, crash reports, rule-set cache,
  subscription bodies (subscription nodes are re-fetched), the built config,
  Tailscale node state, set slots, theme.
- The file is meant for LxBox; for the desktop launcher —
  [transfer to desktop](desktop-transfer.md).
- Saving to file, to Downloads and "Share" depend on OS capabilities.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [026](../../../tasks/026-backup-export-import.md) | Done | Settings export and import via the Debug API |
| 2 | [040F](../../../tasks/040F-backup-restore-ui/spec.md) | Implemented | Backup & restore screen, category checkboxes, Debug off by default |
| 3 | [063](../../../tasks/063-backup-format-snapshot-rewrite.md) | Done | One format — a snapshot of the settings document, no version field |
| 4 | [189](../../../tasks/189-native-prefs-mirror-in-json.md) | ✅ Implemented | VPN toggles — from the single mirror, block format unchanged |
| 5 | [221](../../../tasks/221-backup-export-allowlist-asymmetry.md) | Done | Export lost Directions: allowlist ⊆ export |
| 6 | [349](../../../tasks/349-two-month-revision-services-fixes.md) | Released v2.19.3 | Auto-ping on start was an orphan of the backup |
| 7 | [374](../../../tasks/374-backup-export-save-to-file.md) | Device-verified | "Save to file" and "to Downloads" instead of only "Share" |
| 8 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released v2.24.0 | The form marker travels with any set of categories |
| 9 | [524](../../../tasks/524-unified-source-entries.md) | Released v2.25.3 | Chains — in the Server lists category |
