[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Taildrop — files, text and clipboard between your own tailnet devices

LxBox sends and receives files through Taildrop, the file transfer built into
Tailscale, over a Tailscale node of the running config. A file goes out from
the system "Share" menu of any app or from a device page on the node's
Network tab; incoming files from the user's own devices land in that node's
inbox without a consent step. On top of the same transport the app exchanges
the clipboard and links with the desktop launcher (singbox-launcher): the
"📋 Send" button in the VPN notification opens a chat-like window
over the current app that sends the phone's clipboard (or shared or selected
text) to the PC, and text from a PC the user allowed lands in the phone's
clipboard by itself.

| Field | Value |
|-------|-------|
| Feature | 032-TAILDROP |
| Type | Product feature |
| Absorbed | — (new; owner decisions 2026-11-01) |
| State | ✍ Draft, 2026-11-01; implemented by task 707 (iterations 1–7, up to 2026-11-03), the state of each function is in its file |

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
never reads the clipboard on its own, only when the user opens the Send
clipboard window, and sends nothing without an explicit send.

## Promises

- **P1. "Share" from any app sends to an own online device.** The share screen
  asks for a Tailscale node only when the running config has more than one,
  then for a peer; the peer list holds only online devices of the same owner
  as this device. Several files go in one share. **Witness:** `no witness`
  (not implemented); planned manual check — share two photos from the
  gallery, the laptop receives both. **Mutation:** an offline or shared-in
  machine in the peer list.
- **P2. The device page on the Network tab offers "Send file…".** A tap on a
  device opens its page; "Send file…" opens the system file picker and sends
  the chosen files to that device. The button is always shown and is active
  only for an online own device that can receive files; otherwise it is
  disabled with the reason under it. **Witness:** widget test of the Network
  tab (device page, disabled Send file… with the reason), emulator check
  2026-11-03 (task 707, iteration 6). **Mutation:** an active button on a
  shared-in or offline machine.
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
- **P8. Shared or selected text opens the Send clipboard window.** Text or a
  link from "Share", or text selected in any app and sent with "Send to
  device" from the selection menu, opens the Send clipboard window with that
  text in the field instead of the clipboard; it leaves as a command file
  (`clipboard`, or `open_url` for one link), not as a note file. Until task
  707 (iteration 7) shared text went as `note-YYYY-MM-DD-HHMM.txt`; the note
  is now made only by the Debug API. **Witness:** `no witness` (planned
  manual check: share text and select text, the window shows it).
  **Mutation:** shared text sent without the window, or turned into a note
  file.
- **P9. "📋 Send" in the VPN notification sends the clipboard to
  the chosen device.** The button opens a window over the current app: the
  recipient `To: … ▾`, the feed with that device, the field filled with the
  clipboard text. ➤ sends the field as a `clipboard` command; "Open on
  <device>" (only when the field is exactly one `http(s)` link) sends
  `open_url`. The sent message lands on the right of the feed with ✓ or the
  error text. There is no Quick Settings tile for this (owner decision
  2026-11-03). **Witness:** JVM unit tests of the window logic (command file,
  "one link", feed, recipients and refusal order — task 707, iteration 7);
  the window itself `no witness` on a device. **Mutation:** a send to a
  device other than the one in `To:`.
- **P10. Clipboard text from an allowed PC goes straight into the phone's
  clipboard.** The clipboard file is consumed: its content is put into the
  clipboard, the file is deleted and never shows in the inbox; of several in
  a row the last one wins, a stale one is dropped. **Witness:** `no witness`;
  planned manual check with the launcher. **Mutation:** an applied clipboard
  file left in the inbox.
- **P11. Nothing leaves the phone without an explicit send.** The clipboard
  is read into the field of the window and leaves only on ➤ or "Open on
  <device>". A clip that Android marks as sensitive (a password) is shown in
  the field like any other: everything is visible before sending (owner
  decision 2026-11-03; until then such a clip was refused). **Witness:**
  `no witness`; planned manual check — copy from a password manager, open the
  window, nothing reaches the PC until ➤. **Mutation:** the window sending on
  open.
- **P12. The clipboard is accepted only from a device the user allowed.**
  "Clipboard from this device" (and "Links from this device" for links) on
  the device page is off by default; without it the command is not run and
  the file is deleted. A received clip is never sent back on its own.
  **Witness:** `no witness`; planned manual check — switch off, send from the
  launcher, the clipboard is untouched and nothing shows in the inbox.
  **Mutation:** the phone's clipboard overwritten by a device nobody allowed.

## Controlled parameters

