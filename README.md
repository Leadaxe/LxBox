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

### Subscriptions
- Add subscriptions by URL or direct proxy link
- Supported protocols: **VLESS, VMess, Trojan, Shadowsocks, Hysteria2, SSH, SOCKS, WireGuard**
- Formats: Base64, Xray JSON Array (with chained proxy/jump), plain text
- **Enable/disable** individual subscriptions without deleting
- Auto-refresh on VPN start (configurable interval)
- Profile title and traffic stats from HTTP headers (subscription-userinfo)
- Subscription detail: node list, traffic quota bar, expiry date, support/web links
- **Offline caching**: subscriptions cached on disk, work without internet
- Quick Start: built-in free VPN preset
- Telegram support links open natively

### Home Screen
- **Start/Stop** VPN with one button
- Group selector (proxy-out, auto-proxy-out, vpn-1, vpn-2)
- Node list sorted by **Ping**, **A-Z**, or **Default** order
- Active node highlighted with checkmark
- Traffic bar: upload/download speed, connection count, uptime
- Tap traffic bar to open **Statistics**
- **Mass Ping**: parallel ping all nodes (20 concurrent)
- Long press ping button for **Ping Settings** with URL presets (Google, Cloudflare, Apple, Firefox, Yandex)

### Node Filter (auto-proxy-out)
- Full node list from proxy-out with checkboxes
- Checked nodes included in auto-proxy-out (urltest)
- Unchecked nodes excluded from auto selection but remain in manual selector
- Search, Select All / Deselect All
- Reads from config (offline, instant)

### Routing
- **Proxy Groups**: enable/disable preset groups (Auto Proxy, Proxy, VPN 1, VPN 2)
- **Routing Rules**: Block Ads, Russian domains direct, Russia-only services, BitTorrent direct, Private IPs direct
- Per-rule **outbound selection** (direct/proxy/auto/vpn-X)
- **App Groups**: named groups of apps routed through chosen outbound
  - App picker with icons, search, select all/invert, clipboard import/export
- **Default traffic** (route.final): fallback outbound for unmatched traffic
- All changes **autosaved** (no Apply button)

### DNS Settings
- **16 DNS server presets**: Cloudflare (UDP/DoT/DoH), Google (UDP/DoT/DoH), Yandex (UDP/Safe/Family/DoT/DoH), Quad9, AdGuard, via-VPN variants
- Enable/disable servers with switches
- Add custom servers via JSON editor
- **DNS Strategy**: prefer_ipv4 / prefer_ipv6 / ipv4_only / ipv6_only
- **Independent cache** toggle
- **DNS Rules** editor (JSON)
- **DNS Final** and **Default Domain Resolver** dropdowns from enabled servers
- All presets defined in `wizard_template.json` (single source of truth)

### VPN Settings
- Log level (warn/info/debug/trace)
- Clash API address and secret (auto-generated)
- Resolve strategy
- Auto-detect interface
- Packet sniffing
- **URLTest URL** — endpoint for auto-proxy latency testing
- **URLTest interval** — how often to test (e.g. 5m)
- **URLTest tolerance** — minimum latency difference to switch (ms)
- TUN address, MTU, strict route, TUN stack
- All changes autosaved

### Speed Test
- **4 parallel download streams** (configurable: 1/4/10)
- **Real-time** speed updates every 500ms
- Ping: 5 measurements, trimmed mean
- **10 servers**: Cloudflare, Hostkey (Moscow, Frankfurt, Amsterdam, Helsinki, New York), Selectel (RU), Tele2 (EU), OVH (France), ThinkBroadband (UK)
- Shows current proxy or "Direct" indicator
- **Session history** (last 10 tests, persists while app is running)
- All settings from `wizard_template.json`

### Statistics
- Total upload/download and connection count
- **Traffic by Outbound**: expandable cards per proxy node
- Each connection: host:port, protocol (TCP/UDP), rule, traffic, duration, chain
- Tap **Connections** counter to open full connection list with close buttons

### App Settings
- Theme: **System / Light / Dark**
- **Auto-start on boot**: VPN starts when device boots
- **Keep VPN on exit**: VPN stays active when app is swiped away

### Config Editor
- View and edit raw sing-box JSON config
- Pretty-printed display
- Save, paste from clipboard, load from file

---

## For Developers

