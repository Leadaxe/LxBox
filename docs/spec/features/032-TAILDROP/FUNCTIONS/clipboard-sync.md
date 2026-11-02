[English](clipboard-sync.md) · [Русский](clipboard-sync.ru.md)

# Command files — clipboard and links between the phone and the launcher

A Taildrop file of a special form carries commands. LxBox or the desktop
launcher (singbox-launcher) receiving it from an allowed device runs the
commands and deletes the file; such a file never reaches the inbox or
Downloads. Two commands exist: put text on the clipboard and open a link.
Phone → PC: the "Send clipboard" tile and "Share" with a link. PC → phone:
clipboard and links from an allowed device.

| Field | Value |
|-------|-------|
| Feature | [032-TAILDROP](../FEATURE.md) |
| Promises | P9–P12 |
| State | 🟡 Partial, 2026-11-02 — receiving implemented (task 707, iteration 4: commands run, file deleted, per-device permissions); sending — iteration 5. Contract 1.1.148–1.1.150 |

## What it does

**Phone → PC, clipboard.** The user adds the "Send clipboard" tile to Quick
Settings. A tap opens a transparent window for a split second: Android 10+
lets an app read the clipboard only from a foreground window. The window
reads the clipboard, checks it, sends it to the target device as a command
file with a `clipboard` command and closes; a notification says "Sent to
<PC>". The target device is chosen once in the Settings block of the node's
Network tab.

**Phone → PC, link.** "Share" with text that is exactly one `http(s)` link.
After the device is chosen the phone asks "Open on <device>" or "Send as
note". The first sends an `open_url` command, the second a note as today
(P8).

**PC → phone.** A file arrives whose name matches the command-file format and
whose body parses. Each command runs if the receiver allows that kind from
that sender. Then the file is deleted, whatever happened to the commands. If
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
| Tile | "Send clipboard", separate from the tunnel tile |
| Clipboard target device | one own device of one Tailscale node; chosen once in the Settings block of the node's Network tab |
| Permissions | on the receiver, per own device and per kind: "Clipboard from <device>", "Links from <device>"; off by default; in the device menu on the node's Network tab |
| Freshness (TTL) | 2 minutes by the receiver's clock from receipt; older — deleted without running |
| Size | at most 64 KiB |
| Backup | the target and the permissions are not in the backup (owner decision 2026-11-02) |
| Send confirmation | notification "Sent to <PC>" |

Prefix, suffix, size limit, TTL and format version are constants of the
contract with the launcher (`docs/contract` and the registry). The format
replaces the `lxclip-*` protocol of contract 1.1.146, which neither side
implemented.

## Inputs / Outputs

**Inputs:** a tile tap and the clipboard at that moment; "Share" with a link;
incoming command files and their Taildrop sender; the chosen target;
permissions.

**Outputs:** a command file to the target device; a "Sent to <PC>"
notification or a refusal with the reason; the phone clipboard; a link
notification; a warning in the app log about a broken command file.

## Rules and invariants

- **Sending the clipboard.** The clipboard is read only on a tile tap;
  nothing is sent on copy. The tile does not send and shows the reason when
  the clip is empty, over the limit, not valid UTF-8 or marked sensitive by
  Android (passwords, P11); and when no target is chosen, the target is
  offline, the VPN is off or the node is not running.
- **Receiving** (P12). A command runs only if its kind is allowed for its
  sender. The sender is the Taildrop sender.
- **Interception.** A command file is handled before auto-save and the
  "received" notification ([inbox](inbox.md)): once parsed it reaches neither
  Downloads nor the inbox (P10).
- **Deletion.** After handling the file is always deleted, even if no command
  ran (no permission, expired).
- **Freshness.** A file older than the TTL when the receiver finds it is
  deleted without running.
- **Bursts.** Of several `clipboard` commands in a row the last received
  wins.
- **Security.** Tailscale authenticates the sender: files come only from own
  devices (or an ACL grant). Any program on an allowed device can send a
  command file — hence only harmless commands. No arbitrary commands,
  scripts, paths or intents in the body.
- **No loop back.** A received command is never forwarded on its own.
- Clipboard text and links are not written to the app log, the support dump
  or the Debug API.

## Boundaries

- Between LxBox and the launcher only. The official Tailscale client shows a
  command file as an ordinary `.json`.
- No background clipboard reading and no automatic sending on copy.
- Text only; images and other clip types are not sent.
- VPN control and adding subscriptions are not in this version.
- The launcher side is its own spec: clipboard on macOS, Windows and remote
  lxd (over gRPC), none on Linux classic and Windows 386; sending from the PC
  is a tray item "Send clipboard to <phone>", no global hotkey.
- Not verified on a device.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| — | — | Draft | 2026-11-01: clipboard via `lxclip-*` (contract 1.1.146). 2026-11-02: one command-file format for all commands, no pairing, commands — clipboard and link |
