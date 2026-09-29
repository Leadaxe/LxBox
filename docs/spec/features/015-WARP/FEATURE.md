[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Cloudflare WARP — free WireGuard, AmneziaWG and MASQUE nodes in one tap

LxBox registers the device with Cloudflare WARP directly and adds a ready
WireGuard, AmneziaWG-obfuscated or MASQUE node to the server list in one tap.
The private key is generated on the phone, and no third-party config generator
is involved.

| Field | Value |
|-------|-------|
| Feature | 015-WARP |
| Type | Product feature |
| Absorbed | `§025F` `§130F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

The user wants a free working tunnel without someone else's configs and
generator sites. The feature registers the device with Cloudflare WARP with a
single "Register" press in the "Get WARP" wizard (Servers screen menu) and
immediately puts a ready node into the list: a WireGuard node (optionally with
AmneziaWG obfuscation) or a MASQUE node (CONNECT-IP over HTTP/3 or HTTP/2).
Separately — "Make experiment": a folder of random WARP nodes over a pool of
known addresses, to find what gets through in a particular network.

The feature protects five principles:

- **The tunnel key is born and stays on the device.** No third-party config
  generators: their owner knows everyone's private key. Only the public part
  goes to Cloudflare.
- **One registration — many nodes.** The registration is cached and reused;
  node parameters (endpoint, obfuscation, HTTP version, SNI) change without a
  new registration. A new one — only on an explicit "Re-register".
- **The user's choice is stronger than defaults.** A manually entered endpoint
  is overwritten neither by the Cloudflare response, nor by the cache, nor by
  randomisation.
- **Pool data is not code.** Addresses, ports, SNI, API hosts and regional
  overrides live in one pool file and are edited without changing logic.
- **Only its current schema goes to the core.** MASQUE goes into the config
  with the `vhttp` and `tls{}` keys; obfuscation — with the core keys
  `id`/`ip`/`ib`; the service packet `i1` is built by the core, not the app.

## Promises

- **P1. The private key does not leave the device.** WireGuard: the
  registration request carries the public X25519 key. MASQUE: the first
  request carries a one-time public X25519 key, the second — a public ECDSA
  P-256 key in DER. **Witness:** units "register: /reg receives pub, not
  priv", "registerMasque: … the POST carries a 32-byte key", "PKIX public key:
  SPKI structure". **Mutation:** the private key gets into the request body.
- **P2. A dead API host does not break registration.** Hosts are tried in
  order; a network error or timeout (5 s per request) — the next host; any
  HTTP response, including 4xx/5xx, is final; all hosts dead — an error
  listing the hosts. Subsequent requests of the flow go to the host that
  answered. **Witness:** units "first host unreachable → registration via the
  second; license goes there too", "first host timeout → second", "an HTTP
  error from the first host is final", "all hosts unreachable → WarpException
  listing the hosts", "registerMasque: PATCH goes to the same host".
  **Mutation:** 4xx switches the host; PATCH goes to the first host.
- **P3. An invalid WARP+ license does not prevent getting a node.** A failure
  to bind the license leaves a free account, the node is added. **Witness:**
  unit "license: PATCH 4xx → the free account is kept". **Mutation:** a
  license error brings down the registration.
- **P4. A repeated "Register" does not register again.** Without
  "Re-register" the registration cache of its own transport is used; with
  "Re-register" — a new registration, the cache is replaced. The free-account
  cache is not used when a license is entered — the registration is new.
  **Witness:** manual check — Register twice without the checkbox: one
  `WARP registered` line in the log, both nodes have the same interface
  address. **Mutation:** the cache is ignored.
- **P5. Each "Register" adds a new node.** Previous WARP nodes are not
  deleted; a taken tag gets the suffix ` 2`, ` 3`… The tag by kind: `🔥☁️
  WARP`, `🔥⛈️ WARP (AWG 1.5)`, `🔥🎭 WARP (MASQUE)`, `+` for WARP+. **Witness:**
  unit "§137 nodeTag: cloud/storm, +, AWG suffix"; accumulation — manual
  check. **Mutation:** the new node replaces the previous one.
- **P6. A custom WireGuard endpoint is not overwritten.** A non-default
  endpoint goes into the node both on a fresh registration (the Cloudflare
  response is ignored) and from the cache; a default one is replaced by the
  host from the response. **Witness:** units "§135 register: a custom endpoint
  is NOT overwritten", "§135 default endpoint → fallback to the host from the
  response", "§138 copyWith(endpoint)". **Mutation:** the endpoint from the
  cache beats the input.
- **P7. A plain WARP node carries the binding to the device.** `reserved` from
  `client_id` (3 bytes), MTU 1280, all traffic in `allowed_ips`, keepalive 25
  s by default; with obfuscation `reserved` is not written by default;
  keepalive 0 — not written. **Witness:** units "toWireguardUri carries
  reserved and parses back", "keepalive=25 → query keepalive", "keepalive=0 →
  not written", "§142 includeReserved=false → NO Reserved". **Mutation:** a
  node without `reserved` with obfuscation off.
- **P8. Obfuscation does not break the WARP handshake.** Preset: `s1=s2=0`,
  `h1..h4=1,2,3,4`, `jc/jmin/jmax` (default 4/40/70) plus the masquerade keys
  `ip`/`id`/`ib` (`ib` — only with `ip=quic`); the app does not write `i1`.
  **Witness:** units "preset: s1=s2=0, h1..h4=1,2,3,4", "§143
  buildAmneziaAwg(quic): id/ip/ib, WITHOUT i1", "buildAmneziaAwg(dns): ib is
  NOT written", "§143 obfuscated: AWG + id/ip/ib + reserved reach the spec".
  **Mutation:** `i1` next to `id`/`ip`/`ib` (the core rejects both).
- **P9. MASQUE goes into the config only in the new schema.** Outbound
  `masque`: `vhttp`, SNI and SNI disabling — in the nested `tls{}`; there are
  no `network`/`sni` keys at the root; an empty SNI — no `tls` block.
  **Witness:** units "emitMasque yields an Outbound in the core schema", "SNI
  and disable_sni move into the nested tls{}", "an empty SNI does not create
  an empty tls{}". **Mutation:** writing the old and the new name side by side
  (the core fails on a mismatch).
- **P10. The HTTP version is a property of the node, not of the
  registration.** One MASQUE registration yields `h3`, `h2`, `auto` nodes; the
  WARP node's identity does not shift on any version. **Witness:** units "§393
  — the HTTP version is set when building the URI, not stored in the account",
  "the WARP factory node did not shift on any HTTP version". **Mutation:** the
  HTTP version in the registration cache.
- **P11. A manual MASQUE IP:port — only into the node.** The cache keeps the
  server from the registration; an empty IP field — the registration server.
  **Witness:** `no witness`. **Mutation:** the override is written to the cache
  and goes into all future nodes.
- **P12. h3 is not offered where it is dead.** Randomisation and the host list
  for `h3` — only the pool's h3 hosts; for `h2`/`auto` — the common hosts and
  the block minus exclusions. **Witness:** units "§420 randomMasqueIp: h3 —
  only from h3 hosts; h2 — the block minus exclude", "§420 masqueHostsFor: h3
  — common + h3-only; h2 and auto — common only". **Mutation:** h3
  randomisation over the whole block.
- **P13. The region edits the pool, not the logic.** The pool's
  `loc.<country>` section is overlaid on the root: objects are merged, lists
  are replaced whole, `alias` — one hop; an unknown region — the root.
  **Witness:** units "override by key; … a list replaced whole", "alias — one
  hop", "empty/unknown/broken region = root", "the picker cache is bound to
  the region". **Mutation:** region lists are appended to the root.
- **P14. The "(recommended)" mark does not leak into the value.** **Witness:**
  unit "§424 label = clean value". **Mutation:** the preset suffix in the
  endpoint.
- **P15. The experiment does not privilege a protocol.** Candidates are
  equally likely AWG / MASQUE h3 / MASQUE h2 among those available in the
  pool; the port — from its own transport's set; a protocol without a source
  is not seeded. **Witness:** units "covers all three protocols with a full
  pool", "§305 — the port matches the protocol", "wg range but NO wg ports →
  masque only, no crash". **Mutation:** AWG with an empty port set.
- **P16. Registration secrets are not written to the log.** The log gets a
  representation with the private key, token and license masked. **Witness:**
  units "WarpAccount.redacted masks priv_key/token/license", "redacted masks
  the private key and token". **Mutation:** the full registration in a log
  line.
- **P17. Registrations survive a backup.** **Witness:** units "warp:
  round-trip keeps the registration and mobile extras", "§219 —
  warp_account/masque_account survive restore". **Mutation:** a restore
  without registrations — a new "Register" spawns another device.

## Controlled parameters

The "Get WARP" wizard:

| Knob | Values | Default | Transport |
|------|--------|---------|-----------|
| Transport | WireGuard · MASQUE | WireGuard | — |
| Add Amnezia obfuscation | on/off | off | WG |
| WARP+ license key | string | empty (free) | WG |
| Endpoint | `host:port`, pool presets, 🎲 with obfuscation | `engage.cloudflareclient.com:2408` | WG |
| Persistent keepalive (s) | number, 0 — off | 25 | WG |
| Bind to this device (reserved) | on/off | = not obfuscation | WG |
| Masquerade protocol (`ip`) | QUIC · DNS · STUN · SIP | QUIC | WG+obfuscation |
| Masquerade domain (`id`) | domain, pool, 🎲 | random from the pool | WG+obfuscation |
| Browser (`ib`) | Chrome · Firefox · cURL | Chrome | with `ip=quic` |
| Jc / Jmin / Jmax | numbers | 4 / 40 / 70 | WG+obfuscation |
| Transport (HTTP version) | Auto (h3 → h2) · HTTP/3 · HTTP/2 | Auto | MASQUE |
| Endpoint IP / Port | IP, presets per transport, 🎲; port from the set | empty = from the registration; the first port of the set | MASQUE |
| SNI | domain, pool, 🎲 | random from the pool | MASQUE |
| Idle timeout (min) / Keep-alive (sec) | numbers; empty — core default | empty | MASQUE; keep-alive not for HTTP/2 |
| Re-register (force new account) | on/off | off | both |

"Make experiment": Number of nodes 1–200 (default 20), pool JSON (default —
the built-in pool). The common setting "Usage region" (Auto · Not set ·
country code) selects the pool's `loc.<cc>` section.

Core config keys the feature emits:

- endpoint `wireguard`: `address`, `private_key`, `mtu`, `peers[].address`/
  `port`/`public_key`/`reserved`/`allowed_ips`/`persistent_keepalive_interval`;
  with obfuscation at the root — `jc`, `jmin`, `jmax`, `s1`, `s2`, `h1`–`h4`,
  `ip`, `id`, `ib`;
- outbound `masque`: `server`, `server_port`, `profile: cloudflare`, `vhttp`,
  `private_key`, `public_key`, `ip`, `ipv6`, `mtu: 1280`, `tls.server_name`,
  `tls.disable_sni`, `idle_timeout`, `keep_alive_period`.

## Inputs / Outputs

**Inputs:** wizard presses; responses of the Cloudflare registration API
(`/reg`, `/reg/{id}`, `/reg/{id}/account`); the pool file (`api`,
`wireguard`, `masque`, `loc`); the region setting; the system IPv6 flag
(allows v6 WG addresses).

**Outputs:** a node in the Servers list (a single server with a
`wireguard://…` or `masque://…` link); the "WARP GENERATOR" folder; the WG and
MASQUE registration caches; `warp[]` entries in the backup; the snack "Added
WARP node" / "Added WARP+ node" / "Added MASQUE node" or an error text.

## Data flow

```
wizard → [transport registration cache?] ─ yes ─┐
            │ no / Re-register                  │
            ▼                                   │
   key on the device → POST /reg (trying API hosts)
            │ WG: (+PATCH license)   MASQUE: PATCH enroll ECDSA
            ▼                                   │
   registration → cache ◄───────────────────────┘
            ▼
   node parameters (endpoint, obfuscation, vhttp, SNI, IP:port)
            ▼
   node link → shared parsing → new single server with a WARP tag
            ▼
   config build → endpoint `wireguard` / outbound `masque`
```

Experiment: pool (+region, +JSON edit) → cache or registration of both
transports → N random candidates → links → the "WARP GENERATOR" folder.

## Rules and guarantees

- Registration without network/with an error — the node is not added, the
  cache does not change.
- A response without the peer key or without the interface address — a "bad
  response" error, no node. A MASQUE server response in PEM is converted to
  base64(DER).
- Obfuscation is client-side: turning it on/off on the cache does not require
  a new registration. Turning it on substitutes a random `ip:port` from the WG
  blocks if the endpoint was not entered by hand; turning it off returns the
  fields to defaults.
- v6 WG addresses are substituted only when IPv6 is enabled in the system.
- The WG and MASQUE registration caches are separate and do not go into the
  config — only the nodes do: WG — an endpoint, MASQUE — an outbound; both
  work as regular nodes.
- Global TLS fragmentation affects a MASQUE node only with `h2`/`auto` (there
  is a TCP leg) and not under a detour; `h3` is silently skipped.

## Boundaries

- Parsing `wireguard://` / `masque://` links / WG INI — 002-NODE_IMPORT; the
  feature only produces the links.
- Editing a ready node — 008-NODE_EDITOR; ping and checking the "WARP
  GENERATOR" folder — 009-NODE_HEALTH (the experiment itself does not probe
  and does not delete dead nodes).
