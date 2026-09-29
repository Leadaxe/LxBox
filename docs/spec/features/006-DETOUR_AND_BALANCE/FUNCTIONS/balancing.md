[English](balancing.md) · [Русский](balancing.ru.md)

# Auto-select and balancing

| Field | Value |
|------|----------|
| Feature | [006-DETOUR_AND_BALANCE](../FEATURE.md) |
| Promises | P13 P14 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Spreads traffic across several nodes instead of a single selected one.
Three carriers of one auto-select form:

| Carrier | Where it is enabled | What is in the config |
|---|---|---|
| Direction twin | Direction editor → "Include auto (urltest)" | `urltest` `<tag>-auto` over the Direction's nodes; first and the default in the selector if Default (regex) selected nothing |
| Auto-select node | folder → "Add auto node…"; import of Xray `balancers` | `urltest` (Fastest/Load balance) or `selector` with `default` (Manual) of the members of its own container |
| Source fold | subscription/folder → "Replace with a group" | Manual → `selector`; Auto → `urltest`; Both → `<tag>-auto` + `selector` |

Load Balance (formerly planned as a separate `loadbalance` outbound) is the
`round_robin` mode of the fork core's standard `urltest`.

## Parameters

| Knob | Values | Default | Core key |
|---|---|---|---|
| Mode | Fastest ("single best server by latency") · Load balance ("spread connections across a pool of servers") · Manual (auto-select node, fold) | Fastest | `mode: round_robin` only with Load balance |
| Pool size | ≥1 | 3 | `balancer.pool` |
| Pool tolerance (ms) | 0 = keep the whole live pool; >0 — pick the best; for an auto-select node ≤15000 | 0 | `balancer.pool_tolerance` |
| Sticky session by | process · domain · source ip · dest ip · dest port; empty = "no stickiness" | process + domain | `balancer.sticky_hash`, empty → `["none"]` |
| Test URL / Interval / Tolerance / Idle timeout | — | `https://cp.cloudflare.com/generate_204` / 15m / 50 / 30m | `url`, `interval`, `tolerance`, `idle_timeout` |
| Interrupt connections on switch | on/off | off | `interrupt_exist_connections` |
| Auto-select node: Members | All · Rule (Include/Exclude regex over the tag and synonyms) · Pick (checkboxes) | All | `outbounds` |
| Auto-select node: Badge in list (regex) | pool badge | first flag emoji | — |

The global "Passive health check" adds `passive_check: true` to all
`urltest` groups (not to the manual genus).

## Inputs / Outputs

**Inputs:** nodes of the Direction / container; Xray `routing.balancers` and
`burstObservatory`; global ping settings.
**Outputs:** groups in the config; a label in the node list `🎯 [N]`
(Fastest) / `🔀 [N/pool]` (Load balance); the live pool of the running core
("connect to see the live pool").

## Rules and invariants

- `balancer{}` and `mode` are written only with Load balance: the core
  rejects `balancer` without `round_robin` and flat `pool` (P13).
- An empty `urltest` is not emitted: a Direction twin without nodes, an
  auto-select node with an empty pool (an explicit membership without a
  single member — with the warning "Auto node "…" was skipped…"), a fold
  without nodes — code `replace_group_empty` (P14).
- Auto-select node: into the pool — only nodes of its own container, not
  other groups; it gets into the Direction's selector but not into
  `<tag>-auto` (a urltest inside a urltest would measure someone else's
  choice). Disabled or missing members are cut off with the code
  `group_member_dropped`.
- Xray import: `random`/`roundRobin`/`leastLoad` with `expected>1` → Load
  balance; `leastPing` or `expected≤1` → Fastest; `expected` → pool,
  `maxRTT` → pool_tolerance; `selector` → include rule `^(…)`; `pingConfig`
  → url/interval; malformed shapes do not break parsing.
- `interval` greater than `idle_timeout` → `idle_timeout` is raised to
  `interval` (otherwise the core does not start).
- A fold tag that coincides with a Direction — `replace_tag_conflict`, the
  source is not folded.
- A group is not a detour target and has no detour of its own (P12, see
  [node-detour.md](node-detour.md)).

## Boundaries

- Node selection inside a group and pool display on the main screen — [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md).
- Measurements and their settings — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).
- There is no separate `loadbalance` outbound and no strategies outside
  `sticky_hash`.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [024F](../../../tasks/024F-load-balance/spec.md) | Implemented differently | Load Balance as `round_robin` |
| 2 | [208](../../../tasks/208-urltest-balancer-round-robin.md) | IMPLEMENTED | Mode, `balancer{}`, pool view |
| 3 | [210](../../../tasks/210-libbox-rc15-sticky-none.md) | IMPLEMENTED | Empty stickiness → `["none"]` |
| 4 | [272](../../../tasks/272-idle-suspend-urltest-energy.md) | IMPLEMENTED | Interval 15m, `passive_check` |
| 5 | [322F](../../../tasks/322F-balancer-node/spec.md) | DEVICE-VERIFIED | Auto-select node, import of Xray `balancers` |
| 6 | [344](../../../tasks/344-outbound-view-balancer-modes.md) | DEVICE-VERIFIED | The node window distinguishes pool and fastest |
| 7 | [442](../../../tasks/442-urltest-interval-idle-pair.md) | Released v2.24.0 | `idle_timeout` is raised to `interval` |
| 8 | [565F](../../../tasks/565F-selector-group-genus/spec.md) | Phase A merged | Manual genus (`selector`) of an auto-select node |
| 9 | [568](../../../tasks/568-source-replace-fold.md) | Implemented | "Replace with a group" for a folder and a subscription |
