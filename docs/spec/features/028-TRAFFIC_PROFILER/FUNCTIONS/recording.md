[English](recording.md) · [Русский](recording.ru.md)

# Recording and buffer — a network event log on an explicit command

Recording starts only on START, lives in the background, keeps the log within
the chosen window and under the ceiling, and is erased by an app restart.

| Field | Value |
|-------|-------|
| Feature | [028-TRAFFIC_PROFILER](../FEATURE.md) |
| Promises | P1, P2, P3, P4, P5, P6 |
| State | ✅ written from code, 2026-09-29 |

## What it does

The Profiler tab of the Statistics screen: on START it subscribes to the
core's profiler channel and turns connection snapshots and DNS events into a
log: opening and closing of TCP/UDP connections, DNS resolves and failures.
The log is a time window with a ceiling; an app restart erases it. Only a
manual export "saves" it.

## Parameters

| Knob | Values | Default |
|------|--------|---------|
| Recording | START / STOP | stopped |
| Retention window ("Keep …") | 1m / 10m / 1h | 10m; saved, part of the backup |
| Display | Pause / Resume (freezes the list, recording continues) | live |

Fixed: ceiling 20,000 events; window cleanup every 15 s; ring of unowned
events — 50; "probable RST" — under 1 s and 0 bytes.

## Inputs / Outputs

**Inputs:** START/STOP from the tab header or the Debug API; connection
snapshots (`CommandConnections`) and DNS events (`CommandDNS`) of the profiler
channel, only while recording.

**Outputs:** events `tcpOpen` / `tcpClose` / `udpOpen` / `dnsResolve` /
`dnsFail`: time, app, domain, IP, port, network, rule, group chain, detour
tail, outbound type, ↑/↓, duration (on close), problem flags; the header
"Recording system-wide events · time · N events" / "Not recording" with the
hint "Tap START to begin capture. Recording continues when you leave this
tab."; the `Live` chip on the home screen.

## Rules and invariants

- **Recording is explicit and long.** It starts only on START; a repeated
  START does nothing. It continues when leaving the tab and backgrounding the
  app ([012-LIVE_STATE · P3](../../012-LIVE_STATE/FEATURE.md#promises));
  STOP drops the subscription and freezes the log until the next START, which
  clears the log and the unowned ring.
- **Live / Aggregated modes** are ways to show one log: an event stream
  (newest first) or summaries by domain / IP
  ([filters-and-views](filters-and-views.md)). Pause freezes a snapshot of
  the stream; switching to a summary lifts the pause.
- **Window and ceiling.** Events older than the window are purged every 15 s;
  beyond 20,000 the oldest are evicted. A window change applies at the next
  cleanup. A cleanup that removed something recomputes the banners.
- **Two connection phases.** A new connection in a snapshot gives an open
  event; one that vanished from the snapshot or was marked closed by the core
  gives a close event. Bytes of an open connection are updated without
  events. A short connection that opened and closed between snapshots gives
  both phases; a repeat of an already closed one in later snapshots gives no
  duplicates (closed ones are remembered for 5 min).
- **Core clock.** Start and end are taken from the core's timestamps; a
  timestamp before 2000-01-01 is "no data", then the arrival time is used. A
  negative duration from clock skew is not shown and is not judged as a
  "probable RST".
- **Probable RST.** TCP that closed in under 1 s without a single byte is
  marked ⚠ "Connection closed within 1s without bytes (likely RST /
  blocked)" — a heuristic, false positives are possible.
- A channel stream error does not break the recording: the next snapshot
  arrives on the next tick.
- Everything is in memory: an app restart erases the log.

## Boundaries

- A recording started with the tunnel down or one that survived its restart
  gets its channel back on the next tunnel start
  ([605](../../../tasks/605-service-live-automation-workspaces-bugs.md)). Returning after a swipe from recents stops the
  orphaned channel, the buffer is lost
  ([591](../../../tasks/591-spec-kit-revision-audit.md)).
- Owner and route attribution — [attribution](attribution.md); the DNS part
  of events — [dns-trace](dns-trace.md).
- There are no saved sessions; export — [filters-and-views](filters-and-views.md).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [044F](../../../tasks/044F-per-app-traffic-profiler/spec.md) | Implemented v1.7.0 | Profiler, everything in memory |
| 2 | [044F/new-profiler](../../../tasks/044F-per-app-traffic-profiler/new-profiler.md) | ✅ Implemented, device-pending | One control row, retention window 1m/10m/1h |
| 3 | [048](../../../tasks/048-perapp-trace-attribution-gaps.md) | Done | Explicit recording, a log across all apps, time-based cleanup |
| 4 | [168](../../../tasks/168-profiler-on-commandclient-connections.md) | Implemented, device-verified | Connections from the core channel, recording in the background |
| 5 | [176](../../../tasks/176-connections-filterstate-all-consumer-side-filter.md) | Implemented, device-verified | Short connections — both phases, no duplicates |
| 6 | [219](../../../tasks/219-deep-audit-2026-07.md) | — | Ceiling 20,000, cleanup every 15 s |
| 7 | [288](../../../tasks/288-remove-per-app-trace-tab.md) | complete | The App tab and per-app sessions removed |
| 8 | [353](../../../tasks/353-profiler-kernel-timestamps.md) | ✅ Released v2.19.3 | Duration by the core's clock |
| 9 | [605](../../../tasks/605-service-live-automation-workspaces-bugs.md) | Implemented | Recording gets its channel back after a tunnel restart |
