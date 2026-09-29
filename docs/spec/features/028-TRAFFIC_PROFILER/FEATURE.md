[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Traffic profiler — per-app connection log, attribution and DNS trace

LxBox records the network events of every app on the device — TCP/UDP
connections and DNS queries — with the owner app, the routing rule and the
sing-box node. The log lives in the Profiler tab of the Statistics screen:
filter by app, rule and outbound, grouping by domain or IP, JSON export and
the same data through the Debug API.

| Field | Value |
|-------|-------|
| Feature | 028-TRAFFIC_PROFILER |
| Type | Product feature |
| Absorbed | `§044F` |
| State | ✅ written from code, 2026-09-29 |

## Purpose

The user asks "where does this app go and how is it routed", "which app is to
blame" and "why does it not resolve". The feature answers without packet
capture or root: on an explicit START it records a log of all network events
of the device, each with its owner, rule, group chain and the physical path of
the packet, and DNS queries with the CNAME chain, the server and the failure
reason.

The feature keeps four principles:

- **Recording is explicit.** Without START nothing accumulates and there is no
  core subscription; a started recording lives until STOP or process death.
- **The owner comes from the core.** The app behind a connection or a DNS
  query is named by the core; the client guesses nothing. An event without an
  owner is visible and marked, not hidden.
- **The observer is inclusive.** An event with an unknown owner or a rare record
  type is not dropped — it enters the log with a confidence level.
- **Everything is in memory.** The log is a 1 min / 10 min / 1 h window with a
  ceiling of 20,000 events; an app restart erases it.

## Promises

- **P1. Recording — only on an explicit START.** Without recording, events do
  not accumulate. **Witness:** unit "recording off → events ignored".
  **Mutation:** auto-start of recording.
- **P2. START clears the previous log, STOP freezes it.** After STOP the list
  stays until the next START, which begins from zero. `no witness`.
- **P3. The retention window is selectable and remembered.** 1 min / 10 min /
  1 h, default 10 min, survives a restart. **Witness:** unit "profiler
  retention — default + round-trip + persist". **Mutation:** the window is a
  hard-coded constant.
- **P4. Buffer quotas.** Events older than the window are purged every 15 s;
  beyond 20,000 the oldest are evicted; the ring of unowned events holds 50.
  `no witness`.
- **P5. A short connection is seen whole and once.** A connection opened and
  closed between ticks gives both phases; a closed one that keeps arriving in
  snapshots for another 5 min is closed exactly once. **Witness:** units
  "short conn with closedAt>0 at once → both phases", "the same closed conn
  for 2 ticks → ONE close". **Mutation:** the consumer receives only live
  connections.
- **P6. Connection time is by the core's clock.** Duration is computed from
  the core's timestamps, a sentinel does not turn into the year 1970; a
  "probable RST" is a close in under 1 s with no bytes. **Witness:** units
  "kernel timestamps: duration from createdAt/closedAt", "sentinel closedAt=1
  does not turn into 1970", "TCP RST early flagged on close". **Mutation:**
  duration from the moment the snapshot arrived.
- **P7. The owner comes from the core; no owner is visible.** The app package
  is taken from the core's data as is (a UID suffix or a list of several
  packages does not break attribution); an event without an owner is marked
  `unattributed` and "no owner". **Witness:** units "UID-suffixed package name → verified",
  "multi-package UID → verified", "tcp conn without owner → unattributed",
  "DNS fail with HTTPS record type — unattributed if no owner". **Mutation:**
  an event without an owner is dropped.
- **P8. The unattributed alarm — only on failures.** More than 5 failed events
  without an owner (DNS failure, TCP/UDP without an owner) within 30 s light
  the banner; a successful DNS without an owner is normal. **Witness:** units
  "unattributedBannerActive flips when many unattributed events arrive",
  "successful unattributed DNS resolves do NOT light the banner".
  **Mutation:** a successful DNS without an owner counts as an alarm.
- **P9. One routing line for connections and the profiler.** On the left — how
  the router chose (`rule ⇒ groups`), to the right of `:` — the physical path
  of the packet; an empty rule — `final`; the group chain and the detour are
  carried separately. **Witness:** units "§204 routingLineOf 1:1 Conn ↔
  Event", "chains and detours are carried SEPARATELY", "routingLine: full
  trace". **Mutation:** detour glued into the group chain.
- **P10. Filter axes are independent.** Within an axis — OR, between axes —
  AND; Protocol catches the family (DNS — resolve and failure, TCP — open and
  close); "Unattributed" — OR with the selected packages; an empty rule is
  caught as `final`; Outbound — any link of the chain or detour. **Witness:**
  units "kind axis by family: DNS catches resolve+fail", "unattributed — OR
  with the selected apps", "rule axis: an empty rule is caught as final",
  "outbound axis: catches a detour link", "rule + outbound are orthogonal".
  **Mutation:** axes joined by OR.
