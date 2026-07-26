# Protocol Documentation

L×Box parses proxy URIs from subscriptions and converts them into [sing-box](https://sing-box.sagernet.org/) outbound (or endpoint) JSON. This document describes every supported protocol, its URI format, parsed parameters, and the resulting sing-box configuration.

**Source code (Parser v2, spec 026):**
- [`app/lib/services/parser/uri_parsers.dart`](../app/lib/services/parser/uri_parsers.dart) — URI-форматы всех 12 протоколов (vless, vmess, trojan, shadowsocks, hysteria2, naive, tuic, ssh, socks, http, wireguard/awg, masque)
- [`app/lib/services/parser/transport.dart`](../app/lib/services/parser/transport.dart) — парсинг `TransportSpec`, нативный XHTTP (§097, полный набор параметров §127)
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
17. [JSON Outbound (raw sing-box)](#10-json-outbound)
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

Парсинг в [`app/lib/services/subscription/sources.dart`](../app/lib/services/subscription/sources.dart) (`_metaFromHeaders` + `_parseContentDispositionFilename`). После fetch'а заголовки превращаются в `SubscriptionMeta` и кладутся в `SubscriptionServers.meta`:

- `SubscriptionServers.name` ← `profile-title` (с fallback на `content-disposition: filename=...`, v1.3.0+)
- `SubscriptionMeta.{totalBytes, uploadBytes, downloadBytes, expireTimestamp}` ← `subscription-userinfo`
- `SubscriptionMeta.supportUrl` ← `support-url`
- `SubscriptionMeta.webPageUrl` ← `profile-web-page-url`
- `SubscriptionServers.updateIntervalHours` ← `profile-update-interval` (используется в [spec 027](./spec/features/027%20subscription%20auto%20update/spec.md))

User-Agent HTTP-запросов: `LxBox-android/<appVersion>` (напр. `LxBox-android/2.9.0`; бренд-токен с §114, ранее `LxBox Android subscription client` / `SubscriptionParserClient`). Переопределяется per-request через App Settings → Subscriptions → Custom User-Agent (§118). Панели маршрутизируют тело ответа по подстроке `LxBox` в UA (`user_agent.dart`, `resolveSubscriptionUserAgent`).

Displayed в subscription detail → **Source tab** → Headers section.

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
| Public key | `pbk` | REALITY public key. REALITY активируется только при валидном X25519 (base64/base64url → 32 байта); мусор → plain TLS + warning (§169) |
| Short ID | `sid` | REALITY short ID (hex, max 16 chars) |
| Transport type | `type` | `tcp`, `ws`, `grpc`, `http`, `httpupgrade`, `xhttp`, `raw` |
| Path | `path` | WebSocket/HTTP/HTTPUpgrade path |
| Host | `host` | WebSocket Host header / HTTP host |
| Service name | `serviceName` or `service_name` | gRPC service name |
| Header type | `headerType` | When `http` with `type=tcp`/`raw`, creates HTTP transport |
| Packet encoding | `packetEncoding` (case-insensitive) | Allow-list: `xudp` / `packetaddr`. xray-style `none` и любой мусор молча дропаются — sing-box `NewOutbound` принимает только эти два значения, любое другое → panic в libbox. |
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
| WebSocket | `ws` | `{"type": "ws", "path": ..., "headers": {"Host": ...}}` — `?ed=N` в пути → `max_early_data` (§303, см. заметку ниже) |
| gRPC | `grpc` | `{"type": "grpc", "service_name": ...}` |
| HTTP/2 | `http` | `{"type": "http", "path": ..., "host": [...]}` |
| HTTPUpgrade | `httpupgrade` | `{"type": "httpupgrade", "path": ..., "host": ...}` |
| XHTTP | `xhttp` | `{"type": "xhttp", "path": ..., "host": ..., "mode": ...}` — нативный с §097, см. [XHTTP transport](#xhttp-transport) |

> **Note on WebSocket early data (§303).** Xray задаёт early data хвостом пути — `"path": "/api/v2/channel?ed=2560"`. В sing-box это отдельное поле транспорта, а хвост в `path` уходит в HTTP-запрос и даёт `404`. При импорте (URI, Xray JSON, sing-box JSON) хвост срезается, а `ed=N` становится `max_early_data: N`. Имя заголовка при этом **не** подставляется: пустой `early_data_header_name` = ядро шлёт early data в путь (`transport/v2raywebsocket/conn.go`), ровно как Xray для `?ed=`; подстановка `Sec-WebSocket-Protocol` переключила бы режим на header-based и сломала бы совместимость с сервером. Явный `Sec-WebSocket-Protocol` в `wsSettings.headers` по-прежнему читается как обычный заголовок. Для `httpupgrade` такого поля у транспорта нет — хвост срезается, `ed` отбрасывается. Обратный emit в URI склеивает `path?ed=N` назад, чтобы round-trip не терял параметр.

> **Note on XHTTP.** С §097 (ядро = fork [`sing-box-lx`](https://github.com/Leadaxe/sing-box-lx), build-тег `with_xhttp`) XHTTP эмитится **нативно**: `{"type": "xhttp", ...}` без подмены wire-протокола. Прежний fallback на `httpupgrade` с `UnsupportedTransportWarning` (Parser v2, до v1.8.2 включительно) удалён. XHTTP-специфичные query-ключи — `mode`, `xPaddingBytes`/`x_padding_bytes`, `noGRPCHeader`/`no_grpc_header` (camelCase = Xray-URI, snake = sing-box). С `flow=xtls-rprx-vision` несовместим — Vision живёт только на голом TCP. Подробности: [XHTTP transport](#xhttp-transport).

### TLS Behavior

- If `pbk` is present **and is a valid X25519 public key** (base64/base64url, decodes to exactly 32 bytes): REALITY TLS is enabled. An invalid `pbk` (e.g. `pbk=enabled`/`true` from broken subscriptions) falls back to **plain TLS** with a parse warning instead of emitting a REALITY block the core rejects — before §169 one broken node used to poison the whole `config.json` at startup.
- `flow` is **never** auto-derived from REALITY (§115): it is taken verbatim from the link. Historically bare-TCP+REALITY without `flow` got a forced Vision, breaking valid `none` setups.
- `xtls-rprx-vision` is valid only on bare TLS. If a transport (ws/grpc/xhttp/http/httpupgrade) is present, the explicit `flow` is dropped with a `VisionWithTransportWarning` (the core would not bring up that combination). `emit()` writes `flow` only when it is exactly `xtls-rprx-vision` with no transport.
- If `security=none`: no TLS block.
- If port is a known plaintext port (80, 8080, 8880, 2052, 2082, 2086, 2095) and no explicit security: no TLS.
- Otherwise: TLS enabled with UTLS fingerprint (defaults to `random`).
- Special flow `xtls-rprx-vision-udp443`: normalized to `xtls-rprx-vision` + `packet_encoding: xudp` (в URI-парсере порт **не** меняется; `server_port: 443` форсится только в Xray-JSON-пути, секция 11).

### packet_encoding allow-list

sing-box `vless.NewOutbound` принимает ровно три формы (см. [docs](https://sing-box.sagernet.org/configuration/outbound/vless/)):

| Значение в URI | В outbound JSON | Семантика |
|----------------|-----------------|-----------|
| omitted, `""`, `none` | поле не emit'ится | sing-box default |
| `xudp` / `XUDP` / `Xudp` | `"packet_encoding": "xudp"` | XUDP wrapper (xray) |
| `packetaddr` / `PacketAddr` | `"packet_encoding": "packetaddr"` | packet-addr (v2ray 5+) |
| любое другое | поле не emit'ится + warning в лог | защита от libbox panic |

Xray-style подписки (xray-knife и др.) кладут `packetEncoding=none` имея в виду «без encoding». sing-box эту строку не понимает и панически падает в `format.ToString` при попытке отдать ошибку (`E.New` принимает указатель `*string` вместо разыменованной строки — апстрим-баг). L×Box фильтрует на входе по allow-list, чтобы наружу не уезжало невалидных значений.

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
| `xhttp` | `{"type": "xhttp", "path": ..., "host": ...}` — нативный с §097, см. [XHTTP transport](#xhttp-transport) |

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
| Transport | `type` | `ws`, `grpc`, `http`, `httpupgrade`, `xhttp` (нативный с §097, см. [XHTTP transport](#xhttp-transport)) |
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

SIP002-URI query несёт SIP003-плагин:

| Query key | Format | Description |
|-----------|--------|-------------|
| `plugin` | `name;k=v;k=v…` | Имя плагина (до первого `;`) + опции (`obfs-local`, `v2ray-plugin`, …) |
| `plugin_opts` | `k=v;k=v…` | Опции отдельно, если не переданы внутри `plugin` |

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

- Shadowsocks handles its own encryption; TLS is not applicable. Transport-обфускация возможна только через SIP003-плагин (`plugin`/`plugin_opts` выше) — эмитятся в outbound, когда заданы.
- Unsupported methods cause a parse error (node is skipped).
- Base64 decoding tries both standard and URL-safe variants, with and without padding.
- Round-trip: `plugin`/`plugin_opts` эмитятся в sing-box JSON, но share-URI (`toUri`) их **не** пишет — при экспорте в `ss://` плагин теряется.

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

Кастомные схемы вместо голых `http://`/`https://` (§222): голые схемы
перехватываются `isSubscriptionUrl` **раньше** `isDirectLink` (вставленная
ссылка стала бы «подпиской»), а в телах подписок промо-строки вида
`https://t.me/...` превращались бы в мусорные узлы. Схема — дискриминатор
TLS: `proxy-https://` → `tls.enabled=true`. Default port: **80** /
**443** соответственно.

### Parsed Parameters

| Parameter | Source | Description |
|-----------|--------|-------------|
| Username | userinfo (before `:`) | Basic-auth username (`user`, `user:pass`, `:pass`) |
| Password | userinfo (after `:`) | Basic-auth password |
| Path | `path` | sing-box `path` (query-параметр, не URI-path — проще round-trip) |
| Headers | `headers` | Сериализация как naive `extra-headers`: `Header1: V1\r\nHeader2: V2`, URL-encoded |
| SNI | `sni` / `peer` / `host` | Только `proxy-https://`; default = host (конвенции trojan, `parseTrojanTls`) |
| Fingerprint | `fp` | uTLS fingerprint (только `proxy-https://`) |
| ALPN | `alpn` | Comma-separated (только `proxy-https://`) |
| Insecure | `allowInsecure` и алиасы | `tls.insecure` → `InsecureTlsWarning` |

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

- Все поля кроме `server`/`server_port` опциональны — пустые не эмитятся.
- JSON-путь (`parseSingboxEntry`) принимает listable-значения `headers`
  (string | [string, ...]) — как naive `extra_headers`.
- REALITY в URI не переносится (как у trojan) — JSON-путь сохраняет.
- Wizard-таб `HTTP` (§222): Tag/Host/Port/Username/Password + switch
  «HTTPS (TLS)»; тонкая настройка TLS — через JSON-редактор ноды.

### Reference

- sing-box outbound: https://sing-box.sagernet.org/configuration/outbound/http/

---

## 8. WireGuard

### URI Format

```
wireguard://PRIVATE_KEY@host:port?publickey=...&address=...&...#label
```

The private key is URL-encoded in the userinfo position. Default port: **51820**.

Схемы-алиасы: `wireguard://`, `wg://`, `awg://` — все три парсятся одной endpoint-логикой (§097). Наличие AWG-полей в query (любой из схем) делает узел AmneziaWG — см. [секцию 8.5](#85-amneziawg-awg-awg2).

### Parsed Parameters

| Parameter | Query key | Description |
|-----------|-----------|-------------|
| Private key | userinfo | WireGuard private key |
| Public key | `publickey` | Peer public key (required) |
| Address | `address` | Comma-separated local addresses (required) |
| MTU | `mtu` | MTU value (default: 1408; AWG-узлы — clamp `min(mtu, 1280)`, см. [8.5](#85-amneziawg-awg-awg2)) |
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

Добавлено в §097 (спека [`097`](./spec/features/097%20awg2-amneziawg2/spec.md)) вместе со сменой bundled-ядра на fork [`sing-box-lx`](https://github.com/Leadaxe/sing-box-lx) (build-тег `with_awg`, `option.AmneziaWGOptions`; пин версии — `app/android/libbox.version`). AmneziaWG = WireGuard + обфускация: те же ключи/peers/handshake, плюс набор параметров, маскирующих WG-трафик от DPI.

Все поля **config-only** — по сети не негоциируются и **должны совпадать у клиента и сервера**. Mismatch = тихий облом: handshake может пройти, данные не идут.

### URI Format

```
awg://PRIVATE_KEY@host:port?publickey=...&address=...&jc=4&jmin=40&jmax=70&s1=0&s2=0&h1=...&i1=...#label
```

`awg://` — схема-алиас той же endpoint-логики, что `wireguard://` / `wg://` (секция 8). AWG-поля распознаются в query **любой** из трёх схем: есть хотя бы одно поле → узел AmneziaWG (`WireguardSpec.awg != null`), нет ни одного → обычный WG (backward-compat, поведение не меняется).

### Поля

| Ключ | Тип | Назначение | Уровень |
|------|-----|-----------|--------|
| `jc`, `jmin`, `jmax` | int | junk-пакеты перед handshake: количество и границы размера | AWG 1.0 |
| `s1`, `s2` | int | junk-prefix у init/response handshake-пакетов | AWG 1.0 |
| `s3`, `s4` | int | junk-prefix у cookie-reply (`s3`) и transport/data-пакетов (`s4`) | AWG 2.0 |
| `h1`–`h4` | int \| `"N-M"` | magic headers — подмена типов пакетов. Одиночное `N` = 1.0; диапазон `N-M` = ranged headers (§112) | AWG 1.0 / 2.0 |
| `i1`–`i5` | string | CPS decoy-пакеты, тег-формат `<b 0xHEX><r N>…` | AWG 1.5 |
| `id`, `ip`, `ib` | string | masquerade-sugar (WireSock-style) над `i1` — ядро само разворачивает в CPS-пакет `i1`. **Взаимоисключающи с явным `i1`** (оба сразу → ошибка старта ядра). §143 | AWG 1.5 |

- Числовые поля — uint32, эмитятся как JSON **number**.
- `h1`–`h4` (§112): значение `N` → `int` (строка-число `"5"` нормализуется в `int 5`), диапазон `N-M` → `String`, эмитится JSON **string** (контракт ядра ≥ `lx.6`). Глубже не валидируем (start ≤ end, uint32, непересечение диапазонов) — это делает ядро с явной ошибкой на старте; молчаливый drop здесь дал бы тихо сломанный handshake.
- `i1`–`i5` — строки, **регистр сохраняется** как есть (case-sensitive, менять нельзя).
- Битое число в query → поле молча пропускается (forward-compat, как `mtu`/`keepalive`), парс узла не валится. Для `h*` «битое» = не подходящее под `N`/`N-M`.

> **`reserved` ≠ `reserved_zero[3]` — разные сущности на одних байтах.**
> В терминологии LxBox `reserved` — это **Cloudflare WARP client_id**, 3 байта, эмитится **per-peer** (секция 8, `reserved: [b0,b1,b2]`).
> В спеке WireGuard `reserved_zero[3]` — это байты `[1..3]` заголовка пакета, идущие сразу за message type `[0]`; magic headers `h1`–`h4` пишут во **все 4 байта** `[0..3]` целиком (uint32), то есть перезаписывают именно `reserved_zero`.
> Байты физически одни и те же, смысл разный. Смешение уже приводило к реальному багу: безусловная очистка `b[1:4]` под WARP-client_id затирала ranged magic (фикс — ядро `lx.9`). При работе с любым из двух полей уточнять, о каком идёт речь.

Модель: класс `Awg` в [`node_spec.dart`](../app/lib/models/node_spec.dart) (`WireguardSpec.awg`, `null` = обычный WG). Round-trip полный: URI / INI / sing-box JSON → `Awg` → `emit()` / `toUri()` без потерь.

### MTU clamp

Для AWG-узлов клиентский MTU **клампится: `min(mtu, 1280)`**; без явного `mtu` — дефолт **1280** (`awgClampMtu` в [`uri_utils.dart`](../app/lib/services/parser/uri_utils.dart)). Обычный WG не трогаем (дефолт 1408, как было).

Почему 1280:
- рекомендованный клиентский MTU самой AmneziaWG и минимальный IPv6 MTU → безопасно на любом пути (PPPoE 1492, mobile, вложенные туннели);
- «точный» потолок `1500 − 60 − max(s3, s4)` хрупок — предполагает path-MTU ровно 1500, чего у AWG-юзеров обычно нет;
- асимметрия рисков: занижение лишь чуть мельчит пакеты, завышение — тихий облом (handshake есть, данных нет).

Явно заниженный MTU (≤ 1280) уважается как есть.

### INI

AWG-поля читаются из `[Interface]`-секции стандартного WireGuard INI (см. секцию 9):

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

Ключ case-insensitive (`Jc` ≙ `jc`), регистр **значения** сохраняется. При конвертации INI → URI поля прокидываются в query (`i*` URL-эскейпятся).

### sing-box-lx Endpoint Mapping

Поля идут в **корень endpoint'а** (рядом с `mtu`/`address`/`private_key`, **не** per-peer):

```jsonc
{
  "type": "wireguard",
  "tag": "<label>",
  "mtu": 1280,
  "address": ["10.8.1.2/32"],
  "private_key": "<private_key>",
  "peers": [ /* как в секции 8 */ ],
  "jc": 4, "jmin": 40, "jmax": 70,
  "s1": 0, "s2": 0,
  "h1": 1234567890, "h2": 1234567891, "h3": 1234567892, "h4": 1234567893,
  "i1": "<b 0xffffffff><r 16>"
}
```

Ranged headers (§112) — диапазоны строками, одиночные числами, можно смешивать:

```jsonc
  "h1": "43613244-384550127", "h2": "826869626-2105069164",
  "h3": "2124774725-2141151992", "h4": "2144594503-2146278491",
```

Обратный парс (JSON-редактор, Smart-Paste) собирает те же поля из корня entry (`Awg.fromJson` в `parseSingboxEntry`).

### Версии AmneziaWG: awg / awg1.5 / awg2 (§148)

Subtitle узла и variant-фильтр (§102/§103) различают **версию AmneziaWG** структурно — по наличию полей в конфиге ([`config_node.dart`](../app/lib/models/config_node.dart)). Соответствует официальному версионированию Amnezia (у них это явные версии формата конфига, с инструкцией миграции 1.0→1.5). База — по старшему присутствующему маркеру (приоритет сверху вниз):

| Лейбл | Версия | Что добавила версия | Маркер в конфиге |
|-------|--------|---------------------|------------------|
| `awg2` | 2.0 | Динамика вместо статики: диапазоны заголовков, random-padding на transport-сообщения | ranged-заголовок `h1`–`h4` (`"N-M"`, §112) **или** `s3`/`s4` |
| `awg1.5` | 1.5 | Signature-пакеты (CPS) — мимикрия под реальный протокол (hex-снимок, напр. QUIC Initial), шлётся до junk-цепочки | любой из `i1`–`i5` |
| `awg` | 1.0 | Базовая обфускация поверх WireGuard | `jc`/`jmin`/`jmax` (junk), `s1`/`s2` (init-padding), одиночные `h1`–`h4` (magic-заголовки) |
| — | — | обычный WG | ни одного AWG-поля → security-слот пуст |

**Водораздел 1.0→1.5** — появление `I1` (официальная инструкция Amnezia: «добавить `I1` после строки `H4`»). `I2`–`I5` — дополнительные signature-пакеты той же версии 1.5. **Водораздел 1.5→2.0** — переход со статичных `H1`–`H4` на динамические диапазоны (+ `s3`/`s4`-padding); реальный 2.0-экспорт может содержать одновременно ranged-H, `s3`/`s4` и `i*` — старший маркер (2.0) выигрывает.

Суффикс `+` ставится при наличии masquerade-sugar `ip`/`id`/`ib` (§143). Ядро 009 само разворачивает их в CPS-пакет `i1`, т.е. masquerade **сам по себе = версия 1.5**. Поэтому `awg+` невозможен:

| База (до суффикса) | + masquerade |
|--------------------|--------------|
| `awg2` (2.0) | `awg2+` |
| `awg1.5` / `awg` / нет AWG-полей | `awg1.5+` |

masquerade-поля взаимоисключающи с явным `i1` на уровне ядра (оба → ошибка старта), но лейбл считается по сырому JSON до валидации — потому суффикс проверяется независимо.

### Требование к ядру

Работает только на бандленном fork-ядре `sing-box-lx` (build-тег `with_awg`). Стоковый upstream sing-box этих полей не знает и **отвергает конфиг на load**. Ranged headers (`"h1": "N-M"` строкой) требуют ядро ≥ `v1.13.13-lx.6` — старое ядро падает на unmarshal такого конфига (поэтому §112 перепинивает [libbox.version](../app/android/libbox.version) в том же коммите).

### Reference

- AmneziaWG: https://docs.amnezia.org/documentation/amnezia-wg/
- Fork ядра: https://github.com/Leadaxe/sing-box-lx

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

1. Parse `[Interface]`: `PrivateKey`, `Address`, `MTU` + AWG-поля `Jc`/`Jmin`/`Jmax`/`S1`–`S4`/`H1`–`H4`/`I1`–`I5` (§097, см. [8.5](#85-amneziawg-awg-awg2); ключ case-insensitive, регистр значения сохраняется, `i*` URL-эскейпятся в query)
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

Добавлено в §110 (task spec [`110`](./spec/tasks/110-amnezia-vpn-link-import.md)). Контейнерный share-формат Amnezia / awg2; `.vpn`-файл содержит ту же строку.

### Format

```
vpn://<base64url( qCompress(JSON, 8) )>
```

- base64url **без padding** (алфавит `-_`, `Base64UrlEncoding | OmitTrailingEquals`); padded и standard-варианты тоже принимаются (`decodeBase64Safe`).
- `qCompress` = 4 байта big-endian (длина распакованного) + стандартный zlib-поток. Несжатый payload (голый base64-JSON) — fallback, паритет с `importController` Amnezia.
- В JSON: `containers[]` → под-объекты `awg` / `wireguard` → `last_config` (JSON-строка; защитно принимаем и объект) → `config` = готовый WG/AWG INI (секция 9). Плейсхолдеры `$PRIMARY_DNS`/`$SECONDARY_DNS` подставляются из корневых `dns1`/`dns2`.

### Detection / Flow

Шаг 0 в `decode()` ([body_decoder.dart](../app/lib/services/parser/body_decoder.dart)): `startsWith('vpn://')` → [`amnezia_link.dart`](../app/lib/services/parser/amnezia_link.dart) → `AmneziaConfig(iniTexts)` → `parseAll` → каждый INI через `parseWireguardIni`. Все WG/AWG контейнеры ссылки становятся нодами **одного** `UserServer` (`rawBody` = оригинальная ссылка, персист ре-парсит тем же путём); прочие протоколы Amnezia (openvpn/xray/cloak/…) скипаются; нет ни одного WG/AWG → `DecodeFailure` с явной причиной.

### Limits

- Ссылка ≤ 64 KiB (`maxURILength`), claimed uncompressed size ≤ 4 MiB — защита от zlib-бомб.
- Reference: [config-decoder](https://github.com/amnezia-vpn/config-decoder) (эталон формата), `exportController.cpp` / `importController.cpp` в [amnezia-client](https://github.com/amnezia-vpn/amnezia-client).

---

## 9.5 TUIC v5

Добавлен в Parser v2 (спека [`026`](./spec/features/026%20parser%20v2/spec.md)). В v1 парсинг TUIC отсутствовал.

### URI format

```
tuic://<UUID>:<PASSWORD>@<host>:<port>?<params>#<label>
```

### Параметры

| Ключ | Значение |
|------|---------|
| `congestion_control` | `bbr` \| `cubic` \| `new_reno` (default `cubic`) |
| `udp_relay_mode` | `native` \| `quic` (default `native`) |
| `alpn` | CSV список (`h3`, `h3-29`) |
| `sni` | SNI для TLS |
| `allow_insecure` / `insecure` | `1` \| `true` — пропустить проверку сертификата |
| `disable_sni` | `1` — не отправлять SNI |
| `reduce_rtt` | `1` — включить 0-RTT / early data |

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

Транспорт WARP по **RFC 9484 (CONNECT-IP over MASQUE)** — IP-туннель поверх
QUIC/HTTP-3, с fallback на HTTP/2. Добавлен в **v2.9.0** (§130; ядро sing-box-lx
SPEC 021, `type: masque` через `outbound.Register`). Даёт другой пул выходных нод
Cloudflare (часто иностранные IP) и для DPI выглядит как обычный HTTPS/QUIC к
Cloudflare на 443.

MASQUE-узлы создаются через **Get WARP**-визард (ECDSA P-256 регистрируется
на устройстве, `_addMasqueNode` → `account.toMasqueUri()` → `parseMasqueUri`),
но имеют полноценный round-trip через `masque://` URI — парсятся из paste/подписки
так же, как остальные протоколы.

> **Импорт чужих Clash-YAML MASQUE-конфигов не поддерживается** — Clash YAML в
> L×Box не парсится (для любых протоколов). MASQUE поднимается только своей
> регистрацией или из `masque://` URI.

### URI Format

```
masque://<privKeyDer>@<host>:<port>?publickey=<serverPubDer>&address=<v4,v6>&profile=cloudflare&network=h3[&sni=...][&mtu=1280][&idle_timeout=5m][&keep_alive=30s]#<label>
```

Ключи — base64(DER) ECDSA P-256: `userInfo` (до `@`) = наш приватник (SEC1),
`publickey` = серверный pubkey (PKIX, для pinning). Сырой `/` в base64
экранируется (§106). Порт по умолчанию — `443`.

### Parsed Parameters

| Ключ | Значение |
|------|----------|
| userInfo / `privatekey` / `private_key` | base64(SEC1 DER) приватника (**секрет**), обязателен |
| `publickey` / `public_key` | base64(PKIX DER) серверного pubkey, обязателен |
| `address` | CSV локальных адресов туннеля (`v4,v6`), обязателен; авто-CIDR (`/32`//`128`) |
| `profile` | `cloudflare` (default) \| `standard` |
| `network` | `h3` — QUIC (default) \| `h2` — HTTP/2 |
| `sni` | TLS SNI; пусто = дефолт ядра (`consumer-masque.cloudflareclient.com`) |
| `mtu` | int, default `1280` |
| `idle_timeout` | Go-duration idle-suspend туннеля (пусто = дефолт ядра `5m`; отрицательное = выкл, §128) |
| `keep_alive` | Go-duration QUIC keepalive (пусто = `30s`; только `network=h3`) |

### sing-box Outbound Mapping

Эмитится как **Outbound** (не Endpoint, в отличие от WireGuard). `ip`/`ipv6`
разбираются из `address` по признаку `:` (v6). `sni`/`mtu`/`idle_timeout`/
`keep_alive_period` пишутся только при непустых значениях.

```json
{
  "type": "masque",
  "tag": "<tag>",
  "server": "<host>",
  "server_port": 443,
  "profile": "cloudflare",
  "network": "h3",
  "private_key": "<privKeyDer>",
  "public_key": "<serverPubDer>",
  "ip": "172.16.0.2/32",
  "ipv6": "2606:4700:110:...::/128",
  "sni": "consumer-masque.cloudflareclient.com",
  "mtu": 1280,
  "idle_timeout": "5m",
  "keep_alive_period": "30s"
}
```

### Reference

- RFC 9484 (CONNECT-IP over MASQUE)
- §130 spec: [docs/spec/features/130 masque-warp-transport/spec.md](spec/features/130%20masque-warp-transport/spec.md)
- Ядро sing-box-lx SPEC 021 (`type: masque`)
- [WARP integration (§025)](spec/features/025%20warp%20integration/spec.md)

---

## 10. JSON Outbound

### Format

Raw sing-box outbound or endpoint JSON pasted directly. The JSON object must have a `type` field.

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

### Notes

- The entry is **re-parsed** into a typed `NodeSpec` via `parseSingboxEntry` — it is not passed through verbatim. Supported `type` values: `vless`, `vmess`, `trojan`, `shadowsocks`, `hysteria2`, `naive`, `tuic`, `ssh`, `socks`, `wireguard`, `masque`. An unknown `type` → the node is skipped (returns null).
- Because of the typed round-trip, fields the model does not carry are **not preserved** (e.g. hysteria2 port hopping, ssh `host_key_algorithms`). `packet_encoding` is normalized to the allow-list and REALITY `public_key` is validated as X25519 (§169) — an invalid key degrades to plain TLS rather than emitting a config the core rejects.
- The `tag` field is used for display and must be present.
- This is for advanced users who want to specify the exact sing-box configuration.

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
- `xhttp` -> `xhttpSettings` mapped to `{"type": "xhttp", "path": ..., "host": ..., "mode": ...}` (нативный, §097 — см. [XHTTP transport](#xhttp-transport))
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

---

## XHTTP transport

**Контекст.** XHTTP — эволюция HTTP-транспорта в Xray (бывший `splithttp`, конец 2024): HTTP-стримы поверх TLS/Reality/h2c с раздельными режимами upload'а. В подписках — `type=xhttp` (VLESS, Trojan) или `net=xhttp` (VMess).

**Статус.** Upstream sing-box XHTTP **не поддерживает** (PR [SagerNet/sing-box#3879](https://github.com/SagerNet/sing-box/pull/3879) закрыт без мержа 2026-03-09). С §097 L×Box бандлит fork-ядро [`sing-box-lx`](https://github.com/Leadaxe/sing-box-lx) (build-тег `with_xhttp`, `option.V2RayXHTTPOptions`) и эмитит **нативный** `{"type": "xhttp", ...}`. Прежний fallback `xhttp → httpupgrade` + `UnsupportedTransportWarning` + оранжевый баннер в UI (Parser v2, до v1.8.2 включительно) **удалён** — узлы соединяются по настоящему wire-протоколу.

**Парсинг.** sealed `XhttpTransport` ([`models/transport_spec.dart`](../app/lib/models/transport_spec.dart)) собирается из трёх источников:
- URI query — `parseTransport` в [`lib/services/parser/transport.dart`](../app/lib/services/parser/transport.dart); ключи читаются в обеих формах: camelCase (Xray-URI) и snake_case (sing-box);
- sing-box JSON (`transport.type = "xhttp"`) — `parseSingboxEntry`;
- Xray JSON (`streamSettings.network = "xhttp"` + `xhttpSettings`) — см. секцию 11.

С §127 поддержан **полный клиентский набор** Xray splithttp (SPEC 002 v2): кроме 6 базовых полей — настраиваемые placement'ы session/seq/uplink, ключи, метод upload, X-Padding obfs-режим и packet-up tuning. Источник полей в URI — плоские query-параметры **и** параметр `extra` (URL-encoded JSON, см. ниже).

| Поле (snake_case JSON) | URI query (camelCase / snake) | Default |
|------|-----------|--------|
| `path` | `path` | `/` |
| `host` | `host` (fallback: `sni`) | пусто |
| `mode` | `mode` | пусто — ядро решает (auto) |
| `x_padding_bytes` | `xPaddingBytes` | пусто |
| `no_grpc_header` | `noGRPCHeader` | false |
| `headers` | — (только JSON) | пусто |
| `session_placement` | `sessionPlacement` | `path` |
| `session_key` | `sessionKey` | placement-зав. |
| `seq_placement` | `seqPlacement` | `path` |
| `seq_key` | `seqKey` | placement-зав. |
| `uplink_data_placement` | `uplinkDataPlacement` | `auto` |
| `uplink_data_key` | `uplinkDataKey` | placement-зав. |
| `uplink_chunk_size` | `uplinkChunkSize` | placement-зав. |
| `uplink_http_method` | `uplinkHTTPMethod` | `POST` |
| `x_padding_obfs_mode` | `xPaddingObfsMode` | false |
| `x_padding_key` | `xPaddingKey` | `x_padding` |
| `x_padding_header` | `xPaddingHeader` | `X-Padding` |
| `x_padding_placement` | `xPaddingPlacement` | `queryInHeader` |
| `x_padding_method` | `xPaddingMethod` | `repeat-x` |
| `sc_max_each_post_bytes` | `scMaxEachPostBytes` | `1000000` |
| `sc_min_posts_interval_ms` | `scMinPostsIntervalMs` | `30` |

Все пустые/дефолтные поля **не эмитятся** (omitempty) — у ядра свои дефолты. NB: VMess (base64-JSON) несёт только `path`/`host`; расширенные поля доступны в URI-формах (VLESS/Trojan) и JSON.

**Параметр `extra` (URL-encoded JSON).** Реальные подписки часто упаковывают часть полей (особенно tuning `scMaxEachPostBytes`/`scMinPostsIntervalMs`) в один query-параметр `extra=<urlencoded-json>`. Парсер декодирует его и вливает ключи в transport (extra в приоритете для своих ключей). **Битый/обрезанный `extra` игнорируется** — ссылка остаётся рабочей на плоских параметрах. Числа из `extra` приводятся к строке (`30.0` → `"30"`); `path` с `?`-хвостом обрезается. Справочник маппинга — `SPECS/002-XHTTP_CLIENT_TRANSPORT/URL_PARSING.md` в репозитории ядра.

**Режимы (`mode`).**

| mode | Семантика |
|------|----------|
| omitted / `auto` | ядро выбирает; в текущем sing-box-lx ≙ `packet-up` |
| `packet-up` | uplink режется на отдельные POST-запросы (seq-номера), downlink — один GET-стрим |
| `stream-up` | uplink — один потоковый POST, downlink — GET-стрим |
| `stream-one` | один bidirectional стрим — всё в одном запросе |

**Placement (§127).** Куда транспорт кладёт служебные данные на каждом запросе — для демультиплексирования логических соединений поверх одного HTTP-origin:
- `session_placement` / `seq_placement` — session id и номер пакета: `path` | `query` | `header` | `cookie` (default `path`);
- `uplink_data_placement` — payload upload в packet-up: `body` | `auto` | `header` | `cookie` (default `auto`≈body);
- `*_key` — имя ключа для не-path placement (дефолт зависит от placement: `X-Session`/`x_session` и т.п.).

**Обфускация:**
- `x_padding_bytes` — диапазон случайного padding'а, напр. `"100-1000"`;
- `no_grpc_header` — не слать gRPC-обёртку в `stream-up`;
- `x_padding_obfs_mode` — переключатель configurable-obfs (вместо legacy padding в `Referer`); под ним `x_padding_placement` (`cookie`|`header`|`query`|`queryInHeader`) + `x_padding_method` (`repeat-x` | `tokenish` — HPACK-Huffman) + свои ключ/заголовок.

**Нормализация (§217).** `parseTransport` читает поля дословно; проверку делает `toSingbox`. Значения вне enum-множеств ядро отвергает **fatal** (одна битая нода роняла бы весь конфиг на старте), поэтому такие поля **не эмитятся** и нода получает `XhttpParamResetWarning` (⚠️ в подписке + строка в AppLog):

- allow-list'ы: `session_placement`/`seq_placement` ∈ {`path`,`query`,`header`,`cookie`}; `uplink_data_placement` ∈ {`body`,`auto`,`header`,`cookie`}; `x_padding_placement` ∈ {`cookie`,`header`,`query`,`queryInHeader`}; `x_padding_method` ∈ {`repeat-x`,`tokenish`};
- mode-зависимые правила (только при `mode=packet-up`): `uplink_http_method=GET`, а также `uplink_data_placement` = `header`/`cookie`. Вне packet-up эти значения сбрасываются с warning.

Битое значение не роняет конфиг — поле дропается, узел остаётся рабочим на дефолтах ядра.

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

(Расширенные placement/obfs/tuning-поля — опциональны; в дефолте эмитятся только базовые 6.)

**Несовместимость с Vision.** `flow=xtls-rprx-vision` живёт только на «голом» TCP — с XHTTP (как и с ws/grpc/h2) комбинация невалидна по протоколу. Парсер auto-flow при наличии transport-блока не подставляет (см. TLS Behavior в секции 1); конфиг с явным `flow` + xhttp с сервером не заработает.

**Round-trip.** `XhttpTransport.toSingbox` → transport-map (пустые поля не эмитятся); `transportToQuery` → share-URI плоским **camelCase** (Xray-форма, интероп с v2rayN/Xray), и только **не-дефолтные** поля — URI не раздувается, инвариант `parseUri(toUri(spec)) ≈ spec` сохраняется (на входе пустое поле == дефолтное дают одну spec). `extra` на выходе не генерируется — поля разворачиваются плоско. `httpupgrade` остаётся **отдельным** транспортом — больше не «приёмник» для xhttp.

**NB про стоковое ядро.** На upstream sing-box (без `with_xhttp`) конфиг с `"type": "xhttp"` отвергается на load (`unknown transport type`). Фича работает только на релизах с бандленным fork-ядром — как AWG (секция 8.5).
