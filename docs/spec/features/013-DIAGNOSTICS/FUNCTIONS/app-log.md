[English](app-log.md) · [Русский](app-log.ru.md)

# App log

| Field | Value |
|-------|-------|
| Feature | [013-DIAGNOSTICS](../FEATURE.md) |
| Promises | P1, P2, P3 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Keeps app messages and core lines in one log with two independent sources
(`app`, `core`), shows them on the Log tab of the Debug screen and exposes
them outward — to the dump and to the Debug API. Warnings and errors are
persisted to disk and survive a restart and a process crash: you can see what
the app was doing before it died.

## Parameters

No settings of its own. Fixed values:

| What | `app` | `core` |
|------|-------|--------|
| Entries in memory | 300 | 500 |
| Persisted to disk | warning, error | warning, error |
| File ceiling | 200 lines / 64 KB | 200 lines / 64 KB |

Entry levels: `debug`, `info`, `warning`, `error`.

## Inputs / Outputs

**Inputs:** app messages (including Debug API request log lines); core lines —
see [core log](core-log.md); persisted entries of the previous session.
**Outputs:** the Log tab (source filter All / Core / App, level chips,
case-insensitive text search, Copy log, Clear); the `debug_log` field of the
dump; `GET /logs`, `/logs/app`, `/logs/core`, `POST /logs/clear`, `GET
/diag/applog`.

## Rules and invariants

- Each source has its own quota: overflow evicts the oldest entry of that
  source only.
- The mixed view is a merge by time, newest first; a single-source view is
  not merged.
- Empty and whitespace-only messages are not recorded; the text is trimmed at
  the edges.
- Only warning and error of the current session go to disk; after a restart
  they are loaded marked "↑ prev session" (italic, `prev_session: true` in the
  dump and `/diag/applog`). Only entries of the new session go into the file
  again — as soon as the first warning appears in it, the disk holds that
  session.
- If the very first persisted line is larger than 64 KB, it is written anyway:
  an empty file is worse than a slightly exceeded one.
- A broken line of the persisted file is skipped, the rest are read.
- Clear clears both sources in memory and on disk; `POST
  /logs/clear?source=…` — only one.
- Debug API: `limit` 1..1000 (default 200), `source=app|core`, `q` — a
  case-insensitive substring, `level` — a comma-separated list; an unknown
  source or level — 400. Filters combine with AND.
- `GET /diag/applog?prev=true|false|all` — only the previous session, only the
  current one, or everything.
- The screen refreshes no more than ~60 times per second, even with a flood of
  hundreds of core lines.

## Boundaries

- There are no configurable quotas and no separate per-source tabs — by
  design.
- There is no streaming log output (SSE/WebSocket) in the Debug API.
- What arrives from the core and with what level — [core log](core-log.md).
- Depends on OS capabilities: writing to the app directory.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [023F](../../../tasks/023F-debug-and-logging/spec.md) | 🚫 Closed | Debug screen from the menu; the built-in advanced viewer dropped |
| 2 | [028](../../../tasks/028-persistent-applog.md) | Done | warning/error to disk, previous-session mark |
| 3 | [038F](../../../tasks/038F-crash-diagnostics/spec.md) | ✅ Done → §043 | The persisted log is one of the crash analysis channels |
| 4 | [043F](../../../tasks/043F-applog-per-source-quotas/spec.md) | Done | Separate app/core quotas, two files, merge by time, `/logs/app` and `/logs/core` |
| 5 | [041](../../../tasks/041-user-error-format-helper.md) | ✅ Implemented | Errors in the log and on screen — in human-readable form |
| 6 | [219](../../../tasks/219-deep-audit-2026-07.md) | — | A too-long first line is persisted anyway |
