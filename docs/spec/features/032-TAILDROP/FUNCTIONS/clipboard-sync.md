[English](clipboard-sync.md) · [Русский](clipboard-sync.ru.md)

# Command files — clipboard and links between the phone and the launcher

A Taildrop file of a special form carries commands. LxBox or the desktop
launcher (singbox-launcher) receiving it from an own device runs the
commands and deletes the file; such a file never reaches the inbox or
Downloads. Two commands exist: put text on the clipboard and open a link.
Phone → PC: the Send clipboard window, opened from the "📋 Send"
button in the VPN notification, from "Share" with text or from "Send to
device" in the text selection menu. PC → phone: clipboard and links from own
devices, when the receiving node has "Accept clipboard and links from my
devices" on.

| Field | Value |
|-------|-------|
| Feature | [032-TAILDROP](../FEATURE.md) |
| Promises | P9–P12 |
| State | ✅ implemented, 2026-11-03 — receiving (task 707, iteration 4: commands run, file deleted, per-device permissions), permissions on the device page (iteration 6), sending from the Send clipboard window (iteration 7); iteration 9: settings in the node record, per-device permissions removed; the window not verified on a device. Contract 1.1.148–1.1.150 |

## What it does

**Phone → PC: the Send clipboard window.** The VPN notification has the
"📋 Send" button. It opens a chat-like window over the current app
(the lower half of the screen, its own task: the main LxBox window does not
come up). Android 10+ lets an app read the clipboard only from a foreground
window, so the window reads it when it gets focus and puts the text into the
field; an empty clipboard or a non-text clip leaves the field empty.

```
📋  To: LexRouter ▾          ⋮    ✕
                  https://ya.ru      sent · 12:40 ✓
ssh root@10.0.0.5                    from LexRouter · 12:42
[ text from the clipboard, editable ]  [➤]
[ Open on LexRouter ]   ← only for one link
```

- **Recipient** `To: … ▾` — own devices that accept files, from all running
  Tailscale nodes with Allow Taildrop; with several nodes a device is shown
  with its node. The choice is remembered and comes back next time; a
  remembered device that is not in the list gives way to the first one.
- **➤** sends the field as a command file with a `clipboard` command; the
  field is cleared, the window stays open.
- **Open on <device>** appears under the field only when the text is exactly
  one `http(s)` link (after trimming, no spaces inside) and sends `open_url`.
- **Feed** — the conversation with the chosen device: what was sent is on the
  right with the time, ✓ on success or the error text under the message;
  what came from that device and was run by the node setting (`clipboard`,
  `open_url`) is on the left. A tap on a message copies its text, "Copied".
  `⋮ → Clear` clears the feed with this device.
- The window closes with ✕, Back or a tap outside it.

**Phone → PC: shared and selected text.** "Share" with text (no files) opens
the same window with that text in the field instead of the clipboard
([share text](share-text.md)). Text selected in any app and sent with "Send
to device" from the selection menu does the same; the text in the source app
does not change.

**PC → phone.** A file arrives whose name matches the command-file format and
whose body parses. The commands run if the sender is an own device and the
receiving node has "Accept clipboard and links from my devices" on. Then the file is deleted, whatever happened to the commands. If
the name matches but the body does not parse or the version is unknown, the
file stays an ordinary inbox file.

## Format

**Name:** `lx-<time>-<tag>.json`
- `<time>` — sender UTC, `YYYYMMDDTHHMMSSZ`;
- `<tag>` — 5 random `[a-z0-9]` characters;
- the core may rename on a name clash; the receiver recognises a command
  file by the `lx-` prefix and the `.json` suffix.

No content hash is checked in the name: without a shared secret it protects
nothing (owner decision 2026-11-02 — no pairing).

**Body:** UTF-8 JSON without BOM, at most 64 KiB.

```json
{"lx": 1, "commands": [
  {"kind": "clipboard", "text": "…"},
  {"kind": "open_url", "url": "https://…"}
]}
```

- `lx` — format version; an unknown version means an ordinary file.
- `commands` — in order; an unknown `kind` is skipped, the rest run.

## Commands

| `kind` | Field | What the receiving phone does | Limits |
|--------|-------|-------------------------------|--------|
| `clipboard` | `text` | puts the text on the clipboard | not empty; line breaks as is; of several in a row the last received wins |
| `open_url` | `url` | notification "Link from <device>: <url>", a tap opens it in the browser | `http`/`https` only; any other scheme skips the command |

On the phone `open_url` goes through a notification: Android does not let a
background service open windows. The tap is the confirmation. On the desktop
the launcher decides.

## Parameters

