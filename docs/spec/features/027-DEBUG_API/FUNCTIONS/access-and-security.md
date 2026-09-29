[English](access-and-security.md) · [Русский](access-and-security.ru.md)

# Access and security — the gate in front of root access

The server is off by default, listens only on the device's own address and
answers only to a 128-bit token; everything behind that gate is deliberately
open.

| Field | Value |
|-------|-------|
| Feature | [027-DEBUG_API](../FEATURE.md) |
| Promises | P1–P8 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Decides who gets to talk to the Debug API and what a request goes through
before a handler sees it: the enable toggle, the loopback bind, the port, the
bearer token, the host-name check, the request deadline and the body limit.
It also keeps the secret from leaking by accident — masks it in copyable
snapshots and in the request log — and makes sure the API cannot lock the
developer out of itself.

## Parameters

| Setting | Where | Values | Default |
|---------|-------|--------|---------|
| Debug API | App Settings → Diagnostics → Developer | on/off | off |
| Port | same place | 1024..49151, otherwise an error under the field; an out-of-range stored value reads as 9269 | 9269 |
| Token | same place, Copy / Regenerate | 32 hex (128 bits, secure random) | generated on first enable |
| Lock config (debug) | same place, only while the API is on | on/off | off |

Fixed values: address `127.0.0.1`; request handling deadline 30 s; request
body up to 1 MiB (a config of 70–300 KB fits, CRUD bodies are under 4 KB);
paths without a token — `/ping`, `/help`.

## Inputs / Outputs

**Inputs:** HTTP requests to `127.0.0.1:<port>`; the `Host` and
`Authorization` headers; the toggle, port and token from App Settings.

**Outputs:** the request passed on to the route, or an error envelope: 403
`invalid_host`, 401 `unauthorized`, 413 `payload_too_large`, 504 `timeout`,
500 `internal`. Lines in the app log: `Debug API: listening on
127.0.0.1:<port>`, `Debug API: stopped`, `Debug API: bind failed on :<port>`,
`Debug API: token empty — refusing to start`; one line per request
`[debug-api] <method> <path>?<query> → <status> <ms>ms`.

## Rules and invariants

- **Order of checks: host name → token → deadline → route.** Host not
  `127.0.0.1` / `localhost` (the port in the header and case are ignored) —
  403 even with a valid token and even on `/ping`: this is the defence against
  DNS rebinding from a browser. No exact `Authorization: Bearer <token>` — 401;
  the scheme is case-sensitive. Longer than 30 s — 504; the handler is
  abandoned, the server keeps serving.
- **Fail-closed.** An empty token refuses to start the server, and if a server
  somehow runs with one, every protected route is 401. Enabling without a
  token creates one; Regenerate makes old commands get 401 at once.
- **Restart on every change.** Changing the toggle, the port or the token stops
  the old listener (open connections are cut) and binds again; a busy port is
  an error in the app log, the app itself keeps working. The server also comes
  up when the home screen opens, so a script that starts the app can wait on
  `/ping`.
- **The API cannot lock itself out.** `debug_enabled`, `debug_port` and
  `debug_token` are refused through `PUT`/`DELETE /settings/vars/{key}` (409
  "managed via App Settings UI only"); a backup export leaves them out unless
  "Debug API config" is ticked; a replace import that lacks them keeps the
  device's own values. Turning the API off clears Lock config, so a pinned
  config never survives without a way to unpin it.
- **File routes stay in their directories.** `/files/local` serves only a
  whitelist of names; `/files/crash`, `/files/oom` and `&file=` reject `..`,
  absolute paths and separators — 400/404, never a file outside the archive.
- **Masking is a convenience, not a boundary.** `/state/storage` returns
  `debug_token` as `***`, subscription URLs as `scheme://host/***`, a single
  server's body as its byte length and folder members as a count; `/state/subs`
  and `/subs/{id}` unmask with `?reveal=true`; `/nodes/link` returns the URI
  only with `?reveal=true`. `/config`, `/backup/export`, `warp_account` and
  `masque_account` are returned raw by design — the same data is one route
  away, and masking would only slow diagnostics down.
- **The request log does not carry secrets.** Values of query keys containing
  `token`, `secret`, `auth` or the key `key` are written as `***`; 5xx lines
  are warnings, everything else debug. Requests rejected before the pipeline
  (oversized body) are logged too.
- **Errors are typed.** A classified failure becomes its envelope; anything
  else is 500 `internal` with a generic message, and the stack trace goes to
  the app log only.

## Boundaries

- There is no access from the network: only the device address and `adb
  forward`. The loopback is shared by all apps on the device — only the token
  protects there. Depends on OS capabilities: the lifetime of the app process.
- No rate limiting, no token expiry, no per-route permissions: one token is
  root.
- An MCP wrapper over the API (`§035F`) — cancelled, not implemented.
- The audit boundary is the gate (default-off, bind, token, host); what is
  visible behind it is not a finding.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [031F](../../../tasks/031F-debug-api/spec.md) | ✅ Done → §043 | Local server with a token, loopback bind, host check, error envelope |
| 2 | [043F](../../../tasks/043F-applog-per-source-quotas/spec.md) | Done | A single spec for the Debug API, logs and crashes |
| 3 | [037](../../../tasks/037-debug-api-write-config-and-lock-rebuild.md) | ✅ Implemented | Lock config; turning the API off unlocks |
| 4 | [219](../../../tasks/219-deep-audit-2026-07.md) | Done (audit) | Root access by design: the scrubber is not a security boundary |
| 5 | [316](../../../tasks/316-kernel-crash-reports-access.md) | Device-verified | Whitelist and traversal checks on the file routes |
| 6 | [413](../../../tasks/413-backup-replace-keeps-debug-api.md) | Done | A replace import does not shut down the device's Debug API |
| 7 | [035F](../../../tasks/035F-mcp-server/spec.md) | 🚫 Cancelled | An MCP server on top of the Debug API — not to be implemented |
