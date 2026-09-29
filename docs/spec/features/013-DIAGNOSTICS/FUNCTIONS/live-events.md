[English](live-events.md) · [Русский](live-events.ru.md)

# Live events

| Field | Value |
|-------|-------|
| Feature | [013-DIAGNOSTICS](../FEATURE.md) |
| Promises | P20, P21 |
| State | ✅ written from code, 2026-09-28 |

## What it does

On an explicit command records all network events of the device — opening
and closing of TCP/UDP connections, DNS answers and failures — with the owner
app and the routing chain of each event. Answers the question "what is going
on on the device right now at all" when it is unknown which app is to blame.
The **Profiler** tab of the Stats screen and the `/profiler/live*` routes of
the Debug API.

## Parameters

| Setting | Where | Values | Default |
|---------|-------|--------|---------|
| Live retention window | Profiler → history icon | 1m / 10m / 1h | 10m |

Fixed values:

| What | Value |
|------|-------|
| Buffer ceiling | 20 000 events |
| Buffer of events without an owner | 50 |
| "No owner" banner | more than 5 in 30 s |
| "DNS failing" banner | 30 s window, failures ≥ 20 % and ≥ 3, while the connection is alive |
| List redraw | no more than once per 700 ms |

## Inputs / Outputs

**Inputs:** START/STOP in the tab header or `POST /profiler/live/start|stop`;
the core's connection stream and DNS query stream.
**Outputs:**
- the header "Recording system-wide events · mm:ss · N events" / "Not
  recording";
- the shared event browser (Live / Aggregated, filter by apps, types, text;
  pause; event details);
- export "Share N events (JSON)" / "Copy JSON to clipboard";
- banners "N unattributed events / 30s …", "N% of DNS queries failing while
  the connection is alive — tap to fix" (a hint sheet with "Open DNS settings"
  and "Enable FakeIP"), "DNS / router events off" while core log forwarding is
  off;
- Debug API: `/profiler/live?seconds=N` (default 60), `/profiler/live/state`,
  `/profiler/live/stream` (SSE), `/profiler/live/unattributed`.

## Rules and invariants

- Without START nothing is recorded or subscribed; STOP freezes the buffer
  (the list stays), a new START clears it.
- Recording continues when leaving the tab and when the app is minimised —
  until STOP or process death.
- The retention window changes on the fly and is persisted; old events are
  trimmed at the next cleanup. A buffer over the ceiling loses the oldest.
- Each event carries a confidence level for the owner (`verified`,
  `secondary`, `inferred`, `unattributed`) and a routing chain
  (`routingLine`, `outboundChain`, `detourChain`).
- Successful DNS answers without an owner do not light the "no owner" banner —
  only failures and connections without an owner do.
- "DNS failing" does not light up when idle: without connection activity in
  the window, failures are not considered a breakage.
- The tab filter lives for the whole app session and survives navigation
  between screens.
- The redraw lags behind the stream by no more than 700 ms; events are not
  lost meanwhile — they accumulate in the buffer.

## Boundaries

- The connection list, traffic, statistics and status — 012-LIVE_STATE.
- There are no historical sessions per individual app (dropped, §288):
  analysing one app is done with the filter.
- Depends on OS capabilities: determining the owner app of a connection (on
  some OS versions it does not keep up with short connections).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [044F](../../../tasks/044F-per-app-traffic-profiler/spec.md) | Implemented | Traffic profiler: recording, export, API |
| 2 | [160](../../../tasks/160-perapp-trace-live-aggregated-redesign.md) | Done | Shared Live / Aggregated browser with a filter |
| 3 | [168](../../../tasks/168-profiler-on-commandclient-connections.md) | Implemented (device-verified) | Connections — from the core stream |
| 4 | [177](../../../tasks/177-unattributed-banner-dns-fail-only.md) | Implemented (A+B) | The "no owner" banner — only on failures |
| 5 | [180](../../../tasks/180-dns-query-stream.md) | ✅ DEVICE-VERIFIED | DNS events — a structured core stream, not the log |
| 6 | [244](../../../tasks/244-profiler-filter-session-lifetime.md) | implemented | The filter survives navigation |
| 7 | [260](../../../tasks/260-profiler-dns-stream-reconnect.md) | — | Restoring the DNS subscription after a drop |
| 8 | [262](../../../tasks/262-dns-health-detector.md) | Implemented (not device-verified) | The "DNS failing" banner with thresholds and an activity gate |
| 9 | [353](../../../tasks/353-profiler-kernel-timestamps.md) | ✅ Released v2.19.3 | Duration of short connections — by the core clock |
