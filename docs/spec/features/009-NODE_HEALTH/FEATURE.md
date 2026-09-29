[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Node health — VPN server ping, URLTest, diagnostics and auto-disabling broken nodes

LxBox shows which VPN nodes are alive and fast by measuring latency through
the running sing-box core, without switching the active node or breaking
connections. The feature covers ping and mass ping, `urltest` auto-select
groups, a server test with the VPN off, an HTTP diagnostic request through a
single node and a speed test. A node the core rejects at start is disabled
with the core's reason, and the VPN comes up on the remaining nodes.

| Field | Value |
|------|----------|
| Feature | 009-NODE_HEALTH |
| Type | Product feature |
| Absorbed | `§008F` `§015F` `§392F` `§478F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

The user keeps dozens or hundreds of nodes and has to see quickly which of
them are alive, which is faster, why "ping works but sites don't open", and
why the VPN won't start after a subscription update. The feature answers these
questions with measurements and verdicts, without making the user switch the
active node, break live connections or decipher English core errors.

The feature protects five principles:

- **A measurement answers about the node, not about the route.** Ping, the
  server test and diagnostics address the node directly; the active group
  selection is not touched. "What am I going through right now" is another
  feature's question.
- **Cancellation is real.** Stopping a ping kills both the display and the
  measurements already sent to the core. Tunnel death kills all probing;
  backgrounding kills only what is pointless in the background.
- **Measurements do not mix.** Results of one Direction (its own URL and
  timeout) do not erase or replace another's; a list-test result is bound to
  the node, not to the row.
- **One bad node does not cut the connection.** A node the core refused to
  accept is disabled automatically with the verbatim reason, and the VPN comes
  up on the rest. The decision is bound to the node body and is lifted when the
  body changes.
- **Testing does not crash the app.** A mass test of memory-heavy nodes runs
  in batches, not as one config.

## Promises

- **P1. Mass ping is cancelled by the same tap.** A second tap on the ping
  button during a run stops it: `PING…` indicators disappear at once, late
  replies are not applied, measurements already sent to the core are aborted.
  **Witness**: manual check — start a ping on a list of 100+ nodes, press stop
  after 1 s: every `PING…` is gone, no new numbers appear. **Mutation**:
  cancel only clears the run flag, replies keep landing in the list.
- **P2. Direction measurements are isolated.** Mass ping writes and resets
  only the map of the current Direction; a node without its own measurement
  shows another Direction's one marked `~` in a dimmed color. **Witness**:
  units "mass-ping does not touch another Direction's map", "a node with no
  measurement in its Direction takes another's and is marked", "measurements
  outside a Direction live in a scratch key". **Mutation**: one shared
  measurement map for all Directions.
- **P3. Probing lifecycle.** Stopping or death of the tunnel kills mass ping,
  auto-ping and list tests; backgrounding the app kills auto-ping and list
  tests but not mass ping. **Witness**: units "disconnected cancels a running
  mass-ping", "revoked cancels an active folder-probe", "backgrounding the app
  does NOT cancel mass-ping", "backgrounding the app cancels an active
  folder-probe". **Mutation**: the list test registers cancellation only on
  its own screen.
- **P4. Auto-ping after connect.** With the setting on, 5 s after the
  transition to "connected" (including after a config reload on a live
  tunnel) the current list is pinged. **Witness**: units "a config reload on a
  live tunnel schedules auto-ping", "checkbox auto_ping_on_start=false —
  auto-ping is not scheduled". **Mutation**: auto-ping only on a cold start.
- **P5. Deleting a Direction removes its ping settings.** **Witness**: unit
  "deleting a Direction removes its key, leaves another's alone".
  **Mutation**: the override remains an orphan and comes back to life on a new
  Direction with the same tag.
- **P6. A dead group selection does not wait for the interval.** A ping
  failure of a node currently selected by a URLTest group immediately starts
  the core's group test with reselection; the end of a mass ping starts it for
  all URLTest groups. **Witness**: manual check — make the node selected by
  ✨auto unreachable, ping it: the group moves to a live node within seconds,
  not after `interval` (§308, verified on device). **Mutation**: a single
  measurement through the group without reselection.
- **P7. The `interval`/`idle_timeout` pair does not break the start.** If
  `interval` is greater than `idle_timeout`, the build raises `idle_timeout`
  to `interval`, leaves `interval` alone and writes a warning. **Witness**:
  units "the given pair does not fit → idle_timeout raised, interval
  unchanged", "round_robin follows the same rule", "a fitting pair →
  byte-for-byte". **Mutation**: `interval` is shortened to `idle_timeout`.
- **P8. Disabled stickiness reaches the core.** For `round_robin` with an
  empty component set the config gets `sticky_hash: ["none"]`; `balancer` is
  written only for `round_robin`. **Witness**: units "stickiness removed →
  sentinel ["none"] (§210)", "round_robin → mode + balancer{pool,
  pool_tolerance,sticky_hash}". **Mutation**: an empty list `[]`.
- **P9. Server test — only with the VPN off.** The list test runs in a
  temporary core session without a tunnel; with the VPN live the user is
  offered to stop it, the live core is not used. **Witness**: units "VPN
  running: marker gate, the live core is not called", "VPN off: session, ALL
  members are tested, teardown". **Mutation**: testing through the live core.
- **P10. Heavy nodes are tested in batches.** One test session holds at most
  1 naive node and 4 WireGuard/AmneziaWG endpoints; each batch is its own
  session, closed before the next starts; all nodes are tested. **Witness**:
  units "5 naive + 3 vless: naive ≤ per-config limit, all 8 tested",
  "9 WG (3 of them AWG) + 2 naive + 3 vless: both limits respected",
  "naive batches: a test session of its own for each, all nodes measured".
  **Mutation**: all nodes of the list in one config.
- **P11. A test result is bound to the node.** Deleting or inserting a
  neighbour does not shift badges; a subscription update with the same node
  keeps its result. **Witness**: units "the key does not depend on position:
  deleting a neighbour does not move the others", "the key is a function of
  identity: re-parse gives the same key". **Mutation**: the result key is the
  position in the list.
- **P12. A group node is not "unreachable".** An auto-select node gets the
  neutral verdict `auto`, is not tested and is not caught by "Disable
  unreachable". **Witness**: units "failed/broken/invalid → in the set;
  ok/pending/group → not", "§336: a group gets the group verdict".
  **Mutation**: a group is tested like an ordinary node and gets `err`.
- **P13. Node diagnostics does not touch the route.** The request goes through
  the chosen node: with the VPN live — in the live core by tag, with the VPN
  off — in a temporary session of one node that is shut down after the reply;
  a reply with any HTTP status is a result, not an error. **Witness**: units
  "VPN off → probe session, and it is SHUT DOWN after the reply", "VPN on →
  live core, the probe session is NOT started", "non-2xx arrives as a
  result". **Mutation**: diagnostics switches the selector to the node.
- **P14. Auto-disable is finite and cheap.** A successful start pays for no
  checks; each round disables one new node; there are at most two real starts
  per tap; after 10 rounds a human decides. **Witness**: units "clean start →
  not a single checkConfig", "one bad node → start, check clean, start; two
  real starts", "the same node named again → the loop is aborted", "eleven bad
  nodes → dialog". **Mutation**: a loop without a limit.
- **P15. The verdict is bound to the node body.** Same body — the node stays
  disabled; the body changed or the old body is gone — the verdict is lifted
  and the node enabled; the human turned the toggle on — the verdict is
  lifted. A node disabled by the human is not touched by the automation.
  **Witness**: units "same body → the verdict holds", "body changed → the
  verdict is lifted AND the node is enabled back", "a node disabled by the
  human (no verdict) does not come back on a body change". **Mutation**: the
  verdict is lifted on a timer or on a core update.
- **P16. The verdict does not go into the backup.** In the file the node looks
  enabled; importing an old file with a verdict ignores it. **Witness**: units
  "safety net: after import the node is disabled, no verdict", "file with a
  verdict: the entry is removed". **Mutation**: the verdict is exported
  together with the disable.
- **P17. Speed test measures in three phases.** Ping — trimmed mean of 5
  attempts, download — N parallel streams updated every 0.5 s, upload — 2
  streams; history — the last 10 runs of the session. `no witness`.

## Controlled parameters

### User settings

| Setting | Values | Default | Where it applies |
|---------|--------|---------|------------------|
| Ping URL (global) | any URL, presets Google 204 / Cloudflare / Apple / Firefox / Yandex | `https://www.gstatic.com/generate_204` (template) | ping, server test, chain diagnostics |
| Ping timeout, ms | integer > 0 | 5000 (template); without template 10000 on the home screen, 3000 in list tests | same |
| Direction override | own URL and timeout | none | ping and mass ping of that Direction |
| Auto-ping after connect | on / off | on | home list |
| Test color thresholds, ms | green / yellow / orange | 250 / 500 / 700 | server test badges |
| Passive health check | on / off | on | all URLTest groups of Directions |
| ✨auto: Test URL / interval / tolerance | URL; `30s`…`30m`; 10…200 ms | `cp.cloudflare.com/generate_204` / `15m` / 30 | template group ✨auto |
| URLTest of a Direction and of an auto-select node | see [urltest-group](FUNCTIONS/urltest-group.md) | interval `15m`, tolerance 50, idle `30m`, `least_test` | their own groups |
| Speed test: server / streams | 10 template servers; 1 / 4 / 10 | Cloudflare / 4 | Speed Test screen |

### Core config keys (group `urltest`)

`url`, `interval`, `tolerance` (integer, 0…65535), `idle_timeout`,
`interrupt_exist_connections`, `passive_check`, `mode` (`least_test` ·
`round_robin`), `balancer.pool`, `balancer.pool_tolerance`,
`balancer.sticky_hash` (`process`, `domain`, `source_ip`, `dest_ip`,
`dest_port`; disabling — `["none"]`). Semantics — core feature 007-URLTEST_BALANCE.

### Contract with the core

RPC `urlTestOutbound` (measure one node by tag), `urlTestGroup` (test all
group members and reselect), `getURLViaOutbound` (HTTP GET through a node with
the body), `checkConfig` (silent config check), a temporary core session
without a tunnel. Core rejection string: `initialize <outbound|endpoint>[<i>]
<type>[<tag>]: <text>` (core ≥ `1.14.1-lx.7`). Warning code
`core_rejected` with `params.reason`.

## Inputs / Outputs

**Inputs:** user gesture (tap/long tap on the ping button, node menu item,
list test button, Run in diagnostics, Start); tunnel transition to
"connected"/"stopped", app backgrounding; core replies to measurements; core
rejection text at start; the settings above; Debug API commands.

**Outputs:** latency or `ERR` on a node in the list and a test badge;
reselection of URLTest groups in the core; summary `N ok · N err · N broken`;
disabled nodes (in bulk — by user action, automatically — by core rejection)
with a reason; the "N servers disabled" banner; the raw reply of a diagnostic
request; speed test results; `urltest` keys in the config.

## Data flow

```
ping:        gesture/auto-ping → URL+timeout (Direction → global → template)
             → measure in the live core (≤10 in parallel) → Direction map
             → color/sort → [selected one failed] → core group test
test:        gesture → VPN off? ─no→ "Stop VPN" → node batches
             → temporary core session per batch (≤6 measurements in parallel)
             → badge by node key → bulk actions
diagnostics: Run → VPN? → live core by tag | one-node session → raw reply
rejection:   Start → core start → rejection names the node → disable + verdict
             → checkConfig rounds without tunnel → clean → final start → banner
```

## Rules and guarantees

- Ping is possible only with the tunnel up; `block` nodes are not pinged;
  a disabled endpoint shows `—` instead of a measurement.
- Mass ping follows the display order of the list (with filter and sort) and
  snapshots the URL, timeout and target Direction at the start of the run.
- Measurements live in app memory and are not written to storage.
- The server test and diagnostics with the VPN off are mutually exclusive
  with the live core: starting the VPN closes a hanging test session.
- Auto-disable fires only on the Start button (and on a Debug start with the
  safety net); autostart, the tile, the Intent API and reconnect start the
  ready config without the automation.
- Runtime errors (timeout, server refusal, ping failure) never disable a node.

## Boundaries

- The node list, sort by ping, endpoint state badges — [007-NODE_LIST](../007-NODE_LIST/FEATURE.md).
- Group composition and balancing, detour, the dependency graph of dead nodes
  — [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md); this
  feature only feeds it fresh measurements.
- Texts and grouping of node notifications by code —
  [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md).
- Live statistics and a group's node selection in real time —
  [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md).
- The WARP endpoint scanner uses the same test session — [015-WARP](../015-WARP/FEATURE.md).
- Layered chain probe — [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md).
- The speed test does not address a node: it measures the device's current
  path (through the tunnel if the VPN is up) and cannot be cancelled before
  the run ends.
- Depends on OS capabilities: starting the VPN from the background without UI
  (no auto-disable there), the process memory limit that determines the test
  batch size.

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Node ping | Measures one node or all visible nodes through the running core, cancels on a second tap, pings automatically after connecting and keeps results separate per Direction. | P1–P4, P6 | [node-ping.md](FUNCTIONS/node-ping.md) |
| Ping settings | Sets the global ping URL and timeout with presets, and lets a Direction override them. | P5 | [ping-settings.md](FUNCTIONS/ping-settings.md) |
| URLTest group | Passes measurement and switching parameters to the core's `urltest` group, forces a re-test with reselection and keeps `interval` and `idle_timeout` consistent. | P6–P8 | [urltest-group.md](FUNCTIONS/urltest-group.md) |
| List server test | Tests every node of a subscription or folder without the VPN, colours badges by thresholds and applies bulk actions to the results. | P3, P9–P12 | [server-list-test.md](FUNCTIONS/server-list-test.md) |
| Node diagnostics | Sends one HTTP request through a node to a chosen service and shows the raw reply, without switching the active node. | P13 | [node-diagnostics.md](FUNCTIONS/node-diagnostics.md) |
| Auto-disable of nodes rejected by the core | Disables nodes the core rejects at start, keeps the core's verbatim reason as a verdict and reports them in a banner. | P14–P16 | [core-reject-auto-disable.md](FUNCTIONS/core-reject-auto-disable.md) |
| Speed test | Measures ping, download and upload of the device's current path, through the tunnel when the VPN is up. | P17 | [speed-test.md](FUNCTIONS/speed-test.md) |

## Related features

- [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md) — owns the node toggles that auto-disable and bulk test actions flip.
- [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md) — registry checks at parse time; core-rejection auto-disable is the second line behind them.
- [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) — group composition, balancing, detour, the dead-node dependency graph and the layered chain probe; fed by this feature's measurements.
- [007-NODE_LIST](../007-NODE_LIST/FEATURE.md) — the node list, sort by ping, endpoint state badges and node/folder toggles.
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — live statistics, the group's current selection and speed on the home screen.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — texts and grouping of node notifications by code (including `core_rejected`).
- [015-WARP](../015-WARP/FEATURE.md) — the WARP endpoint scanner reuses the same test session and sets a folder's own test URL/timeout.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — export/import of ping settings; the core-rejection verdict is kept out of the backup.

## Maintenance notes

- **The group test is a separate RPC.** A measurement "through a group" by its
  tag does no reselection; the bug lived for months disguised as "Auto keeps a
  dead node" (§308).
- **Folder test and home ping use different scales.** The home list colors by
  200/500 ms with no setting, list tests by the configurable 250/500/700.
- **The core rejection arrives wrapped.** Parsing looks for `initialize `
  anywhere in the string: Go prefixes and a localized template on top are
  normal; in the first version the safety net never fired because of them
  (D-1 in §478F).
- **A tag is not identity.** Namesakes get `Dup`/`Dup-1`, and after the first
  is disabled the second becomes `Dup`; "the same node" is compared by node
  reference, otherwise the loop breaks on the second bad node.
- **Test memory is linear in heavy nodes.** ≈17.5 MB of pools per
  WG endpoint and a full network stack per naive node; batch limits were raised
  only after measuring on a device.
- **`sticky_hash: []` is not disabling.** The core collapses an empty list to
  the default; disabling is only `["none"]`.
