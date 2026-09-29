[English](slot-management.md) · [Русский](slot-management.ru.md)

# Slot management

| Field | Value |
|-------|-------|
| Feature | [018-WORKSPACES](../FEATURE.md) |
| Promises | P9, P10 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Shows which sets exist and which one is on the scene now, and lets the user
rename or delete them. There is no separate management screen — everything is
in the popup of the set button on the home screen.

## Parameters

| Parameter | Rule |
|-----------|------|
| Name | whitespace is trimmed; not empty; ≤ 64 characters; no `/`, `\`, control characters or DEL; does not start with a dot (including `.` and `..`) |
| Case | names are compared case-sensitively |
| "Default" | the current slot's name until the first "Save as"; shown localized, user names are shown as is |

## Inputs / Outputs

**Inputs:** the "Workspaces" popup; the slot row's "⋮" menu: Rename, Delete;
the name dialog with live validation.

**Outputs:** the set directory; in the Load section — slots in
case-insensitive alphabetical order, the current one marked, each with a
relative save date and on-disk size; the current name on the button.

## Rules and invariants

- **Live name validation.** The dialog's "Save" button is disabled for an
  invalid name; reason text: "Name is empty", "Name is too long", "Name must
  not contain / or \", "Name must not start with a dot".
- **Rename** renames the slot together with its copy; if it is the current
  one, current gets the new name. A taken name — "A workspace with this name
  already exists". The slot's Tailscale identities move with it.
- **Delete** — after the "Delete workspace “X”?" confirmation ("This cannot be
  undone"); removes the copy and the entry. The current slot cannot be
  deleted: the item is disabled, and a bypass attempt gives "The current
  workspace cannot be deleted".
- **The current slot without a copy** (before the first "Save as") is shown
  first, without a date and without the "⋮" menu — there is nothing to rename
  or delete.
- **A tap on the current slot** closes the popup with no action.
- An unreadable directory is treated as missing: "Default", no slots.

## Boundaries

- A deleted slot cannot be restored; there is no trash.
- "Default" cannot be renamed before the first "Save as" — it has no copy.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [417F](../../../tasks/417F-workspaces/spec.md) | implemented (v1) | Name rules, rename/delete, slot size; the Manage screen replaced by the "⋮" menu (decision of 05.09) |
| 2 | [445](../../../tasks/445-tailscale-state-dir-lifecycle.md) | Implemented, no device-verify | Rename and Delete maintain the slot's Tailscale identity entries |
