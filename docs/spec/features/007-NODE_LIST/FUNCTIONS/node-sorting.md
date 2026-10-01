[English](node-sorting.md) · [Русский](node-sorting.ru.md)

# Sorting and manual order — arranging the node list

The node list follows the config order, ping, name or a custom drag-and-drop
order, and splits into two columns on a wide screen.

| Field | Value |
|------|----------|
| Feature | [007-NODE_LIST](../FEATURE.md) |
| Promises | P3, P4, P9, P10 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Orders the Direction's list: as in the config, by ping, by name, or in a
custom order set by drag-and-drop. Service nodes and the active node stay at
the top in a separate section. On a wide screen the list is laid out in two
columns.

## Parameters

| Parameter | Where | Values | Default | Lives |
|---|---|---|---|---|
| Mode | tap on the sort button — cycles; the "Sort options" sheet (long-press) — choice | Default → Ping → A–Z → Custom → Default | Ping | saved |
| Manual order | dragging a row | list of tags | empty | saved |
| Pin DIRECT to top | "Sort options" | on/off | on | session |
| Pin AUTO to top | "Sort options" | on/off | on | session |
| Re-sort on manual ping | "Sort options" | on/off | on | session |
| Two columns on wide screens | App Settings → Appearance | on/off | on | saved |

The button icon shows the mode; a yellow dot — when at least one of the three
toggles is not at its default value. Without nodes the button is inactive.

## Inputs / Outputs

**Input:** the Direction's members in config order, node types, the active
node, measurements (own and from other Directions), the drag gesture.
**Output:** the order of rows on screen and the mass ping order; the saved
mode and manual order (they do not mark the config as changed).

## Rules and invariants

- **The pinned section** at the top, in order: direct (if "Pin DIRECT"),
  Direction auto-select twins (if "Pin AUTO"), block (always), then the
  active node (always). Pinning is by node type. An auto-select node of a
  subscription/folder is not pinned. Default mode with the toggles off gives
  the pure config order (block and the active node are at the top anyway).
- **Ping:** ascending by the latency shown in the row (including the dimmed
  "~" one from another Direction); then errors; unmeasured ones — at the end.
- **A–Z:** by name, case-insensitive.
- **Custom:** the saved order, filtered by the current membership; nodes
  absent from it (new ones) — at the end in config order. One order for all
  Directions.
- **Dragging** in Custom mode — by the visible handle on the left,
  immediately; in other modes — by a long press at the left edge of the row;
  any completed drag switches the mode to Custom and saves the visible order.
  Pinned rows do not move, a row cannot be dropped into the pinned section.
- Leaving Custom (by tap or by choice) does **not erase** the order: going
  back to Custom restores it.
- **Re-sort on manual ping off:** a single ping does not move rows; the order
  is recalculated after a mass ping, a Direction change, a config rebuild or
  a change in the number of nodes.
- **Columns:** with width ≥ 600 dp and the toggle on — two columns, row-wise
  order (1-2 / 3-4); in Custom mode always one column; changing the number of
  columns on the fly keeps the scroll position.
- Below the last row — a spare space one row high, so it can be scrolled out
  from under the bottom elements.

## Boundaries

- The order of members inside a folder and the order of sources — [folders](server-folders.md).
- Ping itself and mass ping — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [003F](../../../tasks/003F-home-screen/spec.md) | Implemented | Three modes, cycled with one button; direct/auto on top |
| 2 | [070F](../../../tasks/070F-sort-options/spec.md) | Released v1.9.0 | Options sheet: Pin DIRECT/AUTO, Re-sort on manual ping |
| 3 | [071F](../../../tasks/071F-manual-node-reorder/spec.md) | Released v1.9.0 | Manual order by drag-and-drop, manual mode |
| 4 | [098](../../../tasks/098-reorder-subscriptions-and-unify-dns.md) | DONE | Visible drag handle in manual mode |
| 5 | [100](../../../tasks/100-manual-sort-selectable-and-persisted.md) | DONE | Custom in the cycle and in the sheet; mode and order are saved |
| 6 | [134](../../../tasks/134-node-list-bottom-spacer.md) | Done | One-row spare space under the list |
| 7 | [196](../../../tasks/196-active-node-pinned-after-direct-auto.md) | — | Active node in the pinned section |
| 8 | [325](../../../tasks/325-mass-ping-wipes-other-channels.md) | — | Measurements per Direction; sorting by the visible number |
| 9 | [446](../../../tasks/446-large-node-list-performance.md) | Waves 1–3 in develop | Large lists without lag when sorting |
| 10 | [537](../../../tasks/537-nodes-two-columns-wide.md) | Done | Two columns on a wide screen |
| 11 | [541](../../../tasks/541-appearance-tab-two-columns-toggle.md) | Done | Two-column toggle in Appearance |
