[English](server-certificate.md) · [Русский](server-certificate.ru.md)

# Server certificate verification — CA store, insecure flag and key pinning

LxBox lets the user pick the root CA store for the core and keeps each node's
`insecure` flag, certificate pin and custom CA intact and visible.

| Field | Value |
|-------|-------|
| Feature | [016-DPI_HARDENING](../FEATURE.md) |
| Promises | P16 P17 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Keeps TLS server verification as strict as the subscription promised and lets
the user choose the set of root certificates. Verification is performed by
the core; the app is responsible for the verification parameters not getting
lost along the way and for any weakening of it being visible.

## Parameters

| Knob / input | Values | Default | Core key |
|---|---|---|---|
| Certificate store (core settings) | `system` · `mozilla` · `chrome` | `system` | `certificate.store` |
| `insecure` / `allowInsecure` / `allow_insecure` / `skipCertVerify` / `noverify` … in a link | `1`/`true`/`yes` | off | `tls.insecure` |
| `pinSHA256` in a hysteria/hysteria2 link | base64 SHA-256 of the public key, a list | — | `tls.certificate_public_key_sha256` |
| Node JSON `tls.certificate` / `certificate_path` / `client_*` | PEM as a string or a list, a path | — | the same keys |
| Xray `tlsSettings.certificates[0].certificateFile` | a path | — | `tls.certificate_path` |

The setting's hint: on Android 7.x and older the system store is outdated (no
Let's Encrypt and other modern authorities) — TLS nodes do not connect;
`mozilla`/`chrome` take the current set built into the app.

## Inputs / Outputs

**Inputs:** the user's choice; link parameters; TLS fields of the node JSON.
**Outputs:** `certificate.store` in the config; `tls.insecure`,
`tls.certificate_public_key_sha256`, `tls.certificate*` in the outbound;
codes `tls_insecure` (info), `xray_cert_chain_pin_unsupported`.

## Rules and invariants

- `insecure` from a link is kept (a deliberate choice of the provider), but
  the node gets the code `tls_insecure` with the path and value: MITM
  protection is off. All spellings of the parameter are read
  case-insensitively.
- The key pin (`pinSHA256`) is lost neither during parsing nor in the link on
  export; on QUIC (hysteria2) it applies and is not cut. A conflict with
  `tls.certificate`/`certificate_path` is resolved by the registry.
- The node's own root CA (`tls.certificate`) and neighbouring core TLS fields
  pass node parsing and saving in the form they arrived in (a string stays a
  string, a list — a list); unfamiliar TLS keys are dropped so that the core
  does not reject the config.
- The Xray certificate chain pin (`pinnedPeerCertificateChainSha256`) has no
  core counterpart: it is not carried over, the node gets a code.
- naive accepts from TLS only `certificate`, `certificate_path`, `ech`;
  `insecure` and pins are forbidden for it by the node schema.

## Boundaries

- Core settings in general and portability to the backup —
  [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md); "Certificate store"
  is not part of the cross-platform backup.
- The system store depends on OS capabilities.
- Not done (dropped from the plan §020F): certificate pinning of the app
  itself, encrypted storage of secrets, masking links and credentials in the
  UI and logs.
- The local proxy of Proxy mode and its authorisation —
  [010-VPN_SERVICE](../../010-VPN_SERVICE/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [020F](../../../tasks/020F-security-and-dpi-bypass/spec.md) | Closed | Umbrella security spec; roadmap dropped |
| 2 | [179](../../../tasks/179-rc6-platforminterface-systemcertificates-removed.md) | ✅ DEVICE-VERIFIED | The core stopped taking system certificates from the app |
| 3 | [385](../../../tasks/385-certificate-store-selector.md) | Implemented, PENDING-DEVICE | CA store choice: system / mozilla / chrome |
| 4 | [454](../../../tasks/454-tls-certificate-round-trip.md) | Released v2.24.3 | `tls.certificate` and neighbours are not lost when editing the node |
