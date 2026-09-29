[English](node-detour.md) · [Русский](node-detour.ru.md)

# Node detour — routing a server through another server first

A custom server or folder member can reach the internet through another
node; the path is previewed in packet order, and a broken reference never
turns into a direct connection.

| Field | Value |
|------|----------|
| Feature | [006-DETOUR_AND_BALANCE](../FEATURE.md) |
| Promises | P1 P12 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Lets a custom server or a folder member "go through another server first":
the **Detour** block in the node settings ("Route through another server
first"); the **Detour server** row opens the target picker. Under the row —
a path preview in packet order: `Phone → <hops> → <node> → Internet`, with
the target expanded by its own detour (up to six hops), or "Traffic goes
directly to this server.".

## Parameters

| Knob | Values | Default | Core key |
|---|---|---|---|
| Detour server | None (direct) · member of this folder · detour Direction · free server | None | the node's `detour` |

Sections of the "Detour server" picker, top to bottom:

| Section | Who is in it | When visible |
|---|---|---|
| None (direct) | — | always |
| This folder (N) | members of its own folder, except itself and groups; "Chains inside the folder get the folder detour appended" | only in the folder context |
| Directions | enabled Directions with "Use as detour", caption "Switchable detour direction", the current selection in parentheses | when there is at least one |
| Standalone servers | nodes of enabled standalone servers, except itself and groups; `TYPE · server:port` | otherwise "No standalone servers available" |

## Inputs / Outputs

**Inputs:** the user's choice; the source list; Directions; current group
selections (for the caption in parentheses).
**Outputs:** an address reference in storage (a folder member — the pair
"folder + raw tag", the rest — a root tag); `detour` with the final tag in
the config; a warning if the node dropped out.

## Rules and invariants

- A server cannot go through itself: "A server cannot detour through
  itself". In a folder, a ring of personal detours is rejected immediately:
  "This would create a detour loop inside the folder".
- Subscription nodes and members of other folders are never targets — they
  live under someone else's policy.
- An auto-select node (group) is never a target and has no Detour block
  itself (P12).
- The reference is resolved in the build's second pass, when all final tags
  are known; the target may be lower in the source list.
- Fail-closed (P1): a reference to a missing/disabled node, a deleted
  source, itself or into a ring of references → the node is not emitted,
  those going through it drop out in a cascade. Warning: "Node "…" was
  skipped: its detour … did not resolve — … A node whose detour does not
  resolve is not emitted, so its traffic never goes direct." (for several —
  one line, the first five names and a counter).
- Under a detour assigned by the build, the node body yields: `tls.fragment`
  (and the orphaned `fragment_fallback_delay` if there is no
  `record_fragment`) and WireGuard `listen_port` are removed with a code;
  in an author JSON body `tls.fragment` stays, marked "not applied".
- Detour through WireGuard/AmneziaWG is allowed (the former §130 prohibition
  is lifted).
- "Force direct-out" as a detour is not done: the core breaks every
  connection of such a node; a direct exit is None.

## Boundaries

- Detour of a whole subscription/folder — [source-detour-policy.md](source-detour-policy.md).
- A Direction target and its healing — [detour-directions.md](detour-directions.md).
- Storing references, updating them when nodes are renamed or deleted —
  [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.md).
- Other node settings — [008-NODE_EDITOR](../../008-NODE_EDITOR/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [018F](../../../tasks/018F-detour-server-management/spec.md) | Policy in 026 | Initial model of detour/jump servers |
| 2 | [006](../../../tasks/006-per-node-detour-toggles.md) | Done | Detour registration at the server level |
| 3 | [080](../../../tasks/080-detour-override-picker-prefix-aware.md) | ✅ Implemented | The picker stores the tag with the source prefix |
| 4 | [128](../../../tasks/128-force-direct-out-detour.md) | Won't-fix | `detour: direct-out` is not offered |
| 5 | [130](../../../tasks/130-awg-detour-exclude-wireguard.md) | SUPERSEDED | The AWG→WG prohibition lifted following the core |
| 6 | [237](../../../tasks/237-folder-member-node-settings.md) | implemented | Personal detour of a folder member |
| 7 | [239](../../../tasks/239-folder-detour-symmetry.md) | implemented | Single picker: free servers + own folder |
| 8 | [252](../../../tasks/252-physical-packet-route-line.md) | IMPLEMENTED | Path preview in packet order |
| 9 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released v2.24.0 | A reference is an address `{folder_id?, tag}`, fail-closed |
| 10 | [574](../../../tasks/574-tls-fragment-yields-to-detour.md) | Released v2.25.7 | `tls.fragment` yields to a build detour |
