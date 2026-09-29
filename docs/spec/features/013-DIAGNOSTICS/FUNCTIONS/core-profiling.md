[English](core-profiling.md) · [Русский](core-profiling.ru.md)

# Core profiling — pprof snapshots of the live sing-box core

Snapshots are taken only while the tunnel is up.

| Field | Value |
|-------|-------|
| Feature | [013-DIAGNOSTICS](../FEATURE.md) |
| Promises | P24 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Captures standard pprof snapshots from the live core — goroutine stacks, CPU
profile, heap, allocations — and hands them over as a file via the system
share or through the Debug API. Needed for complaints like "the phone gets
hot", "the core ate the memory", "it hung": the snapshot is taken on the
user's device at the moment of the problem, without building a debug version.

## Parameters

No settings of its own. The set of snapshots on the **Profiling** tab of the
Debug screen:

| Button | What is captured | Format |
|--------|------------------|--------|
| Capture Goroutines (summary) | `goroutine?debug=1` | text |
| Capture Goroutines (full stacks) | `goroutine?debug=2` | text |
| Capture CPU profile (10s) | `profile?seconds=10` (blocks for 10 s) | `.pb` |
| Capture Heap (inuse_space) | `heap?gc=1` | `.pb` |
| Capture Allocations | `allocs` | `.pb` |

Debug API: `GET /diag/pprof?profile=P&query=Q`, `P` — `goroutine` |
`profile` | `heap` | `allocs` | `block` | `mutex` | `threadcreate` (default
`goroutine`); `query` — a raw pprof query; defaults `debug=2` / `seconds=10` /
`gc=1` / empty. The CPU profile duration is bounded to 1..60 s.

## Inputs / Outputs

**Inputs:** a button press or an API request; the live core.
**Outputs:** a snapshot file with a timestamp in the name (without colons) via
the system share; text for `goroutine?debug=…`, otherwise a binary `.pb` for
`go tool pprof`; an on-screen hint on how to open a binary profile.

## Rules and invariants

- Without the tunnel up the snapshot is not taken: "VPN must be running to
  capture a profile."
- One snapshot runs at a time: the other buttons are inactive; the blocking
  CPU profile has a progress indicator and "Profiling for 10s…".
- The snapshot server inside the core is brought up on the device address only
  for the duration of one request (the first free port in 6060..6065) and shut
  down right away: in normal operation nothing listens.
- An empty response — "Profile was empty (timeout?)."; an error — "Capture
  failed: …".
- An unknown profile in the API — 400 with the list of allowed ones.
- Goroutine stacks while the tunnel is live also go into the
  [dump](diagnostic-dump.md); the CPU profile does not.

## Boundaries

- With the core runtime fully blocked, the snapshot server will not answer —
  the snapshot will hit the deadline; the goal of the channel is "the core
  spins idle", not a deadlock.
- Memory snapshots the core takes on its own under memory pressure —
  [crash reports](crash-reports.md).
- Depends on OS capabilities: the system share.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [207](../../../tasks/207-goroutine-cpu-dump.md) | implemented | pprof snapshots on the device, a one-request server, `/diag/pprof` |
