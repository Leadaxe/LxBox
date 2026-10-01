[English](F-INDEX.md) · [Русский](F-INDEX.ru.md)

# Old feature specs (the `F` index) — historical index

> Formerly `docs/spec/features/README.md`. The folders were moved to `tasks/` as `NNNF-name/`
> keeping their number (see [`README.md`](README.md) → "the `F` index"). Current
> feature descriptions are being written anew in [`../features/`](../features/README.md); this list is
> a map of sources for revision work and for the revision tables in `FUNCTIONS/`.


Functionality specifications: user scenarios, UI/core behavior, constraints, definition of done.

**Folder name:** `NNN <name with spaces>` — see [`../README.md`](../README.md). Inside — `spec.md`, and `plan.md` and `tasks.md` when needed.

**Rules (see [`../README.md`](../README.md) and [`../tasks/054-spec-reorg-features-vs-tasks.md`](../tasks/054-spec-reorg-features-vs-tasks.md)):**
- `features/` holds **only live product / architectural** concepts.
- Historical decisions (MVP scope, initial stack), migrations, refactors, superseded specs — in [`../tasks/`](../tasks/).
- Numbers go monotonically "forward". Freed numbers (001, 002, 004, 005, 013, 039, 041) are **not reused**, so that archive links do not break.

## Index

