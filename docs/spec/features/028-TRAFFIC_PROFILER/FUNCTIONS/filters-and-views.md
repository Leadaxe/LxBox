[English](filters-and-views.md) · [Русский](filters-and-views.ru.md)

# Filters and views — selection by app, rule and outbound, summaries and export

One log is viewed as a stream or as a summary by domain / IP, cut by a filter
on four axes and text, and exported to JSON.

| Field | Value |
|-------|-------|
| Feature | [028-TRAFFIC_PROFILER](../FEATURE.md) |
| Promises | P10, P11, P12 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Answers "where does this particular app go", "what went through this rule or
Direction" and "which domains and addresses are the heaviest" without picking
an app in advance: the filter narrows the shared log, the summary groups it
by domain or IP, the details of any row lead into search, and export hands
the log outward.

## Parameters

| Knob | Values | Default |
|------|--------|---------|
| Grouping | Event stream / Group by Domain / Group by IP | stream |
| Filter · Protocol | DNS, TCP, UDP | empty |
| Filter · App | seen packages, "Unattributed (no owner)", "Add app from full list" | empty |
| Filter · Rule | seen rules, an empty one — "final" | empty |
| Filter · Outbound | seen links of chains and detours | empty |
| Search | substring of domain / IP / app | empty |

## Inputs / Outputs

**Inputs:** the recording's log; the "Filter events" window with axis tabs,
the "Search domain / IP / app" field and the "Reset all" button; a tap on a
domain, IP or package in the details; "View in Aggregated" from the aggregate
details; the export button in the header.

**Outputs:** the "Filter (N)" button with a yellow dot while a filter is
active; the event stream (newest first) with the rule line, a coloured kind
label (`DNS`, `DNS×`, `TCP`, `TCP·` closed, `UDP`), ⚠ on a problem and the
`cached` badge; the summary by domain or IP (connections, ↑/↓, ports,
outbounds, first and last seen); the event sheet with copyable fields; the
aggregate sheet with the summary and all connections for the key; "Share N
events (JSON)" / "Copy JSON to clipboard" and the "Export JSON copied"
snackbar.

## Rules and invariants

- **Axes are independent.** Within an axis — OR, between axes — AND; search
  sits on top of all axes, a case-insensitive substring (IP — as is).
  Protocol catches the family: DNS — resolve and failure, TCP — open and
  close, UDP — open. App — the package is among the selected OR (unowned and
  "Unattributed" is selected). Rule — the rule string, an empty one is
  caught by the "final" item. Outbound — any link of the group chain or the
  detour (selector, Direction, transport).
- **Axis lists come from what was seen.** The App, Rule and Outbound tabs
  offer what is already in the log; "Add app from full list" opens the full
  list of installed apps with icons.
- **Counter.** "Filter (N)" — the number of selected items plus search.
- **The filter lives for the whole app session.** Switching tabs, leaving the
  screen and stopping the tunnel do not reset it; reset — "Reset all" or an
  app restart. It is not written to disk.
- **Search from the details.** A tap on a domain, IP or package puts the key
  into search; a repeated tap with the same key removes it. "View in
  Aggregated" puts the key in and switches to the by-domain summary.
- **Summaries.** Computed from the full log (without the filter axes), search
  applies to the summary rows; events without an owner do not enter
  summaries. The by-domain summary collects IPs, CNAME targets, outbounds,
  the connection count, volume and problem flags; by IP — ports, outbounds,
  connections, volume.
- **Export.** JSON with `exported_at`, `event_count`, `events` and recomputed
  `by_domain` / `by_ip`; an event carries all fields, including `confidence`,
  `outbound_chain`, `detour_chain`, `issues` and `extra`. The button is
  disabled while the log is empty.
- Pause freezes a snapshot of the stream; a summary lifts the pause.

## Boundaries

- Export uploads the whole log, not the filtered list, although the
  serialiser is meant for the filtered one
  ([588](../../../tasks/588-spec-kit-revision-audit.md)).
- Rules are not created from the log (no "Add to ru-direct", "Block this
  domain").
- There is no comparison of two recordings and no per-domain latency.
- Keeping the filter across launches is deliberately not provided.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [044F/new-profiler](../../../tasks/044F-per-app-traffic-profiler/new-profiler.md) | ✅ Implemented, device-pending | Filter window, Protocol and App axes, export in the header |
| 2 | [160](../../../tasks/160-perapp-trace-live-aggregated-redesign.md) | Done, v2.4.1 | Stream / summaries, detail sheets, search from the details |
| 3 | [177](../../../tasks/177-unattributed-banner-dns-fail-only.md) | Implemented (A+B) | Protocol by event family |
| 4 | [230](../../../tasks/230-profiler-filter-rule-outbound.md) | In implementation | Rule and Outbound axes, visible search |
| 5 | [244](../../../tasks/244-profiler-filter-session-lifetime.md) | Implemented | The filter survives navigation |
| 6 | [288](../../../tasks/288-remove-per-app-trace-tab.md) | complete | One app is analysed with the App filter |
