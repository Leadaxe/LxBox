[English](endpoint-pool.md) · [Русский](endpoint-pool.ru.md)

# Endpoint pool and region

| Field | Value |
|-------|-------|
| Feature | [015-WARP](../FEATURE.md) |
| Promises | P12, P13, P14 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Keeps in one built-in file everything WARP knows about the Cloudflare network:
registration API hosts, WireGuard blocks and ports, endpoint presets, MASQUE
hosts and ports per transport, SNI pools and regional overrides. The wizard
and the experiment take presets, randomisation and hints from it; editing the
pool does not require editing the logic.

## Parameters

Pool file sections:

| Section | Keys | Meaning |
|---------|------|---------|
| `api` | `hosts` | Registration hosts in order of preference |
| `wireguard` | `v4_cidr`, `v6_cidr` | Blocks for a random endpoint |
| | `ports`, `ports_extra` | Reliable ports (2408/500/1701/4500) and empirical ones |
| | `endpoints_preset`, `recommended_endpoint` | The Endpoint field list and the marked item |
| | `keepalive` | Keepalive of experiment nodes, s; 0/absent — not written |
| | `sni_pool` | AWG masquerade domains (without Cloudflare domains) |
| `masque` | `hosts_preset`, `recommended_host` | Hosts where both h3 and h2 live |
| | `h3.hosts_extra`, `h3.ports` | h3-only hosts, h3 ports |
| | `h2.v4_cidr`, `h2.exclude`, `h2.ports` | The h2 block and addresses excluded from it |
| | `sni_pool`, `recommended_sni` | MASQUE SNI (Cloudflare domains allowed) |
| `loc.<cc>` | any keys above or `alias` | Overrides for a region |

The "Usage region" setting (App Settings → General): Auto (the country of the
operator network, then locales) · Not set · an explicit country code.

## Inputs / Outputs

**Inputs:** the built-in pool file; the region setting; the system IPv6 flag;
the experiment's JSON window (same format).

**Outputs:** presets and "(recommended)"-marked wizard items; random WG
`ip:port`, MASQUE IP and port, SNI; API hosts for registration.

## Rules and invariants

- **Region.** The `loc.<cc>` section is overlaid on the root: objects are
  merged by key, lists and values are replaced whole (otherwise "remove a
  domain for a region" would be impossible). `{"alias": "ru"}` — one hop, no
  chains. An unknown, empty or broken region — the root as is. Changing the
  region re-reads the pool.
- **The "(recommended)" mark** — only on the item equal to the explicit
  recommended key, at any position, and only in the menu: the clean value goes
  into the field and the config.
- **MASQUE per transport.** h3 — only `hosts_preset` ∪ `h3.hosts_extra`
  (randomising over the block would give dead addresses); h2 — a random
  address of `h2.v4_cidr` outside `h2.exclude`. The old flat format
  (`v4_cidr`, `h3_v4_cidr`, `ports_h3`/`ports_h2`) is read as a fallback.
- **WG randomisation.** The address — fully random over the host part of the
  block; v6 blocks — only with IPv6 enabled.
- **API hosts.** A trailing `/` and empty strings are stripped. Empty or a
  broken file — the built-in fallback list (matches the file).
- **A broken pool** — the wizard works on defaults (the registration endpoint,
  empty presets), the experiment button is hidden.
- **Live data (as of 2026-09).** WG: `162.159.192/193/195.0/24`,
  `188.114.96.0/22`. MASQUE: `.198.2`, `.199.2` — both transports; `.198.1`,
  `.199.1` — h3 only; the rest of `162.159.198/199.0/24` — h2 only; ports for
  both — 443/500/1701/4500/4443/8443/8095. The `ru` region adds Russian
  domains to both SNI pools.

## Boundaries

- The pool describes addresses, not their liveness: measure it with a ping
  (009-NODE_HEALTH) through the production core.
- Today the region affects only the WARP pools.
- Country auto-detection depends on OS capabilities.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [132](../../../tasks/132-warp-endpoint-scanner-research.md) | Research done — implementation NOT started | Blocks, ports and a liveness methodology for WG endpoints |
| 2 | [136](../../../tasks/136-warp-quic-i1-generator.md) | Implemented + device-smoke ✅ | Random WG endpoint from blocks, SNI pool |
| 3 | [305](../../../tasks/305-masque-endpoint-h2-pool-and-override.md) | implemented, device-verified | Pool per transport, dead blocks removed, v6 only with IPv6 |
| 4 | [386](../../../tasks/386-warp-endpoint-preset-combobox.md) | — | Presets and recommended keys |
| 5 | [418](../../../tasks/418-warp-api-host-failover.md) | Done (unit) · DEVICE-PENDING | `api.hosts`, new domains in the SNI pools |
| 6 | [420](../../../tasks/420-masque-pool-per-transport.md) | Done (unit) · DEVICE-PENDING | `hosts_preset`, `h3.hosts_extra`, `h2.exclude` |
| 7 | [424](../../../tasks/424-warp-preset-recommended-mark-leak.md) | Implemented (unit + widget test) | The mark only in the menu |
| 8 | [425](../../../tasks/425-warp-pool-region-loc.md) | Implemented, device-verified | Region setting and `loc.<cc>` sections |
