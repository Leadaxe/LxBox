# L×Box v1.1.2

Android VPN client powered by [sing-box](https://sing-box.sagernet.org/).

## What's New

### Detour Server Management
- **⚙ prefix** for intermediate/detour servers — clear visual distinction
- **Per-subscription control**: Register (show in node list), Use (enable routing), Override (replace with your server)
- Detour dropdown in node settings for building multi-hop chains

### JSON Outbound Import
- Paste raw sing-box JSON outbound from clipboard
- Smart paste dialog auto-detects format (subscription URL, proxy link, WireGuard config, JSON)
- Each server as separate entry with full JSON editor

### Node Settings
- Edit any server as JSON — tag, detour, all parameters
- Save button + copy button in JSON editor
- Works for both URI-parsed and JSON-imported servers

### TLS Fragment (DPI Bypass)
- Fragment and Record Fragment toggles
- Applied only to first-hop outbounds
- Configurable fallback delay

### WireGuard Endpoint
- Correct sing-box 1.12+ endpoint structure (not deprecated outbound)
- Auto-detect WireGuard INI config from clipboard
- IPv6 endpoint support

### Speed Test
- 10 servers worldwide (Cloudflare, Hostkey 5 cities, Selectel, Tele2, OVH, ThinkBroadband)
- Per-server ping URL for accurate latency measurement
- Upload test with configurable method (PUT/POST)

### UI Improvements
- Animated VPN status chip (spinning on connect)
- Config dirty indicator — rebuild button highlights when changes pending
- Auto-rebuild config option in App Settings
- Subscription detail: Nodes / Settings / Source tabs
- Source tab shows HTTP headers and raw subscription data
- Connections screen: process/app name, expanded layout
- Copy menu: server / detour / both (detour stripped from copies)
- Compact + button for adding servers
- Sections in VPN Settings

### Other
- Renamed from BoxVPN to L×Box
- Free VPN dialog with checkboxes and credits
- Donate dialog (USDT ERC20/TRC20, Boosty)
- Ping concurrency reduced to 10, timeout increased to 10s
- 25 restructured feature specs
- Comprehensive protocol documentation

## Install
Download `LxBox-v1.1.2.apk` and install on Android device.
