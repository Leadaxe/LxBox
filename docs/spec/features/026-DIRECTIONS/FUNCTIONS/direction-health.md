[English](direction-health.md) · [Русский](direction-health.ru.md)

# Direction health — ping, URLTest and per-Direction test settings

A Direction is measured two ways: the app pings its nodes from the home screen, and the
core's `<tag>-auto` twin URLTests them on its own schedule with the parameters set in the
Direction editor.

| Field | Value |
|------|----------|
| Feature | [026-DIRECTIONS](../FEATURE.md) |
| Promises | P21 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Gives every Direction its own view of node health. Mass ping on the home screen measures
the nodes of the selected Direction and keeps a map per Direction; a Direction may override
the global test URL and timeout. The auto twin is the core's own measurement: it re-tests
its pool by `interval`, switches when a node is better by more than `tolerance`, sleeps
after `idle_timeout` without traffic and, with Passive health check, skips a probe while
traffic is flowing. This function only names what belongs to a Direction; measurement
itself is owned by [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).

## Parameters

| Knob | Where | Values | Default | Owner |
|---|---|---|---|---|
| Ping URL / timeout override | ping settings sheet, scope "current Direction" | URL, ms | global | [009 ping settings](../../009-NODE_HEALTH/FUNCTIONS/ping-settings.md) |
| Test URL, Interval, Tolerance (ms), Idle timeout, Interrupt connections | Direction editor, "Include auto" | — | `generate_204` / `15m` / 50 / `30m` / off | here → the twin |
| Mode, Pool size, Pool tolerance, Sticky session by | same | Fastest · Load balance | Fastest / 3 / 0 / process + domain | [006 balancing](../../006-DETOUR_AND_BALANCE/FUNCTIONS/balancing.md) |
| Passive health check | Settings → Optimization | on/off | on | one value for all twins |

## Inputs / Outputs

**Inputs:** the twin's fields from the editor; the global and per-Direction ping settings;
Passive health check.
**Outputs:** `url`, `interval`, `tolerance`, `idle_timeout`, `interrupt_exist_connections`
and `passive_check` in the `<tag>-auto` group; the ping map of the selected Direction;
the group's selected node in the home-screen row ("→ node").

## Rules and invariants

- The twin's fields go into the config as entered (after clamping); "Fastest" writes no
  `mode` and no `balancer`, so the twin is byte-identical to the upstream `urltest`.
- Ping maps are per Direction: mass ping writes and resets only the current Direction's map;
  a node without a measurement here shows another Direction's value marked `~`
  ([009-NODE_HEALTH · P2](../../009-NODE_HEALTH/FEATURE.md#promises)).
- A per-Direction override is looked up by the Direction tag; deleting the Direction removes
  the override, disabling keeps it; an orphan from an old deletion or a restored backup is
  removed on load ([009-NODE_HEALTH · P5](../../009-NODE_HEALTH/FEATURE.md#promises), 408);
  overrides travel in the backup together with the Directions (409).
- A forced re-test of the twin makes the core reselect immediately instead of waiting for
  `interval` ([009-NODE_HEALTH · P6](../../009-NODE_HEALTH/FEATURE.md#promises)).
- `interval` larger than `idle_timeout` is raised by the build with a hint in the editor
  ([009-NODE_HEALTH · P7](../../009-NODE_HEALTH/FEATURE.md#promises)).
- A twin is flagged as a dead support only when its whole membership is dead
  ([006-DETOUR_AND_BALANCE · P15](../../006-DETOUR_AND_BALANCE/FEATURE.md#promises)).

## Boundaries

- Mass ping, its cancellation and lifecycle, auto-ping after connect, folder tests, speed
  test and core-rejection auto-disable — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).
- Round-robin balancing and the pool view — [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).
- The folder and subscription server test does not see Direction overrides.
- The ping settings sheet caption "Shared with the home screen ping" stays even when a
  Direction override is active (591).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [125F](../../../tasks/125F-configurable-channels/spec.md) | IMPLEMENTED | Auto twin parameters in the channel editor |
| 2 | [208](../../../tasks/208-urltest-balancer-round-robin.md) | IMPLEMENTED | Load balance mode of the twin |
| 3 | [272](../../../tasks/272-idle-suspend-urltest-energy.md) | IMPLEMENTED | `passive_check`, `15m` default interval |
| 4 | [408](../../../tasks/408-ping-options-groups-heal.md) | Done | Orphaned per-Direction ping overrides removed |
| 5 | [409](../../../tasks/409-direction-ping-options-backup.md) | Done | Per-Direction overrides in the backup |
| 6 | [442](../../../tasks/442-urltest-interval-idle-pair.md) | Released v2.24.0 | `interval`/`idle_timeout` pair |
