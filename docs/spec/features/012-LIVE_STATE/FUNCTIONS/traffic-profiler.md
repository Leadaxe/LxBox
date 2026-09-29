[English](traffic-profiler.md) · [Русский](traffic-profiler.ru.md)

# Traffic profiler (per app)

| Field | Value |
|-------|-------|
| Feature | [012-LIVE_STATE](../FEATURE.md) |
| Promises | P9, P10, P11, P12, P13, P14 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The Profiler tab of the Statistics screen: on an explicit command it records a
log of all of the device's network events — opening and closing of TCP/UDP
connections, DNS resolves and their failures — with the owner app, rule and
route. Answers "where does this app go and how is it routed" and "what is
going on in the network at all" without choosing an app in advance.

## Parameters

| Knob | Values | Default |
|------|--------|---------|
| Recording | START / STOP | stopped |
| Retention window ("Keep …") | 1m / 10m / 1h | 10m; saved, part of the backup |
| Display | Pause / Resume (freezes the list, recording continues) | live |
| Grouping | stream / by Domain / by IP | stream |
| Filter | Protocol: DNS, TCP, UDP · App: seen packages, "Unattributed (no owner)", "Add app from full list" · Rule · Outbound · search by domain/IP/app | empty |

## Inputs / Outputs

**Inputs:** connection snapshots and DNS events of the profiler channel (see
[data-channels](data-channels.md)), only while recording.

**Outputs:**
- events `tcpOpen` / `tcpClose` / `udpOpen` / `dnsResolve` / `dnsFail`: time,
  app, domain, IP, port, network, rule, group chain, detour tail, outbound
  type, ↑/↓, duration (on close), problem flags;
- the header "Recording system-wide events · time · N events" / "Not
  recording"; the `Live` chip on the home screen; ⚠ in the tab title on an
  unattributed alarm;
- the event sheet (routing line, app with icon and name, fields are copyable,
  domain/IP/package — into the search); the aggregate sheet (summary + all
  connections for the key);
- export "Share N events (JSON)" / "Copy JSON to clipboard".

## Rules and invariants

- **Recording is explicit and long.** It starts only on START; continues when
  leaving the tab and backgrounding the app; STOP freezes the log until the
  next START, which clears it. Without recording, events do not accumulate.
- **Window and ceiling.** Events older than the window are purged every 15 s;
  beyond 20,000 — the oldest are evicted. A window change takes effect at once.
- **Two connection phases.** A new connection gives an open event; one that
  disappeared or was marked closed by the core — a close event. A short
  connection that opened and closed between snapshots gives both phases; a
  repeat of an already closed connection in later snapshots gives no
  duplicates.
- **Core clock.** Start and end are taken from the core's timestamps (values
  before 2000-01-01 — "no data", then the arrival time); a negative duration is
  not shown.
- **Probable RST.** TCP that closed in under 1 s without a single byte is
  marked ⚠ "likely RST / blocked" — a heuristic, false positives are possible.
- **Attribution.** The owner is the package from the core's data, otherwise
  the process path; a suffix like `(10364)` is stripped. No owner — a "no
  owner" event, it is visible in the log and counted by the "Unattributed"
  filter.
- **Unattributed alarm.** More than 5 failed events without an owner (DNS
  failure, TCP/UDP without an owner) within 30 s → the banner "N unattributed
  events / 30s" and ⚠ on the tab. A successful DNS without an owner is normal,
  not an alarm.
- **Grouping.** By domain / by IP — counters, ports, volume; events without an
  owner do not enter aggregates.
- **Filter.** Within an axis — OR, between axes — AND; "Unattributed" — OR with
  the selected packages; Protocol catches the family (DNS — both resolves and
  failures; TCP — open and close); Outbound — any link of the chain or detour.
  Active counter — "Filter (N)". The filter lives for the whole app session,
  is not reset by a tunnel stop; reset — "Reset all".
- **Export** — the whole log of the current snapshot with recomputed
  aggregates.
- Everything is in memory: an app restart erases the log.
- Redraw — at most once per 0.7 s; events are not lost in the meantime.

## Boundaries

- Per-app sessions, the App tab and saved sessions were removed: only the
  shared log with an app filter.
- The DNS part of events — [dns-trace](dns-trace.md).
- Serving the log through the Debug API — 013-DIAGNOSTICS.
- The owner is determined by the core; the OS may not provide it for part of
  the traffic.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [044F](../../../tasks/044F-per-app-traffic-profiler/spec.md) | Implemented v1.7.0 | Per-app profiler, everything in memory |
| 2 | [044F/new-profiler](../../../tasks/044F-per-app-traffic-profiler/new-profiler.md) | ✅ Implemented, device-pending | One control row, filter window, retention window 1m/10m/1h |
| 3 | [048](../../../tasks/048-perapp-trace-attribution-gaps.md) | Done | Log across all apps, confidence levels, banner |
| 4 | [160](../../../tasks/160-perapp-trace-live-aggregated-redesign.md) | Done, v2.4.1 | Stream / aggregates, details sheets |
| 5 | [168](../../../tasks/168-profiler-on-commandclient-connections.md) | Implemented, device-verified | Connections from the core channel, recording in the background |
| 6 | [176](../../../tasks/176-connections-filterstate-all-consumer-side-filter.md) | Implemented, device-verified | Short connections — both phases, no duplicates |
| 7 | [177](../../../tasks/177-unattributed-banner-dns-fail-only.md) | Implemented (A+B) | Banner only on failures |
| 8 | [230](../../../tasks/230-profiler-filter-rule-outbound.md) | In implementation | Rule and Outbound axes, visible search |
| 9 | [244](../../../tasks/244-profiler-filter-session-lifetime.md) | Implemented | The filter survives navigation |
| 10 | [288](../../../tasks/288-remove-per-app-trace-tab.md) | complete | App tab and per-app sessions removed |
| 11 | [353](../../../tasks/353-profiler-kernel-timestamps.md) | ✅ Released v2.19.3 | Duration by the core's clock |
