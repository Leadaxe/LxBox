[English](directions.md) · [Русский](directions.ru.md)

# Directions — named exits with their own node selectors

A Direction is a named exit — `vpn-1`, `vpn-2` or your own — with its own set of nodes; rules and
Default traffic send traffic to Directions.

| Field | Value |
|------|----------|
| Feature | [004-ROUTING](../FEATURE.md) |
| Promises | P15 P16 P17 P18 |
| State | ✅ written from code, 2026-09-28 |

## What it does

A Direction is a named exit that rules send
traffic to: `vpn-1` ("VPN ①"), `vpn-2`, own ones (`ru-exit`)… Each is a separate
node selector with its own members, in which the active node is chosen on the main
screen. The **Directions** tab of the Routing screen: the list of Directions,
"Add direction", the **Default traffic** tile (where everything that did not match goes).

## Parameters

| Field | Values | Default | Core key |
|---|---|---|---|
| Tag | `vpn-N` (the first free one) or own; immutable | `vpn-N` | the `selector` tag |
| Title | any name | "VPN ⓝ" for `vpn-N`, otherwise the tag | — (client only) |
| On/off | — | `vpn-1` on, `vpn-2` off | the Direction is not emitted |
| Include direct-out / Include block | checkboxes | off | options `direct-out` / `block` |
| Other directions | only Directions higher in the list | — | option tags of other selectors |
| Node filter (regex) + Exclude matching (invert) | case-insensitive | empty = all nodes | `outbounds` members |
| Default (regex) | the first matching node | empty | `default` |
| Interrupt connections on switch | on/off | on | `interrupt_exist_connections` |
| Default traffic | `direct` · Direction · `block` | `vpn-1` | `route.final` |

Auto-select (`<tag>-auto`), balancing, "Use as detour" (⚙ in the name) —
[006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).

## Inputs / Outputs

**Inputs:** the list of Directions; subscription and own nodes; user actions.
**Outputs:** one `outbounds[type=selector]` per enabled Direction;
targets for the rule, preset and Default traffic pickers; build warnings;
a notification about redirected references.

## Rules and invariants

- Target picker: `direct` first, then enabled Directions (`vpn-1` always,
  detour Directions with ⚙), `block` last, in red. Disabled ones are hidden.
- `vpn-1` cannot be disabled or deleted — it is the fallback target for everything.
- A new tag: empty, a service one (`direct-out`, `block`, `block-out`,
  `dns-out`, `reject`, `drop`, `direct`), a duplicate or a collision with `<tag>-auto`
  are rejected with a reason in the dialog. There is no ceiling on the number of Directions.
- **Deleting or disabling** a Direction moves to `vpn-1` in storage:
  rule targets, preset target overrides, Default traffic, the channel of
  DNS servers (see 005); node detour references are removed (006). The result — one
  notification "Direction "…" deleted/disabled — …". Re-enabling
  does not bring the references back.
- References from "Other directions" are cleaned only on deletion; on
  disabling they stay (reversible), the build skips them with a warning.
- A reference to a Direction lower in the list, non-existent or disabled, is not
  emitted (anti-cycle), a warning.
- The filter cut off all nodes (or the inversion excluded everything) → members `[block,
  direct-out]`, default `block`, a warning; an invalid regex → all
  nodes. The tile caption shows "N of M nodes" from a snapshot of the running core.
- Default traffic to a vanished target → `vpn-1`, a build warning.
- A rule or Default traffic with a target that is not in the config is a fatal of the
  pre-start check; normally it does not get that far thanks to the healing above.

## Boundaries

- Selecting the active node, the NETWORKS pseudo-direction (Tailscale nodes outside
  selectors) — [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md).
- Chains, the detour role, group folds ("Replace groups") —
  [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).
- Latency measurement settings per Direction — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [125F](../../../tasks/125F-configurable-channels/spec.md) | IMPLEMENTED | Configurable channels: on/off, regex filter, default, healing `route.final` |
| 2 | [184](../../../tasks/184-add-vpn4-channel.md) | — | A fourth channel |
| 3 | [197](../../../tasks/197-channel-node-filter-invert.md) | IMPLEMENTED | Node filter inversion |
| 4 | [201](../../../tasks/201-block-outbound-for-channels.md) | IMPLEMENTED | The `block` option in members, fallback for an empty filter |
| 5 | [202](../../../tasks/202-heal-channel-refs-on-disable.md) | IMPLEMENTED | Healing references on disabling, without resurrection |
| 6 | [267](../../../tasks/267-group-templates-magic-nodes.md) | — | Seeding Directions from the template (`default_directions`) |
| 7 | [274](../../../tasks/274-detour-role-to-permission.md) | RELEASE v2.15.6 | A detour Direction is available to rules again |
| 8 | [275](../../../tasks/275-channel-mutations-detour-resync.md) | RELEASE v2.15.6 | A single point of changing Directions with healing |
| 9 | [301](../../../tasks/301-regex-filter-case-insensitive.md) | ✅ implemented | The filter is case-insensitive |
| 10 | [393F](../../../tasks/393F-directions/spec.md) | released v2.21.0 | Channels → Directions: own tags, no ceiling, `include` |
| 11 | [402](../../../tasks/402-direction-chain-label-removed.md) | Done | The Direction name removed (reverted by 405) |
| 12 | [405](../../../tasks/405-direction-chain-label-mobile-only.md) | Done | The name returned as a client field |
| 13 | [441](../../../tasks/441-template-preset-vars-in-record.md) | Released v2.24.0 | Healing the target in preset and DNS server variables → `vpn-1` |
