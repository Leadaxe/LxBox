[English](save-and-load.md) · [Русский](save-and-load.ru.md)

# Saving and loading a set — Save as and Load with the tunnel kept in place

LxBox stores the current state under a name with "Save as…"; loading another
slot first saves the current one, then rebuilds the config and returns the
tunnel to its previous state.

| Field | Value |
|-------|-------|
| Feature | [018-WORKSPACES](../FEATURE.md) |
| Promises | P1–P7, P11, P13, P14 |
| State | ✅ written from code, 2026-09-28 |

## What it does

"Save as…" puts a copy of the current state under a name and makes that slot
current. A tap on another slot in the Load section saves the scene into the
current slot and puts the selected one onto the scene; the config is rebuilt
from the new set, and the tunnel returns to its previous position. There is no
separate "Save" button.

## Parameters

| What | Value |
|------|-------|
| Slot contents | settings file · downloaded rule-sets · subscription body cache |
| Not in the slot | built config · core cache database · theme · logs · crash reports · service copies and temporary files · Tailscale state directories |
| Suggested name in "Save as" | the current slot's name if it has no copy yet; otherwise empty |

## Inputs / Outputs

**Inputs:** the slot or name chosen in the popup; the tunnel position; the
journal of an unfinished load at startup.

**Outputs:** the selected slot's scene; the rebuilt config; the tunnel brought
up again if it was up; snackbar "Workspace “X” loaded" / "Saved as “X”"; the
modal "Loading workspace…" indicator.

## Rules and invariants

- **Load order:** stop subscription auto-update and probes → stop the tunnel
  → flush settings to disk → journal → scene into the current slot → target
  onto the scene → current = target, journal cleared → "config is stale" flag
  → re-read state (language, toggle mirror, Directions migrations, automation
  events) → new home screen → rebuild → start, if it was up.
- **The copy is a mirror.** After saving, the slot equals the scene: items
  absent from the scene are removed from the slot; folders are copied anew in
  full; a file on the scene is never half-written.
- **The settings backup copy is removed** after a load — it is a snapshot of
  the previous slot.
- **Start after a load — only on its own config.** If the rebuild failed and
  the config stayed "stale", the tunnel is not started; the log says
  "auto-connect skipped".
- **Completion.** A `load` journal at startup repeats the steps in full (they
  are idempotent) before the first settings read and raises the "config is
  stale" flag. No target — the journal is cleared, the scene stays.
- **Save as** does not touch the tunnel and re-reads nothing. If the name
  already exists — dialog "Overwrite “Y”?"; agreeing replaces the slot
  entirely.
- **Old storage form.** A slot saved before storage contract 1.0 gets a copy of
  the original settings file next to it on load (if there is none yet); the
  scene is migrated on read; "Save as" already writes the new form. Dormant
  slots are not migrated.
- Errors: the slot has disappeared — "Workspace not found"; anything else —
  "Failed to load workspace: …". The indicator is removed in any case.

## Boundaries

- The rebuild itself and its gates — [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md);
  tunnel stop and start — [010-VPN_SERVICE](../../010-VPN_SERVICE/FEATURE.md).
- The backup sees only the scene — [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.md).
- A kill in the middle of copying, and a load with the VPN up and auto-start
  on a device, have not been checked (417F header).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [417F](../../../tasks/417F-workspaces/spec.md) | implemented (v1) | Save slots, Load/Save as, completion journal, re-read without restart |
| 2 | [414](../../../tasks/414-config-dirty-check-files-dir.md) | Done | The "config is stale" check looked for the config in the wrong directory — found during the file inventory |
| 3 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released in v2.24.0 | Old-form slot: a copy of the original next to the slot, scene migration on read |
| 4 | [447](../../../tasks/447-v2-24-0-avd-findings.md) | Fixed, no device-verify | Load did not rebuild the config: an explicit flag instead of modification time |
| 5 | [506](../../../tasks/506-change-review.md) | Released in v2.25.2 | Review: auto-connect after a set switch goes to a bare start, bypassing the core-rejected nodes machine |
| 6 | [440](../../../tasks/440-remove-storage-v0-migration.md) | Backlog | Remove the old-form migration and the original copy next to the slot |
