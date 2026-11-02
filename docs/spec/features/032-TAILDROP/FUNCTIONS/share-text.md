[English](share-text.md) · [Русский](share-text.ru.md)

# Share text — shared or selected text into the Send clipboard window

Text or a link shared to LxBox from any app, or text selected in any app and
sent with "Send to device", opens the Send clipboard window with that text in
the field. From there it leaves as a command file to an own device.

| Field | Value |
|-------|-------|
| Feature | [032-TAILDROP](../FEATURE.md) |
| Promises | P8 |
| State | ✅ implemented, 2026-11-03 ([707](../../../tasks/707-taildrop-send-receive-files.md), iteration 7); not verified on a device |

## What it does

Two entries, one window:

1. **Share.** When the "Share" menu hands LxBox text and no files, the Send
   clipboard window of [command files](clipboard-sync.md) opens with that text
   in the field instead of the clipboard.
2. **Selection menu.** "Send to device" in the text selection menu of any app
   (in the selection bar or under ⋮) opens the same window with the selected
   text. The text in the source app does not change.

The text can be edited in the field. ➤ sends it as a `clipboard` command;
"Open on <device>" (only for exactly one `http(s)` link) sends `open_url`.
The recipient, the feed and the refusals are those of the window.

## Parameters

| What | Value |
|------|-------|
| Entries | LxBox in "Share" (text without files); "Send to device" in the text selection menu |
| When they exist | only while the VPN is up and the running config has a Tailscale node with Allow Taildrop |
| Delivery | a command file through the Send clipboard window: `clipboard` or `open_url` |

## Inputs / Outputs

**Inputs:** a share intent with text (plain text or a link) and no files; the
text from "Send to device".

**Outputs:** the Send clipboard window with the text in the field; after ➤ or
"Open on <device>" — a command file to the chosen device.

## Rules and invariants

- A share that carries files is sent as files ([send files](send-files.md));
  this function handles text only.
- Nothing is sent until ➤ or "Open on <device>": the window shows the text
  first.
- Both entries are switched on with a VPN start or a config reload that has a
  Tailscale node with Allow Taildrop, and off with a VPN stop, a reload
  without such a node and a process restart. If an entry still fires with no
  such node (a race), the window shows the refusal reason (`Start VPN to
  send` with the VPN down).
- Shared text no longer becomes a note file. A `note-YYYY-MM-DD-HHMM.txt`
  file (the phone's local time, UTF-8) is made only by the Debug API
  (`POST /taildrop/send` with `text`), and travels as a regular Taildrop file.

## Boundaries

- The receiver gets a command, not a file: an official Tailscale client shows
  it as an ordinary `.json`. A note for an official client is the Debug API
  path only.
- Not verified on a device.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [707](../../../tasks/707-taildrop-send-receive-files.md) | Implemented | Text without files → `note-YYYY-MM-DD-HHMM.txt` (UTF-8) over the same send path |
| 2 | [707](../../../tasks/707-taildrop-send-receive-files.md) iteration 7 | Implemented, not verified on a device | 2026-11-03: shared text opens the Send clipboard window instead of a note; "Send to device" in the text selection menu; both entries only while the VPN is up with a Tailscale node that allows Taildrop |
