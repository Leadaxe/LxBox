[English](tunnel-control.md) · [Русский](tunnel-control.ru.md)

# Tunnel control — starting, stopping and reconnecting the VPN with an honest status

Start, stop, core reload and reconnect are available from the app and from
the service notification, and every transitional phase ends by a deadline
with a stated reason.

| Field | Value |
|------|----------|
| Feature | [010-VPN_SERVICE](../FEATURE.md) |
| Promises | P1, P2, P3, P4, P20 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Start, stop, core reload and reconnect of the tunnel — from the app and from
the service notification. Keeps an honest status: every transitional phase has
a deadline, after which a hung core is forcibly shut down and the user gets
the reason.

## Parameters

No settings of its own. Fixed deadlines:

| Deadline | Value |
|----------|-------|
| Service wait for a confirmed stop | 9 s |
| App wait for a reply to "Stop" | 10 s |
| Emergency stop from the Stopping phase | 12 s |
| Emergency stop from the Connecting phase | 15 s + 10 s × number of WG/AWG nodes, ceiling 4 min |
| Pause between core reloads | 3 s |
| Node caption in the notification if the app was not opened | ~3 s after the start |

## Inputs / Outputs

**Inputs:** the Start / Stop / Reload buttons in the app; Stop / Reconnect in
the notification; the saved core config.
**Outputs:** the tunnel status and the stop reason; the persistent
notification "L×Box [final = <route.final>]" with the caption
"<group>: <node>" (or the status "Connected" if the node is unknown) and the
Stop / Reconnect buttons.

## Rules and invariants

- "Stop" returns success only after the "Stopped" confirmation. If the service
  does not make it within 9 s — "Stop timed out"; the core is then finished off
  by the emergency stop at 12 s, which moves the UI to "Disconnected" at once.
- The emergency stop does not wait for the core: the interface is shut down at
  once, and the core's resources are closed with a 2 s limit per step, so that
  the next start does not hit a busy port.
- Expiry of the Connecting phase gives a reason with the threshold and the
  number of nodes; it also counts as the start verdict for the node safety net
  ([009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md)).
- Reconnect = confirmed stop → start; if the stop was not confirmed, the start
  is cancelled ("Stop timed out — reconnect aborted"). Reconnect from the
  notification works the same way, but without the app; a repeated tap during
  a reconnect is ignored.
- A start cancelled by a stop while waiting for the core cannot later announce
  itself "Started" (a late start is dropped).
- Core reload — only with the tunnel connected, no more than once per 3 s,
  without stopping the service; a successful one clears the "restart needed"
  mark; an error is shown and allows a retry right away.
- The start waits for the core to be ready; an empty config, a core that is not
  ready, a core rejection → a stop with a reason text. Rules with Wi-Fi
  conditions without the location permission → a dialog leading to settings.
- The notification caption is updated on a node change and on a language
  change without reconnecting.

## Boundaries

- What exactly is re-read when settings are auto-applied —
  [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md).
- Display of connection time and speed — [012-LIVE_STATE](../../012-LIVE_STATE/FEATURE.md).
- Starting without the screen (tile, Intent API) —
  [014-AUTOMATION](../../014-AUTOMATION/FEATURE.md).
- Depends on OS capabilities: the persistent notification and its buttons.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [012F](../../../tasks/012F-native-vpn-service/spec.md) | Implemented | Own tunnel service instead of a third-party plugin; blocking stop |
| 2 | [001](../../../tasks/001-reconnect-sink-leak.md) | Done | Reconnect does not lose the status stream |
| 3 | [002](../../../tasks/002-blocking-stopvpn-intent-reset.md) | Done | Stop waits for confirmation; reconnect without a race |
| 4 | [004](../../../tasks/004-lifecycle-resume-resync.md) | Done | Status is re-read on returning to the app |
| 5 | [016](../../../tasks/016-libbox-newservice-throwable-catch.md) | Done | A core creation failure does not crash the app |
| 6 | [027](../../../tasks/027-libbox-init-race-fix.md) | Done | Start waits for the core to be ready |
| 7 | [030](../../../tasks/030-vpn-reload-button.md) | ✅ Implemented | Core reload button with a 3 s pause |
| 8 | [123](../../../tasks/123-server-name-in-notification.md) | Done | Node name in the notification |
| 9 | [129](../../../tasks/129-vpnservice-force-stop-on-stuck-core.md) | ✅ Done | Forced stop of a hung core |
| 10 | [140](../../../tasks/140-force-stop-port-race-and-connecting-timeout.md) | ✅ Done | The emergency stop does not hold the port; separate phase deadlines |
| 11 | [182](../../../tasks/182-notification-action-buttons.md) | Done | Stop / Reconnect buttons in the notification |
| 12 | [223](../../../tasks/223-notification-live-labels.md) | ✅ Implemented | The notification caption follows node changes |
| 13 | [287](../../../tasks/287-stop-latency-mass-ping-wg-teardown.md) | complete | Long stop during a mass ping |
| 14 | [361](../../../tasks/361-late-started-status-after-service-destroy.md) | ✅ Fixed | A late "Started" after the service died |
| 15 | [373](../../../tasks/373-reload-on-main-thread-anr.md) | 🔧 DEVICE-PENDING | Core reload does not freeze the interface |
| 16 | [387](../../../tasks/387-zombie-started-after-force-stop.md) | Done, DEVICE-PENDING | Zombie "Started" after an emergency stop |
| 17 | [415](../../../tasks/415-stop-timeout-budget.md) | Done | Stop budget ladder 9 < 10 < 12 s |
| 18 | [519](../../../tasks/519-connecting-timeout-post-start.md) | Released v2.25.3 | The connecting deadline grows with the number of WG/AWG nodes |
