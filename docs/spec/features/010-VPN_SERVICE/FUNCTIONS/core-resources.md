[English](core-resources.md) · [Русский](core-resources.ru.md)

# Core resources — sleeping idle WireGuard tunnels and limiting core memory

With many WireGuard and AmneziaWG nodes, idle tunnels are suspended and
built only on first use, and the core gets a memory ceiling.

| Field | Value |
|------|----------|
| Feature | [010-VPN_SERVICE](../FEATURE.md) |
| Promises | P17, P18 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Keeps memory and battery under control with many WireGuard/AmneziaWG nodes:
suspends idle tunnels (they wake up by themselves on first use), builds a
tunnel only on first use and limits how many are built at once. Separately — sets
the core's memory ceiling.

## Parameters

| Setting (VPN settings → System) | Values | Default | Core key |
|---------------------------------|--------|---------|----------|
| Suspend idle tunnels | Off / 30 s / 2 min / 5 min | 30 s | `lx.wg.idle_suspend` |
| Suspend active-route tunnels | Off / 5 / 15 / 30 min / 1 h | 5 min | `lx.wg.idle_suspend_reachable` |
| Lazy tunnel build | on/off | on | `lx.wg.lazy_build` |
| Built tunnels limit | 0 (no ceiling) / 3 / 5 / 8 / 12 | 5 | `lx.wg.build_max` |
| Memory limit (Optimization) | Auto / Off / 200 / 384 / 512 / 768 MB | Auto | core start parameter `oomMemoryLimit` |

All five are part of the backup.

## Inputs / Outputs

**Input:** the user's choice.
**Output:** the `lx.wg` block in the core config; the memory ceiling in the
core parameters.

## Rules and invariants

- "Suspend idle tunnels" suspends tunnels that are not on the active route and
  have been idle longer than the threshold. Off — the `lx` block is not written
  at all (the core does not start the idle counter).
- "Suspend active-route tunnels" — a second, long window for tunnels of the
  active route (the selected node, pool members); the first connection after
  sleep takes ~1 RTT longer. Written only together with the first threshold;
  without it the row is dimmed and unavailable (the core rejects the window
  without a threshold).
- "Lazy tunnel build" and "Built tunnels limit" are written only together with
  the sleep threshold; with lazy build off neither `lazy_build` nor
  `build_max` is written. `0` is written as is — no ceiling.
- The obsolete `route.lx_idle_suspend` is never written: the core issues a
  warning for every such key.
- Changing any of the four WG parameters — "Applies on next connect." and the
  "restart needed" mark.
- Memory limit: Auto picks the ceiling by the device's memory size (up to
  3.5 GiB — 200 MB, up to 7 GiB — 384 MB, more — 512 MB); Off removes the
  ceiling, but watching for low memory in the system stays; an unknown value
  (for example, from another version) behaves like Auto. The garbage collector
  ceiling is applied to the running core at once ("Applied.", no restart); the
  memory-based emergency unload threshold — from the next connection.
- A limit that is too low keeps the CPU busy with garbage collection and heats
  the phone — hence the ceiling is configurable rather than a hard 200 MB.

## Boundaries

- Disabling/enabling an individual WG/AWG node on the fly and its state
  (sleeping/built) — [012-LIVE_STATE](../../012-LIVE_STATE/FEATURE.md) /
  [008-NODE_EDITOR](../../008-NODE_EDITOR/FEATURE.md).
- Passive health check and URLTest intervals — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).
- Sleep of the whole tunnel — [tunnel-sleep](tunnel-sleep.md).
- Depends on OS capabilities: the device's memory size, the policy of
  unloading processes on low memory.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [128F](../../../tasks/128F-idle-suspend/spec.md) | IMPLEMENTED + DEVICE-VERIFIED | Sleep threshold for idle WG/AWG, presets as a list |
| 2 | [173](../../../tasks/173-oom-killer-setup-options.md) | Implemented (device-verify pending) | The core memory ceiling is set by start parameters |
| 3 | [215](../../../tasks/215-libbox-rc18-idle-suspend.md) | IMPLEMENTED + DEVICE-VERIFIED | Core with WG/AWG sleep support |
| 4 | [271](../../../tasks/271-configurable-memory-limit.md) | RELEASE v2.15.3 | Configurable memory limit, applied without a restart |
| 5 | [272](../../../tasks/272-idle-suspend-urltest-energy.md) | IMPLEMENTED | Sleep window for the active route, default 5 min; sleep on by default (30 s) |
| 6 | [277](../../../tasks/277-reachable-suspend-silent-gate.md) | RELEASE v2.15.10 | The dependent window is honestly unavailable rather than silently not saved |
| 7 | [535](../../../tasks/535-kernel-1-14-2-lx1-pin-lx-wg-keys-endpoint-state.md) | Implemented | Sleep keys moved from `route` to `lx.wg` |
| 8 | [536](../../../tasks/536-lx-wg-lazy-build-build-max.md) | Implemented | Lazy build and a budget of 5 next to the sleep threshold |
| 9 | [542](../../../tasks/542-build-max-setting.md) | Implemented | Lazy build and the budget are user settings |