See [docs/](docs/) for architecture, build instructions, and development guide:
- [Architecture](docs/ARCHITECTURE.md)
- [Build](docs/BUILD.md)
- [Development Guide](docs/DEVELOPMENT_GUIDE.md)
- [Development Report](docs/DEVELOPMENT_REPORT.md)

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

## Feature Specs

Every feature is documented as a spec in [`docs/spec/features/`](docs/spec/features/). This is the core of the **spec-driven development** approach.

### Implemented (23)

| # | Feature |
|---|---------|
| [001](docs/spec/features/001%20mobile%20stack/) | Mobile Stack (Android + iOS) |
| [002](docs/spec/features/002%20mvp%20scope/) | MVP Scope |
| [003](docs/spec/features/003%20home%20screen/) | Home Screen (groups, nodes, traffic, sort, filter) |
| [004](docs/spec/features/004%20subscription%20parser/) | Subscription Parser (8 protocols + Xray JSON) |
| [005](docs/spec/features/005%20config%20generator/) | Config Generator (Wizard Template) |
| [006](docs/spec/features/006%20servers%20ui/) | Servers UI (subscriptions, toggles, detail tabs, paste dialog) |
| [007](docs/spec/features/007%20config%20editor/) | Config Editor |
| [008](docs/spec/features/008%20ping%20and%20node%20management/) | Ping & Node Management (mass ping, settings, URLTest) |
| [009](docs/spec/features/009%20ux%20and%20theme/) | UX & Theme (dark mode, autosave, animations) |
| [010](docs/spec/features/010%20quick%20start%20and%20offline/) | Quick Start & Offline (caching, fallback) |
| [011](docs/spec/features/011%20local%20ruleset%20cache/) | Local Rule Set Cache |
| [012](docs/spec/features/012%20native%20vpn%20service/) | Native VPN Service (auto-start, keep on exit) |
| [013](docs/spec/features/013%20routing/) | Routing (groups, rules, per-app proxy) |
| [014](docs/spec/features/014%20dns%20settings/) | DNS Settings (16 presets, JSON editor) |
| [015](docs/spec/features/015%20speed%20test/) | Speed Test (10 servers, per-server ping, upload) |
| [016](docs/spec/features/016%20statistics%20and%20connections/) | Statistics & Connections (process/app name) |
| [017](docs/spec/features/017%20custom%20nodes%20and%20node%20settings/) | Custom Nodes & Node Settings (JSON editor, detour) |
| [018](docs/spec/features/018%20detour%20server%20management/) | Detour Server Management (⚙ prefix, register/use/override) |
| [019](docs/spec/features/019%20wireguard%20endpoint/) | WireGuard Endpoint (URI + INI config) |
| [021](docs/spec/features/021%20ci%20cd%20pipeline/) | CI/CD Pipeline (tag → release) |
| [022](docs/spec/features/022%20app%20settings/) | App Settings (theme, boot, keep on exit) |
| [023](docs/spec/features/023%20debug%20and%20logging/) | Debug & Logging |

### Partial

| # | Feature | Status |
|---|---------|--------|
| [020](docs/spec/features/020%20security%20and%20dpi%20bypass/) | Security & DPI Bypass | TLS fragment done; encrypted storage planned |

### Planned

| # | Feature |
|---|---------|
| [024](docs/spec/features/024%20load%20balance/) | Load Balance |
| [025](docs/spec/features/025%20warp%20integration/) | WARP Integration (Cloudflare) |

---

## Documentation

| Document | Description |
|----------|-------------|
| [`docs/PROTOCOLS.md`](docs/PROTOCOLS.md) | Protocol URI formats, parameters, and sing-box mapping |
| [`docs/DEVELOPMENT_GUIDE.md`](docs/DEVELOPMENT_GUIDE.md) | **How to develop**: principles, risks, testing, AI workflow |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Architecture, data flows, native code |
| [`docs/BUILD.md`](docs/BUILD.md) | Build instructions, CI, APK signing |
| [`docs/DEVELOPMENT_REPORT.md`](docs/DEVELOPMENT_REPORT.md) | Full development history (10 stages) |
| [`CHANGELOG.md`](CHANGELOG.md) | Release changelog |
| [`docs/spec/features/`](docs/spec/features/) | **44 feature specifications** (spec-driven development) |

---

## License

TBD
