[English](core-reject-auto-disable.md) · [Русский](core-reject-auto-disable.ru.md)

# Auto-disable of nodes rejected by the core

| Field | Value |
|-------|-------|
| Feature | [009-NODE_HEALTH](../FEATURE.md) |
| Promises | P14, P15, P16 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The core refuses to start as a whole if even one node in the config is
invalid. On a Start tap the app recognizes the node named in the rejection,
disables it with the same toggle the user uses, with the core's verbatim
reason, quietly finds the other invalid nodes and brings the VPN up on the
remaining ones.

## Parameters

| Parameter | Value |
|-----------|-------|
| Round limit before asking | 10 |
| Trigger | the Start button; a Debug start with the safety-net flag |

There are no user settings.

## Inputs / Outputs

**Inputs:** the core rejection text at start and on `checkConfig`; tags of the
built config; the human's answer to the limit question; cancellation.

**Outputs:** disabled nodes with the `core_rejected` warning
(`params.reason` — the core text without the prefix); the Start button in the
check phase — "Checking servers… (%d disabled)" with cancellation; a banner on
the home screen; an icon and the reason in the node list, in the server row
and a counter on the subscription/folder row.

## Rules and invariants

- **Tree.** Start accepted → end, not a single check. A rejection not about a
  node (inbound, dns, route), without a tag (core older than `lx.7`) or with a
  tag not present in the config → an ordinary error. The rejection names a
  node → disable → `checkConfig` rounds without a tunnel: a new node named →
  disable and continue; an already disabled node named or an error not about a
  node → error, end; clean → final start. A rejection of the final start is an
  error; the named node is disabled, but there is no third start.
- **Parsing.** The string `initialize <outbound|endpoint>[<i>] <type>[<tag>]:
  <text>` is searched for anywhere in the message. A tag may contain `]: `,
  so candidates are tried right to left, the first one matching a config tag
  wins. The index `<i>` is not used for matching.
- **Tag → node.** For derived entries (a chain hop, a folder member, WARP, a
  subscription node with a prefix) the source node is disabled. "The same
  node" is compared by node reference, not by tag: namesakes `Dup`/`Dup-1` do
  not break the loop.
- **Limit.** After 10 rounds — the question "10 servers disabled — there may
  be more" with the buttons Stop / Keep checking. Keep checking lifts the
  limit until the end of this Start; Stop and dismissing without the buttons —
  the VPN is not up, disabled nodes stay disabled. Cancelling with the button
  or any Stop in the check phase — the same outcome; the round plays out to
  the end.
- **Banner.** "1 server disabled" / "%d servers disabled", up to three names
  and `+N more`, the Show button — the list of disabled nodes; a tap on a row
  opens the node details on the Diagnostics tab at the notifications; a
  deleted node is an inactive row. Lives until ×, Stop/Disconnected, the next
  Start or an app restart. There is no "Enable everything back" — the core
  would reject again.
- **The verdict is bound to the body.** Same body (restart, cache, an update
  with the same body) — it holds. The body changed (subscription update, a
  user edit, including a rename) or the old body is gone — the verdict is
  lifted, the node enabled, the next start checks again. A core update does
  not lift verdicts. The user turned the toggle on — the verdict is lifted.
- A node disabled by a human (without a verdict) is never touched by the
  automation.
- **Backup.** The verdict and the safety-net disable are not written to the
  file; a manual disable is exported. Importing a file with a verdict drops
  it.
- Runtime errors (timeout, ping, server refusal) do not disable a node.
- Autostart, the tile, the Intent API, reconnect and a settings-set switch
  start without the automation: a rejection of the new config waits for
  Start.

## Boundaries

- Protocol grammars are not duplicated in the app: this is the second line
  after the registry checks at parse time (002-NODE_IMPORT).
- Notification texts and their grouping — 013-DIAGNOSTICS.
- Node toggles — 001-SUBSCRIPTIONS.
- Depends on OS capabilities: a tunnel start without a UI — there the limit
  question has nobody to be shown to.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [478F](../../../tasks/478F-core-rejected-node-auto-disable/spec.md) | Released v2.25.0 | Auto-disable on core rejection: tree, limit, banner, verdict by body |
| 2 | [489](../../../tasks/489-core-reject-verdict-not-backup.md) | Released v2.25.0 | The verdict does not go into the backup |
| 3 | [490](../../../tasks/490-guard-review-findings.md) | Released v2.25.0 | Safety-net review findings |
| 4 | [498](../../../tasks/498-core-reject-list-navigation.md) | Released v2.25.0 | List of disabled nodes: navigation to the node, banner lifetime |
| 5 | [499](../../../tasks/499-core-reject-source-list-indicators.md) | Released v2.25.0 | The verdict is visible in the source list |
| 6 | [503](../../../tasks/503-core-reject-list-disabled-node-navigation.md) | Released v2.25.0 | Navigation to a disabled node outside the build; "the same node" by reference |
| 7 | [506](../../../tasks/506-change-review.md) | Released v2.25.2 | The automation — only the Start button (D1) |
