# L×Box v1.2.0

Android VPN client powered by [sing-box](https://sing-box.sagernet.org/).

## What's New in v1.2.0

### Outbound Groups Overhaul
- Renamed **proxy-out → vpn-1**, added **vpn-3** (now VPN ①/②/③ all available)
- **VPN ①** is always generated — toggle is locked (required base group)
- **auto-proxy-out** is now controlled by an **Include Auto** toggle — when on, it's generated as urltest and added to `vpn-*` groups; when off, no auto section is produced at all

### Node List UX
- **direct-out** and **auto-proxy-out** are pinned at the top of the node list in every sort mode (direct first, then auto), with a subtle highlight so they stand out
- Long-press context menu cleaned up:
  - No Copy actions for `direct-out` / `auto-proxy-out` (they're not real servers)
  - *Copy detour* and *Copy server + detour* hidden when a node has no detour

### Defaults
- `urltest_tolerance` default changed from 100 → 30 ms (switches faster when latency improves)

## Prior highlights (v1.1.x)

- Detour server management (⚙ prefix), per-subscription register/use/override, multi-hop chains
- Smart Paste dialog (subscription URL / proxy link / WireGuard INI / JSON)
- Node Settings JSON editor
- TLS Fragment / Record Fragment DPI bypass
- WireGuard endpoint (sing-box 1.12+) with IPv6 support
- Speed Test with 10 global servers
- Animated status chip, config-dirty banner, restart-VPN banner, auto-rebuild
- SRS rule-set cloud status (green = cached, red = download error)
- Subscription HTTP headers: `subscription-userinfo`, `profile-title`, `profile-web-page-url`, `profile-update-interval`

## Install

Download `app-release.apk` from this release, enable "Install unknown apps" for your browser, tap the APK to install.
