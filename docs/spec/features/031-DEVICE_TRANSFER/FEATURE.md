[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Device transfer — send settings from a phone to a TV over the local network

LxBox sends its VPN settings — subscriptions, servers, routing rules, DNS,
split tunneling — from a phone to an Android TV on the same Wi-Fi in two steps:
the TV shows a QR code, the phone scans it and sends. Nothing is typed with a remote control, nothing
passes through a cloud service, and the receiver applies the settings only
after the user confirms them on its screen.

| Field | Value |
|-------|-------|
| Feature | 031-DEVICE_TRANSFER |
| Type | Product feature |
| Absorbed | — (new, [§622](../../tasks/622-device-transfer-phone-to-tv.md)) |
| State | ✅ implemented, 2026-10-16 (§622); manual checks P4 confirmation, P7, P8 on TV and phone emulators pending |

## Purpose

Setting up a VPN client with a TV remote is painful: subscription URLs,
node links and routing rules are long strings, and Android TV has no file
picker to load a backup from
([§372](../../tasks/372-android-tv-support.md)). The phone already holds a
working setup. The feature moves it to the TV in one scan.

Principles: **a TV-only receiver** — only a television receives; on a phone
or a tablet the receive entry does not exist, because those devices already
have a file picker and a keyboard; **nothing listens by default** — the receiver exists only while
its screen is open; **the network is not trusted** — the local network may
be shared, so the content is encrypted and authenticated with a key that
only the QR code carries; **one path for incoming settings** — a transfer is
a backup delivered over the air and is applied by the same restore as a
backup file, with the same checks and the same confirmation.

## Promises

- **P1. Nothing listens until the user asks.** The receiver opens a port
  only while the "Receive settings" screen is open; leaving the screen, the
  session timeout or a completed transfer closes it. **Witness:** units
  "close() is idempotent and the port refuses afterwards (P1)", "timeout
  closes the session and the port (P1)".
  **Mutation:** the receiver starts with the app.
- **P2. Without the key from the QR code nothing is accepted.** The payload
  is encrypted and authenticated with a one-time key that appears only in
  the QR code on the receiver's screen. A payload that does not decrypt
  with it is rejected and nothing is applied. **Witness:** units "wrong key
  → 403, parse not called; 5th rejection closes (P2, P3)", "corrupted
  ciphertext → 403", "foreign key → auth error", "corrupted ct → auth
  error", "corrupted nonce → auth error".
  **Mutation:** the payload is accepted in plain text.
- **P3. One session — one transfer.** After the first accepted payload the
  session closes; repeated attempts are refused. The receiver handles one
  request at a time; a request that arrives meanwhile is refused as busy
  before its content is read. After a fixed number of rejected attempts —
  an envelope that does not parse or does not decrypt — the session closes
  as well. **Witness:** units "valid envelope → 200, session closed, same
  parse as backup file (P3, P4)", "second request while the first is in
  processing → 503 busy (P3)", "5 garbage envelopes → 400 each, session
  closed (P3)", "wrong key → 403, parse not called; 5th rejection closes
  (P2, P3)".
  **Mutation:** the session stays open after success.
- **P4. A transfer is applied as a backup.** The received content goes
  through the backup validation and restore
  ([017-BACKUP_AND_STORAGE · P4–P9](../017-BACKUP_AND_STORAGE/FEATURE.md#promises)):
  the user sees what arrived, chooses merge or replace on the receiver and
  confirms; without confirmation nothing changes. **Witness:** unit
  "valid envelope → 200, session closed, same parse as backup file (P3,
  P4)"; the confirmation — manual check on a TV emulator (pending). **Mutation:** applying on receipt.
- **P5. The sender chooses what to send.** The same categories as in
  backup export; Debug API keys are off by default and do not travel
  unless selected
  ([017-BACKUP_AND_STORAGE · P1](../017-BACKUP_AND_STORAGE/FEATURE.md#promises)).
  **Witness:** widget test "categories sent default to everything except
  Debug API (P5)".
  **Mutation:** the sender sends everything.
- **P6. A failure is named.** The sender sees one of: the device is not
  reachable (different network or client isolation on the Wi-Fi), the code
  has expired, the code was not accepted, the content is too large. The
  receiver sees why a received payload could not be applied. **Witness:**
  units "each answer has its own status", "closed receiver port → expired",
  "nobody answers → unreachable", "body over the limit → 413", "decrypted but
  not a backup → 422 with reason, session stays open (P6)".
  **Mutation:** a generic "Error".
- **P7. A running VPN does not get in the way.** The receiver is reachable
  on its local address with its own tunnel up; the sender reaches the local
  address directly, not through its tunnel, whatever its routing rules say.
  **Witness:** manual check with the tunnel up on both sides (pending).
  The fallback path without a physical network: unit "no non-VPN network →
  Dart client delivers to a live receiver".
  **Mutation:** the send goes into the sender's tunnel and times out.
- **P8. The receiver works with a remote.** The receive screen needs no
  touch and no text input: the QR code, the address, the time left and the
  state are visible, the screen does not sleep during the session, every
  action is reachable with the D-pad. **Witness:** manual check on a TV
  emulator (pending). **Mutation:** the confirmation requires a tap outside the
  focus order.
- **P9. The key does not leak.** The key is not written to logs, the
  request log or crash reports. **Witness:** units "session log never
  contains the key or the code text (P9)", "toString masks the key (P9)". **Mutation:** the QR text in the log.
- **P10. Only a TV receives.** The receive entry is shown only on a device
  that runs in television mode (Android TV, Google TV); on a phone or a
  tablet it is absent. The send entry is shown only on a device with a
  camera. **Witness:** units "not a TV → no receive item; send only with a
  camera", "TV: receive only, even with a camera"; widget tests "phone with
  camera: Send to TV, no receive item (P10)", "TV: receive item first, no
  Send to TV (P10)"; manual check on a TV emulator and a phone emulator
  (pending). **Mutation:** the receive entry on a
  phone.

## Controlled parameters

No user settings. Fixed values:

| Parameter | Value |
|-----------|-------|
| Session lifetime | 10 minutes |
| Port | any free one, chosen per session |
| Payload size limit | 32 MiB |
| Rejected attempts (unparsable or undecryptable envelope) before the session closes | 5 |
| Requests handled at a time | 1, the others are refused as busy |
| Encryption | AES-256-GCM, 96-bit nonce, one-time 256-bit key per session |

Transfer code (QR content), version 1:

```
lxbox-transfer:1?a=<ipv4>:<port>[,<ipv4>:<port>…]&k=<key, base64url>&n=<device name>
```

`a` lists the receiver's local IPv4 addresses (Wi-Fi, Ethernet; not
loopback, not the tunnel); the sender tries them in order. `n` is shown to
the sender before sending.

Payload: `POST /transfer` with the JSON envelope
`{"v":1,"nonce":"<base64>","ct":"<base64>"}`; the plaintext is a full
backup file ([017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md)),
the associated data is `lxbox-transfer/1`.

## Inputs / Outputs

**Receiver.** Takes: the user opening the receive screen, the device's
local addresses, one HTTP request with the envelope. Gives: the QR code and
the session state on screen; the received backup handed to the restore
preview; a short reply to the sender (accepted / refused with a reason).

**Sender.** Takes: the selected categories, the scanned transfer code.
Gives: the encrypted backup to the receiver, the result on screen.

## Data flow

```
Receiver: open screen → key + port + addresses → QR on screen → wait
Sender:   categories → scan QR → show device name → build backup → encrypt
          → POST to each address in turn → result
Receiver: envelope → size check → decrypt (key) → backup parse
          → reply to sender → close session → restore preview
          → user: merge / replace → apply
```

## Rules and guarantees

- The key, the port and the addresses are new for every session; a QR code
  from a closed session is useless.
- Decryption precedes any parsing: content that does not authenticate is
  not read as JSON.
- The receiver replies "accepted" only after the backup parses; whether the
  user applies it is the receiver's business and is not reported back.
- Leaving the preview without applying discards the received content; it
  is not stored on disk.

## Boundaries

- **Phone to TV only.** Phone to phone or phone to tablet is not a
  transfer: those devices import a backup file. A TV does not send.
- **The same local network only.** No relay through the internet, no cloud
  account, no discovery: the QR code is the only way to find the receiver.
  A Wi-Fi with client isolation (often a guest network) makes the transfer
  impossible; the sender names this case.
- **IPv4 only** in version 1.
- **One-time, not sync.** Later changes on the phone do not reach the TV by
  themselves.
- **The sender needs a camera.** A device without a camera receives but
  does not send; there is no manual code entry (the key is too long to
  type).
- **No web page.** Configuring the receiver from a browser on a laptop is a
  possible later function of this feature, not part of it now.
- Device properties that a backup does not carry (theme, per-device
  state) stay as they are on the receiver
  ([017-BACKUP_AND_STORAGE · P8](../017-BACKUP_AND_STORAGE/FEATURE.md#promises)).

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Receive session (TV) | Opens the session, shows the QR code, accepts and decrypts one payload, hands it to the restore preview | P1–P4, P6–P10 | [receive-session](FUNCTIONS/receive-session.md) |
| Send to TV (phone) | Category choice, QR scan, encryption and delivery, result | P5–P7, P10 | [send-to-tv](FUNCTIONS/send-to-tv.md) |

## Related features

- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — the
  payload format, the categories, the validation and the restore; this
  feature only delivers the file.
- [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md) — the QR scanner
  and the existing import paths (URL, clipboard) that remain the
  alternative.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — the tunnel on either
  side must not swallow the local transfer (P7).
- [027-DEBUG_API](../027-DEBUG_API/FEATURE.md) — the other local HTTP
  server; it stays loopback-only, this feature does not widen it.

## Maintenance notes

- Do not reuse the Debug API server for the receiver: its promises
  (loopback only, the Host check) are the opposite of what the receiver
  needs.
- Two emulators on one host do not see each other's addresses; the manual
  check needs port forwarding through the host or real devices.
