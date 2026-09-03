# Guards — the sanitiser registry

Every place where LxBox **drops, normalises, defaults, degrades or rejects**
a value so that the sing-box core does not fail, panic, or go silently dead.

This file is the single registry. It was written by walking the code, not from
memory; each row carries `file:line` so a reader can check the claim. Where the
purpose of a guard could not be established from the code, the row says so
instead of guessing.

Related: [`PROTOCOLS.md`](PROTOCOLS.md) (what each protocol's fields mean),
[`ARCHITECTURE.md`](ARCHITECTURE.md) (where the parser and builder sit in the
pipeline), [`spec/features/026 parser v2/spec.md`](spec/features/026%20parser%20v2/spec.md)
(the parser's original design).

## Why this exists

sing-box validates a config **as a whole**. A single unusable field in a single
node of a single subscription is frequently not a per-node failure but a fatal
one for the entire file:

```
initialize outbound[3]: create client transport: xhttp: v2ray-xhttp:
uplink_data_placement can be header only in packet-up mode
```

The user experience of that is "the VPN does not start", with no indication
which of their several hundred subscription nodes is at fault — or that a node
is at fault at all. Guards exist so that provider data cannot take the whole
config down.

## Contents

- [Principles](#principles)
- [Where guards live](#where-guards-live)
- [How a user finds out](#how-a-user-finds-out)
- [Layer 1 — URI parsing](#layer-1--uri-parsing)
- [Layer 2 — JSON branches](#layer-2--json-branches)
- [Layer 3 — node emission](#layer-3--node-emission)
- [Layer 4 — config assembly](#layer-4--config-assembly)
- [Known asymmetries and gaps](#known-asymmetries-and-gaps)

## Principles

**1. Drop, do not silently fit (§169).** When a value is unusable, discard it.
Do not trim, pad or coerce it into a shape the core will accept — that produces
a *valid config with the wrong meaning*, which is worse than a rejected one.
A REALITY `short_id` truncated to an even length is a valid short id belonging
to somebody else; the server compares it byte for byte and the node dies
quietly. Dropping it leaves an empty short id, which is legal.

**2. Fail closed against a whole-config fatal.** The unit of damage decides the
response. If the core rejects one outbound, passthrough is fine — let the core
judge it. If the core rejects the entire file, the app must intervene, because
one node from a provider would otherwise cost the user every node.
`XhttpTransport` shows both policies side by side: `session_placement` and
`uplink_http_method` pass through untouched (the core's problem), while
`uplink_data_placement: header` is guarded (§416 — the whole config's problem).

**3. Changed behaviour must be visible.** If a guard alters what the source
asked for, the user gets a warning. The anti-pattern (§277/§278) is a guard
that only fires on a code path nobody watches. Two deliberate exceptions:
canonicalising a synonym is not a degradation (uTLS xray aliases, §281), and
neither is a value whose absence and whose "none" mean the same thing
(`packetEncoding=none`).

**4. Never quietly widen the user's exposure.** A guard may not replace a
declared relay with a direct connection. §404 rejects an Xray node whose
`dialerProxy` is unusable *in full*, rather than emit it with a direct path:
the provider wrapped the dial in a relay on purpose, and quietly unwrapping it
routes traffic where the user did not agree to send it. The mirror case in the
sing-box branch (§368) drops only the chain, because there `detour` is optional
decoration rather than the point of the node.

**5. Degrade one element, do not fail the build.** A broken rule, member or
node is dropped so the rest of the config survives. The exception is DNS groups
(§312): an emptied group blocks the build with a fatal issue rather than
degrade, deliberately, so the user resolves it instead of silently losing
resolution.

**6. Fail open only when guessing is worse.** Two documented cases: an
unparsable core version is treated as *supporting* chains (§393 C5 — degrading
on a guess costs the user a working route, and a config the core rejects at
least produces a visible error), and a node pulled out of a group keeps its
`detour` (§393 A4 rule 4).

## Where guards live

Four layers, in pipeline order. A guard belongs at the **narrowest point every
source branch must pass through**. Putting the §416 check in the URI parser
would have missed sing-box JSON, Xray JSON and the manual editor; putting it in
`XhttpTransport.toSingbox` catches all four, because every branch builds that
object before emitting.

| Layer | Code | What it guards |
|---|---|---|
| 1 — URI parsing | `app/lib/services/parser/uri_parsers/**`, `uri_utils.dart`, `transport.dart`, `utls_fingerprint.dart`, `hysteria2_obfs.dart`, `ini_parser.dart`, `amnezia_link.dart`, `body_decoder.dart` | One link from a subscription body |
| 2 — JSON branches | `app/lib/services/parser/singbox_config.dart`, `json_parsers.dart` | Imported sing-box and Xray configs |
| 3 — node emission | `app/lib/models/transport_spec.dart`, `tls_spec.dart`, `node_spec_emit.dart`, `node_spec.dart` | The node → outbound JSON step, common to all sources |
| 4 — config assembly | `app/lib/services/builder/**`, incl. `post_steps/**` and `validator.dart` | The whole file: graph, groups, rules, DNS |

## How a user finds out

Three channels, and they are not interchangeable.

| Channel | Type | Surface | Notes |
|---|---|---|---|
| `NodeWarning` | sealed subclass, `models/node_warning.dart` | Inline line under the node in the subscription screen, coloured by `severity` (`node_warning_row.dart:19-22`) | Deduped by type + data, not by rendered text (§279). Reaches `emitWarnings` as `'<tag>: <renderEn()>'` (`build_config.dart:282-285`) |
| `emitWarnings` | `List<String>`, EN text, `BuildResult` | SnackBar (§105) + AppLog | Builder-layer channel. Free text, mostly without machine codes — the chain degradations are the exception (`chain_unsupported_by_core`, `chain_invalid`, `chain_hop_missing`, `chain_nested_position`, `chain_cycle_through_direction`) |
| `ValidationIssue` | sealed, `models/validation.dart`, all `Severity.fatal` | Blocks the build: `FatalValidationException`, config is neither saved nor sent to the core (§141 P0.1) | Last line of defence, not the first — the graph sanitiser unties what it can *before* this |

`NodeWarning` subclasses also carry machine codes for the shared contract
(`app/contract/registry/warnings.json`), mapped by runtime type in
`test/contract/contract_test.dart:87`.

## Layer 1 — URI parsing

### 1.1 Shared helpers (`uri_utils.dart`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| URI longer than 65536 (except `vpn://`) | node rejected | silent | `uri_utils.dart:8`, applied `uri_parsers.dart:45` | base64 bomb guard | — |
| `vpn://` longer than 524288 | rejected (`DecodeFailure`) | silent | `uri_utils.dart:24`, `amnezia_link.dart:24` | under the common cap such a link was silently lost while desktop accepted it | §103 §9.B12 |
| WG key (private/public/psk) not exactly 32 bytes after lenient base64 | **node rejected** | silent | `uri_utils.dart:127-131` | garbage like Proton's `*****` or `publickey=enabled` otherwise reaches `sing-box check` and fails the whole file | D-023/D-030 |
| Key in a non-canonical base64 form (`…ccC=` vs `…ccA=`) | normalised to canonical std-base64 | silent | `uri_utils.dart:130` | same 32 bytes, different text → two identity hashes for one node | D-030 |
| Dart's strict base64 rejects non-canonical padding bits | manual lenient decoder instead of `dart:convert` | silent | `uri_utils.dart:79-114` | matching core behaviour instead of over-rejecting valid keys | D-030 |
| `reserved` not 3 parts / outside 0..255 / not 3 bytes | value dropped | silent | `uri_utils.dart:138-156` | degrade to "no reserved" | §025 |
| Control characters in display strings | stripped (`<0x1F`, `0x7F`, keeping `\t\n\r`) | silent | `uri_utils.dart:164-175` | display sanitation | — |
| Trailing CRLF in the fragment (chat copy-paste) | sanitise, then trim edges only | silent | `uri_utils.dart:193-200` | mirrors Go's label pipeline | §103 |
| `packetEncoding` empty or `none` | field dropped, **no warning** | silent (deliberate) | `uri_utils.dart:259` | xray subscriptions write `none` meaning "unset"; semantically identical to omitted | — |
| `packetEncoding` outside `{xudp, packetaddr}` | field dropped | `PacketEncodingUnknownWarning` | `uri_utils.dart:253-266` | unknown value **panics** the core in `format.ToString` — a native `libbox.so` crash, not a failed connection | SPEC 103 |
| `packetEncoding` upper-case | lower-cased | silent | `uri_utils.dart:258` | core accepts lowercase only | — |
| AWG `mtu` above 1280 | clamped to 1280 | silent (AppLog only) | `uri_utils.dart:277-282` | too high is a silent failure: handshake succeeds, data does not flow | §097 |
| AWG `mtu` absent | default 1280 | silent | `uri_utils.dart:278` | AmneziaWG's own recommended client MTU and the IPv6 minimum | §097 |
| Bare IP without CIDR in `address` / `allowed_ips` | `/32` or `/128` appended | silent | `uri_utils.dart:288-292` | breaks endpoint load: `netip.ParsePrefix(...): no '/'` | §106 |
| Raw `/` inside a base64 key in userInfo | percent-encoded to `%2F`, userInfo only | silent | `uri_utils.dart:298-309` | `Uri.tryParse` would read it as the start of the path and lose the userInfo | §106 |
| REALITY `pbk` not 32-byte X25519 | REALITY block not created, node degrades to plain TLS | silent | `uri_utils.dart:335-340`, applied `transport.dart:472` | a non-X25519 key makes the core reject the **entire** config.json | §169 |
| REALITY `sid` non-hex / odd length / over 16 | value dropped entirely (`''`), case folded | `RealityShortIdInvalidWarning` (info) | `uri_utils.dart:352-365` | decoded as hex into `[8]byte`; any of these is a whole-config fatal. Trimming would yield a valid id belonging to someone else | §343/§169 |
| `sid` normalisation differs from `lower(trim(raw))` | detection only — predicate runs **before** normalisation | `RealityShortIdInvalidWarning` | `uri_utils.dart:373-376`, added `transport.dart:476` | after normalising, the original value is gone | SPEC 103 |
| Duration given as a bare number (`"30"`) | `s` suffix appended | silent | `uri_utils.dart:385-389` | `badoption.Duration` rejects it with `time: missing unit in duration` and drops the whole config | D-024 |
| VMess `security` empty / `null` / `undefined` | default `auto` | silent | `uri_utils.dart:394` | — | — |
| VMess `security` outside the 6-value whitelist | replaced with `auto` | silent | `uri_utils.dart:396-407` | normalise to the sing-box vocabulary | — |
| Shadowsocks method outside the 9-value whitelist | **node rejected** | silent | `uri_utils.dart:411-424` | core will not accept an unknown method | — |
| `insecure` in 5 spellings | normalised to bool | (produces `InsecureTlsWarning`) | `uri_utils.dart:220-232` | — | — |
| Label contains `🇪🇳` | replaced with `🇬🇧` | silent | `uri_utils.dart:181` | **purpose unclear** — the comment says "leftover artefact from v1" and does not name a core error or observable behaviour | — |

### 1.2 uTLS fingerprint (`utls_fingerprint.dart`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| `fp` outside `kUtlsFingerprints` (15 values) and not an xray alias | replaced with `chrome` | `UnknownFingerprintWarning` | `utls_fingerprint.dart:63`, added `:79` | the core matches fingerprints strictly and case-sensitively; an unknown one is a whole-config fatal at start. One bad node takes the VPN down | §281 |
| `fp` is a known xray alias (`hellochrome_120`, …), 9 prefixes | canonicalised **silently** | silent (deliberate) | `utls_fingerprint.dart:41-51, 60-62` | a synonym is not a degradation (principle 3) | §281 |
| `fp` in any case / with spaces | `trim().toLowerCase()` | silent | `utls_fingerprint.dart:57` | Xray accepts any case | §281 |
| `fp` empty while `reality != null` | default `chrome` | silent | `utls_fingerprint.dart:78` | REALITY requires a uTLS block ("uTLS is required by reality client" — fatal on outbound creation), and an empty fingerprint emits no block | §281 |

### 1.3 Hysteria2 obfuscation (`hysteria2_obfs.dart`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| obfs type outside `{salamander, gecko}` | obfs dropped whole (type and password) | `UnknownObfsWarning` | `hysteria2_obfs.dart:38-41` | `Hysteria2Obfs.MarshalJSON` returns "unknown obfs type" — the config will not assemble at all | §358 |
| Valid type, empty password | obfs dropped whole | `MissingObfsPasswordWarning` | `hysteria2_obfs.dart:42-45` | "missing obfs password" is fatal on outbound creation | §358 |
| Type in another case / with spaces | `trim().toLowerCase()` | silent | `hysteria2_obfs.dart:36` | — | §358 |

### 1.4 Transport and TLS from the query (`transport.dart`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| Xray tail `?ed=N` in a ws path | tail cut, `ed` moved to `max_early_data` | `WsEarlyDataConvertedWarning` (info) | `transport.dart:47, 73-75` | left in place the core sends the tail to the server as part of the path and gets a 404 — and `sing-box check` passes | §303 |
| `?ed=N` on httpupgrade | tail cut, `ed` **discarded** | silent | `transport.dart:109-117` | httpupgrade has no early data; leaving the tail gives a 404 | §303/§320 |
| `?ed=` on xhttp | tail cut, value discarded | silent | `transport.dart:216-226` | xhttp has no early data | §303 |
| Broken percent-encoding in the tail (`splitQueryString` throws) | exception swallowed → "no ed"; path still cleaned | silent | `transport.dart:152-159` | the path must be cleaned regardless | §303 |
| `eh` without `ed` | `eh` dropped | silent | `transport.dart:56` | the core enables early data on `max_early_data > 0`; a header name without a size means nothing | §320 |
| Doubly percent-encoded path (`/%2Fassignment`) | extra decode, **capped at 2 passes** | silent | `transport.dart:172-182` | `Uri.queryParameters` decodes once, so the server receives the wrong path and 404s. More than two passes is almost certainly garbage | §320 |
| ALPN multiply percent-encoded | unwound to a fixed point, **capped at 16 passes** | silent | `transport.dart:586-607` | leftover `%XX` went into `tls.alpn` verbatim; the cap guards against pathological input | §151 F2 |
| ALPN element still contains `%` / space / control after unwinding | element dropped from the list | silent | `transport.dart:603` | not a valid protocol id | §151 F2 |
| `ech=<name>+<resolver>` present and not `none` | **not applied at all** | `EchIgnoredWarning` (info) | `transport.dart:443-447` | subscriptions put public ECH probes there (`ip.gs`), whose keys do not belong to this server — the handshake breaks and the core has no fallback. Device-verified: with `ech` dead, without it 723 ms | §320 |
| `echfq` | never read | silent | `transport.dart:441-442` | the paired core option is legacy, removed in sing-box 1.13.0, and drops the config when true | §320 |
| XHTTP `extra` broken / not an object | ignored whole; node lives on flat params | silent | `transport.dart:355-365` | — | §399 |
| `extra` contains `host` / `path` / `mode` | values from `extra` **discarded**; only flat params read | silent | `transport.dart:319, 370-371` | device-verified: `extra.path = "/"` made the server answer 404 on uplink while the flat `/hls/…` worked. Deliberate divergence from the Go reference | §410 |
| `extra` holds an empty string for a key | empty does **not** override the flat value | silent | `transport.dart:383, 389-391` | otherwise `mode` disappears, the core defaults to `auto`, and a node with `uplinkDataPlacement=header` drops the whole config | §410 |
| `extra` holds an array or nested object (except `xmux`) | discarded | silent | `transport.dart:302-313` | — | §399 |
| Number like `1000000.0` in an XHTTP scalar | normalised to `"1000000"` | silent | `transport.dart:401-407` | the core cannot parse exponential notation | §399 |
| XHTTP int field non-numeric or absent | `-1` ("unset"), key not emitted | silent | `transport.dart:279-287` | zero is a meaningful value for these fields, not emptiness | §127 |
| `type=h2` in a VLESS/Trojan query | transport not created | silent | `transport.dart:100` | Go does not recognise bare `type=h2` there either | SPEC 103 |
| Unknown `type` | transport not created, node survives | silent | `transport.dart:129-135` | — | — |
| httpupgrade / xhttp `host` empty | **no fallback to sni** (unlike ws) | silent | `transport.dart:118-121, 228-231` | the fallback produced different configs and identity hashes for an empty host | §103 D-016 |
| No `path` key at all (ws/httpupgrade/xhttp) | path stays `''`, `/` **not** substituted | silent | `transport.dart:45-48, 114-117, 224-226` | only an explicit `path=` reaches the config | SPEC 103 CANON §2.4 |
| VLESS `sec` empty and port in `{80, 8080, 8880, 2052, …}` | TLS disabled by port whitelist | silent | `transport.dart:502`, list `uri_utils.dart:427` | ports that normally carry plain HTTP | — |

### 1.5 Per-protocol URI parsers

Rejection of a node for a missing host, empty userinfo, empty password or
unparsable key is the common case across `vless_parser.dart:13`,
`trojan_parser.dart:12,17`, `ssh_parser.dart:10,17`, `socks_parser.dart:10`,
`tuic_parser.dart:12-18`, `anytls_parser.dart:16,22`,
`shadowsocks_parser.dart:29-49`, `masque_parser.dart:25-47`,
`wireguard_parser.dart:12-36`, `ini_parser.dart:82` — all silent. Port defaults
(443 / 1080 / 22 / 8388 / 51820) likewise. The rows below are the guards that do
something more than reject or default.

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| VLESS `flow=xtls-rprx-vision` with any transport | flow suppressed (`''`) | `VisionWithTransportWarning` (info) | `vless_parser.dart:41-44` | vision is valid only on bare TLS; with ws/grpc/xhttp the core will not bring the config up. The link is the source of truth — not guessed from REALITY | §115 |
| VLESS `flow=xtls-rprx-vision-udp443` | replaced with `xtls-rprx-vision` + `packetEncoding=xudp` | silent | `vless_parser.dart:32-35` | v1 quirk | — |
| VLESS `encryption` (post-quantum) | taken verbatim, **deliberately not validated** | silent | `vless_parser.dart:55-59` | base64url up to ~1600 chars; any corruption the core rejects itself | §335 |
| VMess body not base64 / empty / no `add` or `id` | node rejected | silent | `vmess_parser.dart:23-43` | — | — |
| VMess malformed UTF-8 | `utf8Lossy` (`allowMalformed`) | silent | `vmess_parser.dart:25` | — | — |
| SSH empty elements in `host_key` / `host_key_algorithms` | dropped from the list | silent | `ssh_parser.dart:25-38` | — | — |
| Bare `http(s)://` as a proxy link | only the custom schemes `proxy-http(s)` / `proxy+http(s)` accepted | silent | `http_parser.dart:13-16` | plain URLs are caught earlier as subscriptions; promo links inside bodies would otherwise become "nodes" | §222/§268 |
| Hysteria2 multi-port authority (`host:443,20000-30000`) | authority rebuilt on the first numeric port, rest → `server_ports` | silent | `hysteria2_parser.dart:48-56, 179-235` | Dart's `Uri.parse` cannot digest `,`/`-` in the port position | §103 §9.B2 |
| Hysteria2 first port outside 1..65535 | rebuild abandoned → node rejected | silent | `hysteria2_parser.dart:270-286` | — | §103 §9.B2 |
| Hysteria2 empty password | node **survives**, password simply not emitted | silent (deliberate) | `hysteria2_parser.dart:59-63` | Go requires non-empty userinfo only for vless/trojan/ssh/tuic/anytls | §103 |
| Hysteria2 `sni` empty, `== '🔒'`, or without `.` and `:` | replaced with the server | silent | `hysteria2_parser.dart:82-85` | "this is not a domain name" heuristic. The `'🔒'` literal is **unexplained in the code** — purpose unclear | — |
| Hysteria2 `up_mbps` / `down_mbps` in the URI | **deliberately not read** | silent | `hysteria2_parser.dart:122-131` | JSON-only fields; reading them here would mean understanding a URI Go does not | §084 H3 |
| TUIC `congestion_control` outside `{bbr, cubic, new_reno}` | field cleared, core default applies | `TuicCongestionInvalidWarning` | `tuic_parser.dart:59-61` | a broken value must not smuggle a pseudo-explicit `cubic` into the config | SPEC 103 |
| TUIC `congestion_control` empty | cleared **without** warning | silent (deliberate) | `tuic_parser.dart:59` | "unset" is not a degradation | SPEC 103 |
| TUIC `alpn` absent | empty list; `h3` **not** substituted | silent | `tuic_parser.dart:41-46` | `h3` is a protocol default, not our value; substituting changes the identity hash | §103 D-016 |
| AnyTLS `security` in the query | removed before TLS parsing | silent | `anytls_parser.dart:31-34` | AnyTLS is always over TLS; `security=none` would zero the whole TLS block | §269 |
| AnyTLS `min_idle_session` not a non-negative integer | field cleared | `AnyTlsMinIdleInvalidWarning` | `anytls_parser.dart:44-48` | core default applies, node lives | SPEC 103 |
| AnyTLS / TUIC durations as bare numbers | `s` suffix appended | silent | `anytls_parser.dart:62-64`, `tuic_parser.dart:66-69` | whole-config fatal otherwise | D-024 |
| Naive `padding` parameter | discarded | `NaivePaddingIgnoredWarning` (info) | `naive_parser.dart:55-60` | no sing-box equivalent; previously log-only, so the user never learned their parameter was dropped | SPEC 103 |
| Naive TLS block | trimmed to `enabled` + `server_name` | silent | `naive_parser.dart:72-74` | naive accepts nothing else in TLS; the validator rejects alpn/utls/insecure/reality | §281 |
| Naive extra-header without `:` / empty name / name outside the charset | line discarded | silent | `naive_parser.dart:94-115` | HTTP header-name charset from the DuckSoft de-facto spec | §084 M7 |
| Naive empty host | node **not** rejected (deliberate) | silent | `naive_parser.dart:20-27` | Go validates a non-empty hostname only for five schemes, naive not among them | §103 |
| MASQUE `vhttp` outside `{h3, h2, auto}` | forced to `h3` | `MasqueVhttpInvalidWarning` | `masque_parser.dart:60-67` | mirrors `node_parser_masque.go` | SPEC 103 |
| MASQUE `vhttp` absent | default `h3`, **no warning** | silent | `masque_parser.dart:53-54` | "no parameter" and "operator chose auto" are different things | contract 0.11.1 |
| MASQUE legacy `network` / `server_name` | not accepted at all | silent | `masque_parser.dart:15-18, 50-52` | operator directive D-078 | §393 |
| AWG `h1`–`h4` not uint32 and not a `lo-hi` range | field cleared | `AwgHeaderInvalidWarning` | `wireguard_parser.dart:95-105`, collected `node_spec.dart:713-720` | the core falls back to the plain WG header and the handshake stops matching the server — a **silently broken** node, hence warning not info | SPEC 103 |
| AWG `jc`/`jmin`/`jmax`/`s1`–`s4` broken | field cleared **silently** | silent (deliberate) | `node_spec.dart:700-704, 722-723` | Go drops these silently too: a quiet default there does not break the handshake, whereas for headers it does | SPEC 103 |
| AWG header range reversed (`300-200`) | normalised to `200-300` | silent | `node_spec.dart:685-693` | the same pair, not another value; without this one node yields two hashes | D-031 |
| AWG `id`/`ip`/`ib` alongside an explicit `i1` | `id`/`ip`/`ib` suppressed | silent | `node_spec.dart:729-736` | the core rejects them together with an explicit `i1` | §143 |
| Deeper AWG validation (uint32 bounds, start ≤ end, non-overlap) | **deliberately not validated** | — | `node_spec.dart:675-678` | the core gives an explicit start error, while a silent drop here is a silently broken handshake — the original §112 bug | §112 |
| Plain WG (no AWG) without an explicit `mtu` | `mtu` **not emitted at all** | silent | `wireguard_parser.dart:89-98` | the core sets 1408 itself; our own default fights it and breaks the identity hash | SPEC 103 D-026 |
| WG `preshared_key` (underscored) | alias **not** accepted; only `presharedkey` | silent | `wireguard_parser.dart:54-58` | the only spelling Go reads — unlike `private_key`, which Go added deliberately | D-021 |
| INI bare IPv6 endpoint without brackets | whole endpoint becomes the host, port 51820 | silent | `ini_parser.dart:98-105` | the port is genuinely indistinguishable from the address here — a deliberate degradation | §219 |
| Amnezia claimed uncompressed size over 4 MiB | inflate not performed | silent | `amnezia_link.dart:143-152` | decompression-bomb cap | §110 |
| Amnezia container not awg/wireguard | skipped | silent | `amnezia_link.dart:17-18, 41-45` | — | §110 |
| `vpn://` as a single URI with N containers | exactly **one** node (`defaultContainer`, else the first); rest dropped | silent | `amnezia_link.dart:58-104` | mirrors Go | §103 §9.B12 |
| Unknown scheme, or any exception inside a protocol parser | `null`, line skipped | silent | `uri_parsers.dart:89-94` | structural errors return null rather than throw | — |
| Base64 body: over 20% control bytes, under 16 chars, or no `://`/`{`/`[` after decoding | decode refused or rolled back | silent | `body_decoder.dart:96, 144-169` | probably binary | — |
| Lines starting with `#`, `//`, `;` | skipped (counted in `skippedComments`) | silent | `body_decoder.dart:131-135` | — | §219 |

## Layer 2 — JSON branches

### 2.1 sing-box import (`singbox_config.dart`, `parseSingboxEntry`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| `type` in `{direct, block, dns}` | service outbound — never becomes a node | silent | `singbox_config.dart:35, 172` | `block`/`dns` were removed in 1.11 but still appear in configs | §368 §3.1 |
| Tag is the target of someone's `detour` | withdrawn from candidates, travels as the owner's hop | silent | `singbox_config.dart:155-162, 178` | — | §368 §4 P1 |
| Tag takes part in a detour **cycle** | edge cut, target **returned** to candidates | owner gets the warning below | `singbox_config.dart:146-162, 313-344` | otherwise the node would land in `detourTargets` and vanish from the list entirely — the silent loss §3.5 exists to prevent | §368 §4 P3 |
| Duplicate tag | first wins; indexed fallback `tag N` for the name | silent | `singbox_config.dart:141-144, 185-189` | the file is written by the provider, and repeats between elements are normal | §368 §3.3 |
| Converter returned `null` (unsupported type) | node skipped, type accumulated | `UnsupportedProtocolWarning` on the config's first node | `singbox_config.dart:205-209` | a config that produced no node at all is lost silently — compensated by the "skipped" counter in the import dialog | §368 §3.5 |
| Detour depth ≥ 8 (`kMaxDetourDepth`) | chain truncated, node lives | `DetourChainTooDeepWarning(8)` | `singbox_config.dart:366-370` | real configs are 2–3 hops; the limit guards against recursion driven by provider data | §368 §4 P2 |
| `detour` closes a cycle | edge broken, node connects directly | `DetourCycleBrokenWarning` | `singbox_config.dart:374-377` | broken rather than fatal (unlike §254) because the cycle arrived in someone else's file — the user did not create it | §368 §4 P3 |
| `detour` target not in the config | chain not built, node lives | `DetourTargetMissingWarning` | `singbox_config.dart:381-384` | drop the unusable part, not the whole (§169) | §368 §4 P4 |
| `detour` points at a group | chain not built | `DetourToGroupWarning` | `singbox_config.dart:388-392` | `getEntries` expands the group into a detour list its members are absent from | §368 §4 P5 |
| `detour: "direct"` | chain not built — **silently** | silent (deliberate) | `singbox_config.dart:393-397` | a common way of saying "go direct"; not an error and not a hop, since a direct exit is not a node here | §368 §4 |
| Exception (TypeError on a garbage field type) inside a converter | node skipped, neighbours survive | `UnsupportedProtocolWarning('malformed')` | `singbox_config.dart:245-251` | "broken forms do not sink the whole parse" at node granularity | §321/§368 |
| Any config field of the wrong type | `is` checks, never casts | silent | `singbox_config.dart:118-127, 158-159` | a cast would sink the parse of the whole subscription | §368 §3.1 |
| `type: selector` (manual choice) | imported as auto-select (`urltest`) | `SelectorAsAutoWarning` (info) | `singbox_config.dart:434` | we have no manual type, and losing a hand-built roster is worse than changing selection mode | §368 §5.1 |
| Group member unresolvable (nested group / service / broken) | member dropped | `GroupMemberMissingWarning(count)` | `singbox_config.dart:450-459` | a group cannot be a pool member | §368 §5.3 |
| Group empty after filtering | group **not created at all** | silent | `singbox_config.dart:460` | an empty `urltest` kills core startup | §368 §5 |
| Sorting more than 32 elements | index added to the comparator | silent | `singbox_config.dart:68-74` | Dart's `List.sort` is stable only up to ~32 | §342 |
| Empty `server` or `server_port == 0` (all protocols) | node rejected | silent | `json_parsers.dart:994, 1013, 1028, …` | — | — |
| Empty `tag` | synthetic `<type>-<server>-<port>` | silent | `json_parsers.dart:998, 1016, …` | LxBox has no nameless nodes — they need identity to be disabled individually | contract 0.10.0 |
| AnyTLS with no/disabled TLS block | minimal `enabled` block substituted | silent | `json_parsers.dart:1042-1047` | AnyTLS is always over TLS | §269 |
| `up_mbps: 100.0` (double, not int) | read as `num` | silent | `json_parsers.dart:1102-1107` | `as int` would sink the whole node via TypeError | §404 |
| `server_ports` mixed array `[443, "20000:30000"]` | element-wise `toString()`, empties dropped | silent | `json_parsers.dart:498-507` | `cast<String>()` throws on read and the node would be lost, though the range parses fine | §404 |
| naive full TLS block in JSON | trimmed to `enabled` + `server_name` | silent | `json_parsers.dart:1134-1137` | the rest is fatal on outbound creation | §281 |
| WG private/public/psk not 32 bytes | node rejected | silent | `json_parsers.dart:1254-1268` | garbage sinks `sing-box check` entirely; a non-canonical form changes the identity hash | D-023/D-030 |
| WG `reserved` not a 3-element array in 0..255 | `null` — degrade to "no reserved" | silent | `json_parsers.dart:1349-1358` | do not lose the node | §219 |
| WG AWG with `mtu` over 1280 | clamped | silent | `json_parsers.dart:1290` | mirrors the URI parser so the model does not depend on the source | §097 |
| MASQUE flat legacy `network`/`sni`/`skip_cert_verify` | never read | silent | `json_parsers.dart:1307-1313` | a flat `sni` beside `tls.server_name` made the core fail fast | §393 |
| `reality.enabled != true` or invalid `public_key` | `reality = null`, node stays plain TLS | silent | `json_parsers.dart:1385-1395` | do not poison config.json | §169 |
| `reality.short_id` non-hex / odd / over 16 | dropped (`''`) | silent | `json_parsers.dart:1392-1394` | as in the URI branch | §343 |
| ws/httpupgrade `path` key absent | path `''`, no `/` default | silent | `json_parsers.dart:1412-1416` | canonical sing-box JSON does not write the default either | §103 D-016 |
| Glued Xray path `/x?ed=N` in ws JSON | tail cut | silent (no warnings channel here) | `json_parsers.dart:1413-1415` | glued Xray paths reach the editor too | §303 |
| JSON flavour unrecognised, or `clashYaml` | 0 nodes | silent | `body_decoder.dart:181-209`, `parse_all.dart:191-193` | the `xrayArray` branch works, and its classification must not shift on ambiguous input | §368 §7.1 |

### 2.2 Xray import (`parseXrayElement`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| `protocol` in `{freedom, blackhole, dns, loopback}` | service outbound — never a node | silent | `json_parsers.dart:572, 63-68` | not servers | §321 |
| Tag is a `sockopt.dialerProxy` target | withdrawn from standalone nodes | silent | `json_parsers.dart:130-133` | a relay is not a subscription node of its own; it lives as the owner's hop | §310 |
| Tag is a target but inside a **cycle** | returned to candidates | owner gets `DialerProxyUnusableWarning` | `json_parsers.dart:104-133` | filtering it here would lose the node **silently**, with no warning at all | §404 |
| `dialerProxy` target unusable (missing / group / service / unconvertible / cyclic / deeper than 8) | **owner rejected in full** — no node created | `DialerProxyUnusableWarning` (error) | `json_parsers.dart:225-241`, logic `:794-855` | emitting it with a direct path would be a silent deanonymisation: the provider wrapped the dial in a relay because the direct route is cut. Principle 4 | §404 / D-085 |
| Unusable hop in the **middle** of a multi-hop chain | whole chain → null → owner rejected | `DialerProxyUnusableWarning` | `json_parsers.dart:846-851` | a truncated path releases traffic one hop earlier than the provider intended | §404 |
| `dialerProxy: "direct"` | chain → null → **owner rejected** | `DialerProxyUnusableWarning` | `json_parsers.dart:815-819` | differs from the sing-box branch, where the same text is silent and costs no node — here D-085 forbids substituting a direct path for a relay | §404 |
| Rejected owner has no sibling to carry the warning | reason kept in `dropped[]`, attached to the subscription's first node | `DialerProxyUnusableWarning` | `json_parsers.dart:286-291`, `parse_all.dart:151-164` | if there is no node at all the subscription is empty and there is nobody to tell — a documented hole | §404 P3 |
| Duplicates by `nodeDedupSignature` | skipped | silent | `json_parsers.dart:248-256` | the old key ignored transport and relay, collapsing "direct + BYPASS" pairs into one | §404 D-086 |
| Exception (TypeError) inside a converter | node skipped | `UnsupportedProtocolWarning(proto\|'malformed')` | `json_parsers.dart:263-271` | garbage field types (`streamSettings: "none"`) throw | §322 |
| Several balancers in one element | first taken, rest **silently ignored** | silent | `json_parsers.dart:312-323` | the schema allows it; real configs have one | §322 |
| Balancer `maxRTT` | clamped by `clampPoolTolerance` | silent | `json_parsers.dart:388-390` | `maxRTT` is an absolute ceiling in Xray while `pool_tolerance` is a window from the best — carried 1:1 by owner decision, since an exact conversion is impossible | §322 |
| `strategy.type` unknown / absent | default `roundRobin`; `leastLoad expected≤1` → `leastTest` | silent | `json_parsers.dart:366-373` | `leastLoad` with expected > 1 → round_robin is an approximation | §322 |
| hysteria `version != 2` | node rejected | `UnsupportedProtocolWarning` | `json_parsers.dart:751` | no v1 spec here | §321 |
| `finalmask.quicParams` on hysteria | **not carried over** | silent | `json_parsers.dart:741-743` | no sing-box equivalent, and an unknown field sinks the whole config | §321 |
| Xray `fingerprint` outside the vocabulary | → `chrome` | `UnknownFingerprintWarning` | `json_parsers.dart:535-538, 662-665, …` | whole-config fatal | §281 |
| Xray REALITY `publicKey` invalid | `reality = null` → plain TLS | silent | `json_parsers.dart:888-899` | keep the node working, do not poison config.json | §169 |
| Xray ws `?ed=N` | tail cut → `max_early_data` | silent (no warnings channel) | `json_parsers.dart:928-931` | otherwise a 404 | §303 |
| Xray ws `eh` without `ed` | `eh` ignored | silent | `json_parsers.dart:932-935` | the core enables the mode on `max_early_data > 0` | §320 |

## Layer 3 — node emission

The narrowest waist in the pipeline: every source branch — URI, sing-box JSON,
Xray JSON, manual editor — builds a `NodeSpec` and emits through here. A guard
placed at this layer cannot be bypassed by adding a new source.

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| XHTTP `uplink_data_placement: header` with **no** `mode` | `mode: packet-up` written, placement kept | `XhttpModeForcedPacketUpWarning` | `transport_spec.dart:266-292` | the core accepts header placement only in packet-up and drops the **entire** config otherwise; one subscription node stops the VPN coming up at all. The mode is added rather than the placement removed because `header` is meaningful only in packet-up — so the source implied it, and removing the placement would build the node differently from what the server expects | §416 |
| XHTTP `uplink_data_placement: header` with an explicit non-packet-up `mode` | placement removed, `mode` **left alone** | `XhttpParamResetWarning(placementRequiresPacketUp)` | `transport_spec.dart:293-295` | now two intents conflict. Principle 1: rewriting an explicit `mode` would change the node's wire protocol, so the unusable part goes instead | §416/§169 |
| XHTTP `seq_placement` outside `{path, query, header, cookie}` | field reset (not emitted) | `XhttpParamResetWarning(invalidEnumValue)` | `transport_spec.dart:244-252, 262-263` | a value outside the set is a fatal | §217 |
| XHTTP `x_padding_placement` outside `{cookie, header, query, queryInHeader}` | field reset | `XhttpParamResetWarning(invalidEnumValue)` | `transport_spec.dart:314-315` | as above | §217 |
| XHTTP `x_padding_method` outside `{repeat-x, tokenish}` | field reset | `XhttpParamResetWarning(invalidEnumValue)` | `transport_spec.dart:316-317` | as above | §217 |
| XHTTP `session_placement`, `uplink_http_method` | **pure passthrough, no guard by design** | silent | `transport_spec.dart:254-260, 303-309` | principle 2: the core rejects one node on these, not the file. The canon is Go's behaviour ("normalization is left to the core") | SPEC 103 |
| XHTTP empty `xmux` sub-object | not emitted | silent | `transport_spec.dart:305-317` | `{"xmux":{}}` would read as configured-but-zero | §127 |
| uTLS **and** REALITY over QUIC (hysteria2/tuic) | both blocks stripped from the emit; `server_name`/`alpn`/`insecure` kept | silent | `tls_spec.dart:35-40`, applied `node_spec_emit.dart:339, 457` | their `STDConfig()` returns an error and the QUIC path falls back to exactly that — both blocks on QUIC mean a dead node, and `fp` on hy2/tuic is xray-subscription noise | §282 |
| VLESS `flow` other than exactly `xtls-rprx-vision` on bare TLS | field not written (plain VLESS) | silent | `node_spec_emit.dart:54, 79` | the core accepts exactly two values; a universal net over all paths (URI/Xray/raw JSON/manual) | §115 |
| hysteria2 obfs type not `salamander`/`gecko` at emit | `obfs` object not written | silent | `node_spec_emit.dart:326` | second line after the parser: only what the core accepts gets through | §358 |
| MASQUE legacy `network`/`sni` names | never written | silent | `node_spec_emit.dart:678-681` | still accepted but deprecation-warned per outbound, and writing old and new names with different values is fatal | §393 |
| Default-valued fields (`path='/'`, absent ints) | not emitted | silent | `transport_spec.dart:222-227` | the constructor default is for the UI, not the wire; emitting it breaks canon and identity hashes | SPEC 103 CANON §2.4 |

## Layer 4 — config assembly

Order matters and is hard-coded in `buildConfig`, not derived from the `part`
directives in `post_steps.dart` (which is a barrel, not an orchestrator):
`resolveChains` → direction groups → `normalizeRuleOrder` → custom rules →
rule-set flush → `route.final` degrade → TLS transforms → custom DNS →
`applyTunPackages` → `healPresetTagPrefix` → `healDanglingResolveServers` →
`healLegacyDnsStrategy` → `healUnknownUtlsFingerprints` → `healInvalidReality` →
`sanitizeOutboundGraph` → `validateConfig`
(`build_config.dart:309-611`). Two adjacencies are normative and commented in
place: prefix healing before the degradations (otherwise the setting is lost
rather than migrated), and the graph sanitiser last before the validator.

### 4.1 Graph sanitiser (`post_steps/sanitize_outbound_graph.dart`)

The final pass over the outbound graph. Its stated rule is "degrade one element
with a warning rather than hand the core a file it will reject"
(`sanitize_outbound_graph.dart:19-20`).

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| `detour` to a non-existent tag | `detour` key removed, node goes direct | `emitWarnings`, aggregated per target (first 5 names + count) | `:293-303`, render `:781` | any dangling reference is fatal for the config **as a whole**, and sing-box names not the culprit but the first outbound referencing it (`dependency[X] not found for outbound[Y]`) | §393 A4 |
| Same, but the target was removed by the sanitiser itself | separate bucket, different text | `emitWarnings` ("was left with no members and removed during sanitation") | `:299-301`, `:792-795` | "referenced missing X" would be a lie sending the user to hunt a broken subscription instead of what happened | §393 A4 |
| Ghost members of a `selector`/`urltest` | excluded from the roster | `emitWarnings` | `:371-391` | the core rejects the config on a dangling member | §393 A4 |
| Group emptied **and** it is a Direction | not dropped: roster becomes `[block, direct-out]`, `default = block` | `emitWarnings` | `:406-419` | removing it would dangle `route.rules[].outbound`; blocking is safer than releasing traffic outside the VPN | §393 A4 |
| Group emptied, not a Direction | entry dropped whole | `emitWarnings` | `:421`, `:143-147` | cascade cleanup | §393 A4 |
| Group `default` not among its members | replaced with `kept.first` | `emitWarnings` | `:429-435` | otherwise the core rejects the config ("default outbound not found") | §393 A4 |
| Node whose detour leads into a group it belongs to | node removed from the roster, **detour kept** (fail-open) | `emitWarnings`, aggregated per node | `:379-399`, render `:772` | the detour was set deliberately; sending the traffic direct would break exactly what the user asked for. Otherwise the kernel would not start (dependency cycle) | §393 A4 |
| Composite: a node keeps a detour into a Direction that has gone to block | nothing changed — composite warning only | `emitWarnings` | `:206-217`, render `:754` | the node's policy silently inverted while the config stays valid and the core starts; no other warning names the consequence | §393 A4 |
| `type: chain` hop pointing at a non-existent tag | **chain dropped whole** | `emitWarnings` | `:321-332` | the core will not start on a dangling reference, and "just drop the hop" would make it a different route | §393 C4 |
| `type: chain` nested chain at position ≥ 1 | chain dropped whole | `emitWarnings` | `:333-341` | core invariant `protocol/chain/chain.go:279` | §393 C4 |
| Group used as a hop contains chains among its leaves | chains excluded from that group's roster | `emitWarnings` | `:487-535` | the core walks group leaves at start and rejects a nested chain; `check` does not catch it, only `run` does | §393 C4 |
| Cycle over any edge (detour / member / chainHop) | Tarjan SCC + scoring, **one** edge cut per pass: detour key removed, member excluded, or chain dropped | `emitWarnings`, 3 texts | `:560-657` | which edge to cut is the §254 question — taking the first would cut innocent nodes (the §254 case would have stripped detours from two clean nodes instead of the one at fault) | §393 A4/§254 |
| No edge unties the cycle (`bestScore <= 0`) | sanitiser gives up | nothing here → fatal `DetourCycle` later | `:633` | hand it to the validator | §393 A4 |
| A tag counts as "alive" only with an actual entry (`dns-out`/`block-out`/`direct`/`reject`/`drop` are ghosts) | affects all rules above | — | `:125-141` | treating a tag as alive without an entry would leave a reference the validator then kills fatally — fail-open here equals fatal there | §393 A4 |
| `chain` deliberately excluded from `_isGroup` | trap guard | — | `:249, 256, 68-74` | giving it group semantics would exclude a ghost hop from the "roster" instead of dropping the chain, and the user would travel a route they never asked for | §393 C4 |
| Fixpoint iteration limit (`len*4 + 8`) exhausted | loop exits | **silent** | `:149-192` | the comment argues it is unreachable (each pass removes an edge or node); there is **no handling and no warning** if it is reached — purpose of the unhandled branch unclear | §393 A4 |

### 4.2 Heal steps (`post_steps/heal_*.dart`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| Route rule `{action: resolve, server: X}` where X is not a DNS server tag | `server` removed, resolution falls back to DNS routing | `emitWarnings` (`build_config.dart:554`) | `heal_dangling_resolve_servers.dart:44-45` | the core does **not** validate this at start — it fails lazily on every matching connection (`DNS server not found`), so all matched traffic is dead. Our validator does not see this reference | §247 |
| REALITY `public_key` not X25519 | whole `reality` block removed, node degrades to plain TLS | `emitWarnings` (`:593`) | `heal_invalid_reality.dart:36-40` | `invalid public_key` is a whole-config fatal | §343/§169 |
| REALITY `short_id` not a String (a number from raw JSON or a §302 patch) | → `''` | `emitWarnings` (`:591`) | `heal_invalid_reality.dart:44-48` | the core cannot decode it either — same fatal. Drop, do not fit | §343/§169 |
| REALITY `short_id` non-hex / odd / over 16 | → `''` (an empty short id is legal) | `emitWarnings` | `heal_invalid_reality.dart:48-51` | decoded as hex into `[8]byte`; whole-config fatal | §343 |
| `reality.enabled != true` | left alone | silent (deliberate) | `heal_invalid_reality.dart:31` | the core does not decode a disabled block, so it is not fatal | §281 |
| Legacy `strategy` in `dns.rules` together with any `query_type`/`ip_version` | `strategy` removed from **all** dns.rules | `emitWarnings` (`:565`) | `heal_legacy_dns_strategy.dart:34-45` | the presence of the new keys switches the core into non-legacy DNS mode, where legacy `strategy` is fatal at start and the VPN does not come up | §246 |
| Other triggers of the same core switch (`match_response`, `response_rcode`, action `evaluate`/`respond`) | **not caught** | silent | `heal_legacy_dns_strategy.dart:15-18` | our template does not emit them; catching every user-authored form is a separate task | §246 |
| Reference to a local (unprefixed) preset tag | rewritten to `<preset_id>:<tag>` in dns rules, `dns.final`, route rules | `emitWarnings` (`:543`) | `heal_preset_tag_prefix.dart:70-101` | the core does not validate this at start: `sing-box check` passes and it fails lazily, so the user sees "the internet is broken on some sites", not "the update broke a setting" | §103 C7 |
| Two presets declared the same local tag | **not healed** — falls through to the dangling-resolve guard | that guard's warning | `heal_preset_tag_prefix.dart:48` | guessing which one the user meant would silently pick the wrong one | §103 C7 |
| hysteria2/tuic carrying `tls.utls` and/or `tls.reality` | both blocks removed | **silent** | `heal_unknown_utls_fingerprints.dart:30-34` | uTLS and REALITY over QUIC are a dead node; restoring utls here would resurrect it | §282 |
| REALITY with no `utls` block (or disabled) | minimal `{enabled: true}` restored | **silent** | `heal_unknown_utls_fingerprints.dart:38-47` | REALITY without uTLS is fatal ("uTLS is required by reality client") | §281 |
| Known xray fingerprint alias | canonicalised | **silent** | `heal_unknown_utls_fingerprints.dart:51-58` | a synonym, not a degradation | §281 |
| Unrecognised fingerprint | → `chrome` | `emitWarnings` (`:578`) | `heal_unknown_utls_fingerprints.dart:57-58` | outside the core's case-sensitive vocabulary is a whole-config fatal; discarding would lose a live server | §281 |
| Whitespace-only fingerprint | key removed, utls stays enabled | silent | `heal_unknown_utls_fingerprints.dart:53-56` | the core treats an empty fingerprint as chrome | §281 |

### 4.3 Core capability gate (`chain_nodes.dart`, `core_chain_capability.dart`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| Core older than `1.14.0-lx.27-rc.5` (no `type: chain`) | **all** chains degrade — none emitted | `emitWarnings`, code `chain_unsupported_by_core` | `chain_nodes.dart:98-102`, `core_chain_capability.dart:119` | an older core rejects the config entirely (`unknown outbound type: chain`) — one configured chain would leave the user with no VPN at all | §393 C5 |
| Version unparsable / empty / upstream without `-lx.N` | **fail open** — assume support | silent | `core_chain_capability.dart:120-123` | degrading on a guess costs a working route, while a config the core rejects at least surfaces as a start error. The reverse mistake is undiagnosable | §393 C5 |
| `Libbox.version()` transient failure | empty string not cached; exception → `''` | silent | `core_chain_capability.dart:150-170` | otherwise chains vanish from one rebuild and return in the next — a "flickering" route is impossible to diagnose | §393 C5 |
| Version comparison | typed `CoreVersion`, not string compare | — | `core_chain_capability.dart:92-108` | string compare is the classic bug (`rc.10` < `rc.5`) | §393 C5 |
| Chain tag collides with an existing node/Direction/chain | chain skipped | `emitWarnings`, `chain_invalid` | `chain_nodes.dart:115-121` | two outbounds with one tag makes the core reject the config | §393 C3 |
| Chain position references an unknown tag (**including a forward reference**) | **chain dropped whole** | `emitWarnings`, `chain_hop_missing` | `chain_nodes.dart:126-143` | cycles between chains become impossible by construction; and silently substituting a hop is the same as silently changing the exit country | §393 C3 |
| Chain passes through a Direction (transitively) | excluded from **that** Direction's roster | `emitWarnings`, `chain_cycle_through_direction` | `chain_nodes.dart:236-263` | the user would get a route they never intended — picking a chain inside proxy-out loops traffic back onto it | §393 C4 |

### 4.4 Build orchestration (`build_config.dart`, `server_list_build.dart`)

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| `route.final` not among `{direct-out, block, emitted Direction tags}` | default `vpn-1` substituted | `emitWarnings` | `build_config.dart:496-509` | a static tag for a Direction with an empty node set would dangle (fatal); `vpn-1` is undeletable and therefore always a valid target | §125/§219 |
| Tags of **all** Directions (including disabled) reserved in the allocator | a same-named node gets a `-N` suffix | silent | `build_config.dart:254-256` | a subscription node labelled `vpn-1` would duplicate a tag and the core refuses to start; for disabled ones the user was getting a "vpn-2" option leading to someone else's server | §351/§393 |
| `direction.include[]` referencing below itself / disabled / non-existent | option dropped from the roster | `emitWarnings` | `build_config.dart:789-798` | the core would reject a forward reference, so degrade the roster rather than break the build | §393 A3 |
| Direction roster empty | fallback `[block-out, direct-out]`, `default = block` | `emitWarnings` when a non-empty filter is to blame | `build_config.dart:837-840, 890-892` | safer to block than to release outside the VPN; and a selector must not be an empty group (fatal) | §201/§274 |
| A non-empty node filter matched nothing | warning states the **actual** outcome (blocked / direct / fallback) | `emitWarnings` + SnackBar | `build_config.dart:849-881` | with include_direct the outcome is direct-out — claiming "blocked" would be a lie about traffic leaving the VPN | §200/§274 |
| Chains subtracted from a Direction | that subtraction does **not** trigger the filter warning | — | `build_config.dart:733-742` | sending the user to fix a filter means sending them to hunt a typo that does not exist | §393 C4 |
| Broken / empty `node_filter` regex | `tryCompileRegex` → null → all base nodes | silent | `build_config.dart:715-722` | — | §125 |
| `defaultFilter` landed on a non-member | `default` key simply not written | silent | `build_config.dart:895-909` | otherwise the core rejects the config ("default outbound not found") and takes the first option anyway | §141 |
| An auto-select node inside a Direction's urltest twin | excluded | silent | `build_config.dart:753-763` | urltest inside urltest would measure the inner group's pick, not a server | §322 |
| `clash_api` block | no longer injected | — | `build_config.dart:168-171` | the core is built without `with_clash_api`, and the block is a fatal start failure | §122 |
| `lx_idle_suspend_reachable` without the base `lx_idle_suspend` | reachable not written | silent | `build_config.dart:475-484` | core: "lx_idle_suspend_reachable requires lx_idle_suspend" | §215/§272 |
| Proxy auth without a password | `proxy_auth = 'false'` | silent | `build_config.dart:187-192` | guards against `[{"":""}]` | §067 |
| Auto-select node with an empty pool | node **not emitted at all** | silent | `server_list_build.dart:143-146` | an empty urltest kills core startup, reachable when all members are disabled or the subscription emptied | §322/§283 |
| Intra-folder detour cycle | DFS colouring, closing edge discarded | silent | `server_list_build.dart:247-264` | the main guard is in the controller; this backs up a hand-edited backup | §239 |
| Intra candidate with its edge cut | detour → `''`, reference not emitted | silent | `server_list_build.dart:273-279` | otherwise a bare tag goes into the config as a dangling reference | §239 |
| Tag allocator exhausts its counter (100000) | returns the **taken** base tag | **silent** | `build_config.dart:658-665` | practically unreachable, but the fail mode is "silently fatal" rather than "silently degrade", and there is no comment — **purpose/deliberateness unclear** | — |

### 4.5 Presets, rules and DNS

| Check | Sanitiser | User sees | Code | Why | Task |
|---|---|---|---|---|---|
| Required preset var empty / unset | the **whole preset** yields empty fragments | `emitWarnings` | `preset_expand.dart:126-141` | — | §033 |
| Remote rule_set with no cached file | rule_set skipped | `emitWarnings` | `preset_expand.dart:189-198` | sing-box downloads nothing itself | §011 |
| DNS rule with no `server` and no serverless action | rule dropped **silently** | silent | `preset_expand.dart:232-235` | `route` and `evaluate` without a server are fatal at start, and an unknown action is a decode error; a template typo must not reach the core | §253 |
| DNS/route rule referencing an unregistered `rule_set` | rule dropped | `emitWarnings` | `preset_expand.dart:242-261, 367-375` | the core fails with `rule-set not found`; the guard is per-element so the rest survive | §011/§045 |
| `rule_set` of an invalid shape (empty string, int, bool, map) | reference removed, rule survives | `emitWarnings` | `preset_expand.dart:263-272, 395-404` | degradation instead of the core's fatal | §219 |
| `outbound == "reject"` (including via a template default) | **unconditional backstop**: `outbound` removed, `action: reject` set | silent | `preset_expand.dart:352-355` (marked "do not delete") | `reject` is an action, not an outbound tag; the validator would see a dangling ref and the core would not start. Without the backstop the literal reached users' route.rules | §033 |
| Intermediate actions (`resolve`/`sniff`/`route-options`) | outbound override and reject backstop **not** applied | silent | `preset_expand.dart:303-304` | the override would replace `action: resolve` with the user's outbound and destroy the semantics | §246 |
| A chosen DNS server is a **group** | its members are pulled in alongside it | silent | `preset_expand.dart:424-437` | without them the group arrives empty, the emission filter drops them as unknown, and the validator hits `EmptyDnsGroup` — fatal before the core starts | §354/§312 |
| Preset tag namespacing `<preset_id>:<tag>` | only tags declared here and references to them are prefixed | silent | `preset_expand.dart:474-546` | without it two presets sharing a local tag collide and the second silently loses its server; a reference to someone else's tag is left alone or it would point nowhere | §103 C7 |
| Duplicate DNS servers / rule_sets across presets | identical → silent skip; conflicting → first wins | `emitWarnings` on conflict | `preset_expand.dart:566-594` | — | §033 |
| `detour` on a `type: group` DNS server | **unconditionally removed** | silent | `preset_expand.dart:628-631` | the core accepts exactly `{servers, mode, error_ttl, win_ttl}` on a group and fails on an extra key — start broke whenever a non-direct Direction was picked | §319 |
| DNS server `detour` = `direct-out` / empty / unknown outbound | key removed | silent | `preset_expand.dart:632-638` | absent key beats a dangling reference | §117 |
| `"//"` comment keys in a raw-JSON rule | **recursively stripped** | `emitWarnings` | `custom_rules.dart:840-858` | sing-box strict-decode on an unknown field drops the whole config at start, and `//` is a common convention — a user copying a commented example got a fatal. Other unknown fields are left alone: their set is unknown to the builder, and cutting blind is worse than letting the core's decoder judge | §350 |
| Raw JSON: empty / malformed / scalar / no objects / empty after comment stripping | rule skipped | `emitWarnings` (4 texts) | `custom_rules.dart:781-827` | the build does not fail; the rule degrades and the rest of the config survives | §225 |
| Preset id missing from the template | rule skipped | `emitWarnings` | `custom_rules.dart:154-157` | — | §033 |
| Preset disabled by the routing toggle | produces no servers, rules or mirror locks | silent | `custom_rules.dart:141-145` | the routing toggle is king — as if the preset were not in the config | §121 |
| Force-IPv4 / DNS mirror with an empty match | not emitted | silent | `custom_rules.dart:~450, ~468` | a match-everything rule would kill AAAA globally | §256/§117 |
| `ip_is_private` / `inbound` / `protocol` inside a headless rule | lifted to routing-rule level | silent | `custom_rules.dart:692-696` | sing-box would cut the config at parse time | §030 |
| DNS group member is the group itself / duplicated / unknown / disabled | member dropped from the emit; **storage not mutated** | `emitWarnings` per reason | `dns_servers.dart:414-430` | self-inclusion drops the config in the core; a disabled member snaps back when re-enabled | §312 |
| DNS group empty after that filtering | **not healed, not dropped** — emitted empty | fatal `EmptyDnsGroup` at the validator | `dns_servers.dart:395-397` | deliberately blocks the build so the user decides, instead of degrading silently (anti-pattern §277/§278) | §312 |
| Disabled DNS server still referenced by an active preset or rule | force-included | silent | `dns_servers.dart:335-339` | otherwise a DNS rule points into nothing | §117 |
| Wizard-only fields in a DNS body (`enabled`, `description`, `_origin`, …) | stripped | silent | `dns_servers.dart:359-364` | the core rejects unknown fields | §044 |
| Orphan/unknown-`kind` DNS entries (legacy) | discarded | silent | `dns_servers.dart:114-123`, `dns_rules.dart:223, 322` | auto-discovery restores fresh state | §043/§044 |
| Duplicated preset rules with one `presetId` | the **last** survives | silent | `rule_order.dart:125-141` | seeding checks presence by presetId and would leave both; on import the second copy reflects the fresher intent | §398 |
| Missing mandatory (`default: true`) presets | seeded | silent | `rule_order.dart:84-111` | guarantees an unsortable preset exists and comes first — critical for route.rule order (sniff first) | §370/§264 |
| Rule-set tag already taken | auto-suffix ` (2)`, ` (3)` | silent | `rule_set_registry.dart:34-43` | tag uniqueness, defence-in-depth for imported or programmatically edited configs | — |
| Mixed-case SNI on a REALITY node | **skipped** | silent | `tls_transforms.dart:25-26` | the server matches the name against a map with an exact string key and no case folding; one changed letter misses the map and falls back to the decoy site — the node does not come up | §363 |
| Punycode labels (`xn--`) | not randomised | silent | `tls_transforms.dart:39` | the prefix is reserved and the payload is case-sensitive | §028 |
| Mixed-case SNI / fragment on inner hops | skipped | silent | `tls_transforms.dart:18, 66` | inner hops are already inside the tunnel; DPI cannot see their TLS | §028 |
| `tls_fragment` on a naive outbound | skipped | silent | `tls_transforms.dart:67-70` | the core rejects it fatally ("fragment is not supported on naive outbound") | §270 |
| `tls_fragment` on a non-h2 MASQUE | skipped **silently and deliberately** | silent | `tls_transforms.dart:71-85` | on h3 the core warns and ignores it; a global toggle should not complain about every unsuitable node | §393 |

### 4.6 Validator — the last line (`validator.dart`)

`validateConfig()` is pure: it never mutates the config, only collects
`ValidationIssue`s, and **every** issue it emits is `Severity.fatal`. Blocking
happens above it (`subscription_controller.dart:1958` → `FatalValidationException`),
so the config is neither persisted nor handed to the core. Before §141 P0.1
fatal issues were only logged and the broken config still reached the core,
producing a looping failed start with the bad config persisted as the source of
truth.

By design this is the *last* line, not the first: routine cycles are untied by
the graph sanitiser with a warning, and only what it could not untie arrives
here (`validator.dart:83-88`).

| Issue | Fires on | Code | Task |
|---|---|---|---|
| `DanglingOutboundRef` | `route.rules[].outbound` or `route.final` naming a non-existent tag | `validator.dart:42, 56` | §219 |
| `DanglingDetourRef` | `detour` naming a non-existent tag | `validator.dart:70` | §084 |
| `DetourCycle` | cycle over detour plus structural group→member edges; Tarjan SCC, minimal culprit set, **capped at 3 culprits** | `validator.dart:101-103, 231`, cap `:6` | §254/§393 |
| `DanglingDnsServerRef` | `dns.final` / `route.default_domain_resolver` naming a non-existent DNS tag | `validator.dart:117, 123` | §121 |
| `BadResolverServerType` | resolver reference pointing at a `fakeip`/`hosts` server | `validator.dart:152` | §384 |
| `EmptyDnsGroup` | group empty after the emission filter | `validator.dart:165` | §312 |
| `BadDnsGroupMember` | group member is `fakeip`/`hosts` | `validator.dart:171` | §312 |
| `DnsGroupCycle` | cycle in the DNS group graph | `validator.dart:180, 464` | §312 |
| `EmptyUrltestGroup` | empty `urltest` | `validator.dart:190` | — |
| `InvalidDefault` | `selector.default` absent from outbounds, or not a String | `validator.dart:196` | §141 |

The culprit cap exists for performance: uncapped colouring is quadratic and a
pathological config (150 nodes) spent about 1.3 s inside `generateConfig`.
Dangling DNS **group members** are deliberately not checked here — the builder
already dropped them with a warning (`validator.dart:130-131`).

## Known asymmetries and gaps

Found in the code during this revision; recorded rather than fixed.

**1. Warnings lost in the sing-box JSON branch.** The same condition that
produces a `NodeWarning` on the URI path is silent when it arrives via
`parseSingboxEntry`, because that function has no warnings accumulator:

| Condition | URI path | JSON path |
|---|---|---|
| `packet_encoding` outside the whitelist | `PacketEncodingUnknownWarning` | silent (`json_parsers.dart:1007-1010`) |
| hysteria2 obfs unknown / no password | `UnknownObfsWarning` / `MissingObfsPasswordWarning` | silent (`:1085-1089`, `warnings: null` passed explicitly) |
| uTLS fingerprint unrecognised | `UnknownFingerprintWarning` | silent (`:1397`) |
| MASQUE `vhttp` outside `{h3,h2,auto}` | `MasqueVhttpInvalidWarning` | silent (`:1315-1321`) |
| ws `?ed=` conversion | `WsEarlyDataConvertedWarning` | silent (`:1413-1415`, and Xray `:928-931`) |

For fingerprint and obfs the silence is **documented** ("power-user path
through the JSON editor / Smart Paste — the resulting value is visible in the
JSON itself"). For `packet_encoding` and MASQUE `vhttp` there is no explanation
in the code, and the divergence looks unintended.

**2. Declared but unused warning variants.** `UnsupportedTransportWarning`,
`MissingFieldWarning`, `DeprecatedFlowWarning` and `NaiveBuildTagWarning` are
produced nowhere in the parser layer. `XhttpResetReason.invalidPlacementValue`
and `XhttpResetReason.getRequiresPacketUp` are declared
(`node_warning.dart:186, 193`) but never set — those paths are passthrough by
the "canon = Go behaviour" decision.

**3. Unexplained literals.** `uri_utils.dart:181` replaces `🇪🇳` with `🇬🇧`
("leftover artefact from v1" — no core error or behaviour named).
`hysteria2_parser.dart:83` treats the literal `'🔒'` as a bad SNI with no
comment at all. Neither purpose could be established from the code.

**4. Unhandled exhaustion branches.** The graph sanitiser's fixpoint limit
(`sanitize_outbound_graph.dart:149-192`) and the tag allocator's counter
(`build_config.dart:658-665`) both exit without a warning if reached. The
sanitiser's comment argues its branch is unreachable; the allocator has no
comment, and returning an already-taken tag is a silent fatal in the core.

**5. Depth limits are inconsistent.** `_detourReaches` and
`_pruneChainLeavesUnderGroups` (`sanitize_outbound_graph.dart:456, 503, 521`)
rely on a `seen` set with no depth cap, unlike `kMaxDetourCulprits` in the
validator and `kMaxDetourDepth` in the parsers. Whether that is a deliberate
choice is not stated.

**6. `healPresetTagPrefix` coverage.** It rewrites `dns.rules[].server`,
`dns.rules[].rule_set`, `dns.final`, `route.rules[].rule_set` and
`route.rules[].server` (`heal_preset_tag_prefix.dart:84-101`), but not
`route.rules[].outbound`. Nothing states whether that list is meant to be
exhaustive.

**7. Silent loss when a source yields no node.** A config or Xray element that
produces zero nodes loses all its warnings — there is no node to carry them
(`json_parsers.dart:205-207`, `singbox_config.dart:254-257`,
`parse_all.dart:151-158`). Compensated by the "skipped" counter in the import
dialog (§368 §8) and the contract's `dropped[]` envelope (D-088).

**8. `xhttp_uplink_header_placement_reset` is a red contract case.** The §416
guard diverges from the Go reference, which still passes the placement through.
The shared corpus expectation lives in the launcher repository and
`app/contract/` is a vendored, lock-checked copy, so the divergence surfaces as
a failing test until the launcher side accepts a class-A override. See
[`spec/tasks/416-xhttp-packet-up-guard.md`](spec/tasks/416-xhttp-packet-up-guard.md).
