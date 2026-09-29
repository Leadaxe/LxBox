[English](app-status.md) · [Русский](app-status.ru.md)

# App status — name, icon and an honest "uninstalled" label

Each row of the app list shows which app the package belongs to and whether it
is still installed.

| Field | Value |
|-------|-------|
| Feature | [011-SPLIT_TUNNELING](../FEATURE.md) |
| Promises | P10 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Shows the human-readable app name and icon in the tab's list instead of a bare
package, and honestly marks packages that are not on the device:
"<package> — uninstalled, auto-skipped", with a dimmed icon.

## Parameters

None.

## Inputs / Outputs

**Input:** packages from the list; OS replies: "present, here is the name",
"no such package" or no reply (timeout, failure).

**Output:** a list row with the name and icon; the "uninstalled" label only for
confirmed absence.

## Rules and invariants

- Three package states: unknown (still being checked or the check failed),
  installed, confirmed absent. The label — only for the third.
- A failed check is not cached as "absent": up to three automatic retries with
  delays of 2, 5, 15 s; after that — "unknown", a new attempt the next time the
  tab is opened.
- A confirmed "absent" is not asked again until the end of the session;
  loading the full app list (the picker) heals stale entries.
- The name appears at once, the icon is loaded separately; until it arrives —
  a neutral placeholder.
- A package without a name (not checked yet) is shown by its identifier and
  sorted by it.
- A labelled package is not removed from the list automatically: a reinstalled
  app works again without selecting it again.

## Boundaries

- The label is a diagnosis for the user; the real decision "skip the package"
  is made by the OS when the tunnel is created, and the core's verbose log
  records it (see [mode-and-list](mode-and-list.md)).
- Depends on OS capabilities: the reply to a package query and its speed.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [046F](../../../tasks/046F-tunnel-apps-split-tunneling/spec.md) | Implemented (v1.7.1) | Uninstalled packages are marked and stay in the list |
| 2 | [109](../../../tasks/109-tun-apps-false-uninstalled.md) | Done (develop) | A false "uninstalled" from a timeout; three states and retries |