- **P11. The filter lives for the whole app session.** Switching tabs and
  leaving statistics do not reset it; reset — "Reset all" or a restart.
  **Witness:** units "the filter survives unmount/remount", "clearAll resets
  the session filter". **Mutation:** the filter is a field of the screen.
- **P12. Aggregates are honest, export is complete.** Events without an owner
  do not enter the by-domain and by-IP summaries; the export contains the
  event list and recomputed summaries. **Witness:** units "serialises the
  list + recomputed aggregates", "unattributed events do not pollute
  aggregates". **Mutation:** unowned events mixed into the summary.
- **P13. DNS is attributed to what was asked.** The event carries the original
  domain, the CNAME chain separately and the first answer address as the IP;
  the core's answer is a full record string, the value is taken. **Witness:**
  units "DNS chain attribution: CNAME hops in answers, ip = final A", "rdata
  as a FULL RR string → take the value". **Mutation:** the event domain = the
  final CNAME target.
- **P14. A DNS failure is an event with a reason; a rare type is not a loss.**
  The core's failure flag decides, not the response code; an unknown record
  type gives `TYPE<N>`. **Witness:** units "DNS fail produces dnsTimeout
  issue", "HTTPS record DNS resolve is parsed with record_type=HTTPS", "SOA
  record (NXDOMAIN) is parsed without IP". **Mutation:** failure by the
  response code.
- **P15. DNS group trace — only on group queries.** The group path, probes,
  fan-out and survival mode are visible in the details; ordinary queries have
  none of these fields; a failure carries the trace too. **Witness:** units
  "fan-out: path, probes and the fanned flag", "NOT a group query → no trace
  keys", "dnsFail carries the trace too". **Mutation:** empty trace fields on
  every event.
- **P16. DNS degradation is recognised while the link is alive.** The banner
  — at a failure share ≥ 20 %, at least 3 failures within 30 s and only if
  there were connections in the same window. **Witness:** units "3 fails of
  10 + activity → unhealthy", "5 fails 100%, but NO conn activity →
  healthy", "old fails (>30 s ago) are not counted". **Mutation:** the
  activity gate removed.
- **P17. The Debug API sees what the screen sees.** The `/profiler/live*`
  routes read the same log, start and stop the same recording, and an event
  in JSON carries the server, the source and the group trace. `no witness`.

## Controlled parameters

| Setting | Values | Default | Where |
|---------|--------|---------|-------|
| Recording | START / STOP | stopped | Profiler tab header; `/profiler/live/start` · `stop` |
| Retention window ("Keep …") | 1m / 10m / 1h | 10m | the `⏱` button in the control row; part of the backup |
| Display | Pause / Resume | live | control row, stream mode only |
| Grouping | Event stream / Group by Domain / Group by IP | stream | control row |
| Filter | axes Protocol, App, Rule, Outbound + search | empty | the "Filter events" window; the whole app session |

Fixed values: log ceiling 20,000 events; ring of unowned events — 50; window
cleanup every 15 s; unattributed alarm threshold — more than 5 in 30 s; DNS
detector — 30 s window, share ≥ 20 %, at least 3 failures; "probable RST" —
under 1 s and 0 bytes; list redraw at most once per 0.7 s; Debug API snapshot
— 1…600 s, default 60.

**Contract with the core.** The feature emits no config keys. It consumes the
core's profiler channel ([012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md)):
`CommandConnections` (deltas; `chain`, the `detour` tail, outbound type,
owner, `createdAt`/`closedAt`) and `CommandDNS` (domain, type, rcode, answer
source, failure flag and reason, owner, server and its type, channel, answers,
group path, probes, fan-out, survival).

## Inputs / Outputs

**Inputs:** START/STOP (the tab or the Debug API); connection snapshots and
DNS events of the profiler channel, only while recording; gestures — pause,
retention window, grouping, filter, search from the details, export.

**Outputs:** events `tcpOpen` / `tcpClose` / `udpOpen` / `dnsResolve` /
`dnsFail`; the header "Recording system-wide events · time · N events" /
"Not recording"; the `Live` chip on the home screen and ⚠ on the tab on an
alarm; the event and aggregate detail sheets; the banners "N unattributed
events / 30s" and "N% of DNS queries failing…" with the "DNS queries are
failing" sheet; export "Share N events (JSON)" / "Copy JSON to clipboard";
`/profiler/live*` responses.

## Data flow

