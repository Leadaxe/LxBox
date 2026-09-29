[English](network-changes.md) · [Русский](network-changes.ru.md)

# Reacting to network and node changes

| Field | Value |
|-------|-------|
| Feature | [010-VPN_SERVICE](../FEATURE.md) |
| Promises | P15, P19 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Keeps apps from hanging on connections that died together with the old network
or the old node: on a real network change it resets the core's connections, on
screen-on it asks the core to rebind stale WireGuard sessions, on a node change
(optionally) it breaks the connections of the group being switched.

## Parameters

| Setting | Where | Values | Default |
|---------|-------|--------|---------|
| Interrupt connections on switch | VPN settings → System | on/off | off |

Fixed values: quiet before a reset on network change — 1.5 s; budget for
breaking connections on node change — 5 s.

## Inputs / Outputs

**Inputs:** change, loss and appearance of the default network (always the
physical one, not our own tunnel); screen on; choosing another node in a
group.
**Outputs:** core calls `resetNetwork` (close connections, reset the DNS
cache, rebind outbounds), `rebindStaleEndpoints`, `closeConnection` for each
connection of the group; telling the core about the current interface or its
absence.

## Rules and invariants

- Connection reset — only on a real interface change: the previous and the new
  interfaces are known and differ. The first connection, an update of the same
  network's properties and network loss give no reset; a burst of events
  collapses into one reset.
- Network loss: the core is told "no interface", no reset (there is nowhere to
  reconnect to). The previous interface is remembered, so the transition
  "Wi-Fi → no network → LTE" still gives a reset.
- The default network for the core and for local DNS resolution is always the
  physical network, never our own tunnel (otherwise DNS goes in circles). While
  there is no physical network, local DNS resolution answers with an error at
  once rather than waiting.
- Screen-on in any sleep mode asks the core to rebind only provably stale
  WG/AWG sessions; the decision and debounce are on the core side, the call
  does not block.
- Breaking on node change: performed only if the toggle is on and the core
  accepted the node choice; only live connections whose chain contains the
  group being switched are broken; errors of individual connections are
  ignored, overall budget 5 s. Choosing the already active node does nothing
  and breaks nothing.
- A manual network reset exists only in the Debug API: with the tunnel
  connected, no more than once per 3 s.

## Boundaries

- Breaking connections by the core itself on a group selection change (the
  Direction option `interrupt_exist_connections`) — 006-DETOUR_AND_BALANCE /
  007-NODE_LIST.
- Deep device sleep as a reason to pause — [tunnel-sleep](tunnel-sleep.md).
- Rule conditions on the Wi-Fi network — 004-ROUTING.
- Depends on OS capabilities: default network events, their order and the
  delay before the interface appears, the screen-on event.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [023](../../../tasks/023-change-network-state-permission.md) | Done | Network permission on old OS versions |
| 2 | [031](../../../tasks/031-reset-network-api.md) | ✅ Implemented | Core network reset without recreating it; manual call via the Debug API |
| 3 | [086](../../../tasks/086-stale-connections-network-change-doze.md) | Research | Roots of "hung" connections after a network change and sleep |
| 4 | [087](../../../tasks/087-network-change-force-reset.md) | ✅ Implemented | Connection reset on a real interface change with debounce |
| 5 | [119](../../../tasks/119-default-network-not-vpn.md) | Code-complete | The default network is never our own tunnel |
| 6 | [122](../../../tasks/122-default-network-null-onlost.md) | Won't-fix | Without a network local DNS fails at once, we do not add a wait |
| 7 | [143-interrupt](../../../tasks/143-interrupt-connections-on-node-switch.md) | Implemented | Optional breaking of the group's connections on node change |
| 8 | [290](../../../tasks/290-automation-node-switch-gaps.md) | — | Choosing the already active node — no break and no reselection |
| 9 | [340](../../../tasks/340-user-present-rebind-stale-endpoints.md) | v2 (SCREEN_ON) shipped | Screen on → rebind stale WG/AWG |
