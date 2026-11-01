[English](inbox.md) · [Русский](inbox.ru.md)

# Inbox — files from own devices, per Tailscale node

Files sent to the phone from the user's own tailnet devices are accepted
without a prompt into the inbox of the node they arrived on, announced in a
notification and listed on that node's Network tab until the user saves or
deletes them.

| Field | Value |
|-------|-------|
| Feature | [032-TAILDROP](../FEATURE.md) |
| Promises | P4–P7 |
| State | ✍ Draft, 2026-11-01 — not implemented |

## What it does

While a file is coming in, a notification "receiving from X" shows the
progress and offers Cancel. When the file is in, the notification becomes
"file from X" with Save and Delete. The node's Network tab has an inbox block
under Devices: each received file with Save and Delete. Save puts the file
into Downloads; Delete removes it. A tap on either notification opens the
Network tab of the node that received the file.

## Parameters

| What | Value |
|------|-------|
| Accepted from | own devices of the node's tailnet; no consent step |
| Where it lands | the node's inbox, kept in the node's own `taildrop_directory` (the core's default is one `Taildrop` folder for all nodes) |
| Notification while receiving | "receiving from X", Cancel |
| Notification when received | "file from X", Save, Delete |
| Inbox block | Network tab of the node, under Devices; per file Save, Delete |
| Save target | Downloads |
| Tap on a notification | the Network tab of the receiving node |

## Inputs / Outputs

**Inputs:** incoming Taildrop files from own devices; taps on Cancel, Save,
Delete and on the notification; deletion of the node.

**Outputs:** files in the node's inbox; a file in Downloads; notifications;
the inbox block on the Network tab.

## Rules and invariants

- Each Tailscale node has its own inbox; files are never shown under another
  node.
- Cancel stops the transfer and leaves no partial file in the inbox.
- A received file stays in the inbox across app and VPN restarts until it is
  saved or deleted (P6). Deleting the node deletes its inbox together with its
  state.
- A saved file leaves the inbox; Downloads holds the copy the user keeps.
- With the VPN down or the node not running nothing is received (P7); the
  inbox block still lists what was received earlier.
- A file with the clipboard prefix from a sender with "Accept clipboard from
  <device>" on is not an inbox file — see [clipboard sync](clipboard-sync.md);
  from any other sender it is an ordinary inbox file.
- File and device names are not written to the app log, the support dump or
  the Debug API.

## Boundaries

- No accept/decline prompt and no per-device allow list: Tailscale delivers
  from own devices only, and that is the trust boundary.
- No preview or opening of a file inside LxBox; the user saves it and opens it
  with another app.
- The inbox is not in the backup.
- Receiving requires Taildrop enabled in the tailnet's admin console (the
  file sharing capability on this node); without it the inbox block says why.
- Today the core already accepts files silently into its default folder,
  outside any UI; what happens to files left there before the feature is
  open ([Maintenance notes](../FEATURE.md#maintenance-notes)). Whether
  receiving works in the userspace network stack is confirmed by code, not on
  a device.
- Not verified on a device.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| — | — | Draft | Owner decisions 2026-11-01; no task yet |
