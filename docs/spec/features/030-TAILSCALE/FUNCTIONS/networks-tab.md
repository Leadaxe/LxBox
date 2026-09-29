[English](networks-tab.md) · [Русский](networks-tab.ru.md)

# Network tab — the tailnet as seen from the phone, with an exit node switch

The Network tab of a Tailscale node shows whether the node is in, who else is
in the tailnet, which peer is the exit, and lets the user switch the exit on
the fly, sign in, log out and ping a device.

| Field | Value |
|-------|-------|
| Feature | [030-TAILSCALE](../FEATURE.md) |
| Promises | P19–P24 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Turns the core's tailnet state stream into a screen: the Status block (state,
network name, "signed in with a key", Sign in, Log out), This device (name,
MagicDNS name, addresses, key expiry), Exit node (the peers that offer an
exit, None first, with "Save choice" when the active exit differs from the
recorded one), Devices (online first, grouped by owner when there are several)
and Ping through the tailnet. The same stream feeds the NETWORKS row on the
home screen, the Diagnostics tab and the Debug API.

## Parameters

| What | Value |
|------|-------|
| Where | node screens of an own server, a folder member, a subscription node and the view screen opened from NETWORKS or "View details"; before Diagnostics |
| Initial tab | from a NETWORKS row — Network; from "View details" — as before |
| Exit node list | peers with `ExitNodeOption`, sorted like Devices; "None" first |
| Save choice | visible when the active and the recorded exit differ and the node has a source record (own server or folder member) |
| Written value | the active peer's Tailscale address, IPv4 first; without addresses — the MagicDNS name, then the host name; None removes `exit_node` |
| Ping | up to five replies or until the sheet closes; latency, direct or relay, endpoint address or relay region |
| Debug API | `GET /state` → `tailscale: {tag: {backend_state, devices}}` |

## Inputs / Outputs

**Inputs:** the core stream (`BackendState`, `StateText`, `AuthURL`,
`NetworkName`, `MagicDNSSuffix`, `KeyAuth`, self, exit node, peers by owner);
the tunnel status; the node body; taps: a list item, Save choice, Sign in,
Log out, Copy name, Copy address, Ping.

**Outputs:** the tab; `SetTailscaleExitNode` (a `StableID` or empty),
`TailscaleLogout`, `StartTailscalePing`; the node source with `exit_node`
changed and the config rebuilt; snackbars "Copied", "Failed: …"; the
Diagnostics line "This node has no exit. Check devices on the Network tab."

## Rules and invariants

- **Only a Tailscale node has the tab** (P19); the Diagnostics tab index
  shifts by one.
- **Without data** (P20): VPN off — "Start VPN to see the network."; no core
  record for the tag yet — a waiting indicator; the node is disabled or not
  in the running config — "The node is not in the running config."
- **Status:** the state text as on the NETWORKS row (`running`, `sign-in
  needed`, `stopped`, `starting`, or the core's text); Sign in appears in
  `NeedsLogin` with a non-empty `AuthURL` and opens it in the browser; Log out
  appears in `Running`, after a confirmation that says a node with a stored
  auth key signs in again at the next start.
- **Exit node** (P21): picking an item calls the core and switches the exit
  on the fly; the body is untouched. The recorded value refers to a peer when
  it equals one of its addresses, its MagicDNS name (with or without the
  trailing dot), the base name or the host name, case-insensitively. The
  mismatch cases and their warning texts: none recorded, chosen on the fly —
  "Not saved. Traffic is not routed through this node until you save the
  choice."; recorded, cleared on the fly — "Not saved. The node stays in the
  lists, but has no exit until you save the choice."; another one chosen —
  "Not saved. The choice is lost after restart." Save choice writes the
  address into the node source (key order kept), checks the config with the
  core and saves the node the way Save on the Source tab does; after a
  rebuild the node moves between NETWORKS and the Direction lists. A
  subscription node shows the sign but no Save choice.
- **Devices** (P22): peers other than this device, online first then by name;
  marks: `online` / `offline` with `last seen`, `key expired`, `shared`,
  `exit node`, OS when known; a tap on a name or address copies it, the row
  menu offers Copy name, Copy address, Ping. Owner groups appear only with
  more than one owner; profile pictures are not loaded.
- **Redraw** no more than once a second; the list is lazy.
- **Diagnostics** (P23): no active exit — the external-URL check is hidden
  and replaced by the line; with the VPN up the core's exit decides,
  otherwise the recorded `exit_node`.
- **Privacy** (P24): names, addresses, the network name, owners and the
  sign-in link never reach the app log, the support dump or the Debug API.
- The state subscription is counted: the home screen and every open tab hold
  it together; a config reload re-establishes it.

## Boundaries

- The NETWORKS row itself and the state mapping —
  [012-LIVE_STATE · P19](../../012-LIVE_STATE/FEATURE.md#promises); the
  Diagnostics tab — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).
- Exit switching, Log out and Ping are not verified on a device with a live
  tailnet (DEVICE-PENDING).
- Not shown: per-device traffic, connections through the node, SSH, Taildrop,
  `*.ts.net` certificates.
- An exit chosen on the fly survives a restart through the state directory
  while the body has no `exit_node`; `ephemeral: true` loses it.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [579](../../../tasks/579-networks-pseudo-direction.md) | Implemented, DEVICE-PENDING | The state stream bridge; NETWORKS row; the tab's follow-up decided |
| 2 | [581](../../../tasks/581-tailscale-network-tab.md) | Implemented, DEVICE-PENDING | The Network tab, exit node on the fly and Save choice, Ping, Diagnostics line, Debug API summary |
