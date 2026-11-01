[English](live-connections.md) · [Русский](live-connections.ru.md)

# Live connections — each connection with its app, rule, node and detour

The Conns tab lists connections straight from the core and lets the user close
them.

| Field | Value |
|-------|-------|
| Feature | [012-LIVE_STATE](../FEATURE.md) |
| Promises | P7, P8, P22 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The Conns tab of the Statistics screen: the core's connection list in real
time (newest on top) with the owner app, route and traffic; details on tap;
closing one or all. Shows through which rule, groups, node and detour tail a
connection went, and highlights hung ones.

## Parameters

| Knob | Values | Default |
|------|--------|---------|
| Keeping closed ones | "Closed kept 30s" / "Keeping all closed" | 30 s; not saved |

## Inputs / Outputs

**Inputs:** the connection snapshot (live and closed); the rule catalog;
gestures — tap, ×, "Close all".
**Outputs:** a connection row; the details sheet; `closeConnection`,
`closeConnections` calls; the header "N active / M total".

Row: the app icon (or a TCP/UDP arrow, a checkmark for closed ones),
`host:port`, ↑/↓, ×; the second line — the routing line and on the right the
age or "closed". The details sheet — non-empty fields in groups (addresses,
route, traffic, time, app), a tap copies the value, "Copy JSON", "Close".

## Routing line (chain reconstruction)

`rule ⇒ groups : detour entry → … → exit (selector (choice)) → target`

- To the left of `:` — the decision axis: the rule (name from the catalog,
  empty — `final`), then selector groups top-down.
- To the right — the physical path of the packet: the node's detour tail is
  unrolled so that the transport closest to the phone comes first; the exit is
  the node wrapped in its selectors; last — the destination domain or host.
- The group chain (`chain`) and the detour tail (`detour`) come from the core
  separately and are not glued together. An empty chain — the selected node is
  taken.
- A "selector + its choice" pair collapses into `selector (choice)`.
- The same line is used in the profiler log
  ([028-TRAFFIC_PROFILER](../../028-TRAFFIC_PROFILER/FUNCTIONS/attribution.md)).

## Rules and invariants

- A "one-sided" connection (pink background, the "One-way" badge and an
  explanation in the details): TCP that has lived ≥ 3 s with traffic strictly
  in one direction. UDP, fresh, closed, ones without a start time and zero ones
  are not marked.
- A connection counts as closed by the core's mark or by disappearing from the
  snapshot. Closed ones stay grey for 30 s or until the "all" mode is turned
  off.
- "Close all" immediately marks live ones as closed without waiting for the
  core; snackbar — "Closed N connections" / "No active connections to close" /
  "Failed to close connections (tunnel down?)".
- Breaking on node switch is done by the core, not by this screen: with the
  Direction flag `interrupt_exist_connections` on, it closes the connections of
  the switched Direction on any selection change; the application closes
  nothing and only shows them as closed. Choosing the already active node
  breaks nothing.
- The list is redrawn at most once per 0.7 s; closes are accounted for on every
  snapshot.

## Boundaries

- The screen lives inside Statistics; there is no separate screen.
- History longer than the core's window (5 min) is not stored; accumulating
  "all" — only while the screen is open.
- The Direction flag that breaks connections on switch —
  [026-DIRECTIONS](../../026-DIRECTIONS/FEATURE.md); the node selection itself —
  007-NODE_LIST.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [016F](../../../tasks/016F-statistics-and-connections/spec.md) | Implemented | Live list, closing one and all |
| 2 | [143](../../../tasks/143-interrupt-connections-on-node-switch.md) | Removed 2026-11-01 (§9) | Breaking the group's connections on node switch |
| 3 | [152](../../../tasks/152-conn-detail-sheet.md) | Done | Connection details sheet |
| 4 | [153](../../../tasks/153-oneway-conn-highlight.md) | Done | Highlighting one-sided TCP |
| 5 | [154](../../../tasks/154-conn-app-icon-and-i18n.md) | Done | App icon in the row |
| 6 | [174](../../../tasks/174-restore-connection-chains.md) | Implemented, device-verified | Group chain from the core restored |
| 7 | [178](../../../tasks/178-detour-tail-in-connection-chain.md) | ✅ DEVICE-VERIFIED | Detour tail as a separate field |
| 8 | [181](../../../tasks/181-routing-section-three-axes.md) | ✅ Implemented | Decision axis and detour axis separately |
| 9 | [204](../../../tasks/204-conns-routing-unify-with-profiler.md) | Implemented | Conns routing line = profiler |
| 10 | [251](../../../tasks/251-selector-fold-routing-lines.md) | Implemented | Collapsing "selector (choice)" |
| 11 | [252](../../../tasks/252-physical-packet-route-line.md) | Implemented | Physical path in the order of packet travel |
