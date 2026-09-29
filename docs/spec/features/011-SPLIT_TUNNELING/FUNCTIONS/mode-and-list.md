[English](mode-and-list.md) · [Русский](mode-and-list.ru.md)

# Mode and app list

| Field | Value |
|-------|-------|
| Feature | [011-SPLIT_TUNNELING](../FEATURE.md) |
| Promises | P1–P6, P11 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Stores the user's choice — the mode and the package list — and turns it into a
field of the core config's tunnel input, from which the OS learns, when the
tunnel is created, which apps to let into the tunnel and which to route
around it.

| Mode | Caption on screen | In the tunnel |
|------|-------------------|---------------|
| Off | All apps go through VPN (default) | all apps |
| Allow-list | Only selected apps go through VPN. Others bypass via cellular/wifi | only the selected ones |
| Deny-list | Selected apps bypass VPN. Others go through | all except the selected ones |

## Parameters

| Setting | Values | Default |
|---------|--------|---------|
| Mode | `off` / `allow` / `deny` | `off` |
| List | package identifiers | empty |

The list is shown only in Allow/Deny: the counter "Apps in this list (N)", the
"Add app" button (picker), a delete button on each row. The tab menu: "VPN
settings (System)" (go to the system tunnel settings), "Clear all" (with
confirmation, the mode is kept), "Help".

## Inputs / Outputs

**Inputs:** the choice on the tab, the picker result (replaces the whole
list), `PUT /settings/tun_apps`, backup restore.

**Outputs:** `{mode, packages}` in the settings; `include_package` (allow) or
`exclude_package` (deny) on the first `inbounds[type=tun]`; the "rebuild
needed" flag; `GET /settings/tun_apps` returns the current pair.

## Rules and invariants

- An unknown mode on read — Off with an empty list; on write — rejection (the
  screen does not allow it, the Debug API answers 400).
- Writing normalizes the list: whitespace trimmed, no empties, no duplicates,
  alphabetical. On screen the rows are ordered by app name.
- A mode change does not touch the list; Off only stops applying it.
- An empty list in Allow/Deny — the config does not change (everything in the
  tunnel).
- No tunnel input (Proxy mode) — the step does nothing, no error.
- The step is the last editor of the tunnel input during the config build.
- An edit is applied to a live tunnel only by its new bring-up: the "restart"
  banner or auto-restart — [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FUNCTIONS/apply-to-running-tunnel.md).
  Edits accumulate in memory and are written to disk when leaving the screen or
  when the app goes to the background.
- Debug API: a package name is a Latin letter, then letters/digits/`_`,
  segments separated by dots; otherwise 400. Empty strings are dropped.
- A package that is not on the device is skipped on tunnel bring-up.
- In the core's verbose log mode, on every tunnel bring-up the line
  `per-app: mode=… allow_bypass=… applied=N […] not_installed=M […]` is
  written; in normal mode — nothing.

## Boundaries

- Proxy mode: the list does not apply; the tab does not show this.
- Split by domains and addresses — core rules, 004-ROUTING.
- Depends on OS capabilities: the mechanism of allowed/disallowed apps,
  application only when the tunnel is created.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [046F](../../../tasks/046F-tunnel-apps-split-tunneling/spec.md) | Implemented (v1.7.1) | Off/Allow/Deny modes, the list, the tunnel input field, Debug API |
| 2 | [075](../../../tasks/075-tun-apps-restart-regen-config.md) | Released v1.9.0 | A restart without a rebuild ran on the old config; the local banner was replaced with the shared one |
| 3 | [107](../../../tasks/107-lazy-persist-stale-read-race.md) | DONE (v2.0.2) | The rebuild on return read a choice not yet written |
| 4 | [113](../../../tasks/113-false-config-changed-banner.md) | In progress (device pending) | A false "config changed" banner after an edit and an app restart |
| 5 | [119F](../../../tasks/119F-vpn-mode/spec.md) | Implemented (v2.2.0) | In Proxy the list is not applied; in VPN+Proxy — only to the tunnel |
| 6 | [293](../../../tasks/293-vpn-settings-facade.md) | dedup implemented | A single mode check for the screen and the Debug API |
| 7 | [324](../../../tasks/324-saved-vs-running-canonical-diff.md) | ✅ Implemented (DEVICE-PENDING) | "Config is stale" is compared with the running core taking the list into account |
| 8 | [539](../../../tasks/539-perapp-debug-log.md) | Done | A summary of applied and uninstalled packages in the verbose log |
