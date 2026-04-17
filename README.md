# BoxVPN

Android VPN client powered by [sing-box](https://sing-box.sagernet.org/). Multi-subscription, smart routing, built-in speed test.

**[Download latest release](https://github.com/Leadaxe/BoxVPN/releases/latest)** | **[Документация на русском](README_RU.md)**

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

## Architecture

```
wizard_template.json          <- Single source of truth for all defaults
    |
    +-- dns_options            (16 DNS servers + rules)
    +-- ping_options           (URL, timeout, presets)
    +-- speed_test_options     (servers, streams, ping URLs)
    +-- preset_groups          (proxy groups: auto/selector/vpn)
    +-- vars                   (all config variables)
    +-- selectable_rules       (routing rules with SRS)
    +-- config                 (sing-box config skeleton)

boxvpn_settings.json          <- User overrides (SharedPreferences)
    |
    +-- vars                   (user-changed variables)
    +-- proxy_sources          (subscriptions)
    +-- dns_options            (user DNS server/rule changes)
    +-- enabled_rules          (routing rule toggles)
    +-- excluded_nodes         (node filter)
    +-- app_rules              (per-app routing)

ConfigBuilder.generateConfig()
    |
    1. Load wizard_template
    2. Substitute @vars
    3. Load & parse subscriptions (with disk cache fallback)
    4. Filter excluded nodes (urltest only)
    5. Build preset groups
    6. Apply routing rules
    7. Apply DNS servers & rules
    8. Cache remote SRS rule sets
    9. Output sing-box JSON
```

### Tech Stack
- **Flutter** (Dart 3.11+), Material 3
- **sing-box** native library (libbox 1.12.12 via JitPack)
- **Clash API** for real-time proxy management
- Gradle Kotlin DSL, AGP 8.11.1, Kotlin 2.2.20, Java 17

### Project Structure
```
app/
  lib/
    controllers/        HomeController, SubscriptionController
    models/             HomeState, ProxySource, ParsedNode, WizardTemplate
    screens/            12 screens (home, routing, subscriptions, DNS, speed test, etc.)
    services/           ConfigBuilder, SourceLoader, ClashApiClient, UrlLauncher, etc.
    widgets/            NodeRow
    vpn/                BoxVpnClient (MethodChannel/EventChannel)
  android/
    app/src/main/kotlin/
      vpn/              VpnPlugin, BoxVpnService, ConfigManager
      MainActivity.kt   MethodChannel for URL opening
  assets/
    wizard_template.json
    get_free.json
```

---

## Build

### Prerequisites
- Flutter SDK 3.41+
- Java 17 (Temurin)
- Android SDK with platforms 34-36, build-tools 35, NDK 28

### Local build
```bash
cd app
flutter pub get
flutter build apk --release
```

### CI/CD
GitHub Actions workflow supports:

| Trigger | What happens |
|---------|-------------|
| Push to `main` | Checks only (analyze + test) |
| Push tag `v*` | Checks + Build APK + GitHub Release (draft) |
| Manual `run_mode=build` | Checks + Build APK |
| Manual `run_mode=release` | Checks + Build APK + GitHub Release |

```bash
# Stable release
git tag v1.2.0
git push origin v1.2.0

# Manual build
gh workflow run CI --repo Leadaxe/BoxVPN -f run_mode=build

# Manual release
gh workflow run CI --repo Leadaxe/BoxVPN -f run_mode=release
```

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

---

## Feature Specs

Every feature is documented as a spec in [`docs/spec/features/`](docs/spec/features/). This is the core of the **spec-driven development** approach.

| # | Feature | Status |
|---|---------|--------|
| 001 | Mobile Stack (Android + iOS) | Done |
| 002 | MVP Scope | Done |
| 003 | Home Screen (Groups & Nodes via Clash API) | Done |
| 004 | Subscription Parser (8 protocols) | Done |
| 005 | Config Generator (Wizard Template) | Done |
| 006 | Subscription & Settings UI | Done |
| 007 | Config Editor (JSON formatting) | Done |
| 008 | Ping & Node Management | Done |
| 009 | Dark Theme & UX | Done |
| 010 | Quick Start & Auto-refresh | Done |
| 011 | Local Rule Set Cache | Done |
| 012 | Xray JSON Array + Chained Proxy | Done |
| 013 | Native VPN Service | Done |
| 014 | Subscription Detail View | Done |
| 015 | Rule Outbound Selection | Done |
| 016 | Routing Screen | Done |
| 017 | Per-App Proxy (Split Tunneling) | Done |
| 018 | Custom Nodes (Manual + Override) | Spec |
| 019 | Load Balance | Spec |
| 020 | Multi-hop / Chained Proxy UI | Spec |
| 021 | Speed Test | Done |
| 022 | Node Filter (auto-proxy-out) | Done |
| 023 | Auto-connect on Boot | Done |
| 024 | Statistics & Connections | Done |
| 025 | DNS Settings | Done |
| 026 | Subscription Toggles (Enable/Disable) | Done |
| 027 | Autosave (No Apply Buttons) | Done |
| 028 | Subscription Caching (Offline Fallback) | Done |
| 029 | Subscription Context Menu | Done |
| 030 | URL Launcher (Intent-based Links) | Done |
| 031 | Wizard Template Architecture | Done |
| 032 | Ping Settings (URL Presets) | Done |
| 033 | URLTest Configuration | Done |
| 034 | Node Context Menu | Done |
| 035 | Traffic Bar & Navigation | Done |
| 036 | Sort Modes (Default/Ping/A-Z) | Done |
| 037 | CI/CD Pipeline (Tag → Release) | Done |
| 038 | Subscription Detail Enhancements | Done |
| 039 | Security Hardening | Partial |
| 040 | TLS Fragment (DPI Bypass) | Done |
| 041 | WireGuard Endpoint Support | Done |
| 042 | Node Settings (JSON Editor, Detour) | Done |
| 043 | Smart Paste Dialog | Done |
| 044 | Detour Server Naming (⚙ Prefix) | Done |

---

## Documentation

| Document | Description |
|----------|-------------|
| [`docs/DEVELOPMENT_GUIDE.md`](docs/DEVELOPMENT_GUIDE.md) | **How to develop**: principles, risks, testing, AI workflow |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Architecture, data flows, native code |
| [`docs/BUILD.md`](docs/BUILD.md) | Build instructions, CI, APK signing |
| [`docs/DEVELOPMENT_REPORT.md`](docs/DEVELOPMENT_REPORT.md) | Full development history (10 stages) |
| [`CHANGELOG.md`](CHANGELOG.md) | Release changelog |
| [`docs/spec/features/`](docs/spec/features/) | **44 feature specifications** (spec-driven development) |

---

## License

TBD
