[English](reality-params.md) · [Русский](reality-params.ru.md)

# REALITY parameters

| Field | Value |
|-------|-------|
| Feature | [016-DPI_HARDENING](../FEATURE.md) |
| Promises | P9 (P6, P8 — adjacent) |
| State | ✅ written from code, 2026-09-28 |

## What it does

Builds a node's `tls.reality` block from a link (`security=reality`, `pbk`,
`sid`, `key_share`), Xray JSON (`realitySettings`) or sing-box JSON and makes
sure that a broken value of one subscription node does not turn into a core
refusal for the whole config. The core decodes `public_key` as X25519 and
`short_id` as 8 bytes of hex, and fails at startup on any deviation.

## Parameters

| Link parameter | Core key | Norm |
|---|---|---|
| `pbk` | `tls.reality.public_key` | base64/base64url, with or without padding, exactly 32 bytes; into the config — the core's form (RawURL) |
| `sid` | `tls.reality.short_id` | hex, even length, ≤ 16 characters; empty is legitimate |
| `key_share` | `tls.reality.key_share` | `""` (as the fingerprint carries it) · `hybrid` · `classical`; core ≥ `v1.14.1-lx.4` |

## Inputs / Outputs

**Inputs:** VLESS and AnyTLS links (REALITY from a link is not parsed for
trojan/http), Xray `realitySettings`, sing-box `tls.reality`.
**Outputs:** `tls.reality{enabled, public_key, short_id?, key_share?}` (empty
`short_id`/`key_share` are not written); codes on the node; build lines
"REALITY short_id cleared: outbound "…" had invalid hex "…" — kernel would
reject the whole config." and "REALITY removed: outbound "…" had invalid
public_key "…" — node degraded to plain TLS."

## Rules and invariants

- REALITY is built from a valid key, not from "`pbk` is non-empty": junk
  (`enabled`, `true`, empty, not 32 bytes) → no block, the node goes over
  regular TLS (the case of broken public subscriptions with `pbk` on
  `security=tls`).
- `short_id` during parsing: lower-cased, non-hex characters are stripped;
  a result of odd length or longer than 16 → empty, the node lives.
  Truncation to 16 is not done: it would produce someone else's identifier.
- `key_share`: case and whitespace are normalised; outside the enum → the
  field is removed silently, the node lives; without a valid `pbk` the
  parameter is ignored; the "link → node → link" round trip preserves it.
- Before the core — a safeguard for paths bypassing parsing (JSON, import
  rules, substitutions): an invalid `public_key` → the whole `reality` block
  is removed; a `short_id` that is odd/non-hex/>16/not a string → `""`. The
  check is strict, without fitting. A disabled block (`enabled: false`) is
  not checked.
- REALITY and `tls.ech.enabled`, REALITY and `tls.spoof` — a conflict, one
  of the fields is removed by the registry.
- There is no REALITY on QUIC (hysteria2/tuic): the block is removed.
- The SNI of a REALITY node is not randomised (see
  [mixed-case-sni.md](mixed-case-sni.md)); fingerprint and hybrid key share —
  [utls-fingerprint.md](utls-fingerprint.md).
- Fragmentation applies to REALITY from core `v1.14.1-lx.4`.

## Boundaries

- Establishing the REALITY handshake, the client version for
  `minClientVer`, the hybrid key share itself — the core (core: FEATURE
  017-REALITY).
- There is no separate `key_share` choice in the app settings: the value
  comes from the link/JSON or is edited in the node JSON.
- Degrading to regular TLS means the node most likely will not come up (the
  server expects REALITY), but the rest of the config works.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [169](../../../tasks/169-reality-pbk-validation.md) | Implemented (device-verified) | REALITY only with a valid X25519 key |
| 2 | [343](../../../tasks/343-reality-short-id-validation.md) | Released v2.19.2 | A broken `short_id` is dropped entirely, a safeguard before the core |
| 3 | [457](../../../tasks/457-kernel-lx4-reality-key-share.md) | Released v2.24.3 | `tls.reality.key_share` (hybrid · classical) |
| 4 | [459](../../../tasks/459-guards-contract-24-2.md) | Released v2.25.0 | `key_share` case is normalised |
| 5 | [556](../../../tasks/556-registry-debt-1157-1170.md) | Partially done | REALITY without uTLS is fixed by a registry rule |
