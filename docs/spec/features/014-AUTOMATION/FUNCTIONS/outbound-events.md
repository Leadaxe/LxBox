[English](outbound-events.md) · [Русский](outbound-events.ru.md)

# Outbound events — broadcasts about the tunnel, nodes and subscriptions

Each event category is off until the user enables it.

| Field | Value |
|-------|-------|
| Feature | [014-AUTOMATION](../FEATURE.md) |
| Promises | P7, P8, P9, P10, P13 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Tells the outside world what happened in the app: the tunnel came up or went
down, the node or group changed, a subscription was updated, a new version was
released. An automation app subscribes to the event ("Event → Intent
Received") and can wait for it as the answer to its command.

## Parameters

| Category (App Settings → Automation → Outbound events) | Default |
|---------------------------------------------------------|---------|
| Lifecycle | off |
| State | off |
| Subscription | off |
| Health | off |

The first enable of any category goes through an explanatory dialog (once).

Events (prefix `com.leadaxe.lxbox.event.`):

| Event | Extras | Category | When |
|-------|--------|----------|------|
| `VPN_CONNECTED` | — | Lifecycle | the tunnel came up |
| `VPN_DISCONNECTED` | `reason`: `user` / `error` / `revoked` | Lifecycle | the tunnel went down |
| `VPN_ERROR` | `code`, `message` | Lifecycle | the tunnel failed (`tunnel_error`) or a command failed (`bad_request`, `conflict`, `not_found`, `switch_failed`, …, `error`) |
| `VPN_REVOKED` | — | Lifecycle | another app took the VPN slot |
| `UPDATE_AVAILABLE` | `version`, `url` | Lifecycle | a new version was found |
| `ACTIVE_NODE_CHANGED` | `old_tag`, `new_tag`, `group`, `reason` | State | a node was selected explicitly (in the app or by command) |
| `NODE_ALREADY_ACTIVE` | `tag`, `group` | State | `SWITCH_NODE` on the already active node |
| `ACTIVE_GROUP_CHANGED` | `old_group`, `new_group`, `reason` | State | a different group was selected |
| `SUB_REFRESHED` | `sub_id`, `nodes_count`, `delta_count` | Subscription | a subscription was updated |
| `SUB_REFRESH_FAILED` | `sub_id`, `error` | Subscription | a subscription failed to update or yielded 0 nodes |

## Inputs / Outputs

**Inputs:** tunnel status and the stop reason; an explicit node/group change;
subscription update results; the update check; command failures.
**Outputs:** an open broadcast event; the log line
`[automation] emit <EVENT> <extras> → ok` or `→ throttled`.

## Rules and invariants

- A disabled category — the event is not sent at all (not an "empty" one).
- A stop on error yields the pair `VPN_ERROR(tunnel_error)` +
  `VPN_DISCONNECTED(error)`; a slot takeover — `VPN_REVOKED` +
  `VPN_DISCONNECTED(revoked)`; a normal stop — `VPN_DISCONNECTED(user)`.
- `message` of `VPN_ERROR(tunnel_error)` is the raw core error text, not
  masked: the automation app gets what the log gets (owner's decision
  2026-09-29).
- Request-response: a command's success arrives in State
  (`ACTIVE_NODE_CHANGED` / `NODE_ALREADY_ACTIVE` / `ACTIVE_GROUP_CHANGED`), a
  failure — `VPN_ERROR` in Lifecycle. The settings explicitly suggest enabling
  both.
- `ACTIVE_GROUP_CHANGED` — only on a real group change, not on re-selecting
  the same one.
- `old_tag` / `old_group` are absent if there is no previous value (the first
  switch after launch); empty values are not sent.
- `reason` for a node and group change is always `user`; `urltest` /
  `automation` from `047F` are not planned (owner decision 2026-09-29, audit [591](../../../tasks/591-spec-kit-revision-audit.md)).
- `SUB_REFRESH_FAILED` — no more than once a minute per subscription; other
  events have no rate limit.
- `sub_id` — the masked subscription address, without the token; the
  `message` of a command failure is a controlled text, an internal error →
  `internal error`.
- The event is open to any app on the device; it carries no secrets.

## Boundaries

- A node change by the group's automation (URL test, fallback) yields no
  event — only an explicit selection does.
- Health (`HEARTBEAT_FAILED`, `LATENCY_DEGRADED`, `UNATTRIBUTED_BURST`) and
  `PERMISSION_NEEDED` — reserved, there is no source; the Health toggle
  enables nothing.
- Events are sent by the app UI; while it is not loaded, events do not go out,
  even if the tunnel changes status.
- Depends on OS capabilities: delivery of broadcast events to the subscriber.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [047F](../../../tasks/047F-public-intent-api/spec.md) | Implemented (2026-06-21) | Events by category, off by default, a limit for subscription failures |
| 2 | [036F](../../../tasks/036F-update-check/spec.md) | Released (v1.5.0) | The source of `UPDATE_AVAILABLE` |
| 3 | [157](../../../tasks/157-automation-drop-require-permission.md) | Done | Events are open to all subscribers, without a receiver filter |
| 4 | [042F](../../../tasks/042F-health-watchdog/spec.md) | 🚫 Won't-fix | Health events remain reserved without a source |
| 5 | [219](../../../tasks/219-deep-audit-2026-07.md) | Done (audit) | The rate-limit unit does not check the exact one-minute boundary |
| 6 | [290](../../../tasks/290-automation-node-switch-gaps.md) | complete | `NODE_ALREADY_ACTIVE`, `VPN_ERROR` on command failure, the "enable both categories" hint |
