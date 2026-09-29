[English](full-backup-restore.md) · [Русский](full-backup-restore.ru.md)

# Full backup restore — merging or replacing settings from a backup file

LxBox restores settings from a full backup file after a preview, either merging
them with the current ones or replacing them.

| Field | Value |
|-------|-------|
| Feature | [017-BACKUP_AND_STORAGE](../FEATURE.md) |
| Promises | P4–P9 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Brings settings back from a full backup file: shows what is in the file,
lets the user deselect categories and pick a mode — add to the current
settings or replace them. From the empty home screen ("Restore from
backup") — the same in one step, without a preview.

## Parameters

| Setting | Values | Default |
|---------|--------|---------|
| Categories | only those present in the file, with counters: "N server lists (S subs, C custom)", "Routing — N rules, final: …", "N app settings", "N VPN system toggles", "Debug API config (sensitive — token included)" | all present |
| Mode | "Merge with existing (recommended)" — "Adds new items, keeps existing."; "Replace all (destructive)" | Merge |

## Inputs / Outputs

**Inputs:** a JSON file; categories and mode; Debug API `POST /backup/import
[?merge=true][&rebuild=true]` (replace by default).

**Outputs:** applied settings; the line "Imported: N server lists, routing
(N rules), N app settings, debug config, N VPN settings", with the suffixes
"(N errors)" and "· N unknown keys skipped"; the "Restart now" button. From
the home screen — "… · fetching subscriptions…".

## Rules and invariants

- **Validation before writing.** Not JSON — "Not a valid JSON file…"; the
  root is not an object; no `app: lxbox` / `kind: backup` — "Not a LxBox
  backup file…"; no `storage` block — "Unsupported backup format. Re-export
  from a recent app version.". All — an "Invalid backup" dialog, nothing
  written.
- **Old form.** A block without the form marker migrates on parsing — before
  the preview and the filter; the migration result and losses go to the log.
- **Replace** is confirmed separately: "Replace all data?" — "This will
  overwrite your current data in the selected categories. This cannot be
  undone." In fact the whole settings document is replaced: unselected
  categories are not kept (P7).
- **What survives replace** if the file is silent about it: enabling, port
  and token of the Debug API (§413); "already asked" flags of startup
  prompts (battery, tile, update check, notifications). A key from the file
  wins; `wizard_*` flags are never accepted from the file. With the
  category deselected, VPN toggles stay at the device values.
- **Merge:** sources are appended by `id` (an existing `id` is not touched);
  the archive's chains, if any, replace the current ones wholesale, an
  archive without chains does not touch them; vars — by key; other keys of
  the file overwrite their own.
- **Default-deny allowlist** in both modes: top level — a closed list of
  keys, vars — app flags ∪ template vars of this build. Dropped items go to
  the log and the counter.
- After writing — Directions seeding: an archive without them gets the
  template ones and `vpn-1`; running it again changes nothing.
- VPN toggles are applied one by one; a broken key is an error in the
  counter, the others are applied. The UI language from the backup is
  applied immediately.
- A failure of one part (sources, chains, document, Directions) — a line in
  the errors, the rest is applied.
- From the home screen: replace of all the file's categories without a
  preview, then re-reading the sources and a forced subscription update.
- Debug API: the `app`/`kind` markers are not checked; merge — overwriting
  top-level keys wholesale (sources are not appended); the response carries
  `migrated`, the migration report and `dropped_keys`.

## Boundaries

- An LX Backup file is not read by this input — [transfer to desktop](desktop-transfer.md).
- Subscription nodes are not stored in the backup — they arrive with a
  subscription update.
- Importing directly into a set slot is not supported — [018-WORKSPACES](../../018-WORKSPACES/FEATURE.md).
- File picking depends on OS capabilities (on TV — a hint).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [026](../../../tasks/026-backup-export-import.md) | Done | Import via the Debug API, merge/replace |
| 2 | [040F](../../../tasks/040F-backup-restore-ui/spec.md) | Implemented | Preview with categories and mode, replace confirmation |
| 3 | [063](../../../tasks/063-backup-format-snapshot-rewrite.md) | Done | Old format without a settings block is rejected |
| 4 | [159](../../../tasks/159-backup-allowlist-strict-filter.md) | Done | Strict default-deny allowlist at the input, counter of dropped items |
| 5 | [219](../../../tasks/219-deep-audit-2026-07.md) | Done (audit) | MASQUE account and profiler window survive restore |
| 6 | [393F](../../../tasks/393F-directions/spec.md) | Released v2.21.0 | Order restore → Directions seeding |
| 7 | [413](../../../tasks/413-backup-replace-keeps-debug-api.md) | Done | Replace does not kill the device Debug API |
| 8 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released v2.24.0 | An old-form block migrates before the preview and the filter |
| 9 | [447](../../../tasks/447-v2-24-0-avd-findings.md) | Fixed | Replace does not reset startup prompt flags |
| 10 | [524](../../../tasks/524-unified-source-entries.md) | Released v2.25.3 | Old archives with chains are read with the Server lists checkbox |
