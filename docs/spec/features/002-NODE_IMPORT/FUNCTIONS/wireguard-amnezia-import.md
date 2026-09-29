[English](wireguard-amnezia-import.md) · [Русский](wireguard-amnezia-import.ru.md)

# WireGuard / AmneziaWG import — .conf files, wg/awg links and Amnezia vpn:// profiles

A WireGuard or AmneziaWG config in any distribution form becomes a sing-box `wireguard` endpoint,
with the AmneziaWG MTU capped at 1280.

| Field | Value |
|------|----------|
| Feature | [002-NODE_IMPORT](../FEATURE.md) |
| Promises | P8 P14 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Turns a WireGuard or AmneziaWG config into a core `wireguard` endpoint —
from any of the forms in which it is distributed: a wg-quick `.conf` file, a
`wireguard://`/`wg://`/`awg://`/`amneziawg://` link with parameters, the same link with
base64 of a whole `.conf`, an Amnezia profile `vpn://`. AmneziaWG is not a separate
protocol but obfuscation fields on the same endpoint.

## Parameters

| Field | From | Rule |
|------|--------|---------|
| `PrivateKey`, `Address`, `MTU` | `[Interface]` / query | keys are normalized to standard base64; bare IP → CIDR |
| `PublicKey`, `PresharedKey`, `Endpoint`, `AllowedIPs`, `PersistentKeepalive`, `Reserved` | `[Peer]` / query | default port 51820; `AllowedIPs` defaults to `0.0.0.0/0, ::/0`; `Endpoint` — `host:port`, `[IPv6]:port` |
| `Jc`, `Jmin`, `Jmax`, `S1`–`S4`, `H1`–`H4`, `I1`–`I5` | AmneziaWG 1/2 | `H` — a number or a range `N-M`; a reversed range is swapped |
| AmneziaWG 3.x fields | header protection, padding, tails, timings | booleans `on/true/1`; keepalive allows a range |
| `DNS` | `[Interface]` | does not go into the body, code `wgconf_dns_ignored` |
| AmneziaWG MTU | ceiling 1280 | see the rules |

## Inputs / Outputs

**Input:** INI text (with a name hint — the file name), a link, a
`vpn://` profile. **Output:** an endpoint node; the source is the INI text itself byte for byte
(for a link — the link itself).

## Rules and invariants

- **Name:** a comment under `[Peer]` is stronger than the file name, the file name is stronger than the
  fallback; for a link — the fragment, without it — the `Endpoint` host. A file name with
  spaces, Cyrillic letters and brackets is kept as is, without percent-encoding.
- **Without `Endpoint`, `PrivateKey` or `PublicKey` there is no node** (`field_missing`).
  A broken `PresharedKey` rejects the node.
- **The AmneziaWG MTU ceiling is 1280.** A node with any AWG field: without MTU → 1280
  without a code; above 1280 → 1280 with code `awg_mtu_clamped` (the author's value in
  `value`); below — as is. Plain WireGuard is not touched. An authored sing-box
  body keeps its value, the info code `awg_mtu_high` is set.
  For a `vpn://` profile an explicit `MTU` in `[Interface]` is stronger than `last_config.mtu`.
- **An unusable AWG field is removed field by field**, the node lives; overlapping
  headers, a broken protection key or short padding with a key remove the node.
- **`vpn://` profile:** all `awg`/`wireguard` containers are unpacked;
  others (xray, openvpn, …) are skipped; a profile without WG/AWG containers —
  a rejection with a reason. A bare `.conf` can also lie under `vpn://`. Base64 padding
  is optional, compressed and uncompressed payloads are accepted, DNS placeholders
  are filled from `dns1`/`dns2`. Nodes of the containers of one profile get
  a name with an index: `name`, `name 2`, … by container number.
- **`awg://<base64 .conf>`**: one link — one node, a second `[Interface]` is
  ignored; base64 without `[Interface]` — a reject.
- The same node as an `amneziawg://` line and a `vpn://` profile in one body
  collapses into one with code `duplicate`.

## Boundaries

- The private key is stored in the node and in its link; copying — via
  confirmation ([export](share-link-export.md)).
- Enabling/disabling a WG node on the fly, probing — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).
- Generating WARP nodes — [015-WARP](../../015-WARP/FEATURE.md).
- A link expresses one peer: a body with several `peers` is not built
  into a link.

## Revisions

| # | Revision | Status | Summary |
|---|---------|--------|------|
| 1 | [019F](../../../tasks/019F-wireguard-endpoint/spec.md) | Implemented | WireGuard is an endpoint, not an outbound; link and INI |
| 2 | [097F](../../../tasks/097F-awg2-amneziawg2/spec.md) | In progress | AWG/AWG2: parsing, emit, link round trip, MTU clamp 1280 |
| 3 | [106](../../../tasks/106-wireguard-slash-key-and-bare-cidr.md) | DONE | `/` in a key, bare IP → CIDR |
| 4 | [110](../../../tasks/110-amnezia-vpn-link-import.md) | Done | Amnezia profile `vpn://` |
| 5 | [112](../../../tasks/112-awg-ranged-magic-headers.md) | Done | `H1`–`H4` as a number or a range |
| 6 | [243](../../../tasks/243-wg-import-filename-tag.md) | Replaced by §456 | The `.conf` file name is the node name |
| 7 | [421](../../../tasks/421-awg3-header-protection-timings.md) | Implemented | AmneziaWG 3.x |
| 8 | [450](../../../tasks/450-awg-conf-base64-link.md) | Implemented | `awg://<base64 .conf>` |
| 9 | [456](../../../tasks/456-wg-ini-as-source-tag-in-record.md) | Released v2.24.3 | The source is the INI text; the name from the `[Peer]` comment |
| 10 | [473](../../../tasks/473-contract-115-awg-mtu-by-registry.md) | Released v2.25.0 | MTU ceiling by the registry, codes `awg_mtu_clamped`/`awg_mtu_high` |
| 11 | [481](../../../tasks/481-contract-1111-wg-awg-by-registry.md) | Released v2.25.0 | WG keys and AWG rules are judged by the registry |
| 12 | [506](../../../tasks/506-silent-parse-loss-reasons.md) | Released v2.25.2 | A bare `.conf` under `vpn://` — a node, not zero |
| 13 | [538](../../../tasks/538-subscription-dedup-by-identity.md) | Done | `amneziawg://` and `vpn://` of one node — one node |
| 14 | [570](../../../tasks/570-close-open-tails.md) | Wave B done | All profile containers from a list line |
