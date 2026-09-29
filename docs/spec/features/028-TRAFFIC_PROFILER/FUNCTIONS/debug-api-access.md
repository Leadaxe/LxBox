[English](debug-api-access.md) · [Русский](debug-api-access.ru.md)

# Debug API access — the log, the stream and recording on the `/profiler/*` routes

The same log and recording as on the Profiler tab are available from a
computer over HTTP through the Debug API.

| Field | Value |
|-------|-------|
| Feature | [028-TRAFFIC_PROFILER](../FEATURE.md) |
| Promises | P17 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Lets the profiler log be taken and the recording controlled without the
screen: from `curl`, a script or an agent on a computer. The routes read the
same buffer and drive the same recording as the tab: a start over the API is
seen on the screen as "Recording…", a start on the screen is seen in
`/profiler/live/state`.

## Parameters

| Route | Method | Response |
|-------|--------|----------|
| `/profiler/live/start` | POST | `{ok, recording: true, started_at}`; a repeated call does nothing |
| `/profiler/live/stop` | POST | `{ok, recording: false}`; a repeated call does nothing |
| `/profiler/live/state` | GET | `{recording, started_at, buffer_count, unattributed_count, banner_active}` |
| `/profiler/live?seconds=N` | GET | `{window_seconds, count, events}` — events of the last N s (1…600, default 60) |
| `/profiler/live/stream` | GET | SSE `event: traffic_event` with the event in `data` |
| `/profiler/live/unattributed` | GET | `{count, recent_count_30s, banner_active, events}` — the unowned ring |

## Inputs / Outputs

**Inputs:** HTTP requests with the Debug API token ([027-DEBUG_API](../../027-DEBUG_API/FEATURE.md)).

**Outputs:** event JSON in the same form as the export: `ts`, `kind`,
`domain`, `cname_chain`, `ip`, `port`, `outbound_chain`, `detour_chain`,
`up_bytes`, `down_bytes`, `duration_ms`, `process`, `network`, `rule`,
`confidence`, `matched_via`, `shown_because`, `dns_record_type`, `issues`,
`extra` (server, server type, source, group trace).

## Rules and invariants

- A wrong method — a bad request error; an unknown path under `/profiler/` —
  "not found". The old session routes (`/profiler/start`, `/stop`, `/active`,
  `/sessions`, `/session/<id>`, `/stream`, `/secondary-packages`) were
  removed (§288).
- Subscribing to the stream without recording is safe but empty: events flow
  only after a start.
- `unattributed_count` and `banner_active` count only failures within 30 s,
  like the banner on the screen; the ring's `events` return everything
  without an owner.
- The SSE stream has no resumption by `Last-Event-ID`: a dropped client
  subscribes again and continues from the current moment.

## Boundaries

- Transport, token, enabling — 027-DEBUG_API; all routes — its
  [route map](../../027-DEBUG_API/FUNCTIONS/route-map.md) and the
  [Debug API reference](../../../../api/debug-api-reference.md).
- The retention window, filter and grouping are not controlled over the API.
- The snapshot is limited to 600 s regardless of the retention window.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [044F](../../../tasks/044F-per-app-traffic-profiler/spec.md) | Implemented v1.7.0 | Profiler routes in the Debug API |
| 2 | [048](../../../tasks/048-perapp-trace-attribution-gaps.md) | Done | `/profiler/live*`: snapshot, stream, unowned ring |
| 3 | [288](../../../tasks/288-remove-per-app-trace-tab.md) | complete | Session routes removed |
| 4 | [315](../../../tasks/315-dns-group-trace-in-profiler.md) | implemented | `extra` is serialised — the API sees the server and the group trace |
