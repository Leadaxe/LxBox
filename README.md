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

Add servers by subscription URL, direct proxy link, WireGuard URI/INI, or raw sing-box JSON outbound. Smart-paste dialog auto-detects format and previews the content. Enable/disable subscriptions without deleting. Offline rehydrate — nodes restored from body cache after app restart. Per-subscription settings for detour servers.

- **9 protocols**: VLESS, VMess, Trojan, Shadowsocks, Hysteria2, **TUIC v5**, SSH, SOCKS, WireGuard
- Formats: Base64, Xray JSON Array (chained proxy), plain text, raw sing-box JSON
- Per-subscription **Update interval** picker (1/3/6/12/24/48/72/168h), honors `profile-update-interval` header
- Subscription row subtitle: `124 nodes · 🔄 24h · 🕐 3h ago · (2 fails)`
- Title fallback from `Content-Disposition: filename=...` (RFC 5987)
- Quick Start with built-in free VPN preset
</details>

<details>
<summary><strong>Subscription auto-update</strong> — 4 triggers, hard gates against spam</summary>

Subscriptions refresh in the background without spamming providers. Every request is gated; nothing runs off the rails.

- **Triggers**: app start · 2 min after VPN connected · every hour · immediately on VPN disconnected · manual ⟳ (force)
- **Gates**: `minRetryInterval=15min` (persists via `lastUpdateAttempt`), `maxFailsPerSession=5` (in-memory, thaws on app restart), `10s ± 2s` between subs, `_running`/`_inFlight` dedup flags, `inProgress` guard against double-clicks
- Crash-safe init sweep: stuck `inProgress` on disk resets to `failed`
- Rebuild config **never** triggers HTTP — only local assembly from loaded nodes
- See [spec 027](docs/spec/features/027%20subscription%20auto%20update/spec.md)
</details>

<details>
<summary><strong>Home Screen</strong> — connect and manage nodes</summary>

One-tap VPN start/stop with animated status chip. Choose proxy group, sort nodes by ping/name, mass-ping all servers. Traffic bar shows real-time speed, connections count, uptime.