```
START ──► subscribe to the profiler channel (does not sleep in the background)
core ──CommandConnections (deltas)──► snapshot diff ──► open/close events
     ──CommandDNS──► resolve/fail events (+ group trace)
events ──► log (window · 20,000) ──► stream / by-domain and by-IP summaries ──► screen
       ├─► unowned ring (50) ──► unattributed alarm ──► banner, ⚠
       ├─► DNS health detector (30 s) ──► banner ──► solutions sheet → 005-DNS
       └─► SSE ──► /profiler/live/stream; snapshot ──► /profiler/live
STOP ──► unsubscribe; the log is frozen until the next START
```

## Rules and guarantees

- The profiler channel does not sleep when the app is backgrounded: a started
  recording continues in the background
  ([012-LIVE_STATE · P3](../012-LIVE_STATE/FEATURE.md#promises)).
- Every event carries an owner confidence level: `verified` (the core named
  the package) or `unattributed`; the levels `secondary` and `inferred` are
  dormant — not assigned by the current code, kept for reading old exports.
- Pause freezes only the display; recording and the log go on.
- Summaries are computed from the full log; search applies to the summary rows.
- The redraw lags behind the stream by at most 0.7 s; events are not lost.
- A tunnel stop touches neither the filter nor the log.

## Boundaries

- Data channels, their energy model and reconnection — 012-LIVE_STATE. The
  profiler channel does not reconnect by itself: a recording started with the
  tunnel down or one that survived its restart receives no events, although
  the `Live` chip is lit (task candidate,
  [591](../../tasks/591-spec-kit-revision-audit.md)).
- Live connections, statistics, status — 012-LIVE_STATE. The rule in the log
  is the core's string, not a name from the 004-ROUTING catalog; empty —
  `final`.
- DNS settings, groups, FakeIP — 005-DNS; the "DNS queries are failing" sheet
  only leads there.
- Transport, token and the Debug API reference — 027-DEBUG_API; here only the
  `/profiler/*` routes.
- Per-app sessions, the App tab and saved sessions were removed (§288); one
  app is analysed with the App filter.
- L4 only: domain, IP, port; no HTTP headers, URLs or per-domain latency.
- There is no "record only while the tab is open" mode, and it is not
  planned (owner decision 2026-09-29, audit [591](../../tasks/591-spec-kit-revision-audit.md)): recording runs from START to STOP.
- Depends on OS capabilities: the traffic owner; the OS may not name it for
  part of the connections.

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Recording and buffer | Starts and stops recording, keeps the log within the window and under the ceiling, turns connection snapshots into open and close events by the core's clock. | P1–P6 | [recording.md](FUNCTIONS/recording.md) |
| Attribution | Attributes an event to an app, a rule and a route from the core's data, shows the confidence level and warns about unowned events. | P7–P9 | [attribution.md](FUNCTIONS/attribution.md) |
| Filters and views | Filters the log by protocol, app, rule, outbound and text, groups it by domain or IP and exports it to JSON. | P10–P12 | [filters-and-views.md](FUNCTIONS/filters-and-views.md) |
| DNS query trace | Shows each DNS query with its owner, CNAME chain, server and failure reason, traces DNS groups and warns when DNS degrades while the link is alive. | P13–P16 | [dns-trace.md](FUNCTIONS/dns-trace.md) |
| Debug API access | Serves the log, the stream and the recording state on the `/profiler/live*` routes and controls recording from outside. | P17 | [debug-api-access.md](FUNCTIONS/debug-api-access.md) |

## Related features

- [004-ROUTING](../004-ROUTING/FEATURE.md) — the rules and Directions whose
  names the core returns in events and by which the log is filtered.
- [005-DNS](../005-DNS/FEATURE.md) — DNS groups, DNS and FakeIP settings, where
  the "DNS queries are failing" sheet leads.
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — the profiler channel and
  energy model, live connections with the same routing line, the `Live` chip.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — the app and core logs
  next to the profiler; the "Forward sing-box logs" hint.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — the
  retention window is part of the backup.
- [027-DEBUG_API](../027-DEBUG_API/FEATURE.md) — the Debug API transport and
  reference where the `/profiler/*` routes live.

## Maintenance notes

- The core keeps closed connections for 5 min and sends them every tick: a
  consumer that does not remember what it has already closed produces
  duplicates (§176).
- DNS `rdata` is the full record string (§180); core timestamps before
  2000-01-01 are "no data" sentinels, not dates (§353).
- The event's `extra` must serialise to JSON, otherwise the Debug API loses the
  server, the source and the group trace that the screen shows (§315).
- The "DNS / router events off" hint above the log is a leftover of core log
  parsing; since §180 DNS comes as a structured stream and does not depend on
  "Forward sing-box logs" (task candidate, 591).
- Export uploads the whole log, not the filtered list, although the serialiser
  is meant for the filtered one (task candidate, 591).
