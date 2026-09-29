[English](crash-reports.md) · [Русский](crash-reports.ru.md)

# Crash reports — core panics, memory snapshots and process exit reasons

Nothing has to be enabled in advance: the core and the OS write the evidence
as the failure happens.

| Field | Value |
|-------|-------|
| Feature | [013-DIAGNOSTICS](../FEATURE.md) |
| Promises | P7, P8, P9 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Collects evidence that the core or the process died and hands it to the user
in one tap: core panic reports (trace, metadata, config at the moment of the
crash), memory snapshots the core takes on its own when approaching the memory
limit, and the system reasons for process termination. After a core panic the
home screen offers to share the report once.

## Parameters

No settings of its own. Fixed values:

| What | Value |
|------|-------|
| Panic report archive | 10 freshest |
| Memory snapshot archive | 5 freshest (a snapshot is ~750 KB) |
| When rotation runs | at every app startup |
| Process exit reasons | the last 5, Android 11+ |

## Inputs / Outputs

**Inputs:** the current core report `CrashReport-lxbox.log`; the archive
`crash_reports/<time>/` (`go.log`, `metadata.json`, `configuration.json`;
early builds — a flat file); snapshots `oom_reports/<time>/`; the system
process exit history.

**Outputs:**
- the home screen banner "The core crashed last session — tap to share the
  report";
- the Debug screen, **Crashes** tab: a list (time, size, core version or
  "current session"), trace view with copying, share;
- the **OOM** tab: a list (time, size, RSS), a summary "N snapshots · size",
  view of memory fields and the core log at the moment of the snapshot, share,
  "Delete all OOM reports" with confirmation;
- Debug API: `/files/crash/list`, `/files/crash?name=`, `/files/local?name=
  CrashReport-lxbox.log[.old]`, `/files/oom/list`, `/files/oom?name=[&file=]`,
  `/diag/stderr` (the current report), `/diag/exit-info`;
- the `stderr_log`, `crash_archive`, `oom_reports`, `exit_info` fields in the
  [dump](diagnostic-dump.md).

## Rules and invariants

- An empty current report means "there were no panics" (the core recreates it
  on every launch); it does not appear in the list. An archive directory
  without `go.log` is not a report and is not shown.
- The list is newest first; archived and current together.
- Sharing an archived report sends all files of the directory, each name
  prefixed with the crash time (so in a conversation the `go.log` files of
  different crashes are distinguishable); on failure — the snackbar "Share
  failed".
- Banner: shown if the freshest report does not match the "shown" mark (name
  + file time). A tap — share and mark; dismissal — mark. The mark is written
  in any case, even if the share failed.
- Rotation deletes a report as a whole directory; it does not touch the
  current report; a busy file is skipped without failing startup.
- A memory snapshot without `metadata.json` is incomplete and not shown; a
  broken `metadata.json` — the snapshot is visible with empty fields; the
  snapshot size is the whole directory.
- `/files/*` reject names with path traversal and names outside the
  whitelist; no archive — `[]`, not an error.
- Exit reasons: time, reason (`CRASH`, `CRASH_NATIVE`, `ANR`, `LOW_MEMORY`,
  `SIGNALED`, `EXIT_SELF`, …), description, memory, code, trace if the system
  attached one; on older OS versions — an empty list.
- The Crashes tab is always present; when empty it says "No crash reports" and
  that the channel covers only core panics.

## Boundaries

- Native failures outside Go, an abort from a callback and a kill by the
  system leave no report: an empty report next to a system "tombstone" is a
  conclusion in itself.
- Resetting core caches after a crash —
  [010-VPN_SERVICE → recovery](../../010-VPN_SERVICE/FUNCTIONS/recovery.md).
- There is no banner for memory snapshots: a snapshot is routine and needs no
  attention.
- Depends on OS capabilities: exit history (Android 11+), the system share.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [038F](../../../tasks/038F-crash-diagnostics/spec.md) | ✅ Done → §043 | Four crash analysis channels without `adb` |
| 2 | [018](../../../tasks/018-stderr-viewer-debug-tab.md) | Done | The core panic trace is visible on the Debug screen |
| 3 | [029](../../../tasks/029-application-exit-info.md) | Done | System reason for process termination |
| 4 | [050](../../../tasks/050-libbox-debug-build/spec.md) | Done | Analysis of a "mysterious" abort: the cause is an exception in a callback, not the core |
| 5 | [173](../../../tasks/173-oom-killer-setup-options.md) | Implemented (device-verify ahead) | The core receives the report source and the memory limit at launch |
| 6 | [316](../../../tasks/316-kernel-crash-reports-access.md) | device-verified | Real report path, archive, banner once per failure, Crashes tab |
| 7 | [318](../../../tasks/318-oom-reports-access.md) | DEVICE-PENDING | Memory snapshots: OOM tab, API, rotation 5 |
| 8 | [334](../../../tasks/334-on-launch-after-crash-cache-reset.md) | ✅ DEVICE-PENDING | The fact of a crash is an event with independent subscribers |
