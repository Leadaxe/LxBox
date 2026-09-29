[English](server-folders.md) · [Русский](server-folders.ru.md)

# Server folders and the single source list

| Field | Value |
|------|----------|
| Feature | [007-NODE_LIST](../FEATURE.md) |
| Promises | P14 |
| State | ✅ written from code, 2026-09-28 |

## What it does

A **folder** gathers standalone servers into one container with a shared
name, switch, tag prefix and detour policy — instead of a scatter of a dozen
imported files. Folders, subscriptions, standalone servers and chains live
in **one list** on the Servers screen, in the order the person sets.

## Parameters

| Parameter | Where | Values | Default |
|---|---|---|---|
| Folder name | folder header (Rename) | string | set on creation |
| Folder on/off | switch in the Servers list | on/off | on |
| Member on/off | switch on the member | on/off | on |
| Tag prefix, detour policy, Replace with a group | folder → Settings (the same form as for a subscription) | as for a subscription | prefix empty |
| Member's personal detour | tap on a member → node settings | node / none | none |

## Inputs / Outputs

**Input into a folder:** "Paste from clipboard", "Import from files…"
(several files), "Add by URL…" (a one-time snapshot), "Add auto node…" (an
auto-select group among the members of this folder); "Move to folder…" on a
standalone server or a member of another folder.
**Output:** nodes of enabled members with the folder prefix → config build;
the folder record in the single source list.

## Rules and invariants

- **Member ↔ node strictly 1:1.** A fragment containing several nodes is
  split into several members when added. A member stores its original text
  (a link or a whole WG/AWG config), the node is derived from it anew.
- An unnamed node from a file gets the file name without the extension;
  collisions — with a suffix.
- A disabled folder gives no nodes; a disabled member does not get into the
  config. A broken member lives in the folder ("Unreadable entry") and does
  not go into the config.
- Editing a member with unparsable text — rolled back with an error, the
  member is untouched.
- **"Add by URL…" is a snapshot:** one request, the nodes become static
  members, no subscription is created, the address is not stored ("Fetched
  once …").
- **Deleting a folder:** "Delete folder & servers" or "Keep servers" —
  members are moved out as standalone servers; auto-select groups are then
  deleted and named in the dialog; if the folder has only groups, there is
  no "Keep servers".
- **Move out of folder** — the member becomes a standalone server right
  after the folder; an auto-select group has no such item.
- **Standalone server → folder:** its personal prefix and detour policy are
  discarded, the folder's apply. A member's personal detour survives moves
  between folders and moving out.
- Members are ordered by drag-and-drop; with an active filter inside the
  folder dragging is disabled.
- A subscription cannot be put into a folder; there are no nested folders;
  there is no member deduplication.
- The screen closes itself if the folder was deleted or disappeared.
- **The single source list:** subscriptions, servers, folders and chains are
  one sequence; dragging writes the whole permutation as one record; a chain
  can stand between a server and a subscription; deleting a record from the
  middle does not shift the neighbours; an unreadable record keeps its
  place.
- A node's membership in a folder for the main screen filter is by the
  folder's tag prefix ([filters](node-filters.md)).

## Boundaries

- Subscriptions and their update, adding a source — 001.
- Editing a member's node — 008; chains and detour policy — 006.
- Folding a folder into a group — [genus and fold](selector-genus-and-fold.md).
- Chains are not a filter source on the main screen.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [234F](../../../tasks/234F-server-folders/spec.md) | Implemented, device-verified | Folder: members 1:1, shared switch, operations, snapshot by URL |
| 2 | [098](../../../tasks/098-reorder-subscriptions-and-unify-dns.md) | DONE | Dragging source records |
| 3 | [237](../../../tasks/237-folder-member-node-settings.md) | implemented | Folder member: full node settings, personal detour |
| 4 | [239](../../../tasks/239-folder-detour-symmetry.md) | implemented | Detour symmetry of a folder with a subscription |
| 5 | [278](../../../tasks/278-folder-detail-orphan-pop.md) | RELEASE v2.15.10 | An orphaned folder screen closes itself |
| 6 | [322F](../../../tasks/322F-balancer-node/spec.md) | — | "Add auto node…" — an auto-select group in a folder |
| 7 | [509](../../../tasks/509-mixed-source-reorder.md) | Released v2.25.1 | A chain is sorted together with its neighbours |
| 8 | [524](../../../tasks/524-unified-source-entries.md) | Released v2.25.3 | Single list of source records, one writer |
| 9 | [568](../../../tasks/568-source-replace-fold.md) | Implemented, awaiting merge | Replace with a group for a folder |
