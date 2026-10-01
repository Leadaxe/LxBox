[English](one-tap-registration.md) · [Русский](one-tap-registration.ru.md)

# One-tap registration — a WARP account with the key kept on the device

Registration runs from the "Get WARP" wizard in the Servers screen menu.

| Field | Value |
|-------|-------|
| Feature | [015-WARP](../FEATURE.md) |
| Promises | P1, P2, P3, P4, P16, P17 |
| State | ✅ written from code, 2026-09-28 |

## What it does

On the "Register" button in the "Get WARP" wizard, registers the device with
Cloudflare WARP directly through the Cloudflare API, without third-party
generators. The tunnel key is created on the phone; only the public part goes
to Cloudflare. The registration is cached and reused by all subsequent nodes
of the same transport until the user asks for a new one.

## Parameters

| Parameter | Value |
|-----------|-------|
| API hosts | the pool's `api.hosts`; by default `https://api.devices.cloudflare.com`, then `https://api.cloudflareclient.com` |
| Path / client version | `v0a2158` · `CF-Client-Version: a-7.21-0721` · `User-Agent: okhttp/3.12.1` |
| Timeout | 5 s per request to one host |
| WARP+ license key | empty — free; WireGuard transport only |
| Re-register (force new account) | off |

## Inputs / Outputs

**Inputs:** the selected transport, the license, the Re-register flag;
responses of `POST /reg`, `PATCH /reg/{id}/account` (license), `PATCH
/reg/{id}` (MASQUE enroll).

**Outputs:** a WG registration (key, peer key, v4/v6 addresses, `client_id`,
device, token, license, WARP+ flag) or a MASQUE one (ECDSA key in SEC1 DER,
server key in PKIX DER, addresses, data-plane server and port); the
registration cache; a log line with secrets masked.

## Rules and invariants

- **WireGuard.** An X25519 pair on the device → `POST /reg` with the public
  key. With a license — `PATCH …/account` with the same token to the same
  host; any refusal (network, 4xx, no token) — the free account stays, the
  node is added anyway, the snack "Added WARP node" instead of "Added WARP+
  node".
- **MASQUE — two steps.** `POST /reg` with a one-time real X25519 key (random
  32 bytes got 401 "Invalid public key"), then `PATCH /reg/{id}` with a
  public ECDSA P-256 key (`key_type: secp256r1`, `tunnel_type: masque`). The
  server key from the response, if it arrives as PEM, is converted to plain
  base64(DER); port `0` → 443; `:0` in the address is stripped.
- **Trying hosts.** A client exception or a timeout — the next host; any HTTP
  response is final. All hosts dead — a "network error:" error with the list.
  The host that answered serves the whole flow (enroll, license); the winner
  is not remembered between registrations.
- **Response errors** are shown to the user in a snack: "registration failed
  (HTTP N). API version may have changed", "bad response: not JSON / missing
  config / missing peer public_key / missing interface address", for MASQUE —
  "MASQUE enroll failed (HTTP N)". The node is not added, the cache is not
  touched.
- **Cache.** Without Re-register the cache of its own transport is used (WG
  and MASQUE separately). Re-register — a new registration, the cache is
  overwritten. A WG cache without WARP+ is not used when a license is entered:
  the registration is new.
- **Secrets.** The private key, token and license are not written to the log
  — only the `<redacted>` mask.
- **Backup.** Registrations travel as `warp[]` entries (`type: wg|masque`,
  canonical field names); an entry without the private key or the peer key is
  dropped on import; an entry without `type` — a warning, not a silent loss.

## Boundaries

- Registration is a direct request from the app; choosing a node or detour
  for it is not possible.
- WARP+ for MASQUE is not supported and is not planned (owner decision 2026-09-29, audit [591](../../../tasks/591-spec-kit-revision-audit.md)).
- There is no device deletion at Cloudflare: Re-register leaves the old device
  in the Cloudflare account.
- Registration without the UI (`POST /warp`, WireGuard only) — Debug API,
  [027-DEBUG_API](../../027-DEBUG_API/FUNCTIONS/route-map.md).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [025F](../../../tasks/025F-warp-integration/spec.md) | Released v2.3.0 | Registration on the device, WARP+, cache and Re-register |
| 2 | [130F](../../../tasks/130F-masque-warp-transport/spec.md) | Released v2.9.0 | Two-step MASQUE registration, ECDSA in DER |
| 3 | [147](../../../tasks/147-debug-api-warp-endpoint.md) | Implemented, device-test pending | Registration via the Debug API without the UI |
| 4 | [393](../../../tasks/393-masque-config-schema-migration.md) | Released v2.20.8 | The HTTP version left the registration; `warp[]` in the backup |
| 5 | [418](../../../tasks/418-warp-api-host-failover.md) | Done (unit) · DEVICE-PENDING | API host list, failover, 5 s timeout, a real X25519 in the MASQUE POST |
