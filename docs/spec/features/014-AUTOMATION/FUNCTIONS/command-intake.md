[English](command-intake.md) · [Русский](command-intake.ru.md)

# Command intake — controlling LxBox from Tasker and the shell

Intake is off until the user turns on "Accept automation commands".

| Field | Value |
|-------|-------|
| Feature | [014-AUTOMATION](../FEATURE.md) |
| Promises | P5, P6, P7, P8, P11 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Accepts public commands from automation apps and the shell (`am broadcast`,
Tasker "Send Intent", target — Broadcast Receiver) and executes them the same
way as the corresponding action in the app or in the Debug API. The command
list with a copy button is shown in App Settings → Automation.

## Parameters

| Setting | Values | Default |
|---------|--------|---------|
| Accept automation commands | on/off; turning on — after the warning "any app on the device will be able to control the VPN" | off |

Commands (prefix `com.leadaxe.lxbox.`):

| Command | Extra | Action | Requires |
|---------|-------|--------|----------|
| `START_VPN` | — | start; if already up — nothing | VPN permission (except Proxy) |
| `STOP_VPN` | — | stop | — |
| `TOGGLE_VPN` | — | toggle relative to the status | — |
| `SWITCH_NODE` | `tag` (String) | active node in the current group | a selected group, tunnel up |
| `SET_GROUP` | `group` (String) | active group | the group exists |
| `REBUILD_CONFIG` | — | rebuild the config from subscriptions | the config is not locked for debugging |
| `REFRESH_SUBS` | `force` (Bool) | update subscriptions | the updater is ready |
| `RESET_NETWORK` | — | reset connections, DNS, reconnect sockets | tunnel up |
| `URLTEST_GROUP` | `group` (String) | URL test of a group | tunnel up |

## Inputs / Outputs

**Inputs:** a command with extras; the app state (group, nodes, tunnel).
**Outputs:** the action; on failure — `VPN_ERROR` (see "Outbound events");
log: `[automation] action <name> → ok / ERROR <code>`; the fact of intake —
only in the system log under the `LxBoxIntent` tag.

## Rules and invariants

- While intake is off, commands do not reach any handler — this is the only
  barrier; there is no separate "pass" for apps.
- The system follows the saved toggle not only on a tap: on app start, after
  loading a settings set and after restoring a backup intake is switched on
  or off to match it.
- `START_VPN`, `STOP_VPN`, `TOGGLE_VPN` are executed without the app UI.
  `TOGGLE_VPN` without the VPN permission opens the app for consent (like the
  tile); `START_VPN` does not request consent — a start without the permission
  ends in a tunnel error.
- Other commands are executed by the shared handlers with Debug API error
  codes: an empty `tag`/`group` → `bad_request`; no group, tunnel down, config
  lock, app not ready → `conflict`; no group with that name → `not_found`; a
  config build failure → a core/build error; the core rejected the node of
  an accepted `SWITCH_NODE` → `switch_failed`. Every failure is `VPN_ERROR`; a
  raw exception does not leak outside.
- `SET_GROUP` on a non-existent group does not change the group and does not
  send `ACTIVE_GROUP_CHANGED`.
- `SWITCH_NODE` on the already active node does not drop connections and
  answers `NODE_ALREADY_ACTIVE`.
- `force` accepts a boolean; the strings `true`/`1`/`yes` are read as "yes",
  anything else — "no".
- Any "Stop" from outside shuts down the running node safeguard cycle.
- Intake never crashes the process: a command parsing error is written to the
  log.

## Boundaries

- Commands without a required extra (`SWITCH_NODE` without `tag`, etc.) and
  unknown commands are dropped with an entry in the system log, without
  `VPN_ERROR`.
- Commands other than start/stop/toggle require the app UI to be loaded;
  otherwise they are skipped without an answer.
- There is no "same call" answer: the result is learned only from events.
- There is no sender check and no per-command permissions.
- Depends on OS capabilities: delivery of broadcast commands, autostart bans
  in firmwares.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [047F](../../../tasks/047F-public-intent-api/spec.md) | Implemented (2026-06-21) | Nine public commands, off by default |
| 2 | [155](../../../tasks/155-audit-2026-06-quick-wins.md) | In progress | Receiving entries without a system permission — by design |
| 3 | [157](../../../tasks/157-automation-drop-require-permission.md) | Done | The non-working "pass" removed; the barrier is only the main toggle |
| 4 | [192](../../../tasks/192-proxy-mode-prepare-revokes-foreign-vpn.md) | ✅ device-verified | `TOGGLE_VPN` in Proxy does not ask for the VPN permission |
| 5 | [290](../../../tasks/290-automation-node-switch-gaps.md) | complete | `SWITCH_NODE`: conflict with the tunnel down, confirmation of re-selection, not_found for a group, failure → `VPN_ERROR` without leaks |
| 6 | [494](../../../tasks/494-debug-api-debts.md) | Released v2.25.0 | Start by command — direct, without the safeguard cycle |
| 7 | [510](../../../tasks/510-review-findings-after-v2251.md) | Released v2.25.2 | "Stop" by command shuts down the node safeguard cycle |
| 8 | [605](../../../tasks/605-service-live-automation-workspaces-bugs.md) | Implemented | Intake follows the saved toggle after a backup restore and a set load |
| 9 | [605](../../../tasks/605-service-live-automation-workspaces-bugs.md) | Implemented | The core rejecting an accepted `SWITCH_NODE` → `VPN_ERROR(switch_failed)` |
