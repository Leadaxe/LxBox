# Public servers registry

[Русская версия](PUBLIC_SOURCES.ru.md)

**This list exists for individual testing of the L×Box client: checking how it
parses subscriptions, protocols and transports.** The servers belong to third
parties. The L×Box project does not run them, does not vet them and does not
recommend them. Availability, speed and security are not guaranteed: a node may
be down, slow, or log your traffic. Use these subscriptions only in compliance
with the laws of your country (see
[Purpose and terms of use](../README.md#purpose-and-terms-of-use)).

Checked on **2026-09-30**. A source is listed only if, on that date, all three
conditions held:

- the subscription URL answered `200` with a non-empty body;
- L×Box parsed at least one node from it;
- the repository was updated within the last 14 days.

Connections to the nodes were not tested. Node counts come from L×Box parsing
snapshots taken on 2026-09-24…30; the live lists change every hour or so.
Update frequency is estimated from the commit history of each file over
2026-09-27…30.

"Whitelist" and "blacklist" below refer to Russian mobile networks: under a
whitelist only an approved set of domestic sites and addresses is reachable,
under a blacklist everything except blocked resources is.

## Sources

### [zieng2/wl](https://github.com/zieng2/wl)

The author's own subscription for mobile whitelists, rebuilt every hour; the
README lists mirrors on Codeberg, GitLab, Mos.Hub and GitVerse and advises
running a latency test over the whole list or using auto-select. The older
`vless.txt` in the same repository now holds only stub entries saying the
subscription is outdated, so it is not listed here.

- **Subscriptions:**
  - [vless_universal.txt](https://raw.githubusercontent.com/zieng2/wl/main/vless_universal.txt) — 95 nodes
  - [vless_lite.txt](https://raw.githubusercontent.com/zieng2/wl/main/vless_lite.txt) — 95 nodes
- **Protocols:** VLESS
- **Updates:** hourly

### [igareck/vpn-configs-for-russia](https://github.com/igareck/vpn-configs-for-russia)

Separate lists for mobile whitelists (by SNI and by CIDR) and for the mobile
blacklist; the README says nodes are published after real availability,
latency and speed tests. The repository also carries Clash-format exports, Tor
bridges and mirrors on GitLab and Bitbucket.

- **Subscriptions:**
  - [Vless-Reality-White-Lists-Rus-Mobile.txt](https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/refs/heads/main/Vless-Reality-White-Lists-Rus-Mobile.txt) — 25 nodes
  - [WHITE-CIDR-RU-checked.txt](https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/refs/heads/main/WHITE-CIDR-RU-checked.txt) — 5 nodes
  - [BLACK_VLESS_RUS_mobile.txt](https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/BLACK_VLESS_RUS_mobile.txt) — 132 nodes
- **Protocols:** VLESS, Hysteria2, VMess
- **Updates:** about hourly

### [hussaroff/lte-universal-checked](https://github.com/hussaroff/lte-universal-checked)

VLESS nodes for LTE networks under a whitelist, gathered from 50+ sources and
pre-checked by real delay. Built for the author's Tunnel client, but it is a
plain list any client can read.

- **Subscriptions:**
  - [whitelist.txt](https://raw.githubusercontent.com/hussaroff/lte-universal-checked/refs/heads/main/whitelist.txt) — 24 nodes
- **Protocols:** VLESS
- **Updates:** every 3–4 h

### [RKPchannel/RKP_bypass_configs](https://github.com/RKPchannel/RKP_bypass_configs)

Assembled from open sources by the author's own script, which picks nodes for
the whitelist by the IP prefixes and SNI that pass under it. The same lists are
also published in Clash YAML; the README warns that a node may answer a ping
and still not carry traffic.

- **Subscriptions:**
  - [whitelist.txt](https://raw.githubusercontent.com/RKPchannel/RKP_bypass_configs/refs/heads/main/whitelist.txt) — 56 nodes
  - [blacklist.txt](https://raw.githubusercontent.com/RKPchannel/RKP_bypass_configs/refs/heads/main/blacklist.txt) — 2865 nodes
- **Protocols:** VLESS, Hysteria2, Shadowsocks, Trojan
- **Updates:** every ~2 h

### [Maskkost93/kizyak-vpn-4.0](https://github.com/Maskkost93/kizyak-vpn-4.0)

`kizyakbeta7.txt` and `kizyakbeta6.txt` target mobile whitelists,
`kizyakbeta6BL.txt` targets the blacklist (wired and regular mobile). The
blacklist file has no VLESS at all: only Hysteria2, Trojan and VMess.

- **Subscriptions:**
  - [kizyakbeta7.txt](https://raw.githubusercontent.com/Maskkost93/kizyak-vpn-4.0/refs/heads/main/kizyakbeta7.txt) — 73 nodes
  - [kizyakbeta6.txt](https://raw.githubusercontent.com/Maskkost93/kizyak-vpn-4.0/refs/heads/main/kizyakbeta6.txt) — 30 nodes
  - [kizyakbeta6BL.txt](https://raw.githubusercontent.com/Maskkost93/kizyak-vpn-4.0/refs/heads/main/kizyakbeta6BL.txt) — 33 nodes
- **Protocols:** VLESS, Hysteria2, Trojan, VMess
- **Updates:** every 2–3 h

### [AirLinkVPN1/AirLinkVPN](https://github.com/AirLinkVPN1/AirLinkVPN)

A VLESS list for the whitelist. The README speaks of VLESS Reality only, but
about a fifth of the nodes are VLESS over plain TLS, and a few entries point to
`111.111.111.111:111`, which is a placeholder rather than a server.

- **Subscriptions:**
  - [rkn_white_list](https://raw.githubusercontent.com/AirLinkVPN1/AirLinkVPN/refs/heads/main/rkn_white_list) — 97 nodes
- **Protocols:** VLESS
- **Updates:** hourly

### [flaafix/AetrisVPN-white-list-lite](https://github.com/flaafix/AetrisVPN-white-list-lite), [flaafix/AetrisVPN-black-list](https://github.com/flaafix/AetrisVPN-black-list)

Two repositories by one author: a lighter whitelist list and a blacklist list.
The READMEs describe domain and IP lists, but the files listed here are server
subscriptions whose header shows the server count and the time of the last
build.

- **Subscriptions:**
  - [AetrisVPN.txt](https://raw.githubusercontent.com/flaafix/AetrisVPN-white-list-lite/refs/heads/main/AetrisVPN.txt) — 114 nodes
  - [configs.txt](https://raw.githubusercontent.com/flaafix/AetrisVPN-black-list/refs/heads/main/configs.txt) — 206 nodes
- **Protocols:** VLESS, Shadowsocks, VMess, Trojan
- **Updates:** every ~5 h

### [ksenkovsolo/HardVPN-bypass-WhiteLists-](https://github.com/ksenkovsolo/HardVPN-bypass-WhiteLists-)

A repository of the HardVPN project; `WHITELIST-ALL.txt` contains VLESS
Reality only. It is updated irregularly: the file last changed on 2026-09-21.

- **Subscriptions:**
  - [WHITELIST-ALL.txt](https://raw.githubusercontent.com/ksenkovsolo/HardVPN-bypass-WhiteLists-/refs/heads/main/vpn-lte/WHITELIST-ALL.txt) — 188 nodes
- **Protocols:** VLESS
- **Updates:** irregular

### [whoahaow/rjsxrd](https://github.com/whoahaow/rjsxrd)

An automatically updated collection that drops nodes with insecure settings
(`allowInsecure`, `security=none`, weak Shadowsocks ciphers and so on).
`bypass-all.txt` holds the whitelist-bypass nodes in one file;
`bypass-1`…`bypass-6` are split files of at most 300 nodes each, meant for
weaker devices. The README is
available in English.

- **Subscriptions:**
  - [bypass-all.txt](https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/bypass/bypass-all.txt) — 621 nodes
  - [bypass-1.txt](https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/bypass/bypass-1.txt) — 286 nodes
  - [bypass-2.txt](https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/bypass/bypass-2.txt) — 262 nodes
  - [bypass-3.txt](https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/bypass/bypass-3.txt) — 277 nodes
  - [bypass-4.txt](https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/bypass/bypass-4.txt) — 281 nodes
  - [bypass-5.txt](https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/bypass/bypass-5.txt) — 25 nodes
  - [bypass-6.txt](https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/bypass/bypass-6.txt) — 279 nodes
- **Protocols:** VLESS, Trojan, Shadowsocks, VMess
- **Updates:** hourly (bypass-all, bypass-1), the rest less often

### [kort0881/vpn-checker-backend](https://github.com/kort0881/vpn-checker-backend)

A checker that collects public nodes, tests TCP/TLS/WebSocket reachability and
latency, and sorts them into pools; `WHITE` means the node passed the check.
The file is large (about 1.4 MB, 4000+ nodes), which matters on weak phones.

- **Subscriptions:**
  - [ru_white_all_WHITE.txt](https://raw.githubusercontent.com/kort0881/vpn-checker-backend/main/checked/RU_Best/ru_white_all_WHITE.txt) — 4025 nodes
- **Protocols:** VLESS, Shadowsocks, Trojan, Hysteria2
- **Updates:** every ~6 h

### [LimeHi/LimeVPN](https://github.com/LimeHi/LimeVPN)

Automatically built whitelist and blacklist lists, almost entirely VLESS
Reality.

- **Subscriptions:**
  - [whitelist.txt](https://raw.githubusercontent.com/LimeHi/LimeVPN/refs/heads/main/whitelist.txt) — 191 nodes
  - [blacklist.txt](https://raw.githubusercontent.com/LimeHi/LimeVPN/refs/heads/main/blacklist.txt) — 106 nodes
- **Protocols:** VLESS, Shadowsocks, VMess
- **Updates:** hourly

### [luxxuria/harvester](https://github.com/luxxuria/harvester)

A VLESS aggregator and validator written in Rust. `ping_tested.txt` holds
nodes that passed URI validation and a TCP port check; `top_600.txt` is the
fastest subset with a cap per provider (ASN). The README lists jsDelivr and
GitHack mirrors for when GitHub is unreachable.

- **Subscriptions:**
  - [ping_tested.txt](https://raw.githubusercontent.com/luxxuria/harvester/refs/heads/main/ping_tested.txt) — 117 nodes
  - [top_600.txt](https://raw.githubusercontent.com/luxxuria/harvester/refs/heads/main/top_600.txt) — 49 nodes
  - [non_ru.txt](https://raw.githubusercontent.com/luxxuria/harvester/refs/heads/main/non_ru.txt) — 45 nodes
- **Protocols:** VLESS
- **Updates:** every 5–6 h

### [ANT1VEN0M/PODVAL-KOTA-VPN-](https://github.com/ANT1VEN0M/PODVAL-KOTA-VPN-)

The repository has no description; files are added through GitHub uploads. The
blacklist file has the widest protocol mix on this page, including single
AnyTLS, SOCKS and WireGuard nodes. Both files listed here last changed on
2026-09-12; recent commits go to other files in the repository.

- **Subscriptions:**
  - [Белые_списки229.txt](https://raw.githubusercontent.com/ANT1VEN0M/PODVAL-KOTA-VPN-/refs/heads/main/%D0%91%D0%B5%D0%BB%D1%8B%D0%B5_%D1%81%D0%BF%D0%B8%D1%81%D0%BA%D0%B8229.txt) — 70 nodes
  - [antinet_Черные_списки.txt](https://raw.githubusercontent.com/ANT1VEN0M/PODVAL-KOTA-VPN-/refs/heads/main/antinet_%D0%A7%D0%B5%D1%80%D0%BD%D1%8B%D0%B5_%D1%81%D0%BF%D0%B8%D1%81%D0%BA%D0%B8.txt) — 642 nodes
- **Protocols:** VLESS, Trojan, VMess, Hysteria2, Shadowsocks, AnyTLS, SOCKS, WireGuard
- **Updates:** irregular

### [btsk161/Freeinternet_byMygalaru.github.io](https://github.com/btsk161/Freeinternet_byMygalaru.github.io)

A list from the RaViraNet Telegram group. Despite the file name
`premium.txt`, it is a free public list.

- **Subscriptions:**
  - [premium.txt](https://raw.githubusercontent.com/btsk161/Freeinternet_byMygalaru.github.io/refs/heads/main/premium.txt) — 153 nodes
- **Protocols:** VLESS, Shadowsocks, Hysteria2, Trojan
- **Updates:** every 1–2 days

### [Diversan313/apex-parser](https://github.com/Diversan313/apex-parser)

An open-source collector: gathers nodes from source lists and Telegram,
checks liveness, removes duplicates and filters by location. `alive_full.txt`
combines the whitelist and blacklist sets; the README also lists a GitVerse
mirror.

- **Subscriptions:**
  - [alive_full.txt](https://raw.githubusercontent.com/Diversan313/apex-parser/main/subs/main/alive_full.txt) — 595 nodes
- **Protocols:** VLESS, Shadowsocks, VMess, Trojan
- **Updates:** hourly or more often

### [histeenn/VLESS-PO-GRIBI](https://github.com/histeenn/VLESS-PO-GRIBI)

Collects and checks free servers from about 25 open sources; the file is about
1 MB. The README warns that Shadowsocks nodes may not work because that
protocol is being throttled.

- **Subscriptions:**
  - [sub.txt](https://raw.githubusercontent.com/histeenn/VLESS-PO-GRIBI/main/deploy/sub.txt) — 2891 nodes
- **Protocols:** VLESS, Shadowsocks, VMess
- **Updates:** every ~7 h

### [OVI-vpn/bs](https://github.com/OVI-vpn/bs)

The repository has no description. The file is mostly VLESS with Reality and
TLS over xhttp, gRPC and WebSocket.

- **Subscriptions:**
  - [full.txt](https://raw.githubusercontent.com/OVI-vpn/bs/refs/heads/main/full.txt) — 251 nodes
- **Protocols:** VLESS, Shadowsocks, VMess
- **Updates:** hourly

## How to add a subscription to L×Box

Copy the raw link of a file and add it as a subscription — see
[User Guide → Subscription](USER_GUIDE.md#subscription).

Thanks to the authors of these repositories for keeping their lists public.
