[English](README.md) · [Русский](README.ru.md)

# L×Box features — what the Android VPN client can do

L×Box is an Android VPN client built on the sing-box-lx core. This catalogue
lists every capability of the app — subscriptions and node import, routing and
DNS, hop chains, split tunneling, Cloudflare WARP, DPI bypass, diagnostics,
backup — as black-box specifications: what each feature promises, how it is
controlled and where it stops. The structure follows the core's Spec Kit
([sing-box-lx/SPECS/FEATURES](https://github.com/Leadaxe/sing-box-lx/tree/lx/SPECS/FEATURES)).

A feature describes **the current state** of a whole domain area as a
**black box**: why it exists, what it promises the user, which principles it
protects, what controls it, what it takes and what it gives, where its
boundaries are. The implementation (files, classes, control flow, platform)
lives in tasks — [`../tasks/`](../tasks/README.md); old feature specs are tasks
with the `F` index ([`../tasks/F-INDEX.md`](../tasks/F-INDEX.md)).

**Portability criterion:** if the app is rewritten from scratch on another
platform, the `features/` folder moves over whole and does not change until the
behavior for the user changes.

## Languages

The primary language of long-lived documentation is **English**; the Russian
version sits next to it with the `.ru.md` suffix (`FEATURE.md` + `FEATURE.ru.md`,
`FUNCTIONS/<name>.md` + `FUNCTIONS/<name>.ru.md`). The first line of every
document is a switcher: `[English](X.md) · [Русский](X.ru.md)`. Both versions
are required and are edited together; tasks in `tasks/` may be in Russian only.

## Three levels

```
Feature    features/NNN-NAME/FEATURE.md          why, promises, parameters, boundaries, list of functions
Function   features/NNN-NAME/FUNCTIONS/<name>.md one capability of the feature: what it does, its own parameters,
                                                 invariants, revision table
Revision   tasks/NNN-title.md | tasks/NNNF-name/  a work cycle that changed a function (implementation)
```

A function is something the user or a neighboring subsystem can name on its own
("OpenVPN profile import", "subscription auto-update"), not a code layer and not
a screen. One task may be listed as a revision of several functions.

## Product

| # | Feature | What it gives | Absorbed (`F`) | State |
|---|---------|---------------|----------------|-------|
| [001-SUBSCRIPTIONS](001-SUBSCRIPTIONS/FEATURE.md) | Node sources: subscription by URL, file, paste; request identity; auto-update; disabling nodes | 006 010 027 118 129 283 | ✅ 2026-09-28 |
| [002-NODE_IMPORT](002-NODE_IMPORT/FEATURE.md) | Parsing links and configs of all protocols into a single node model: share-URI, Xray JSON, sing-box JSON, WireGuard INI, AmneziaWG, OpenVPN, NaïveProxy | 019 026 037 097 321 368 460 472 480 584 | ✅ 2026-09-28 |
| [003-CONFIG_BUILD](003-CONFIG_BUILD/FEATURE.md) | Building the core config from nodes and settings: template, typed variables, settings lifecycle, pre-start validation | 076 120 | ✅ 2026-09-28 |
| [004-ROUTING](004-ROUTING/FEATURE.md) | Routing rules: custom rules, presets, rule-set cache, directions | 011 030 033 393 | ✅ 2026-09-28 |
| [005-DNS](005-DNS/FEATURE.md) | DNS: servers, rules, strategy, groups, FakeIP | 014 117 312 | ✅ 2026-09-28 |
| [006-DETOUR_AND_BALANCE](006-DETOUR_AND_BALANCE/FEATURE.md) | Node chains, detour channels, load balancer | 018 024 248 322 | ✅ 2026-09-28 |
| [007-NODE_LIST](007-NODE_LIST/FEATURE.md) | Home screen: groups, filters, sorting, folders, manual order, active node selection | 003 048 070 071 234 236 565 | ✅ 2026-09-28 |
| [008-NODE_EDITOR](008-NODE_EDITOR/FEATURE.md) | Custom nodes, node settings, protocol-schema editor, add-server wizard | 017 074 554 | ✅ 2026-09-28 |
| [009-NODE_HEALTH](009-NODE_HEALTH/FEATURE.md) | Ping and URLTest, node diagnostics, auto-disabling core-rejected nodes, speed test | 008 015 392 478 | ✅ 2026-09-28 |
| [010-VPN_SERVICE](010-VPN_SERVICE/FEATURE.md) | Tunnel: start/stop, VPN/Proxy modes, auto-start, watchdog, background sleep, idle-suspend, reaction to network changes | 012 042 119 124 128 | ✅ 2026-09-28 |
| [011-SPLIT_TUNNELING](011-SPLIT_TUNNELING/FEATURE.md) | Which apps go through the tunnel and which bypass it | 046 | ✅ 2026-09-28 |
| [012-LIVE_STATE](012-LIVE_STATE/FEATURE.md) | Live core state: status, connections, statistics, per-app traffic | 016 122 123 | ✅ 2026-09-28 |
| [013-DIAGNOSTICS](013-DIAGNOSTICS/FEATURE.md) | Diagnostics: app log, core log, crash report, Debug API, live events | 023 038 043 | ✅ 2026-09-28 |
| [014-AUTOMATION](014-AUTOMATION/FEATURE.md) | External control: quick connect, public Intent API, integration with automation apps | 032 047 | ✅ 2026-09-28 |
| [015-WARP](015-WARP/FEATURE.md) | Cloudflare WARP: one-tap registration, MASQUE transport | 025 130 | ✅ 2026-09-28 |
| [016-DPI_HARDENING](016-DPI_HARDENING/FEATURE.md) | DPI circumvention: TLS fragmentation, SNI obfuscation, ECH, XHTTP parameters | 020 028 045 127 | ✅ 2026-09-28 |
| [017-BACKUP_AND_STORAGE](017-BACKUP_AND_STORAGE/FEATURE.md) | Backup and restore, storage contract, migrations | 040 439 | ✅ 2026-09-29 |
| [018-WORKSPACES](018-WORKSPACES/FEATURE.md) | Named settings sets | 417 | ✅ 2026-09-28 |
| [019-CONFIG_EDITOR](019-CONFIG_EDITOR/FEATURE.md) | Viewing and editing the final config | 007 | ✅ 2026-09-28 |
| [020-APP_SHELL](020-APP_SHELL/FEATURE.md) | App shell: settings, theme, haptic feedback, icon, localization, first launch, support, update check | 009 022 029 034 036 105 126 | ✅ 2026-09-28 |
| [024-TEMPLATE](024-TEMPLATE/FEATURE.md) | The config template, its language (`#if`, `for_each`, `#tpl`, typed variables) and the preset language; how the client is extended through the template | 120 (functions) 033 (language) | ✅ 2026-09-29 |
| [025-CONTRACT_REGISTRY](025-CONTRACT_REGISTRY/FEATURE.md) | The contract registry: protocol schemas, the mapper → sanitizer → model pipeline, the build gate for the pinned core, warning codes, sync and guards | 460 472 480 (registry parts) | ✅ 2026-09-29 |
| [026-DIRECTIONS](026-DIRECTIONS/FEATURE.md) | Directions — the routing targets `vpn-N`, `direct-out`, `block`: model, groups in the config, selection, detour role, health | 125 248 393 (direction parts) | ✅ 2026-09-29 |
| [027-DEBUG_API](027-DEBUG_API/FEATURE.md) | Debug API — the local HTTP control surface: access and security, route map, `/help`, write operations, automation recipes | 031 | ✅ 2026-09-29 |
| [028-TRAFFIC_PROFILER](028-TRAFFIC_PROFILER/FEATURE.md) | Traffic profiler — per-app connection log, attribution, filters and views, DNS trace | 044 | ✅ 2026-09-29 |
| [029-LOCALIZATION](029-LOCALIZATION/FEATURE.md) | Localization — languages, the English-as-key model, translation workflow, native and core strings | 279 | ✅ 2026-09-29 |
| [030-TAILSCALE](030-TAILSCALE/FEATURE.md) | Tailscale — the phone as a node of your tailnet: node, device identity and state, tailnet DNS and routes, Network tab | 435 (former feature) | ✅ 2026-09-29 |
| [031-DEVICE_TRANSFER](031-DEVICE_TRANSFER/FEATURE.md) | Device transfer — send settings from a phone to a TV over the local network: QR code with a one-time key, encrypted backup, restore preview on the receiver | — | ✍ 2026-10-09 |

## Process

| # | Feature | What it gives | Absorbed (`F`) | State |
|---|---------|---------------|----------------|-------|
| [021-CORE_CONTRACT](021-CORE_CONTRACT/FEATURE.md) | The boundary with the sing-box-lx core: versions, libbox contract, feedback to the core | 121 · `docs/CONTRACT.md` · `docs/contract/` | ✅ 2026-09-29 |
| [022-ARCHITECTURE](022-ARCHITECTURE/FEATURE.md) | Code structure principles: layers, facades, "cohesion over line count" | 291 | ✅ 2026-09-29 |
| [023-BUILD_CI_RELEASE](023-BUILD_CI_RELEASE/FEATURE.md) | Build, checks, release, stores | 021 · `docs/RELEASE_PROCESS.md` | ✅ 2026-09-29 |

State: `—` not written · `✍` in progress · `✅` written from code · `D` confirmed by the owner.

Not carried over: `035F mcp server` (spec only, no code) — the owner's decision.

## Feature template — `NNN-NAME/FEATURE.md`

Header table: Type (product/process), Absorbed (`§NNNF …`), State.
Then sections in this order:

1. **Purpose** — what it gives the user, why it exists, which principle it protects.
2. **Promises** — `P1..Pn`, each with: a statement of observable behavior,
   a **Witness** (a test named by behavior, or a reproducible manual check),
   a **Mutation** (what should break the promise). A promise without a witness is
   marked `no witness` — it is a candidate for a revision, not a decoration.
3. **Controlled parameters** — all knobs: user settings (values, default), core
   config keys the feature emits (this is the contract with the core).
4. **Inputs / Outputs** — what the box takes (links, files, OS events, core
   responses) and what it gives (config, state, notifications, behavior).
5. **Data flow** — the path of data through stages, from input to output. Stages,
   not files.
6. **Rules and guarantees** — invariants, mutual exclusions, what is validated and
   when.
7. **Boundaries** — what the feature intentionally does not do; what depends on OS
   capabilities.
8. **Functions** — a table: function · what it does · which promises it holds ·
   file in `FUNCTIONS/`.
9. **Related features** — sibling and neighboring features, the functions and
   promises in them: a link + one line on why they are related (a boundary, a
   shared contract, a dependency).
10. **Maintenance notes** — behavioral pitfalls that are expensive.

A reference to another feature's promise is written as `005-DNS · P2`, linked to
that feature's promises section: `[005-DNS · P2](../005-DNS/FEATURE.md#promises)`
(in the Russian version the anchor is `#обещания`). Promise numbers inside a
feature are stable: a withdrawn promise is marked "withdrawn", and its number is
not reused.

⚠️ **No names of files, classes, code functions, widgets or platform mechanisms.**
Check: the implementation was rewritten from scratch — `FEATURE.md` did not change.
What remains: settings and their values, core config keys, core RPC names, link
and file formats (these are contracts with the user and the core).

## Function template — `NNN-NAME/FUNCTIONS/<name>.md`

Header: Feature, Promises (which `P` it holds), State. Sections:

1. **What it does** — one capability, in the user's terms.
2. **Parameters** — only the knobs that relate to this function.
3. **Inputs / Outputs**.
4. **Rules and invariants** — including error handling: what the user sees.
5. **Boundaries**.
6. **Revisions** — a table `# · Revision · Status · Summary`, links to
   `../../tasks/NNN…`. A revision is the history of requirements, not of the
   implementation: a one-line summary, no files.

## Conventions

- **A feature folder is `NNN-NAME`**, UPPER_SNAKE, a running number from `001` — a
  stable anchor that does not change once assigned. A new feature gets the next
  free number.
- **One feature — one `FEATURE.md`**, the current state on top, no chronology.
  Chronology lives in revisions.
- **A feature is written from code and tests**; old `F` specs and tasks are a source
  of revisions and hints, not the truth. A mismatch between code and expectation is
  a new task, not smoothing over.
- **Link to a feature or a function, not to a task.** Link to a task when a specific
  analysis is needed.
- **Behavior changes — the feature is edited.** `FEATURE.md` and `FUNCTIONS/` are a
  living design, not an archive: a task that changes behavior updates them and adds
  itself to the revisions.
