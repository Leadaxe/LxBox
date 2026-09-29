[English](app-picker.md) · [Русский](app-picker.ru.md)

# App selection

| Field | Value |
|-------|-------|
| Feature | [011-SPLIT_TUNNELING](../FEATURE.md) |
| Promises | P8, P9 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The "Select apps" screen: shows installed apps with checkboxes, lets the user
find the right ones, check or uncheck them in bulk, move the selection via the
clipboard and return the result to the tab. The same picker is used for the
"by app" condition in user rules (004-ROUTING).

## Parameters

| Knob | Values | Default |
|------|--------|---------|
| Show / Hide system apps | show system apps | hidden |
| Search "Search apps…" | substring of the name or package, case-insensitive | empty |

Menu: Select all, Deselect all, Invert, Import from clipboard, Export to
clipboard, Show/Hide system apps.

## Inputs / Outputs

**Input:** the tab's current list (becomes the initial selection); the list of
installed apps (loaded once per session, shared by all pickers).

**Output:** the full new package list — returned both by the arrow and by the
system "back"; the tab replaces its list with it.

## Rules and invariants

- Checked apps are on top, then by name; a row — icon, name, package.
- The selection is toggled only by tapping the checkbox; a tap on the row
  changes nothing (scrolling does not clear the selection).
- The system "back" returns the selection just like the arrow; a double return
  is excluded.
- Select all and Invert act on the visible ones (taking search and the system
  filter into account); Deselect all clears the whole selection, including
  invisible ones.
- Import from clipboard: one package per line; only packages installed on the
  device are added; snackbar "N packages imported".
- Export to clipboard: selected packages one per line; available during
  loading too; snackbar "N packages copied".
- While the list is loading — an indicator, bulk actions and import are
  unavailable; counter "N selected · M shown".
- Already selected but not installed packages stay in the selection (they are
  not in the list, but they are returned to the tab).

## Boundaries

- Our own app is not highlighted or blocked separately.
- Depends on OS capabilities: visibility of the full list of installed apps
  (without it the picker shows an incomplete list).

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [046F](../../../tasks/046F-tunnel-apps-split-tunneling/spec.md) | Implemented (v1.7.1) | The picker opens from the tab, the result replaces the list |
| 2 | [108](../../../tasks/108-app-picker-back-loses-selection.md) | DONE (v2.0.2) | The system "back" lost the selection |
| 3 | [278](../../../tasks/278-folder-detail-orphan-pop.md) | Release v2.15.10 | Export to clipboard is no longer swallowed during loading |
| 4 | [412](../../../tasks/412-app-picker-checkbox-only-tap.md) | Done | The selection is toggled only by the checkbox |
