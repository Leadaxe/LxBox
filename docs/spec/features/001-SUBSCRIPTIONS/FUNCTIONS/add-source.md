[English](add-source.md) · [Русский](add-source.ru.md)

# Adding a source — subscription URLs, links, QR codes and files

A URL, pasted text, a QR code or a file becomes a subscription, a single server, a folder or a file
subscription in the list of sources.

| Field | Value |
|------|----------|
| Feature | [001-SUBSCRIPTIONS](../FEATURE.md) |
| Promises | — (relies on P1 on the first request) |
| State | ✅ written from code, 2026-09-28 |

## What it does

Accepts a node source from the user and creates an entry for it in the shared
list of sources: a subscription by URL, a single server, a folder or a file
subscription. After a successful add the config is rebuilt, and the new entry is
scrolled into view and highlighted.

## Parameters

No settings of its own. Entry points on the sources screen:

| Entry | What happens |
|---|---|
| Input field + "+" | the text is classified and added immediately |
| "+" with an empty field / "Paste from clipboard" | clipboard → analysis → confirmation dialog |
| "Scan QR code" (if there is a camera) | the string from the QR → the same analysis and confirmation |
| "Import from file…" | one file → see below; several → a new folder |
| "Get Public Test Servers" | a list from the community manifest; choosing one puts the source into the input field |

## Inputs / Outputs

**Input:** a string or file contents.
**Classification** (check order):

1. `http://` / `https://` → **subscription by URL**. The entry is created with an empty
   name and requested immediately; the name will be filled from `profile-title`, otherwise
   the list shows the host.
2. A WireGuard config, an Amnezia container, a link to one node, JSON — a **single
   server** (parsing — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md)).
3. Otherwise — "not recognized".

**Importing one file:** if it holds > 1 node, a
[file subscription](file-subscription.md) is created, named from `profile-title` or the file
name without extension; ≤ 1 node — a single server, the file name becomes a
hint for the node name. **Several files** → a new folder, one server from
each file; empty files are listed in the message.

**Output:** a new entry; a snackbar "Config regenerated: N nodes" (or "…& applied").

## Rules and invariants

- Clipboard and QR are untrusted input: before writing, a dialog shows the
  recognized type (Subscription URL + host, WireGuard config + endpoint,
  link, JSON) and the number of entries that will not become nodes, with reasons.
- An unrecognized clipboard → an "unknown format" dialog with a text preview.
- Empty clipboard → "Clipboard is empty"; empty file → "File is empty".
- Leaving the screen with a non-empty input field asks "Discard input?".
- A parse error of a single input opens a sheet with the rejection reason.
- A subscription by URL is added **even if the first request failed**: the entry
  stays with an error status and is retried in the usual order.
- The same URL can be added twice — there is no entry dedup.

## Boundaries

- Which formats are recognized and how — 002-NODE_IMPORT.
- Folders and single servers as entities — [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md),
  [008-NODE_EDITOR](../../008-NODE_EDITOR/FEATURE.md).
- File picking and the camera depend on OS capabilities; without a file
  manager a hint is shown.
- The "Get Free VPN" preset with automatic rule setup (from `§010F`) no longer exists in the app;
  public lists only put a URL into the field.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [006F](../../../tasks/006F-servers-ui/spec.md) | Implemented | Subscriptions screen: adding a URL/link, paste with type auto-detection |
| 2 | [010F](../../../tasks/010F-quick-start-and-offline/spec.md) | Implemented | Quick Start "Get Free VPN" (no longer in the code) |
| 3 | [149](../../../tasks/149-servers-import-from-file.md) | Implemented, device-pending | "Import from file…" in the sources menu |
| 4 | [129F](../../../tasks/129F-file-subscription/spec.md) | Spec (implemented) | File > 1 node → file subscription, ≤ 1 → single server |
| 5 | [375](../../../tasks/375-qr-scanner-import.md) | PENDING (device) | Import from QR along the same path as the clipboard |
| 6 | [500](../../../tasks/500-direct-link-reject-reason.md) | Released v2.25.0 | Rejection reason of a single input in a sheet |
| 7 | [504](../../../tasks/504-new-entry-highlight.md) | Released v2.25.0 | Scrolling to and highlighting the new entry |
| 8 | [561](../../../tasks/561-dropped-only-in-source-summary.md) | Done | Rejections are shown in the paste preview and the source summary |
