[English](config-pin.md) · [Русский](config-pin.ru.md)

# Config pinning — a hand-made config that rebuilds do not overwrite

For experiments, a config written through the Debug API or the editor can be
pinned so that UI actions stop rebuilding it from the settings.

| Field | Value |
|-------|-------|
| Feature | [019-CONFIG_EDITOR](../FEATURE.md) |
| Promises | P6, P7 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Lets the user test a config the app cannot build (an experimental core
capability, a custom DNS scheme): write it whole through the Debug API or the
editor and pin it so that UI actions do not overwrite it. Once the pin is
removed, the next action builds the config from the settings again.

## Parameters

| Knob | Values | Default |
|------|--------|---------|
| Lock config (debug) — toggle in the settings' Diagnostics | on/off; visible only when the Debug API is enabled | off |
| `PUT /settings/config_locked` | body `{"locked": true\|false}` | — |
| `GET /state/config_locked` | response `{"locked": bool}` | — |
| `PUT /config` | body — the raw config JSON object | — |

## Inputs / Outputs

**Inputs:** the toggle; Debug API requests; any UI action that triggers a
rebuild.

**Outputs:** the saved config does not change on rebuilds; Debug API
responses; snackbars "Config locked. UI actions will not rebuild config." /
"Config unlocked. Next UI action will rebuild from settings.".

## Rules and invariants

- **`PUT /config` without pinning is temporary.** The response says so
  directly: any rebuild erases the write; to keep it — pin it.
- **`PUT /config` accepts only a JSON object** in UTF-8; otherwise 400. JSON5
  comments are not allowed here (unlike the editor).
- **While pinned**, a rebuild from the UI is silently skipped (the log gets an
  entry about the skip due to the pin), and a false fatal build error sheet of
  the previous generation is not shown; `POST /action/rebuild-config` and the
  same automation action answer 409 with a hint on how to remove the pin.
- **Removing** the pin rebuilds nothing by itself — the next action will
  rebuild.
- **No orphan.** The toggle is hidden when the Debug API is off; turning the
  Debug API off in settings removes the pin.
- The pin is stored among the app settings and, like them, belongs to the
  current set ([018-WORKSPACES](../../018-WORKSPACES/FEATURE.md)).

## Boundaries

- There is no protection against a config invalid for the core: an accepted
  JSON object goes to the core as is; the error shows up on start/restart.
- Transport, token and port of the Debug API — [027-DEBUG_API](../../027-DEBUG_API/FUNCTIONS/access-and-security.md).
- An edit from the editor while pinned holds the same way as `PUT /config`.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [037](../../../tasks/037-debug-api-write-config-and-lock-rebuild.md) | ✅ Implemented (later) | Writing the config through the Debug API and pinning against rebuilds |
| 2 | [254](../../../tasks/254-detour-cycle-fatal-detector.md) | — | While pinned, do not show the fatal sheet of the previous build |
