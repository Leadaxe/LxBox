[English](name-is-tag.md) · [Русский](name-is-tag.ru.md)

# The name is the tag — one name for a custom server, kept in sync everywhere

A custom server has a single name, its node tag: it gets a default and an
emoji on creation, and a rename rewrites every reference to the node.

| Field | Value |
|------|----------|
| Feature | [008-NODE_EDITOR](../FEATURE.md) |
| Promises | P2 P3 P4 P11 |
| State | ✅ written from code, 2026-09-28 |

## What it does

A custom server has one name — the tag of its node. It is visible as the
title in the source list, as the row on the main screen, in the detour
picker and in rules. The feature guarantees that this name is set in one
place, survives a restart and does not break references to the node when it
changes.

## Parameters

| Where the tag comes from | Rule |
|---|---|
| wizard form | the Tag field; empty → `local-socks5-out` / `local-http-out` / `tailscale` |
| link | the `#…` fragment; parsing — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md) |
| sing-box JSON | the `tag` field |
| WireGuard `.conf` from a file | the file name without the extension, if the INI has no name of its own ([002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md)) |
| the node screen's Tag field | on Save it is written into the source according to its kind |

Auto emoji on record creation, if the tag has no emoji:

| Node | Emoji |
|---|---|
| tag `WARP` / `WARP+` | 🔥☁️ |
| server `127.0.0.1`, `localhost`, `::1` | 🔁 |
| WireGuard / AmneziaWG | 🏠 |
| Tailscale | 🕸️ |
| MASQUE | 🎭 |
| Hysteria2, TUIC | 🚀 |
| others | ⚡ |

An emoji is a Unicode pictograph or a pair of regional indicators (a flag).

## Inputs / Outputs

**Input:** a tag from a form, a link, JSON, a file name or the Tag field.
**Output:** the node tag in the source; the record title; on renaming —
rewritten references to the node.

## Rules and invariants

- The record name of a custom server is neither written nor shown; an old
  name from version v2.11.0 is ignored and erased on the first re-save (P3).
  For subscriptions and folders the record name works as before.
- The emoji is set only when the record is created (wizard, paste, file) and
  as a prefix followed by a space: `⚡ my-node`. A tag that already has an
  emoji anywhere is not touched; a repeat does not duplicate (P4).
- The tag in the wizard is not checked for uniqueness. On a collision the
  build gives the next node a suffix `-1`, `-2`… — the final tag is visible
  in the node list, the wizard message shows the entered one.
- Renaming by editing the source rewrites all references to the node: detour
  of other nodes, group members, chain positions. Nodes before and after are
  matched by position in the body, not by tag (P11).
- The tag prefix of a folder or subscription is added to the tag at build
  time; it is not in the source or in the Tag field.
- An INI node's tag is stored as a record field: the INI itself stays byte
  for byte.

## Boundaries

- How the tag is derived from a link or config — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md).
- Prefixes, the tag policy of a folder and subscription — [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md) / [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md).
- The "node disabled" mark of a subscription by node name — [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FUNCTIONS/node-disable.md).
- Record storage — [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [017F](../../../tasks/017F-custom-nodes-and-node-settings/spec.md) | Spec | Editable Tag; ⚙ mark in the tag (removed later) |
| 2 | [074F](../../../tasks/074F-add-server-wizard/spec.md) | Released in v1.9.0 | The form tag is stored in the JSON body, not in the link fragment |
| 3 | [094](../../../tasks/094-emoji-tags-node-settings-tabs.md) | DONE | Auto emoji by node kind and the palette |
| 4 | [243](../../../tasks/243-wg-import-filename-tag.md) | Implemented, partially replaced by §456 | The `.conf` file name is the tag; record title = tag; Display name removed |
| 5 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released in v2.24.0 | Reference registry: renaming and deleting rewrite references |
| 6 | [456](../../../tasks/456-wg-ini-as-source-tag-in-record.md) | Released v2.24.3 | An INI node's tag — as a record field |
