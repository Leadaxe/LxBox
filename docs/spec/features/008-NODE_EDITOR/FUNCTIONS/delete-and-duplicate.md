[English](delete-and-duplicate.md) · [Русский](delete-and-duplicate.ru.md)

# Node deletion and duplication — removing a custom node without dangling references

Deleting a custom node clears every reference to it and reports what was
affected; duplication is not available.

| Field | Value |
|------|----------|
| Feature | [008-NODE_EDITOR](../FEATURE.md) |
| Promises | P11 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Removes a custom node from the application so that nothing is left
referencing emptiness, and reports who was affected. Node duplication
("make a copy for editing") does not exist in the application.

## Parameters

| What is deleted | Where | Confirmation |
|---|---|---|
| a custom standalone server | long press on the record in the source list → "Delete" | dialog "Delete subscription?" / "Remove "<tag>"?" |
| a folder member | folder screen ([007-NODE_LIST](../../007-NODE_LIST/FEATURE.md)) | see [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md) |
| a folder | long press on the folder → "Delete…" | choice: delete the folder with its servers or keep the servers |

## Inputs / Outputs

**Input:** the user's confirmation.
**Output:** the record is deleted; references to its node are cleared; a
notification counting the affected ones; a config rebuild.

## Rules and invariants

- When a node is deleted, all references to it are cleared:
  - other nodes' detour becomes "None (direct)";
  - the node leaves the members of auto-select groups;
  - the position leaves the chain, the chain itself stays.
- The notification counts the affected ones separately: detour carriers,
  groups and their members, chain positions; an auto-select group member is
  not counted as a detour carrier. **Witness:** units "deletion clears
  references and names the affected ones separately…", "member deletion: the
  notification counts detour, group members and positions separately".
- Renaming, unlike deletion, does not clear references but rewrites them and
  does not notify (P11, [name-is-tag.md](name-is-tag.md)).
- Deletion is irreversible: there is no trash and no undo.
- **There is no duplication.** A copy of a node can only be made by hand: take
  the source from the Source tab (or copy the link,
  [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md)) and add it via the wizard
  or the input field as a new server. The new record gets its own tag; on a
  tag collision the build suffixes `-1`.

## Boundaries

- Deleting a whole subscription, folder nodes and moving between folders —
  [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md) /
  [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md).
- Disabling a node instead of deleting it —
  [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md) (subscription nodes)
  and [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md) (custom ones).
- The reference registry and storage — [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.md).
- The meaning of detour and chains after the target is deleted — [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).
- Node duplication is not planned (owner decision 2026-09-29, audit [591](../../../tasks/591-spec-kit-revision-audit.md)).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [006F](../../../tasks/006F-servers-ui/spec.md) | Implemented | Record deletion with confirmation |
| 2 | [172](../../../tasks/172-heal-dangling-detour.md) | Implemented | Dangling detour after the target is deleted |
| 3 | [234F](../../../tasks/234F-server-folders/spec.md) | IMPLEMENTED, device-verified | Folder deletion with a choice of the servers' fate |
| 4 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released in v2.24.0 | Reference registry: deletion clears references with a notification |
