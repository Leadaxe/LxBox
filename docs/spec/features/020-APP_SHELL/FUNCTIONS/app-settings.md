[English](app-settings.md) · [Русский](app-settings.ru.md)

# App settings — one screen for settings outside the core config

The App Settings screen groups the settings that do not go into the sing-box
config and saves each one the moment it changes.

| Field | Value |
|-------|-------|
| Feature | [020-APP_SHELL](../FEATURE.md) |
| Promises | P23 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Gathers settings unrelated to the core config on one App Settings screen and
saves each one at the moment of change. The screen only hosts them: the contents
of most sections belong to neighboring features.

## Parameters

Tabs (centered, scrollable on a narrow screen):

| Tab | Sections | Whose feature |
|-----|----------|---------------|
| General | Region | 015-WARP |
| | Behavior: auto-start, automatic VPN restart on settings change | 010, 003 |
| | Quick connect: tile, shortcut | 014 |
| | Updates: auto-check, Check now | this one ([update-check](update-check.md)) |
| | Feedback: auto-ping after connecting · Haptic feedback | 009 · this one ([haptic](haptic-feedback.md)) |
| | Backup & restore | 017 |
| Appearance | theme, Layout, Language | this one ([appearance](appearance.md), [localization](localization.md)) |
| Subscriptions | auto-update, request identity | 001 |
| Diagnostics | System setup, logs, Developer | 013 |
| Automation | Intent API | 014 |

## Inputs / Outputs

**Inputs:** touches; opening from the side menu (on General), from neighboring
screens straight onto the needed tab (Subscriptions, Diagnostics), from a
support feed link `lxbox://route:app-settings[/appearance|subscriptions|diagnostics|automation]`.
**Outputs:** saved values; an immediate effect wherever possible.

## Rules and invariants

- There is no "Save" button: a toggle is written to storage on change.
- Until the values are read from storage, the toggles are inactive — a value
  the user has not seen cannot be written.
- Theme and language repaint the screen immediately without closing it.
- Editing screens (routing, DNS, VPN mode) save an edit to memory immediately,
  and to disk on leaving the screen or backgrounding the app; the config build
  sees the edit already on returning home (003).
- The settings are stored together with the rest of the app settings: they
  are part of the backup and of settings sets; the exception is the theme.

## Boundaries

- The meaning, defaults and effects of other features' sections are in those
  features.
- There is no reset of all app settings to defaults.
- The menu item caption "Theme, appearance" is narrower than the screen's
  contents.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [022F](../../../tasks/022F-app-settings/spec.md) | Implemented (v1.4.0) | Screen for settings unrelated to the config: theme, startup, feedback |
| 2 | [009F](../../../tasks/009F-ux-and-theme/spec.md) | Implemented | Autosave of edits |
| 3 | [158](../../../tasks/158-settings-tabs-center-alignment.md) | Done | Centered tabs, fade at the edges |
| 4 | [541](../../../tasks/541-appearance-tab-two-columns-toggle.md) | Done | A separate Appearance tab |
| 5 | [425](../../../tasks/425-warp-pool-region-loc.md) | Implemented | Region section on the General tab |
