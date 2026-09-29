[English](awg-obfuscation.md) · [Русский](awg-obfuscation.ru.md)

# AmneziaWG obfuscation

| Field | Value |
|-------|-------|
| Feature | [015-WARP](../FEATURE.md) |
| Promises | P8 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The "Add Amnezia obfuscation" checkbox makes a WARP WG node unrecognisable to
DPI: before the handshake go junk packets disguised as a real protocol (QUIC,
DNS, STUN or SIP), while the handshake itself stays bit-for-bit regular
WireGuard — Cloudflare accepts it. The service decoy packet `i1` is built by
the core from the `id`/`ip`/`ib` keys; the app does not generate it.

## Parameters

| Parameter | Core key | Values | Default |
|-----------|----------|--------|---------|
| Masquerade protocol | `ip` | `quic` · `dns` · `stun` · `sip` | `quic` |
| Masquerade domain | `id` | domain | random from the WG SNI pool; empty → random, otherwise `www.google.com` |
| Browser | `ib` | `chrome` · `firefox` · `curl` | `chrome`; written only with `ip=quic` |
| Jc / Jmin / Jmax | `jc`/`jmin`/`jmax` | numbers | 4 / 40 / 70 |
| Fixed | `s1`,`s2` = 0; `h1..h4` = 1,2,3,4 | — | — |

## Inputs / Outputs

**Inputs:** the checkbox and the Advanced fields; the WG SNI pool (with the
regional override); the pool's WG blocks and ports.

**Outputs:** a `wireguard` endpoint with AmneziaWG fields at the root; the tag
`🔥⛈️ WARP (AWG 1.5)`.

## Rules and invariants

- **The handshake is not touched.** `s1=s2=0` and `h1..h4=1..4` — handshake
  packets as in plain WG; the DPI signature is thrown off only by the junk and
  the decoy.
- **`i1` is not written.** `id`/`ip`/`ib` and an explicit `i1` are mutually
  exclusive — the core would reject both.
- **The domain is on the wire** only for `dns` (QNAME) and `sip` (host); for
  `quic` and `stun` it is decorative — the wizard hints at this under the
  protocol choice.
- **Random endpoint.** Turning the checkbox on with a default/empty/previously
  random endpoint sets a random `ip:port` from the pool's WG blocks (the port
  from the main and extended ports); 🎲 re-rolls. An endpoint entered by hand
  is not touched.
- **Turning off** returns all fields to defaults: random endpoint → default,
  `reserved` → by the checkbox, protocol `quic`, browser `chrome`, junk
  4/40/70, a fresh random domain.
- **No new registration.** Obfuscation is client-side: turning it on and off
  on a cached registration rebuilds only the node fields.
- `reserved` is off by default (see WireGuard node).

## Boundaries

- AWG obfuscation does not apply to MASQUE — the checkbox is hidden.
- Ordering and fragmentation of QUIC Initial inside `i1` — the core's concern.
- Checking whether a particular decoy gets through in the network — a node
  ping (009-NODE_HEALTH) or the experiment.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [126](../../../tasks/126-warp-amneziawg-obfuscation.md) | Implemented (device-smoke pending) | AWG 1.5 preset on top of WARP, node via INI |
| 2 | [133](../../../tasks/133-warp-junk-generators-research.md) | Research done — implementation NOT started | Research into junk/CPS generator practices |
| 3 | [136](../../../tasks/136-warp-quic-i1-generator.md) | Implemented + device-smoke ✅ | Configurable Jc/Jmin/Jmax, random endpoint with obfuscation |
| 4 | [142](../../../tasks/142-warp-reserved-optional.md) | Done (released v2.3.3) | No `reserved` with obfuscation, simplified presets |
| 5 | [143](../../../tasks/143-warp-masquerade-id-ip-ib.md) | Implemented (device-smoke ✅) | Masquerade via the core keys `id`/`ip`/`ib`, own `i1` generator removed |
| 6 | [146](../../../tasks/146-warp-quic-initial-fragmented-i1.md) | ✅ Implemented in the core | QUIC Initial decoy with out-of-order fragmentation — on the core side |
