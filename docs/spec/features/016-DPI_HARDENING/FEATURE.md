[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# DPI hardening — TLS fragmentation, mixed-case SNI, uTLS, REALITY, ECH and XHTTP

LxBox hardens TLS-based VPN nodes (VLESS, Trojan, AnyTLS and others) against
deep packet inspection with ClientHello fragmentation and mixed-case SNI. The
same feature normalises what subscriptions carry — uTLS fingerprints, REALITY
keys, ECH, XHTTP transport parameters, VLESS flow and encryption — so that a bad
value degrades one node instead of breaking the whole sing-box config. Server
certificate checks stay under the user's control and are never weakened
silently.

| Field | Value |
|-------|-------|
| Feature | 016-DPI_HARDENING |
| Type | Product feature |
| Absorbed | `§020F` (security & DPI bypass — only the fragmentation part is alive; the Clash API was removed from it together with `clash_api`), `§028F` (mixed-case SNI), `§045F` (ECH — the Draft was not implemented as intended: instead of a per-node toggle — a pass-through `tls.ech` from JSON and refusal of the link's `ech=`), `§127F` (the full set of XHTTP link parameters) |
| State | ✅ written from code, 2026-09-28 |

## Purpose

Defines how a node's ClientHello and transport look on the wire and how the
server is verified. The user enables global techniques with a single checkbox;
everything that came from the subscription (fingerprint, REALITY, XHTTP, `flow`,
the provider's fragmentation) reaches the core in a form the core will accept.

Principles the feature protects:

- **One broken disguise does not bring down the whole VPN.** The core rejects
  an unknown fingerprint, an odd-length `short_id`, a non-X25519 key, an
  invalid XHTTP mode as fatal for the whole config; here such a value is
  dropped or replaced on the node with a warning, the rest works.
- **An anti-DPI technique — only where DPI sees it.** Global techniques are
  applied to the first hop; under `detour` fragmentation is decided by the
  core, and the node's `tls.fragment` is removed so as not to interfere with
  it.
- **Do not silently override the provider's choice.** Fingerprint, `flow`,
  `ech`, `encryption` from the subscription pass as is, are removed with a
  code, or reject the node — there is no silent downgrade of protection.

Out of the box: global techniques are off, delay `500ms`, CA store `system`.

## Promises

- **P1. Global fragmentation — first hop only.** "TLS Fragment" →
  `tls.fragment: true`, "TLS Record Fragment" → `tls.record_fragment: true`
  and `fragment_fallback_delay` on outbounds with TLS enabled and without
  `detour`; nodes with `detour` are not touched. **Witness:** unit
  "tls_fragment=true fragments first-hop TLS only". **Mutation:** remove the
  `detour` check.
- **P2. Fragmentation does not break startup.** naive and MASQUE on `h3` do not
  get the flags; MASQUE on `h2`/auto gets them (with the new `tls{}`).
  **Witness:** units "§270 — tls_fragment skips naive", "h3 is skipped silently
  — no tls block is created", "h2 gets fragment in a nested tls{}".
  **Mutation:** write the flags into any `tls`.
- **P3. `tls.fragment` yields to the build's `detour`.** The node flag (from a
  subscription or JSON) under a `detour` assigned by the build is removed with
  the code `detour_with_tls_fragment` together with the orphaned delay;
  `record_fragment` stays; on an authored JSON body the flag is not removed, the
  code is marked "not applied". **Witness:** units "explicit record_fragment
  under detour stays, fragment removed", "only record_fragment under detour —
  the body is not touched", "with record_fragment the delay stays".
  **Mutation:** not removing the flag — a 500 ms delay per segment and the
  core's default switched off.
- **P4. Xray provider fragmentation is carried over.** `dialerProxy` to
  `freedom` with `fragment` and `finalmask.tcp[type=fragment]` → `tls.fragment:
  true`, if TLS is enabled and there is no hop; Xray parameters are dropped
  without a code. **Witness:** units "TLS + fragment freedom → direct node,
  tls.fragment, no code", "finalmask_tcp_fragment: xhttp + REALITY →
  tls.fragment", "…_no_tls: no flag", "…_with_hop: no flag". **Mutation:** set
  the flag even without TLS.
- **P5. Mixed-case SNI — random case, the same string.** With the checkbox
  on, the `server_name` of each first-hop outbound gets its own random case
  mix, equal to the original case-insensitively; IP literals and `xn--`
  labels do not change; `detour` nodes are not touched. **Witness:** units
  "case-insensitively equal to original", "punycode label preserved",
  "detour outbound NOT touched", "two outbounds get independent
  randomization". **Mutation:** one RNG result for all nodes.
- **P6. Mixed-case SNI does not touch REALITY.** A node with
  `tls.reality.enabled: true` keeps the SNI byte for byte; a neighbour
  without REALITY is randomised. **Witness:** units "reality outbound NOT
  touched", "gate is per-outbound". **Mutation:** remove the gate — the
  REALITY node silently goes to the camouflage site.
- **P7. The uTLS fingerprint is always from the core's dictionary.** Xray
  aliases (`hellochrome_120`, …) and case are canonicalised silently; junk →
  `chrome` with `utls_fp_unknown`; on QUIC `utls`/`reality` are removed.
  **Witness:** units "REALITY + fp=hellochrome_120 → chrome, SILENTLY", "junk →
  chrome + utls_fp_unknown (TLS and REALITY)", "hysteria2 URI with fp → emitted
  config WITHOUT utls". **Mutation:** pass the raw value through.
- **P8. The fingerprint under REALITY is not replaced, but warned about.**
  `edge`/`ios`/`android`/`360`/`qq`/`randomized` go as is with the code
  `reality_fp_not_chrome`; `chrome*`, `firefox`, `safari` — without a code; an
  implicit `random` on vless-REALITY → `chrome` with the code
  `reality_fp_random_pinned`. **Witness:** units "REALITY + fp=edge/…/qq →
  warning on the node", "REALITY + fp=firefox/safari → as is, no warning",
  "vless REALITY without fp and with fp= → chrome with a code". **Mutation:**
  rewrite `edge` to `chrome`.
- **P9. A broken REALITY degrades rather than breaking the config.** An invalid
  `public_key` (not 32 bytes) → the node goes over regular TLS; a `short_id`
  that is odd-length, longer than 16 or not a string → empty; `key_share`
  outside `hybrid`/`classical` → removed. **Witness:** units "REAL-WORLD CASE:
  security=tls + pbk=enabled → plain TLS", "odd-length short_id → cleared, node
  and config alive", "key_share outside the enum — field dropped silently, node
  alive". **Mutation:** truncate `short_id` to 16.
- **P10. ECH from a link is never enabled.** `ech=` → the code `ech_ignored`, no
  `tls.ech`; `echfq` is not read; `tls.ech{}` from sing-box JSON passes as is.
  **Witness:** units "name+resolver → no ech block, a warning is present",
  "sing-box JSON: tls.ech{} reaches the emitted config, the URI branch does
  not", "toUri does not invent ech". **Mutation:** map `ech=` to
  `tls.ech.enabled`.
- **P11. XHTTP: three inputs — one set of fields.** The link, Xray JSON and
  sing-box JSON read the same set of keys (camelCase and snake_case), `extra` is
  merged in, `xmux` as a nested object is equivalent to flat keys. **Witness:**
  units "the three branches read the same set of keys", "extra={"xmux":{…}} is
  equivalent to flat keys", "golden: all 15 camelCase fields → snake_case
  transport". **Mutation:** a new field only in the URI branch.
- **P12. XHTTP: `extra` does not break working flat parameters.** A broken
  `extra` is ignored; an empty value in `extra` does not override the flat one;
  `host`/`path`/`mode` are not read from `extra`. **Witness:** units "a broken
  extra is ignored", "an empty value in extra does not override the flat field
  (§410)", "extra.host/path/mode do not override the flat ones". **Mutation:**
  extra-first for `path`.
- **P13. XHTTP: an invalid mode pair does not reach the core.** Values outside
  the enum (`mode`, placements, `x_padding_method`) are removed with
  `xhttp_param_reset`; header/cookie placement without `mode` → `mode:
  packet-up` with `xhttp_mode_forced_packet_up`; with an explicit other `mode` —
  the placement is removed. **Witness:** units "mode: junk removed +
  xhttp_param_reset", "JSON: header/cookie without mode → mode: packet-up +
  code", "header/cookie + mode=stream-one → placement removed, mode intact".
  **Mutation:** emit the pair as is.
- **P14. VLESS `flow` — only from the link and only without a transport.**
  `flow` is not imposed; `xtls-rprx-vision` with a transport is removed with
  `vision_with_transport`, except on a node with `encryption`; `none`/deprecated
  values are not emitted. **Witness:** units "bare TCP + REALITY, no flow → flow
  is not emitted", "XHTTP + REALITY, flow=vision → flow is dropped", "vision +
  xhttp + encryption → flow stays (§544)". **Mutation:** default `vision` for
  REALITY.
- **P15. VLESS `encryption`: an invalid form rejects the node.** A valid value
  goes verbatim (edges trimmed); empty and exact `none` — no layer; a different
  case `None` and broken grammar → the node does not get into the list, with a
  code. **Witness:** units "an invalid form rejects the NODE instead of removing
  the field", "None in a different case is NOT the off switch". **Mutation:**
  remove the field and keep the node — a silent downgrade of protection.
- **P16. Server verification is not weakened silently.** `insecure` from a link
  is kept but marked with the code `tls_insecure`; hysteria(2) `pinSHA256` →
  `tls.certificate_public_key_sha256`; a custom CA (`tls.certificate`) survives
  editing the node. **Witness:** units "insecure yields a registry code with
  path and value" (anytls), "pinSHA256 reaches the body (it is valid on QUIC)",
  "certificate as a string survives the round trip as a string". **Mutation:**
  lose `pinSHA256` during parsing.
- **P17. The root CA store is chosen by the user.** "Certificate store" →
  `certificate.store`. Manual check: `mozilla` → in the resulting config
  `"certificate": {"store": "mozilla"}`. `no witness` (no unit).

## Controlled parameters

User-facing (settings sections "TLS Fragmentation" and "Certificate store"):

| Setting | Values | Default | Core key |
|---|---|---|---|
| TLS Fragment | on/off | off | `tls.fragment` of first hops |
| TLS Record Fragment | on/off | off | `tls.record_fragment` of first hops |
| Fallback delay | duration string | `500ms` | `tls.fragment_fallback_delay` |
| Mixed-case SNI | on/off | off | `tls.server_name` of first hops without REALITY |
| Certificate store | `system` · `mozilla` · `chrome` | `system` | `certificate.store` |

Node keys (contract with the core): `tls.utls.fingerprint`,
`tls.reality.{public_key,short_id,key_share}`, `tls.ech{}`, `tls.insecure`,
`tls.certificate*`, `transport` `xhttp` (with `xmux{}`), VLESS `flow`,
`packet_encoding`, `encryption`. Link parameters: `fp`, `pbk`, `sid`,
`key_share`, `ech`, `pinSHA256`, `insecure`, `flow`, `encryption`,
`type=xhttp|splithttp` with `extra`.

## Inputs / Outputs

**Inputs:** global checkboxes; node links and JSON; the core version (REALITY
fragmentation and `key_share` — from `v1.14.1-lx.4`).
**Outputs:** `tls`/`transport`/`flow`/`encryption` fields in outbounds; codes
on nodes (`utls_fp_unknown`, `reality_fp_not_chrome`,
`reality_fp_random_pinned`, `reality_short_id_invalid`, `ech_ignored`,
`xhttp_param_reset`, `xhttp_mode_forced_packet_up`,
`vision_with_transport`, `detour_with_tls_fragment`, `tls_insecure`,
`tls_fragment_system_engine`); build warning lines ("Fingerprint
replaced…", "REALITY short_id cleared…", "REALITY removed…").

## Data flow

```
link / Xray / sing-box JSON
   ▼  parsing: fingerprint, REALITY gate, ech= → code, XHTTP + extra, flow/encryption
node model ─► node body (registry sanitiser: enums, relations, prohibitions)
   ▼
build: detour set → detour concessions (tls.fragment removed)
   ▼
global techniques: first-hop fragmentation → mixed-case SNI (except REALITY)
   ▼
safeguards: unknown fingerprint → chrome; broken REALITY → sid empty / block removed
   ▼
core (under detour enables record_fragment itself if there are no flags)
```

## Rules and guarantees

- "First hop" = an outbound without the `detour` key at the time of the
  global step. Positions of a `type: chain` chain are separate outbounds
  without `detour`; removing techniques from chain links is done by the core
  (`strip_evasion`,
  [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md)).
- The SNI case mix is fixed per config build: a new one on every rebuild, not
  on every handshake.
- `tls.fragment` and `tls.record_fragment` together with a system TLS engine
  (`tls.engine` = `apple`/`windows`) are removed with the code
  `tls_fragment_system_engine` — on Android such an engine is not set.
- `tls.ech.enabled` and `tls.reality.enabled` are mutually exclusive
  (`field_conflict`); ECH on MASQUE is removed.
- An empty `short_id` is legitimate; an empty `fingerprint` under REALITY from
  JSON stays empty (core = `chrome`).
- The validity of values is judged by the contract registry: at every parsing
  input and once more before the core.

## Boundaries

- Parsing links and formats in general, parsing codes —
  [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md); here only the TLS and
  transport fields that protect or disguise the connection.
- The order of build steps, the template, variables in general —
  [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md).
- Chains, `strip_evasion`, detour —
  [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md).
- AmneziaWG/WARP obfuscation (junk, I1–I5, header protection) —
  [015-WARP](../015-WARP/FEATURE.md); that is a different layer, not TLS.
- Editing individual TLS fields of a node by hand —
  [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md).
- Not done: SNI rotation on every handshake, ClientHello padding,
  domain fronting, ECH from a link (`ech=`/`echfq`), a per-node ECH toggle,
  ECH auto-fallback, Xray fragmentation parameters (`length`, `delay`,
  `maxSplit`), XHTTP `downloadSettings`, "detour with no fragmentation at
  all" (the core enables `record_fragment` itself).
- Dropped from the plan (§020F): encrypted storage of secrets, app pinning,
  masking links in the UI and logs.
- Not planned (owner decision 2026-09-29, audit [588](../../tasks/588-spec-kit-revision-audit.md)): ECH as designed in `§045F` — a
  per-node ECH checkbox and the `?ech=` link parameter. ECH reaches the core
  only from the node JSON and Xray `echConfigList` ([ECH](FUNCTIONS/ech.md)).
- Certificate verification is performed by the core; the `system` store
  depends on OS capabilities (outdated on old Android versions).

## Functions

| Function | What it does | Promises | File |
|---|---|---|---|
| TLS fragmentation | Splits the ClientHello so DPI cannot read the SNI: global checkboxes for the first hop, skipping incompatible nodes, yielding to `detour`, carrying over Xray fragmentation. | P1 P2 P3 P4 | [tls-fragmentation.md](FUNCTIONS/tls-fragmentation.md) |
| Mixed-case SNI | Randomises the letter case of `server_name` against exact-match DPI and skips REALITY nodes. | P5 P6 | [mixed-case-sni.md](FUNCTIONS/mixed-case-sni.md) |
| uTLS fingerprint | Keeps the ClientHello fingerprint inside the core's dictionary: defaults, canonicalisation, junk → `chrome`, QUIC, hybrid key share. | P7 P8 | [utls-fingerprint.md](FUNCTIONS/utls-fingerprint.md) |
| REALITY parameters | Validates `public_key`, `short_id` and `key_share` so that a broken REALITY block degrades one node instead of the config. | P9 | [reality-params.md](FUNCTIONS/reality-params.md) |
| ECH | Passes `tls.ech` through from node JSON only and drops the link's `ech=` with an explanation. | P10 | [ech.md](FUNCTIONS/ech.md) |
| XHTTP parameters | Carries the full XHTTP transport from a subscription to the core: all fields, `extra`, `xmux`, enum gate, mode/placement pair. | P11 P12 P13 | [xhttp-params.md](FUNCTIONS/xhttp-params.md) |
| VLESS flow and encryption | Keeps XTLS Vision and VLESS Encryption exactly as the provider set them: Vision from the link, conflict with a transport, `encryption` grammar. | P14 P15 | [vless-flow-encryption.md](FUNCTIONS/vless-flow-encryption.md) |
| Server certificate verification | Keeps TLS server verification as strict as the subscription promised: CA store, `insecure`, key pin, custom CA. | P16 P17 | [server-certificate.md](FUNCTIONS/server-certificate.md) |

## Related features

- [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md) — filtering nodes by
  `tls.utls.fingerprint`.
- [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md) — parses links and formats as
  a whole, including `packet_encoding`; here only the TLS and transport fields.
- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — the order of build steps
  into which the global techniques are embedded; core settings and their backup
  portability.
- [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) — chains,
  detour and `strip_evasion` that decide what counts as the first hop.
- [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md) — manual editing of a node's
  TLS fields and fingerprint via its JSON.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — the local proxy of Proxy
  mode and its authorisation.
- [015-WARP](../015-WARP/FEATURE.md) — AmneziaWG/WARP obfuscation and QUIC
  Initial fragmentation, a separate non-TLS layer.

## Maintenance notes

- REALITY matches the SNI as an exact string: any "harmless" edit of a
  REALITY node's `server_name` results in a silent diversion to the
  camouflage site.
- The core's fingerprint dictionary and the "with hybrid key share" set are
  mirrored in the app; the hybrid set (`firefox`, `safari`) is correct only
  for core `v1.14.1-lx.3` and newer — if the pin is rolled back it must be
  narrowed.
- `tls.fragment` under `detour` does not break the connection but slows it
  down (500 ms per segment) and turns off the core's protective default — the
  symptom is "slow through a chain", not "does not work".
