[English](core-log.md) · [Русский](core-log.ru.md)

# Core log — the sing-box log inside the app, without adb

Forwarding is off by default and takes effect only after a process restart.

| Field | Value |
|-------|-------|
| Feature | [013-DIAGNOSTICS](../FEATURE.md) |
| Promises | P4, P5, P6 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Shows the internal sing-box log (routing, DNS, inbounds, outbounds, dials)
inside the app — the Log → Core tab and `/logs/core` — without `adb`. How much
the core writes is decided by the log level in the config; whether it reaches
the app — by the forwarding toggle; trace lines — by a separate Verbose mode.

## Parameters

| Setting | Where | Values | Default | When it applies |
|---------|-------|--------|---------|-----------------|
| Log level | core settings → General | `trace`…`panic` | `warn` | config rebuild and tunnel restart |
| Forward sing-box logs | App Settings → Diagnostics | on/off | off | after a process restart |
| Verbose (TRACE/DEBUG) | same place, under forwarding | on/off | off | immediately |

Core config keys: `log.level`, `log.timestamp: true`. Debug API: `GET/PUT
/settings/core_logs_enabled`, `GET/PUT /settings/core_logs_verbose`. Both
forwarding settings are stored outside the main settings file (they must be
known before the UI starts).

## Inputs / Outputs

**Inputs:** core log lines.
**Outputs:** `core` source entries in the [app log](app-log.md). The Profiler
does not read the core log.

## Rules and invariants

- With forwarding off the core does not emit lines at all; Verbose is then
  unavailable.
- A forwarding change is saved immediately but takes effect only in a new
  process: the snackbar "Saved. Force-stop & reopen app to apply.", an
  explanation under the toggle and a "Quit & reopen app" button (terminates
  the process together with the tunnel after confirmation). Stopping/starting
  the tunnel does not help.
- Verbose lifts the dropping of TRACE/DEBUG lines on the fly, without a
  restart.
- Terminal control sequences are stripped from lines; the brackets with the
  connection number and time are kept.
- The line level is taken from the marker in the text: ERROR/FATAL/PANIC →
  error, WARN → warning, INFO → info, TRACE/DEBUG → debug, otherwise info; the
  highest marker wins. Both core forms are supported — `INFO ` with spaces and
  `INFO[0006]`.
- The line queue is bounded to 4096; on overflow new lines are dropped, the
  core does not wait for the app. Lines are delivered in batches of up to 200.
- The "raw stderr" file (`/diag/stderr`) is the current core panic report, see
  [crash reports](crash-reports.md).

## Boundaries

- The core writes the crash report itself, independently of forwarding:
  nothing needs to be enabled for it.
- Core lines are not parsed structurally — the text as is.
- The source of the profiler's DNS events is the core stream, not the log.
- Depends on OS capabilities: the process restart is performed by the user.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [023F](../../../tasks/023F-debug-and-logging/spec.md) | 🚫 Closed | The core log level is the `log_level` variable |
| 2 | [043F](../../../tasks/043F-applog-per-source-quotas/spec.md) | Done | Forwarding the core log to the app, a toggle with a process restart |
| 3 | [050](../../../tasks/050-libbox-debug-build/spec.md) | Done | Analysis of an alternative: the log via the command stream instead of a callback |
| 4 | [141](../../../tasks/141-deep-code-audit-hardening.md) | In progress | Without a subscriber lines are not processed at all |
| 5 | [171](../../../tasks/171-ansi-strip-bare-esc-dns.md) | Implemented (device-verified) | Bare control bytes are stripped from lines |
| 6 | [345](../../../tasks/345-core-logs-verbose-toggle.md) | ✅ Device-verified | Verbose: TRACE/DEBUG on the fly |
