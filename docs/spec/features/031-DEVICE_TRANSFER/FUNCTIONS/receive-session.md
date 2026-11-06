[English](receive-session.md) · [Русский](receive-session.ru.md)

# Receive session — a TV shows a code and accepts one backup from a phone

While the "Receive settings" screen is open, the TV listens on the local
network for one encrypted backup addressed with the key from its QR code and
hands what arrived to the usual restore preview.

| Field | Value |
|-------|-------|
| Feature | [031-DEVICE_TRANSFER](../FEATURE.md) |
| Promises | P1–P4, P6–P10 |
| State | ✅ implemented, 2026-10-16 (§622); manual checks on a TV emulator pending |

## What it does

On a TV, "Receive from phone" (the first card of Backup & restore; on the
empty home screen, above "Restore from backup") opens "Receive settings".
The screen opens a session and shows a QR code on a white field, the
device name, the local address, the time left and the state. The phone
scans the code and sends; once a payload decrypts and parses as a backup,
the screen closes and the restore preview opens — the same one a backup
file gets: categories, Merge or Replace, then "Restart now" in the result
line. From the home screen subscriptions are re-read and fetched right after
applying, as with "Restore from backup".

## Parameters

No user settings.

| Value | Setting |
|-------|---------|
| Session lifetime | 10 minutes, a countdown on screen |
| Port | chosen by the system per session |
| Payload limit | 32 MiB |
| Rejected attempts (unparsable or undecryptable envelope) before the session closes | 5 |
| Requests handled at a time | 1 |

## Inputs / Outputs

**Inputs:** the screen being opened; the device's local IPv4 addresses
(Wi-Fi and Ethernet first; loopback, link-local and tunnel interfaces left
out); one `POST /transfer` with the envelope.

**Outputs:** the QR code (`lxbox-transfer:1?a=…&k=…&n=…`); the state line;
a reply to the sender — 200 accepted, 400 bad envelope, 403 wrong key, 404
other route, 409 session already closed, 413 too large, 422 not a usable
backup (with the reason), 503 busy with another request; the parsed backup to the restore preview.

## Rules and invariants

- Order of checks: size → envelope → decryption → backup parse. Nothing is
  parsed before it authenticates.
- One request at a time: while one is being read, decrypted or parsed,
  another `POST /transfer` gets 503 before its content is read.
- An envelope that does not parse (400) or does not decrypt (403) adds to
  the counter, shown as "Rejected attempts with a wrong code: N of 5"; the
  fifth closes the session — "Too many attempts with a
  wrong code. The code is closed; press New code to get another one."
- A payload that decrypts but is not a backup keeps the session open and
  shows "The phone sent settings that cannot be restored: <reason>".
- No usable address — "No local network" and "Connect this TV to Wi-Fi or
  Ethernet, then press New code."
- Timeout — "The code has expired. Press New code to get another one."
- "New code" closes the session and opens a new one with a new key and
  port. "Cancel" (focused when the screen opens) and leaving the screen
  close the session; the port refuses afterwards.
- The screen stays on while it is open.
- The log records the session opening, the port, the number of addresses
  and the outcome of each request; never the key or the code text.
- Leaving the restore preview without applying drops the payload; it is not
  written to disk.

## Boundaries

- Shown only on a device in television mode.
- IPv4 only; no discovery, no manual code entry.
- The receiver does not tell the sender whether the user applied the
  backup.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [622](../../../tasks/622-device-transfer-phone-to-tv.md) | Implemented | QR session on a TV, encrypted one-shot receipt, restore through the backup preview |
