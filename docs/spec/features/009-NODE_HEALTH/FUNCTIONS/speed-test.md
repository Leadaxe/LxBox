[English](speed-test.md) · [Русский](speed-test.ru.md)

# Speed test — latency, download and upload of the current connection

The Speed Test screen measures ping, download and upload speed of the
device's current path, through the VPN tunnel when it is up.

| Field | Value |
|------|----------|
| Feature | [009-NODE_HEALTH](../FEATURE.md) |
| Promises | P17 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The Speed Test screen (from the side menu) measures latency, download and
upload speed of the device's current path without leaving the app: through
the tunnel if the VPN is up, otherwise directly. It shows what the test went
through and keeps the history of the session's runs.

## Parameters

| Parameter | Values | Default |
|-----------|--------|---------|
| Server | 10 template servers: Cloudflare, Hostkey (Moscow / Frankfurt / Amsterdam / Helsinki / New York), Selectel (RU), Tele2 (EU), OVH (France), thinkbroadband (UK) | Cloudflare |
| Streams | 1 / 4 / 10 (template) | 4 (template) |

The server choice is remembered by its identifier in the template, not by
position; an unknown one — the first server.

## Inputs / Outputs

**Inputs:** server addresses (`ping_url`, `download_url`, `upload_url`,
`upload_method`); tunnel state and the active node.

**Outputs:** Ping (ms or "Failed"), Download and Upload (Mbit/s), a progress
bar and phase status, the caption "Via: <group/node>" or "Direct (no VPN)",
the "Session History".

## Rules and invariants

- **Ping:** 5 sequential HTTP GETs to `ping_url` (otherwise
  `download_url`), 5 s timeout per attempt; replies with status < 400 are
  counted. With 3+ successes — the mean without the minimum and maximum. None —
  "Failed".
- **Download:** N parallel GET streams to `download_url`, overall limit
  15 s; the speed on screen is updated every 0.5 s. If the chosen server gave
  0, the other template servers are tried in turn.
- **Upload:** 2 parallel streams of 5 MB each with the `upload_method` method
  (POST or PUT, default PUT) to `upload_url`, when absent — to
  `download_url`; overall limit 30 s. The measurement is the volume of sent
  bodies over time, without accounting for the server reply.
- History — up to 10 runs in memory, until the app restarts.
- A running test cannot be stopped: the button is inactive until the run ends.
- A phase error — "Error: <reason>" in the status line.

## Boundaries

- The test does not address a node and does not switch it: the current path
  is measured.
- Speed on the home screen — [012-LIVE_STATE](../../012-LIVE_STATE/FEATURE.md).

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [015F](../../../tasks/015F-speed-test/spec.md) | Implemented | Three-phase test, streams, history, fallback server |
