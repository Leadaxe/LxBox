[English](share-text.md) · [Русский](share-text.ru.md)

# Share text — text or a link as a note file

Text or a link shared to LxBox from any app becomes a small text file and
travels as a regular Taildrop file, so any Taildrop receiver, including the
official Tailscale clients, gets it as an ordinary file.

| Field | Value |
|-------|-------|
| Feature | [032-TAILDROP](../FEATURE.md) |
| Promises | P8 |
| State | ✍ Draft, 2026-11-01 — not implemented |

## What it does

When the "Share" menu hands LxBox text and no files, the text is written into
a file `note-YYYY-MM-DD-HHMM.txt` (the phone's local date and time of the
share) and goes the same path as [send files](send-files.md): node choice if
needed, peer choice, progress in a notification.

## Parameters

| What | Value |
|------|-------|
| File name | `note-YYYY-MM-DD-HHMM.txt`, local time of the share |
| Content | the shared text as is, UTF-8 |
| Delivery | the send-files path: node, own online peer, notification |

## Inputs / Outputs

**Inputs:** a share intent with text (plain text or a link) and no files.

**Outputs:** one `.txt` file sent through Taildrop.

## Rules and invariants

- On the receiving side the note is an ordinary file; nothing in it marks it
  as LxBox's.
- A share that carries files is sent as files; this function handles text
  only.
- The temporary note file is removed after the transfer ends or fails.

## Boundaries

- No clipboard semantics: a note lands in the receiver's file inbox, not in
  its clipboard. Clipboard text goes through [clipboard sync](clipboard-sync.md).
- Not verified on a device.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| — | — | Draft | Owner decisions 2026-11-01; no task yet |
