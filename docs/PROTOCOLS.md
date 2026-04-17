# Protocol Documentation

L×Box parses proxy URIs from subscriptions and converts them into [sing-box](https://sing-box.sagernet.org/) outbound (or endpoint) JSON. This document describes every supported protocol, its URI format, parsed parameters, and the resulting sing-box configuration.

Source code: [`app/lib/services/node_parser.dart`](../app/lib/services/node_parser.dart), [`app/lib/services/xray_json_parser.dart`](../app/lib/services/xray_json_parser.dart).

---

## Table of Contents

1. [Subscription HTTP Headers](#0-subscription-http-headers)
2. [VLESS](#1-vless)
3. [VMess](#2-vmess)
4. [Trojan](#3-trojan)
5. [Shadowsocks](#4-shadowsocks)
6. [Hysteria2](#5-hysteria2)
7. [SSH](#6-ssh)
8. [SOCKS](#7-socks)
9. [WireGuard](#8-wireguard)
10. [WireGuard INI Config](#9-wireguard-ini-config)
11. [JSON Outbound (raw sing-box)](#10-json-outbound)
12. [Xray JSON Array](#11-xray-json-array)

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

See [`app/lib/services/subscription_fetcher.dart`](../app/lib/services/subscription_fetcher.dart). After fetching a subscription, headers are parsed and stored in `ProxySource` fields:

- `ProxySource.name` ← `profile-title`
- `ProxySource.totalBytes`, `uploadBytes`, `downloadBytes`, `expireTimestamp` ← `subscription-userinfo`
- `ProxySource.supportUrl` ← `support-url`
- `ProxySource.webPageUrl` ← `profile-web-page-url`

Displayed in subscription detail → **Source tab** → Headers section.

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
| Public key | `pbk` | REALITY public key |
| Short ID | `sid` | REALITY short ID (hex, max 16 chars) |
| Transport type | `type` | `tcp`, `ws`, `grpc`, `http`, `httpupgrade`, `xhttp`, `raw` |
| Path | `path` | WebSocket/HTTP/HTTPUpgrade path |
| Host | `host` | WebSocket Host header / HTTP host |
| Service name | `serviceName` or `service_name` | gRPC service name |
| Header type | `headerType` | When `http` with `type=tcp`/`raw`, creates HTTP transport |
| Packet encoding | `packetEncoding` | Packet encoding mode (e.g. `xudp`) |
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
| WebSocket | `ws` | `{"type": "ws", "path": ..., "headers": {"Host": ...}}` |
| gRPC | `grpc` | `{"type": "grpc", "service_name": ...}` |
| HTTP/2 | `http` | `{"type": "http", "path": ..., "host": [...]}` |
| HTTPUpgrade | `httpupgrade`, `xhttp` | `{"type": "httpupgrade", "path": ..., "host": ...}` |

### TLS Behavior

- If `pbk` (REALITY public key) is present: REALITY TLS is enabled, `flow` defaults to `xtls-rprx-vision` when no transport and no explicit flow.
- If `security=none`: no TLS block.
- If port is a known plaintext port (80, 8080, 8880, 2052, 2082, 2086, 2095) and no explicit security: no TLS.
- Otherwise: TLS enabled with UTLS fingerprint (defaults to `random`).
- Special flow `xtls-rprx-vision-udp443`: normalized to `xtls-rprx-vision` + `packet_encoding: xudp` + `server_port: 443`.

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
| `xhttp`, `httpupgrade` | `{"type": "httpupgrade", "path": ..., "host": ...}` |

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
| Transport | `type` | `ws`, `grpc`, `http`, `httpupgrade`, `xhttp` |
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

### sing-box Outbound Mapping

```json
{
  "type": "shadowsocks",
  "tag": "<label>",
  "server": "<host>",
  "server_port": <port>,
  "method": "<method>",
  "password": "<password>"
}
```

### Notes

- No transport or TLS options; Shadowsocks handles its own encryption.
- Unsupported methods cause a parse error (node is skipped).
- Base64 decoding tries both standard and URL-safe variants, with and without padding.

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
| Multi-port | `mport` or `ports` | Port hopping spec (e.g. `1000-2000,3000`) |

### sing-box Outbound Mapping

```json
{
  "type": "hysteria2",
  "tag": "<label>",
  "server": "<host>",
  "server_port": <port>,
  "password": "<password>",
  "server_ports": ["1000:2000", "3000:3000"],
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
- Multi-port (`mport`) format: comma-separated ranges with `-` converted to `:` for sing-box `server_ports`.
- `server_ports` is only set when `mport`/`ports` is present.
- Invalid SNI values (e.g. emoji-only) are replaced with the server address.

### Reference

- sing-box outbound: https://sing-box.sagernet.org/configuration/outbound/hysteria2/

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
| Password | userinfo (after `:`) or `password` query | SSH password |
| Private key | `private_key` | URL-encoded private key content |
| Private key path | `private_key_path` | Path to private key file |
| Key passphrase | `private_key_passphrase` | Passphrase for private key |
| Host keys | `host_key` | Comma-separated host key strings |

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
  "private_key_path": "<path>",
  "private_key_passphrase": "<passphrase>",
  "host_key": ["ssh-rsa AAAA..."]
}
```

### Notes

- Only password or private key authentication. No agent forwarding.
- `host_key` is split by comma into an array.

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

## 8. WireGuard

### URI Format

```
wireguard://PRIVATE_KEY@host:port?publickey=...&address=...&...#label
```

The private key is URL-encoded in the userinfo position. Default port: **51820**.

### Parsed Parameters

| Parameter | Query key | Description |
|-----------|-----------|-------------|
| Private key | userinfo | WireGuard private key |
| Public key | `publickey` | Peer public key (required) |
| Address | `address` | Comma-separated local addresses (required) |
| DNS | `dns` | DNS servers (from INI conversion) |
| MTU | `mtu` | MTU value (default: 1408) |
| Pre-shared key | `presharedkey` | Peer pre-shared key |
| Keepalive | `keepalive` | Persistent keepalive interval (seconds) |
| Allowed IPs | `allowedips` | Peer allowed IPs (default: `0.0.0.0/0, ::/0`) |

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

1. Parse `[Interface]`: `PrivateKey`, `Address`, `DNS`, `MTU`
2. Parse `[Peer]`: `PublicKey`, `Endpoint` (host:port), `PresharedKey`, `PersistentKeepalive`
3. Construct: `wireguard://host:port?publickey=...&privatekey=...&address=...&...#WireGuard`
4. The resulting URI is then parsed by the standard WireGuard parser (see section 8).

### Required Fields

- `PrivateKey` (in `[Interface]`)
- `PublicKey` (in `[Peer]`)
- `Endpoint` (in `[Peer]`)

Missing any of these throws a `FormatException`.

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

- The JSON is used as-is with no transformation.
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

1. For each element in the array, find all VLESS outbounds (`protocol: "vless"` with `vnext`).
2. Pick the "main" VLESS outbound:
   - Prefer the one with a `dialerProxy` in `sockopt` (chained proxy).
   - If multiple have dialer refs, prefer the one tagged `"proxy"`.
   - If none have dialer refs, prefer the one tagged `"proxy"`, else first.
3. Convert the main VLESS outbound to a sing-box VLESS outbound.
4. If the main outbound has `sockopt.dialerProxy`, resolve the referenced outbound and build it as a **detour server** (jump proxy).

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
- `security: "reality"` -> `tls.reality.enabled: true` with `realitySettings` mapped to `public_key`, `short_id`
- `security: "tls"` -> standard TLS from `tlsSettings` (`serverName`, `fingerprint`, `allowInsecure`)
- If REALITY is enabled with a public key and no explicit flow on TCP: auto-sets `flow: xtls-rprx-vision`

**Transport (from `streamSettings.network`):**
- `ws` -> `wsSettings` mapped to `{"type": "ws", "path": ..., "headers": {"Host": ...}}`
- `grpc` -> `grpcSettings` mapped to `{"type": "grpc", "service_name": ...}`
- `http`/`h2` -> `httpSettings` mapped to `{"type": "http", "path": ..., "host": [...]}`
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

Multiple query keys are checked: `insecure`, `allowInsecure`, `allowinsecure`. Values `1`, `true`, `yes` all enable insecure mode.
