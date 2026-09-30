[English](server-list-test.md) · [Русский](server-list-test.ru.md)

# List server test — checking a subscription or folder without connecting the VPN

All nodes of a subscription or folder can be tested with the VPN off, and
the results drive bulk actions: disable slow nodes, disable or delete dead
ones.

| Field | Value |
|------|----------|
| Feature | [009-NODE_HEALTH](../FEATURE.md) |
| Promises | P3, P9, P10, P11, P12 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Tests all nodes of a subscription or folder without connecting the VPN:
"added a batch of servers → tested them right away → threw out the junk". The
button in the bar above the list starts and stops the test; each node gets a
badge, a summary appears on top; the "Test actions" menu applies decisions to
the results.

## Parameters

| Parameter | Values | Default |
|-----------|--------|---------|
| URL / timeout | global ping settings; a folder's own, if set | the template's ping URL and timeout 3000 ms if not set globally |
| Color thresholds | Green up to / Yellow up to / Orange up to, ms | 250 / 500 / 700 |
| Parallelism | up to 6 measurements per session | — |
| naive nodes per session | 1 | — |
| WireGuard/AmneziaWG endpoints per session | 4 | — |

Test settings (address/timeout and thresholds) are opened by a long tap on
the button in a folder; a subscription has no settings of its own. A
non-positive or empty threshold is saved as the default.

## Inputs / Outputs

**Inputs:** the list's nodes, including disabled ones (for a folder — also
unreadable members); VPN state; replies of the temporary core session.

**Outputs:**

| Badge | Meaning |
|-------|---------|
| `…` | not tested yet |
| `N ms` | alive; color by thresholds (green / yellow / orange / red) |
| `err` | the core returned an error or timeout; tap — error text |
| `broken` | the entry cannot be read — nothing to test |
| `invalid` | the node does not build into a config or was removed by the registry check |
| `auto` | group node: not tested, neutral color |

Summary: `Test servers` → `Testing… N done` → `N ok · N err · N broken`.

| Action | Folder | Subscription |
|--------|--------|--------------|
| Disable slower than… (threshold, orange by default) | ✓ | ✓ |
| Disable unreachable (`err`, `broken`, `invalid`) | ✓ | ✓ |
| Delete unreachable | ✓ | — |
| Sort by ping (alive ascending, then untested, errors last) | ✓ | — |

## Rules and invariants

- **Only with the VPN off.** The test needs its own core session, which
  cannot run alongside the tunnel. With the VPN live — the "VPN is running"
  window with a Stop VPN button; after the stop the test starts by itself. If
  the VPN came up between the check and the session start — the same window,
  not an error.
- **The bare node is tested.** The Directions' detour policy is not applied;
  the node's own chain from its entry is kept.
- **Batches.** Nodes without naive and WireGuard go in one session;
  memory-heavy ones are packed into batches up to the limits, batches run
  sequentially, each session is closed before the next starts. A node with a
  chain is indivisible. All nodes get a verdict.
- **Result — per node.** The badge is bound to the node identity (the name
  within the source), not to the position: deleting or inserting a neighbour,
  a subscription update do not shift it. A rename is a change of identity.
- Disabled nodes are tested: the question is "is the server alive", not "is it
  in the config".
- A group node is not among the "unreachable" and is not counted in the
  summary.
- The actions menu is available from the first finished verdict. If the
  subscription has a filter rule that enables nodes, bulk disabling warns:
  the next update will remove manual marks.
- The test is cancelled by the button, by stopping the tunnel and by
  backgrounding the app. Results live while the screen is open.
- A fatal session start error is shown as text; errors of individual nodes —
  only in their badges.

## Boundaries

- Measuring through the live core — [node-ping](node-ping.md).
- The WARP endpoint scanner uses the same test session — [015-WARP](../../015-WARP/FEATURE.md).
- Node and folder toggles —
  [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md) /
  [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md).
- Depends on OS capabilities: the process memory limit.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [236F](../../../tasks/236F-folder-server-testing/spec.md) | Implemented, device-verified | Folder test without VPN, thresholds, bulk actions; Stop VPN gate |
| 2 | [286](../../../tasks/286-probe-lifecycle-halt.md) | — | The test is killed by tunnel stop and backgrounding |
| 3 | [296](../../../tasks/296-folder-probe-controller.md) | — | Shared test for folders, subscriptions and servers |
| 4 | [326](../../../tasks/326-folder-probe-results-keyed-by-index.md) | ✅ Implemented (device-pending) | The result is bound to the node, not to the position |
| 5 | [336](../../../tasks/336-probe-skips-group-nodes.md) | Implemented | A group node gets a neutral verdict |
| 6 | [339](../../../tasks/339-subscription-probe-button.md) | Implemented | Test servers on the subscription screen |
| 7 | [388](../../../tasks/388-subscription-probe-bulk-disable.md) | Done, DEVICE-PENDING | Bulk disabling by results in a subscription |
| 8 | [496](../../../tasks/496-probe-bar-bulk-switch.md) | Released v2.25.0 | Shared toggle in the subscription test bar |
| 9 | [518](../../../tasks/518-naive-probe-batch-oom.md) | Released v2.25.2 | naive — one per session, no OOM |
| 10 | [523](../../../tasks/523-wireguard-probe-batch-memory.md) | Released v2.25.3 | WireGuard/AmneziaWG — up to 4 per session |
| 11 | [546](../../../tasks/546-emitters-drop-registry-rule-copies.md) | — | Registry check in the test session — by the core version of the live build |
| 12 | [604](../../../tasks/604-dns-build-health-directions-bugs.md) | Done | No global URL — the template's ping URL, not the core default |
