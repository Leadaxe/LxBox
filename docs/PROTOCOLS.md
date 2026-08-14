# Protocol Documentation

L×Box parses proxy URIs from subscriptions and converts them into [sing-box](https://sing-box.sagernet.org/) outbound (or endpoint) JSON. This document describes every supported protocol, its URI format, parsed parameters, and the resulting sing-box configuration.

**Source code (Parser v2, spec 026):**
- [`app/lib/services/parser/uri_parsers.dart`](../app/lib/services/parser/uri_parsers.dart) — the URI formats of all 12 protocols (vless, vmess, trojan, shadowsocks, hysteria2, naive, tuic, ssh, socks, http, wireguard/awg, masque)
- [`app/lib/services/parser/transport.dart`](../app/lib/services/parser/transport.dart) — parsing `TransportSpec`, native XHTTP (§097, the full parameter set in §127)
- [`app/lib/services/parser/json_parsers.dart`](../app/lib/services/parser/json_parsers.dart) — `parseSingboxEntry`, `parseXrayOutbound`
- [`app/lib/services/parser/ini_parser.dart`](../app/lib/services/parser/ini_parser.dart) — WireGuard INI
- [`app/lib/services/parser/parse_all.dart`](../app/lib/services/parser/parse_all.dart) — orchestrator
- [`app/lib/models/node_spec.dart`](../app/lib/models/node_spec.dart), [`node_spec_emit.dart`](../app/lib/models/node_spec_emit.dart) — sealed `NodeSpec` + `emit()` / `toUri()`

---

## Table of Contents

1. [Subscription HTTP Headers](#0-subscription-http-headers)
2. [VLESS](#1-vless)
3. [VMess](#2-vmess)
4. [Trojan](#3-trojan)
5. [Shadowsocks](#4-shadowsocks)
6. [Hysteria2](#5-hysteria2)
7. [NaïveProxy](#55-naïveproxy)
8. [SSH](#6-ssh)
9. [SOCKS](#7-socks)
10. [HTTP(S) proxy](#75-https-proxy)
11. [WireGuard](#8-wireguard)
12. [AmneziaWG (AWG, AWG2)](#85-amneziawg-awg-awg2)
13. [WireGuard INI Config](#9-wireguard-ini-config)
14. [Amnezia vpn:// Link](#92-amnezia-vpn-link)
15. [TUIC v5](#95-tuic-v5)
16. [MASQUE (Cloudflare WARP)](#96-masque-cloudflare-warp)
17. [JSON Outbound / config (raw sing-box)](#10-json-outbound)
18. [Xray JSON Array](#11-xray-json-array)
19. [XHTTP transport](#xhttp-transport)

---

## 0. Subscription HTTP Headers

When fetching a subscription URL, L×Box reads several **de facto standard** HTTP response headers. These are **not formally standardized** (no RFC), but the convention is universally adopted across V2Ray/Clash/sing-box client ecosystem since ~2019. Backends like [V2Board](https://github.com/v2board/v2board), [Xboard](https://github.com/cedar2025/Xboard), [Marzban](https://github.com/Gozargah/Marzban) emit them out of the box.

### Parsed Headers

| Header | Format | Purpose |
|--------|--------|---------|
| `subscription-userinfo` | `upload=N; download=N; total=N; expire=UNIX` | Traffic quota and expiry |
| `profile-title` | plain text or **base64-encoded UTF-8** | Display name for subscription |
| `profile-update-interval` | integer hours | Auto-refresh interval hint |
| `support-url` | URL (often `https://t.me/...`) | Link to provider support |
| `profile-web-page-url` | URL | Provider's website |
| `content-disposition` | `attachment; filename="..."` | Fallback for title |

### Example Response

```
HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8
subscription-userinfo: upload=12345678; download=987654321; total=107374182400; expire=1735689600
profile-title: My VPN Provider
profile-update-interval: 24
support-url: https://t.me/myvpn_support
profile-web-page-url: https://myvpn.com

vless://uuid@server1.example.com:443?...
vless://uuid@server2.example.com:443?...
...
```

### Where They Come From

| Client | Role |
|--------|------|
| [v2rayN](https://github.com/2dust/v2rayN) (2018) | First to parse `subscription-userinfo` |
| [Clash](https://github.com/Dreamacro/clash) (2020) | Formalized header list in [Clash Wiki](https://clash.wiki/configuration/subscription-userinfo) |
| [Clash.Meta / Mihomo](https://github.com/MetaCubeX/mihomo) | Extended with additional fields |
| [subconverter](https://github.com/tindy2013/subconverter) | De facto reference converter — reads/writes all headers |
| [Hiddify](https://github.com/hiddify/hiddify-next) | Full set support |

### Traffic Quota Display

The `subscription-userinfo` header drives the **traffic quota bar** in subscription detail:

```
Used:     1.05 GB uploaded + 920 MB downloaded = 1.97 GB / 100 GB
Expires:  2026-12-31 (8 months remaining)
```

Backend reference: any of V2Board, Xboard, Marzban panels. These are PHP/Go backends that generate subscription responses with correct headers automatically — provider admins don't need to configure them manually.

### Why No RFC

This is **cargo cult convention** — works because all clients parse identically. Similar to how `X-Forwarded-For` was de facto standard for ~10 years before [RFC 7239](https://datatracker.ietf.org/doc/html/rfc7239). If a new client introduced its own header, no provider would emit it, so the ecosystem stays consistent through inertia.

### Implementation in L×Box

Parsing lives in [`app/lib/services/subscription/sources.dart`](../app/lib/services/subscription/sources.dart) (`_metaFromHeaders` plus `_parseContentDispositionFilename`). After a fetch the headers become a `SubscriptionMeta` and are stored in `SubscriptionServers.meta`:

- `SubscriptionServers.name` ← `profile-title` (falling back to `content-disposition: filename=...`, v1.3.0+)
- `SubscriptionMeta.{totalBytes, uploadBytes, downloadBytes, expireTimestamp}` ← `subscription-userinfo`
- `SubscriptionMeta.supportUrl` ← `support-url`
- `SubscriptionMeta.webPageUrl` ← `profile-web-page-url`
- `SubscriptionServers.updateIntervalHours` ← `profile-update-interval` (used by [spec 027](./spec/features/027%20subscription%20auto%20update/spec.md))

The User-Agent of HTTP requests is `LxBox-android/<appVersion>` (for example `LxBox-android/2.9.0`; the brand token since §114, previously `LxBox Android subscription client` / `SubscriptionParserClient`). It can be overridden per request through App Settings → Subscriptions → Custom User-Agent (§118). Panels route the response body by the `LxBox` substring in the UA (`user_agent.dart`, `resolveSubscriptionUserAgent`).

Displayed in the subscription detail → **Source tab** → Headers section.

---

## 1. VLESS

### URI Format

```
vless://UUID@host:port?query_params#label
```

### Parsed Parameters

| Parameter | Query key | Description |
|-----------|-----------|-------------|
| UUID | (userinfo) | User ID |
| Flow | `flow` | XTLS flow control (`xtls-rprx-vision`, `xtls-rprx-vision-udp443`) |
| Security | `security` | `tls`, `reality`, or `none` |
| SNI | `sni` or `peer` | TLS server name |
| Fingerprint | `fp` or `fingerprint` | UTLS fingerprint (defaults to `random`) |
| ALPN | `alpn` | Comma-separated ALPN values |
| Public key | `pbk` | The REALITY public key. REALITY is enabled only for a valid X25519 key (base64/base64url → 32 bytes); garbage falls back to plain TLS plus a warning (§169) |
| Short ID | `sid` | REALITY short ID (hex, max 16 chars) |
| Transport type | `type` | `tcp`, `ws`, `grpc`, `http`, `httpupgrade`, `xhttp`, `raw` |
| Path | `path` | WebSocket/HTTP/HTTPUpgrade path |
| Host | `host` | WebSocket Host header / HTTP host |
| Service name | `serviceName` or `service_name` | gRPC service name |
| Header type | `headerType` | When `http` with `type=tcp`/`raw`, creates HTTP transport |
| Packet encoding | `packetEncoding` (case-insensitive) | An allow-list of `xudp` / `packetaddr`. The xray-style `none`, and any garbage, is dropped silently — sing-box `NewOutbound` accepts only those two values, and anything else panics inside libbox. |
| Insecure | `insecure`, `allowInsecure` | Skip certificate verification |

### sing-box Outbound Mapping

```json
{
  "type": "vless",
  "tag": "<label>",
  "server": "<host>",
  "server_port": <port>,
  "uuid": "<UUID>",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "<sni>",
    "utls": { "enabled": true, "fingerprint": "<fp>" },
    "reality": {
      "enabled": true,
      "public_key": "<pbk>",
      "short_id": "<sid>"
    },
    "alpn": ["h2", "http/1.1"],
    "insecure": false
  },
  "transport": {
    "type": "ws",
    "path": "/path",
    "headers": { "Host": "<host>" }
  }
}
```

### Transport Options

| Type | Query `type=` | sing-box transport |
|------|---------------|-------------------|
| TCP (raw) | `tcp`, `raw`, empty | No transport block |
| TCP + HTTP headers | `tcp`/`raw` + `headerType=http` | `{"type": "http", "path": ..., "host": [...]}` |
| WebSocket | `ws` | `{"type": "ws", "path": ..., "headers": {"Host": ...}}` — a `?ed=N` in the path becomes `max_early_data` (§303, see the note below) |
| gRPC | `grpc` | `{"type": "grpc", "service_name": ...}` |
| HTTP/2 | `http` | `{"type": "http", "path": ..., "host": [...]}` |
| HTTPUpgrade | `httpupgrade` | `{"type": "httpupgrade", "path": ..., "host": ...}` |
| XHTTP | `xhttp` | `{"type": "xhttp", "path": ..., "host": ..., "mode": ...}` — native since §097, see [XHTTP transport](#xhttp-transport) |

> **Note on WebSocket early data (§303).** Xray specifies early data as a tail on the path — `"path": "/api/v2/channel?ed=2560"`. In sing-box that is a separate transport field, and a tail left in `path` goes into the HTTP request and produces a `404`. On import (from a URI, Xray JSON or sing-box JSON) the tail is stripped and `ed=N` becomes `max_early_data: N`. The header name is **not** filled in: an empty `early_data_header_name` means the core sends early data in the path (`transport/v2raywebsocket/conn.go`), exactly as Xray does for `?ed=`; filling in `Sec-WebSocket-Protocol` would switch to header-based mode and break compatibility with the server. An explicit `Sec-WebSocket-Protocol` in `wsSettings.headers` is still read as an ordinary header. `httpupgrade` has no such transport field, so the tail is stripped and `ed` is discarded. Emitting back to a URI glues `path?ed=N` together again so the round trip does not lose the parameter.
>
> **A second form — flat `ed`/`eh` (§320).** Some generators put the same parameters in separate keys: `?ed=2560&eh=Sec-WebSocket-Protocol` (in Xray JSON, `wsSettings.ed` / `.eh`). Here `eh` is given **explicitly**, meaning the provider is asking for header mode, so `early_data_header_name` is emitted — without it the core would append base64 to the path while the server waited for it in a header (`404`). A path tail takes priority over a flat `ed`: it addresses one specific path rather than the whole link. An `eh` with no `ed` is ignored — early data mode is enabled by `max_early_data > 0`, and a header name without a size means nothing. For `httpupgrade` the flat `ed`/`eh` are not read at all.
>
> **Double percent-encoding of the path (§320).** Aggregators hand out `path=%2F%252Fassignment`: `Uri.queryParameters` decodes exactly once, so `/%2Fassignment` used to reach the config instead of `//assignment`. The remainder is unwrapped (up to two passes) **before** the `?ed=` tail is stripped, otherwise a doubly-encoded `%253Fed%253D2560` is not recognised. The path itself is not validated — emoji, `//` and `@` are all legal, and the core prepends a leading slash itself when one is missing (`client.go`).

> **Note on XHTTP.** Since §097 (the core is the [`sing-box-lx`](https://github.com/Leadaxe/sing-box-lx) fork with the `with_xhttp` build tag) XHTTP is emitted **natively**: `{"type": "xhttp", ...}` with no substitution of the wire protocol. The former fallback to `httpupgrade` with an `UnsupportedTransportWarning` (Parser v2, up to and including v1.8.2) has been removed. The XHTTP-specific query keys are `mode`, `xPaddingBytes`/`x_padding_bytes` and `noGRPCHeader`/`no_grpc_header` (camelCase is the Xray URI form, snake_case is sing-box). It is incompatible with `flow=xtls-rprx-vision` — Vision only lives on bare TCP. Details: [XHTTP transport](#xhttp-transport).

### TLS Behavior

- If `pbk` is present **and is a valid X25519 public key** (base64/base64url, decodes to exactly 32 bytes): REALITY TLS is enabled. An invalid `pbk` (e.g. `pbk=enabled`/`true` from broken subscriptions) falls back to **plain TLS** with a parse warning instead of emitting a REALITY block the core rejects — before §169 one broken node used to poison the whole `config.json` at startup.
- `flow` is **never** auto-derived from REALITY (§115): it is taken verbatim from the link. Historically bare-TCP+REALITY without `flow` got a forced Vision, breaking valid `none` setups.
- `xtls-rprx-vision` is valid only on bare TLS. If a transport (ws/grpc/xhttp/http/httpupgrade) is present, the explicit `flow` is dropped with a `VisionWithTransportWarning` (the core would not bring up that combination). `emit()` writes `flow` only when it is exactly `xtls-rprx-vision` with no transport.
- If `security=none`: no TLS block.
- If port is a known plaintext port (80, 8080, 8880, 2052, 2082, 2086, 2095) and no explicit security: no TLS.
- Otherwise: TLS enabled with UTLS fingerprint (defaults to `random`).
- Special flow `xtls-rprx-vision-udp443`: normalized to `xtls-rprx-vision` + `packet_encoding: xudp` (the URI parser does **not** change the port; `server_port: 443` is forced only on the Xray-JSON path, section 11).

### packet_encoding allow-list

sing-box `vless.NewOutbound` accepts exactly three forms (see the [docs](https://sing-box.sagernet.org/configuration/outbound/vless/)):

| Value in the URI | In the outbound JSON | Meaning |
|----------------|-----------------|-----------|
| omitted, `""`, `none` | the field is not emitted | the sing-box default |
| `xudp` / `XUDP` / `Xudp` | `"packet_encoding": "xudp"` | XUDP wrapper (xray) |
| `packetaddr` / `PacketAddr` | `"packet_encoding": "packetaddr"` | packet-addr (v2ray 5+) |
| anything else | the field is not emitted, plus a warning in the log | protection against a libbox panic |

Xray-style subscriptions (xray-knife and others) put `packetEncoding=none` there meaning “no encoding”. sing-box does not understand that string and panics inside `format.ToString` while trying to report the error (`E.New` receives a `*string` pointer instead of a dereferenced string — an upstream bug). L×Box filters on input against the allow-list so that no invalid value ever leaves the app.

### Reference

- URI format: https://github.com/XTLS/Xray-core
- sing-box outbound: https://sing-box.sagernet.org/configuration/outbound/vless/

---

## 2. VMess

### URI Format (v2rayN)

```
vmess://BASE64_JSON#label
```

The base64 payload decodes to a JSON object:

```json
{
  "v": "2",
  "ps": "node name",
  "add": "server.com",
  "port": 443,
  "id": "uuid",
  "aid": 0,
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "example.com",
  "path": "/path",
  "tls": "tls",
  "sni": "example.com",
  "alpn": "h2,http/1.1",
  "fp": "chrome"
}
```

### Legacy Format

```
vmess://BASE64(method:uuid@host:port)#label
```

Decoded as `method:uuid@host:port`. The method is normalized to a sing-box VMess security value.

### Parsed Parameters

| Field | JSON key | Description |
|-------|----------|-------------|
| Server | `add` | Server address |
| Port | `port` | Server port |
| UUID | `id` | User ID |
| Name | `ps` | Display name |
| Security | `scy` or `security` | Encryption method |
| Alter ID | `aid` | Alter ID (0 for AEAD) |
| Network | `net` | Transport type |
| Path | `path` | Transport path |
| Host | `host` | Transport host |
| TLS | `tls` | `"tls"` to enable TLS |
| SNI | `sni` | TLS server name |
| ALPN | `alpn` | Comma-separated ALPN |
| Fingerprint | `fp` | UTLS fingerprint |
| Insecure | `insecure` | `"1"` to skip cert verify |

### Security Normalization

| Input | Normalized |
|-------|-----------|
| empty, `null`, `undefined` | `auto` |
| `chacha20-ietf-poly1305` | `chacha20-poly1305` |
| `auto`, `none`, `zero`, `aes-128-gcm`, `chacha20-poly1305`, `aes-128-ctr` | as-is |
| anything else | `auto` |

### Transport Mapping

| `net` value | sing-box transport |
|-------------|-------------------|
| `tcp` or empty | No transport |
| `ws` | `{"type": "ws", "path": ..., "headers": {"Host": ...}}` |
| `grpc` | `{"type": "grpc", "service_name": ...}` |
| `h2` | `{"type": "http", "path": ..., "host": [...]}` (forces TLS) |
| `http` | `{"type": "http", "path": ..., "host": [...]}` |
| `httpupgrade` | `{"type": "httpupgrade", "path": ..., "host": ...}` |
| `xhttp` | `{"type": "xhttp", "path": ..., "host": ...}` — native since §097, see [XHTTP transport](#xhttp-transport) |

### sing-box Outbound Mapping

```json
{
  "type": "vmess",
  "tag": "<ps>",
  "server": "<add>",
  "server_port": <port>,
  "uuid": "<id>",
  "security": "auto",
  "alter_id": 0,
  "tls": {
    "enabled": true,
    "server_name": "<sni>",
    "alpn": ["h2", "http/1.1"],
    "utls": { "enabled": true, "fingerprint": "<fp>" }
  },
  "transport": { "type": "ws", "path": "/path", "headers": {"Host": "..."} }
}
```

### Notes

- H2 transport forces TLS even if `tls` field is not `"tls"`.
- `alter_id` is only included if non-zero.

### Reference

- v2rayN format: https://github.com/XTLS/Xray-core
- sing-box outbound: https://sing-box.sagernet.org/configuration/outbound/vmess/

---

## 3. Trojan

### URI Format

```
trojan://password@host:port?query_params#label
```

### Parsed Parameters

| Parameter | Source | Description |
|-----------|--------|-------------|
| Password | userinfo | Trojan password |
| Security | `security` | `none` to disable TLS |
| SNI | `sni`, `peer`, `host` | TLS server name |
| Fingerprint | `fp` | UTLS fingerprint |
| ALPN | `alpn` | Comma-separated ALPN |
| Insecure | `insecure`, `allowInsecure` | Skip cert verify |
| Transport | `type` | `ws`, `grpc`, `http`, `httpupgrade`, `xhttp` (native since §097, see [XHTTP transport](#xhttp-transport)) |
| Path | `path` | Transport path |
| Host | `host` | Transport host |
| Service name | `serviceName` | gRPC service name |

### sing-box Outbound Mapping

```json
{
  "type": "trojan",
  "tag": "<label>",
  "server": "<host>",
  "server_port": <port>,
  "password": "<password>",
  "tls": {
    "enabled": true,
    "server_name": "<sni>",
    "utls": { "enabled": true, "fingerprint": "<fp>" },
    "alpn": ["h2", "http/1.1"]
  },
  "transport": { "type": "ws", "path": "/path", "headers": {"Host": "..."} }
}
```

### TLS Behavior

- TLS is enabled by default.
- If `security=none`: TLS block is `{"enabled": false}`.
- SNI fallback order: `sni` -> `peer` -> `host` -> server address.

### Reference

- sing-box outbound: https://sing-box.sagernet.org/configuration/outbound/trojan/

---

## 4. Shadowsocks

### URI Formats

**SIP002 (modern):**
```
ss://BASE64(method:password)@host:port#label
```

**Legacy:**
```
ss://BASE64(method:password@host:port)#label
```

Both formats are auto-detected. The base64 part before `@` is decoded first; if it contains `method:password` and the method is valid, SIP002 format is used. Otherwise the entire base64 is decoded as legacy format.

### Supported Methods

- `2022-blake3-aes-128-gcm`
- `2022-blake3-aes-256-gcm`
- `2022-blake3-chacha20-poly1305`
- `none`
- `aes-128-gcm`
- `aes-192-gcm`
- `aes-256-gcm`
- `chacha20-ietf-poly1305`
- `xchacha20-ietf-poly1305`

### SIP003 Plugins

The SIP002 URI query carries the SIP003 plugin:

| Query key | Format | Description |
|-----------|--------|-------------|
| `plugin` | `name;k=v;k=v…` | The plugin name (up to the first `;`) plus its options (`obfs-local`, `v2ray-plugin`, …) |
| `plugin_opts` | `k=v;k=v…` | The options on their own, when not passed inside `plugin` |

### sing-box Outbound Mapping

```json
{
  "type": "shadowsocks",
  "tag": "<label>",
  "server": "<host>",
  "server_port": <port>,
  "method": "<method>",
  "password": "<password>",
  "plugin": "obfs-local",
  "plugin_opts": "obfs=http;obfs-host=example.com"
}
```

### Notes

- Shadowsocks handles its own encryption; TLS is not applicable. Transport obfuscation is only possible through a SIP003 plugin (`plugin`/`plugin_opts` above) — those are emitted into the outbound when set.
- Unsupported methods cause a parse error (node is skipped).
- Base64 decoding tries both standard and URL-safe variants, with and without padding.
- Round-trip: `plugin`/`plugin_opts` are emitted into the sing-box JSON, but the share URI (`toUri`) does **not** write them — exporting to `ss://` loses the plugin.

### Reference

- SIP002 spec: https://shadowsocks.org/doc/sip002.html
- sing-box outbound: https://sing-box.sagernet.org/configuration/outbound/shadowsocks/

---

## 5. Hysteria2

### URI Format

```
hysteria2://password@host:port?query_params#label
hy2://password@host:port?query_params#label
```

Both `hysteria2://` and `hy2://` schemes are supported (the latter is normalized to the former).

### Parsed Parameters

| Parameter | Query key | Description |
|-----------|-----------|-------------|
| Password | userinfo | Authentication password |
| SNI | `sni` | TLS server name |
| Insecure | `insecure`, `allowInsecure`, `skip-cert-verify` | Skip cert verify |
| Fingerprint | `fp` or `fingerprint` | UTLS fingerprint |
| ALPN | `alpn` | Comma-separated ALPN |
| Obfuscation | `obfs` | Obfuscation type (only `salamander` supported) |
| Obfs password | `obfs-password` | Salamander obfuscation password |
| Up bandwidth | `up_mbps` | Bandwidth hint, Mbps (int, optional; §084) |
| Down bandwidth | `down_mbps` | Bandwidth hint, Mbps (int, optional; §084) |

### sing-box Outbound Mapping

```json
{
  "type": "hysteria2",
  "tag": "<label>",
  "server": "<host>",
  "server_port": <port>,
  "password": "<password>",
  "up_mbps": 100,
  "down_mbps": 100,
  "obfs": {
    "type": "salamander",
    "password": "<obfs-password>"
  },
  "tls": {
    "enabled": true,
    "server_name": "<sni>",
    "insecure": false,
    "utls": { "enabled": true, "fingerprint": "<fp>" },
    "alpn": ["h3"]
  }
}
```

### Notes

- TLS is always enabled (Hysteria2 runs over QUIC).
- Port hopping (`mport`/`ports` → `server_ports`) is **not** implemented — the parser does not read those keys and `server_ports` is never emitted.
- `up_mbps`/`down_mbps` are parsed and round-tripped (URI/JSON), emitted only when present.
- Invalid SNI values (e.g. emoji-only) are replaced with the server address.

### Reference

- sing-box outbound: https://sing-box.sagernet.org/configuration/outbound/hysteria2/

---

## 5.5 NaïveProxy

### URI Format

```
naive+https://<user>:<pass>@<host>:<port>/?<params>#<label>
```

Following the [DuckSoft 2020 de-facto specification](https://gist.github.com/DuckSoft/ca03913b0a26fc77a1da4d01cc6ab2f1) (used by NekoBox, NaiveGUI, v2rayN, Hiddify).

| Component | Purpose | Default |
|-----------|---------|---------|
| `host` | Server address (FQDN or IP, IPv6 in brackets) | required |
| `port` | TCP port | `443` |
| userinfo: `user:pass` | HTTP Basic credentials | optional |
| userinfo: `pass` (no colon) | Treated as **password-only** auth | optional |
| Query: `extra-headers=<urlencoded>` | `Header1: Value1\r\nHeader2: Value2` after URL-decoding (`\r\n` → `%0D%0A`, `:` → `%3A`) | empty |
| Query: `padding=true\|false` | **Ignored with log warning** — no sing-box equivalent | n/a |
| Fragment `#label` | Display name (UTF-8, URL-decoded) | derived from `host:port` |

### Examples

```
naive+https://user:pass@server.example.com:443/?padding=false#JP-01
naive+https://server.example.com:8443                                      # anonymous
naive+https://onlypass@server.example.com                                  # password-only
naive+https://u:p@host?extra-headers=X-User%3Aalice%0D%0AX-Token%3Axyz
naive+https://u:p@host:443/?extra-headers=X-Forwarded-Proto%3Ahttps#%E2%9C%85%20DE
```

### Generated sing-box Outbound

```json
{
  "type": "naive",
  "tag": "<label or naive-host-port>",
  "server": "<host>",
  "server_port": <port>,
  "username": "<user>",
  "password": "<pass>",
  "extra_headers": { "Header": "Value" },
  "tls": { "enabled": true, "server_name": "<host>" }
}
```

### Behaviour Notes

- TLS is **always** enabled — `tls.enabled = true`, `tls.server_name = host`. NaïveProxy without TLS is meaningless.
- The naive outbound in sing-box rejects `alpn`, `insecure`, `utls`, `reality`, `min_version`, `cipher_suites`, `fragment`. The parser deliberately leaves them unset; users wanting custom TLS edit the JSON directly via the config editor (spec 007).
- `network`/`udp_over_tcp`/`quic` fields are **not** emitted in v1 — the URI standard does not carry them and naive QUIC mode is deferred (see spec 037 §10).
- `extra_headers` keys are sorted lexicographically when emitted to JSON or back to URI form, for deterministic round-trip.
- `padding` is silently dropped because sing-box has no corresponding option.

### Build-tag Requirement

NaïveProxy outbound is gated behind the sing-box build tag `with_naive_outbound`. Since §097/§104 L×Box bundles its own fork core `sing-box-lx` (local `app/android/libbox.aar`, pin in [`app/android/libbox.version`](../app/android/libbox.version); the old Maven `com.github.singbox-android:libbox` dependency is gone), built **with** this tag — see [spec 037 §2](spec/features/037%20naive%20proxy/spec.md#2-build-tag-в-libbox--проверено) for verification details. If a future core build ever ships without naive, `BoxVpnClient` surfaces a `NaiveBuildTagWarning` per node when sing-box returns the upstream error string `naive outbound is not included in this build, rebuild with -tags with_naive_outbound`.

### Reference

- sing-box outbound: https://sing-box.sagernet.org/configuration/outbound/naive/
- DuckSoft URI spec: https://gist.github.com/DuckSoft/ca03913b0a26fc77a1da4d01cc6ab2f1
- LxBox spec: [`docs/spec/features/037 naive proxy/spec.md`](spec/features/037%20naive%20proxy/spec.md)

---

## 5.6 AnyTLS

Anti-DPI protocol (sing-box `type: "anytls"`, core ≥ 1.12.0): native
multiplexing with flexible padding over a plain TLS connection. Structurally
close to Trojan — `password` + TLS over TCP, no separate transport wrapper
(multiplexing is internal). Added in §269.

### URI Format

```
anytls://<password>@<host>:<port>/?<params>#<label>
```

AnyTLS has **no standardized share-URI** (sing-box documents JSON only). L×Box
accepts the de-facto Trojan-style form used by Karing / v2rayN mods.

| Component | Purpose | Default |
|-----------|---------|---------|
| userinfo `password` | Auth credential | required (empty → parse fails) |
| `host` | Server address (FQDN or IP, IPv6 in brackets) | required |
| `port` | TCP port | `443` |
| Query: `sni` / `peer` / `host` | TLS server name | `host` |
| Query: `fp` | uTLS fingerprint | `random` |
| Query: `pbk` / `sid` | REALITY public key / short ID (valid X25519 → REALITY, else plain TLS, §169) | none |
| Query: `alpn` | comma-separated ALPN list | none |
| Query: `allowInsecure` / `insecure` | Skip cert verify (warns) | `false` |
| Query: `idle_session_check_interval` | Go-duration (`"30s"`) | core default (30s) |
| Query: `idle_session_timeout` | Go-duration (`"30s"`) | core default (30s) |
| Query: `min_idle_session` | int | core default (0) |
| Fragment `#label` | Display name | derived from `host:port` |

### Examples

```
anytls://password@server.example.com:8443#AT-01
anytls://pw@server.example.com                                             # port 443
anytls://pw@h.example:8443?sni=cdn.example.com&alpn=h2,http/1.1#TLS-tuned
anytls://pw@h.example:8443?idle_session_timeout=30s&min_idle_session=2#Idle
```

### Generated sing-box Outbound

```json
{
  "type": "anytls",
  "tag": "<label or anytls-host-port>",
  "server": "<host>",
  "server_port": <port>,
  "password": "<pass>",
  "tls": { "enabled": true, "server_name": "<host>" },
  "idle_session_timeout": "30s",
  "min_idle_session": 2
}
```

### Behaviour Notes

- TLS is **always** enabled — `security=none` in the URI is ignored, and a
  sing-box JSON entry without a `tls` block is coerced to `enabled: true`
  (`server_name = host`). AnyTLS without TLS is meaningless.
- idle fields (`idle_session_check_interval` / `idle_session_timeout` /
  `min_idle_session`) are optional; when absent they are omitted from the
  outbound so the core applies its own defaults. They round-trip through the
  URI as query params.
- No `transport` block — AnyTLS multiplexes internally, unlike Trojan/VLESS.

### Reference

- sing-box outbound: https://sing-box.sagernet.org/configuration/outbound/anytls/
- LxBox spec: [`docs/spec/tasks/269-anytls-protocol.md`](spec/tasks/269-anytls-protocol.md)

---

## 6. SSH

### URI Format

```
ssh://user:password@host:port?query_params#label
```

Default port: **22**.

### Parsed Parameters

| Parameter | Source | Description |
|-----------|--------|-------------|
| User | userinfo (before `:`) | SSH username (defaults to `root`) |
| Password | userinfo (after `:`) | SSH password |
| Private key | `private_key` | URL-encoded private key content |
| Key passphrase | `private_key_passphrase` | Passphrase for private key |
| Host keys | `host_key` | Comma-separated host key strings |
| Host key algorithms | `host_key_algorithms` | Comma-separated CSV → array of allowed host-key algorithms |

### sing-box Outbound Mapping

```json
{
  "type": "ssh",
  "tag": "<label>",
  "server": "<host>",
  "server_port": <port>,
  "user": "<user>",
  "password": "<password>",
  "private_key": "<key_content>",
  "private_key_passphrase": "<passphrase>",
  "host_key": ["ssh-rsa AAAA..."],
  "host_key_algorithms": ["ssh-ed25519", "rsa-sha2-256"]
}
```

### Notes

- Only password or private key authentication. No agent forwarding.
- `host_key` and `host_key_algorithms` are each split by comma into an array.
- NB: `parseSingboxEntry` (section 10, raw sing-box JSON) currently drops `host_key_algorithms` on round-trip — only the URI parser reads it.

### Reference

- sing-box outbound: https://sing-box.sagernet.org/configuration/outbound/ssh/

---

## 7. SOCKS

### URI Format

```
socks://user:password@host:port#label
socks5://user:password@host:port#label
```

Both `socks://` and `socks5://` are accepted. Default port: **1080**.

### Parsed Parameters

| Parameter | Source | Description |
|-----------|--------|-------------|
| Username | userinfo (before `:`) | SOCKS username |
| Password | userinfo (after `:`) | SOCKS password |

### sing-box Outbound Mapping

```json
{
  "type": "socks",
  "tag": "<label>",
  "server": "<host>",
  "server_port": <port>,
  "version": "5",
  "username": "<user>",
  "password": "<password>"
}
```

### Notes

- Always mapped to SOCKS version 5.
- Username and password are optional.

### Reference

- sing-box outbound: https://sing-box.sagernet.org/configuration/outbound/socks/

---

## 7.5. HTTP(S) proxy

### URI Format

```
proxy-http://user:password@host:port?path=...&headers=...#label
proxy-https://user:password@host:port?path=...&headers=...&sni=...&fp=...&alpn=...&allowInsecure=1#label
```

Custom schemes are used instead of bare `http://` / `https://` (§222): the bare
schemes are intercepted by `isSubscriptionUrl` **before** `isDirectLink` (a pasted
link would become a “subscription”), and promotional lines like `https://t.me/...`
inside subscription bodies would turn into junk nodes. The scheme is the TLS
discriminator: `proxy-https://` → `tls.enabled=true`. The default ports are **80**
and **443** respectively.

### Parsed Parameters

| Parameter | Source | Description |
|-----------|--------|-------------|
| Username | userinfo (before `:`) | Basic-auth username (`user`, `user:pass`, `:pass`) |
| Password | userinfo (after `:`) | Basic-auth password |
| Path | `path` | The sing-box `path` (a query parameter rather than a URI path — it round-trips more easily) |
| Headers | `headers` | Serialized like naive `extra-headers`: `Header1: V1\r\nHeader2: V2`, URL-encoded |
| SNI | `sni` / `peer` / `host` | `proxy-https://` only; the default is the host (the trojan convention, `parseTrojanTls`) |
| Fingerprint | `fp` | The uTLS fingerprint (`proxy-https://` only) |
| ALPN | `alpn` | Comma-separated (`proxy-https://` only) |
| Insecure | `allowInsecure` and its aliases | `tls.insecure` → `InsecureTlsWarning` |

### sing-box Outbound Mapping

```json
{
  "type": "http",
  "tag": "<label>",
  "server": "<host>",
  "server_port": <port>,
  "username": "<user>",
  "password": "<password>",
  "path": "<path>",
  "headers": { "<Header>": "<Value>" },
  "tls": { "enabled": true, "server_name": "<sni>" }
}
```

### Notes

- Every field except `server` / `server_port` is optional — empty ones are not emitted.
- The JSON path (`parseSingboxEntry`) accepts listable `headers` values
  (string | [string, ...]) — just like naive `extra_headers`.
- REALITY does not travel in the URI (as with trojan) — the JSON path preserves it.
- The wizard's `HTTP` tab (§222): Tag/Host/Port/Username/Password plus an
  “HTTPS (TLS)” switch; fine-grained TLS settings go through the node's JSON editor.

### Reference

- sing-box outbound: https://sing-box.sagernet.org/configuration/outbound/http/

---

## 8. WireGuard

### URI Format

```
wireguard://PRIVATE_KEY@host:port?publickey=...&address=...&...#label
```

The private key is URL-encoded in the userinfo position. Default port: **51820**.

Scheme aliases: `wireguard://`, `wg://` and `awg://` — all three are parsed by the same endpoint logic (§097). The presence of AWG fields in the query (under any of the schemes) makes the node an AmneziaWG one — see [section 8.5](#85-amneziawg-awg-awg2).

### Parsed Parameters

| Parameter | Query key | Description |
|-----------|-----------|-------------|
| Private key | userinfo | WireGuard private key |
| Public key | `publickey` | Peer public key (required) |
| Address | `address` | Comma-separated local addresses (required) |
| MTU | `mtu` | The MTU value (default 1408; AWG nodes are clamped to `min(mtu, 1280)`, see [8.5](#85-amneziawg-awg-awg2)) |
| Pre-shared key | `presharedkey` | Peer pre-shared key |
| Keepalive | `keepalive` | Persistent keepalive interval (seconds) |
| Allowed IPs | `allowedips` | Peer allowed IPs (default: `0.0.0.0/0, ::/0`) |
| Reserved / client_id | `reserved` or `client_id` | Cloudflare WARP client_id — 3 bytes, decimal `b0,b1,b2` or base64 (§025/§126). Emitted **per-peer** as `reserved: [b0,b1,b2]`. Without it a WARP handshake may complete but no data passes. |

### sing-box Endpoint Mapping

**Important**: In sing-box 1.12+, WireGuard uses the **endpoint** type, not outbound.

```json
{
  "type": "wireguard",
  "tag": "<label>",
  "mtu": 1408,
  "address": ["10.0.0.2/32", "fd00::2/128"],
  "private_key": "<private_key>",
  "peers": [
    {
      "address": "<host>",
      "port": <port>,
      "public_key": "<publickey>",
      "pre_shared_key": "<presharedkey>",
      "allowed_ips": ["0.0.0.0/0", "::/0"],
      "persistent_keepalive_interval": 25
    }
  ]
}
```

### Notes

- WireGuard is placed in the `endpoints` array in the sing-box config, not `outbounds`.
- The `address` field is split by comma into an array of CIDR strings.
- `allowed_ips` defaults to `0.0.0.0/0, ::/0` (route all traffic).
- `persistent_keepalive_interval` is only set when `keepalive` is present.

### Reference

- sing-box endpoint: https://sing-box.sagernet.org/configuration/endpoint/wireguard/

---

## 8.5 AmneziaWG (AWG, AWG2)

Added in §097 (the [`097`](./spec/features/097%20awg2-amneziawg2/spec.md) spec) together with the switch of the bundled core to the [`sing-box-lx`](https://github.com/Leadaxe/sing-box-lx) fork (the `with_awg` build tag, `option.AmneziaWGOptions`; the version pin is `app/android/libbox.version`). AmneziaWG is WireGuard plus obfuscation: the same keys, peers and handshake, plus a set of parameters that disguise WG traffic from DPI.

Every field is **config-only** — nothing is negotiated over the wire, and the values **must match on the client and the server**. A mismatch fails silently: the handshake may succeed while no data flows.

### URI Format

```
awg://PRIVATE_KEY@host:port?publickey=...&address=...&jc=4&jmin=40&jmax=70&s1=0&s2=0&h1=...&i1=...#label
```

`awg://` is a scheme alias for the same endpoint logic as `wireguard://` / `wg://` (section 8). AWG fields are recognised in the query of **any** of the three schemes: with at least one field present the node is AmneziaWG (`WireguardSpec.awg != null`), and with none it is ordinary WG (backward compatible, with unchanged behaviour).

### Fields

| Key | Type | Purpose | Level |
|------|-----|-----------|--------|
| `jc`, `jmin`, `jmax` | int | Junk packets before the handshake: the count and the size bounds | AWG 1.0 |
| `s1`, `s2` | int | A junk prefix on the init and response handshake packets | AWG 1.0 |
| `s3`, `s4` | int | A junk prefix on the cookie reply (`s3`) and on transport/data packets (`s4`) | AWG 2.0 |
| `h1`–`h4` | int \| `"N-M"` | Magic headers — substituting the packet types. A single `N` is 1.0; a range `N-M` is ranged headers (§112) | AWG 1.0 / 2.0 |
| `i1`–`i5` | string | CPS decoy packets, in the tag format `<b 0xHEX><r N>…` | AWG 1.5 |
| `id`, `ip`, `ib` | string | Masquerade sugar (WireSock-style) over `i1` — the core expands it into an `i1` CPS packet itself. **Mutually exclusive with an explicit `i1`** (both at once is a core startup error). §143 | AWG 1.5 |

- The numeric fields are uint32 and are emitted as a JSON **number**.
- `h1`–`h4` (§112): a value of `N` becomes an `int` (the numeric string `"5"` is normalised to `int 5`), while a range `N-M` becomes a `String` and is emitted as a JSON **string** (the core contract from `lx.6` onwards). We do not validate further (start ≤ end, uint32, non-overlapping ranges) — the core does that with an explicit startup error, and dropping silently here would produce a quietly broken handshake.
- `i1`–`i5` are strings and **case is preserved** exactly (they are case-sensitive and must not be altered).
- A malformed number in the query means the field is skipped silently (forward compatibility, as with `mtu` and `keepalive`) and parsing the node does not fail. For `h*`, “malformed” means it fits neither `N` nor `N-M`.

> **`reserved` ≠ `reserved_zero[3]` — different things sharing the same bytes.**
> In LxBox terminology `reserved` is the **Cloudflare WARP client_id**, 3 bytes, emitted **per peer** (section 8, `reserved: [b0,b1,b2]`).
> In the WireGuard spec `reserved_zero[3]` means bytes `[1..3]` of the packet header, right after the message type at `[0]`; the magic headers `h1`–`h4` write **all 4 bytes** `[0..3]` at once (as a uint32), which is to say they overwrite exactly that `reserved_zero`.
> The bytes are physically the same; the meaning is not. Conflating them has already caused a real bug: unconditionally clearing `b[1:4]` for the WARP client_id wiped out ranged magic (fixed in core `lx.9`). When working with either field, be explicit about which one you mean.

The model is the `Awg` class in [`node_spec.dart`](../app/lib/models/node_spec.dart) (`WireguardSpec.awg`, where `null` means ordinary WG). The round trip is complete: URI / INI / sing-box JSON → `Awg` → `emit()` / `toUri()` with no loss.

### MTU clamp

For AWG nodes the client MTU is **clamped to `min(mtu, 1280)`**; with no explicit `mtu` the default is **1280** (`awgClampMtu` in [`uri_utils.dart`](../app/lib/services/parser/uri_utils.dart)). Ordinary WG is left alone (the default stays 1408).

Why 1280:
- it is both AmneziaWG's own recommended client MTU and the minimum IPv6 MTU, so it is safe on any path (PPPoE 1492, mobile, nested tunnels);
- the “exact” ceiling of `1500 − 60 − max(s3, s4)` is fragile — it assumes a path MTU of exactly 1500, which AWG users usually do not have;
- the risks are asymmetric: setting it too low only makes packets slightly smaller, while setting it too high fails silently (the handshake works, no data flows).

An explicitly lower MTU (≤ 1280) is respected as given.

### INI

AWG fields are read from the `[Interface]` section of a standard WireGuard INI (see section 9):

```ini
[Interface]
PrivateKey = <base64_key>
Address = 10.8.1.2/32
Jc = 4
Jmin = 40
Jmax = 70
S1 = 0
S2 = 0
H1 = 1234567890
I1 = <b 0xffffffff><r 16>

[Peer]
...
```

Keys are case-insensitive (`Jc` ≙ `jc`), while the case of the **value** is preserved. Converting INI → URI passes the fields through into the query (`i*` are URL-escaped).

### sing-box-lx Endpoint Mapping

The fields go into the **root of the endpoint** (next to `mtu` / `address` / `private_key`, **not** per peer):

```jsonc
{
  "type": "wireguard",
  "tag": "<label>",
  "mtu": 1280,
  "address": ["10.8.1.2/32"],
  "private_key": "<private_key>",
  "peers": [ /* as in section 8 */ ],
  "jc": 4, "jmin": 40, "jmax": 70,
  "s1": 0, "s2": 0,
  "h1": 1234567890, "h2": 1234567891, "h3": 1234567892, "h4": 1234567893,
  "i1": "<b 0xffffffff><r 16>"
}
```

Ranged headers (§112) — ranges as strings, single values as numbers, and the two can be mixed:

```jsonc
  "h1": "43613244-384550127", "h2": "826869626-2105069164",
  "h3": "2124774725-2141151992", "h4": "2144594503-2146278491",
```

Parsing back (the JSON editor, Smart-Paste) collects the same fields from the root of the entry (`Awg.fromJson` inside `parseSingboxEntry`).

### AmneziaWG versions: awg / awg1.5 / awg2 (§148)

A node's subtitle and the variant filter (§102/§103) tell the **AmneziaWG version** apart structurally, by which fields are present in the config ([`config_node.dart`](../app/lib/models/config_node.dart)). This matches Amnezia's own versioning (they publish explicit config-format versions, with migration instructions for 1.0→1.5). The verdict comes from the highest marker present (priority top to bottom):

| Label | Version | What the version added | The marker in the config |
|-------|--------|---------------------|------------------|
| `awg2` | 2.0 | Dynamics instead of static values: header ranges and random padding on transport messages | a ranged `h1`–`h4` header (`"N-M"`, §112) **or** `s3`/`s4` |
| `awg1.5` | 1.5 | Signature packets (CPS) — mimicry of a real protocol (a hex snapshot, e.g. a QUIC Initial), sent before the junk chain | any of `i1`–`i5` |
| `awg` | 1.0 | Basic obfuscation on top of WireGuard | `jc`/`jmin`/`jmax` (junk), `s1`/`s2` (init padding), single-valued `h1`–`h4` (magic headers) |
| — | — | ordinary WG | no AWG field at all → the security slot is empty |

**The 1.0→1.5 watershed** is the appearance of `I1` (Amnezia's official instruction: “add `I1` after the `H4` line”). `I2`–`I5` are additional signature packets of that same 1.5. **The 1.5→2.0 watershed** is the move from static `H1`–`H4` to dynamic ranges (plus `s3`/`s4` padding); a real 2.0 export can carry ranged H, `s3`/`s4` and `i*` all at once — the highest marker (2.0) wins.

The `+` suffix is added when the masquerade sugar `ip`/`id`/`ib` is present (§143). Core 009 expands those into an `i1` CPS packet itself, which means masquerade **on its own equals version 1.5**. That is why `awg+` cannot exist:

| Base (before the suffix) | + masquerade |
|--------------------|--------------|
| `awg2` (2.0) | `awg2+` |
| `awg1.5` / `awg` / no AWG fields | `awg1.5+` |

The masquerade fields are mutually exclusive with an explicit `i1` at the core level (both at once is a startup error), but the label is derived from the raw JSON before validation — which is why the suffix is checked independently.

### The core requirement

This only works on the bundled `sing-box-lx` fork core (the `with_awg` build tag). Stock upstream sing-box does not know these fields and **rejects the config at load time**. Ranged headers (`"h1": "N-M"` as a string) require a core of at least `v1.13.13-lx.6` — an older core dies unmarshalling such a config (which is why §112 re-pins [libbox.version](../app/android/libbox.version) in the same commit).

### Reference

- AmneziaWG: https://docs.amnezia.org/documentation/amnezia-wg/
- The core fork: https://github.com/Leadaxe/sing-box-lx

---

## 9. WireGuard INI Config

### Format

Standard WireGuard configuration file format:

```ini
[Interface]
PrivateKey = <base64_key>
Address = 10.0.0.2/32, fd00::2/128
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = <base64_key>
Endpoint = server.com:51820
PresharedKey = <base64_key>
PersistentKeepalive = 25
```

### Detection

Auto-detected when input contains both `[Interface]` and `[Peer]` sections.

### Conversion

The INI config is converted to a `wireguard://` URI internally using `wireGuardConfigToUri()`:

1. Parse `[Interface]`: `PrivateKey`, `Address`, `MTU` plus the AWG fields `Jc`/`Jmin`/`Jmax`/`S1`–`S4`/`H1`–`H4`/`I1`–`I5` (§097, see [8.5](#85-amneziawg-awg-awg2); keys are case-insensitive, the case of the value is preserved, and `i*` are URL-escaped in the query)
2. Parse `[Peer]`: `PublicKey`, `Endpoint` (host:port), `PresharedKey`, `PersistentKeepalive`, `Reserved`/`ClientId` (WARP client_id, §126)
3. Construct: `wireguard://host:port?publickey=...&privatekey=...&address=...&...#WireGuard`
4. The resulting URI is then parsed by the standard WireGuard parser (see section 8).

### Required Fields

- `PrivateKey` (in `[Interface]`)
- `PublicKey` (in `[Peer]`)
- `Endpoint` (in `[Peer]`)

Missing any of these throws a `FormatException`.

---

## 9.2 Amnezia vpn:// Link

Added in §110 (the task spec [`110`](./spec/tasks/110-amnezia-vpn-link-import.md)). This is Amnezia's container share format for awg2; a `.vpn` file holds the same string.

### Format

```
vpn://<base64url( qCompress(JSON, 8) )>
```

- base64url **without padding** (the `-_` alphabet, `Base64UrlEncoding | OmitTrailingEquals`); the padded and standard variants are accepted too (`decodeBase64Safe`).
- `qCompress` is 4 big-endian bytes (the uncompressed length) followed by a standard zlib stream. An uncompressed payload (bare base64 JSON) is the fallback, matching Amnezia's `importController`.
- Inside the JSON: `containers[]` → the `awg` / `wireguard` sub-objects → `last_config` (a JSON string; we defensively accept an object too) → `config`, a ready-made WG/AWG INI (section 9). The `$PRIMARY_DNS` / `$SECONDARY_DNS` placeholders are filled in from the root-level `dns1` / `dns2`.

### Detection / Flow

Step 0 in `decode()` ([body_decoder.dart](../app/lib/services/parser/body_decoder.dart)): `startsWith('vpn://')` → [`amnezia_link.dart`](../app/lib/services/parser/amnezia_link.dart) → `AmneziaConfig(iniTexts)` → `parseAll` → each INI through `parseWireguardIni`. Every WG/AWG container in the link becomes a node of **one** `UserServer` (`rawBody` is the original link, and persistence re-parses through the same path); Amnezia's other protocols (openvpn/xray/cloak/…) are skipped; if there is no WG/AWG at all the result is a `DecodeFailure` with an explicit reason.

### Limits

- The link must be ≤ 64 KiB (`maxURILength`) and the claimed uncompressed size ≤ 4 MiB — protection against zlib bombs.
- Reference: [config-decoder](https://github.com/amnezia-vpn/config-decoder) (the reference implementation of the format), plus `exportController.cpp` / `importController.cpp` in [amnezia-client](https://github.com/amnezia-vpn/amnezia-client).

---

## 9.5 TUIC v5

Added in Parser v2 (the [`026`](./spec/features/026%20parser%20v2/spec.md) spec). v1 had no TUIC parsing at all.

### URI format

```
tuic://<UUID>:<PASSWORD>@<host>:<port>?<params>#<label>
```

### Parameters

| Key | Value |
|------|---------|
| `congestion_control` | `bbr` \| `cubic` \| `new_reno` (default `cubic`) |
| `udp_relay_mode` | `native` \| `quic` (default `native`) |
| `alpn` | A CSV list (`h3`, `h3-29`) |
| `sni` | The SNI for TLS |
| `allow_insecure` / `insecure` | `1` \| `true` — skip certificate verification |
| `disable_sni` | `1` — do not send an SNI |
| `reduce_rtt` | `1` — enable 0-RTT / early data |

### sing-box outbound (emit)

```json
{
  "type": "tuic",
  "tag": "<tag>",
  "server": "<host>",
  "server_port": <port>,
  "uuid": "<UUID>",
  "password": "<PASSWORD>",
  "congestion_control": "bbr",
  "udp_relay_mode": "native",
  "zero_rtt_handshake": true,
  "tls": {
    "enabled": true,
    "server_name": "<sni>",
    "alpn": ["h3"],
    "insecure": false
  }
}
```

### Reference

- sing-box outbound: https://sing-box.sagernet.org/configuration/outbound/tuic/

---

## 9.6 MASQUE (Cloudflare WARP)

A WARP transport following **RFC 9484 (CONNECT-IP over MASQUE)** — an IP tunnel
over QUIC/HTTP-3 with a fallback to HTTP/2. Added in **v2.9.0** (§130; sing-box-lx
core SPEC 021, `type: masque` through `outbound.Register`). It gives access to a
different pool of Cloudflare exit nodes (often foreign IPs) and looks to DPI like
ordinary HTTPS/QUIC to Cloudflare on 443.

MASQUE nodes are created through the **Get WARP** wizard (an ECDSA P-256 key is
registered on the device, `_addMasqueNode` → `account.toMasqueUri()` →
`parseMasqueUri`), but they round-trip fully through a `masque://` URI — they are
parsed from a paste or a subscription just like every other protocol.

> **Importing third-party Clash YAML MASQUE configs is not supported** — L×Box
> does not parse Clash YAML at all (for any protocol). MASQUE comes up only
> through our own registration or from a `masque://` URI.

### URI Format

```
masque://<privKeyDer>@<host>:<port>?publickey=<serverPubDer>&address=<v4,v6>&profile=cloudflare&vhttp=h3[&sni=...][&disable_sni=1][&mtu=1280][&idle_timeout=5m][&keep_alive=30s]#<label>
```

The keys are base64(DER) ECDSA P-256: `userInfo` (before the `@`) is our private
key (SEC1) and `publickey` is the server's public key (PKIX, used for pinning). A
raw `/` inside the base64 is escaped (§106). The default port is `443`.

### Parsed Parameters

| Key | Value |
|------|----------|
| userInfo / `privatekey` / `private_key` | base64(SEC1 DER) of the private key (**a secret**), required |
| `publickey` / `public_key` | base64(PKIX DER) of the server's public key, required |
| `address` | A CSV of the tunnel's local addresses (`v4,v6`), required; the CIDR is added automatically (`/32` / `/128`) |
| `profile` | `cloudflare` (default) \| `standard` |
| `vhttp` | The HTTP version: `h3` for QUIC (the default) \| `h2`. §393; the legacy name `network` is still accepted on input |
| `sni` | The TLS SNI; empty means the core's default (`www.cloudflare.com` since lx.25-rc.4) |
| `disable_sni` | `1`/`true` produces a ClientHello with no SNI. NOT a synonym for an empty `sni` (which is replaced by the profile's default). §393 |
| `mtu` | int, default `1280` |
| `idle_timeout` | A Go duration for the tunnel's idle-suspend (empty means the core's default of `5m`; a negative value disables it, §128) |
| `keep_alive` | A Go duration for the QUIC keepalive (empty means `30s`; `vhttp=h3` only) |

**§393 — two generations of names.** The emitter writes only the new ones
(`vhttp`, a nested `tls{}`); the input side also accepts the old ones (`network`,
a flat `sni`), because URIs issued before the migration and links from elsewhere
are written that way. When both names are present, the new one wins. The core dies
on such a pair when the values DIFFER, which is why we never write the old and the
new name at the same time.

The key is named `vhttp` and NOT `transport`: in every other protocol
`transport` is an object `{type: ws|grpc|…}`, an entirely different thing. Here
the value is the HTTP version (`h3`/`h2`) as a flat string.

### sing-box Outbound Mapping

It is emitted as an **Outbound** (not an Endpoint, unlike WireGuard). `ip` and
`ipv6` are split out of `address` by looking for a `:` (v6). `mtu`,
`idle_timeout` and `keep_alive_period` are written only when non-empty; the
`tls{}` block appears only when an SNI or `disable_sni` is set.

The core's schema (§393, kernel SPEC 062): the HTTP version under the `vhttp`
key, and the TLS options in a nested `tls{}`.

```json
{
  "type": "masque",
  "tag": "<tag>",
  "server": "<host>",
  "server_port": 443,
  "profile": "cloudflare",
  "vhttp": "h3",
  "private_key": "<privKeyDer>",
  "public_key": "<serverPubDer>",
  "ip": "172.16.0.2/32",
  "ipv6": "2606:4700:110:...::/128",
  "tls": { "server_name": "www.cloudflare.com" },
  "mtu": 1280,
  "idle_timeout": "5m",
  "keep_alive_period": "30s"
}
```

| deprecated | current |
|---|---|
| `network` | `vhttp` |
| `sni` | `tls.server_name` |
| `skip_cert_verify` | `tls.insecure` |
| `fragment` / `record_fragment` | `tls.fragment` / `tls.record_fragment` |
| `fragment_fallback_delay` | `tls.fragment_fallback_delay` |

The core accepts the old names until `v1.14.0-lx.30`, printing one warning per
outbound. The interim name `transport` (which lived for a single core rc) is not
supported in the client: it never went out.

**Fragmentation.** The global `tls_fragment` (§270) is applied to masque only
when `vhttp: h2`: with h3 there is nothing to fragment (QUIC does not carry TLS
over TCP), the core ignores such fields with a warning, and the builder skips h3
nodes silently.

### Reference

- RFC 9484 (CONNECT-IP over MASQUE)
- §130 spec: [docs/spec/features/130 masque-warp-transport/spec.md](spec/features/130%20masque-warp-transport/spec.md)
- §393 (the schema migration): [docs/spec/tasks/393-masque-config-schema-migration.md](spec/tasks/393-masque-config-schema-migration.md)
- The sing-box-lx core: SPEC 021 (`type: masque`), SPEC 062 (the config schema)
- [WARP integration (§025)](spec/features/025%20warp%20integration/spec.md)

---

## 10. JSON Outbound

### Format

Raw sing-box JSON pasted directly, or served as a subscription body. Four shapes are accepted (§368):

| shape | example | detection |
|---|---|---|
| single outbound | `{"type":"vless",…}` | object with `type` |
| array of outbounds | `[{"type":"vless",…},…]` | array whose first element has `type` |
| whole config | `{"log":…,"outbounds":[…],"route":…}` | object with `outbounds` or `endpoints`, no `type` |
| array of configs | `[{"outbounds":[…]},…]` | array of elements with `outbounds` carrying `type` (vs `protocol` → Xray, section 11) |

```json
{
  "type": "vless",
  "tag": "my-server",
  "server": "example.com",
  "server_port": 443,
  "uuid": "...",
  "tls": { "enabled": true }
}
```

All four normalize to a single parser (`parseSingboxConfigs`); the single-outbound case is an array of one config, so the passes below degenerate but the code path is the same.

### What is imported from a whole config

| section | imported |
|---|---|
| `outbounds`, `endpoints` | yes — nodes and groups |
| `route`, `dns`, `inbounds`, `log`, `experimental` | **no** |

Routing and DNS are generated by the app from its own settings, so a foreign `route` block has nowhere to map. The confirmation dialog lists the sections actually present that were left behind — the drop is never silent.

`direct`, `block` and `dns` outbounds are service entries and do not become nodes. `urltest` and `selector` become auto-select groups (below).

### Parsing logic (parity with section 11)

The same six principles as the Xray branch, adapted to the flat sing-box schema:

- **N nodes per config.** Every payload outbound becomes a node; `endpoints` (WireGuard/MASQUE since sing-box 1.11) are read alongside `outbounds`.
- **Two passes.** Configs are sorted by payload count ascending for a draft pass (so a single-node "country card" gets to name a server before a pool does), then emitted in file order. Positions stay authorial.
- **Names.** Unlike Xray — where the name lives outside the outbound, in `remarks` — sing-box carries it in the outbound's own `tag`, so no `remarks`-style arbitration is needed. A tag repeated within one config gets an index suffix; an empty tag falls back to `<type>-<server>-<port>`.
- **Dedup** by identity `protocol|server|port|credential`, scoped to one parse (one subscription). The key is taken from the finished `NodeSpec`, so it matches `nodeIdentityKey` by construction.
- **Tag synonyms** map provider tags to identities; they resolve both group membership and `detour` references that point into a neighbouring config element.
- **Nothing vanishes silently.** An unsupported `type` (or a malformed outbound that throws during conversion) leaves an `UnsupportedProtocolWarning` on a neighbouring node — one per type, not per outbound. A config that yields no node at all has no warning carrier; the import dialog's counters cover that case.

### Chains (`detour`)

`detour: "<tag>"` becomes a nested `chained` node, and emit unfolds it back to a `detour` field — the round-trip is closed. Any of the 13 types can be a hop (the Xray branch only ever saw `socks` and `vless` via `dialerProxy`).

| case | behaviour |
|---|---|
| target referenced by anyone | arrives as a hop, not as a standalone node |
| target referenced by several nodes | copied into each owner (identical copies, tags separated at build) |
| chain longer than 8 hops | truncated + warning |
| loop (`A → B → A`) | closing edge dropped + warning; **both nodes survive** |
| dangling tag | node kept, no chain + warning |
| `detour` to a group | node kept, no chain + warning |
| `detour: "direct"` | no chain, no warning — a direct exit is not a node here |

Loops are broken rather than rejected. This deliberately differs from §254, which treats a loop in the *user's own* config as fatal so the culprit can be untangled: here the loop arrived in someone else's file, before any node exists.

### Groups (`urltest` / `selector`)

Both become an `AutoSelectSpec`. `url`, `interval`, `tolerance`, `idle_timeout` and `interrupt_exist_connections` map one-to-one; absent fields take the app's own defaults. `mode`/`balancer` are a local extension (§208) with no upstream counterpart and are not read.

Membership uses **explicit identity keys**, not a tag regex as in §322 — inside a config a tag resolves to exactly one outbound, which has already been parsed, so there is nothing to guess. A member tag that yields no node (a service entry, a nested group — a group cannot be a pool member) drops out with a warning; if the whole membership empties, the group is not imported at all, since an empty `urltest` fails core startup.

`selector` is imported as auto-select with a warning: there is no manual-choice node type in the model, and losing a hand-built membership is worse than changing how the winner is picked. Its `default` field is ignored.

### Notes

- Entries are **re-parsed** into typed `NodeSpec`s via `parseSingboxEntry` — nothing is passed through verbatim. Supported `type` values: `vless`, `vmess`, `trojan`, `anytls`, `shadowsocks`, `hysteria2`, `naive`, `tuic`, `ssh`, `socks`, `http`, `wireguard`, `masque`.
- Because of the typed round-trip, fields the model does not carry are **not preserved** (e.g. hysteria2 port hopping, ssh `host_key_algorithms`). `packet_encoding` is normalized to the allow-list and REALITY `public_key` is validated as X25519 (§169) — an invalid key degrades to plain TLS rather than emitting a config the core rejects.
- The `tag` field is used for display; an absent tag falls back to `<type>-<server>-<port>`.
- This is for advanced users who want to specify the exact sing-box configuration, and for migrating from sing-box itself.

---

## 11. Xray JSON Array

### Format

A JSON array where each element is a full Xray/v2ray configuration with `outbounds` containing `protocol` fields (Xray-style, not sing-box `type`):

```json
[
  {
    "remarks": "Server Name",
    "outbounds": [
      {
        "tag": "proxy",
        "protocol": "vless",
        "settings": {
          "vnext": [
            {
              "address": "server.com",
              "port": 443,
              "users": [{ "id": "uuid", "flow": "xtls-rprx-vision" }]
            }
          ]
        },
        "streamSettings": {
          "network": "tcp",
          "security": "reality",
          "realitySettings": {
            "serverName": "example.com",
            "fingerprint": "chrome",
            "publicKey": "...",
            "shortId": "abcd1234"
          },
          "sockopt": {
            "dialerProxy": "jump-server"
          }
        }
      },
      {
        "tag": "jump-server",
        "protocol": "socks",
        "settings": {
          "servers": [
            {
              "address": "jump.com",
              "port": 1080,
              "users": [{ "user": "admin", "pass": "secret" }]
            }
          ]
        }
      }
    ]
  }
]
```

### Detection

Auto-detected when input is a JSON array where the first element has `outbounds` containing at least one object with a `protocol` field.

Since §368 an array of *sing-box* configs has the same outer shape, so the elements decide: `type` inside `outbounds` → sing-box (section 10), `protocol` → Xray. Neither present (or an empty `outbounds`) stays Xray — this branch predates the sing-box one, and an ambiguous input must not be reclassified.

### Parsing Logic

Since §310, one array element yields **N nodes** — one per VLESS outbound — instead of a single "main" node. Providers put several equivalent servers (primary + fallbacks) into one element; collapsing them to one dropped the fallbacks.

1. For each element in the array, find all VLESS outbounds (`protocol: "vless"` with `vnext`).
2. Exclude outbounds referenced by another outbound's `sockopt.dialerProxy` — they are imported as a **detour server** of their owner, not as standalone nodes.
3. Convert each remaining VLESS outbound to its own sing-box VLESS outbound.
4. Node order — the "main" outbound comes first, so the first node stays what it was before §310:
   - Prefer the one with a `dialerProxy` in `sockopt` (chained proxy).
   - Else the one tagged `"proxy"`, else the first one.
5. If an outbound has `sockopt.dialerProxy`, resolve the referenced outbound and build it as a **detour server** (jump proxy) of that node only.
6. Naming — the first node takes the element's `remarks` verbatim; the rest get `remarks` + the outbound tag (`Main Server proxy-2`), falling back to an index suffix when the outbound has no tag. A single-VLESS element is named exactly as before.

### Supported Outbound Protocols

| Xray protocol | Converted to |
|---------------|-------------|
| `vless` | sing-box `vless` outbound (main or detour) |
| `socks` | sing-box `socks` outbound (detour only) |

### Chained Proxy (Jump/Detour)

When `streamSettings.sockopt.dialerProxy` references another outbound tag:
- The referenced outbound becomes a **detour server** with a tag prefixed by `"⚙ "`.
- The main outbound gets a `detour` field pointing to the detour server's tag.
- Supported detour protocols: SOCKS and VLESS.

### Xray to sing-box Conversion Details

**VLESS outbound:**
- `settings.vnext[0].address` -> `server`
- `settings.vnext[0].port` -> `server_port`
- `settings.vnext[0].users[0].id` -> `uuid`
- `settings.vnext[0].users[0].flow` -> `flow`
- Special flow `xtls-rprx-vision-udp443` -> `flow: xtls-rprx-vision` + `packet_encoding: xudp` + `server_port: 443`

**TLS (from `streamSettings`):**
- `security: "reality"` -> `tls.reality.enabled: true` with `realitySettings` mapped to `public_key`, `short_id`. REALITY is only built when the public key is a valid X25519 key (base64/base64url → 32 bytes); an invalid key degrades to plain TLS with a warning (§169).
- `security: "tls"` -> standard TLS from `tlsSettings` (`serverName`, `fingerprint`, `allowInsecure`)
- `flow` is taken verbatim from `users[0].flow`; it is **not** auto-derived from REALITY (§115). As in the URI path, Vision with a transport is dropped with a warning.

**Transport (from `streamSettings.network`):**
- `ws` -> `wsSettings` mapped to `{"type": "ws", "path": ..., "headers": {"Host": ...}}`
- `grpc` -> `grpcSettings` mapped to `{"type": "grpc", "service_name": ...}`
- `http`/`h2` -> `httpSettings` mapped to `{"type": "http", "path": ..., "host": [...]}`
- `xhttp` -> `xhttpSettings` mapped to `{"type": "xhttp", "path": ..., "host": ..., "mode": ...}` (native, §097 — see [XHTTP transport](#xhttp-transport))
- `tcp` or empty -> no transport block

**SOCKS detour:**
- `settings.servers[0].address` -> `server`
- `settings.servers[0].port` -> `server_port`
- `settings.servers[0].users[0].user` -> `username`
- `settings.servers[0].users[0].pass` -> `password`

### Tag Generation

- Tags are derived from `remarks` field (or Xray outbound `tag`, or `xray-<index>`).
- Non-alphanumeric characters (excluding Cyrillic, CJK, flag emoji) are replaced with `-`.
- Maximum 48 characters.
- Detour server tags are prefixed with `"⚙ "`.

### Reference

- Xray-core config: https://github.com/XTLS/Xray-core
- sing-box outbound: https://sing-box.sagernet.org/configuration/outbound/

---

## Common Behaviors

### Label and Tag Extraction

- The URI fragment (`#...`) is URL-decoded and used as the display label.
- The tag (used internally by sing-box) is derived from the label.
- If the label contains `|`, the part after `|` becomes the comment.
- Flag emoji `🇪🇳` is normalized to `🇬🇧`.
- If no label is provided, the tag defaults to `<scheme>-<host>-<port>`.

### Skip Filters

Nodes can be filtered out during parsing using skip filters. Filters support:
- Exact match: `value`
- Negation: `!value`
- Regex: `/pattern/i`
- Negation regex: `!/pattern/i`

Filterable fields: `tag`, `host`, `label`, `scheme`, `fragment`, `comment`, `flow`.

### Base64 Decoding

The parser tries multiple base64 variants in order:
1. URL-safe with padding
2. URL-safe without padding
3. Standard with padding
4. Standard without padding

### URI Length Limit

URIs exceeding the maximum length (defined by `maxURILength`) are rejected with a `FormatException`.

### TLS Insecure Flag

Multiple query keys are checked: `insecure`, `allowInsecure`, `allowinsecure`, `allow_insecure`, `skip-cert-verify`. Values `1`, `true`, `yes` all enable insecure mode.

### ECH from subscriptions is ignored (§320)

Xray links carry ECH as `ech=<query-name>+<resolver-URL>` (e.g. `ech=ip.gs+udp://8.8.8.8`), sometimes as a bare `ech=<query-name>`. **L×Box does not apply it** — the parameter is dropped with an `EchIgnoredWarning` (info severity: the node stays usable, only SNI masking is lost).

The form carries no ECH key. It says "fetch the ECHConfigList from the DNS HTTPS record of `<query-name>`", and the key so obtained belongs to that name. Subscriptions put **public ECH probes** there. Device-verified: DNS returns the *same* config list for both `ip.gs` and `encryptedsni.com`, decoding to `public_name = cloudflare-ech.com`, while the node's SNI is `www.ignitelimit.com` / `space.byu.id.yxls.eu.cc`. The key does not belong to the node's server, so the encrypted ClientHello is undecryptable and the handshake fails.

Measured on device (node `172.67.149.60` `/in-pdr`, path `/in-pdr`): **dead with `ech`, 723 ms without it.** NekoBox drops the parameter too — its database holds all 103 nodes of the same subscription with zero occurrences of `ech` — and keeps that node alive at 23 ms.

Suitability cannot be checked before connecting: `public_name` is only visible after the DNS query, inside the core's runtime, and sing-box has no fallback to plain TLS (`common/tls/ech.go` returns an error rather than degrading). A stricter rule (`ech` must equal the SNI) would still not prove the key belongs to the server, so the parameter is not applied at all.

`echfq` is not read either: it is Xray's pq-signature-schemes flag, and the core's counterpart is marked legacy and rejects the whole config when set.

**ALPN is passed through verbatim.** An earlier revision of §320 stripped `h2`/`h3` for ws/httpupgrade on the theory that HTTP/2 negotiation breaks the WebSocket upgrade. That was never measured, and such links usually list `http/1.1` alongside — client and server negotiate it themselves. The filter was reverted: the config follows the link.

---

## XHTTP transport

**Context.** XHTTP is the evolution of Xray's HTTP transport (formerly `splithttp`, late 2024): HTTP streams over TLS/Reality/h2c with separate upload modes. In subscriptions it appears as `type=xhttp` (VLESS, Trojan) or `net=xhttp` (VMess).

**Status.** Upstream sing-box does **not** support XHTTP (PR [SagerNet/sing-box#3879](https://github.com/SagerNet/sing-box/pull/3879) was closed unmerged on 2026-03-09). Since §097 L×Box bundles the [`sing-box-lx`](https://github.com/Leadaxe/sing-box-lx) fork core (the `with_xhttp` build tag, `option.V2RayXHTTPOptions`) and emits a **native** `{"type": "xhttp", ...}`. The former fallback of `xhttp → httpupgrade` plus an `UnsupportedTransportWarning` and an orange banner in the UI (Parser v2, up to and including v1.8.2) has been **removed** — nodes now connect over the real wire protocol.

**Parsing.** The sealed `XhttpTransport` ([`models/transport_spec.dart`](../app/lib/models/transport_spec.dart)) is assembled from three sources:
- the URI query — `parseTransport` in [`lib/services/parser/transport.dart`](../app/lib/services/parser/transport.dart); keys are read in both forms, camelCase (the Xray URI style) and snake_case (sing-box);
- sing-box JSON (`transport.type = "xhttp"`) — `parseSingboxEntry`;
- Xray JSON (`streamSettings.network = "xhttp"` plus `xhttpSettings`) — see section 11.

Since §127 the **full client-side set** of Xray splithttp is supported (SPEC 002 v2): beyond the six basic fields there are configurable session/seq/uplink placements, their keys, the upload method, the X-Padding obfuscation mode and packet-up tuning. In a URI these come from flat query parameters **and** from the `extra` parameter (URL-encoded JSON, see below).

| Field (snake_case JSON) | URI query (camelCase / snake) | Default |
|------|-----------|--------|
| `path` | `path` | `/` |
| `host` | `host` (falls back to `sni`) | empty |
| `mode` | `mode` | empty — the core decides (auto) |
| `x_padding_bytes` | `xPaddingBytes` | empty |
| `no_grpc_header` | `noGRPCHeader` | false |
| `headers` | — (JSON only) | empty |
| `session_placement` | `sessionPlacement` | `path` |
| `session_key` | `sessionKey` | placement-dependent |
| `seq_placement` | `seqPlacement` | `path` |
| `seq_key` | `seqKey` | placement-dependent |
| `uplink_data_placement` | `uplinkDataPlacement` | `auto` |
| `uplink_data_key` | `uplinkDataKey` | placement-dependent |
| `uplink_chunk_size` | `uplinkChunkSize` | placement-dependent |
| `uplink_http_method` | `uplinkHTTPMethod` | `POST` |
| `x_padding_obfs_mode` | `xPaddingObfsMode` | false |
| `x_padding_key` | `xPaddingKey` | `x_padding` |
| `x_padding_header` | `xPaddingHeader` | `X-Padding` |
| `x_padding_placement` | `xPaddingPlacement` | `queryInHeader` |
| `x_padding_method` | `xPaddingMethod` | `repeat-x` |
| `sc_max_each_post_bytes` | `scMaxEachPostBytes` | `1000000` |
| `sc_min_posts_interval_ms` | `scMinPostsIntervalMs` | `30` |

Every empty or default field is **not emitted** (omitempty) — the core has its own defaults. NB: VMess (base64 JSON) carries only `path` and `host`; the extended fields are available in the URI forms (VLESS/Trojan) and in JSON.

**The `extra` parameter (URL-encoded JSON).** Real subscriptions often pack some of the fields (especially the `scMaxEachPostBytes` / `scMinPostsIntervalMs` tuning) into a single query parameter, `extra=<urlencoded-json>`. The parser decodes it and merges its keys into the transport (`extra` wins for its own keys). **A malformed or truncated `extra` is ignored** — the link keeps working on the flat parameters. Numbers from `extra` are coerced to strings (`30.0` → `"30"`), and a `path` with a `?` tail is trimmed. The mapping reference is `SPECS/002-XHTTP_CLIENT_TRANSPORT/URL_PARSING.md` in the core's repository.

**The modes (`mode`).**

| mode | Meaning |
|------|----------|
| omitted / `auto` | the core decides; in the current sing-box-lx that means `packet-up` |
| `packet-up` | the uplink is cut into separate POST requests (with sequence numbers), the downlink is a single GET stream |
| `stream-up` | the uplink is one streaming POST, the downlink a GET stream |
| `stream-one` | a single bidirectional stream — everything in one request |

**Placement (§127).** Where the transport puts its bookkeeping data on each request, so that logical connections can be demultiplexed over a single HTTP origin:
- `session_placement` / `seq_placement` — the session id and the packet number: `path` | `query` | `header` | `cookie` (default `path`);
- `uplink_data_placement` — the payload upload in packet-up: `body` | `auto` | `header` | `cookie` (default `auto`, ≈ body);
- `*_key` — the key name for a non-path placement (the default depends on the placement: `X-Session` / `x_session` and so on).

**Obfuscation:**
- `x_padding_bytes` — the range of random padding, for example `"100-1000"`;
- `no_grpc_header` — do not send the gRPC wrapper in `stream-up`;
- `x_padding_obfs_mode` — the switch for configurable obfuscation (instead of the legacy padding in `Referer`); under it sit `x_padding_placement` (`cookie`|`header`|`query`|`queryInHeader`), `x_padding_method` (`repeat-x` | `tokenish` — HPACK-Huffman) and their own key/header.

**Normalization (§217).** `parseTransport` reads the fields verbatim; `toSingbox` does the checking. The core rejects values outside the enum sets **fatally** (one malformed node would take the whole config down at startup), so such fields are **not emitted** and the node gets an `XhttpParamResetWarning` (a ⚠️ in the subscription plus a line in the AppLog):

- the allow-lists: `session_placement`/`seq_placement` ∈ {`path`,`query`,`header`,`cookie`}; `uplink_data_placement` ∈ {`body`,`auto`,`header`,`cookie`}; `x_padding_placement` ∈ {`cookie`,`header`,`query`,`queryInHeader`}; `x_padding_method` ∈ {`repeat-x`,`tokenish`};
- the mode-dependent rules (valid only with `mode=packet-up`): `uplink_http_method=GET`, and `uplink_data_placement` = `header`/`cookie`. Outside packet-up those values are reset with a warning.

A malformed value never kills the config — the field is dropped and the node keeps working on the core's defaults.

**Generated transport block:**

```json
"transport": {
  "type": "xhttp",
  "path": "/path",
  "host": "cdn.example.com",
  "mode": "packet-up",
  "x_padding_bytes": "100-1000",
  "no_grpc_header": true,
  "session_placement": "header",
  "seq_placement": "query",
  "x_padding_obfs_mode": true,
  "x_padding_method": "tokenish",
  "sc_max_each_post_bytes": "1000000"
}
```

(The extended placement, obfuscation and tuning fields are optional; by default only the six basic ones are emitted.)

**Incompatible with Vision.** `flow=xtls-rprx-vision` only lives on “bare” TCP — combined with XHTTP (as with ws/grpc/h2) it is invalid by protocol. The parser does not auto-fill `flow` when a transport block is present (see TLS Behavior in section 1); a config with an explicit `flow` plus xhttp will not work against a server.

**Round trip.** `XhttpTransport.toSingbox` produces the transport map (empty fields are not emitted); `transportToQuery` produces a share URI in flat **camelCase** (the Xray form, for interop with v2rayN and Xray), carrying only **non-default** fields — so the URI does not bloat and the invariant `parseUri(toUri(spec)) ≈ spec` holds (on input, an empty field and a default one yield the same spec). No `extra` is generated on output — the fields are expanded flat. `httpupgrade` remains a **separate** transport and is no longer a “receiver” for xhttp.

**A note on the stock core.** On upstream sing-box (without `with_xhttp`) a config containing `"type": "xhttp"` is rejected at load time (`unknown transport type`). The feature works only on releases carrying the bundled fork core — just like AWG (section 8.5).
