[English](storage-contract.md) · [Русский](storage-contract.ru.md)

# Storage contract

| Field | Value |
|-------|-------|
| Feature | [017-BACKUP_AND_STORAGE](../FEATURE.md) |
| Promises | P17 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Defines what the app stores and in which form. The user's settings live in
one document whose records are the same as in LX Backup 1.0: one form for
disk, full backup, transfer and Debug API. Node links are stored as a node
address, not as a final-tag string, and follow the node on rename and move.

## Parameters

**Data sets** (what is stored where):

| Set | What it holds | In the full backup | In a set slot |
|-----|---------------|--------------------|---------------|
| Settings document | everything the user configured; VPN toggles — as a mirror | yes (by category) | yes |
| Previous copy of the document | the last whole state, for recovery | no | no |
| Old-form original | document bytes before the 2.23.2 migration | only Debug API `from=v0_bak` | no |
| Subscription body cache | downloaded subscription nodes | no (re-fetched) | yes |
| Rule-set cache | downloaded rule-sets | no | yes |
| Built config | the build result | no | no |
| Core cache database, logs, crash reports | service data | no | no |
| Tailscale node state | node identities | no | per slot ([018](../../018-WORKSPACES/FEATURE.md)) |
| Device properties outside the document | theme; the OS working copy of VPN toggles | no | no |

**Settings document, top level:** `storage_version: 1` (form marker),
`vars`, `sources[]`, `rules[]`, `dns{servers[], rules[]}`, `directions[]`,
`directions_migrated`, `route_final`, `ping_options`, `warp_account`,
`masque_account`, `tun_apps`, `vpn_mode`, idle-suspend thresholds, WG build
budget, passive check, node sorting and manual order, service marks, the
VPN toggles mirror. The closed list is also the import allowlist; the VPN
toggles mirror is not in the allowlist and arrives in the backup as a
separate block.

**`sources[]` records** (the record order is normative):

| `kind` | Essence |
|--------|---------|
| `subscription` | `id`, `name`, `enabled`, `url`, `tag_policy{prefix}`, `identity`, `update{interval_hours}`, `disabled{node: unix seconds}` + LxBox fields |
| `server` | `id`, `tag`, `enabled`, `origin{kind: uri\|wg_ini\|json, raw}`, `detour` (node address) + LxBox fields; the former `sections` field is read and removed with a note |
| `folder` | `id`, `name`, `enabled`, `tag_policy`, `nodes[]` (`server` / `unsupported` with `reason` / `auto`) |
| `chain` | `tag`, `enabled`, `label`, `body{type: chain, …}`, `hops[]` (node addresses) |

Rules — `rules[]` with `kind: inline|srs|preset`, matchers in `body` with
sing-box keys; DNS servers — `user|preset|template`.

**Node address (NodeLink):** `{folder_id?, tag}` — a "container + raw tag"
pair for a folder or subscription node, a root `{tag}` for a single server,
a Direction, `direct-out`, a chain.

## Inputs / Outputs

**Inputs:** screen edits; renaming, moving and deleting nodes.

**Outputs:** the document on disk; rewritten links; a notification about
cleared links naming the affected ones (detour, group members, chain
positions).

## Rules and invariants

- **A link is never re-pointed to another node.** Which addresses changed
  is decided by the nodes themselves, not by similar tags (P17).
- Renaming a node (editing its body) and moving it between folders rewrite
  all link carriers: source detour, folder member detour, chain positions,
  auto-select group membership.
- Deleting a node or a source clears links: the detour is removed, the
  position leaves the chain, the affected ones are named separately.
- Changing a container's prefix or name does not change the address — links
  are not touched; the final tag is computed by the build.
- LxBox fields live next to contract fields in the same record; an unknown
  key at the input is dropped by the allowlist, garbage already on disk is
  harmless.
- A document without the form marker is the 2.23.2 form
  ([migration](storage-migration.md)); a new installation writes the marker
  at once.

## Boundaries

- The meaning of fields is in the owning features
  ([006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md) for
  detour and chains, [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md),
  [004-ROUTING](../../004-ROUTING/FEATURE.md), [005-DNS](../../005-DNS/FEATURE.md)).
- The form norms are the contract with the launcher (`docs/contract/`), 1.0.x.
- Storage is not encrypted.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [159](../../../tasks/159-backup-allowlist-strict-filter.md) | Done | The closed list of top-level keys is the source of truth |
| 2 | [189](../../../tasks/189-native-prefs-mirror-in-json.md) | ✅ Implemented | VPN toggles: the document is the truth, the OS copy is a mirror |
| 3 | [575](../../../tasks/575-remove-node-sections.md) | Implemented (phases 1–3) | Node sections removed: the record field is removed with a note |
| 4 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released v2.24.0 | Storage in the contract 1.0 form; node address `{folder_id?, tag}`; link registry |
| 5 | [441](../../../tasks/441-template-preset-vars-in-record.md) | Released v2.24.0 | Var values of template DNS servers and presets — in the record |
| 6 | [524](../../../tasks/524-unified-source-entries.md) | Released v2.25.3 | A single list of source records, chains in it |
