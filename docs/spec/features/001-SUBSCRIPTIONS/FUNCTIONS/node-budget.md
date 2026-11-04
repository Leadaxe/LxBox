[English](node-budget.md) · [Русский](node-budget.ru.md)

# Node budget — one app-wide node limit shared between subscriptions

Manual servers, enabled folder members and the nodes of enabled subscriptions together stay
within one number. Subscriptions share what manual nodes leave, and a subscription above its
share keeps only its first nodes.

| Field | Value |
|------|----------|
| Feature | [001-SUBSCRIPTIONS](../FEATURE.md) |
| Promises | — |
| State | ✅ written from code, 2026-11-04 |

## What it does

Keeps the app out of the size where it freezes and the system kills it (an aggregator
subscription with 7 000+ nodes). The cut happens when the subscription body is parsed:
storage, the config, the node list, auto-select and mass ping never see the extra nodes.

## Parameters

| Setting | Where | Default | Range |
|---|---|---|---|
| Node budget | App settings → General | 1000 | from 1, no upper limit |

An empty field or Reset returns the default. A value below 1 becomes 1.

## What counts

| Counts | Does not count |
|---|---|
| Nodes of enabled manual servers | Tailscale nodes |
| Enabled members of enabled folders | Group (auto) nodes of subscriptions, folders and Directions |
| Nodes of enabled subscriptions | Chains; disabled subscriptions, servers and members |

## Rules and invariants

1. **Manual nodes are never cut.** They are taken from the budget first. When they reach the
   budget, every subscription gets 0 nodes and its card says «Budget used by manual servers».
2. **The rest is shared equally with redistribution.** Each enabled subscription takes
   `min(its size, the share)`; what a small subscription does not need goes to the others,
   until the budget or the subscriptions run out. The remainder of the division goes to the
   subscriptions in list order. The size is the node count after parsing and import rules,
   before the cut.
3. **What is cut:** the first N nodes in the subscription's order, after import rules, without
   sorting or ping. Group nodes of the subscription are kept and do not count.
4. **Referenced nodes stay above the queue** inside the subscription's share: the node a rule
   sends traffic to, a chain hop, the selected member of a subscription's manual group, the
   first node matching a Direction's default filter. They are taken first, the share is filled
   in order after them. When they alone exceed the share, all of them stay and the share is
   exceeded.
5. **Re-cut without network.** Enabling or disabling a subscription, adding or removing a
   manual server or a folder member, and changing the budget recompute the shares; a
   subscription whose result changes is re-parsed from its body cache.
6. **No migration.** A subscription above its share is cut on its next update or re-cut, not
   when the app is updated.
7. **The card shows the cut:** «N of M nodes» instead of «N nodes» when `N < M`, plus a ⚠ icon
   whose tooltip points to the setting. With `N == M` the card is as before.

## Storage

The budget is the top-level key `node_budget` (absent = 1000); it travels in the backup with
the app settings. A subscription record keeps `total_node_count` — the size before the cut
(machine runtime, not in the backup). See [STORAGE.md](../../../../STORAGE.md).

## Boundaries

- No per-subscription limit: the launcher's `max_nodes` of a subscription is still ignored.
- No smart selection (by ping, country), no limit on manual nodes, Tailscale or chains.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [714](../../../tasks/714-node-budget-subscription-cut.md) | In progress | App-wide budget, shares between subscriptions, cut in the parse worker |
