[English](appearance.md) · [Русский](appearance.ru.md)

# Appearance

| Field | Value |
|-------|-------|
| Feature | [020-APP_SHELL](../FEATURE.md) |
| Promises | P1, P2, P3 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Defines how the app looks and behaves under the fingers: light or dark theme,
orientation lock, the node list layout on a wide screen, the pull-to-refresh
gesture and the app icon.

## Parameters

| Setting | Values | Default | When it takes effect |
|---------|--------|---------|----------------------|
| Theme | System / Light / Dark | System | immediately |
| Allow rotation | on/off | off | immediately |
| Two columns on wide screens | on/off | on | immediately |

The two-column threshold is a window width of 600 dp inclusive.

## Inputs / Outputs

**Inputs:** the choice in App Settings → Appearance; the device theme (for
System); the window width; the device position and system auto-rotate; a
downward gesture on the list.
**Outputs:** the app palette; the orientation; the number of node list
columns; refreshed list data.

## Rules and invariants

- One palette for both themes, from a single seed color (indigo), Material 3.
- System follows the device theme and changes with it on the fly.
- The theme choice survives a restart; it is not part of the backup or of
  settings sets — it is a device property.
- Allow rotation off — portrait only; on — the system decides the orientation,
  including its rotation lock.
- Two columns: row-wise order (1-2 / 3-4); with manual sort the list is always
  a single column; switching without layout flicker at startup.
- Pull-to-refresh:

  | Where | What it does |
  |-------|--------------|
  | Home, node list | re-reads groups from the running core; without the tunnel — redraws from the last known ones |
  | Servers | updates all subscriptions, like the update button; while an update is running — nothing |

- Icon: an orange gradient, a light "L" frame and a cross of two arrows with
  three nodes ("routing cross"); on Android 8+ it is adaptive (the launcher
  sets the shape). The name under the icon is "L×Box" in all languages. The
  Quick Settings tile has its own monochrome icon.

## Boundaries

- The theme option labels (System / Light / Dark) are not translated.
- There is no themed (monochrome) Android 13+ icon — the icon is always in
  color.
- There is no accent color choice and no dynamic wallpaper colors.
- The Connect / Disconnect shortcuts and their icons — 014.
- Depends on OS capabilities: the system theme, auto-rotate, launcher icon
  shapes.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [009F](../../../tasks/009F-ux-and-theme/spec.md) | Implemented | Dark theme following the system, Material 3, pull-to-refresh |
| 2 | [022F](../../../tasks/022F-app-settings/spec.md) | Implemented (v1.4.0) | Theme choice System / Light / Dark |
| 3 | [034F](../../../tasks/034F-app-icon/spec.md) | Active | The "routing cross" icon instead of the default one |
| 4 | [139](../../../tasks/139-qs-tile-icon-manifest-rebrand.md) | Done | Quick Settings tile icon in the L× style |
| 5 | [220](../../../tasks/220-allow-rotation-setting.md) | — | Allow rotation, portrait by default |
| 6 | [537](../../../tasks/537-nodes-two-columns-wide.md) | Done | Node list in two columns from 600 dp |
| 7 | [541](../../../tasks/541-appearance-tab-two-columns-toggle.md) | Done | Appearance tab, two-column toggle |
