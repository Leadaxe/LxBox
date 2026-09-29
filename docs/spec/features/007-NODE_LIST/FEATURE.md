[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Node list — choosing a VPN server on the main screen: filters, sorting and folders

The LxBox main screen lists the nodes of the selected Direction and switches
the active VPN server in the running sing-box core with one tap, without a
tunnel restart. Filters by name, emoji flag, protocol (VLESS, WireGuard,
AmneziaWG, Hysteria2 and others), transport and ping, four sort modes and a
drag-and-drop order help find a node among hundreds. Standalone servers are
grouped into folders that can be tested without starting the VPN.

| Field | Value |
|------|----------|
| Feature | 007-NODE_LIST |
| Type | Product feature |
| Absorbed | `§003F` `§048F` `§070F` `§071F` `§234F` `§236F` `§565F` (phase B of `§565F` — task 568) |
| State | ✅ written from code, 2026-09-28 |

## Purpose

The main screen is where a person **sees what traffic is going through right
now and changes it with one tap**. Nodes are shown as the list of the
selected **Direction** (a core selector group); the active node is pinned at
the top; choosing another node is applied in the running core without
restarting the tunnel.

Around the list are tools to find the right node among hundreds: filters
(regex and emoji, protocol, transport/security, source, ping threshold,
detour), four sort modes and a manual order via drag-and-drop. The sources
screen hosts **folders** — containers of standalone servers with a shared
switch and a "batch" test without starting the VPN — and the **fold** of a
source into one manual or auto-select group.

Principles the feature protects:

1. **Selecting a node is not a config edit.** Switching within a Direction
   happens in the live core; the tunnel is not restarted, the config is not
   marked as changed.
2. **Service entries are always visible and always in place.** Direct, the
   Direction's auto-select twin, block and the active node — at the top under
   any sort; the filter does not hide them.
3. **The view does not change the route.** Filters, sorting, columns and
   manual order affect only the display (and the order of mass ping); they
   do not get into the core config and do not mark the config as changed.

Where nodes come from — [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md);
ping, URLTest and node health — [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md);
node editing — [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md); statistics
and traffic — [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md).

## Promises

- **P1. Node selection is applied live.** Choosing another node in a
  Direction with the tunnel up goes to the core as `SelectOutbound`, then the
  list pulls a fresh group snapshot; the tunnel is not restarted.
  **Witness:** unit "selecting another node goes to the core via a select
  call". **Mutation:** rebuild the config on node selection.
- **P2. Re-selecting the active node is a no-op.** The core is not called,
  connections are not broken. **Witness:** unit "selecting the already active
  node — no-op, event 'already active'". **Mutation:** remove the comparison
  with the current active node.
- **P3. The active node is pinned at the top.** Under any sort it stands right
  after direct / auto-select twins / block and is not duplicated if it is a
  service entry itself. **Witness:** units of the group "§196 — the active
  node is pinned after direct/auto" (latency, A–Z, default, duplicate,
  absent from the list). **Mutation:** sort the active node together with
  the rest.
