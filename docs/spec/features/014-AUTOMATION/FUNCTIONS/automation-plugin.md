[English](automation-plugin.md) · [Русский](automation-plugin.ru.md)

# Automation plugin

| Field | Value |
|-------|-------|
| Feature | [014-AUTOMATION](../FEATURE.md) |
| Promises | P5, P12 |
| State | ✅ written from code, 2026-09-28 |

## What it does

L×Box appears in the plugin list of automation apps that support the
Locale/Tasker standard (Tasker, MacroDroid, Llama, Automate with the premium
block): **actions** — pick a command from a list instead of typing a string by
hand; **conditions** — the profile is active while the tunnel is up or the
required node or group is active.

## Parameters

No settings of its own; executing actions and answering conditions are
enabled by the same "Accept automation commands". The plugin configuration
screens are always available.

Actions (rows in the plugin list):

| Row | Behaviour |
|-----|-----------|
| L×Box: Start VPN / Stop VPN / Toggle VPN | selection without a screen, ready immediately |
| L×Box: Custom… | a selection screen: Switch node, Set group, URL-test group, Refresh subscriptions, Rebuild config, Reset network |

Conditions: **VPN is up**; **Active node =** value; **Active group =** value.

Format of the saved setting (stored by the automation app, a public
contract): one JSON string under the key `com.leadaxe.lxbox.plugin.CONFIG` —
action `{"v":1,"cmd":"<command>","args":{…}}`, where the command is
`start-vpn`, `stop-vpn`, `toggle-vpn`, `switch-node` (`tag`), `set-group`
(`group`), `urltest-group` (`group`), `refresh-subs`, `rebuild-config`,
`reset-network`; condition
`{"v":1,"check":"vpn-up|active-node|active-group","equals":"…"}`.

## Inputs / Outputs

**Inputs:** a selection in the plugin screens; action execution and condition
polling by the automation app; the cache of the active node, group, the node
list of the active group and the group list, which the app updates on every
change.

**Outputs:** the saved setting and its label (in the app language, for
example "Switch node → <node>"); command execution; the condition answer
"satisfied / not satisfied / unknown".

## Rules and invariants

- Actions are executed by the same paths as commands from "Command intake":
  start, stop, toggle — without the UI (toggling without the VPN permission
  opens the app); the rest — by the shared handlers with `VPN_ERROR` on
  failure. `refresh-subs` from the plugin — without a forced update.
- "Custom…" for Switch node offers a drop-down of the real nodes of the active
  group, for Set group / URL-test group — a list of groups; an empty cache
  (the app has not been opened since install or since a subscription change) →
  manual input.
- Reopening the screen pre-fills the saved command and value.
- The condition answers right away, without launching the UI: "VPN is up" —
  from the tunnel service status; node and group — from the cache. No cache,
  an empty expected value, a corrupted setting or an unknown check →
  "unknown".
- A corrupted or foreign action setting is ignored.
- Command and check strings in the setting are English forever; labels are
  localised.

## Boundaries

- The "Active node =" condition is set by typing text; there is no node list
  in it.
- The condition is polled by the automation app periodically; there is no
  instant notification to the host about a change (events are for that).
- There is no separate plugin app and no UI beyond these screens.
- Depends on OS and host capabilities: presence of the plugin block, the
  condition polling rate, the setting size limit of the standard (25 KB).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [047F](../../../tasks/047F-public-intent-api/spec.md) | Implemented (2026-06-21) | Step 2: actions and conditions per the Locale/Tasker standard, choosing the node and group from a list |
| 2 | [157](../../../tasks/157-automation-drop-require-permission.md) | Done | The plugin is enabled by the same main toggle |
| 3 | [192](../../../tasks/192-proxy-mode-prepare-revokes-foreign-vpn.md) | ✅ device-verified | A toggle from the plugin in Proxy does not ask for the VPN permission |
| 4 | [279F](../../../tasks/279F-localization/spec.md) | phases 0–7 done | Plugin labels and screens in the app language; command strings — English |
| 5 | [290](../../../tasks/290-automation-node-switch-gaps.md) | complete | "Active node =" as a poll of the current node instead of waiting for an event |
