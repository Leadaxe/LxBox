[English](data-channels.md) · [Русский](data-channels.ru.md)

# Core data channels and energy model — live data without draining the battery

Every live screen of this feature reads the core through these channels.

| Field | Value |
|-------|-------|
| Feature | [012-LIVE_STATE](../FEATURE.md) |
| Promises | P2, P3, P5 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Delivers the core's live data to the app screens over the core's built-in
control channel (without an open network port) and keeps its battery cost
minimal: data flows only where and only at the rate that the user currently
sees.

## Parameters

No user settings. Fixed modes:

| Mode | Status tick | When |
|------|-------------|------|
| NORMAL | 0.5 s | foreground, home screen |
| FAST | 0.1 s | the Statistics screen is open |
| pause | none | the app is in the background |

## Inputs / Outputs

**Inputs:** the app lifecycle; opening/closing consumer screens; START/STOP of
profiler recording; core events.

**Outputs:** four independent channels.

| Channel | Core subscriptions | Lives | Sleeps in the background |
|---------|--------------------|-------|--------------------------|
| status | `CommandStatus` with an interval | while the tunnel is up | yes |
| screens | `CommandOutbounds`, `CommandGroup`, `CommandConnections` | while at least one consumer is open (home, Statistics) | yes, the consumer counter is kept |
| profiler | `CommandConnections`, `CommandDNS` | while recording | no |
| one-off calls | `GetGroups`, `GetOutbounds`, `GetRunningConfig`, `closeConnection`, node selection etc. | on demand | no |

## Rules and invariants

- A status frequency change recreates only the status channel; groups and
  connections are not broken by it — which is why the channels are not merged.
- The status channel reconnects by itself after a break (0.5 → 8 s) while the
  tunnel is alive and the app is not in the background; the others are brought
  up explicitly.
- Return from the background: status comes up at the current frequency;
  screens — only if a consumer is still open.
- Connections arrive as deltas. The accumulator applies each one, even without
  a subscriber, and gives a new subscriber the full snapshot at once. The
  "screens" and "profiler" channels have separate accumulators.
- The core returns both live and closed (up to 5 min) connections; each
  consumer decides what to show.
- Each channel gives subscribers the last snapshot immediately on subscription;
  on tunnel stop the snapshots are reset.
- Status, groups and connections collapse to the last snapshot; DNS events do
  not collapse (each is a separate fact), on queue overflow (4096) the new ones
  are dropped.
- Groups: an empty snapshot on top of a non-empty one is noise and is ignored;
  initial groups are fetched with `GetGroups` every 0.4 s, up to 12 attempts.
  `GetGroups` / `GetOutbounds` distinguish "unavailable" from "no groups".
- The first interface start after a swipe with the tunnel alive resyncs the
  orphaned channels (consumer counter reset, NORMAL frequency, profiler
  recording is interrupted); on tunnel reconnects — it does not.

## Boundaries

- Reconnecting a subscription is the client's duty: the core does not restore
  broken subscriptions.
- The core tears the profiler channel down with the tunnel; while the channel
  has a holder, each tunnel start brings it up again
  ([605](../../../tasks/605-service-live-automation-workspaces-bugs.md)).
- Depends on OS capabilities: "foreground / background" events, process
  survival in the background.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [122F](../../../tasks/122F-commandclient-migration/spec.md) | Implemented, device-verified | Moving from the HTTP interface to the core control channel, push instead of polling |
| 2 | [123F](../../../tasks/123F-subscription-model/spec.md) | Implemented | Channel model: separate clients, two worlds of status |
| 3 | [163](../../../tasks/163-home-screen-data-model-refactor.md) | Implemented | Groups — a hybrid of push + one-off pull |
| 4 | [164](../../../tasks/164-cc-clients-energy-model.md) | Implemented, device-verified | FAST/NORMAL and sleep in the background |
| 5 | [170](../../../tasks/170-connections-accumulator-per-client-race.md) | Implemented, device-verified | A separate connection accumulator per channel |
| 6 | [176](../../../tasks/176-connections-filterstate-all-consumer-side-filter.md) | Implemented, device-verified | The core returns everything, the consumer filters |
| 7 | [185](../../../tasks/185-cold-start-cc-resync.md) | ✅ DEVICE-VERIFIED | Channel resync after a swipe |
| 8 | [193](../../../tasks/193-connections-reemit-on-subscribe.md) | ✅ Implemented, device-verify pending | What has accumulated is given to a new subscriber |
| 9 | [209](../../../tasks/209-unary-cc-via-pingclient.md) | Implemented | One-off calls through the non-sleeping channel |
| 10 | [261](../../../tasks/261-dns-stream-to-command-multiplex.md) | Open (in the header) | The DNS stream — a command in the profiler channel |
| 11 | [605](../../../tasks/605-service-live-automation-workspaces-bugs.md) | Implemented | The profiler channel is brought up again on each tunnel start |
