# В данном форке:
- заменена используемая для регистрации WARP ссылка на API на незабаненную ссылку на API для Zero Trust,
- изменены наборы SNI и конечных точек для WARP,  
- изменён параметр по умолчанию Ib = curl вместо chrome.  
# Возможные адреса эндпоинтов WARP по протоколу MASQUE:
162.159.198.\*, 162.159.199.\* - для обычных пользователей<br />
162.159.197.\* - доступен только с Zero Trust<br />
\* заменяем на:<br />
- число 0 или число от 3 до 255 - только MASQUE h2 (TCP)<br />
- число 1 - только MASQUE h3 (UDP)<br />
- число 2 - MASQUE h3 (UDP) или MASQUE h2 (TCP)<br />

На адресах 162.159.198.\* и 162.159.199.\* возможны разные колокации, например:<br />
162.159.198.\* - colo=HEL (аэропорт Хельсинки) <br />
162.159.199.\* - colo=LED (аэропорт Пулково, Санкт-Петербург)<br />

Конечные точки смотрите по ссылке:  
https://help-guide.notion.site/Cloudflare-WARP-1f82684dab0d8024a1c8fec230f5e4e1

# L×Box

[![GitHub](https://img.shields.io/badge/GitHub-Leadaxe%2FLxBox-blue)](https://github.com/Leadaxe/LxBox)
[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Version](https://img.shields.io/github/v/release/Leadaxe/LxBox?label=version)](https://github.com/Leadaxe/LxBox/releases)
[![Dart](https://img.shields.io/badge/Dart-3.11%2B-blue)](https://dart.dev/)

Android VPN client powered by [sing-box-lx](https://github.com/Leadaxe/sing-box-lx) — a [sing-box](https://sing-box.sagernet.org/) fork with AmneziaWG 2.0 and native XHTTP. Multi-subscription, smart routing, built-in speed test. English and Russian UI.

**[Download latest release](https://github.com/Leadaxe/LxBox/releases/latest)** | **[Документация на русском](README.ru.md)** | **[User Guide](docs/USER_GUIDE.md)** | **[Support the project](docs/DONATE.md)**

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
<img src="docs/screenshots/routing_rules.jpg" width="240" alt="Routing Rules"/>
<img src="docs/screenshots/app_picker.jpg" width="240" alt="App Picker"/>
<img src="docs/screenshots/app_settings.jpg" width="240" alt="App Settings"/>
</p>

---

## Features

<details>
<summary><strong>Servers & Subscriptions</strong> — every proxy source in one place</summary>

Add servers by subscription URL, direct proxy link, WireGuard URI/INI, Amnezia `vpn://` link, raw sing-box JSON — a single outbound or a **whole config**, from which nodes, auto-select groups and detour chains are imported (§368) — or **Import from file…** (a local `.txt`/`.json`; a file with more than one node becomes a file-backed subscription, §129). The smart-paste dialog auto-detects the format and previews the content. Enable/disable subscriptions without deleting them. Offline rehydrate — nodes are restored from the body cache on app restart.

- **12 protocols**: VLESS (incl. post-quantum ML-KEM-768 encryption, §335), VMess, Trojan, Shadowsocks, Hysteria2, **TUIC v5**, **NaïveProxy**, **AnyTLS** (§269), SSH, SOCKS, WireGuard (incl. **AmneziaWG / AWG 2.0** — `awg://` URI, AmneziaWG `.conf`, **Amnezia `vpn://` links**, JSON), **MASQUE** (Cloudflare WARP — `masque://`, QUIC/HTTP-3)
- Formats: Base64, Xray JSON Array (incl. dialerProxy chains and every protocol in the array, §321), plain text, sing-box JSON — outbound, array, whole config or array of configs, with groups and `detour` chains (§368)
- **Node deduplication** (§321) — one server listed several times across a subscription collapses into a single node
- **Auto nodes** (§322) — a provider's "Auto | Best server" entry arrives as one node with a pool inside: the row shows mode and contents (`🔀 [15/7]` — load balance, `🎯 [3]` — single fastest). You can build your own inside a folder: "Add auto node…" — membership by regex rule, by checkbox list, or "all servers in this folder"
- **Disable individual nodes** (§283) — a switch on every subscription node; the choice is bound to a stable node hash, so it survives updates, restarts and provider-side renames
- **Filters — subscription processing rules** (§302) — applied on import and on every update: conditions are `path operator value` (contains/equals/regex, Not, AND/OR), actions are **Disable** / **Enable** (§332; the last matching rule wins, so "disable all → enable NL" works as a whitelist) / **Replace** (write a new value at a path, with `$1`, `$2`… backreferences from regex capture groups). The **Matches** tab shows what a rule will do before you save it
- **Inspect node** (§302) — tap a subscription node: the JSON tab (what actually goes into the config) and the Source tab (the raw subscription fragment it was built from); Source has a **Decode base64** checkbox for encoded bodies
- **Fetch identity** (§289) — User-Agent / HWID / device headers configurable per subscription (Default = global values, Custom = its own set); panels behind an HWID gate return real nodes instead of an "App not supported" placeholder (§310)
- **On update** (§323/§331) — what to do when an update brings a new node set: rebuild the config only (default), rebuild and reload the core, or do nothing; it fires only when the node set actually changed
- **Test servers** (§339) — ping the nodes of a subscription or folder without starting the VPN; while the VPN is running you get an explicit "Stop VPN / Cancel" gate instead of misleading numbers measured through the live tunnel (§236)
- **File subscription** (§129) — a multi-node local file lives as a subscription badged `file`; **Edit source…** changes the URL or switches online↔file without re-creating it
- Per-subscription update interval (1–168 h), `profile-update-interval` header honored; optional "update disabled subscriptions too" (§337)
- Subscription row subtitle: `124 nodes · 🔄 24h · 🕐 3h ago · (2 fails)`; title fallback from `Content-Disposition` (RFC 5987)
- **Get WARP** — one-tap Cloudflare WARP (WireGuard or MASQUE), see below
</details>

<details>
<summary><strong>Get WARP</strong> — one-tap Cloudflare WARP, keys generated on-device</summary>

Tap **Get WARP** on the servers screen → a tunnel to Cloudflare is registered and added as a node. No copy-pasting configs from third-party generator sites.

- **Transport**: **WireGuard** (default) or **MASQUE** (CONNECT-IP over QUIC/HTTP-3, HTTP/2 fallback — often exits from a foreign IP and looks like plain HTTPS to DPI). For MASQUE you also pick h3/h2, SNI and idle/keep-alive.
- **On-device registration**: the private key is generated on the phone and never leaves it — only the public key is sent to Cloudflare (`api.devices.cloudflare.com`). WireGuard uses X25519, MASQUE uses ECDSA P-256. Third-party generator workers are not used: they hand out a server-generated private key.
- **Add Amnezia obfuscation** (WireGuard transport): masks the WARP handshake from DPI with junk traffic mimicking a QUIC-Initial (default) or SIP template; SNI, level and Jc/Jmin/Jmax live under *Advanced*. Enable it when plain WARP is throttled or blocked.
- **Persistent keepalive** (§304) — a field under *Advanced* (25 s by default): without it the carrier drops the NAT UDP mapping while the node is idle and the node silently dies.
- **Custom endpoint** — a manual `IP:port` under *Advanced*; for MASQUE, a port picked from the known-working list (§305).
- **SCAN WARP** (§284) — the **Make experiment** button in the wizard creates an experiment folder: it generates a pool of WARP variants (WireGuard / AWG / MASQUE h2/h3) across Cloudflare address ranges and pings them; dead nodes disable themselves. Finds a working endpoint on your specific network without manual trial and error.
- **WARP+** (optional): paste a license key under *Advanced* to bind WARP+ (Argo Smart Routing). Empty = free WARP.
- **Idempotent**: re-tapping reuses the cached account instead of registering a new device; *Re-register* forces a fresh one.
- See [spec 025](docs/spec/features/025%20warp%20integration/spec.md)
</details>

<details>
<summary><strong>Subscription auto-update</strong> — 6 triggers, hard gates against spam</summary>

Subscriptions refresh in the background without spamming providers. Every request is gated; nothing runs off the rails.

- **Triggers**: app start · app resumed from background (§291) · 2 min after VPN connected · every hour · immediately on VPN disconnected · manual ⟳ (force)
- **Gates**: `minRetryInterval=15min` (persists via `lastUpdateAttempt`), `maxFailsPerSession=5`, `10s ± 2s` between subscriptions, dedup flags against concurrent runs and double-clicks
- Crash-safe init sweep: a stuck `inProgress` on disk resets to `failed`
- Rebuilding the config **never** triggers HTTP — only local assembly from already-loaded nodes
- See [spec 027](docs/spec/features/027%20subscription%20auto%20update/spec.md)
</details>

<details>
<summary><strong>Home Screen</strong> — connect and manage nodes</summary>

One-tap VPN start/stop with an animated status chip. Pick a direction, sort nodes by ping/name/manual order, mass-ping every server. The traffic bar shows real-time speed, connection count and uptime.

- **Node row**: `[ACTIVE] PROTOCOL · · · 50MS` — protocol label from the outbound type, ping right-aligned and coloured by latency; subtitle `PROTOCOL · transport · security` (`VLESS·xhttp·TLS`, `WG·awg2`) shows what is inside a node without opening JSON
- **Auto nodes in the list** (§322/§344) — the row shows mode and the live pool (`🔀 [15/7]` with country flags); the node detail screen understands urltest modes
- **⚠ dependency graph** (§355) — if a node with an ERR ping is the detour for other nodes or DNS servers, a ⚠ appears next to its name; tapping it opens the list of affected entries with the dependency path, plus a banner for the DNS branch
- **Per-direction ping** (§325) — each direction keeps its own measurements (test URL and timeout are per-direction); a node not yet tested in this direction shows the measurement from another one, dimmed and marked `~`
- **Filter workspace**: a filter panel with **Regex · Protocol · Subscribes · Settings** tabs plus active-filter summary chips; each category has its own `!` inversion; transport/security chip row (`tcp`/`ws`/`grpc`/`quic`/`xhttp` + `TLS`/`Reality`/`awg`…); filters are remembered per direction; regex is case-insensitive at every point (§301)
- **Tri-state detour filter**: show all / hide detours / detours only
- **Directions** (§125/§393) — any number of route groups with tags of your choosing (add/rename/delete; `vpn-1` is undeletable), each with a regex node filter, an optional auto twin (`<tag>-auto`, Fastest or Load balance), an optional Include block and other directions listed above it
- **Empty state** (§328) — with zero servers the home screen shows a full-screen guide linking to Servers and to backup restore, instead of a dead Start button
- Custom sort order survives restart; long-press: Ping · Use this node · View JSON · Copy URI; "Share URL" without an intermediate dialog (§347)
</details>

<details>
<summary><strong>Quick Connect</strong> — toggle the VPN without opening the app</summary>

- **Quick Settings tile** — tap to toggle, with a live `Connected` / `Connecting…` subtitle. Add it via App Settings → General → Quick connect (system prompt on Android 13+).
- **Long-press the launcher icon** → **Toggle VPN**.
- **Notification actions** (§182) — **Stop** / **Reconnect** buttons right in the persistent notification; fully native, they work even when the UI process has been killed.
- The first run briefly flashes the app for the system VPN consent dialog (an Android API requirement); afterwards there is no UI flash. The tile survives an OOM-kill of the service and won't falsely claim "Connected".
</details>

<details>
<summary><strong>Routing</strong> — one unified rule model</summary>

Block ads, route Russian domains directly, send BitTorrent through a chosen direction, route per-app, match private subnets. Every user rule is a single model with all match fields in parallel (OR within a category, AND across them — the sing-box default rule formula).

- **4 tabs**: Directions · Presets (read-only catalog → Copy to Rules) · Rules (your registry) · Tunnel apps (OS-level split tunneling)
- **Match fields**: domain / domain_suffix / domain_keyword, ip_cidr, ports and port ranges, packages (per-app), application protocols (tls/quic/bittorrent/…), **traffic type tcp/udp/icmp** (§240 — e.g. UDP direct, TCP through the tunnel), ip_is_private and source_ip_is_private, **inbound** (packet arrived via TUN or via the local proxy, §119), **wifi_ssid / wifi_bssid**, remote .srs rule-set
- **Traffic Processing** (§264) — a pinned preset at the top of the rule list holding the traffic pre-processing the rest of routing depends on: sniff, Hijack DNS and destination resolution. It cannot be disabled, deleted or moved — you change its settings inside the preset
- **Action & Resolve** — the gear next to Action, with three modes: plain route to a direction; **Resolve first** — resolve the domain before routing with a forced address family and the full sing-box resolve option set (strategy, DNS server, cache, TTL, client subnet, timeout); **Resolve only** — the rule resolves and lets later rules pick the route. **Force IPv4 (drop AAAA)** (§256) answers AAAA queries locally — a lifesaver on networks with half-broken IPv6
- **Rule-level DNS** (§257) — the **Send DNS to dedicated server** switch attaches a paired DNS rule to the routing rule: the rule's domains get resolved by a dedicated server (auto = follow the route's direction), so one rule decides both route and resolution
- **Raw-JSON rule** (§225) — a rule can be written as a raw `route.rules` fragment for fields the form doesn't expose; syntax is validated as you type
- **SRS is local-only** — no auto-update, manual download via the ☁ icon, the rule stays disabled until it is cached
- Drag-reorder, long-press → Delete with confirmation, dirty-aware save ("Discard changes?"), a View tab with the exact sing-box fragment
- Default traffic fallback (`route.final`)
- See [spec 030](docs/spec/features/030%20custom%20routing%20rules/spec.md), [spec 011](docs/spec/features/011%20local%20ruleset%20cache/spec.md)
</details>

<details>
<summary><strong>Load balancing</strong> — spread traffic across a pool of servers</summary>

A direction's **auto** group can do more than pick the single fastest node. Switch it to **Load balance** and it spreads new connections across a **pool** of N servers (round-robin), while keeping sessions sticky to their server so TLS/auth don't bounce between IPs.

- **Two modes** in the direction editor → *Include auto*: **Fastest** (`least_test`) — one best node by latency; **Load balance** (`round_robin`) — connections rotate across a fixed-size pool of live nodes
- **Pool size** — how many nodes sit in the pool; **Pool tolerance** — `0` keeps the pool full (speed-agnostic), `>0` evicts slower nodes in favour of faster ones
- **Sticky session by** — chip row (`process` / `domain` / `source ip` / `dest ip` / `dest port`); a key like `process + domain` lands every connection of one app to one site on the **same** pool server. Clear all chips → pure rotation
- **View pool** — long-press the auto node → the live pool: `slot · node · delay`
- Built on sing-box-lx SPEC 019 (fixed slots, lazy health-check, slot-hash stickiness — no per-connection state)
- See [§208 spec](docs/spec/tasks/208-urltest-balancer-round-robin.md)
</details>

<details>
<summary><strong>Wi-Fi-aware routing</strong> — different rules on different networks</summary>

Declare rules like *"on this Wi-Fi → direct"* persistently — no temporary hacks. `wifi_ssid` / `wifi_bssid` AND-combine with every other match field:

- `wifi_ssid: [HomeWiFi] → direct` — bypass the VPN at home
- `wifi_ssid: [OfficeWiFi] AND domain: [*.bank.com] → direct` — banking direct only on the office network
- `rule_set: [geosite-ru] AND wifi_ssid: [HomeWiFi] → ru-direct` — country-specific routing per Wi-Fi

The rule editor offers chips with **Add current** (read the live SSID), **Pick saved** (history of visited networks) and **Manual**; Android permission gates are wired in. Network history is recorded only if you opt in (App Settings → Diagnostics), a network is stored after ≥5 minutes on it, and the history is capped at 50 entries.

- See [spec 051](docs/spec/tasks/051-custom-rule-wifi-conditions.md), [feature highlight](docs/features/wifi-aware-routing.md)
</details>

<details>
<summary><strong>Chains of hops</strong> — a route through several servers as a source</summary>

A chain is a **third kind of source**, next to subscriptions and servers: an explicit route `you → hop 1 → hop 2 → destination`, emitted as one outbound of type `chain`. Chains sit in the common source list as equal rows — toggled, dragged and filtered like everything else.

**Chain vs detour** — a chain is a **route (a source)**; detour is a **property of one node** ("this server goes through that one"). Reach for a chain when the route itself is the thing you are building; reach for detour when a single server needs a relay in front of it.

- **Positions are in packet order** — `[0]` is the first hop from you. A position is a node, a group or a **direction**; a direction as a hop makes that step switchable on the fly
- **Rules of composition** — at least two positions; no empty, duplicate or self-referencing ones; a nested chain only at position 0; a reference only to a chain **declared above** in the list (the order is what rules out cycles)
- **The editor is the only gate** — `sing-box check` passes this class of error and `run` dies on it, so the form validates the core's start-time invariants before the config is ever built
- **Layered diagnostics** — a chain's node → Diagnostics: every hop with cumulative latency and its own price (`67 ms → 91 ms (+24) → 96 ms (+5)`). A hop's price is the difference between neighbouring layers, never a measurement of its own. A dead layer shows the core's error text and marks everything behind it "not reached"
- **Deleting a source cleans its positions** out of chains, with a visible counter; a chain that drops below two positions stops being emitted until repaired. A subscription refresh never touches positions
- **Field notes** — MASQUE placed after a TCP hop needs `vhttp: auto`; WireGuard behind a TCP hop requires a server that actually proxies UDP
- Requires core **sing-box-lx v1.14.0-lx.27** or newer (pinned at `v1.14.0-lx.28-rc.1`)
</details>

<details>
<summary><strong>Detour</strong> — proxy chains ("go through")</summary>

One server reaches the internet through another: `you → A → B → internet`. Why: exit from the IP of a specific country through a fast nearby server, punch through a block on the server itself, or take a double hop for privacy.

- **One target picker** — a detour is assigned to a single server (Node Settings), to a whole subscription or folder (Settings tab), or to an individual folder member; the target can be another server, a member of the same folder, or a **direction**
- **Detour directions** (§248/§274) — the "Use as detour" checkbox turns a direction into a switchable relay layer: the core decides which server inside it is used, and the direction stays available to rules and route final (⚙ in its name)
- **Chains** — A through B, B through C; inside a folder chains are built directly between members, and the chain preview is shown in subscription and folder settings (§252)
- **Cycle detector** (§254/§255) — a closed loop stops the config build and names the culprits; tapping a culprit navigates to the owner of that node
- **⚠ dependency graph** (§355) — a dead node that others route through is flagged on the home screen (see Home Screen)
- **AmneziaWG over a WireGuard detour** works (§130; the kernel guard was removed after end-to-end verification)
- The whole chain lives inside a single L×Box tunnel — this is not OS-level VPN-over-VPN and is cheaper in resources
</details>

<details>
<summary><strong>DNS</strong> — server groups, failure-tolerant resolution</summary>

A catalog of DNS servers (Cloudflare, Google, Yandex, Quad9, AdGuard, OpenDNS — UDP/DoT/DoH) plus custom ones via JSON. Every server picks the direction it travels through (**Outbound/detour**): DNS can go either direct or through the tunnel.

- **DNS groups** (§312) — several servers under one tag with a selection strategy: **Stable** (stick to a working one), **Fastest** (race, then stick to the winner), **Parallel** (race every query). You build your own in the DNS server editor: type **Group** next to UDP/TLS/HTTPS, members by checkbox, strategy, plus **Error TTL / Win TTL**. Member errors are remembered with a TTL, so a revived path returns on its own; a disabled member doesn't break the config (it is skipped at build time with a warning and returns when re-enabled). The list shows a `GROUP · mode · N` badge, and with the tunnel up you see the current target and each member's state (errors, RTT)
- **Shield DNS** (§314) — the default on a fresh install: the `dns_shield` group spanning five providers, three transports (UDP/DoT/DoH) and two paths (direct and through the VPN) — no single failure takes resolution down
- **ru-DNS over three paths** (§354) — the "Russian domains & IPs" preset resolves ru domains through the `dns_ru` group (UDP via the preset's direction, DoT via `vpn-1`, DoH direct): a dead node in the direction no longer hangs ru sites
- **Group trace in the profiler** (§315) — a DNS event shows which group handled the query, which member answered and with what RTT
- **DNS Rules** — a separate reorderable list: your own rules (**Add user rule**, a `dns.rules` JSON fragment), rules from enabled presets and from the template, and mirrors of routing rules' DNS blocks (§257) — grouped together and edited on the parent rule's side
- DNS Final and Default Domain Resolver — the app-facing resolver and the core's internal resolver are set separately
</details>

<details>
<summary><strong>DPI bypass</strong> — tricks against blocking</summary>

Three orthogonal tricks — combinable on the same outbound.

- **TLS Fragment** — splits ClientHello over TCP segments
- **TLS Record Fragment** — splits the handshake into multiple TLS records
- **Mixed-case SNI** — randomises `server_name` case (`WwW.gOoGle.CoM`); bypasses naive exact-match DPI used by regional providers (per RFC 6066 the field is case-insensitive, so server behaviour doesn't change). Ineffective against GFW-class filtering
- All tricks apply to the first hop only (inner hops are inside the tunnel, local DPI can't see them)
- See [spec 020](docs/spec/features/020%20security%20and%20dpi%20bypass/spec.md), [spec 028](docs/spec/features/028%20antidpi%20sni%20obfuscation/spec.md)
</details>

<details>
<summary><strong>Haptic feedback</strong> — vibration on VPN events</summary>

Short vibration on VPN transitions, errors and taps. Respects the Android system Touch feedback setting.

- Tap Start/Stop → light tick; connected → medium impact; user disconnect → light
- Revoked / heartbeat fail (first only, not per tick) → heavy
- Auto triggers don't vibrate; a 100 ms throttle prevents spam
- Toggle in App Settings → Feedback (default **on**)
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

Three tabs: **Stats** (real-time traffic per direction with expandable cards) · **Conns** (live connections) · **Profiler** (recording of every connection and DNS resolve).

- Every connection shows host, protocol, matched rule, traffic, duration, proxy chain and the owning app with its launcher icon (§154); individual connections can be closed
- **Detail sheet** (§152) — tap a connection → full metadata plus **Copy JSON** for bug reports
- **Stuck one-way connections** (§153) — TCP with traffic in one direction only (↑>0, ↓0) is highlighted with a **One-way** badge — a common sign of blocking
- **Profiler** — system-wide recording: every TCP/UDP open and DNS resolve on the device in real time; filters by event kind / app / domain-IP; aggregation by domain or IP with CNAME chains, outbounds and bytes; issue detection (`dnsTimeout`, `tcpReset`); short-connection duration taken from core timestamps (§353)
- **DNS health detector** (§262) — a running monitor of resolve failure rates with a decisions banner
- DNS group trace in DNS event details (§315)
</details>

<details>
<summary><strong>Diagnostics</strong> — Debug screen, crash reports, pprof</summary>

Side menu → **Debug**, four tabs.

- **Log** — app and core log; a live verbose switch lifts the TRACE/DEBUG filter without a restart (§345)
- **Crashes** (§316) — core crash reports: the Go trace is saved to a file (it never reaches logcat — stderr goes to `/dev/null` on Android), and a banner appears on the home screen after a crash; the archive ships with "Share dump"
- **OOM** (§318) — snapshots from the core's memory watchdog: memstats, log and the config at trigger time; view, share, purge
- **Profiling** (§207) — Go pprof pulled from the live core on-device: CPU (10 s), Heap inuse, Allocations, Goroutines; `.pb` files open with `go tool pprof`
- **Self-healing** (§334) — if the previous run ended in a core crash, the app resets the core's caches before the next start (a corrupted `cache.db` is a common "crashes immediately" cause); configs and settings are left untouched
- The reason a start failed is in `last_start_error` (§250, Debug API)
- For scripted diagnostics — the [Debug API](docs/api/debug-api-reference.md): an HTTP control surface (subscription and rule CRUD, start/stop, config, logs, profiler)
</details>

<details>
<summary><strong>VPN Settings</strong> — tune the engine</summary>

Two tabs:

- **Mode** (§119) — **VPN** (system-wide tunnel, default) / **Local proxy** (no tunnel: a local HTTP+SOCKS proxy that apps are pointed at manually; the Android VPN slot stays free, so it coexists with another VPN) / **VPN + Proxy** (both at once). The proxy port is configurable; reachable from this device only or from the LAN — the LAN variant strictly requires password auth. Tunnel and proxy traffic can be told apart by the rules' inbound matcher
- **System** — Android-side toggles: `Allow VPN bypass` (apps that explicitly ask the system for the physical network may step around the tun), `Keep VPN on exit`, `Tunnel sleep mode` (`never` / `lazy` Doze-only / `always` screen-off — a battery vs reliability trade-off)
- **WireGuard connections** (§272) — suspending idle tunnels: Suspend idle tunnels (30 s) / Suspend active-route tunnels (5 min); sleeping WG/AWG endpoints release memory and wake on the next dial (device A/B showed a large RAM drop)
- **Passive health check** (§272) — urltest probes stay silent while live traffic already proves the server is up
- **Memory limit** (§271) — core memory limit: Auto (by device RAM: 200/384/512 MB) / Off / manual 200–768 MB; applied to the running core instantly. Fixes the GC storm and CPU overheating on configs with large WireGuard pools
- **Core** — sing-box engine vars (`mtu`, `log_level`, …); routing- and DNS-specific vars live on their own screens

All changes autosave. URLTest parameters for auto node selection. The permissions block (Battery / Notifications / Location / Wi-Fi) lives in App Settings → Diagnostics.
</details>

<details>
<summary><strong>Config Editor</strong> — for power users</summary>

View and edit the raw sing-box JSON config. The editor is line-based (§333): only visible lines are highlighted, line numbers are shown, and configs hundreds of kilobytes long no longer freeze the UI or the keyboard; JSON5 syntax errors on save are reported with coordinates. Configs above 1 MB open read-only with a hint (Share → external editor → Load from file). Save, paste from clipboard, load from file, share.
</details>

<details>
<summary><strong>App Settings</strong></summary>

- **Language** (§279) — System default / English / Русский; switches instantly, and native surfaces (notification shade, Quick Settings tile, launcher shortcuts) are translated too. Technical surfaces (logs, Debug API, automation events) stay English by design
- Theme: System / Light / Dark
- Auto-start VPN on boot; keep the tunnel alive when the app is closed
- **Auto-restart VPN on settings change** (§338) — no manual "Restart"; the "restart VPN" banner is checked against the *running* core and won't appear when there is nothing to apply (§324)
- **First-run wizard** (§126) — onboarding: notifications → battery optimization → Quick Settings tile
- **Battery optimization** and **App info (OEM power settings)** — status plus shortcuts into the system whitelists
- **Auto-ping after connect** — ping the active direction 5 s after the VPN comes up
- **Interrupt connections on switch** (§143) — drop the group's connections when you switch nodes so traffic moves immediately (default off); re-selecting the already-active node is a no-op (§290)
- Haptic feedback, Quick connect, Backup & restore (a snapshot of subscriptions, directions, chains, rules and settings, with a preview before restoring)
</details>

---

## Supported Protocols

| Protocol | URI scheme | Transport |
|----------|-----------|-----------|
| VLESS | `vless://` | TCP, WebSocket, gRPC, H2, HTTPUpgrade, **XHTTP**, REALITY; post-quantum **ML-KEM-768** encryption (`mlkem768x25519plus`, §335) |
| VMess | `vmess://` (v2rayN base64) | TCP, WebSocket, gRPC, H2, HTTPUpgrade, **XHTTP** |
| Trojan | `trojan://` | TCP, WebSocket, gRPC |
| Shadowsocks | `ss://` (SIP002 + legacy + SS2022) | TCP, UDP, SIP003 plugins |
| Hysteria2 | `hy2://` / `hysteria2://` | QUIC, Salamander obfs |
| **TUIC v5** | `tuic://` | QUIC, BBR/CUBIC/NewReno, zero-RTT |
| **NaïveProxy** | `naive+https://` | Real Chrome TLS via cronet, `extra-headers` |
| **AnyTLS** | `anytls://` (§269) | TLS (incl. REALITY, uTLS, ALPN), idle sessions |
| SSH | `ssh://` | TCP, host key / password / private key |
| SOCKS | `socks://` / `socks5://` | TCP, auth |
| WireGuard / **AmneziaWG** | `wireguard://`, `awg://`, INI / `.conf`, **Amnezia `vpn://`** | UDP, multi-peer, **AWG 1.x/2.0 obfuscation** (jc/jmin/jmax, s1–s4, h1–h4 incl. **`N-M` ranges**, i1–i5), auto-MTU 1280 |
| **MASQUE** (Cloudflare WARP) | `masque://` | QUIC / HTTP-3 (RFC 9484 CONNECT-IP), HTTP/2 fallback, ECDSA P-256 pinning |

**XHTTP** is a native transport (Xray splithttp: `mode` auto/packet-up/stream-up/stream-one) with the full client-side param set: session/seq/uplink placements (path/query/header/cookie), keys, upload method, X-Padding obfs mode (`repeat-x`/`tokenish`) and packet-up tuning — read both from flat query params and from the `extra` (URL-encoded JSON) parameter. Works with TLS and Reality, incompatible with XTLS-Vision (protocol limitation).

See [Protocol Documentation](docs/PROTOCOLS.md) for full URI format details and sing-box mapping.

---

## Architecture

L×Box is built around a **3-layer parser/builder pipeline** (spec 026):

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

- **Bundled core** — [sing-box-lx](https://github.com/Leadaxe/sing-box-lx), a fork of the sing-box 1.14 branch with its own extensions: AmneziaWG 2.0, native XHTTP, the round-robin load balancer, idle-suspend for unreachable tunnels, a MASQUE / CONNECT-IP outbound, DNS groups, access to the running core's config, and crash/OOM reporting. The control channel runs over libbox `CommandClient` (no Clash API, no open port). The exact version is pinned in [`app/android/libbox.version`](app/android/libbox.version); the AAR is fetched from the fork's GitHub Releases by `scripts/fetch-libbox.sh` with SHA256 verification
- **Sealed `NodeSpec`** — 12 protocols, polymorphic `emit(vars)` / `toUri()` (round-trip invariant)
- **`EmitContext`** — passes template vars into per-node emit
- **`ValidationResult`** — typed issues: dangling refs, empty urltest, invalid selector default

See [Architecture](docs/ARCHITECTURE.md) for the full picture.

---

## Development

Spec-driven development — feature specifications document every capability.
Full documentation map: **[docs/README.md](docs/README.md)**.

| Document | Description |
|----------|-------------|
| [Documentation index](docs/README.md) | Full map of all docs — start here |
| [Support the project](docs/DONATE.md) | Ways to support: cryptocurrency, Boosty, and how to help without money |
| [User Guide](docs/USER_GUIDE.md) | How it works: traffic stages, directions, chains, detour, DNS — not about code, about the logic. Plus recipes: sharing the VPN over Wi-Fi via proxy, pairing with ByeDPI, and a regex reference |
| [Automation](docs/AUTOMATION.md) | Automate L×Box from Tasker / MacroDroid via the Public Intent API (broadcast commands + events, Wi-Fi triggers) |
| [Debug API](docs/api/debug-api-reference.md) | Full HTTP control/diagnostics surface (subscriptions & rules CRUD, start/stop, config, logs, profiler) |
| [Security](docs/SECURITY.md) | Threat model — traffic-leak protection, local attack surface, on-device secrets |
| [Protocol Reference](docs/PROTOCOLS.md) | URI formats, parameters, sing-box mapping |
| [Architecture](docs/ARCHITECTURE.md) | 3-layer pipeline, data flows, native bridge |
| [Build](docs/BUILD.md) | Build instructions, CI, APK signing, local-build marker |
| [Development Guide](docs/DEVELOPMENT_GUIDE.md) | Principles, testing, spec organisation |
| [Changelog](CHANGELOG.md) | Release history |
| [Release Notes](docs/releases/) | Detailed per-version notes (EN + RU) |

### Local build

```bash
./scripts/build-local-apk.sh
```

The script wraps `flutter build apk --release` with `--dart-define`s that embed git describe info. The About screen shows a pink **🧪 LOCAL BUILD · N commits since vX.Y.Z** badge to distinguish it from CI builds.

---

## Security

- **TUN inbound only by default** — no proxy ports are opened on localhost until proxy mode is explicitly enabled; LAN access to the proxy always requires auth
- **Control channel** — libbox `CommandClient` in-process (no networked Clash API, no open port or secret)
- **VPN Service** is not exported (`android:exported="false"`)
- More in [SECURITY.md](docs/SECURITY.md)

---

## License

L×Box is licensed under the [GNU General Public License v3.0](LICENSE).

Commercial licensing from Leadaxe may be available for **Leadaxe's own code in L×Box**. Note that L×Box links against [`libbox`](https://github.com/SagerNet/sing-box) (sing-box, GPLv3), so any compiled L×Box build remains under GPLv3 regardless — a Leadaxe-only commercial license cannot authorize embedding L×Box into a proprietary product. Scope and limits: [LICENSING.md](LICENSING.md). Inquiries: [ledaxe@gmail.com](mailto:ledaxe@gmail.com).
