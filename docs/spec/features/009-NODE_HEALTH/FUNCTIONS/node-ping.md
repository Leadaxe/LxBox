[English](node-ping.md) · [Русский](node-ping.ru.md)

# Node ping

| Field | Value |
|-------|-------|
| Feature | [009-NODE_HEALTH](../FEATURE.md) |
| Promises | P1, P2, P3, P4, P6 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Measures node latency through the running core: one node — via the "Ping"
item in the node menu, all visible nodes — via the ping button on the home
screen, automatically — 5 s after connecting. The result is shown on the right
of the node row as `NNMS` or `ERR`, colored by the scale.

## Parameters

| Parameter | Value |
|-----------|-------|
| URL and timeout | from the [ping settings](ping-settings.md), by the current Direction |
| Auto-ping after connect | on (default) / off; 5 s delay |
| Mass ping parallelism | up to 10 measurements at once |
| Color scale in the list | < 200 ms green, < 500 ms orange, otherwise and `ERR` — red |

## Inputs / Outputs

**Inputs:** gesture (menu item, tap on the button, long tap — settings);
tunnel transition to "connected"; the core's `urlTestOutbound` reply — latency
or error text (failure is determined only by a non-empty error, a 0 ms latency
is success).

**Outputs:** a measurement in the current Direction's map; `PING…` for the
duration of the measurement; an error line of the form
`<node> → <host> — <reason>` in the log and banner for a single failure; at the
end of a mass run — a single re-sort of the list and a group test of all
URLTest groups ([urltest-group](urltest-group.md)); recalculation of the
"root causes" for detour.

## Rules and invariants

- **Only with the tunnel up.** The button is inactive without a tunnel, in the
  busy state, with an empty list and on the NETWORKS pseudo-Direction.
- **What is not pinged.** A `block` node is excluded from single and mass
  ping. A node with a manually disabled endpoint shows `—` in a neutral color:
  its failure is not a fault.
- **Order — as on screen.** Mass ping walks the displayed list taking filter,
  sort and pinned items into account; service outbounds (direct etc.) are in
  it too.
- **Snapshot at start.** The URL, timeout and target Direction are fixed at the
  start of the run (and of a single measurement): switching the Direction in
  the middle of a run does not send the results to another map.
- **Isolation by Direction.** Mass ping clears measurements only of its own
  nodes in its own Direction; their place is taken by `PING…` for the duration
  of the run. A node without its own measurement shows the last known one from
  another Direction with the `~` prefix in a dimmed color. Measurements outside
  a Direction live in a separate map.
- **Cancellation.** A second tap during a run is stop: results stop being
  applied at once, `PING…` is removed from all nodes, and measurements already
  sent to the core are aborted by breaking the separate ping channel (status
  and statistics are not affected). Group tests already started in the core
  play out; new ones are not started.
- **Lifecycle.** Stopping/death of the tunnel and revocation of the VPN slot
  kill mass ping and auto-ping; backgrounding the app kills only auto-ping —
  a mass ping already started lives on in the background.
- **Single failure of the selected node.** If the failed node is selected by
  some URLTest group, a group test with reselection is started for that group
  immediately. For other nodes — nothing.
- **Batched rendering.** Results of a mass run are applied in batches every
  ~120 ms, so that a list of hundreds of nodes is not redrawn for each one.
- Measurements live in memory and are not kept between app launches.

## Boundaries

- Sort by ping and "Re-sort on manual ping" — 007-NODE_LIST.
- The ⚠ warning on a dead node that others depend on —
  006-DETOUR_AND_BALANCE.
- Ping measures the node by tag in the live core; the node's detour and chain
  enter the measurement as part of its path.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [008F](../../../tasks/008F-ping-and-node-management/spec.md) | Implemented | Mass ping, cancellation, node menu, color indication |
| 2 | [034](../../../tasks/034-mass-ping-cancel-actually-cancels.md) | Done | Cancelling a mass ping actually stops the run |
| 3 | [078](../../../tasks/078-control-outbound-and-display-order-ping.md) | ✅ Implemented | Mass ping in display order |
| 4 | [175](../../../tasks/175-ping-cancel-separate-client.md) | Implemented (device-verify pending) | Cancellation aborts measurements in the core through a separate channel |
| 5 | [209](../../../tasks/209-unary-cc-via-pingclient.md) | — | Single requests to the core through the non-sleeping ping channel |
| 6 | [286](../../../tasks/286-probe-lifecycle-halt.md) | — | Deterministic probing halt on tunnel stop; batched rendering |
| 7 | [287](../../../tasks/287-stop-latency-mass-ping-wg-teardown.md) | — | Stopping the VPN during a mass ping is not delayed |
| 8 | [308](../../../tasks/308-group-urltest-wrong-rpc-no-reselect.md) | ✅ device check passed | Failure of the selected node and the end of a run force group reselection |
| 9 | [325](../../../tasks/325-mass-ping-wipes-other-channels.md) | ✅ Implemented | Measurements per Direction, another's measurement marked |
| 10 | [355](../../../tasks/355-detour-dependency-health-warnings.md) | DEVICE-VERIFIED | Measurements feed the dependency graph of dead nodes |
| 11 | [367](../../../tasks/367-autoping-after-inplace-reload.md) | ✅ Fixed | Auto-ping also after a config reload on a live tunnel |
| 12 | [557](../../../tasks/557-kernel-lx4-wg-endpoint-toggle.md) | Implemented | A disabled endpoint — a dash instead of a measurement |
