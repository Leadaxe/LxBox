[English](foreign-vpn.md) · [Русский](foreign-vpn.ru.md)

# Coexisting with another VPN

| Field | Value |
|-------|-------|
| Feature | [010-VPN_SERVICE](../FEATURE.md) |
| Promises | P7, P8, P9 |
| State | ✅ written from code, 2026-09-28 |

## What it does

There is one system VPN slot on the device. The function keeps L×Box from
silently displacing another VPN on start and honestly reports when another VPN
has displaced L×Box.

## Parameters

No settings of its own. Behaviour depends on the operating mode: the question
and the system permission request exist only in modes with a tunnel (`vpn`,
`vpn_proxy`), see [operating-modes](operating-modes.md).

## Inputs / Outputs

**Inputs:** a manual start from the app; the presence of another app's active
VPN network; the OS signal about the slot takeover.
**Outputs:** the "Another VPN is active" dialog with the Switch / Cancel / VPN
settings buttons; the `revoked` status and the message "Another VPN app took
the system VPN slot (e.g. an always-on VPN). Start again to reconnect."

## Rules and invariants

- Before a manual start in a mode with a tunnel the app checks whether another
  VPN is active. If it is — a dialog: Switch continues the start, Cancel
  cancels it, VPN settings opens the system VPN list (the active one is marked
  there; the OS does not tell the app the name of the taker) and does not start
  either.
- A VPN counts as foreign if it currently serves the active network; L×Box's
  own "orphaned" VPN network is not foreign. While our tunnel is not stopped,
  the question is not asked. A check failure = "no foreign VPN": the start is
  not blocked.
- In Proxy mode neither the question nor the system VPN permission request is
  made: starting the port must not revoke another VPN.
- A start without the screen (tile, automation, Debug API) asks no question; if
  the permission has not been granted yet, it answers "consent needed" and does
  not start.
- Slot takeover: the tunnel stops regularly (all stop waits resolve), the
  status is `revoked`, the reason is shown as a pop-up message and saved as the
  last start error. There is no separate fifth service status: it is a flag on
  top of "Stopped".
- The takeover flag is also returned on a status request, so the app opened
  after a takeover shows it, not "Disconnected".
- The takeover reason text in external interfaces (Debug API, last start error)
  is always English.

## Boundaries

- Determining which app took the slot is impossible — the OS does not tell.
- Automatically taking the slot back is not done.
- Depends on OS capabilities: the uniqueness of the VPN slot, other apps'
  always-on VPN, visibility of the VPN network owner (on old OS versions our own
  orphaned network may count as foreign).

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [003](../../../tasks/003-revoke-ux.md) | Done; the UX did not work until §276 | A clear message on slot takeover |
| 2 | [192](../../../tasks/192-proxy-mode-prepare-revokes-foreign-vpn.md) | ✅ DEVICE-VERIFIED | Proxy mode does not request the VPN permission and does not break another VPN |
| 3 | [211](../../../tasks/211-foreign-vpn-switch-dialog.md) | SPEC (implemented in code) | The "another VPN is active" dialog before start |
| 4 | [224](../../../tasks/224-foreign-vpn-revoke-ux.md) | Done (closed in §276) | An honest reason text instead of "taken by another app" |
| 5 | [241](../../../tasks/241-foreign-vpn-settings-button.md) | implemented | The "VPN settings" button in the dialog |
| 6 | [276](../../../tasks/276-revoked-status-contract.md) | Done — device-verified | Takeover is a flag on top of Stopped, survives the background |
| 7 | [427](../../../tasks/427-foreign-vpn-active-network-api30.md) | Done, DEVICE-VERIFIED | A foreign VPN — by the active network; our own orphan is not foreign |
| 8 | [528](../../../tasks/528-foreign-vpn-dialog-proxy-mode.md) | Done | The dialog is not shown in Proxy mode |
