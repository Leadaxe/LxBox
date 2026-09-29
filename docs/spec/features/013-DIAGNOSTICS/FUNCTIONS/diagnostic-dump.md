[English](diagnostic-dump.md) · [Русский](diagnostic-dump.ru.md)

# Diagnostic dump — everything for a bug report in one JSON file

The dump is taken with "Share dump" on the Debug screen or with `GET
/diag/dump`.

| Field | Value |
|-------|-------|
| Feature | [013-DIAGNOSTICS](../FEATURE.md) |
| Promises | P10, P11 |
| State | ✅ written from code, 2026-09-28 |

## What it does

With one button collects everything needed to analyse a complaint into one
JSON file and opens the system share: the user hands over one file, the
developer does not need to ask for "this too".

## Parameters

No settings of its own. Entry points: the **Share dump** icon on the Debug
screen and `GET /diag/dump` (the same file). Fixed values:

| What | Value |
|------|-------|
| System log tail | 1000 lines of level Error and above, 2 s deadline |
| Panic report body in the dump | up to 64 KB, a truncated one is marked `truncated` |
| Memory snapshot bodies | only the 5 freshest; the rest — a summary |
| File name | `lxbox-dump-<YYYY-MM-DDThh-mm-ss>.json` |

## Inputs / Outputs

**Inputs:** the saved core config; settings variables; node sources; the
[log](app-log.md); [crash reports](crash-reports.md); the system log tail of
the app's own process; goroutine stacks of the live core.

**Outputs:** JSON with the fields:

| Field | What |
|-------|------|
| `generated_at`, `app` | build time, `lxbox` |
| `app_version`, `app_build`, `core_version` | what the dump was taken on |
| `vars` | all settings variables |
| `server_lists` | source entries + tags and node count (without full nodes) |
| `config` | the saved core config |
| `debug_log` | the log of both sources, `prev_session` on previous-session entries |
| `stderr_log` | the current panic report or `null` |
| `crash_archive` | archived reports with bodies |
| `oom_reports` | snapshot summary; all files for the 5 freshest |
| `exit_info` | process exit reasons |
| `logcat_tail` | the system log tail of the app's own process |
| `goroutines_stack` | goroutine stacks, only while the tunnel is up |

## Rules and invariants

- Each field is collected best-effort: an unavailable channel gives
  `null`/an empty list, the dump is collected anyway.
- Memory snapshot files: text ones (`metadata.json`, `connections.json`,
  `configuration.json`, `go.log`, `cmdline`) — as is; binary profiles and
  unfamiliar files — `gzip+base64` with the original size; `go.log` over the
  limit — the tail and a truncation flag.
- Sources are taken as the UI sees them (with parsed nodes); if the UI is not
  up yet — from storage.
- System log tail: only the app's own process, filtering done by the system,
  no special permission; more can be fetched via
  `/diag/logcat?count=50..5000&level=V|D|I|W|E|F`.
- While the dump is being collected, the button shows progress and cannot be
  pressed again; an error — the snackbar "Share failed: …".

## Boundaries

- The CPU profile is not part of the dump — it is captured separately, see
  [profiling](core-profiling.md).
- The dump is deliberately unmasked: the config with keys, subscription
  addresses, the Debug API token and variables go as is. A masked dump is
  useless for diagnosis; the user decides whom to hand the file to (owner's
  decision, 2026-09-29).
- Depends on OS capabilities: access to the system log of the app's own
  process, exit history (Android 11+), the system share.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [038F](../../../tasks/038F-crash-diagnostics/spec.md) | ✅ Done → §043 | The dump collects all crash analysis channels |
| 2 | [022](../../../tasks/022-logcat-tail-in-dump.md) | Done | The system log tail of the app's own process |
| 3 | [029](../../../tasks/029-application-exit-info.md) | Done | Exit reasons — lazily, only in the dump |
| 4 | [207](../../../tasks/207-goroutine-cpu-dump.md) | implemented | Goroutine stacks while the tunnel is live |
| 5 | [316](../../../tasks/316-kernel-crash-reports-access.md) | device-verified | Core panic archive in the dump, bodies up to 64 KB |
| 6 | [318](../../../tasks/318-oom-reports-access.md) | DEVICE-PENDING | Memory snapshot summary in the dump |
| 7 | [378](../../../tasks/378-dump-app-and-core-version.md) | Done | App, build and core versions in the dump root |
| 8 | [397](../../../tasks/397-oom-report-bodies-in-dump.md) | — | Bodies of the 5 freshest memory snapshots, binary ones gzip+base64 |
