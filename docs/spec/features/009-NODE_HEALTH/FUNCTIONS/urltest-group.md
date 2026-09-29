[English](urltest-group.md) · [Русский](urltest-group.ru.md)

# URLTest group

| Field | Value |
|-------|-------|
| Feature | [009-NODE_HEALTH](../FEATURE.md) |
| Promises | P6, P7, P8 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Gives the core's auto-select group (`urltest`) the parameters for checking
its members' health and choosing the best one: how often and at what address
to measure, at what difference to switch, whether to spread load across a
pool. Lets the user force the group to re-measure all members and reselect a
node manually — via the "Run URLTest" item in the group menu.

## Parameters

| Parameter | Core key | ✨auto (template) | Direction / auto-select node |
|-----------|----------|-------------------|------------------------------|
| Test URL | `url` | `https://cp.cloudflare.com/generate_204` | same |
| Test interval | `interval` | `15m` (presets `30s`…`30m`) | `15m` |
| Tolerance, ms | `tolerance` | 30 (presets 10…200) | 50 |
| Idle timeout | `idle_timeout` | — (core default `30m`) | `30m` |
| Break live connections on switch | `interrupt_exist_connections` | on | off |
| Passive health check | `passive_check` | — | on (one setting for all Direction groups) |
| Mode | `mode` | `least_test` | `least_test` · `round_robin` |
| Pool size | `balancer.pool` | — | 3, at least 1 |
| Pool threshold, ms | `balancer.pool_tolerance` | — | 0 |
| Stickiness key | `balancer.sticky_hash` | — | `process` + `domain` |

Stickiness components: `process`, `domain`, `source_ip`, `dest_ip`,
`dest_port`; an unknown component is dropped. The meaning of the modes, pool
and penalties — core feature 007-URLTEST_BALANCE.

## Inputs / Outputs

**Inputs:** values from the Direction editor, the auto-select node, a source
rollup or template variables; groups from a subscription body (sing-box, Xray
balancer) with their own timings; the "Run URLTest" gesture.

**Outputs:** a `urltest` entry in the core config; RPC `urlTestGroup` — the
core tests all members at the group's address, reselects a live node and
breaks the group's hung connections; the new selection arrives in the groups
stream.

## Rules and invariants

- **`tolerance` is an integer 0…65535.** An out-of-range value is clamped; a
  numeric string from old storage is read as a number and goes to the config
  as a number.
- **`balancer` and `mode` — only with `round_robin`.** With `least_test`
  neither is in the config: the core rejects `balancer` outside
  `round_robin`, and flat `pool`/`pool_tolerance` as unknown fields.
- **Disabled stickiness is `["none"]`.** An empty component set goes into the
  config as a sentinel; the core would read an empty list as the default.
- **`pool_tolerance` of an auto-select node** is capped at 15000 ms (the core
  limit); for a Direction and a rollup — only by the `tolerance` range (see
  the discrepancy report).
- **Timing pair.** If the effective `interval` is greater than the effective
  `idle_timeout` (taking the core defaults `3m`/`30m` into account when absent
  or zero), the build raises `idle_timeout` to `interval`, and when
  `interval` is absent — to `3m`. `interval` is never changed. Every
  intervention is a build warning with both values. A value the core does not
  recognize is left alone — the core will name the error itself. The rule is
  shared by Directions, auto-select nodes, subscription groups and Xray
  balancers, for both modes.
- In the editor a grey hint "Idle timeout will be raised to %s when the
  config is built" is shown under the interval/idle timeout fields — saving is
  allowed.
- **Run URLTest** is available only on URLTest groups with the tunnel up; the
  core replies at once, the selection changes asynchronously. An RPC failure
  is an error message in the banner.
- **Automatic reselection** is also started on a ping failure of the node
  selected by the group and at the end of a mass ping
  ([node-ping](node-ping.md)). Repeated starts during a running test are
  suppressed by the core itself.
- An empty group is not emitted to the config: a `urltest` without members
  crashes the core.

## Boundaries

- Group composition, rollups, Direction twins and pool view —
  006-DETOUR_AND_BALANCE.
- Group latency numbers and the current selection in real time —
  012-LIVE_STATE.
- Passive health check lowers the probe frequency at the cost of fresher
  numbers; the logic itself lives in the core.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [008F](../../../tasks/008F-ping-and-node-management/spec.md) | Implemented | Run URLTest item for a URLTest group |
| 2 | [161](../../../tasks/161-urltest-tolerance-uint16.md) | Done | `tolerance` is an integer 0…65535, not a string |
| 3 | [205](../../../tasks/205-libbox-rc12-cold-urltest.md) | — | Fix for cold URLTest in the core |
| 4 | [208](../../../tasks/208-urltest-balancer-round-robin.md) | — | `round_robin` mode, pool and stickiness |
| 5 | [210](../../../tasks/210-libbox-rc15-sticky-none.md) | — | Disabling stickiness with the `["none"]` sentinel |
| 6 | [272](../../../tasks/272-idle-suspend-urltest-energy.md) | IMPLEMENTED | `passive_check` and `interval` 15m for battery |
| 7 | [308](../../../tasks/308-group-urltest-wrong-rpc-no-reselect.md) | ✅ device check passed | Group test via `urlTestGroup` with reselection |
| 8 | [376](../../../tasks/376-FEEDBACK-kernel-urltest-goroutines-survive-restart.md) | — | Feedback to the core: group runs survived a restart |
| 9 | [442](../../../tasks/442-urltest-interval-idle-pair.md) | Released v2.24.0 | The `interval`/`idle_timeout` pair does not break the start |