- Registration is a direct request from the app: choosing a node or detour for
  it is not possible; with dead hosts there is no "register via a proxy" hint.
- WARP+ for MASQUE is not supported (the license field is hidden in MASQUE
  mode).
- The `host:port` format of the endpoint is not validated before
  registration.
- `tls.disable_sni` is not set in the wizard — only via a link/import.
- Country auto-detection depends on OS capabilities (operator network →
  locale).
- Secrets in the Debug API are deliberately not masked (root access by
  design, 013-DIAGNOSTICS); registration without the UI — `POST /warp` in the
  same place.

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| One-tap registration | Registers the device with Cloudflare directly, keeps the key on the device, tries API hosts in turn, binds WARP+, caches the registration until "Re-register" and saves it in the backup. | P1–P4, P16, P17 | [one-tap-registration.md](FUNCTIONS/one-tap-registration.md) |
| WARP WireGuard node | Turns a WireGuard registration into a new node with endpoint, `reserved` and keepalive, tagged by kind, without replacing earlier WARP nodes. | P5–P7, P14 | [wireguard-node.md](FUNCTIONS/wireguard-node.md) |
| AmneziaWG obfuscation | Adds AmneziaWG junk packets disguised as QUIC, DNS, STUN or SIP through `id`/`ip`/`ib`, keeping the WireGuard handshake that Cloudflare accepts. | P8 | [awg-obfuscation.md](FUNCTIONS/awg-obfuscation.md) |
| WARP MASQUE node | Builds a `masque` outbound over HTTP/3 or HTTP/2 with the chosen IP:port, SNI and timeouts, in the core's current schema. | P9–P12 | [masque-node.md](FUNCTIONS/masque-node.md) |
| Endpoint pool and region | Keeps Cloudflare API hosts, WireGuard and MASQUE addresses and ports, SNI pools and `loc.<cc>` region overrides in one data file. | P12–P14 | [endpoint-pool.md](FUNCTIONS/endpoint-pool.md) |
| Experiment: WARP node generator | Creates the "WARP GENERATOR" folder of random AWG and MASQUE candidates, so the user can test them and keep what gets through. | P15 | [warp-generator.md](FUNCTIONS/warp-generator.md) |