- **P4. Service nodes are at the top by type, not by name.** Direct (the "Pin
  DIRECT" toggle), the Direction's auto-select twin (the "Pin AUTO" toggle),
  block — always; an auto-select node of a subscription/folder stays in its
  place. **Witness:** units "§125 — the auto twin is pinned by the urltest
  type", "the §322 auto-select node is NOT pinned", "block is pinned under
  any sort". **Mutation:** pin by the literal tag `direct-out`.
- **P5. The filter does not hide the chassis.** Directions, their twins,
  direct/block/dns are visible under any filter; a subscription's
  auto-select node is filtered on a par with ordinary ones. **Witness:**
  units "chassis visible under any regex", "regex not matching the name — the
  subscription's auto node goes away". **Mutation:** short-circuit all
  urltest groups.
- **P6. Filter categories combine with AND, within a category — OR; `!`
  inverts a category.** An unknown protocol/transport does not pass with an
  active filter; an unmeasured node always passes the ping threshold; regex
  is case-insensitive. **Witness:** units "filter: AND combine", "unknown
  proto with active filter → false", "delay == null → true", "match — true
  (case-insensitive)". **Mutation:** treat an unpinged node as slow.
- **P7. Source membership is by tag prefix.** A node belongs to a
  subscription/folder if its tag starts with "prefix + space"; a source
  without a prefix does not take part in the filter; a shared prefix gives
  the node to both. **Witness:** units "empty prefix → does NOT take part",
  "prefix without a following space → does NOT match", "subscription and
  folder with one prefix → matches both". **Mutation:** compare the prefix
  without the separator.
- **P8. The filter is remembered per Direction within a session.** Switching
  A→B→A brings back A's filter; the detour filter and "show non-matching" are
  shared. **Witness:** units "Direction A's filter is restored after A→B→A",
  "detour/show-non-matching are global". **Mutation:** one filter for all
  Directions. Reset on application restart — `no witness`.
- **P9. The manual order lives across modes and restarts.** Leaving "Custom"
  does not erase the order; new nodes go to the end, vanished ones drop out;
  the mode and the order are restored after a restart and do not mark the
  config as changed. **Witness:** units "new node → end", "deleted node
  filtered out", "non-config savers (sort/ping) do NOT raise the flag";
  surviving a restart — manual check (Custom, drag, kill the app, open — the
  order is the same). **Mutation:** reset the order on cycle.
- **P10. Two columns only on a wide screen and not in manual mode.** ≥ 600 dp
  and the toggle on — two columns row by row; "Custom" — always one.
  **Witness:** units "599 dp — one", "600 dp — two", "manual sort stays
  single-column". **Mutation:** strict `> 600`.
- **P11. The "Add a server" hint — by zero servers, not by an empty config
  file.** Shown with the VPN off if there is not a single real node either in
  the config or in the sources. **Witness:** units "template config without
  servers → guide", "window 'server added, config not rebuilt yet' → no
  guide", "tunnel up → never". **Mutation:** bring back the "config is empty"
  predicate.
- **P12. A group of the manual genus stays a selector with a selection.** A
  `selector` group from a subscription or folder goes to the core as a
  `selector` with `default`; a dropped member removes `default` (the core
  takes the first) with one report line; the member selection of a
  subscription/folder group is saved and survives a restart. **Witness:**
  units "core body: type selector, membership and default", "dropped default
  removed, one code", "selection of a subscription group is stored and
  applied to the build". **Mutation:** collapse a selector into a urltest.
- **P13. A source fold is expanded by mode.** `manual` — one selector, `auto`
  — a urltest under the same name, `both` — `<tag>-auto` and a selector with
  it first and as the default; zero nodes — no groups, rules pointing to the
  fold go to `route.final`; a name taken by a Direction — the source is not
  folded. **Witness:** fold build units "both: auto-select <tag>-auto, then
  the selector", "zero nodes: one replace_group_empty", "fold tag =
  Direction: source not folded". **Mutation:** write an empty group.
- **P14. A folder is one switch for all.** A disabled folder or member does
  not get into the config; input is split into members 1:1; "Keep servers" on
  deletion moves members out as standalone. **Witness:** units "a disabled
  folder emits nothing", "input is split into members 1:1", "deleting a
  folder with Keep servers moves members out as standalone".
  **Mutation:** store the folder as one body.
- **P15. The folder test is a separate core session, not with the VPN.** With
  the VPN up the test does not start (the "VPN is running" dialog with "Stop
  VPN"); without the VPN all members are tested, including disabled ones;
  broken ones get a verdict before the core. **Witness:** units "VPN running:
  marker gate, the live core is not called", "ALL members (including
  disabled) get into the config", "broken members get a verdict before the
  core". **Mutation:** test through the live core.
- **P16. A test result is bound to the node, not to the row.** Deleting or
  reordering a neighbour does not move someone else's result. **Witness:**
  unit "the key does not depend on position: deleting a neighbour does not
  shift the rest". **Mutation:** key by index.
- **P17. Breaking connections on switch — only by the toggle.** With
  "Interrupt connections on switch" on, after a node is selected the live
  connections of that Direction are closed; by default — not.
  `no witness`.

## Controlled parameters

| Parameter | Where | Values | Default |
|---|---|---|---|
| Direction | main screen, dropdown (active with the VPN) | core selector groups except `GLOBAL`; `NETWORKS` when present | `route.final`, otherwise the first |
| Sort mode | sort button (tap — cycles), "Sort options" sheet | Default · Ping · A–Z · Custom | Ping |
| Pin DIRECT to top / Pin AUTO to top | "Sort options" | on/off, per session | on / on |
| Re-sort on manual ping | "Sort options" | on/off, per session | on |
| Filters: Regex, Protocol, Sources, Settings | filter panel | see [filters](FUNCTIONS/node-filters.md) | all off, threshold "200" inactive |
| Interrupt connections on switch | Settings | on/off | off |
| Two columns on wide screens | App Settings → Appearance | on/off | on |
| Folder: name, on, tag prefix, detour policy | Servers → folder → Settings | — | prefix empty |
| Replace with a group | folder/subscription Settings | Manual · Auto · Both; name; auto parameters | off; name = source name |
| Test color thresholds | long-press on the test button in a folder | green/yellow/orange, ms | 250 / 500 / 700 |
| Ping URL, test timeout | same place (global ping settings) | URL, ms | global; timeout 3000 ms |

Constants: the two-column threshold is 600 dp; the folder test — 6 parallel
measurements, no more than 1 naive and 4 WireGuard records per run of the
test core.

**Core keys and RPCs the feature hands over/uses:** the `selector` outbound
(`outbounds`, `default`, for a fold `interrupt_exist_connections: true`),
`urltest` (the `<tag>-auto` twin), `route.final` (the starting Direction and
the receiver of rules of a dropped fold). RPC: `SelectOutbound`, the group
snapshot and stream, `CloseConnection` (breaking on switch),
`URLTestOutbound` (the folder test in a separate session).

## Inputs / Outputs

**Inputs:** the core's group snapshot (tags, types, members, current
selection; only with the tunnel up), the built config (node types,
transport/security, detour links), source records (prefixes, folders, folds,
group member selection), ping measurements, user gestures.

**Outputs:** node selection in the core; the saved member selection of a
source group; changes of folders and folds in sources (→ config rebuild);
mass ping order = the visible list order; the saved sort mode and manual
order.

## Data flow

```
core group snapshot ─► Directions (selector, without GLOBAL) ─► selected Direction
        │                                                      │
        └── members + selection ──► pinned section ─► sorting ─► detour pool
                                                                  │
                    filter (regex/protocol/variant/source/ping) ──┘
                                   │
                  matching ─► (+ non-matching dimmed | hidden) ─► list
                                   │
       node selection ─► SelectOutbound ─► fresh snapshot ─► ACTIVE
                                   └─► source group ─► remember the selection
```

Folders and folds take a different path: an edit on the sources screen →
[config build](../003-CONFIG_BUILD/FEATURE.md) → new groups in the core
snapshot.

## Rules and guarantees

- The node list is built only from the core snapshot: with the VPN off there
  are no nodes, instead of the list — "Tap to connect" or the "Add a server"
  hint.
- An empty group snapshot on top of an already filled one with a live tunnel
  is ignored (core race noise); swipe down pulls the snapshot again.
- A Direction that vanished from the snapshot is replaced with `route.final`,
  otherwise the first one.
- Tapping a row only highlights the node; selection — with the ▷ button or
  "Use this node" in the menu, and only with the tunnel up.
- Pinned rows cannot be dragged, and a row cannot be "dropped" into them.
- Dragging in any mode switches sorting to "Custom".
- Filter, sorting and columns do not change the core config.

## Boundaries

- Sources and their update —
  [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md); parsing group forms —
  [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md); building groups,
  Directions and the template —
  [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) and
  [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md).
- Ping, mass ping, group URLTest, ping settings, ⚠ "root of trouble" —
  [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md). Here only the badge's
  place and the mass ping order.
- The node screen (View details), Copy URI, emoji tags in the name —
  [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md).
- The traffic bar above the list (speed, connections, time) and navigation to
  statistics — [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md).
- The application itself does not store the selection in a Direction's
  selector between VPN restarts.
- The folder test requires the VPN to be off: one core session runs at a
  time (depends on OS and core capabilities).

## Functions

| Function | What it does | Promises | File |
|---|---|---|---|
| Direction and active node | Selects a Direction and a node in the running core, pins the active node at the top and handles `NETWORKS` and swipe-to-refresh. | P1 P2 P3 P17 | [directions-and-active-node.md](FUNCTIONS/directions-and-active-node.md) |
| Group genus and folding a source into a group | Keeps the manual or automatic genus of a source group together with its selected member, and folds a whole subscription or folder into one group. | P12 P13 | [selector-genus-and-fold.md](FUNCTIONS/selector-genus-and-fold.md) |
| Node filters | Filters a Direction's nodes by regex or emoji, protocol, transport/security, source, ping threshold and detour role, and remembers the filter per Direction. | P5 P6 P7 P8 | [node-filters.md](FUNCTIONS/node-filters.md) |
| Sorting and manual order | Orders the list by config, ping, name or a custom drag-and-drop order, keeps service nodes and the active node pinned, and uses two columns on wide screens. | P3 P4 P9 P10 | [node-sorting.md](FUNCTIONS/node-sorting.md) |
| Node row: badges and context menu | Shows the ACTIVE mark, protocol·transport·security, ping, WireGuard state and notification icons in the row, and opens node actions on a long press. | P2 | [node-row-badges-and-menu.md](FUNCTIONS/node-row-badges-and-menu.md) |
| Main screen empty states | Replaces an empty list with the next step: "Add a server", "Tap to connect" or a hint to pick another Direction. | P11 | [empty-states.md](FUNCTIONS/empty-states.md) |
| Server folders and the single source list | Groups standalone servers into folders with a shared switch, tag prefix and detour policy, and keeps subscriptions, servers, folders and chains in one ordered list. | P14 | [server-folders.md](FUNCTIONS/server-folders.md) |
| Folder test | Measures a folder's servers in a separate core session without the VPN, colours results by thresholds and offers bulk actions on slow and unreachable servers. | P15 P16 | [folder-testing.md](FUNCTIONS/folder-testing.md) |

## Related features

- [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md) — where nodes come from: subscriptions, adding a source, disabling subscription nodes.
- [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md) — parsing groups from formats (the `selector`/`urltest` genus) and parse notifications in the row.
- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — building groups, Directions and the template; folders and folds reach the main screen through it.
- [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) — Directions, the auto-select node, folder detour policy, Direction filters in the config.
- [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md) — the node screen (View details), Copy URI, editing a folder member's node.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — ping, mass ping, group URLTest, ⚠ "root of trouble"; here only the badge's place and the order.
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — the traffic bar above the list and navigation to statistics.
- [014-AUTOMATION](../014-AUTOMATION/FEATURE.md) — switching a node and a Direction from outside.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — storage and backup of `replace`, `group_type`, `default`, restore from backup.

## Maintenance notes

- **The nodes of the selected Direction are the members of the core's
  selector group**, not a list from the sources. Anything that did not get
  into the group (disabled, rejected, folded) is not visible on the main
  screen — look for the reason in the build.
- **Source membership is reconstructed from the tag prefix.** Without a
  subscription/folder prefix the source filter does not apply to it, its
  nodes fall into "others". There is no synthetic "Custom" chip any more.
- **Dragging fixes the visible order.** The new manual order is exactly the
  displayed list: those matching the filter first; nodes hidden by the
  filter are not included and later go to the end.
- **The pin toggles and "Re-sort on manual ping" are per session**, while the
  sort mode and the manual order are saved. The different durability of
  neighbouring settings in one sheet is deliberate, but surprising.
- **Selecting a subscription group member with a live tunnel** does not mark
  the config as stale, but the next VPN start rebuilds the config —
  otherwise the selection would be lost.
