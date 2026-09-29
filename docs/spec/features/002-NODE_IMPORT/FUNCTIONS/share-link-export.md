[English](share-link-export.md) · [Русский](share-link-export.ru.md)

# Export to a share link — copying a node as a link for another device or client

Any node can be turned back into a share link of its scheme; a link that carries a private key is
copied only after confirmation.

| Field | Value |
|------|----------|
| Feature | [002-NODE_IMPORT](../FEATURE.md) |
| Promises | P2 P13 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Builds a share link of the node's scheme from the node — to move the node to another
device or another client ("Copy link"). The same link serves as the storage form
of own servers, so it must parse back into the same node.

## Parameters

| Node | What is produced |
|------|--------------|
| `vless`, `trojan`, `tuic`, `anytls`, `hysteria2`, `ssh` | URL form, parameters in alphabetical order |
| `vmess` | `vmess://` + base64(JSON) without padding |
| `shadowsocks` | `ss://` + base64url(`method:password`) without padding, `@host:port#name` |
| `socks` | scheme by version: `socks4://`, `socks4a://`, otherwise `socks5://` |
| `http` | `proxy-https://` with TLS, otherwise `proxy-http://` |
| `naive` | `naive+quic://` with QUIC, otherwise `naive+https://`; the port is always written |
| `wireguard` (+AWG), `masque` | URL form, semantic parameter order; WireGuard — one peer |
| `tailscale` | not a link: the JSON text of the body with `tag` |
| `openvpn-client`, a type outside the registry | the node's source text |
| group | no link |

Build rules — the `emit` section of each protocol in the registry.

## Inputs / Outputs

**Input:** a node. **Output:** a link string; an empty string — the link cannot
be built.

## Rules and invariants

- **Round trip:** parsing the built link yields the same body; rebuilding the same
  body gives the same string byte for byte; old links from the former hand-written
  emit are read the same way.
- **Rejection instead of distortion.** A body that cannot be expressed as a link
  (WireGuard with several `peers`) yields an empty link, not a link to the
  first peer. Copying an empty link does nothing.
- **Private key.** If the body has a field with the `private_key` role per the registry
  (WireGuard/AWG, SSH with a key, MASQUE), the app asks for confirmation before copying:
  "Link contains a private key" with the buttons "Cancel" and "Copy anyway".
  Cancel does not touch the clipboard. The key is not cut from the link — otherwise
  the own link would stop restoring the node. A VLESS UUID and an SSH password
  do not count as a key.
- After copying — "URI copied"; node not found — "No source URI for this
  node".
- Without a loaded registry, building a link is an error, not an empty string
  (the own link is a storage form, a silent loss is unacceptable).

## Boundaries

- Where copying and QR are in the UI — [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md).
- Node storage form and backup — [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.md).
- A subscription node's link is its source text; export builds the link
  anew from the body, it is not obliged to match the original byte for byte.

## Revisions

| # | Revision | Status | Summary |
|---|---------|--------|------|
| 1 | [026F](../../../tasks/026F-parser-v2/spec.md) | Implemented | Canonical node URI, round-trip invariant |
| 2 | [037F](../../../tasks/037F-naive-proxy/spec.md) | Draft | A naive link from a node |
| 3 | [097F](../../../tasks/097F-awg2-amneziawg2/spec.md) | In progress | Link round trip with AWG fields |
| 4 | [466](../../../tasks/466-copy-link-private-key-confirm.md) | Released v2.25.0 | Confirmation when copying a link with a private key |
| 5 | [475](../../../tasks/475-contract-118-socks-version-by-scheme.md) | Released v2.25.0 | socks scheme by body version |
| 6 | [480F](../../../tasks/480F-registry-driven-mapper/spec.md) | Released v2.25.0 | Building a link by the registry `emit` section (W7) |
| 7 | [495](../../../tasks/495-emitter-section33-launcher-parity.md) | Released v2.25.0 | Emitter checked against the launcher's findings |
| 8 | [514](../../../tasks/514-contract-sync-11152.md) | Released v2.25.2 | Empty socks4 password — the separator is kept |
