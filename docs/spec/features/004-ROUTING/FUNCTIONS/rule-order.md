[English](rule-order.md) · [Русский](rule-order.ru.md)

# Rule order and enabling

| Field | Value |
|------|----------|
| Feature | [004-ROUTING](../FEATURE.md) |
| Promises | P1 P2 P3 P4 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Keeps one rule list on the **Rules** tab, where own rules and presets
are intermixed. The user drags rules by the handle, enables and
disables them with a switch, deletes them with a long tap (with confirmation) or from the
editor. The core checks rules top to bottom, the first match wins
— so the order in the list is the meaning of routing.

## Parameters

The order is set by a sparse number axis shared by all rules:

| Zone | Numbers | Who |
|---|---|---|
| Head | 0 | Traffic Processing (does not move) |
| Specific presets | 945–990 | Tailscale, Private IPs, Block Ads, FCM, BitTorrent, VoWiFi |
| Own rules | 1000–1100 | inline / `.srs` / JSON |
| Broad catch-alls | 1110–1150 | Russia-only, Ru internet segment, FakeIP, Unknown traffic |

A number is a starting position: a preset from the catalog lands on the template number,
a new own rule — at the end of the occupied part of the 1000–1100 zone.

## Inputs / Outputs

**Inputs:** user gestures; numbers from the template; the list from storage.
**Outputs:** a list sorted by number in storage; in the config —
rules in the same order.

## Rules and invariants

- The list is always sorted by number; with equal numbers the relative order
  is preserved.
- **Drag "land after the target":** the rule gets the target's number + 1; if it is
  taken, only the contiguous occupied block up to the first gap is shifted by +1.
  Template anchors beyond the gap do not move; neighbours are not
  renumbered on deletion.
- A rule dropped at the very beginning lands below the head, not above it.
- The own-rule zone is exhausted — new ones get its upper bound, and the order
  is decided by the position in the list.
- A list without numbers (old storage) is marked up on first load:
  presets — with template numbers, the rest — consecutively from 1000 in the previous order.
- The head always stands at number 0: shifted by an import, it returns at
  load, build and after the import; lost — it is seeded.
- A disabled rule stays in place and contributes nothing to the config; its
  DNS aspect goes out too.
- Deleting a rule wipes the files of its external sets.
- Saving a rule in the editor does not change its number (no false "Save
  changes?" and no jump up).
- Changes on the screen mark the config for rebuild; they are written to disk on
  leaving the screen or minimizing the app.

## Boundaries

- The automatic "reject above direct" sorting no longer exists — only the axis.
- DNS rule order — [005-DNS](../../005-DNS/FEATURE.md) (routing
  mirrors go in the order of this list).
- Moving via the Debug API — [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [030F](../../../tasks/030F-custom-routing-rules/spec.md) | Active (v1.4.0) | One rule list, drag, deletion, insertion by the reject/direct heuristic (replaced) |
| 2 | [062](../../../tasks/062-custom-rules-unified-order.md) | active (v1.7.4) | A single order of presets and own rules in the config |
| 3 | [264](../../../tasks/264-traffic-processing-preset.md) | device-verified | The pinned head of the list |
| 4 | [369](../../../tasks/369-pinned-preset-order-in-rules-list.md) | implemented, device-pending | A preset from the catalog does not push out the head |
| 5 | [370](../../../tasks/370-rule-order-num-axis.md) | implemented in the task | The sparse number axis, lazy shift |
| 6 | [381](../../../tasks/381-rule-editor-drops-order-num.md) | DONE, device-pending | The editor keeps the rule number |
| 7 | [398](../../../tasks/398-rule-transfer-presets-and-dedup.md) | — | Collapsing preset copies, the last one stays |
