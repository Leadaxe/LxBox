[English](connection-status.md) · [Русский](connection-status.ru.md)

# Status and traffic bar

| Field | Value |
|-------|-------|
| Feature | [012-LIVE_STATE](../FEATURE.md) |
| Promises | P1, P4 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Shows whether the tunnel is connected and what goes through it, right on the
home screen: the bar under the status carries the transferred volume, the
number of connections, the profiler recording indicator and the connection
time. A tap on the bar opens Statistics.

## Parameters

No settings of its own.

## Inputs / Outputs

**Inputs:** the tunnel service status (`connecting`, `connected`, `stopping`,
`disconnected`, `revoked` + reason); `CommandStatus` ticks — `uplinkTotal` /
`downlinkTotal`, `memory`, `connectionsIn`, `connectionsOut`; the tunnel uptime
known to the service; the profiler recording flag; the "VPN bypass allowed in
this session" flag.

**Outputs:**

| Element | What it shows |
|---------|---------------|
| ↑ / ↓ | accumulated volume over the core session |
| 🔗 N | `connectionsIn` — app connections (= the list on Stats) |
| 🗄 M | `connectionsOut` — connections to servers (nodes) |
| `Live` | profiler recording is running |
| time | how long the tunnel has been up |
| ⚠ in the Statistics header | VPN bypass is allowed in this session — part of the traffic may go around |

Connection counters are shown only when the sum is non-zero; a long press
gives the hint "App connections" / "Outbound connections to servers".

## Rules and invariants

- **Two worlds of status.** The tunnel phase comes only from the service; the
  core's data channels (section [data-channels](data-channels.md)) give only
  numbers. Their connect/disconnect is not displayed as the tunnel status.
  Hence channel sleep in the background does not blind the app to the tunnel
  being turned off.
- A repeated or late terminal status ("Stopped" on top of an already stopped
  one) does not break the live state of a new session.
- On return from the background the service status is re-read once; a
  divergence from what is shown is processed as an ordinary status event.
- Status ticks outside a running tunnel are ignored.
- The home counters are redrawn at most once per second, even if ticks come
  more often.
- The numbers are consistent: home 🔗 ≈ "Connections" on Stats ≈ "active" in
  the Conns tab; 🗄 is a different quantity (the core's physical outward
  connections). A sum used to be shown that matched no screen.
- The connection time after swiping from recents and reopening keeps counting
  from the real tunnel start, not from the moment of opening (a fresh start —
  no correction, threshold 2 s).
- The bypass warning reflects the actual state of the current session, not the
  saved setting.

## Boundaries

- The status transitions themselves, their deadlines, "Connection lost" on
  status silence — 010-VPN_SERVICE.
- Speed (bytes/s) is not shown on the home screen — only the accumulated
  volume.
- Depends on OS capabilities: delivery of the service status with the app in
  the background, the return-from-background event.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [016F](../../../tasks/016F-statistics-and-connections/spec.md) | Implemented | Traffic bar on the home screen, navigation to Statistics |
| 2 | [123F](../../../tasks/123F-subscription-model/spec.md) | Implemented | Tunnel status — from the service, not from the core data channel |
| 3 | [069](../../../tasks/069-current-session-allow-bypass.md) | Released v1.9.0 | VPN bypass warning in the current session |
| 4 | [187](../../../tasks/187-uptime-survives-swipe.md) | ✅ Implemented | Connection time survives swiping from recents |
| 5 | [194](../../../tasks/194-connection-counters-clarity.md) | ✅ Implemented, device-verify pending | App connections and connections to servers — separately |
| 6 | [276](../../../tasks/276-revoked-status-contract.md) | Done, device-verified | VPN slot takeover is distinguishable from a stop |
| 7 | [361](../../../tasks/361-late-started-status-after-service-destroy.md) | ✅ Fixed | A late "Started" after the service died does not hang the status |
