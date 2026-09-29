[English](ech.md) · [Русский](ech.ru.md)

# ECH (Encrypted Client Hello) — passed through from JSON, never enabled from a link

LxBox passes a node's `tls.ech` block to the core only when the node JSON
contains it; the link parameter `ech=` is dropped with an explanation.

| Field | Value |
|-------|-------|
| Feature | [016-DPI_HARDENING](../FEATURE.md) |
| Promises | P10 |
| State | ✅ written from code, 2026-09-28 |

## What it does

ECH hides the real SNI in the encrypted part of the ClientHello; DPI sees
only the front's outer name. The app **does not enable ECH itself** and
provides no toggle for it: the `tls.ech` block reaches the core only if the
node JSON explicitly brought it, while the Xray link parameter `ech=` is
dropped with an explanation. The per-node "Enable ECH" checkbox planned in
§045F and parsing of `?ech=1`/`?ech=<base64>` are not implemented.

## Parameters

| Input | What happens | Core key |
|---|---|---|
| sing-box JSON `tls.ech{…}` | copied as is (an object), the app does not look inside | `tls.ech` (`enabled`, `config`, `config_path`, `query_server_name`) |
| Xray JSON `tlsSettings.echConfigList` | strings → `tls.ech.config`, `enabled: true` is inferred | `tls.ech` |
| Link `ech=<name>+<resolver>` or `ech=<name>` | not mapped; code `ech_ignored` (info) with the value `<name>` | — |
| Link `ech=` empty / `none` | nothing, no code | — |
| `echfq` | not read | — |

## Inputs / Outputs

**Inputs:** node JSON; link parameters.
**Outputs:** `tls.ech{}` in the outbound (field order as in the core
structure); the `ech_ignored` code in the node's notifications.

## Rules and invariants

- Why the link's `ech=` is not applied: the Xray form carries not this
  server's key but the name of a public ECH probe that must be asked for the
  config via DNS. Subscriptions put foreign names there (`ip.gs`,
  `encryptedsni.com`), their config is issued for another front's
  `public_name` — the handshake with it will not happen. The core has no
  fallback to regular TLS, and suitability cannot be checked before
  connecting. Measurement: the same node with `ech` is dead, without it —
  alive.
- `echfq` (Xray pq-signature-schemes) is not read: the matching core option
  was removed and with `true` would bring down the config.
- A non-object `tls.ech` in JSON is dropped silently; a block with
  `enabled: false` is removed.
- `tls.ech.enabled` conflicts with `tls.reality.enabled`; on MASQUE ECH is
  removed (`masque_tls_field_ignored`); naive reads the block as a whole.
- `ech` is never written into a link on export.
- The rest of the node (SNI, transport, REALITY) does not change depending on
  the presence of `ech=`.
- Mixed-case SNI has no separate gate for ECH nodes: the `server_name` of such
  a node is randomised like that of regular TLS.

## Boundaries

- There is no global "ECH for everyone" and there will not be: a server
  without ECH support fails with an obscure handshake error.
- The core does not provide an auto-fallback "ECH failed → without ECH";
  neither does the app.
- ECH is always built into the core (there is no separate build tag).
- `echConfigList` from Xray JSON is not covered by an app unit (only in the
  contract corpus).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [045F](../../../tasks/045F-tls-ech/spec.md) | Draft, not implemented | The idea: a per-node ECH checkbox, `?ech=1`/`?ech=<base64>` |
| 2 | [320](../../../tasks/320-trojan-subscription-parse-gaps.md) | ✅ DEVICE-VERIFIED | `ech=` from a subscription is not enabled, only a code |
| 3 | [459](../../../tasks/459-guards-contract-24-2.md) | Released v2.25.0 | `tls.ech{}` from JSON passes (the core is always built with ECH) |
