# BoxVPN v1.1.1 — First Public Release

Android VPN client powered by [sing-box](https://sing-box.sagernet.org/). Multi-subscription, smart routing, built-in speed test.

## Features

### VPN Core
- **sing-box** native library (libbox 1.12.12) — high-performance kernel
- **TUN-only** inbound — no SOCKS5/HTTP proxy on localhost (IP leak protection)
- Start/Stop VPN with one button
- Auto-start on boot
- Keep VPN active on app exit

### Subscriptions
- Add by URL or direct proxy link
- **8 protocols**: VLESS, VMess, Trojan, Shadowsocks, Hysteria2, SSH, SOCKS, WireGuard
- Formats: Base64, Xray JSON Array (with chained proxy/jump), plain text
- Enable/disable individual subscriptions without deleting
- Auto-refresh on VPN start (configurable interval)
- Traffic quota bar, expiry date, support links from HTTP headers
- **Offline caching** — subscriptions cached on disk, work without internet
- Quick Start: built-in free VPN preset

### Home Screen
- Proxy group selector (proxy-out, auto-proxy-out, vpn-1, vpn-2)
- Node list sorted by Ping, A-Z, or Default order
- Active node highlighted with checkmark
- Traffic bar: upload/download speed, connection count, uptime
- **Mass Ping**: parallel ping all nodes (20 concurrent)
- Ping settings with URL presets (Google, Cloudflare, Apple, Firefox, Yandex)

### Node Filter (auto-proxy-out)
- Full node list from proxy-out with checkboxes
- Checked nodes included in auto-proxy-out (urltest)
- Unchecked nodes excluded from auto selection but remain in manual selector

### Routing
- Enable/disable preset proxy groups (Auto Proxy, Proxy, VPN 1, VPN 2)
- Routing rules: Block Ads, Russian domains direct, Russia-only services, BitTorrent direct, Private IPs direct
- Per-rule outbound selection (direct/proxy/auto/vpn)
- **App Groups**: named groups of apps routed through chosen outbound
- Default traffic (route.final) fallback outbound
- All changes autosaved

### DNS Settings
- **16 DNS server presets**: Cloudflare, Google, Yandex, Quad9, AdGuard (UDP/DoT/DoH variants)
- Enable/disable servers with switches
- Custom servers via JSON editor
- DNS Strategy, independent cache, DNS rules editor
- DNS Final and Default Domain Resolver dropdowns

### VPN Settings
- Log level, Clash API address/secret
- URLTest URL, interval, tolerance — configurable auto-proxy latency testing
- TUN address, MTU, strict route, TUN stack
- All changes autosaved

### Speed Test
- **4 parallel download streams** (configurable: 1/4/10)
- Real-time speed updates every 500ms
- Ping: 5 measurements, trimmed mean
- **10 servers**: Cloudflare, Hostkey (Moscow, Frankfurt, Amsterdam, Helsinki, New York), Selectel (RU), Tele2 (EU), OVH (France), ThinkBroadband (UK)
- Upload test with configurable method (PUT/POST) per server
- Session history with server name subtitle

### Statistics
- Total upload/download and connection count
- Traffic by outbound: expandable cards per proxy node
- Each connection: host:port, protocol, rule, traffic, duration, chain
- Close individual connections

### App Settings
- Theme: System / Light / Dark
- Auto-start on boot
- Keep VPN on exit

### Config Editor
- View and edit raw sing-box JSON config
- Pretty-printed, save/paste/load

## Security
- **TUN-only inbound** — no SOCKS5/HTTP proxy on localhost
- **Clash API** on random port (49152-65535) with mandatory secret
- VPN Service not exported (`android:exported="false"`)
- Geo-routing: Russian domains → direct
- Secret generated with cryptographically secure PRNG

## Architecture
- **wizard_template.json** — single source of truth for all defaults
- **Autosave** with 500ms debounce (no Apply buttons)
- **Offline-first**: subscription cache, config generation from cache
- Flutter (Dart 3.11+), Material 3
- Gradle Kotlin DSL, AGP 8.11.1, Kotlin 2.2.20, Java 17

## Install
Download `BoxVPN-v1.1.1.apk` and install on Android device.