| Knob | Values | Default |
|------|--------|---------|
| Node → "Allow Taildrop" (files and command files) | on / off; off — the core refuses incoming and outgoing transfers, the node is not in Share, no inbox and no "Send file…", commands are not handled; a node field in the core config, in the backup; needs a core option (requested 2026-11-02) | off (owner decision 2026-11-02) |
| Share screen → Node | a running Tailscale node; asked only when there are several | the only one |
| Share screen → Device | an online own device of that node's tailnet | — |
| Network tab → device page → "Send file…" | system file picker, one or more files; disabled with the reason when the device does not qualify | — |
| Network tab → inbox → Save / Delete | per file | — |
| Notification → Cancel (receiving), Save / Delete (received) | per transfer | — |
| VPN notification → "📋 Send" | shown while the VPN is up and the running config has a Tailscale node with Allow Taildrop; opens the Send clipboard window | — |
| Send clipboard window → `To: … ▾` | own devices that accept files, from all running Tailscale nodes with Allow Taildrop (with the node's name when there are several nodes); the choice is remembered | the remembered one, else the first |
| Send clipboard window → ⋮ → Clear | clears the feed with the chosen device | — |
| Text selection menu → "Send to device" | opens the Send clipboard window with the selected text; shown under the same condition as the notification button | — |
| Device page → Taildrop → "Clipboard from this device", "Links from this device" | a switch per own device and per kind, on the receiver | off |

Core config keys: the receive directory is the endpoint's
`taildrop_directory`; by default it is `Taildrop` relative to the core's
working directory (not the node's `state_directory`) and is therefore shared
by all Tailscale nodes. The build sets each node's to
`<state_directory>/taildrop`, so a node has its own inbox and it is deleted
with the node's state directory; an explicit `taildrop_directory` in the node
body is left alone.
Core build: the pinned core already carries Taildrop; no rebuild is needed.
Command files
(clipboard, links): the name format, the size limit, the TTL and the format
version are constants of the launcher contract (`docs/contract` and the
registry); proposed values — `lx-<time>-<tag>.json`, at most 64 KiB, TTL 2
minutes, UTF-8 JSON without BOM, `"lx": 1`.

## Inputs / Outputs

**Inputs:** the system share intent (files, text, links) from any app; the
text selection menu; the system file picker; taps on the Network tab, the
device page, the notifications and the Send clipboard window; the clipboard
when that window gets focus; incoming Taildrop files from own
devices; the core's tailnet state (which peers are online and whose);
the VPN and node state.

**Outputs:** Taildrop transfers to a peer; progress, receive and result
notifications; files in the node's inbox; files saved to Downloads; the
phone's clipboard set from an incoming clipboard file; command files to the
chosen device; the window's feed with ✓ or the error text.

## Data flow

```
Share (files)  → share screen → node (if several running) → own online peer → Taildrop send → progress notification
Share (text)   → Send clipboard window with that text in the field
Selection menu → "Send to device" → Send clipboard window with the selected text
Network tab    → tap on a device → device page "Send file…" → system picker → Taildrop send → progress notification
Incoming       → core accepts from an own device → clipboard prefix and sender allowed?
                 yes → fresh, valid, last of a burst? → content → phone clipboard · file deleted either way
                 no  → node inbox (node's Taildrop directory) → "receiving from X" (Cancel) → "file from X" (Save, Delete)
Inbox          → Network tab block under Devices → Save → Downloads · Delete → removed
Notification   → "📋 Send" → window over the current app reads the clipboard into the field on focus
                 → no VPN / no Allow Taildrop / no recipients / recipient offline / too big? reason above the field
                 : ➤ → clipboard command · "Open on <device>" → open_url → recipient → ✓ or error in the feed
Incoming run   → executed clipboard / open_url from that device → left side of the window's feed
Node deleted   → its Taildrop directory removed with its state
```

## Rules and guarantees

- The inbox is per node. Two Tailscale nodes in the config are two devices
  in (possibly different) tailnets, each with its own inbox; a notification
  and its tap target name the node the file came to.
- The peer lists (share screen, "Send file…", the window's recipients)
  contain only online devices of the same owner as this device. Shared-in machines and
  devices of other users of the tailnet never appear: Taildrop does not work
  with them.
- Receiving has no consent step for own devices, as in Tailscale. What arrives
  stays in the inbox until the user saves or deletes it, or the node is
  deleted.
- A command file that parses is never shown in the inbox: its commands run by
  the sender's permissions ("Clipboard / Links from this device"), or are
  dropped as stale, not allowed or superseded, and the file is deleted. One
  that does not parse stays an ordinary inbox file. A received clip is never
  sent back.
- The clipboard is read only when the Send clipboard window gets focus. There
  is no automatic sending on copy; nothing leaves without ➤ or "Open on
  <device>", and the window stays open after a send, like a chat.
- A clip marked as sensitive is shown in the field like any other and is sent
  only on ➤ (owner decision 2026-11-03).
- The window's feed lives only in memory while the VPN runs: a VPN stop or
  the death of the process wipes it; at most 50 messages per device, a tap on
  a message copies its text.
- "📋 Send", "Send to device" and LxBox in "Share" exist only while
  the VPN is up and the running config has a Tailscale node with Allow
  Taildrop; they follow the VPN start, stop and config reload, and are off
  after a process restart until the VPN is up again.
- File names, file contents, clipboard text and device names do not reach the
  app log, the support dump or the Debug API (the same rule as
  [030-TAILSCALE](../030-TAILSCALE/FEATURE.md#rules-and-guarantees)).
- The inbox is not part of the backup, like the node's state. Neither are the
  window's remembered recipient and the "Clipboard / Links from this device"
  switches (owner
  decision 2026-11-02): they are settings of this phone in this tailnet.

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
  later forbid it); the Send clipboard window reads it when it is in the
  foreground. There is no Quick Settings tile for the clipboard. Writing the
  clipboard from the background is allowed, so the PC → phone direction
  needs no window.
- Not a KDE Connect clone: notifications mirroring, SMS, remote control,
  media control and the like are outside the feature.
- Tailscale SSH — see [030-TAILSCALE](../030-TAILSCALE/FEATURE.md#boundaries)
  (decided there).
- Debug API routes for Taildrop (`/taildrop/*`) are described in `docs/api/debug-api-reference.md` (task 707, iteration 5).
- Not verified on a device; the device page is verified on an emulator.

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Send files | Sends files to an own online device from the system "Share" menu or from the device page on the Network tab, with node and peer choice and progress in a notification. | P1–P3, P7 | [send-files.md](FUNCTIONS/send-files.md) |
| Inbox | Accepts files from own devices without a prompt into the node's inbox, notifies with Cancel / Save / Delete, shows the inbox on the Network tab and deletes it with the node. | P4–P7 | [inbox.md](FUNCTIONS/inbox.md) |
| Share text | Opens the Send clipboard window with text from "Share" or from "Send to device" in the selection menu. | P8 | [share-text.md](FUNCTIONS/share-text.md) |
| Command files (clipboard, links) | Sends the clipboard and links to the chosen device as command files from the Send clipboard window (the notification button); runs clipboard and link commands from an allowed device. | P9–P12 | [clipboard-sync.md](FUNCTIONS/clipboard-sync.md) |

## Related features

- [030-TAILSCALE](../030-TAILSCALE/FEATURE.md) — the Tailscale node, its state
  directory that the Taildrop directory lives next to and leaves with
  (device-identity-and-state), and the Network tab that gets the inbox block
  and the device page with "Send file…" and the Taildrop permissions
  (networks-tab).
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — the tunnel must be up for
  anything to move ([P7](#promises)); its notification carries the
  "📋 Send" button ([010-VPN_SERVICE · P20](../010-VPN_SERVICE/FEATURE.md#promises)).
- [014-AUTOMATION](../014-AUTOMATION/FEATURE.md) — the Quick Settings tile
  stays one, the tunnel toggle; there is no "Send clipboard" tile (owner
  decision 2026-11-03).
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
- **Files received before the feature** into the core's shared default
  folder are moved once into the inbox of the first Tailscale node in config
  order; the shared folder is removed after the move. **Open:** whether
  receiving works in the userspace network stack on a real device (by code —
  yes).
- The launcher's clipboard side is its own spec.
- **Clipboard protocol is the launcher contract's.** The prefix, the size
  limit, the TTL and the encoding are constants in `docs/contract` and the
  registry, the contract version is opened by the launcher; the numbers in
  this spec are the current values, and the contract wins on a mismatch. The
  source of a clip is the Taildrop sender, the file name carries no marker.
- **Core API for the app** (present in the lx.29 pin): `subscribeTaildropInbox`,
  `sendTaildropFiles` (+ `TaildropSendSession.writeChunk` / `finishFile`),
  `downloadTaildropFile`, `deleteTaildropFile`, `cancelTaildropReceiving`,
  `markTaildropInboxRead`; the node status has `canShareFiles`, a peer has
  `canReceiveFiles` (the core already applied the send right and own/foreign).
  The core itself sends "receiving…" and "received…" notifications with the
  address `sing-box:taildrop?endpoint=<tag>`.
- Nothing here has run on a device; the device page and iterations 1–5 ran
  on an emulator.
