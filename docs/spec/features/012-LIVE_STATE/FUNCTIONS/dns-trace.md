[English](dns-trace.md) · [Русский](dns-trace.ru.md)

# DNS query trace — who asked, what was answered and why it failed

The trace is part of the profiler log and is recorded only while recording is
on.

| Field | Value |
|-------|-------|
| Feature | [012-LIVE_STATE](../FEATURE.md) |
| Promises | P15, P16, P17, P18 |
| State | ✅ written from code, 2026-09-28 |

## What it does

While the profiler is recording, shows every DNS query of the device: who
asked, what was asked, what was answered (with the CNAME chain), which server
and through which channel answered, whether the answer came from the cache,
and for DNS groups — whom they polled and how it ended. Notices when DNS fails
to resolve en masse while the link is alive, and suggests what to do.

## Parameters

No settings of its own; works while the profiler is recording
([traffic-profiler](traffic-profiler.md)).

## Inputs / Outputs

**Inputs:** the core's `CommandDNS` stream — domain, query type, rcode, TTL,
answer source (`exchanged` / `cached` / `optimistic` / `refreshed` / `rejected`
/ `failed`), failure flag and reason, owner, DNS server and its type, the
server's channel, answers, group path, probes (`answered` / `timeout` /
`network_error` / `servfail` + RTT), fan-out and survival flags.

**Outputs:** `dnsResolve` / `dnsFail` events in the log; in the details —
server, server type, source, answer, group path, probes, fan-out, survival; a
`cached` badge in the row; the banner "N% of DNS queries failing while the
connection is alive — tap to fix" and the sheet "DNS queries are failing" with
the buttons "Open DNS settings", "Enable FakeIP", "Close".

## Rules and invariants

- The event domain is the one the app asked for; CNAME targets — as a separate
  chain; IP — the first A/AAAA address of the answer; for non-address answers
  the value goes into "answer". The core's answer arrives as a full record
  string — the value is taken.
- Query type — the record name (A, AAAA, CNAME, HTTPS, SVCB, SOA…); an unknown
  code — `TYPE<N>`; events are not lost because of a rare type.
- Failure is determined by the core's failure flag: some failures arrive with a
  real response code. Reason — the core text, otherwise "no response" (rcode
  `-1` — there was no reply at all), otherwise "rcode N". A failure event
  carries ⚠ "DNS exchange failed: …" and the group trace.
- The server channel is the selected node (the selector is unrolled by the
  core); empty — direct or an answer from the cache.
- Owner — from the core; no owner — "no owner", only a failure counts as an
  alarm (see [traffic-profiler](traffic-profiler.md)).
- The group trace is written only for queries through a DNS group, the fan-out
  and survival flags — only when true; on a cache hit there are no probes; late
  fan-out answers do not enter the trace.
- **DNS health.** A sliding 30 s window over the log: "degradation" if there
  are ≥ 3 failures, their share is ≥ 20 % and there were connections within the
  window. Without connections (idle) — silence. Failures older than the window
  are not counted.

## Boundaries

- DNS queries hijacked by the core do not get into connections — only here.
- Without profiler recording DNS events are not collected and the detector is
  silent.
- The full state of DNS groups, DNS and FakeIP settings — 005-DNS; the sheet
  only leads there.
- The core keeps no history: the stream starts from the moment of subscription.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [044F](../../../tasks/044F-per-app-traffic-profiler/spec.md) | Implemented | DNS in the log, attribution to the original domain, `cached` |
| 2 | [171](../../../tasks/171-ansi-strip-bare-esc-dns.md) | Implemented, device-verified | DNS was lost because of log text parsing (the path was removed later) |
| 3 | [180](../../../tasks/180-dns-query-stream.md) | ✅ DEVICE-VERIFIED | Structured DNS stream from the core with owner and CNAME |
| 4 | [183](../../../tasks/183-cleanup-stale-dns-attribution.md) | ✅ Implemented | Core log parsing and guessing heuristics removed |
| 5 | [259](../../../tasks/259-dns-direct-block-detector.md) | Implemented, then cut | One-off detector at start — replaced by §262 |
| 6 | [260](../../../tasks/260-profiler-dns-stream-reconnect.md) | Cancelled | A patch for reconnecting the DNS subscription |
| 7 | [261](../../../tasks/261-dns-stream-to-command-multiplex.md) | Open (in the header) | The DNS stream — a command of the profiler channel |
| 8 | [262](../../../tasks/262-dns-health-detector.md) | Implemented, not device-verified | DNS health detector and the solutions sheet |
| 9 | [315](../../../tasks/315-dns-group-trace-in-profiler.md) | implemented | DNS group trace in the event |