| What | Value |
|------|-------|
| Notification button | "📋 Send" next to Stop; there is no Quick Settings tile (owner decision 2026-11-03) |
| Where the window and its entries exist | "📋 Send", "Send to device" and LxBox in "Share" — only while the VPN is up and the running config has a Tailscale node with Allow Taildrop |
| Recipient | `To: … ▾` in the window: own devices that accept files, from all such nodes; remembered on this phone |
| Feed | in memory only while the VPN runs; at most 50 messages per device (node + device); `⋮ → Clear` |
| Receive setting | one per receiving node: "Accept clipboard and links from my devices" in the Taildrop panel of the Network tab; the node record field `taildrop_commands`; off by default; in the backup; sharees do not count as own; a subscription node has no such setting |
| Freshness (TTL) | 2 minutes by the receiver's clock from receipt; older — deleted without running |
| Size | at most 64 KiB |
| Backup | the remembered recipient is Kotlin's cache on this phone, not in the backup; the receive setting is in the backup |
| Send confirmation | ✓ or the error text under the message in the feed; no separate notification |

Prefix, suffix, size limit, TTL and format version are constants of the
contract with the launcher (`docs/contract` and the registry). The format
replaces the `lxclip-*` protocol of contract 1.1.146, which neither side
implemented.

## Inputs / Outputs

**Inputs:** a tap on "📋 Send" and the clipboard when the window
gets focus; "Share" with text; "Send to device" with selected text; ➤ and
"Open on <device>"; incoming command files and their Taildrop sender; the
chosen recipient; the node's receive setting.

**Outputs:** a command file to the chosen device; ✓ or the error in the
feed, or a refusal reason above the field; the phone clipboard; a link
notification; incoming commands that ran, in the feed of their sender; a
warning in the app log about a broken command file.

## Rules and invariants

- **Sending.** The clipboard is read only when the window gets focus;
  nothing is sent on copy and nothing leaves without ➤ or "Open on <device>"
  (P11). A clip that Android marks as sensitive (a password) is shown in the
  field like any other: everything is visible before sending (owner decision
  2026-11-03; the contract rule "do not send a sensitive clip" is about
  sending without showing).
- **Refusals.** ➤ and "Open on" are disabled and the reason stands above the
  field, the first that applies: the VPN is off or no Tailscale node runs —
  `Start VPN to send`; no node has Allow Taildrop — `Taildrop is off for this
  node.`; no device accepts files — `No devices accept files`; the recipient
  is offline — `Device is offline.`; the text is over the size limit — `Too
  large to send`. An empty field disables the buttons without a reason. A
  core error during the send shows under the message in the feed.
- **Feed.** Only in memory: a VPN stop and the death of the process wipe it;
  there is no file. Clipboard text and links in it never reach the app log
  or the Debug API; the Debug API shows only the remembered recipient (its
  name with `reveal`) and the number of messages per feed.
- **Receiving** (P12). A command runs only if the receiving node has the
  receive setting on and the sender is an own device. The sender is the
  Taildrop sender; a sharee does not count as own.
- **Interception.** A command file is handled before auto-save and the
  "received" notification ([inbox](inbox.md)): once parsed it reaches neither
  Downloads nor the inbox (P10).
- **Deletion.** After handling the file is always deleted, even if no command
  ran (setting off, sender not own, expired).
- **Freshness.** A file older than the TTL when the receiver finds it is
  deleted without running.
- **Bursts.** Of several `clipboard` commands in a row the last received
  wins.
- **Security.** Tailscale authenticates the sender: files come only from own
  devices (or an ACL grant). Any program on an own device can send a
  command file — hence only harmless commands. No arbitrary commands,
  scripts, paths or intents in the body.
- **No loop back.** A received command is never forwarded on its own.
- Clipboard text and links are not written to the app log, the support dump
  or the Debug API.

## Boundaries

- Between LxBox and the launcher only. The official Tailscale client shows a
  command file as an ordinary `.json`.
- No background clipboard reading and no automatic sending on copy; no Quick
  Settings tile for the clipboard.
- Text only; images and other clip types are not sent.
- VPN control and adding subscriptions are not in this version.
- The launcher side is its own spec: clipboard on macOS, Windows and remote
  lxd (over gRPC), none on Linux classic and Windows 386; sending from the PC
  is a tray item "Send clipboard to <phone>", no global hotkey.
- Not verified on a device: the window, reading the clipboard on focus, the
  selection menu entry, switching the entries on and off, the notification
  button. The window logic is covered by JVM unit tests (task 707,
  iteration 7).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| — | — | Draft | 2026-11-01: clipboard via `lxclip-*` (contract 1.1.146). 2026-11-02: one command-file format for all commands, no pairing, commands — clipboard and link |
| 1 | [707](../../../tasks/707-taildrop-send-receive-files.md) iteration 4 | Implemented | Receiving: commands run by per-device permission, the file is deleted |
| 2 | [707](../../../tasks/707-taildrop-send-receive-files.md) iteration 6 | Implemented, emulator-verified | 2026-11-03: the permissions moved from the row menu to the device page |
| 3 | [707](../../../tasks/707-taildrop-send-receive-files.md) iteration 7 | Implemented, not verified on a device | 2026-11-03: the Send clipboard window from the notification button instead of the tile and the target in Settings; shared and selected text open it; a sensitive clip is shown and sent only on ➤; the feed in memory |
| 4 | [707](../../../tasks/707-taildrop-send-receive-files.md) iteration 9 | In progress | 2026-11-04: per-device permissions removed; one node setting "Accept clipboard and links from my devices" — a record field, in the backup |
