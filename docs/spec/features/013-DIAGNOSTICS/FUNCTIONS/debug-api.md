[English](debug-api.md) · [Русский](debug-api.ru.md)

# Debug API

| Field | Value |
|-------|-------|
| Feature | [013-DIAGNOSTICS](../FEATURE.md) |
| Promises | P12–P19 |
| State | ✅ written from code, 2026-09-28 |

## What it does

A local HTTP server on the device through which a developer on the host (via
`adb forward`) reads the entire app state and changes it without the screen:
for analysing complaints, autotests and config experiments. The full list of
routes is the contract in
[`docs/api/debug-api-reference.md`](../../../../api/debug-api-reference.md) and
in the server itself (`GET /help`).

## Parameters

| Setting | Where | Values | Default |
|---------|-------|--------|---------|
| Debug API | App Settings → Diagnostics → Developer | on/off | off |
| Port | same place | 1024..49151, otherwise an error under the field | 9269 |
| Token | same place, Copy / Regenerate | 32 hex (128 bits) | generated on first enable |
| Lock config (debug) | same place, only while the API is on | on/off | off |

Fixed values: address `127.0.0.1`; request handling deadline 30 s; request
body up to 1 MiB.

## Inputs / Outputs

**Inputs:** HTTP requests to `127.0.0.1:<port>`.
**Outputs:** JSON (`application/json; charset=utf-8`), text or a file. Writes
respond `{"ok":true,"action":"…",…}`; errors — `{"error":{"code","message"}}`.

| Group | What can be done |
|-------|------------------|
| `/ping`, `/help` | liveness check; API map (`?format=json`) — without a token |
| `/state*`, `/device`, `/pool` | read the state, storage (with the scrubber), device and versions |
| `/config*` | read the saved and the running config; `PUT /config` — replace the saved one |
| `/logs*`, `/diag/*`, `/files/*` | logs, dump, exit reasons, system log, reports, snapshots, pprof |
| `/action/*` | start/stop/reconnect the tunnel, URLTest, rebuild, network reset, etc. |
| `/rules`, `/subs`, `/nodes`, `/directions`, `/chains`, `/folders`, `/warp`, `/settings/*`, `/wifi_history`, `/backup/*` | reading and CRUD of domains via the same paths as the UI |
| `/core_reject/*`, `/profiler/*`, `/support/*` | observe and drive the startup safeguard, event recording, the support feed |

## Rules and invariants

- Order of checks: host name → token → deadline. Host not
  `127.0.0.1`/`localhost` (the port in the header is ignored, and so is case) —
  403 `invalid_host`; no exact `Authorization: Bearer <token>` — 401
  `unauthorized`; longer than 30 s — 504 `timeout`.
- Error codes are stable: 400 `bad_request`, 401, 403, 404 `not_found`, 409
  `conflict` (a precondition is missing: the tunnel is not up, etc.), 413
  `payload_too_large`, 502 `upstream_error`, 504, 500 `internal` (details — in
  the app log, not in the response).
- Enabling without a token creates a token; Regenerate makes old commands get
  401; changing the port or token restarts the server; a busy port is an error
  in the log, not an app failure.
- Turning the API off clears Lock config: otherwise there would be no way to
  lift the lock.
- Lock config: rebuilding the config from settings is silently skipped — a
  manual `PUT /config` lives until the lock is lifted.
- The keys `debug_enabled` / `debug_port` / `debug_token` cannot be written
  through `/settings/vars` (409); a backup export excludes them by default; a
  replace import that lacks them keeps the current ones.
- The storage snapshot masks the token (`***`) and subscription addresses with
  a mask, lifted with `?reveal=true`; `/config` returns secrets as is — by
  design.
- Every request is written to the app log: method, path, query, status, time;
  values of keys with `token`/`secret`/`auth`/`key` — `***`; 5xx — warning,
  everything else — debug.
- Any write accepts `?rebuild=true` — a config rebuild after the write
  (`rebuilt`, `config_bytes` or `rebuild_error` in the response).
- The server runs while the app process is alive; it comes up when the home
  screen opens.

## Boundaries

- There is no access from the network: only the device address and `adb
  forward`.
- The loopback is shared by all apps on the device — only the token protects.
- An MCP wrapper over the API (`§035F`) — cancelled, not implemented.
- There are no Clash API routes any more (§122) — 404.
- Depends on OS capabilities: the lifetime of the app process.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [031F](../../../tasks/031F-debug-api/spec.md) | ✅ Done → §043 | Local server with a token, reading, triggers, CRUD, host check |
| 2 | [043F](../../../tasks/043F-applog-per-source-quotas/spec.md) | Done | A single spec for the Debug API, logs and crashes |
| 3 | [035](../../../tasks/035-platform-interface-extras-in-debug-api.md) | ✅ Implemented (in a modified form) | Extra core callbacks; Wi-Fi not via the Debug API |
| 4 | [037](../../../tasks/037-debug-api-write-config-and-lock-rebuild.md) | ✅ Implemented | `PUT /config` and the rebuild lock |
| 5 | [147](../../../tasks/147-debug-api-warp-endpoint.md) | Implemented | `POST /warp` without the UI |
| 6 | [213](../../../tasks/213-debug-device-core-version.md) | IMPLEMENTATION | `/device` returns the core version |
| 7 | [218](../../../tasks/218-debug-help-sync.md) | DONE | `/help` matches the mounted routes |
| 8 | [238](../../../tasks/238-debug-api-channels-folders.md) | implemented | CRUD of directions and folders |
| 9 | [341](../../../tasks/341-quic-knobs-debug-api.md) | Released v2.19.2 | QUIC knobs for field A/B diagnostics |
| 10 | [346](../../../tasks/346-subs-full-crud-debug-api.md) | DEVICE-VERIFIED | Full subscription configuration via the API |
| 11 | [413](../../../tasks/413-backup-replace-keeps-debug-api.md) | Done | A replace import does not shut down the device's Debug API |
| 12 | [494](../../../tasks/494-debug-api-debts.md) | Released v2.25.0 | Debts: headless start through the safeguard, run reset, config body check |
| 13 | [520](../../../tasks/520-debug-api-warnings-keyed-by-unique-tag.md) | Released v2.25.3 | Warnings of same-named nodes are not lost |
| 14 | [035F](../../../tasks/035F-mcp-server/spec.md) | 🚫 Cancelled | An MCP server on top of the Debug API — not to be implemented |
