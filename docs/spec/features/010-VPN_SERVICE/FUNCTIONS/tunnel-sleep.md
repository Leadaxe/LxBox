[English](tunnel-sleep.md) · [Русский](tunnel-sleep.ru.md)

# Tunnel sleep (background mode) — pausing the VPN to save battery

The tunnel can be paused while the device sleeps or the screen is off and
resumed afterwards; by default it never sleeps.

| Field | Value |
|------|----------|
| Feature | [010-VPN_SERVICE](../FEATURE.md) |
| Promises | P16 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Lets the user trade the reliability of background connections for battery:
pause the whole tunnel when the device sleeps or the screen goes off, and wake
it back up. By default the tunnel never sleeps.

## Parameters

| Setting | Values | Default |
|---------|--------|---------|
| Tunnel sleep mode (VPN settings → System → Optimization) | `never` — "Never sleep (recommended)"; `lazy` — "Lazy sleep", pause in deep device sleep; `always` — "Aggressive battery saving", pause on every screen-off | `never` |

Part of the backup. Applied from the next connection; a change with the tunnel
up marks "restart needed".

## Inputs / Outputs

**Inputs:** the device entering/leaving deep sleep (`lazy`); screen off/on
(`always`).
**Outputs:** core calls `pause` and `wake`.

| Mode | When `pause` | When `wake` |
|------|--------------|-------------|
| `never` | never | never |
| `lazy` | the device entered deep sleep | the device left deep sleep |
| `always` | the screen went off | the screen came on |

## Rules and invariants

- The mode is read once at tunnel start; a change on the fly is not picked up.
- In `never` neither pause nor wake is called at all — zero overhead.
- `pause` closes all core connections: apps get a disconnect, push and
  keep-alive channels break. Hence `always` breaks them on every screen-off,
  and the default is `never`.
- While paused, the tunnel interface stays up: traffic does not go around the
  tunnel, the real address is not exposed. Packets are not queued while paused —
  they are dropped; after `wake` apps reopen connections themselves (hence "a
  burst of pushes on unlock").
- Regardless of the mode, screen-on starts the rebind of stale WG/AWG sessions
  (see [network-changes](network-changes.md)).

## Boundaries

- Selective sleep of individual WG/AWG tunnels — [core-resources](core-resources.md);
  it is orthogonal to the sleep of the whole tunnel.
- Sleep of data streams for the app screen in the background —
  [012-LIVE_STATE](../../012-LIVE_STATE/FEATURE.md).
- Depends on OS capabilities: the presence and moment of deep sleep (usually
  tens of minutes of stillness with the screen off), delivery of screen events.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [124F](../../../tasks/124F-background-mode-tunnel-sleep/spec.md) | Implemented (default `never` since v1.5.0) | Three sleep modes, default `never`, pause without a leak |
| 2 | [086](../../../tasks/086-stale-connections-network-change-doze.md) | Research | The core pause closes connections — the root of drops in `always` |
| 3 | [215](../../../tasks/215-libbox-rc18-idle-suspend.md) | IMPLEMENTED + DEVICE-VERIFIED | Wake on screen-on only in the `always` mode |
