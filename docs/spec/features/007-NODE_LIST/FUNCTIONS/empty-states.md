[English](empty-states.md) · [Русский](empty-states.ru.md)

# Main screen empty states — the next step instead of an empty list

When there are no nodes to show, the main screen offers the next step: add a
server, connect the VPN or pick another Direction.

| Field | Value |
|------|----------|
| Feature | [007-NODE_LIST](../FEATURE.md) |
| Promises | P11 |
| State | ✅ written from code, 2026-09-28 |

## What it does

When there is nothing to show, the list's place is taken not by emptiness
but by the next step: add a server, connect, or choose another Direction.

## Parameters

No settings of its own.

## Inputs / Outputs

**Input:** tunnel state, the saved config (the number of real nodes,
excluding service types), presence of nodes in sources, members of the
selected Direction.
**Output:** one of the screens below in place of the list.

| State | What is shown | Action |
|---|---|---|
| VPN off, **no real servers** (neither in the config nor in sources) or no config | "Add a server" + "Connect a subscription or add a node manually to get started."; the "+" button; "Restore from backup" | "+" — sources screen; restore from backup |
| VPN off, servers exist | a large "Tap to connect" area | tap = the same Start button (inactive while starting/stopping) |
| VPN up, the selected Direction has no nodes | "No nodes in this direction. Try another one." | — |
| VPN up, config empty (load failure) | "Add a server" | as in the first row |

## Rules and invariants

- "No servers" is counted by real nodes, not by the config file: a config
  from the template carries service nodes (direct, Directions), and by them
  the screen would look non-empty.
- A node just added to a source but not yet in the rebuilt config already
  removes the hint.
- A raw config import without source records also removes the hint — its
  nodes are visible in the config.
- With the tunnel up the "Add a server" hint is never shown, except for the
  emergency "config failed to load" — the other "up" states have their own
  banners.
- With the VPN off there is no "Nodes" header, sorting, filter or traffic
  bar — there is nothing to filter.
- VPN up, no real Directions, but there are nodes outside the selection
  lists — `NETWORKS` is shown instead of emptiness.
- To check how the empty screen looks without losing data, the Debug API has
  an empty-state preview mode; it substitutes only the view.

## Boundaries

- The sources screen and adding — [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FUNCTIONS/add-source.md).
- Restore from backup —
  [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.md); first
  launch and the wizard — [020-APP_SHELL](../../020-APP_SHELL/FEATURE.md).
- Start error banners and "Config changed — restart VPN" —
  [010-VPN_SERVICE](../../010-VPN_SERVICE/FEATURE.md)/[003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [024](../../../tasks/024-home-empty-state-cta.md) | Done | "Add a server" with a button and the "Tap to connect" area |
| 2 | [025](../../../tasks/025-preview-empty-state.md) | Done | Empty state preview without data loss |
| 3 | [095](../../../tasks/095-filter-mode-workspace.md) | DONE | Without the tunnel the node header is hidden |
| 4 | [328](../../../tasks/328-no-servers-hint-on-home.md) | Implemented | Hint by zero servers, not by an empty config |
| 5 | [579](../../../tasks/579-networks-pseudo-direction.md) | Implemented | Without Directions, NETWORKS is shown |
