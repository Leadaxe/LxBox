[English](autostart-and-exit.md) · [Русский](autostart-and-exit.ru.md)

# Autostart and exiting the app — the VPN after a reboot and after closing the app

The tunnel can start by itself after the device boots and can keep running
after the app is closed.

| Field | Value |
|------|----------|
| Feature | [010-VPN_SERVICE](../FEATURE.md) |
| Promises | P10, P11 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Decides whether the tunnel lives independently of the open app: whether it
comes up by itself after the device boots and whether it survives closing the
app.

## Parameters

| Setting | Where | Values | Default |
|---------|-------|--------|---------|
| Auto-start on boot | App settings → Behavior | on/off | off |
| Keep VPN on exit | VPN settings → Mode (only in modes with a tunnel) | on/off | on |

Both settings are part of the backup and are restored with it.

## Inputs / Outputs

**Inputs:** the device finishing boot; swiping the app from recents;
"Quit & reopen app" in diagnostics.
**Outputs:** a running tunnel with the last saved config; a stopped tunnel.

## Rules and invariants

- After the device boots the tunnel starts by itself only if "Auto-start on
  boot" is on; the start uses the last saved config, without opening the app
  and without questions.
- If the VPN permission has been revoked by then, a start in a mode with a
  tunnel ends with the error "missing vpn permission"; in Proxy mode the
  permission is not needed.
- The values of both settings are available to the service even without the
  app running; the truth is stored in the app settings and is re-synced to the
  service on every app start (a divergence heals itself).
- "Keep VPN on exit" on — swiping the app away does not touch the tunnel; off —
  swiping stops the tunnel regularly.
- The "on" default also applies to users whose value was never saved
  explicitly (default changed in §188).
- "Quit & reopen app" ends the whole process together with the tunnel; the
  keep-alive setting does not affect this.

## Boundaries

- Requesting exclusion from battery optimization — in the startup wizard
  ([020-APP_SHELL](../../020-APP_SHELL/FEATURE.md)); without it autostart and
  survival are unreliable on some firmware.
- Bringing the tunnel up after process death — [recovery](recovery.md).
- Depends on OS capabilities: when the boot event is delivered (on some
  devices — only after the first unlock), background work permission, the
  firmware's behaviour on swipe.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [012F](../../../tasks/012F-native-vpn-service/spec.md) | Implemented | Autostart after boot; stop on swipe by setting |
| 2 | [020](../../../tasks/020-android14-fgs-special-use.md) | Done | The tunnel service declares the type required by new OS versions |
| 3 | [188](../../../tasks/188-tun-toggles-to-mode-tab.md) | ✅ DEVICE-VERIFIED | Keep VPN on exit is on by default, lives on the mode screen |
