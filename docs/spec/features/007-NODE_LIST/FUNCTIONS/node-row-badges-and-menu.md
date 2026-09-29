[English](node-row-badges-and-menu.md) · [Русский](node-row-badges-and-menu.ru.md)

# Node row: badges and context menu

| Field | Value |
|------|----------|
| Feature | [007-NODE_LIST](../FEATURE.md) |
| Promises | P2 (the ▷ button of the active node is inactive) |
| State | ✅ written from code, 2026-09-28 |

## What it does

A single list row tells everything needed for a choice: the name, whether
the node is active, the protocol with transport and security, the last ping
with its colour, the state of a WireGuard node, parse notifications. A long
press opens the menu of actions on the node.

## Parameters

No settings of its own. The pool badge regex is set on the auto-select group
(by default — the first flag emoji of the name), see 006.

## Inputs / Outputs

**Input:** the node's tag and type from the built config, transport and
security, the latency measurement, the endpoint node state from the core,
source and build notifications, the selected member of an auto-select
group.
**Output:** a row 56 high and a menu.

## Rules and invariants

**The first line** — the node name as is (emoji tags are part of the name).
For service nodes the name is replaced with the title from the template with
an icon: Direct 🌐, Auto ✨ (only the Direction's auto-select twin), Block ⛔;
such rows are slightly tinted. ⚠ after the name — a node that others depend
on (DNS, detour) while it is itself dead; tapping opens the list of affected
ones.

**The second line**, left to right:

| Element | When | Look |
|---|---|---|
| `ACTIVE` | the node is selected in the Direction | green pill; bolder name, stripe on the left |
| Notification icon | the node has notifications | ⓘ / ⚠ / ⊗ by the highest level; tap — the notification sheet |
| Auto-select mode and choice | auto-select group | `🎯 [N] → node` or `🔀 [N/M]` + pool badges (`🇩🇪, 🇳🇱[2]`) |
| Protocol·transport·security | a node with a protocol | `VLESS·xhttp·Reality+Vision`, `WG·awg2`, `Hy2·TLS`; not shown for auto-select |
| WG/AWG state | the core returned the endpoint state | `up` / `sleep` / `down` / `off` (orange) |
| Ping | on the right, always at the edge | `NNMS`, `ERR`, `PING…`; `~` — a measurement of another Direction, dimmed |

- Ping colour: < 200 ms — green, < 500 — orange, otherwise and `ERR` — red.
  Block has no ping; a disabled endpoint — "—".
- When width runs short, the protocol yields first; the selected member
  holds.
- A node not matching the filter — 0.4 opacity.

**Menu** (long press):

| Item | Available |
|---|---|
| Ping | tunnel up, not busy, not block |
| Use this node | tunnel up, node not active |
| Run URLTest | auto-select group |
| Select server | the auto-select group has a selected member — highlight and scroll to it |
| View pool | the Direction's auto-select twin in round-robin mode |
| Turn off / Turn on | WG/AWG node, the core returned its state, tunnel up |
| View details | always — the node screen |
| Copy URI | an ordinary node; service nodes and auto-select groups do not have the item |

- Tapping a row only highlights it. The ▷ button on the right selects the
  node; for the active one it is ✓ and cannot be pressed.
- `NETWORKS` has no Ping, Use this node or ▷ button.
- Copy JSON / detour moved to View details.

## Boundaries

- Measurement, group URLTest, dependency ⚠, the endpoint switch as a
  mechanism — 009-NODE_HEALTH; node notifications as data — 001/002.
- The View details screen, Copy URI with confirmation for links containing a
  key — 008.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [003F](../../../tasks/003F-home-screen/spec.md) | Implemented | Caption layout, ping colours, node menu |
| 2 | [094](../../../tasks/094-emoji-tags-node-settings-tabs.md) | DONE | Emoji tags in the node name |
| 3 | [099](../../../tasks/099-copy-json-into-view-json.md) | — | Copy JSON variants — in View details |
| 4 | [102](../../../tasks/102-subtitle-transport-variant.md) | DONE | Transport in the row caption |
| 5 | [103](../../../tasks/103-variant-filter-chips.md) | DONE | Transport/security labels are computed in advance |
| 6 | [208](../../../tasks/208-urltest-balancer-round-robin.md) | implemented | View pool, `🔀 [N/M]` |
| 7 | [258](../../../tasks/258-outbound-view-tabs-runtime-chain.md) | done | View details instead of View JSON |
| 8 | [355](../../../tasks/355-detour-dependency-health-warnings.md) | implemented, device-verified | ⚠ on a dead node with dependents |
| 9 | [502](../../../tasks/502-home-node-list-notification-badge.md) | Released v2.25.0 | Notification icon in the row |
| 10 | [505](../../../tasks/505-home-node-badge-user-server.md) | Released v2.25.0 | Icon on cold start and on a standalone server |
| 11 | [540](../../../tasks/540-endpoint-state-short-label-node-properties.md) | Done | Endpoint state in one word |
| 12 | [557](../../../tasks/557-kernel-lx4-wg-endpoint-toggle.md) | — | Turn off / Turn on of a WG node, the `off` state |
| 13 | [572](../../../tasks/572-notifications-group-by-code.md) | Released v2.25.7 | Node notifications grouped by code |