- **Node row layout** (v1.3.1+): `[ACTIVE green pill] PROTOCOL · · · 50MS →` — protocol label (VLESS/Hy2/WG/TUIC/SS) from outbound type, ping right-aligned with colour by latency
- Proxy groups: `auto-proxy-out`, VPN ①/②/③
- Node filter: choose which nodes participate in auto-selection
- Detour servers (⚙) visibility toggle
- Sticky restart warning under Stop — doesn't disappear when you cancel Stop dialog
- Long-press: Ping · Use this node · View JSON · **Copy URI** (vless://, wireguard://, etc) · Copy server (JSON) · Copy detour · Copy server + detour
</details>

<details>
<summary><strong>Routing</strong> — control where traffic goes</summary>

Fine-grained control over traffic routing. Block ads, route Russian domains directly, send BitTorrent through specific proxy. Create named app groups with per-app routing.

- Preset routing rules with per-rule outbound selection
- App Groups: route specific apps through chosen proxy
- Default traffic fallback (`route.final`)
- All changes autosaved, restart warning pops up automatically
</details>

<details>
<summary><strong>Detour Servers</strong> — chain proxies for extra privacy</summary>

Build multi-hop chains: your traffic goes through an intermediate server before reaching the final proxy. Great for bypassing geo-restricted networks: put your home WireGuard as a detour → foreign mobile internet becomes a tunnel to home.

- Add your own server (paste URI / paste JSON / WG INI) — it becomes a candidate for detour
- **Mark as detour server** switch in Node Settings — adds `⚙ ` prefix
- **Override detour** per subscription: route all its nodes through your chosen server
- Register / Use toggles for detour servers from subscriptions
- Detour dropdown in Node Settings persists via `overrideDetour` (no JSON roundtrip drift)
</details>

<details>
<summary><strong>DNS Settings</strong> — full control over name resolution</summary>

16 DNS server presets (Cloudflare, Google, Yandex, Quad9, AdGuard) with UDP/DoT/DoH variants. Custom servers via JSON editor. Strategy, cache, rules — all configurable.

- Enable/disable servers with switches
- DNS Strategy: prefer_ipv4 / prefer_ipv6 / ipv4_only / ipv6_only
- DNS Rules editor, DNS Final, Default Domain Resolver
- Inline `.ru/.su/.xn--p1ai` rule for Yandex DoH
</details>

<details>
<summary><strong>DPI Bypass</strong> — bypass censorship</summary>

Three orthogonal tricks — combinable on the same outbound.

- **TLS Fragment** — splits ClientHello over TCP segments
- **TLS Record Fragment** — splits handshake into multiple TLS records
- **Mixed-case SNI** (v1.3.0+) — randomises `server_name` case (`WwW.gOoGle.CoM`). Bypasses naive exact-match DPI used by regional providers. Per RFC 6066 SNI is case-insensitive; the trick doesn't change server behaviour. Ineffective against GFW-class filtering.
- All tricks applied to first-hop only (inner hops are inside the tunnel, local DPI doesn't see them).
- See [spec 020](docs/spec/features/020%20security%20and%20dpi%20bypass/spec.md), [spec 028](docs/spec/features/028%20antidpi%20sni%20obfuscation/spec.md)
</details>

<details>
<summary><strong>Haptic Feedback</strong> — vibro on VPN events</summary>

Short vibration on VPN transitions, errors, and taps. Respects the Android system Touch feedback setting.

- Tap Start/Stop → light tick
- VPN connected → medium impact; user disconnect → light
- Revoked / heartbeat fail (first only, not per tick) → heavy
- Manual subscription fetch success/fail → light/medium
- Auto triggers don't vibrate; 100 ms throttle prevents spam
- Toggle in App Settings → Feedback (default **on**)
- See [spec 029](docs/spec/features/029%20haptic%20feedback/spec.md)
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

Organized in sections: General, Clash API, Network, Include Auto, DNS, TUN, DPI Bypass. URLTest parameters for auto-proxy latency testing. All changes autosaved.
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
- Auto-rebuild config on settings change
- Haptic feedback toggle
</details>

---

## Supported Protocols

| Protocol | URI scheme | Transport |
|----------|-----------|-----------|
| VLESS | `vless://` | TCP, WebSocket, gRPC, H2, HTTPUpgrade, REALITY |
| VMess | `vmess://` (v2rayN base64) | TCP, WebSocket, gRPC, H2, HTTPUpgrade |
| Trojan | `trojan://` | TCP, WebSocket, gRPC |
| Shadowsocks | `ss://` (SIP002 + legacy + SS2022) | TCP, UDP, SIP003 plugins |
| Hysteria2 | `hy2://` / `hysteria2://` | QUIC, Salamander obfs |
| **TUIC v5** | `tuic://` | QUIC, BBR/CUBIC/NewReno, zero-RTT |
| SSH | `ssh://` | TCP, host key / password / private key |
| SOCKS | `socks://` / `socks5://` | TCP, auth |
| WireGuard | `wireguard://`, INI config | UDP, multi-peer |

**XHTTP transport** auto-falls back to HTTPUpgrade (sing-box 1.12.x doesn't support xhttp natively) — warning surfaced in UI.

See [Protocol Documentation](docs/PROTOCOLS.md) for full URI format details and sing-box mapping.

---

## Architecture

L×Box is built around a **3-layer parser/builder pipeline** (spec 026, v1.3.0+):

```
UI / Controller
  │
  ▼
parseFromSource(source)  ← HTTP fetch + body_decoder + typed parser
  │                         returns: List<NodeSpec>, meta, rawBody
  ▼
ServerList (sealed)      ← SubscriptionServers | UserServer
  │ .build(ctx)            applies tagPrefix, detour policy, allocateTag
  ▼
buildConfig(lists, settings)  ← template + post-steps (DPI, DNS, rules)
  │                              returns: BuildResult{ config, validation, warnings }
  ▼
sing-box JSON
```

- **Sealed `NodeSpec`** — 9 protocols, polymorphic `emit(vars)` / `toUri()` (round-trip invariant)
- **`EmitContext`** — passes template vars into per-node emit
- **`NodeEntries{main, detours[]}`** — named struct for chain results
- **`ValidationResult`** — typed issues: dangling refs, empty urltest, invalid selector default

See [Architecture](docs/ARCHITECTURE.md) for the full picture.

---

## Development

Spec-driven development — 29 feature specifications document every capability.

| Document | Description |
|----------|-------------|
| [Protocol Reference](docs/PROTOCOLS.md) | URI formats, parameters, sing-box mapping |
| [Architecture](docs/ARCHITECTURE.md) | 3-layer pipeline, data flows, native bridge |
| [Build](docs/BUILD.md) | Build instructions, CI, APK signing, local-build marker |
| [Development Guide](docs/DEVELOPMENT_GUIDE.md) | Principles, testing (128 tests), spec organisation |
| [Changelog](CHANGELOG.md) | Release history |
| [Release Notes](docs/releases/) | Detailed per-version notes (EN + RU) |

### Local build

```bash
./scripts/build-local-apk.sh
```

The script wraps `flutter build apk --release` with `--dart-define`s that embed git describe info. About screen shows a pink **🧪 LOCAL BUILD · N commits since vX.Y.Z** badge to distinguish from CI builds.

---

## License

TBD