| # | Folder | Summary | Status |
|---|--------|---------|--------|
| 003 | [`003 home screen/`](003F-home-screen/) | Home screen: groups, nodes, context menu, traffic bar, sorting, node filter | Implemented |
| 006 | [`006 servers ui/`](006F-servers-ui/) | Subscriptions UI: detail view, toggles, context menu, paste dialog | Implemented |
| 007 | [`007 config editor/`](007F-config-editor/) | JSON formatting in the config editor | Implemented |
| 008 | [`008 ping and node management/`](008F-ping-and-node-management/) | Mass ping, ping settings, URLTest config, color indication | Implemented |
| 009 | [`009 ux and theme/`](009F-ux-and-theme/) | Dark theme, pull-to-refresh, autosave | Implemented |
| 010 | [`010 quick start and offline/`](010F-quick-start-and-offline/) | Quick Start, auto-refresh, subscription caching | Implemented |
| 011 | [`011 local ruleset cache/`](011F-local-ruleset-cache/) | Local cache of remote .srs rule set files | Implemented |
| 012 | [`012 native vpn service/`](012F-native-vpn-service/) | Native VPN service, auto-connect on boot | Implemented |
| 014 | [`014 dns settings/`](014F-dns-settings/) | DNS servers, rules, strategy, presets | Implemented |
| 015 | [`015 speed test/`](015F-speed-test/) | Built-in speed test: ping, download, upload | Implemented |
| 016 | [`016 statistics and connections/`](016F-statistics-and-connections/) | Statistics by outbound, live connections | Implemented |
| 017 | [`017 custom nodes and node settings/`](017F-custom-nodes-and-node-settings/) | Custom nodes, overrides, node settings (tag, detour) | Implemented |
| 018 | [`018 detour server management/`](018F-detour-server-management/) | Multi-hop chains, jump server naming & visibility | Implemented |
| 019 | [`019 wireguard endpoint/`](019F-wireguard-endpoint/) | WireGuard URI + INI → sing-box endpoint | Implemented |
| 020 | [`020 security and dpi bypass/`](020F-security-and-dpi-bypass/) | Security hardening, TLS fragment | Partial |
| 021 | [`021 ci cd pipeline/`](021F-ci-cd-pipeline/) | GitHub Actions: checks, build, release | Implemented |
| 022 | [`022 app settings/`](022F-app-settings/) | Theme, auto-start on boot, keep VPN on exit | Implemented |
| 023 | [`023 debug and logging/`](023F-debug-and-logging/) | Debug screen, log level, sing-box log viewer | Partial |
| 024 | [`024 load balance/`](024F-load-balance/) | Load Balance via the PuerNya fork | Spec |
| 025 | [`025 warp integration/`](025F-warp-integration/) | Cloudflare WARP registration and integration (one-tap Get WARP) | Implemented |
| 026 | [`026 parser v2/`](026F-parser-v2/) | Sealed `NodeSpec` + 3-layer parser/builder pipeline | Implemented |
| 027 | [`027 subscription auto update/`](027F-subscription-auto-update/) | Subscription auto-refresh: 4 triggers + spam gates | Implemented |
| 028 | [`028 antidpi sni obfuscation/`](028F-antidpi-sni-obfuscation/) | Mixed-case SNI as a post-step | Implemented |
| 029 | [`029 haptic feedback/`](029F-haptic-feedback/) | Haptic feedback on key actions | Implemented |
| 030 | [`030 custom routing rules/`](030F-custom-routing-rules/) | Unified `CustomRule` + inline and SRS rules | Implemented |
| 031 | [`031 debug api/`](031F-debug-api/) | Localhost HTTP server for introspection | Implemented |
| 032 | [`032 quick connect/`](032F-quick-connect/) | QS tile + home shortcut | Implemented |
| 033 | [`033 preset bundles/`](033F-preset-bundles/) | Preset bundle selector | Implemented |
| 034 | [`034 app icon/`](034F-app-icon/) | Final app icon | Implemented |
| 035 | [`035 mcp server/`](035F-mcp-server/) | MCP wrapper over the Debug API | Spec |
| 036 | [`036 update check/`](036F-update-check/) | Update check on launch + manual | Implemented |
| 037 | [`037 naive proxy/`](037F-naive-proxy/) | NaïveProxy outbound: parser + emit + share-URI | Implemented |
| 038 | [`038 crash diagnostics/`](038F-crash-diagnostics/) | Crash diagnostics (merged into the §043 diagnostics platform) | Implemented |
| 040 | [`040 backup restore ui/`](040F-backup-restore-ui/) | Backup & restore UI | Implemented |
| 042 | [`042 health watchdog/`](042F-health-watchdog/) | Health watchdog (heartbeat metrics + auto-recovery) | Implemented |
| 043 | [`043 applog per-source quotas/`](043F-applog-per-source-quotas/) | Diagnostics platform (Debug API + AppLog + Crash diagnostics) | Implemented |
| 044 | [`044 per-app traffic profiler/`](044F-per-app-traffic-profiler/) | Per-app traffic profiler | Implemented (v1.7.0) |
| 045 | [`045 tls ech/`](045F-tls-ech/) | TLS ECH (Encrypted Client Hello) | Spec |
| 046 | [`046 tunnel apps split-tunneling/`](046F-tunnel-apps-split-tunneling/) | Tunnel apps: OS-level split-tunneling | Implemented (v1.7.1) |
| 047 | [`047 public intent api/`](047F-public-intent-api/) | Public Intent API (Tasker / automation) | Implemented |
| 048 | [`048 home-node-filters/`](048F-home-node-filters/) | Node filters on the home screen (`NodeFilter`) | Implemented |
| 070 | [`070 sort-options/`](070F-sort-options/) | Node sort options | Implemented |
| 071 | [`071 manual-node-reorder/`](071F-manual-node-reorder/) | Manual node order (drag-reorder) | Implemented |
| 074 | [`074 add-server-wizard/`](074F-add-server-wizard/) | Add-server wizard | Implemented |
| 076 | [`076 settings-and-config-lifecycle/`](076F-settings-and-config-lifecycle/) | Settings and config build lifecycle | Implemented |
| 097 | [`097 awg2-amneziawg2/`](097F-awg2-amneziawg2/) | AmneziaWG / AWG2 + XHTTP (core swap to sing-box-lx) | Implemented (v2.0.0) |
| 105 | [`105 support-message/`](105F-support-message/) | Support message | Implemented (v2.0.0) |
| 117 | [`117 dns-rework/`](117F-dns-rework/) | DNS rework for sing-box 1.14 | Implemented (v2.0.6) |
| 118 | [`118 subscription-fetch-identity/`](118F-subscription-fetch-identity/) | Subscription fetch identity (User-Agent etc.) | Implemented (v2.0.6) |
| 119 | [`119 vpn-mode/`](119F-vpn-mode/) | VPN Mode (vpn / proxy / vpn_proxy), data-driven tab | Implemented |
| 120 | [`120 template-engine-typed-vars-and-if/`](120F-template-engine-typed-vars-and-if/) | Typed template engine + declarative `#if` | Implemented |
| 121 | [`121 libbox-1.14-adoption/`](121F-libbox-1.14-adoption/) | Adoption of the sing-box 1.14 core (libbox 1.14 API) | Implemented |
| 122 | [`122 commandclient-migration/`](122F-commandclient-migration/) | Moving the control channel to libbox CommandClient (dropping the Clash API) | Implemented |
| 123 | [`123 subscription-model/`](123F-subscription-model/) | BoxService / CommandClient subscription model (three clients, power model) | Implemented |
| 124 | [`124 background-mode-tunnel-sleep/`](124F-background-mode-tunnel-sleep/) | Tunnel sleep mode (`never`/`lazy`/`always`): pausing/waking the tunnel to save battery; the "no leak while paused" invariant | Implemented |
| 125 | [`125 configurable-channels/`](125F-configurable-channels/) | Configurable routing channels (CRUD ≤10, node_filter, auto twin) | Implemented (v2.6.0) |
| 126 | [`126 first-run-wizard/`](126F-first-run-wizard/) | First-run wizard | Implemented (v2.8.0) |
| 127 | [`127 xhttp-full-url-params/`](127F-xhttp-full-url-params/) | Full XHTTP: transport URL parameters | Implemented (v2.8.0) |
| 128 | [`128 idle-suspend/`](128F-idle-suspend/) | Tunnel idle-suspend (`route.lx_idle_suspend`, kernel SPEC 020) | Implemented (v2.8.2) |
| 129 | [`129 file-subscription/`](129F-file-subscription/) | Subscription from a file (`file:<uuid>`) + editable online↔file source | Implemented (v2.8.2) |
| 130 | [`130 masque-warp-transport/`](130F-masque-warp-transport/) | MASQUE transport for WARP (QUIC/CONNECT-IP) | Implemented (v2.9.0) |
| 234 | [`234 server-folders/`](234F-server-folders/) | Server folders (folder): a container of manual servers, per-member toggle, moving between folders | Implemented |
| 236 | [`236 folder-server-testing/`](236F-folder-server-testing/) | Test servers in a folder: headless probe (CommandServer without tun), scale thresholds, disable slow / delete unreachable / sort by ping | Implemented |
| 248 | [`248 detour-channels/`](248F-detour-channels/) | Detour channels: a §125 channel with the "Use as detour" checkbox as a switchable layer for the detour of servers/folders/subscriptions (⚙; the checkbox is a permission, the channel stays a rule target — §274; cycles are caught by the §254 fatal detector) | Implemented |
| 392 | [`392 node-diagnostics/`](392F-node-diagnostics/) | Diagnostics on the node screen: GET through the node by tag (kernel SPEC 058 `GetURLViaOutbound`) showing the raw response — exit IP/geo/`warp=`; probe branch (VPN off) ↔ live core (VPN on) | DEVICE-PENDING |
| 393 | [`393 directions/`](393F-directions/) | Directions: channel refactoring, backup v1.1, chains, parity with the launcher | Requirements |
| 439 | [`439 storage-contract-1-0/`](439F-storage-contract-1-0/) | Storing `lxbox_settings.json` in the entry form of contract 1.0 (`sources[]`, `rules[]`, `dns{}`), migration on load with a `.v0.bak` copy, node references `{folder_id, tag}` (NodeLink), LX Backup export — a slice of storage | Implemented, DEVICE-PENDING (2.23.3) |
| 417 | [`417 workspaces/`](417F-workspaces/) | Workspaces: named copies of state (settings + subscription cache + .srs); Load = autosave of the current one → copy → re-read without restart → rebuild → VPN; Save as; no file relocation | DEVICE-PENDING |
| 554 | [`554 schema-driven-node-editor/`](554F-schema-driven-node-editor/) | Node editor driven by the registry schema: the form is built from the schema, validation is the sanitizer | Raw idea, needs more work |
| 584 | [`584 openvpn-import/`](584F-openvpn-import/) | Import of OpenVPN `.ovpn` profiles → `openvpn-client` endpoint: recognition by extension, self-contained profile, DNS and routes bound via a preset; requirements shared with the launcher | Deferred (low priority) |

## Demoted / superseded (now in `../tasks/`)

| Old # | What it was | Where it moved |
|-------|-------------|----------------|
| 001 | Mobile stack decision | [`../tasks/055-mobile-stack-decision/`](../tasks/055-mobile-stack-decision/) |
| 002 | MVP scope | [`../tasks/056-mvp-scope-historical/`](../tasks/056-mvp-scope-historical/) |
| 004x | Subscription parser v1 (superseded by §026) | [`../tasks/057-subscription-parser-v1-superseded/`](../tasks/057-subscription-parser-v1-superseded/) |
| 005x | Config generator v1 (superseded by §026) | [`../tasks/058-config-generator-wizard-v1-superseded/`](../tasks/058-config-generator-wizard-v1-superseded/) |
| 013 | Routing v1 (superseded by §030) | [`../tasks/059-routing-v1-superseded/`](../tasks/059-routing-v1-superseded/) |
| 039 | libbox 1.13 migration (one-shot) | [`../tasks/060-libbox-1-13-migration/`](../tasks/060-libbox-1-13-migration/) |
| 041 | DNS rules refactor (live spec → §014) | [`../tasks/061-dns-rules-refactor/`](../tasks/061-dns-rules-refactor/) |
