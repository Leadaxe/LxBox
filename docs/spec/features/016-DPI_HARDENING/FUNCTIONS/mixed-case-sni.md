[English](mixed-case-sni.md) · [Русский](mixed-case-sni.ru.md)

# Mixed-case SNI

| Field | Value |
|-------|-------|
| Feature | [016-DPI_HARDENING](../FEATURE.md) |
| Promises | P5 P6 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The "Mixed-case SNI" checkbox randomly changes the case of letters in
`server_name` (`WwW.gOoGle.CoM`). Per RFC 6066 the SNI name is
case-insensitive, the server accepts any form, while DPI with exact string
matching misses. Against filters that normalise case, the technique is
useless — the setting's hint says so directly.

## Parameters

| Knob | Values | Default | Core key |
|---|---|---|---|
| Mixed-case SNI — "…defeats naive exact-match matching only. Skipped on REALITY nodes — their SNI must stay byte-exact" | on/off | off | `tls.server_name` |

## Inputs / Outputs

**Inputs:** the checkbox; built outbounds with `tls.server_name`.
**Outputs:** the same `server_name` with random case of ASCII letters.

## Rules and invariants

- Candidate: an outbound without `detour`, with a `tls` block and a
  non-empty string `server_name`; a node without an explicit name is not
  touched.
- REALITY (`tls.reality.enabled: true`) is skipped: a REALITY server matches
  the name as an exact string, and the client signs the ClientHello together
  with the SNI — one changed letter diverts the connection to the camouflage
  site without an error. REALITY with `enabled: false` is randomised like
  regular TLS. The decision is per node, not per config: a neighbour without
  REALITY is randomised.
- Only ASCII letters change; digits, hyphens, dots, non-ASCII — as is. An IP
  literal does not change (no letters). A label starting with `xn--`
  (Punycode) does not change at all; neighbouring ASCII labels do.
- The result always equals the original case-insensitively.
- Each outbound has its own independent random mix.
- The mix is fixed per config build and lives until the next rebuild; it
  does not change on every handshake.
- The step runs after fragmentation and is orthogonal to it: both techniques
  can work on one node.
- Checkbox off → `server_name` byte for byte as in the node.

## Boundaries

- Transport headers (`host` of ws/httpupgrade/xhttp, `:authority`) do not
  change — only the TLS SNI.
- Node ping and probe are built by a separate path: their SNI is the
  original. Hence "ping works but the VPN does not" is the first sign that it
  is the global technique that hinders the node.
- Rotation on every handshake, ClientHello padding, replacing the SNI with
  another domain — not done.
- Inner hops (`detour`) are not visible to local DPI and are not touched.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [028F](../../../tasks/028F-antidpi-sni-obfuscation/spec.md) | Implemented and in production | Mixed-case SNI checkbox, first hop, Punycode and IP untouched |
| 2 | [363](../../../tasks/363-mixed-case-sni-breaks-reality.md) | ✅ DEVICE-VERIFIED | REALITY nodes are skipped, SNI byte for byte |
