# L×Box

Android VPN client powered by [sing-box](https://sing-box.sagernet.org/). Multi-subscription, smart routing, built-in speed test.

**[Download latest release](https://github.com/Leadaxe/LxBox/releases/latest)** | **[Документация на русском](README_RU.md)**

---

## Screenshots

<p align="center">
<img src="docs/screenshots/home.jpg" width="240" alt="Home Screen"/>
<img src="docs/screenshots/routing.jpg" width="240" alt="Routing"/>
<img src="docs/screenshots/statistics.jpg" width="240" alt="Statistics"/>
</p>
<p align="center">
<img src="docs/screenshots/speed_test.jpg" width="240" alt="Speed Test"/>
<img src="docs/screenshots/dns_settings.jpg" width="240" alt="DNS Settings"/>
<img src="docs/screenshots/vpn_settings.jpg" width="240" alt="VPN Settings"/>
</p>
<p align="center">
<img src="docs/screenshots/routing_rules.jpg" width="240" alt="Routing Rules & App Groups"/>
<img src="docs/screenshots/app_picker.jpg" width="240" alt="App Picker"/>
<img src="docs/screenshots/app_settings.jpg" width="240" alt="App Settings"/>
</p>

---

## Features

<details>
<summary><strong>Servers & Subscriptions</strong> — manage proxy sources in one place</summary>

Add servers by subscription URL, direct proxy link, WireGuard config, or raw JSON outbound. Smart paste dialog auto-detects format. Enable/disable subscriptions without deleting. Offline caching — works without internet. Per-subscription settings for detour servers.

- 8 protocols: VLESS, VMess, Trojan, Shadowsocks, Hysteria2, SSH, SOCKS, WireGuard
- Formats: Base64, Xray JSON Array (chained proxy), plain text, raw JSON
- Auto-refresh on VPN start, traffic quota bar, expiry date
- Quick Start with built-in free VPN preset
</details>

<details>
<summary><strong>Home Screen</strong> — connect and manage nodes</summary>

One-tap VPN start/stop with animated status. Choose proxy group, sort nodes by ping/name, mass-ping all servers. Traffic bar shows real-time speed, connections count, and uptime.

- Proxy groups: auto-proxy, manual selector, VPN-1, VPN-2
- Node filter: choose which nodes participate in auto-selection
- Detour servers (⚙) visibility toggle
- Long press ping button for URL presets
</details>

<details>
<summary><strong>Routing</strong> — control where traffic goes</summary>

Fine-grained control over traffic routing. Block ads, route Russian domains directly, send BitTorrent through specific proxy. Create named app groups with per-app routing.

- Preset routing rules with per-rule outbound selection
- App Groups: route specific apps through chosen proxy
- Default traffic fallback (route.final)
- All changes autosaved
</details>

<details>
<summary><strong>Detour Servers</strong> — chain proxies for extra privacy</summary>

Build multi-hop chains: your traffic goes through an intermediate server before reaching the final proxy. Per-subscription control: register detour servers in node list, enable/disable their use, or override all detours with your own server.

- ⚙ prefix for detour servers
- Register / Use / Override per subscription
- Detour dropdown in node settings
</details>

<details>
<summary><strong>DNS Settings</strong> — full control over name resolution</summary>

16 DNS server presets (Cloudflare, Google, Yandex, Quad9, AdGuard) with UDP/DoT/DoH variants. Custom servers via JSON editor. Strategy, cache, rules — all configurable.

- Enable/disable servers with switches
- DNS Strategy: prefer_ipv4 / prefer_ipv6 / ipv4_only / ipv6_only
- DNS Rules editor, DNS Final, Default Domain Resolver
</details>

<details>
<summary><strong>DPI Bypass</strong> — bypass internet censorship</summary>

TLS Fragment splits the initial handshake to bypass Deep Packet Inspection. Two modes: TCP fragmentation and TLS record fragmentation. Applied only to first-hop connections — detour traffic is already tunneled.

- TLS Fragment / Record Fragment toggles
- Fallback delay setting
- First-hop only (inner hops skip fragmentation)
</details>

<details>
<summary><strong>Speed Test</strong> — measure your connection</summary>

Built-in speed test with 10 servers worldwide. Per-server ping measures latency to the actual download server. Parallel download streams, upload test, session history.

- Servers: Cloudflare, Hostkey (5 cities), Selectel, Tele2, OVH, ThinkBroadband
- Configurable streams (1/4/10), upload method per server
- Session history with server name
</details>

<details>
<summary><strong>Statistics & Connections</strong> — see what's happening</summary>

Real-time traffic by outbound with expandable cards. Each connection shows host, protocol, routing rule, traffic, duration, proxy chain, and app/process name. Close individual connections.
</details>

<details>
<summary><strong>VPN Settings</strong> — tune the engine</summary>

Organized in sections: General, Clash API, Network, Auto Proxy, DNS, TUN, DPI Bypass. URLTest parameters for auto-proxy latency testing. All changes autosaved.
</details>

<details>
<summary><strong>Config Editor</strong> — for power users</summary>

View and edit raw sing-box JSON config. Pretty-printed display with copy button. Save, paste from clipboard, load from file, share.
</details>

<details>
<summary><strong>App Settings</strong> — personalize</summary>

- Theme: System / Light / Dark
- Auto-start VPN on boot
- Keep VPN active when app is closed
</details>

---

## Supported Protocols

| Protocol | URI scheme | Transport |
|----------|-----------|-----------|
| VLESS | `vless://` | TCP, WebSocket, gRPC, H2, REALITY |
| VMess | `vmess://` (v2rayN base64) | TCP, WebSocket, gRPC, H2 |
| Trojan | `trojan://` | TCP, WebSocket, gRPC |
| Shadowsocks | `ss://` (SIP002 + legacy) | TCP, UDP |
| Hysteria2 | `hy2://` / `hysteria2://` | QUIC |
| SSH | `ssh://` | TCP |
| SOCKS | `socks://` / `socks5://` | TCP |
| WireGuard | `wireguard://` | UDP |

See [Protocol Documentation](docs/PROTOCOLS.md) for full URI format details and sing-box mapping.

---

## Development

This project follows **spec-driven development** — [25 feature specifications](docs/spec/features/) document every capability.

| Document | Description |
|----------|-------------|
| [Protocol Reference](docs/PROTOCOLS.md) | URI formats, parameters, sing-box mapping |
| [Architecture](docs/ARCHITECTURE.md) | Data flows, config pipeline, native code |
| [Build](docs/BUILD.md) | Build instructions, CI, APK signing |
| [Development Guide](docs/DEVELOPMENT_GUIDE.md) | Principles, risks, AI workflow |
| [Changelog](CHANGELOG.md) | Release history |

---

## License

TBD
