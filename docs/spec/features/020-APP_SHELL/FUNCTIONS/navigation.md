[English](navigation.md) · [Русский](navigation.ru.md)

# Navigation and exit — side menu, About screen and double back to exit

Every LxBox screen is reached from the home screen and its side menu; on the
home screen the app closes only on a second "back" press within 2 seconds.

| Field | Value |
|-------|-------|
| Feature | [020-APP_SHELL](../FEATURE.md) |
| Promises | P22 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Gives a single entry point to all screens — the home screen with the side
menu — and protects against accidental exit: on the home screen the app closes
only on the second "back" press.

## Parameters

No settings of its own. Fixed values: the second-press window — 2 s; the
"Press back again to exit" hint stays for the same time.

Side menu (top to bottom, groups separated by a divider):

| Group | Items |
|-------|-------|
| Setup | Servers · Routing · DNS Settings · VPN Settings · App Settings |
| Tools | Speed Test · Statistics · Config Editor · Debug |
| About the app | About |

The home screen title is "L×Box" (not translated) and the settings set menu
(018). About: version and install channel, user guide, source code, core
version, acknowledgements, "Support the project", "Where to get L×Box" (all
install channels always visible), the updates block.

## Inputs / Outputs

**Inputs:** a tap on a menu item; "back" — button, edge gesture, mouse or
keyboard button.
**Outputs:** a screen opened over home; the menu closed; a hint or the app
window closed.

## Rules and invariants

- A menu item closes the menu and opens the screen over home; "back" from the
  screen returns home.
- The double "back" works only when the home screen has no open screens,
  menus, dialogs, sheets or dropdowns; otherwise "back" closes the topmost of
  them.
- The first press — a hint, no exit; the second within 2 s — exit; later than
  2 s — the first press again.
- "Back" closes an open side menu without a hint.
- Exit closes the window; the tunnel keeps running.
- The first press does not start the system close animation (predictive
  gesture).
- On a TV, the remote focus is on the main button when home opens.
- Donations: "Support the project" opens the list of methods (wallets with
  address copying, links); the list comes from the network on tap, otherwise
  from the last successful response or the built-in copy. There is no
  background request.

## Boundaries

- There are no bottom tabs; sections are reached only through the menu.
- Minimizing instead of exiting and ignoring "back" were rejected by the owner.
- The contents of the menu items are in their own features; here only the
  entry.
- The public donations document is `docs/DONATE.md`; the feature does not
  show it.
- Depends on OS capabilities: the predictive "back" gesture (Android 13+).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [009F](../../../tasks/009F-ux-and-theme/spec.md) | Implemented | Quick access to settings from the home screen |
| 2 | [372](../../../tasks/372-android-tv-support.md) | — | Remote focus on the main button of the home screen |
| 3 | [362](../../../tasks/362-project-links-share.md) | implemented | Shared project links, `@placeholders`, the `share:` action |
| 4 | [423](../../../tasks/423-donate-json-single-source.md) | implemented | A single source of support methods, no background requests |
| 5 | [426](../../../tasks/426-install-sources-always-in-about.md) | Done | All install channels always visible in About |
| 6 | [429](../../../tasks/429-bottom-inset-system-navigation.md) | Done | Inset for the system navigation on all screens and sheets |
| 7 | [583](../../../tasks/583-home-back-press-twice-to-exit.md) | Implemented | Exit from home by a double "back" |
