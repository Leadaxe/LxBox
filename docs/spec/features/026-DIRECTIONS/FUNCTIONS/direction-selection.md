[English](direction-selection.md) · [Русский](direction-selection.ru.md)

# Direction and active node — seeing and switching the node that carries traffic

The main screen shows the selected Direction and its active node and
switches either one in the running core without restarting the VPN tunnel.

| Field | Value |
|------|----------|
| Feature | [026-DIRECTIONS](../FEATURE.md) |
| Promises | P15 P16 P17 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Shows which **Direction** (a core selector group) and which node traffic is
going through right now, and lets the user switch both in the running core.
The active node is highlighted and pinned at the top of the list.

## Parameters

| Parameter | Values | Default |
|---|---|---|
| Direction (dropdown) | all selector groups of the core snapshot except `GLOBAL`; last — the `NETWORKS` pseudo-direction, if the config has such nodes | `route.final` if it is a selector; otherwise the first |
| Interrupt connections on switch (Settings) | on/off | off |

The Direction list includes not only the application's Directions but any
selectable selector groups of the config: a provider `selector` from a
subscription and the selector of a source fold ([genus and
fold](../../007-NODE_LIST/FUNCTIONS/selector-genus-and-fold.md)).

## Inputs / Outputs

**Input:** the core's group stream and snapshot (tag, type, members, current
selection); gestures — selection in the Direction list, the ▷ button on a
row, "Use this node" in the menu, swipe down.
**Output:** `SelectOutbound(group, node)` in the core; with the toggle on —
`CloseConnection` for live connections whose chain contains this Direction;
for a subscription or folder group — the saved member selection.

## Rules and invariants

- A node and a Direction can be selected only with the tunnel up: the
  Direction list and the ▷ buttons are inactive while the VPN is off or an
  operation is in progress.
- **Tapping a row only highlights the node** (a stripe on the left, the
  background) — no selection happens. A node is selected with the ▷ button or "Use
  this node".
- Selecting the active node is a no-op: the core is not called, connections
  are not broken; an external automation tool receives "already active"
  ([007-NODE_LIST · P2](../../007-NODE_LIST/FEATURE.md#promises)).
- After selection the list immediately highlights the new node, then pulls a
  fresh group snapshot and sets ACTIVE from the core's answer. If the
  snapshot did not arrive — ACTIVE is set by the selection.
- Core refusal — the error "Switch failed: …"; the previous node stays
  active.
- Breaking connections on switch takes no longer than 5 s; a connection that
  has already closed is skipped.
- **Pinning:** the active node stands right after direct / auto-select twins
  / block under any sort; if the active node is a service node itself, it is
  not duplicated ([007-NODE_LIST · P3](../../007-NODE_LIST/FEATURE.md#promises)).
- An empty group snapshot on top of a non-empty one with a live tunnel is
  race noise and is ignored. Swipe down pulls the snapshot again; without a
  core answer the current one stays.
- If the selected Direction vanished from the snapshot (renamed, disabled) —
  `route.final` is selected, otherwise the first one.
- The selection lives in the core: the app does not store it, but the config
  enables `experimental.cache_file` (`cache.db`), so the core itself brings the
  selector back to the last chosen node on the next start; the cache database
  is not part of a backup or a workspace slot.
- Changing the Direction resets the "frozen" sort order
  ([sorting](../../007-NODE_LIST/FUNCTIONS/node-sorting.md)) and switches the filter memory
  ([filters](../../007-NODE_LIST/FUNCTIONS/node-filters.md)).
- `NETWORKS` is a view, not a traffic exit: it shows nodes outside the
  selection lists (e.g. Tailscale) in config order, without filter, sorting
  and ping; in place of the latency — the node state from the core; tapping
  opens the node screen. The selected real Direction does not change.
- For an auto-select group the row shows "→ selected node"; the "Select
  server" menu item highlights it and scrolls the list to it.

## Boundaries

- The node list itself — filters, sorting, pinning of service rows, badges —
  [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md); selecting a member of a group
  that is not a Direction, from the node screen — [group
  genus](../../007-NODE_LIST/FUNCTIONS/selector-genus-and-fold.md); the node
  screen itself — [008-NODE_EDITOR](../../008-NODE_EDITOR/FEATURE.md).
- Automation tools (switching a node/Direction from outside) —
  [014-AUTOMATION](../../014-AUTOMATION/FEATURE.md).
- The application does not store the selection in a Direction's selector
  between VPN starts; what survives is the core's cache.
- `NETWORKS` composition and state — [012-LIVE_STATE · P19](../../012-LIVE_STATE/FEATURE.md#promises).
- The traffic bar above the list — [012-LIVE_STATE](../../012-LIVE_STATE/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [003F](../../../tasks/003F-home-screen/spec.md) | Implemented | Main screen: group, list, ACTIVE, node selection, swipe |
| 2 | [143](../../../tasks/143-interrupt-connections-on-node-switch.md) | Implemented | Toggle for breaking group connections on node change |
| 3 | [196](../../../tasks/196-active-node-pinned-after-direct-auto.md) | — | Active node at the top after direct/auto under any sort |
| 4 | [203](../../../tasks/203-select-server-on-auto.md) | — | "Select server" on an auto-select node: highlight and scroll |
| 5 | [290](../../../tasks/290-automation-node-switch-gaps.md) | — | Selecting the already active node does not poke the core and the network |
| 6 | [393F](../../../tasks/393F-directions/spec.md) | Released v2.21.0 | Channels became Directions, the Direction dropdown |
| 7 | [579](../../../tasks/579-networks-pseudo-direction.md) | Implemented (device-pending) | The NETWORKS pseudo-direction |
