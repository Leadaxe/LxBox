[English](node-filters.md) · [Русский](node-filters.ru.md)

# Node filters — finding the right server among hundreds

The filter panel narrows a Direction's node list by name, emoji flag,
protocol, transport, source, ping and detour role without touching the
config.

| Field | Value |
|------|----------|
| Feature | [007-NODE_LIST](../FEATURE.md) |
| Promises | P5, P6, P7, P8 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Helps find the right nodes in a large Direction: by name (regex, emoji flag),
protocol, transport/security, source, ping threshold and detour role.
Non-matching nodes are either dimmed and moved down, or hidden. The filter
is view-only: it changes neither the route nor the config.

## Parameters

The panel opens with the filter button in the "Nodes" header; while the
panel is in use the traffic bar and the header are hidden. Tabs get a dot
when their filter is active; above the content — a summary of active filters
as chips (tap — to the tab, ✕ — clear).

| Tab | What | Default |
|---|---|---|
| Regex | regex field + `!`; emoji chips from node names (by frequency); 💾 — save into a Direction | empty |
| Protocol | protocol chips of the pool + `!`; second row — transport/security (`tcp` `ws` `grpc` `h2` `h3` `httpupgrade` `quic` `xhttp`, `TLS` `TLS+Vision` `Reality` `Reality+Vision`, `awg` … `awg3.1`, modes `Fastest`/`Pool`) + `!` | nothing |
| Sources | chips of subscriptions and folders + `!` | nothing |
| Settings | "Test ≤ N ms" (checkbox + number); detour: off / hide detour / only detour; "Show non-matching (dimmed)" | threshold 200 inactive; detour off; show |

## Inputs / Outputs

**Input:** the Direction's list after pinning and sorting; node type,
transport and security from the built config; source prefixes; the latest
measurements (including from other Directions, as in the row).
**Output:** the visible list — matching ones, then (if allowed) non-matching
ones at 0.4 opacity; mass ping gets the same order.

## Rules and invariants

- Two phases: first the **detour pool** (hide, or keep only, the nodes that
  are referenced as a detour hop), then **matching**. Detour is determined by
  links in the config, not by the ⚙ icon.
- **The chassis is always visible and counts as matching:** Directions, their
  auto-select twins, direct/block/dns — by type. An auto-select node of a
  subscription/folder is an ordinary node: its protocol is "Auto", its
  transport — the mode (`Fastest`/`Pool`).
- Between categories — AND, within a category — OR; `!` inverts only its own
  category and has no effect with an empty selection.
- Regex — case-insensitive, with a 300 ms debounce; an invalid regex is
  highlighted and the filter does not apply it. Tapping an emoji chip adds or
  removes the emoji as an OR term of the regex.
- A node's protocol/transport is unknown — with an active filter it does not
  match (with `!` — it matches). A manual-genus group from a source has no
  protocol: any protocol chip hides it.
- **Source — by tag prefix** "prefix + space". A chip exists only for an
  enabled subscription/folder with a non-empty prefix and at least one node.
  A node without a prefix (a standalone server, an import, a source without a
  prefix) belongs to no chip: selecting a chip hides it, `!` keeps it. A
  shared prefix of two sources — the node is visible in both. Chains are not
  filter sources.
- Ping threshold: a node with latency above the threshold does not match; an
  unmeasured one always matches; entering a number enables the threshold by
  itself.
- **Memory:** regex, protocols, variants, sources (with `!`) and the
  threshold are remembered per Direction and restored on returning to it; an
  empty filter does not create an entry. The detour filter and "Show
  non-matching" are shared by all. The memory lasts for the application's
  run time.
- 💾 is available only when an existing Direction is selected: it asks which
  Direction field to put the regex into (node filter or default filter) and
  opens the Direction editor with the field filled in — there is no silent
  write.
- `NETWORKS` has no filter.

## Boundaries

- Direction filters in the config (`node_filter`, inversion) —
  [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md); here only
  moving the regex into the editor.
- The filter on the folder screen (regex + protocols) — [folder test](folder-testing.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [048F](../../../tasks/048F-home-node-filters/spec.md) | Released v1.9.0 | Regex, emoji, protocol, subscription, ping; two phases |
| 2 | [068](../../../tasks/068-node-view-item-extract.md) | Released v1.9.0 | Dimming of non-matching ones lives in the row |
| 3 | [077](../../../tasks/077-subscription-filter-with-prefix.md) | Released v1.9.1 | Subscription with a prefix, a node visible in several |
| 4 | [078](../../../tasks/078-control-outbound-and-display-order-ping.md) | Implemented | Service nodes always visible; ping in display order |
| 5 | [083](../../../tasks/083-per-channel-filter-memory.md) | Released v1.9.1 | Filter memory per channel within a session |
| 6 | [091](../../../tasks/091-config-node-model.md) | — | Source membership by prefix; detour by links |
| 7 | [095](../../../tasks/095-filter-mode-workspace.md) | DONE | Filter mode: tabs, dots, summary chips, without "Custom" |
| 8 | [096](../../../tasks/096-unified-negate-toggle.md) | — | A single `!` per category, binary detour |
| 9 | [103](../../../tasks/103-variant-filter-chips.md) | DONE | Transport/security chips |
| 10 | [195](../../../tasks/195-save-home-filter-to-channel.md) | — | 💾 moving the regex into a Direction |
| 11 | [235](../../../tasks/235-sources-filter.md) | implemented | "Subscribes" → "Sources": subscriptions + folders |
| 12 | [301](../../../tasks/301-regex-filter-case-insensitive.md) | implemented | Case-insensitive regex |
| 13 | [359](../../../tasks/359-user-control-nodes-are-filterable.md) | Implemented, device-verified | A subscription's auto-select node is filtered like an ordinary one |
