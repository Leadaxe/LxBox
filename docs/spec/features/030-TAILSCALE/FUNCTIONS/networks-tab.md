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
network name, "signed in with a key", Sign in, Log out, Replace key, Node
enabled, Restart node), This device (name,
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
| Save choice | visible in `Running` when the active and the recorded exit differ and the node has a source record (own server or folder member) |
| Replace key | visible in `NeedsLogin` when the node has a source record; one hidden field, Save inactive while it is blank |
| Node enabled, Restart node | while the VPN is up and the core reports the node's state; Restart node only while the node is on |
| Written value | the active peer's Tailscale address, IPv4 first; without addresses — the MagicDNS name, then the host name; None removes `exit_node` |
| Ping | up to five replies or until the sheet closes; latency, direct or relay, endpoint address or relay region |
| Debug API | `GET /state` → `tailscale: {tag: {backend_state, devices}}` |

## Inputs / Outputs

**Inputs:** the core stream (`BackendState`, `StateText`, `AuthURL`,
`NetworkName`, `MagicDNSSuffix`, `KeyAuth`, self, exit node, peers by owner);
the reply of `GetTailscaleStatus(tag)` (the same record, every 3 seconds while
the tab is open); the tunnel status; the node body; taps: a list item, Save
choice, Sign in, Log out, Replace key, Node enabled, Restart node, Copy name, Copy MagicDNS name, Copy address, `+N`,
Ping.

**Outputs:** the tab; `GetTailscaleStatus`; `SetTailscaleExitNode` (a
`StableID` or empty), `TailscaleLogout`, `TailscaleLogin(tag, key)`,
`SetEndpointEnabled(tag, on/off)`, `StartTailscalePing`; the node source with
`exit_node` or `auth_key` changed and the config rebuilt; snackbars "Copied",
"Failed: …", the Replace key and Restart node outcomes; the
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
  auth key signs in again at the next start. "signed in with a key" shows
  only in `Running`: offline the key may have been rejected.
- **Replace key:** in `NeedsLogin` (a rejected key or none) a node with a
  source record has Replace key; a subscription node has none. The dialog
  has one hidden Auth key field with Show/Hide, as in the Add server wizard,
  Cancel and Save; Save is inactive while the field is blank. Save writes the
  trimmed key into `auth_key` the way Save choice writes `exit_node` (so it
  survives a restart), then the node signs in with it without restarting the
  VPN. The snackbar says "Signing in with the new key…"; with the tunnel down
  the core is not called and it says "Key saved. It applies when the VPN
  starts."; the core refusing a disabled node — "Turn the node on first.";
  any other refusal — "Could not sign in with the new key.". A rejected key
  shows later in the state and health lines, not in the snackbar. A failed
  write applies nothing.
- **Node enabled and Restart node:** while the VPN is up and the core reports
  the node's state, the Status block has the Node enabled switch ("Stays off
  until you turn it on or stop the VPN.") with the same behaviour and refusal
  texts as Turn off / Turn on in the node list and the switch of a WireGuard
  node. A node turned off rejects connections through it at once. Restart
  node, beside Sign in / Log out / Replace key, shows while the node is on:
  it turns the node off and on again, says "Node restarted." or the refusal
  text, and is inactive while the call runs.
- **Exit node** (P21): the list, the mismatch warning and Save choice only
  in `Running`. In any other state the core has no active exit and nothing
  is compared: a recorded `exit_node` shows as "Saved: <value>" with
  "Applies when the node is online.", no list and no button; nothing
  recorded — no block. Picking an item calls the core and switches the exit
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
- **This device:** Name (outside `Running` an empty name or `localhost`,
  which the core gives before sign-in, shows as `—`), MagicDNS name, then a
  single Address heading with
  every address of the device below it, one per line in the core's order (no
  addresses — no block); a tap on an address copies that address.
- **Devices** (P22): peers other than this device, online first then by name;
  the heading reads `Devices · <online> online / <listed>`. A row has three
  lines:
  1. a dot (green online, grey otherwise), the host name; on the right the
     first address;
  2. OS, `exit node`, `shared` joined by ` · ` (no `online`: the dot shows
     it); on the right the second address, and with more than two addresses
     `+N` with an arrow that unfolds the rest under the line and folds them
     back; too narrow — the left part is cut with an ellipsis, the address
     stays whole;
  3. how the device is reached, first match wins: `DIRECT` — a green bolt and
     `direct <endpoint>`; `DERP` — an orange cloud and `relay <region>`;
     `PEER_RELAY` — an orange hub and `peer relay`; no path, offline and a
     known last-seen time — `last seen 33h ago` (relative: `42s`, `5m`, `33h`
     up to 48 hours, then `17d`); otherwise nothing. `key expired` is
     appended; an empty line is not drawn. The handshake age is not shown here.
  A tap on a row opens the device page; a long press copies the first
  address (the host name when there is none) without opening it; a tap on
  `+N` only unfolds the addresses. Owner groups appear only with
  more than one owner; profile pictures are not loaded.
