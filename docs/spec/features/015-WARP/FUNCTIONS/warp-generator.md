[English](warp-generator.md) · [Русский](warp-generator.ru.md)

# Experiment: WARP node generator — finding WARP nodes that work in your network

The experiment only creates candidates; the standard node checks test them.

| Field | Value |
|-------|-------|
| Feature | [015-WARP](../FEATURE.md) |
| Promises | P15 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The "Make experiment" button in the wizard opens a screen with the number of
nodes and the pool JSON; "Create" assembles the "WARP GENERATOR" folder of
random WARP nodes — AWG, MASQUE h3 and MASQUE h2 on different addresses,
ports, SNI and decoys — with one registration per transport. The user then
tests the folder with the standard Test button and keeps what gets through in
their network.

## Parameters

| Parameter | Value | Default |
|-----------|-------|---------|
| Number of nodes | 1–200 (clamped when out of range) | 20 |
| Pool JSON | the pool file format, with `loc.<cc>` | the built-in pool |
| Reset | restore the built-in JSON | — |
| Folder ping URL | `https://1.1.1.1/cdn-cgi/trace` (no DNS) | — |
| Folder ping timeout | 3000 ms | — |

## Inputs / Outputs

**Inputs:** the number of nodes, the pool JSON, the region, the IPv6 flag; the
WG and MASQUE registration caches.

**Outputs:** the "WARP GENERATOR" folder (recreated on every run) opens in
place of the wizard; "back" leads to Servers. Node tags:
`🔥⛈️ WARP AWG (<decoy> <domain>)`, `🔥🎭 WARP MASQUE (h3: <domain>)`,
`🔥🎭 WARP MASQUE (h2: <domain>)`. A snack with a remark on partial success.

## Rules and invariants

- **Registrations.** The cache of each transport is used; no cache — one
  registration (WG — with the default endpoint, without a license), the result
  is cached. If one fails — generation proceeds on the other with the remark
  "MASQUE (h3/h2) unavailable: registration failed — …". If both fail or the
  pool is broken — "Generation failed — no WARP account."
- **Equal rights.** A candidate's protocol is equally likely among those
  available: AWG — if there is a WG block and WG ports; h3 — if there are h3
  hosts; h2 — if there is an h2 block.
- **AWG candidate.** An address from the v4 (v6 only with IPv6) block; the
  port — with probability 0.3 from the empirical ones, otherwise from the
  reliable ones; the domain from the WG SNI pool; the decoy `quic` (more
  often), `dns` or `stun`; junk 4/40/70; no `reserved`; keepalive from the
  pool's `wireguard.keepalive` (0 — not written).
- **MASQUE candidate.** Address and port from its own transport's sources (see
  the pool), SNI from the MASQUE pool; timeouts — from the registration cache.
- **Invalid JSON** — "Invalid pool JSON — check the structure.", the screen
  does not close.
- The experiment does not probe anything and does not delete dead nodes.

## Boundaries

- Testing and selecting nodes — 009-NODE_HEALTH (folder check).
- "Variations around a live IP" (the scanner's second phase) are not invoked
  from the UI.
- Re-register does not affect the experiment: it always uses the cache.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [132](../../../tasks/132-warp-endpoint-scanner-research.md) | Research done — implementation NOT started | Endpoint scanner research (the generator's foundation) |
| 2 | [305](../../../tasks/305-masque-endpoint-h2-pool-and-override.md) | implemented, device-verified | Experiment screen with the pool JSON; h3/h2 from their own sources |
| 3 | [313](../../../tasks/313-warp-generator-keepalive.md) | — | Keepalive of generator nodes from the pool |
| 4 | [420](../../../tasks/420-masque-pool-per-transport.md) | Done (unit) · DEVICE-PENDING | h3 only from h3 hosts, h2 without excluded ones |
