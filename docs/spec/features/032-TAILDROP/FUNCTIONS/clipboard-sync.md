[English](clipboard-sync.md) · [Русский](clipboard-sync.ru.md)

# Clipboard sync — the phone's clipboard and the desktop launcher

The clipboard moves between LxBox and the desktop launcher (singbox-launcher)
over Taildrop. Phone → PC: a Quick Settings tile "Send clipboard". PC →
phone: clipboard text from a device the user allowed goes into the phone's
clipboard by itself.

| Field | Value |
|-------|-------|
| Feature | [032-TAILDROP](../FEATURE.md) |
| Promises | P9–P12 |
| State | ✍ Draft, 2026-11-01 — not implemented |

## What it does

**Phone → PC.** The user adds the "Send clipboard" tile to Quick Settings. A
tap opens a transparent window for a fraction of a second: Android 10 and
later let an app read the clipboard only from a window in the foreground. The
window reads the clipboard, checks it, sends it to the target device as a
clipboard file and closes; a notification says "Sent to <PC>". The target
device is chosen once in settings.

**PC → phone.** A Taildrop file whose name carries the clipboard prefix, from
a device for which the user turned on "Accept clipboard from <device>", is not
put into the inbox: its content goes into the phone's clipboard (writing the
clipboard from the background is allowed) and the file is deleted. From any
other sender, or with the switch off, the same file is an ordinary inbox
file.

## Parameters

| What | Value |
|------|-------|
| Tile | "Send clipboard", separate from the tunnel tile |
| Target device | one own device of one Tailscale node; chosen once; the place of the setting on screen is open |
| "Accept clipboard from <device>" | a switch per own device, on the receiver; off by default |
| Transport | a Taildrop file whose name starts with the clipboard prefix (current value `lxclip-`) |
| Size limit | current value 64 KiB |
| Encoding | valid UTF-8 without BOM; line breaks are not normalised |
| Freshness (TTL) | current value 2 minutes, counted by the receiver's clock from the moment the file is found |
| Confirmation | notification "Sent to <PC>" |

The prefix, the limit, the TTL and the encoding are constants of the launcher
contract (`docs/contract` and the registry; the launcher opens the contract
version). The values above are the current ones; the contract is the source.

## Inputs / Outputs

**Inputs:** a tap on the tile; the clipboard at that moment; incoming
clipboard files and their Taildrop sender; the chosen target; the "Accept
clipboard from <device>" switches.

**Outputs:** a clipboard file to the target; the "Sent to <PC>" notification
or a refusal notification with the reason; the phone's clipboard set from an
incoming file; a warning in the app log for an invalid incoming clip.

## Rules and invariants

- **Sending.** The clipboard is read only on a tap of the tile; nothing is
  sent on copy. The tile does not send, and shows the reason, when the clip
  is empty, over the size limit, not valid UTF-8, or marked by Android as
  sensitive (passwords, P11); also when no target is chosen, the target is
  offline, the VPN is down or the node is not running.
- **Acceptance** (P12). A clipboard file is applied only when the
  "Accept clipboard from <device>" switch is on for its sender; the switch is
  off by default. The sender is the Taildrop sender of the file; the file
  name carries no source marker. Without the switch, or from a sender not
  allowed, the file goes into the inbox as an ordinary file (the contract
  fixes this finally).
- **Freshness.** A clip older than the TTL when the receiver finds it is
  deleted without being applied.
- **Bursts.** Of several clips that arrive in a row, the last by receive time
  is applied; the others are deleted.
- **Validity.** An incoming clip over the limit or not valid UTF-8 (or with a
  BOM) is deleted with a warning in the app log, not applied.
- **Content as is.** Line breaks are not normalised in either direction.
- **No loop.** A received clip is never sent back automatically.
- An applied clipboard file never shows in the inbox and is deleted once its
  content is in the clipboard (P10).
- Clipboard text is not written to the app log, the support dump or the Debug
  API.

## Boundaries

- Pairs with the launcher only. The official Tailscale clients receive a
  clipboard file as an ordinary file with the prefix in its name; they do not
  put it into their clipboard.
- No background reading of the clipboard and no automatic sending on copy.
- Text only; images and other clip types are not sent.
- The launcher's side is its own spec: clipboard on macOS, Windows and remote
  lxd (through gRPC), none on Linux classic and Windows 386; sending from the
  PC is the tray item "Send clipboard to <phone>", with no global hotkey.
- Open: whether the target and the "Accept clipboard from <device>" switches
  are in the backup.
- Not verified on a device.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| — | — | Draft | Owner decisions 2026-11-01 and the agreement with the launcher; no task yet |
