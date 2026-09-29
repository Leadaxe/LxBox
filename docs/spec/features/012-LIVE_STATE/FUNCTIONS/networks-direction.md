[English](networks-direction.md) · [Русский](networks-direction.ru.md)

# NETWORKS pseudo-direction

| Field | Value |
|-------|-------|
| Feature | [012-LIVE_STATE](../FEATURE.md) |
| Promises | P19 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Shows on the home screen the nodes that did not get into any exit selection
list — currently these are Tailscale nodes without `exit_node` — together with
their live state. The user sees that a node has come up, needs sign-in or is
stopped, and can open its screen.

## Parameters

No settings of its own.

## Inputs / Outputs

**Inputs:** the running config (with the tunnel down — the last built one);
the tunnel status; the core's `SubscribeTailscaleStatus` stream —
`BackendState`, `StateText` by node tag.

**Outputs:** the `NETWORKS` item last in the list of directions; the list of
its nodes; the state in the row in place of latency.

| Condition | In the row |
|-----------|------------|
| VPN off | nothing |
| VPN on, no core entry for the node | `starting` |
| `Running` | `running` |
| `NeedsLogin` | `sign-in needed` (warning color) |
| `Stopped` | `stopped` (warning color) |
| other | the core's `StateText` as is (empty — `BackendState`) |

## Rules and invariants

- A node is included if it is in `endpoints[]`, of type `tailscale` and the
  registry does not consider it an exit (no `exit_node`). Tailscale in
  `outbounds[]`, WireGuard and Tailscale with an exit — are not included.
- NETWORKS is shown only with the VPN up and a non-empty composition; if there
  are no real directions — it is shown alone.
- It is not written to the config or storage; it is absent from the target
  selection lists of rules, DNS and chain links; it cannot be renamed, deleted
  or configured. A user Direction tagged `NETWORKS` is not confused with it.
- With NETWORKS selected: the counter is the number of its nodes, there are no
  sort buttons or filters; the selected real direction and the traffic exit do
  not change.
- A node row: no active mark, a tap opens the node screen and does not select
  the exit; the menu has no selection and no latency measurement; the mass
  measurement is unavailable.
- The state subscription lives while the VPN is on and there are NETWORKS
  nodes; a change of the composition or of the core config snapshot (reload)
  re-establishes it. Redraw — only on a change of state or the number of
  devices.
- Stream messages without a tag are dropped.

## Boundaries

- The Network tab of a Tailscale node (devices, exit node, check) —
  008-NODE_EDITOR / 009-NODE_HEALTH.
- Which nodes go into ordinary directions — 007-NODE_LIST.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [579](../../../tasks/579-networks-pseudo-direction.md) | Implemented, DEVICE-PENDING | Pseudo-direction with the node state |
| 2 | [581](../../../tasks/581-tailscale-network-tab.md) | Implemented, DEVICE-PENDING | The state subscription is shared by the home screen and the node tab |
