[English](file-subscription.md) · [Русский](file-subscription.ru.md)

# File subscription and source change — nodes from a file, safe URL and mode switching

A file with more than one node becomes a subscription, and any subscription can change its URL or
move between online and file modes without losing its nodes.

| Field | Value |
|------|----------|
| Feature | [001-SUBSCRIPTIONS](../FEATURE.md) |
| Promises | P2, P4, P8 |
| State | ✅ written from code, 2026-09-28 |

## What it does

1. **File subscription** — a file with a list of nodes lives as an ordinary subscription:
   toggle, settings, node marks, rules. The source is a snapshot of the
   file contents taken at import; the file itself is no longer read.
2. **Source change** ("Edit source…") — an existing subscription can have its
   URL replaced (the provider's domain changed, a typo) or switch between
   online ↔ file modes without losing its name, enabled state, settings and marks.

## Parameters

| Parameter | Values |
|---|---|
| Mode in the Edit source dialog | Online URL (`http(s)://` field) / Local file (Choose… button) |
| Interval after the change | → file: `-1`; → online: the previous one if it was > 0, otherwise 24 h |

The dialog is entered via the "Edit source…" item in the entry menu and a tap on the
URL / "Source: local file" row in the subscription's Settings tab.

## Inputs / Outputs

**Input:** the file text or a new URL.
**Output:** a subscription with the new source, fresh nodes and metadata,
status OK; the snapshot of the previous source is deleted.

## Rules and invariants

- Creation at import — only with > 1 node in the file; on a source change
  ≥ 1 node is enough.
- **Transactionality:** the new source is first loaded and parsed;
  the address, nodes and cache are swapped only if there are ≥ 1 nodes. Otherwise nothing
  changes, message "Couldn't load new source — keeping current".
- Changing the URL to the same one does not delete the cache; every change to a file creates a new
  internal key `file:<uuid>`.
- On switching to a new URL its response is written to the cache, the old
  address's cache is deleted (unless another entry uses it). A URL change
  without a request (Debug API) moves the cache to the new address: the
  previous nodes live until the first successful update by the new URL.
- On a URL change the subscription's Custom identity is kept — the new address
  is requested with it.
- Marks of disabled nodes survive the source change (same entry).
- A file subscription is created with interval `-1`. "Update" / "Apply"
  parse its snapshot again (the file is not re-read, no network): import
  rules changed on the Filters tab take effect; "updated" time does not move.
  No snapshot → nothing changes. The Source tab shows the snapshot instead of
  a live request.
- After a restart the file subscription's nodes are restored from its snapshot.
- TTL cleanup of marks is not performed for a file subscription — there is no external
  signal that a node is gone.
- The list shows a "file" badge instead of the interval; "Share URL…" is hidden;
  in the log the source appears as `file:<local>`.
- The dialog requires choosing a file in file mode and a valid `http(s)://` in online
  mode, otherwise a hint without a request.

## Boundaries

- There is no persistent access to the file on disk: a file subscription can be updated
  only by choosing the file again.
- Parsing the file contents — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [129F](../../../tasks/129F-file-subscription/spec.md) | Spec (implemented) | Snapshot file subscription, editable source, transactional change, intervals `-1`/`0` |
| 2 | [101](../../../tasks/101-rehydrate-bootstrap-race.md) | DONE | The "keep the previous on failure" principle, applied to source change |
| 3 | [283F](../../../tasks/283F-subscription-node-disable/spec.md) | Implemented (device-pending) | TTL cleanup of marks is disabled for a file subscription |
| 4 | [289](../../../tasks/289-per-subscription-fetch-identity.md) | — | A URL change keeps the Custom identity |
| 5 | [603](../../../tasks/603-subscription-and-own-server-bugs.md) | Implemented | Update re-parses the snapshot with rules; Source tab without HTTP; cache kept on URL change |