## Related features

- [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md) — parses the `wireguard://`
  / `masque://` links and WG INI that this feature produces.
- [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md) — editing a WARP node after it is added.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — ping and checking of WARP nodes and the "WARP GENERATOR" folder.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — Debug API: `POST /warp`
  registration without the UI, unmasked secrets by design.
- [016-DPI_HARDENING](../016-DPI_HARDENING/FEATURE.md) — global TLS fragmentation reaches MASQUE nodes over `h2`/`auto`.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) —
  registrations travel in the backup as `warp[]` entries.

## Maintenance notes

- **The API version moves.** Cloudflare periodically changes the path
  `v0a2158` and the client header `a-7.21-0721`; a 4xx on `/reg` — first of
  all compare with the current `wgcf`/`warp-cli`.
- **`api.cloudflareclient.com` is silent on TCP from Russia.** That is why
  `api.devices.cloudflare.com` comes first; the built-in fallback list must
  match the pool's `api.hosts`.
- **h3 lives on a handful of addresses.** In `162.159.198.0/24` and
  `.199.0/24`: `.1` — h3 only, `.2` — both, the rest — h2 only. h3
  randomisation over the block yields ~1% live ones.
- **A naive probe lies about QUIC.** Measure MASQUE liveness through the
  production core (reconnect + URLTest), not with a probe while the VPN is
  off.
- **Without keepalive a WARP WG node "rots"**: NAT closes in 30–120 s.
