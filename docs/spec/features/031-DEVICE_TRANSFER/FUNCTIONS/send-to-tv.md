[English](send-to-tv.md) · [Русский](send-to-tv.ru.md)

# Send to TV — a phone scans the TV's code and sends its settings

The phone builds a backup of the categories selected for export, encrypts it
with the key from the scanned code and delivers it to the TV over the local
network, past its own tunnel.

| Field | Value |
|-------|-------|
| Feature | [031-DEVICE_TRANSFER](../FEATURE.md) |
| Promises | P5–P7, P10 |
| State | ✅ implemented, 2026-10-16 (§622); manual check with the tunnel up pending |

## What it does

On a device that is not a TV and has a camera, Backup & restore shows the
"Send to TV" card under Export. "Scan code" opens the QR scanner; after the
scan the phone asks "Send to <device name>?", then builds the backup of the
categories checked in the Export card, encrypts it and sends it. The result
is one line at the bottom of the screen.

## Parameters

| Setting | Values | Default |
|---------|--------|---------|
| Categories | those of the Export card: Server lists, Routing, App settings, VPN system toggles, Debug API config | all except Debug API config |

Fixed: connection timeout 5 s per address, reply wait 60 s.

## Inputs / Outputs

**Inputs:** the scanned text; the selected categories.

**Outputs:** one `POST /transfer` with the envelope to each address of the
code in turn, until one answers; the result line.

## Rules and invariants

- No category selected — "Nothing to export — pick at least one category."
  before the scanner opens.
- A QR code that is not a transfer code of version 1 — "This is not a LxBox
  transfer code"; nothing is sent.
- The connection goes over the physical Wi-Fi or Ethernet network, not
  through the phone's own VPN, whatever its routing rules and per-app mode
  say. Without such a network the phone uses an ordinary connection.
- Result lines:
  - accepted — "Sent. Confirm the restore on the TV.";
  - no address answered — "Cannot reach the TV. Both devices must be on the
    same network; guest Wi-Fi often keeps devices from seeing each other.";
  - port closed or 409 — "The code has expired or was already used. Show a
    new code on the TV.";
  - 403 — "The TV did not accept the code. Show a new code on the TV and
    scan it again.";
  - 413 — "The settings are too large to send.";
  - 422 — "The TV cannot restore these settings: <reason>";
  - 503 — "The TV is busy with another request. Try again in a moment.";
  - another answer — "Sending failed: HTTP <code>".

## Boundaries

- Not shown on a TV and not shown without a camera; no manual code entry.
- Sends once; later changes do not follow.
- Does not learn whether the TV applied the backup.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [622](../../../tasks/622-device-transfer-phone-to-tv.md) | Implemented | Scan, confirm, encrypt, deliver past the own tunnel, named results |
