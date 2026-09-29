[English](node-settings.md) · [Русский](node-settings.ru.md)

# Node settings

| Field | Value |
|------|----------|
| Feature | [008-NODE_EDITOR](../FEATURE.md) |
| Promises | P3 P4 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The screen of a custom node — a standalone server or a folder member. Shows
what kind of node it is, lets the user rename it, choose a detour, switch off
presets and edit the source. Opens by tapping a custom server in the source
list, a folder member, or from the list of nodes disabled by the core
(directly on Diagnostics). The screen title is the current Tag and changes
while typing.

## Parameters

| Tab | Contents |
|---|---|
| Settings | Protocol, Server (read-only); Tag with an emoji palette; Detour server with path preview; Skip presets |
| Source | the source text, editable; a caption about the source kind |
| JSON | the body the core will receive, read-only, highlighted; Copy JSON; Edit JSON |
| Network | only for a Tailscale node — tailnet devices, Exit node choice |
| Diagnostics | node diagnostics and notifications (009); a mark on the tab label when there are warnings |

- **Protocol**: the node's protocol; for AmneziaWG — "AmneziaWG (wireguard)".
- **Server**: `host:port`; for Tailscale — "No address (Tailscale)", for an
  addressless node — "No address".
- **Emoji palette** (14): 🏠 ⚡ 🚀 🔁 ⚙ ⭐ 🌍 🔒 ☁️ 🎭 ⛈️ 🌀 🛡️ ❤️ —
  inserted at the cursor position followed by a space.
- **Detour server**: "None (direct)" or a target; caption "Traffic goes
  directly to this server." or "Phone → … → <tag> → Internet" — the full path
  along the detour chain. Selection, prohibitions and policy —
  [006](../../006-DETOUR_AND_BALANCE/FEATURE.md).
- **Skip presets**: "Presets will not add routing or DNS rules for this
  node." Visible only if the template has a preset with `for_each` for the
  node type; never for a subscription.

## Inputs / Outputs

**Input:** a custom server record or a folder member; the user's choice.
**Output:** the changed record; for Tag/Source — via Save
([source-editing.md](source-editing.md)), message "Saved".

## Rules and invariants

- Detour and Skip presets are written immediately on selection; Tag and
  Source — only with the Save button in the header. There is no confirmation
  when leaving with an unsaved Tag.
- Save re-saves the Source text with the tag from the Tag field: a link —
  into the fragment, JSON — into the `tag` field, INI — into a record field.
- An emoji is not substituted into the tag automatically on edit; it is
  added via the palette. There is no separate "detour server mark" (a ⚙
  toggle): ⚙ is an ordinary palette emoji.
- An auto-select node (a group in a folder) has no Detour block at all.
- Folder member: the detour is personal, the folder policy on top of it; a
  refusal (to itself, a cycle) rolls the choice back with a message.
- The JSON tab shows the body without the tag prefix, detour and build steps.

## Boundaries

- A subscription node opens not this screen but a read-only inspection —
  [subscription-node.md](subscription-node.md).
- The node's "View details" screen in the built config (chain, dependents) —
  007/006.
- The Diagnostics tab — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).
- Renaming, deleting, moving the record to a folder — 007 and
  [delete-and-duplicate.md](delete-and-duplicate.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [017F](../../../tasks/017F-custom-nodes-and-node-settings/spec.md) | Spec | Custom server settings screen: Info, Tag, Detour |
| 2 | [094](../../../tasks/094-emoji-tags-node-settings-tabs.md) | DONE | Tabs, emoji palette; ⚙ toggle removed |
| 3 | [130](../../../tasks/130-awg-detour-exclude-wireguard.md) | SUPERSEDED | The "AmneziaWG (wireguard)" caption remained, the AWG-over-WG prohibition lifted |
| 4 | [237](../../../tasks/237-folder-member-node-settings.md) | Implemented | The same screen for a folder member, personal detour |
| 5 | [252](../../../tasks/252-physical-packet-route-line.md) | Implemented | Preview of the full packet path |
| 6 | [392F](../../../tasks/392F-node-diagnostics/spec.md) | DEVICE-PENDING | Diagnostics tab |
| 7 | [455](../../../tasks/455-node-editor-source-json-tabs.md) | Released v2.24.3 | Source and JSON tabs |
| 8 | [501](../../../tasks/501-diagnostics-notifications-merge.md) | Released in v2.25.0 | Notifications inside Diagnostics |
| 9 | [578](../../../tasks/578-tailscale-preset-template-for-each.md) | Spec, implementation started | Skip presets toggle |
| 10 | [581](../../../tasks/581-tailscale-network-tab.md) | Implemented | Network tab of a Tailscale node |
