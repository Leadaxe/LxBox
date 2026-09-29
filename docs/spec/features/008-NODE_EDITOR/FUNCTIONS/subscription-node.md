[English](subscription-node.md) · [Русский](subscription-node.ru.md)

# Subscription node — read-only inspection of a provider's node

A node from a subscription can be inspected and copied but not edited,
because the next update would replace it; changes go through import rules.

| Field | Value |
|------|----------|
| Feature | [008-NODE_EDITOR](../FEATURE.md) |
| Promises | P14 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Shows a node that came from a subscription in as much detail as a custom
one, but does not allow editing it individually. A subscription node is
someone else's text: the next update will replace it, and any manual edit
would be silently wiped. That is why **there are no overrides on a
subscription node**; subscription nodes can be changed only via import rules
at the subscription level.

## Parameters

The node menu in the subscription's node list: "Copy node info", "Copy
tag", "Inspect node". The inspection screen, read-only:

| Tab | Contents |
|---|---|
| JSON | the body the node will turn into in the config |
| Source | the original subscription fragment; for JSON bodies — Compact (the outbound itself) / Extended (the whole element as the provider sent it) |
| Replacements | what the import rules changed; present only if they changed something |
| Network | for Tailscale — view only, without Save choice |
| Diagnostics | diagnostics and notifications ([009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md)) |

## Inputs / Outputs

**Input:** a node from the last successful subscription parse.
**Output:** viewing and copying; it makes no changes.

## Rules and invariants

- No Save, no Edit JSON, no Source editing; for Tailscale — no Exit node
  choice with a write (P14, manual check).
- A subscription node goes into the config through the model and its gates,
  not verbatim — even if the provider sent sing-box JSON.
- **What survives a subscription update** (all of it at the subscription
  level, not the node's, see [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md)):

| What | Survives? |
|---|---|
| the "node disabled" mark | yes, by node name; lost if the provider renames it |
| import rules (Replace / Disable / Enable) | yes, applied to every new parse |
| tag prefix, subscription detour policy | yes ([006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md)) |
| member selection of a subscription's manual group | yes ([006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md)/[007-NODE_LIST](../../007-NODE_LIST/FEATURE.md)) |
| any individual body edit | does not exist |

- To edit a subscription node as a custom one, it is moved by hand: copy the
  link ([007-NODE_LIST](../../007-NODE_LIST/FEATURE.md)) and add it as a
  custom server — from then on it is an independent record that updates do not
  touch.

## Boundaries

- Import rules and disable marks — [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md).
- Subscription prefix and detour — [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).
- The subscription's node list, copying a link — [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [017F](../../../tasks/017F-custom-nodes-and-node-settings/spec.md) | Spec | Subscription node overrides (deep merge, Reset, pencil icon) — not in the code |
| 2 | [159](../../../tasks/159-backup-allowlist-strict-filter.md) | Done | The `node_overrides` key has no readers, it is cleaned |
| 3 | [302](../../../tasks/302-subscription-import-rewrite-rules.md) | implemented (device-verified) | Subscription node inspection screen; replacement rules instead of overrides |
| 4 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released in v2.24.0 | `node_overrides` is removed by a migration as a dead key |
| 5 | [455](../../../tasks/455-node-editor-source-json-tabs.md) | Released v2.24.3 | Verbatim only for custom nodes; the subscription screen untouched |
| 6 | [581](../../../tasks/581-tailscale-network-tab.md) | Implemented | Network on a subscription node without Save choice |
