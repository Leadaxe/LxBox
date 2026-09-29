[English](wireguard-node.md) · [Русский](wireguard-node.ru.md)

# WARP WireGuard node

| Field | Value |
|-------|-------|
| Feature | [015-WARP](../FEATURE.md) |
| Promises | P5, P6, P7, P14 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Turns a WG registration into a ready node in the Servers list: a single
server with a `wireguard://…` link (or a WG INI with AmneziaWG fields when
obfuscated) that can be pinged and works in any VPN/Proxy mode. Each
"Register" adds a new node — the user keeps several variants (endpoint,
obfuscation) on one registration.

## Parameters

| Parameter | Value | Default |
|-----------|-------|---------|
| Endpoint | `host:port`; the pool's preset list + free input | `engage.cloudflareclient.com:2408` |
| Persistent keepalive (s) | number; 0/empty — not written | 25 |
| Bind to this device (reserved) | on/off | on without obfuscation, off with it |
| MTU | 1280 | — |
| `allowed_ips` | `0.0.0.0/0`, `::/0` | — |

## Inputs / Outputs

**Inputs:** a WG registration (fresh or from the cache), wizard input.

**Outputs:** a `wireguard` endpoint in the config: `address` (v4 + v6),
`private_key`, `mtu`, a peer with `address`/`port`/`public_key`/`allowed_ips`,
`reserved` (3 bytes of `client_id`), `persistent_keepalive_interval`.
Node tag: `🔥☁️ WARP`, `🔥☁️ WARP+`, `🔥⛈️ WARP (AWG 1.5)`,
`🔥⛈️ WARP+ (AWG 1.5)`; a taken one — the suffix ` 2`, ` 3`…

## Rules and invariants

- **Endpoint.** An entered non-default endpoint beats both the Cloudflare
  response (which always returns `engage…:2408`) and the endpoint from the
  registration cache. The default without obfuscation — the host from the
  Cloudflare response; the default with obfuscation — a random `ip:port` (see
  obfuscation). The applied endpoint is written to the cache.
- **Presets.** The Endpoint list is taken from the pool's
  `wireguard.endpoints_preset`; the item equal to `recommended_endpoint` is
  marked "(recommended)" only in the menu — the clean value goes into the
  field and the node.
- **reserved.** By default it is written without obfuscation and not written
  with it (the binding to the device is cut by DPI); the checkbox overrides.
  A broken `client_id` (not 3 bytes) — `reserved` is not written.
- **Keepalive.** Empty or 0 — no key; without it a WG node loses the NAT
  mapping when idle and degrades to `err`.
- **Accumulation.** Previous WARP nodes are neither deleted nor updated by
  tag.
- **Success.** The snack "Added WARP node" / "Added WARP+ node", the config is
  rebuilt, the wizard closes. A node build failure — "Invalid WARP config" /
  "Invalid WARP config (obfuscated)".

## Boundaries

- Parsing the link and INI — 002-NODE_IMPORT; editing the node later —
  008-NODE_EDITOR.
- The `host:port` format is not validated before registration.
- A v6 endpoint is substituted only by randomisation and only with IPv6
  enabled.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [025F](../../../tasks/025F-warp-integration/spec.md) | Released v2.3.0 | Node from the registration, `reserved` from `client_id`, MTU 1280 |
| 2 | [135](../../../tasks/135-warp-custom-endpoint-not-overwritten.md) | Done (device-smoke pending) | A custom endpoint is not overwritten by the Cloudflare response |
| 3 | [137](../../../tasks/137-warp-node-naming.md) | Implemented | Tags with emoji, accumulating nodes instead of replacing |
| 4 | [138](../../../tasks/138-warp-cached-account-ignores-endpoint.md) | Fixed | The selected endpoint is applied to the cache as well |
| 5 | [142](../../../tasks/142-warp-reserved-optional.md) | Done (released v2.3.3) | `reserved` is optional, default by obfuscation |
| 6 | [304](../../../tasks/304-warp-persistent-keepalive.md) | — | Keepalive 25 s on manual registration |
| 7 | [386](../../../tasks/386-warp-endpoint-preset-combobox.md) | — | Preset list at the Endpoint field |
| 8 | [424](../../../tasks/424-warp-preset-recommended-mark-leak.md) | Implemented (unit + widget test) | The "(recommended)" mark does not leak into the value |
