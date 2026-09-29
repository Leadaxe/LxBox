[English](utls-fingerprint.md) · [Русский](utls-fingerprint.ru.md)

# uTLS fingerprint — a ClientHello fingerprint the core always accepts

LxBox maps the fingerprint (`fp`) from a subscription onto the uTLS dictionary
of the sing-box core, so that an Xray alias or a typo never breaks the config.

| Field | Value |
|-------|-------|
| Feature | [016-DPI_HARDENING](../FEATURE.md) |
| Promises | P7 P8 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Brings the ClientHello fingerprint given by the subscription (`fp`) to the
core's dictionary and decides what to do if it is not there. The core checks
`tls.utls.fingerprint` strictly against the dictionary, case-sensitively, and
an unknown value brings down the whole config; subscriptions, however, are
written for Xray, which accepts raw library names and any case.

## Parameters

The core dictionary: `chrome`, `chrome_psk`, `chrome_psk_shuffle`,
`chrome_padding_psk_shuffle`, `chrome_pq`, `chrome_pq_psk`, `firefox`,
`edge`, `safari`, `360`, `qq`, `ios`, `android`, `random`, `randomized`.

Default fingerprint (no `fp` field or empty):

| Node | Result |
|---|---|
| VLESS, TLS | `random` (a subscription convention, not the core default) |
| VLESS, REALITY | `chrome` with the code `reality_fp_random_pinned` |
| Trojan, AnyTLS from a link | no `utls` block |
| sing-box JSON with an empty `fingerprint` | `utls.enabled` without a fingerprint (core = `chrome`) |
| Xray JSON REALITY with an empty `fingerprint` | `chrome` |

## Inputs / Outputs

**Inputs:** the link's `fp`/`fingerprint`; Xray `fingerprint`; sing-box JSON
`tls.utls`.
**Outputs:** `tls.utls{enabled, fingerprint}`; codes `utls_fp_unknown`,
`reality_fp_not_chrome`, `reality_fp_random_pinned`,
`tls_not_applicable_quic`; the build line "Fingerprint replaced: outbound
"…" had unknown uTLS fingerprint "…" — using "chrome" instead."

## Rules and invariants

- Case and surrounding whitespace are removed silently (`QQ` → `qq`).
- Xray aliases by prefix — silently, without a code: `hellochrome*` →
  `chrome`, `hellofirefox*` → `firefox`, likewise edge/safari/360/qq/
  ios/android; `hellorandom*` → `random` (from a link `hellorandomized*` →
  `randomized`, see the discrepancy report).
- An unrecognised value → `chrome` + `utls_fp_unknown` with the raw value:
  the fingerprint is a client-side disguise, the server knows nothing about
  it, the node is almost certainly alive, it must not be thrown away.
- REALITY requires uTLS: with REALITY and no `utls` block the block is
  enabled (without a fingerprint). An explicit `random` under REALITY →
  `chrome`.
- An Xray REALITY server ≥ v26.9.8 accepts only a ClientHello with the hybrid
  key share `X25519MLKEM768`. It is carried by `chrome*`, `firefox`, `safari`
  (the last two — from core `v1.14.1-lx.3`). The others under REALITY
  (`edge`, `ios`, `android`, `360`, `qq`, `randomized`) go as is, with the
  warning `reality_fp_not_chrome`: the fingerprint was chosen by the
  provider, the app does not rewrite it.
- hysteria/hysteria2/tuic/MASQUE: `utls` and `reality` are removed
  (`tls_not_applicable_quic`); `fp` is not written back to the link.
- naive: `utls` is forbidden by the node schema.
- Before the core — a safeguard: any unknown fingerprint that got past
  parsing is replaced by `chrome` with a build line; a whitespace-only one is
  removed, `utls` stays enabled. On an authored JSON body the replacement is
  performed (the core would reject it), soft edits are not.

## Boundaries

- Choosing the fingerprint by hand — via the node JSON
  ([008-NODE_EDITOR](../../008-NODE_EDITOR/FEATURE.md)); there is no global
  "default fingerprint" in the settings.
- Filtering nodes by `tls.utls.fingerprint` —
  [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md).
- The ClientHello itself is built by the core; the hybrid set is a mirror of
  the core, and if the pin is rolled back below `v1.14.1-lx.3` it must be
  narrowed.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [281](../../../tasks/281-utls-fingerprint-normalize.md) | Implemented | Unknown fingerprint → `chrome` instead of a fatal error, aliases silently |
| 2 | [282](../../../tasks/282-utls-invalid-over-quic.md) | Implemented | uTLS/REALITY over QUIC are removed |
| 3 | [433](../../../tasks/433-reality-fp-not-chrome-naive-extra-headers-codes.md) | Done | The `reality_fp_not_chrome` code, explicit `chrome` under REALITY |
| 4 | [444](../../../tasks/444-reality-fingerprint-no-override.md) | Done | The subscription's fingerprint under REALITY is not replaced at build |
| 5 | [451](../../../tasks/451-reality-fp-firefox-safari-hybrid.md) | Implemented | `firefox`/`safari` come out from under the warning |
| 6 | [463](../../../tasks/463-contract-w2c-corpus-conformance.md) | Released v2.25.0 | `hellorandom*` no longer goes to `chrome` |
| 7 | [556](../../../tasks/556-registry-debt-1157-1170.md) | Partially done | The REALITY ↔ uTLS pair is a registry rule (`random` → `chrome`) |
