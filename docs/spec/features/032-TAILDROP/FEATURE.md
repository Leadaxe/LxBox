[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Taildrop — files, text and clipboard between your own tailnet devices

LxBox sends and receives files through Taildrop, the file transfer built into
Tailscale, over a Tailscale node of the running config. A file goes out from
the system "Share" menu of any app or from a peer row on the node's Network
tab; incoming files from the user's own devices land in that node's inbox
without a consent step. Shared text travels as a small `.txt` note. On top of
the same transport the app keeps the clipboard in step with the desktop
launcher (singbox-launcher): a Quick Settings tile sends the phone's clipboard
to the PC, and text from a PC the user allowed lands in the phone's clipboard
by itself.

| Field | Value |
|-------|-------|
| Feature | 032-TAILDROP |
| Type | Product feature |
| Absorbed | — (new; owner decisions 2026-11-01) |
| State | ✍ Draft, 2026-11-01 — not implemented, nothing verified on a device |

## Purpose

A user who already has the phone in their tailnet through LxBox wants to move
a photo, a document or a link to their laptop and back without a messenger, a
cloud drive or a second VPN app. The official Tailscale client does this with
Taildrop; LxBox runs Tailscale inside its own tunnel, so it has to offer the
same thing for its node. The clipboard sync answers the most frequent case —
"I copied this here, I need it there" — for the pair phone + desktop launcher.

What happens today, without this feature: the pinned core already carries
Taildrop, and when Taildrop is enabled in the tailnet's admin console it
silently accepts files from the user's own devices into a `Taildrop` folder
under its working directory. Nobody sees them: there is no screen for them,
finished files stay there forever, only unfinished `.partial` files older than
an hour are removed. The feature makes this inbox visible and manageable.

Principles: **own devices only** — Taildrop between machines of one owner, no
sharing with strangers or shared-in machines; **compatible with the official
clients** — a file or a note sent from LxBox is an ordinary Taildrop file on
the other side, and an ordinary Taildrop file sent to LxBox is an ordinary
file here; **the inbox belongs to the node** — every Tailscale node has its own
inbox, and it goes away with the node; **no background snooping** — the phone
never reads the clipboard on its own, only on an explicit tap.

## Promises

- **P1. "Share" from any app sends to an own online device.** The share screen
  asks for a Tailscale node only when the running config has more than one,
  then for a peer; the peer list holds only online devices of the same owner
  as this device. Several files go in one share. **Witness:** `no witness`
  (not implemented); planned manual check — share two photos from the
  gallery, the laptop receives both. **Mutation:** an offline or shared-in
  machine in the peer list.
- **P2. A peer row on the Network tab offers "Send file…".** It opens the
  system file picker and sends the chosen files to that peer; the item exists
  only for an online own device. **Witness:** `no witness`; planned manual
  check. **Mutation:** the item on a shared-in machine.
- **P3. Sending shows progress in a notification.** The notification names the
  peer and the progress until the transfer ends or fails. **Witness:**
  `no witness`; planned manual check with a large file. **Mutation:** a share
  screen that blocks until the transfer is over with no notification.
- **P4. Files from own devices are accepted without a consent step.** They
  land in the inbox of the node they arrived on; while a file is coming in a
  notification "receiving from X" offers Cancel, when it is done the
  notification "file from X" offers Save and Delete. **Witness:**
  `no witness`; planned manual check — send from the laptop, no prompt on the
  phone. **Mutation:** an accept/decline prompt before the transfer.
- **P5. The inbox is a block on the node's Network tab.** It sits under
  Devices; each file has Save (to Downloads) and Delete. A tap on a Taildrop
  notification opens the Network tab of the node the file came to.
  **Witness:** `no witness`; planned manual check with two Tailscale nodes.
  **Mutation:** a tap that opens the tab of another node.
- **P6. Received files stay with the node until saved or deleted.** An unsaved
  file lives in the node's Taildrop directory and survives an app and VPN
  restart; deleting the node deletes its inbox. **Witness:** `no witness`;
  planned manual check. **Mutation:** an inbox emptied by a VPN restart, or
  files left behind after the node is deleted.
- **P7. Nothing moves while the VPN is down or the node is not running.**
  Sending is unavailable, and nothing is received. **Witness:** `no witness`;
  planned manual check — VPN off, send from the laptop, the phone gets
  nothing. **Mutation:** a share that silently queues while the VPN is off.
- **P8. Shared text goes as a note file.** Text or a link from "Share" becomes
  `note-YYYY-MM-DD-HHMM.txt` and travels as a regular Taildrop file; an
  official client shows it as a file. **Witness:** `no witness`; planned
  manual check — share a link to a PC with the official client. **Mutation:**
  a text transfer the official client does not recognise as a file.
- **P9. The "Send clipboard" tile sends the clipboard to the chosen PC.** One
  tap reads the clipboard, sends it to the target device chosen in settings
  and shows "Sent to <PC>". **Witness:** `no witness`; planned manual check
  with the launcher. **Mutation:** the tile sending to a device other than the
  chosen target.
- **P10. Clipboard text from an allowed PC goes straight into the phone's
  clipboard.** The clipboard file is consumed: its content is put into the
  clipboard, the file is deleted and never shows in the inbox; of several in
  a row the last one wins, a stale one is dropped. **Witness:** `no witness`;
  planned manual check with the launcher. **Mutation:** an applied clipboard
  file left in the inbox.
- **P11. Sensitive clipboard content is not sent.** A clip that Android marks
  as sensitive (a password) is refused by the tile with a notification.
  **Witness:** `no witness`; planned manual check — copy from a password
  manager, tap the tile. **Mutation:** the password reaching the PC.
- **P12. The clipboard is accepted only from a device the user allowed.**
  "Accept clipboard from <device>" is off by default; without it a clipboard
  file is an ordinary inbox file. A received clip is never sent back on its
  own. **Witness:** `no witness`; planned manual check — switch off, send from
  the launcher, the file appears in the inbox and the clipboard is untouched.
  **Mutation:** the phone's clipboard overwritten by a device nobody allowed.

## Controlled parameters

| Knob | Values | Default |
|------|--------|---------|
| Share screen → Node | a running Tailscale node; asked only when there are several | the only one |
| Share screen → Device | an online own device of that node's tailnet | — |
| Network tab → peer row → "Send file…" | system file picker, one or more files | — |
| Network tab → inbox → Save / Delete | per file | — |
| Notification → Cancel (receiving), Save / Delete (received) | per transfer | — |
| Clipboard sync → target device | one own device of one Tailscale node, chosen once; the place of the setting on screen is open | not set |
| "Accept clipboard from <device>" | a switch per own device, on the receiver | off |
| Quick Settings tile "Send clipboard" | added by the user from the system tile list | not added |

Core config keys: the receive directory is the endpoint's
`taildrop_directory`; by default it is `Taildrop` relative to the core's
working directory (not the node's `state_directory`) and is therefore shared
by all Tailscale nodes. A per-node inbox needs a per-node `taildrop_directory`.
Core build: the pinned core already carries Taildrop; no rebuild is needed.
Clipboard protocol:
the file name prefix, the size limit, the TTL and the encoding are constants of
the launcher contract (`docs/contract` and the registry); current values —
prefix `lxclip-`, at most 64 KiB, TTL 2 minutes, valid UTF-8 without BOM.

## Inputs / Outputs

**Inputs:** the system share intent (files, text, links) from any app; the
system file picker; taps on the Network tab, the notifications and the tile;
the clipboard at the moment of a tile tap; incoming Taildrop files from own
devices; the core's tailnet state (which peers are online and whose);
the VPN and node state.

**Outputs:** Taildrop transfers to a peer; progress, receive and result
notifications; files in the node's inbox; files saved to Downloads; the
phone's clipboard set from an incoming clipboard file; "Sent to <PC>".

## Data flow

```
Share (files)  → share screen → node (if several running) → own online peer → Taildrop send → progress notification
Share (text)   → note-YYYY-MM-DD-HHMM.txt → same path as files
Network tab    → peer row "Send file…" → system picker → Taildrop send → progress notification
Incoming       → core accepts from an own device → clipboard prefix and sender allowed?
                 yes → fresh, valid, last of a burst? → content → phone clipboard · file deleted either way
                 no  → node inbox (node's Taildrop directory) → "receiving from X" (Cancel) → "file from X" (Save, Delete)
Inbox          → Network tab block under Devices → Save → Downloads · Delete → removed
Tile           → transparent window reads clipboard → empty / too big / not UTF-8 / sensitive? refuse with reason
                 : clipboard file → target PC → "Sent to <PC>"
Node deleted   → its Taildrop directory removed with its state
```

## Rules and guarantees

- The inbox is per node. Two Tailscale nodes in the config are two devices
  in (possibly different) tailnets, each with its own inbox; a notification
  and its tap target name the node the file came to.
- The peer lists (share screen, "Send file…", clipboard target) contain only
  online devices of the same owner as this device. Shared-in machines and
  devices of other users of the tailnet never appear: Taildrop does not work
  with them.
- Receiving has no consent step for own devices, as in Tailscale. What arrives
  stays in the inbox until the user saves or deletes it, or the node is
  deleted.
- A file with the clipboard prefix from a sender with "Accept clipboard from
  <device>" on is never shown in the inbox: it is consumed into the clipboard
  (or dropped as stale, invalid or superseded) and deleted. From any other
  sender it is an ordinary inbox file. A received clip is never sent back.
- The clipboard is read only on a tap of the "Send clipboard" tile. There is no
  automatic sending on copy.
- A clip marked as sensitive is not sent; the tile says so instead of sending.
- File names, file contents, clipboard text and device names do not reach the
  app log, the support dump or the Debug API (the same rule as
  [030-TAILSCALE](../030-TAILSCALE/FEATURE.md#rules-and-guarantees)).
- The inbox is not part of the backup, like the node's state.

## Boundaries

- Own devices of the tailnet only. Shared-in machines and other users'
  devices are out of reach of Taildrop itself.
- Only while the VPN is up and the Tailscale node is running. With the VPN off
  nothing is received — unlike the official client, which keeps its own VPN up
  all the time; a file sent to the phone then fails on the sender's side.
- Taildrop must be enabled in the tailnet's admin console: this node needs
  the file sharing capability, and the sender must be an own untagged device
  or hold the file-sharing-send right. Without it the feature does not work,
  and the UI says why instead of doing nothing.
- Taildrop in Tailscale itself is in alpha.
- No clipboard sync with the official Tailscale clients: they receive a
  clipboard file as an ordinary file named with the prefix. The clipboard
  pairs with the launcher only.
- The phone does not read the clipboard in the background (Android 10 and
  later forbid it); the tile opens a transparent window for a fraction of a
  second to read it. Writing the clipboard from the background is allowed, so
  the PC → phone direction needs no window.
- Not a KDE Connect clone: notifications mirroring, SMS, remote control,
  media control and the like are outside the feature.
- Tailscale SSH — see [030-TAILSCALE](../030-TAILSCALE/FEATURE.md#boundaries)
  (decided there).
- No Debug API routes for Taildrop in this draft.
- Nothing is implemented or verified on a device.

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Send files | Sends files to an own online device from the system "Share" menu or from a peer row on the Network tab, with node and peer choice and progress in a notification. | P1–P3, P7 | [send-files.md](FUNCTIONS/send-files.md) |
| Inbox | Accepts files from own devices without a prompt into the node's inbox, notifies with Cancel / Save / Delete, shows the inbox on the Network tab and deletes it with the node. | P4–P7 | [inbox.md](FUNCTIONS/inbox.md) |
| Share text | Turns shared text or a link into a `note-YYYY-MM-DD-HHMM.txt` file and sends it as a regular Taildrop file. | P8 | [share-text.md](FUNCTIONS/share-text.md) |
| Clipboard sync | Sends the phone's clipboard to the chosen PC from a Quick Settings tile and puts clipboard text from an allowed launcher into the phone's clipboard. | P9–P12 | [clipboard-sync.md](FUNCTIONS/clipboard-sync.md) |

## Related features

- [030-TAILSCALE](../030-TAILSCALE/FEATURE.md) — the Tailscale node, its state
  directory that the Taildrop directory lives next to and leaves with
  (device-identity-and-state), and the Network tab that gets the inbox block
  and the "Send file…" item (networks-tab).
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — the tunnel must be up for
  anything to move ([P7](#promises)).
- [014-AUTOMATION](../014-AUTOMATION/FEATURE.md) — the existing Quick Settings
  tile that toggles the tunnel; "Send clipboard" is a second, separate tile.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — the inbox
  is node state and stays out of the backup.
- [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.md) — the pinned core that
  already carries Taildrop and the launcher contract that fixes the clipboard
  protocol. The launcher side: clipboard on macOS, Windows and remote lxd
  (through gRPC), none on Linux classic and Windows 386; the tray item "Send
  clipboard to <phone>", no global hotkey.

## Maintenance notes

- **The core already has Taildrop.** sing-box has its own Taildrop (a
  peerapi handler for `/v0/put/`), and the `ts_omit_taildrop` build tag does
  not cut it out — the tag is a no-op for it (measured 2026-11-02: the `.so`
  size and `classes.jar` are byte-identical with and without it). The current
  pin needs no rebuild. The desktop launcher's core has Taildrop too; nothing
  to do in the core on either side. Checked by the core session from the code,
  not on a device.
- **Receiving is automatic today** (see Purpose): files go into
  `taildrop_directory` (default `Taildrop` under the core's working
  directory), outside any UI; `.partial` files older than an hour are
  removed, finished ones stay. The core also posts its own "receiving…"
  platform notification; the implementation has to fit its notifications
  around it.
- **Sending** takes a file name and a size (a negative size means unknown)
  and the app streams the content in chunks, so a shared `content://` source
  is read directly, with no temporary copy. Sending needs the service running
  with this node — the same as "only while the VPN is up".
- **Open:** what happens to files the core has already put into the shared
  default folder before the feature; whether receiving works in the userspace
  network stack on a real device (by code — yes).
- The launcher's clipboard side is its own spec.
- **Clipboard protocol is the launcher contract's.** The prefix, the size
  limit, the TTL and the encoding are constants in `docs/contract` and the
  registry, the contract version is opened by the launcher; the numbers in
  this spec are the current values, and the contract wins on a mismatch. The
  source of a clip is the Taildrop sender, the file name carries no marker.
- **Open questions in the app:** whether the clipboard target and the
  "Accept clipboard from <device>" switches go into the backup; where on
  screen the target is chosen.
- Nothing here has run on a device: the feature is not implemented.
