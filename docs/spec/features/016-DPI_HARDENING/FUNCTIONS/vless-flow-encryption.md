[English](vless-flow-encryption.md) · [Русский](vless-flow-encryption.ru.md)

# VLESS flow and encryption

| Field | Value |
|-------|-------|
| Feature | [016-DPI_HARDENING](../FEATURE.md) |
| Promises | P14 P15 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Carries two VLESS protection layers from the subscription into the config
the way the provider set them: XTLS Vision (`flow`) — TLS-in-TLS disguise,
and VLESS Encryption (`encryption`) — post-quantum encryption of the payload
on top of the transport. Adds nothing of its own and removes nothing
silently.

## Parameters

| Input | Value | Core key |
|---|---|---|
| `flow=xtls-rprx-vision` | as is | `flow` |
| `flow=xtls-rprx-vision-udp443` | `xtls-rprx-vision` + `packet_encoding: xudp`; the node port does not change | `flow`, `packet_encoding` |
| `flow` empty · `none` · deprecated (`xtls-rprx-direct`, …) · junk | no key (deprecated/junk — code `flow_deprecated`) | — |
| `encryption=<core grammar>` | verbatim, edges trimmed | `encryption` |
| `encryption` empty or exactly `none` | no layer, no code | — |

## Inputs / Outputs

**Inputs:** a VLESS link; Xray JSON (`users[].flow`, `users[].encryption`);
sing-box JSON.
**Outputs:** `flow`, `packet_encoding`, `encryption` in the outbound; codes
`vision_with_transport` (info), `flow_deprecated`,
`vless_encryption_invalid` (node rejected).

## Rules and invariants

- `flow` is not imposed: REALITY on bare TCP without `flow` in the link goes
  without `flow`: a server without Vision does not accept a client with
  Vision.
- Vision is incompatible with a transport (ws, grpc, xhttp, …): with a
  transport `flow` is removed with the code `vision_with_transport`, the node
  lives. The exception is a node with `encryption` set: Vision then works on
  top of the encryption layer, the transport does not matter to it, `flow`
  stays without a code.
- "`encryption` is set" = the field will reach the body; empty and exact
  `none` are not set and do not trigger the exception.
- Checking `encryption`: decode → trim edges → empty/exact `none` → match
  against the core grammar (`mlkem768x25519plus.<mode>.<rtt>.…`, a key of 32
  or 1184 bytes, padding blocks). A space inside a segment is legitimate.
- An invalid form (three parts, an empty segment, a different method, the
  method in a different case, a trailing dot, `None`) → **the node is
  rejected** with a code and the raw value: removing encryption and keeping
  the node would silently downgrade protection, and without the layer the
  server would not accept the client anyway.
- A sing-box JSON body is judged by the same rule as the link.
- The "link → node → link" round trip preserves `encryption`.

## Boundaries

- Vision working on top of `encryption` on the core side — the core
  (sing-box-lx#29); without it such a node will not come up even with
  `flow`.
- The `encryption` layer as a whole — the core (core: FEATURE
  012-VLESS_ENCRYPTION).
- `packet_encoding` in general (allow-list `xudp`/`packetaddr`) — link
  parsing, [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [012](../../../tasks/012-vless-packet-encoding-libbox-panic.md) | — | `packet_encoding` from a link does not crash the core |
| 2 | [115](../../../tasks/115-vless-flow-honor-link.md) | Code-complete in develop | `flow` from the link, Vision not imposed, suppressed with a transport |
| 3 | [335](../../../tasks/335-vless-encryption-passthrough.md) | ✅ implemented | `encryption` from a subscription reaches the config |
| 4 | [477](../../../tasks/477-vless-encryption-grammar.md) | Released v2.25.0 | The core grammar; an invalid value rejects the node |
| 5 | [544](../../../tasks/544-vless-vision-xhttp-with-encryption.md) | Done | Vision on a node with `encryption` is not removed because of the transport |
