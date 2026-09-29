[English](selector-genus-and-fold.md) · [Русский](selector-genus-and-fold.ru.md)

# Group genus and folding a source into a group

| Field | Value |
|------|----------|
| Feature | [007-NODE_LIST](../FEATURE.md) |
| Promises | P12, P13 |
| State | ✅ written from code, 2026-09-28 |

## What it does

A group node inside a subscription or folder comes in two **genera**:
`selector` — the member is chosen by a person (the `default` field),
`urltest` — the member is chosen by the core by ping. The genus is preserved
from parsing to the core config. In addition, any subscription or folder can
be **folded** into one group: instead of a scatter of nodes, a single name
appears in Directions and in the Direction list.

## Parameters

| Parameter | Where | Values | Default |
|---|---|---|---|
| Group genus | the folder's group editor; from the source for a subscription | Manual (`selector`) · Auto (`urltest`) | from the source; without a genus — `urltest` |
| Selected member (`default`) | group editor, node screen (circle next to a member), main screen | a group member | provider's / the first |
| Replace with a group | folder or subscription Settings | off · Manual · Auto · Both | off |
| Fold name (`tag`) | same place | string | source name |
| Auto parameters | same place, the Direction's auto form | as for a Direction | — |

## Inputs / Outputs

**Input:** a group from the source (a sing-box `selector`/`urltest` carries
its genus as is; an Xray balancer and `autogroup://` are always `urltest`),
the `replace` setting of the source record, the user's member selection.

**Output into the core config:**

| What | Outbound |
|---|---|
| manual-genus group | `selector` with `outbounds` (final tags) and `default` |
| auto-select group | `urltest` with measurement parameters |
| `manual` fold | `selector` `tag` of all source nodes, `interrupt_exist_connections: true` |
| `auto` fold | `urltest` `tag` with auto parameters, without provider groups |
| `both` fold | `urltest` `<tag>-auto`, then `selector` `tag` with it as the first option and `default` |

## Rules and invariants

- On the main screen an auto-select group shows a mode label (`🎯 [N]`
  fastest of N, `🔀 [N/M]` a pool of M out of N) and "→ selected"; a
  manual-genus group shows only its name in the row — neither the genus nor
  the selected member (the "Manual" genus is visible in the folder filter
  chips and on the node screen).
- A `default` pointing to a dropped member is removed — the core takes the
  first; one line `group_member_dropped` in the build report.
- The member selection of a **folder** group is stored in the group itself;
  of a **subscription** group — next to the subscription record, on top of
  the provider's `default` (it survives a subscription update and a restart;
  it does not go into the backup).
- A selection with a live tunnel is applied in the core immediately, the
  config is not marked stale, but the next VPN start rebuilds it. Without
  the tunnel a selection is an ordinary edit: the config is marked changed.
- A group of either genus does not go into the Direction's auto-select twin.
- **A folded source** gives its nodes to the fold, not to the Direction
  pool: the Direction sees one candidate `tag` (for `both` — only the
  selector). The nodes stay in the config as detour and chain targets.
- The fold name is a root one: a rule target, `route.final`, Direction
  `include`, detour. The fold's selector gets into the main screen's
  Direction list.
- Zero nodes or all disabled — no groups, a `replace_group_empty` line; a
  rule pointing to the fold goes to `route.final` or is removed.
- A name taken by a Direction, by a node of another source or by another
  fold — `replace_tag_conflict`, the source is not folded; the editor warns
  about the taken name but allows saving.
- The old `fold`/`fold_tag` forms are neither read nor migrated.

## Boundaries

- Parsing groups from formats — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md);
  the auto group (auto-select node) and Directions —
  [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).
- The storage and backup form of `replace`, `group_type`, `default` —
  [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [322F](../../../tasks/322F-balancer-node/spec.md) | — | Auto-select node inside a subscription/folder, mode label |
| 2 | [208](../../../tasks/208-urltest-balancer-round-robin.md) | implemented | Round-robin, `🔀 [N/M]` label, View pool |
| 3 | [565F](../../../tasks/565F-selector-group-genus/spec.md) | Phase A merged, B — task 568 | The `selector` genus is honoured: `default`, Manual UI |
| 4 | [568](../../../tasks/568-source-replace-fold.md) | Implemented, awaiting merge | Source fold: `replace {mode, tag, auto}` |
| 5 | [570](../../../tasks/570-close-open-tails.md) | — | A subscription group member selection is stored; selection from the node screen |
