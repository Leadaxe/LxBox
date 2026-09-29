[English](masque-node.md) · [Русский](masque-node.ru.md)

# WARP MASQUE node

| Field | Value |
|-------|-------|
| Feature | [015-WARP](../FEATURE.md) |
| Promises | P9, P10, P11, P12 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The Transport = MASQUE switch gives the same WARP over a different transport:
IP packets inside HTTP/3 (QUIC) or HTTP/2 (TCP) to Cloudflare — from outside
it is ordinary HTTPS on 443 and neighbouring ports, and the exit is often in a
different country. The node is a sing-box-lx core `masque` outbound with the
`cloudflare` profile.

## Parameters

| Parameter | Core key | Values | Default |
|-----------|----------|--------|---------|
| Transport | `vhttp` | Auto (h3 → h2) · HTTP/3 (QUIC) · HTTP/2 (TCP) | Auto |
| Endpoint IP | `server` | IP; presets per transport; 🎲 | empty = the registration server (shown as a hint) |
| Port | `server_port` | the transport's port set + input | the first port of the set |
| SNI | `tls.server_name` | domain; MASQUE SNI pool; 🎲 | random from the pool |
| Idle timeout (min) | `idle_timeout` | minutes → `Nm`; empty/0 — not written | empty |
| Keep-alive (sec) | `keep_alive_period` | seconds → `Ns`; unavailable with HTTP/2 | empty |
| Fixed | `profile: cloudflare`, `mtu: 1280`, `ip`/`ipv6` from the registration | — | — |

## Inputs / Outputs

**Inputs:** a MASQUE registration (cache or fresh), wizard input, the pool's
MASQUE section.

**Outputs:** a single server with the link `masque://<key>@<server>:<port>?
publickey=…&address=…&profile=cloudflare&vhttp=…&mtu=1280[&sni=…]
[&idle_timeout=…][&keep_alive=…]#…`; in the config — a `masque` outbound in
the new schema. Tag `🔥🎭 WARP (MASQUE)`, a taken one — the suffix ` 2`…; the
snack "Added MASQUE node"; on a build failure — "Invalid MASQUE config".

## Rules and invariants

- **Core schema.** Only `vhttp` and the nested `tls{}` are written to the
  config; the old root `network`/`sni` are never written (the old and new
  name with different values — the core refuses). An empty SNI — no `tls`
  block, the core decides. The wizard does not set `tls.disable_sni`.
- **Old links.** The `network=` parameter in `masque://` is not read
  (contract 0.8.0): such a link is parsed, but the HTTP version is taken by
  default — `h3`. A link without `vhttp` — an explicit `h3`, not `auto`; a
  junk value → `h3` with a registry warning.
- **The HTTP version belongs to the node.** It is not written to the
  registration cache; one registration spawns nodes of any version, the WARP
  node's identity does not depend on the version.
- **IP:port.** A set IP or port goes only into the node, the cache keeps the
  registration server. On a transport change, a port outside the new
  transport's set is reset to the first one; a preset host the new transport
  does not have (h3-only when switching to h2) is cleared; a manual IP is not
  touched.
- **Hosts per transport.** h3 — common + h3-only hosts; h2 and Auto — only
  common. 🎲: h3 — from the h3 hosts, h2/Auto — a random address of the block
  except exclusions; port — random from the transport's set.
- **SNI, timeouts** are applied to the cache without a new registration.
- **TLS fragmentation** (a global setting) reaches the node with `h2` and
  `auto`, not under a detour; with `h3` — silently not.

## Boundaries

- WARP+ and AWG obfuscation are not provided for MASQUE.
- Automatic fallback of `auto` from h3 to h2, remembering the winner, timeout
  defaults — core behaviour (the core's FEATURE 009-MASQUE_WARP).
- The `standard` profile, importing foreign MASQUE configs — outside the
  feature (parsing — 002-NODE_IMPORT).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [130F](../../../tasks/130F-masque-warp-transport/spec.md) | Released v2.9.0 | MASQUE transport, `masque` outbound, SNI and timeouts in the wizard |
| 2 | [305](../../../tasks/305-masque-endpoint-h2-pool-and-override.md) | implemented, device-verified | Manual IP:port, ports per transport, override only into the node |
| 3 | [393](../../../tasks/393-masque-config-schema-migration.md) | Released v2.20.8 | `vhttp` + `tls{}` instead of `network`/`sni`, the HTTP version belongs to the node |
| 4 | [402](../../../tasks/402-direction-chain-label-removed.md) | Done (part B) | `vhttp=auto` — the wizard default |
| 5 | [420](../../../tasks/420-masque-pool-per-transport.md) | Done (unit) · DEVICE-PENDING | Hosts per transport, preset host reset on transport change |
