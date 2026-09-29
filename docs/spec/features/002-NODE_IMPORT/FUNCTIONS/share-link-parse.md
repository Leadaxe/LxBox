[English](share-link-parse.md) · [Русский](share-link-parse.ru.md)

# Share link parsing

| Field | Value |
|------|----------|
| Feature | [002-NODE_IMPORT](../FEATURE.md) |
| Promises | P1 P4 P5 P10 P15 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Accepts one string of the form `scheme://…` — pasted by hand, scanned
or a line of a subscription list — and turns it into a node. If no node came out,
it names the reason with a code.

## Parameters

| Scheme (spellings) | Core body type | Form notes |
|-------------------|---------------|---------------|
| `vless` | `vless` | REALITY is enabled only with a valid X25519 key `pbk`; `flow` is taken from the link, vision is turned off with a transport |
| `vmess` | `vmess` | v2rayN base64(JSON); the second form — URL |
| `trojan` | `trojan` | TLS by default |
| `ss` | `shadowsocks` | SIP002 (base64 or plain userinfo) and the old base64 form; SIP003 plugin → `plugin` + `plugin_opts` |
| `hysteria2`, `hy2` | `hysteria2` | obfs `salamander`/`gecko`, bandwidth with a unit → Mbit/s, `mport` → `server_ports` |
| `tuic` | `tuic` | v5 |
| `anytls` | `anytls` | |
| `socks`, `socks5`, `socks4`, `socks4a` | `socks` | the scheme spelling carries the version |
| `proxy-http`, `proxy-https`, `proxy+http`, `proxy+https` | `http` | default port 80 / 443; `https` enables TLS |
| `ssh` | `ssh` | password or private key in the link |
| `naive+https`, `naive+quic` | `naive` | default port 443; a single userinfo is the password; bare `naive://` is not accepted |
| `wireguard`, `wg`, `awg`, `amneziawg` | endpoint `wireguard` | see [WireGuard / AmneziaWG import](wireguard-amnezia-import.md) |
| `masque` | `masque` | a WARP node, see [015-WARP](../../015-WARP/FEATURE.md) |
| `vpn://` | endpoint `wireguard` | Amnezia profile: all WG/AWG containers |

The set of spellings is read from the registry (`scheme_in` of the link section plus
the protocol's `aliases`); scheme case does not matter. Length limit — 65536 characters,
for `vpn://` — 524288.

## Inputs / Outputs

**Input:** a link string. **Output:** a node (a body in core form, a name, the original
link byte for byte as the source) or "no node" + a code for the rejects.

## Rules and invariants

- The node name is the decoded remark after `#` (control characters
  are cleaned out, the flag `🇪🇳` is replaced with `🇬🇧`); without a remark —
  `<body type>-<host>-<port>` (for `ss://` this is `shadowsocks-…`).
- Parsing never throws: garbage → "no node".
- Outcomes without a node and what the user sees (via the rejects):

| Situation | Code | Level |
|----------|-----|---------|
| The registry does not know the scheme | `scheme_unsupported`, the scheme in `value` | error |
| A line without `://` | — (silently) | — |
| Longer than the limit | `uri_too_long` | error |
| `vpn://` did not unpack | `form_unrecognized` | error |
| Target `0.0.0.0` / loopback / `localhost` | `provider_banner_link`, the remark is the message | info |
| Service line `incy://routing/…`, `happ://routing/…` | registry code | info |
| A required field is missing (`server`, `uuid`) | `field_missing` | error |
| A registry rule removes the node | the rule's code | error |

- A `vpn://` line inside a list yields all the profile's containers, as if the
  profile were the whole body.
- A single paste that yielded no node shows the reason; a garbage line —
  the previous message without a reason (display — [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md)).

## Boundaries

- `http://`/`https://` is a subscription address, not a node
  ([001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md)).
- `hysteria://`/`hy://` (v1) is declared by the registry, but there is no hysteria v1 model
  in the app — no node is created.
- Details of TLS obfuscation and XHTTP — [016-DPI_HARDENING](../../016-DPI_HARDENING/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---------|--------|------|
| 1 | [026F](../../../tasks/026F-parser-v2/spec.md) | Implemented | Typed nodes, parsing a link into the model, link round trip |
| 2 | [037F](../../../tasks/037F-naive-proxy/spec.md) | Draft | The `naive+https` scheme |
| 3 | [106](../../../tasks/106-wireguard-slash-key-and-bare-cidr.md) | DONE | Raw `/` in a WG key, bare IP → CIDR |
| 4 | [115](../../../tasks/115-vless-flow-honor-link.md) | Code-complete | VLESS `flow` is taken from the link, vision is not imposed |
| 5 | [151](../../../tasks/151-jni-iterator-throw-and-alpn-double-decode.md) | Done | Double encoding of ALPN is undone |
| 6 | [169](../../../tasks/169-reality-pbk-validation.md) | Implemented | REALITY only with a valid X25519 |
| 7 | [222](../../../tasks/222-http-proxy-protocol.md) | — | HTTP(S) proxy `proxy-http(s)` |
| 8 | [268](../../../tasks/268-directlink-naive-masque-proxy-plus.md) | — | Aliases `proxy+http(s)`, `naive+https`, `masque` as links |
| 9 | [269](../../../tasks/269-anytls-protocol.md) | — | The `anytls` scheme |
| 10 | [303](../../../tasks/303-ws-early-data-ed-param.md) | implemented | `?ed=N` in the WS path → early data |
| 11 | [320](../../../tasks/320-trojan-subscription-parse-gaps.md) | partial | `ed`/`eh` in the query, double encoding of the path |
| 12 | [358](../../../tasks/358-hysteria2-obfs-gecko.md) | Implemented | hysteria2 obfs `gecko` reaches the body |
| 13 | [465](../../../tasks/465-naive-single-userinfo-password.md) | Released v2.25.0 | A single naive userinfo is the password |
| 14 | [475](../../../tasks/475-contract-118-socks-version-by-scheme.md) | Released v2.25.0 | The scheme carries the SOCKS version |
| 15 | [500](../../../tasks/500-direct-link-reject-reason.md) | Released v2.25.0 | Rejection reason of a single input |
| 16 | [506](../../../tasks/506-silent-parse-loss-reasons.md) | Released v2.25.2 | Codes instead of a silent line loss |
| 17 | [512](../../../tasks/512-registry-scheme-set-contract-1149.md) | Released v2.25.2 | The scheme set from the registry, `amneziawg://`, service schemes |
| 18 | [514](../../../tasks/514-contract-sync-11152.md) | Released v2.25.2 | Provider banner by target, socks base64 userinfo |
| 19 | [543](../../../tasks/543-hysteria2-3xui-gecko-aliases.md) | Done | 3x-ui links with gecko |
| 20 | [562](../../../tasks/562-uri-scheme-dispatch-from-registry.md) | Done | The scheme dispatcher only from the registry |
| 21 | [570](../../../tasks/570-close-open-tails.md) | Wave B done | A `vpn://` line in a list — all containers |
