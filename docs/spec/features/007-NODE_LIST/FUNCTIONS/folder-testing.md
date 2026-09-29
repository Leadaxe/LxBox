[English](folder-testing.md) · [Русский](folder-testing.ru.md)

# Folder test

| Field | Value |
|------|----------|
| Feature | [007-NODE_LIST](../FEATURE.md) |
| Promises | P15, P16 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Checks a batch of folder servers **without starting the VPN**: brings up a
temporary core session with only the folder's nodes, measures each one and
shows the latency coloured by thresholds. Based on the result, slow ones can
be disabled in one go, unreachable ones disabled or deleted, and the list
ordered by ping. The same test, without deletion and sorting, exists on the
subscription screen.

## Parameters

| Parameter | Where | Values | Default |
|---|---|---|---|
| Ping URL & timeout… | long-press on the test button; "Shared with the home screen ping" | URL (empty = core default), ms | global; timeout 3000 ms |
| Ping color thresholds… | same place | "Green up to", "Yellow up to", "Orange up to", ms; above — red | 250 / 500 / 700 |
| Disable slower than… | the "Test actions" menu | ms | the orange threshold |

Thresholds are stored as application settings and go into the backup; they
do not go into the core config.

## Inputs / Outputs

**Input:** folder members — all of them, including disabled ones; for a
subscription — its nodes.
**Output:** a badge on each member and a summary above the list
("Testing… N done", "N ok", "N off"); bulk folder edits (disabling,
deletion, order) are ordinary source edits with a config rebuild.

| Badge | Meaning |
|---|---|
| `123 ms` | responded; colour by thresholds (inclusive) |
| `err` | the measurement failed; tap — the error text |
| `broken` | the member cannot be parsed — verdict before the core |
| `invalid` | the node did not build into a core record |
| `auto` | auto-select group — not tested |

## Rules and invariants

- **VPN up — the test does not start.** The "VPN is running" dialog with
  "Stop VPN" (stop, then run) and "Cancel". If the VPN started between the
  check and the session start — the same dialog. One core session runs at a
  time.
- The test session has no tun and no routes: only the folder's nodes with
  bare tags (without the prefix), their own detour chains and local DNS. The
  folder's detour policy is not applied — the node is measured, not the
  Direction's route.
- Up to 6 nodes are measured in parallel. Memory-heavy nodes are split into
  sequential runs: no more than 1 naive and 4 WireGuard/AWG records per run
  (a node's chain is indivisible).
- Auto-select groups are not tested; a folder of groups only — no test.
- Results are bound to the node (by its tag), not to the row: reordering and
  deleting neighbours do not shift them; a rename — a new node.
- Results live only on the screen and are not saved.
- The test is interrupted when the application is minimized and when the
  tunnel stops (the main screen's mass ping survives minimizing).
- **Test actions** (the menu is always in place, the items are grey until
  the first result):
  - "Disable slower than…" — disable those that responded slower than the
    threshold;
  - "Disable unreachable" — disable `err`/`broken`/`invalid`;
  - "Delete unreachable" (folder only) — delete them, with confirmation;
  - "Sort by ping" (folder only) — responders ascending, then untested and
    groups, then errors; equal ones — in their previous order.
- On the subscription screen — a shared switch for all nodes in one column
  with the row switches.
- The filter button in the test bar: regex + protocols; with an active filter
  dragging members is disabled.

## Boundaries

- Ping through the running core on the main screen, group URLTest — 009.
- Disabling subscription nodes as a mark — [001](../../001-SUBSCRIPTIONS/FUNCTIONS/node-disable.md).
- The OS's ability to keep a second core session next to the VPN — not
  supported.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [236F](../../../tasks/236F-folder-server-testing/spec.md) | Implemented, device-verified | Test without VPN, thresholds, bulk actions; gate with VPN |
| 2 | [296](../../../tasks/296-folder-probe-controller.md) | foundation implemented | Shared test facade, the gate extracted for folder and subscription |
| 3 | [326](../../../tasks/326-folder-probe-results-keyed-by-index.md) | Implemented (device-pending) | Results bound to the node, not to the position |
| 4 | [336](../../../tasks/336-probe-skips-group-nodes.md) | Implemented | Groups are not tested, the `auto` badge |
| 5 | [388](../../../tasks/388-subscription-probe-bulk-disable.md) | Done, device-pending | Bulk disabling by test on a subscription |
| 6 | [389](../../../tasks/389-test-actions-menu-always-visible.md) | Done, device-pending | The Test actions menu is always visible |
| 7 | [400](../../../tasks/400-identity-tag-mirror.md) | — | Node identity = tag (the result key) |
| 8 | [496](../../../tasks/496-probe-bar-bulk-switch.md) | Released v2.25.0 | Shared switch in the subscription test bar |
| 9 | [518](../../../tasks/518-naive-probe-batch-oom.md) | — | naive — one per run of the test core |
| 10 | [523](../../../tasks/523-wireguard-probe-batch-memory.md) | — | WireGuard — no more than 4 per run |
