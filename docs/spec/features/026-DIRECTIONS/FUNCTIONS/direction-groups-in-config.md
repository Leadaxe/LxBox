[English](direction-groups-in-config.md) · [Русский](direction-groups-in-config.ru.md)

# Direction groups in the config — how a Direction becomes a selector and its auto twin

Every enabled Direction is written into the sing-box config as a `selector` group, and with
"Include auto" also as a `urltest` twin named `<tag>-auto`; Default traffic becomes `route.final`.

| Field | Value |
|------|----------|
| Feature | [026-DIRECTIONS](../FEATURE.md) |
| Promises | P8 P9 P10 P11 P12 P13 P14 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Turns the stored list into config groups in list order. For each Direction the build takes
the nodes that passed the filter, subtracts chains that pass through this Direction, puts the
service options in front and writes the `selector`; if the auto toggle is on and the pool is
not empty, the `urltest` twin is written first and becomes the selector's default. The
membership is shared by the selector and the twin, except that groups (auto-select nodes,
source folds) enter the selector only. Default traffic is written as `route.final`.

## Parameters

| Knob | Values | Default | Core key |
|---|---|---|---|
| Node filter (regex), Exclude matching | case-insensitive regex over final node tags | empty = all | `outbounds` members |
| Default (regex) | the first matched member | empty | `selector.default` |
| Include direct-out / Include block / Other directions | options | off / off / none | `outbounds` head |
| Interrupt connections on switch | on/off | on | `selector.interrupt_exist_connections` |
| Include auto (urltest) | on/off | off | the `<tag>-auto` group |
| Test URL / Interval / Tolerance (ms) / Idle timeout | — | `cp.cloudflare.com/generate_204` / `15m` / 50 / `30m` | `url`, `interval`, `tolerance`, `idle_timeout` |
| Interrupt connections (twin) | on/off | off | `urltest.interrupt_exist_connections` |
| Mode: Fastest · Load balance | — | Fastest | `mode: round_robin` + `balancer{}` only for Load balance |
| Pool size / Pool tolerance (ms) / Sticky session by | ≥ 1 / 0–15000 / set | 3 / 0 / process + domain | `balancer.pool`, `pool_tolerance`, `sticky_hash` |
| Default traffic | `direct` · Direction · `block` | `vpn-1` | `route.final` |

`tolerance` is clamped to 0–65535, `pool_tolerance` to 0–15000 (the core's limit), on read,
save, in the editor and at emission; `pool` to ≥ 1. `passive_check` is not written (core lx.12
removed it, [611](../../../tasks/611-drop-passive-check-kernel-lx12.md)). An empty or missing `interval` is `15m` (272, 604).

## Inputs / Outputs

**Inputs:** the Direction list; final node tags of all sources (after detour resolution,
folds and chains); chain positions; the names of emitted folds (they are legal `include`
targets too); Passive health check.
**Outputs:** `outbounds[type=selector]` per enabled Direction (and `vpn-1` always);
`outbounds[type=urltest]` per twin; `route.final`; build warnings; the list of Directions
without nodes for a home-screen snackbar.

## Rules and invariants

- **Membership order is normative:** `<tag>-auto`, `direct-out`, `block`, "Other
  directions" tags, then nodes in config order. The first option is the implicit default of
  a selector, so a subscription node never silently becomes the default of a Direction made
  of options.
- An `include` tag goes in only if that Direction is enabled and already emitted above (or
  is an emitted fold); a reference downward, to a disabled or a missing tag is dropped with
  the warning "option … dropped — it must be another direction listed above this one (and
  enabled)". A Direction never includes its own twin or itself.
- A Direction does not take a chain that passes through it, transitively included
  ([006-DETOUR_AND_BALANCE · P9](../../006-DETOUR_AND_BALANCE/FEATURE.md#promises)); the
  subtraction is not blamed on the filter.
- An empty membership (the filter matched nothing, or the inversion excluded all) → members
  `[block, direct-out]`, `default: block`, the warning "node filter matched no nodes —
  traffic is blocked (default)"; with `Include direct-out` on and no nodes the warning says
  "traffic goes direct (no VPN hop)". An invalid regex → all nodes. An empty filter with
  zero nodes (no subscription) is not a warning.
- `default` is the first member matching the Default regex; a non-member or no match — the
  key is absent and the core takes the first option; with the twin emitted and no explicit
  default, the twin is the default.
- The twin is emitted only when the toggle is on and the pool of non-group nodes is not
  empty: a `urltest` without members is a core fatal. "Fastest" writes neither `mode` nor
  `balancer`; "Load balance" writes both, an empty sticky set as `["none"]`
  ([006-DETOUR_AND_BALANCE · P13](../../006-DETOUR_AND_BALANCE/FEATURE.md#promises)).
- `route.final` pointing to a missing Direction, a disabled one or a twin that was not
  emitted → `vpn-1` with the warning "Route final … no longer exists — switched to vpn-1";
  `direct-out`, `block` and a live twin are valid targets.
- The tags of every Direction and its twin are reserved before node tags are allocated, so
  a node never collides with a Direction.
- `interval` larger than `idle_timeout` is raised by the build sanitizer and hinted in the
  editor ([009-NODE_HEALTH · P7](../../009-NODE_HEALTH/FEATURE.md#promises)).

## Boundaries

- Storage, healing of references and tag rules — [direction-model.md](direction-model.md).
- Measurement parameters of the twin, mass ping and reselection —
  [direction-health.md](direction-health.md); balancing modes, detour rings —
  [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).
- Source folds and subscription groups are groups of another kind —
  [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [125F](../../../tasks/125F-configurable-channels/spec.md) | IMPLEMENTED | Per-Direction regex filter, default, `route.final` degradation |
| 2 | [141](../../../tasks/141-deep-code-audit-hardening.md) | — | `default` must be a member; the Default regex |
| 3 | [197](../../../tasks/197-channel-node-filter-invert.md) | IMPLEMENTED | Node filter inversion |
| 4 | [201](../../../tasks/201-block-outbound-for-channels.md) | IMPLEMENTED | `block` option; `[block, direct-out]` fallback |
| 5 | [208](../../../tasks/208-urltest-balancer-round-robin.md) | IMPLEMENTED | Load balance mode, `balancer{}` |
| 6 | [272](../../../tasks/272-idle-suspend-urltest-energy.md) | IMPLEMENTED | `passive_check`, interval `15m` for new twins |
| 7 | [301](../../../tasks/301-regex-filter-case-insensitive.md) | ✅ implemented | Filters are case-insensitive |
| 8 | [393F](../../../tasks/393F-directions/spec.md) | released v2.21.0 | `include`, normative order, twin as default, chains through a Direction |
| 9 | [442](../../../tasks/442-urltest-interval-idle-pair.md) | Released v2.24.0 | `interval`/`idle_timeout` pair, editor hint |
| 10 | [604](../../../tasks/604-dns-build-health-directions-bugs.md) | Done | `pool_tolerance` clamped to the core's 15000, as for a node; one `interval` default |