- **Device page:** a full screen with a back arrow and the host name as the
  title. On top a summary — the dot with `online` / `offline`, OS and roles
  as in the row's second line, the path line as in the row's third line.
  Then the buttons: Ping (when the device has an address; the same check
  sheet as before) and Send file…, which is always shown and, when it cannot
  send, is disabled with the reason under the buttons — the first that
  applies: `Taildrop is off for this node`, `File sharing is off in this
  tailnet`, `Device is offline`, `Device belongs to another user`, `Device
  can't receive files`. Allow Taildrop switched off on the other side is not
  visible in advance (the core does not publish it); it shows up as a refusal
  when sending. **Addresses:** Name, MagicDNS (when known) and every Tailscale
  address labelled IPv4 / IPv6; a tap copies the value, "Copied".
  **Taildrop:** the "Clipboard from this device" and "Links from this device"
  switches ([032-TAILDROP · clipboard-sync](../../032-TAILDROP/FUNCTIONS/clipboard-sync.md)),
  only when the node's Taildrop is on, the device has a stable ID and is not
  a shared-in machine; written at once; otherwise the block and its heading
  are absent. While the page is open the status calls go on and the page
  follows the device by stable ID; a device that left the record keeps its
  last known state. There is no bottom sheet with Copy items any more.
- **The active exit** in the Exit node list shows its path with the same icon
  and colour, plus the handshake age.
- **Live status:** while the tab or a device page is on screen, the app is
  in the foreground and the VPN is up, the tab calls the core's `GetTailscaleStatus(tag)` at
  once and then every 3 seconds. The reply is the full endpoint record (self,
  exit node, peers by owner, health) and the whole tab is built from it; until
  it arrives the tab shows what the stream gave. The record shown is the one
  that came last, from the call or from the stream; the stream also covers the
  events between ticks. The tab off screen, closed or the VPN down stops the
  calls; coming back calls at once. A core without the method stops the calls
  until the tab closes, the tab runs on the stream, nothing is shown or
  logged; an unknown tag or an endpoint that is not running skips the tick; a
  call still running skips the next tick.
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
- Exit switching, Log out, Ping, Replace key without a restart, Node enabled
  and Restart node are not verified on a device with a live tailnet
  (DEVICE-PENDING).
- Not shown: per-device traffic, connections through the node, SSH,
  `*.ts.net` certificates. Taildrop (the inbox block and "Send file…" on
  this tab) is [032-TAILDROP](../../032-TAILDROP/FEATURE.md).
- An exit chosen on the fly survives a restart through the state directory
  while the body has no `exit_node`; `ephemeral: true` loses it.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [579](../../../tasks/579-networks-pseudo-direction.md) | Implemented, DEVICE-PENDING | The state stream bridge; NETWORKS row; the tab's follow-up decided |
| 2 | [581](../../../tasks/581-tailscale-network-tab.md) | Implemented, DEVICE-PENDING | The Network tab, exit node on the fly and Save choice, Ping, Diagnostics line, Debug API summary |
| 3 | [645](../../../tasks/645-tailscale-devices-path-addresses.md) | Implemented, DEVICE-PENDING | Device rows in three lines with the path as an icon, addresses in a column, This device with one Address heading, `GetTailscaleStatus` every 3 s |
| 4 | [706](../../../tasks/706-tailscale-network-tab-logged-out.md) | Implemented, DEVICE-PENDING | Offline: the recorded exit as a line instead of the list and Save choice (it is no longer erased), the key chip only in Running, Replace key, Name `—` |
| 5 | [706](../../../tasks/706-tailscale-network-tab-logged-out.md) iteration 2 | Implemented, DEVICE-PENDING | Replace key signs in without restarting the VPN (core SPEC 149), Node enabled switch and Restart node in Status |
| 6 | [707](../../../tasks/707-taildrop-send-receive-files.md) iteration 6 | Implemented, emulator-verified | 2026-11-03: a tap on a device opens the device page (summary, Ping and Send file… with the reason, Addresses with copy on tap, Taildrop permissions) instead of the row menu; a long press copies the first address |
