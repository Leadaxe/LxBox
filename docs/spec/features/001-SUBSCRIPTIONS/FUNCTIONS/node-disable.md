[English](node-disable.md) · [Русский](node-disable.ru.md)

# Disabling subscription nodes — per-node on/off that survives updates

Any node of a subscription can be switched off: it stays in the list but is left out of the config,
and the mark survives updates and restarts.

| Field | Value |
|------|----------|
| Feature | [001-SUBSCRIPTIONS](../FEATURE.md) |
| Promises | P9, P10 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Lets the user disable an individual node **within a subscription** without touching the source.
A disabled node stays visible in the subscription's node list with a toggle,
but does not get into the config. The mark survives updates and a restart.

## Parameters

| Action | Where | Effect |
|---|---|---|
| Node toggle | Subscription → Nodes | on/off for one node |
| Enable/disable all | Subscription → Nodes | Enable: the mark map is cleared entirely (with core verdicts); Disable: all nodes are marked, old marks are kept |
| Batch disabling based on check results | Subscription → Nodes (check buttons) | marks in the same map |
| Disable/Enable rules | Subscription → Filters | [import-rules.md](import-rules.md) |

TTL constants: `clamp(3 × interval, 24 h, 30 days)`; interval ≤ 0 → 24 h.

## Inputs / Outputs

**Input:** a user action or the outcome of the rules.
**Output:** a mark "node name → when it was last seen in the subscription";
the "M off" counter in the subscription header.

## Rules and invariants

- **The mark key is the node name within the source**; namesakes are numbered `X`, `X-2`,
  `X-3` in parse order (a generated name is checked for being taken).
  Changing the address, ports, keys under the same name does not clear the mark;
  a rename by the provider does (the orphaned mark goes away by TTL).
- The subscription tag prefix does not affect the key.
- Groups and nodes without a name have no marks and are not disabled one by one.
- A disabled node is not emitted; its build warnings are not shown;
  references of other nodes to it as a detour are removed with a warning.
- **TTL cleanup — only on a successful network update:** a node in the fresh
  response → "seen" time = now; absent longer than the threshold → the mark
  is removed. A failed update, rehydration from cache and a file subscription
  do not clean marks.
- Disabling sets "seen" = now.
- Old-format marks (content hash, 64 hex) on the first parse
  move to the name of the node with the same content; those that find no node are deleted.
- Enabling a node by hand clears the core's "rejected" verdict from it.
- Changing the set of marks changes the subscription "composition"
  ([on-update-action.md](on-update-action.md)) and marks the config as changed.
- Deleting the subscription takes the marks with it; a source change keeps them.

## Boundaries

- Folders and single servers have their own toggle —
  [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md).
- Auto-disabling of core-rejected nodes and availability checks —
  [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).
- Who disabled the node (a person or a rule) is not remembered.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [283F](../../../tasks/283F-subscription-node-disable/spec.md) | Implemented (device-pending) | Marks over subscription nodes, filter in the build, TTL cleanup |
| 2 | [332](../../../tasks/332-import-rules-enable-and-bulk-toggle.md) | ✅ device-pending | "Enable/disable all" button, the Enable rule clears a manual mark |
| 3 | [388](../../../tasks/388-subscription-probe-bulk-disable.md) | Done, DEVICE-PENDING | Batch disabling based on check results |
| 4 | [400](../../../tasks/400-identity-tag-mirror.md) | Implemented, DEVICE-PENDING | Mark key = node name instead of a hash, migration of old keys |
| 5 | [538](../../../tasks/538-subscription-dedup-by-identity.md) | Done | Dedup of subscription nodes by signature, not by identity |
| 6 | [478F](../../../tasks/478F-core-rejected-node-auto-disable/spec.md) | — | The core verdict is stored next to the mark and cleared by enabling |
