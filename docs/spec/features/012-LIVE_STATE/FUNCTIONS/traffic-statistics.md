[English](traffic-statistics.md) · [Русский](traffic-statistics.ru.md)

# Traffic statistics — volume, active connections and traffic by routing rule

The Stats tab answers "how much and by which rule" for the current core
session.

| Field | Value |
|-------|-------|
| Feature | [012-LIVE_STATE](../FEATURE.md) |
| Promises | P6 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The Stats tab of the Statistics screen: how much has been transferred in the
session, how many connections are active right now, how much memory the app
takes and how the current connections are distributed across routing rules —
expandable down to an individual connection.

## Parameters

No settings of its own. While the screen is open, the status tick is 0.1 s
(see [data-channels](data-channels.md)).

## Inputs / Outputs

**Inputs:** `CommandStatus` ticks; the connection snapshot (live only —
`closedAt == 0`); the user rule catalog; the running config (for the detour
chain under a card).

**Outputs:**

| Block | Content |
|-------|---------|
| Summary | Upload, Download (volume), Connections (number of live ones; tap → Conns), LxBox (memory; tap → breakdown) |
| Traffic by Rule | a card per rule: ↑/↓ total, number of connections, under the name — the `↳ via …` detour chain; sorted by volume; expanding — connections `host:port`, TCP/UDP, rule, age, ↑/↓ |
| By routing rule | distribution of the number of connections across rules as bars |
| Memory | a sheet: process RSS/PSS, breakdown by OS memory categories, core goroutines, `connectionsIn` / `connectionsOut`; a tap on a row copies it |

## Rules and invariants

- Closed connections are not included in the statistics: otherwise the number
  and the distribution would be inflated by history.
- Rule name: the core's raw rule string is matched against the user rule
  catalog (whitespace normalization, tolerant of the core truncating long
  lists); not found or empty — `final`; the result is cached.
- The connection host is the domain if there is one, otherwise the host from
  the destination address.
- "Memory" is that of the whole app process, not only the core: the core lives
  in the same process. The size of the core's Go heap is not available
  separately.
- Cards are recomputed at most once per 0.7 s, the window counts from the end
  of the previous recomputation; the first snapshot — at once.
- Until the first snapshot arrives — a loading indicator; no connections —
  "No active connections".

## Boundaries

- There is no per-app breakdown on Stats — it is in the profiler
  ([028-TRAFFIC_PROFILER](../../028-TRAFFIC_PROFILER/FEATURE.md)).
- Speed is not shown — only volume and number of connections.
- Rules and their texts — 004-ROUTING.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [016F](../../../tasks/016F-statistics-and-connections/spec.md) | Implemented | Summary, traffic with expansion, detour chain under the node |
| 2 | [122F](../../../tasks/122F-commandclient-migration/spec.md) | Implemented | Grouping by rule instead of by node; "Top apps" removed |
| 3 | [165](../../../tasks/165-rule-name-registry.md) | Implemented | Rule name from the catalog + cache |
| 4 | [176](../../../tasks/176-connections-filterstate-all-consumer-side-filter.md) | Implemented, device-verified | Stats — a slice of live ones only |
| 5 | [242](../../../tasks/242-stats-memory-detail-popup.md) | — | Memory breakdown, navigation by tapping the chips |
