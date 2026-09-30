[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Diagnostics — logs, crash reports, debug dump and live events

LxBox collects logs, sing-box core crash reports and memory snapshots on the
device, so a VPN problem can be analysed from one shared file without `adb`.
On a test device the same evidence is readable over HTTP through the Debug API
([027-DEBUG_API](../027-DEBUG_API/FEATURE.md)).

| Field | Value |
|-------|-------|
| Feature | 013-DIAGNOSTICS |
| Type | Product feature |
| Absorbed | `§023F` `§038F` `§043F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

When "it doesn't work", the developer does not have the user's device, and the
user does not have `adb`. The feature gives both of them the same body of
evidence: the app log and the core log, core crash reports and its memory
snapshots, the system reason for process death, a single "everything at once"
dump file, profiler snapshots of the live core and recording of live network
events. A developer on a test device reads all of the same through the Debug
API routes `/logs`, `/files`, `/diag`, `/profiler` — the API itself is
[027-DEBUG_API](../027-DEBUG_API/FEATURE.md).

The feature protects two principles:

- **Evidence survives the failure.** Everything needed to analyse a crash is
  written so that it survives process death: log warnings, the core panic
  report, the memory snapshot. The user does not need to enable anything in
  advance.
- **Diagnostics do not get in the way.** Every channel is best-effort: a
  failure to read evidence does not break startup; noisy sources are off by
  default, archives are rotated, event recording runs only on an explicit
  command.

## Promises

- **P1. Log sources do not evict each other.** The app log and the core log
  have separate quotas (300 and 500 entries); a flood from one does not push
  out the other; overflow evicts the oldest entry of its own source.
  **Witness:** units "app spam does not evict core entries", "core spam does
  not evict app entries", "per-source cap drop oldest". **Mutation:** a shared
  limit for both sources.
- **P2. The combined view is strictly by time.** The mixed log is returned
  newest-first across both sources; clearing one source does not touch the
  other. **Witness:** units "merged result is sorted newest-first across both
  sources", "clearSource(app) clears only app, core untouched". **Mutation:**
  concatenating the lists without a time merge.
- **P3. Warnings survive a restart.** Warning and error entries of each source
  are persisted (up to 200 lines and 64 KB per source) and after a restart are
  shown marked "↑ prev session"; debug and info live only in memory.
  **Witness:** manual check — cause an error (for example, `POST
  /action/emulate-error?kind=plain`), kill the process, open Debug.
  **Mutation:** persisting without distinguishing levels.
- **P4. A core line's level is determined from its text.** ERROR/FATAL/PANIC →
  error, WARN → warning, INFO → info, TRACE/DEBUG → debug, unrecognised →
  info; with several markers the highest wins. **Witness:** units "FATAL →
  error", "error takes priority over warn in a mixed line", "unknown format →
  fallback info", "default-formatter format WARN[NNNN]". **Mutation:** an
  unknown line gets the error level.
- **P5. Forwarding the core log is a deliberate step.** Off by default;
  enabling takes effect only after a process restart, which the screen says
  immediately and offers a "Quit & reopen app" button. **Witness:** manual
  check — enable, do not restart, open Debug → Core: empty; after Quit &
  reopen — core lines. **Mutation:** the restart hint removed.
- **P6. The core's verbose mode switches on the fly.** "Verbose (TRACE/DEBUG)"
  lets trace lines through without a restart and is unavailable while
  forwarding is off. **Witness:** manual check `PUT
  /settings/core_logs_verbose` → DEBUG/TRACE in `/logs/core` (§345,
  device-verified). **Mutation:** the mode is read only at core start.
- **P7. The core crash banner — once per specific failure.** After a core
  panic the home screen shows "The core crashed last session — tap to share
  the report" once; a tap or dismissal clears it for that failure, the next
  failure raises it again. **Witness:** units "new crash → show; repeated
  start → stay silent", "next (newer) crash → show again". **Mutation:** a
  "shown" mark not tied to a specific report.
- **P8. The failure archive is bounded and intact.** The 10 freshest panic
  reports and the 5 freshest memory snapshots are kept; the excess is deleted
  whole at startup; rotation does not touch the current report. **Witness:**
  units "keeps the 10 newest, deletes extra directories whole", "rotation does
  not touch the current report", "keeps the keep newest, deletes the rest".
  **Mutation:** deleting only the trace without the directory.
- **P9. "There were no failures" is an honest answer.** An empty current
  report means "there were no panics" and does not appear in the list; the
  Crashes tab is always present and itself says that the channel covers only
  core panics. **Witness:** units "empty file = no panics", "an empty current
  report is not listed". **Mutation:** the tab appears only when the report is
  non-empty.
- **P10. The dump says what it was taken on.** The dump root carries the app
  version, the build number and the core version. **Witness:** manual check of
  Share dump (§378, device-verified). **Mutation:** the core version only
  inside the snapshots.
- **P11. The dump carries memory snapshot bodies but does not grow without
  bound.** Bodies are included only for the 5 freshest snapshots (text ones
  as is, binary ones gzip + base64), the rest as a summary; a core log over
  the limit — as a tail with a flag. **Witness:** units "body carries all
  files: text readable, binaries gzip+base64", "bodies only for kOomKeep
  freshest", "go.log over the limit keeps the tail and sets the flag".
  **Mutation:** bodies for all snapshots.
- **P12.** moved to 027-DEBUG_API · P1
- **P13.** moved to 027-DEBUG_API · P2
- **P14.** moved to 027-DEBUG_API · P3
- **P15.** moved to 027-DEBUG_API · P4
- **P16.** moved to 027-DEBUG_API · P5
- **P17.** moved to 027-DEBUG_API · P10
- **P18.** moved to 027-DEBUG_API · P6
- **P19.** moved to 027-DEBUG_API · P7
- **P20. Live events are recorded only on an explicit command.** Without START
  events do not accumulate; recording continues when leaving the tab.
  **Witness:** unit "recording off → events ignored". **Mutation:** recording
  starts on opening the tab.
- **P21. Live event banners are not noisy.** "Owner not determined" — more
  than 5 unattributed events in 30 s, successful DNS does not count; "DNS
  failing" — at least 3 failures and 20 % in 30 s, and only while the
  connection is alive. **Witness:** units "§177-A successful unattributed DNS
  resolves do NOT light the banner", "2 fails (< minimum of 3) → healthy", "5
  fails 100%, but NO conn activity → healthy". **Mutation:** a threshold on
  the absolute number of failures without the activity gate.
- **P22. Same-kind notifications collapse.** Notifications of one code at one
  level form one group with a count and a list of entries; the header counters
  count entries. **Witness:** widget tests "seven entries of one code → one
  tile", "the header counter counts entries, not groups". **Mutation:**
  grouping across levels.
- **P23. A core notification with a link leads to the link.** Tapping a system
  notification that came from the core opens its address; the address is
  duplicated into the core log. **Witness:** manual check with an
  unauthorised Tailscale node. **Mutation:** a notification with no tap
  action.
- **P24. A profiler snapshot — only with a live core.** Without the tunnel up
  the snapshot is not taken ("VPN must be running…"); the snapshot server
  exists only for the duration of one request. **Witness:** widget test
  "capture button does not call pprofProfile when VPN is down". **Mutation:**
  the VPN-status gate removed from `_capture`.

## Controlled parameters

| Setting | Where | Values | Default | When it applies |
|---------|-------|--------|---------|-----------------|
| Log level | core settings → General | `trace` / `debug` / `info` / `warn` / `error` / `fatal` / `panic` | `warn` | config rebuild and restart |
| Forward sing-box logs | App Settings → Diagnostics | on/off | off | after a process restart |
| Verbose (TRACE/DEBUG) | same place, active while forwarding is on | on/off | off | immediately |
| Live retention window | Stats → Profiler | 1m / 10m / 1h | 10m | immediately |

The Debug API toggle, port, token and Lock config — 027-DEBUG_API.

Core config keys (contract): `log.level` = the selected Log level,
`log.timestamp: true`. Core launch parameters: crash report source `lxbox`,
the log forwarding flag — from "Forward sing-box logs".

Core file formats the feature reads: the current report
`CrashReport-lxbox.log`; the archive `crash_reports/<ISO-time>/` = `go.log` +
`metadata.json` + `configuration.json` (early builds — a flat file); memory
snapshots `oom_reports/<ISO-time>/` = `metadata.json`, `go.log`,
`configuration.json`, `connections.json`, pprof profiles `*.pb`. The dump —
`lxbox-dump-<time>.json`.

## Inputs / Outputs

**Inputs:** app entries; core log lines; core report and snapshot files; the
system process exit history (Android 11+); the tail of the system log of the
app's own process; the core's stream of connections and DNS queries;
notifications sent by the core.

**Outputs:** the Debug screen (Log / Crashes / OOM / Profiling tabs, Share
dump); the "core crashed" banner on the home screen; the Profiler tab in
Stats; the dump file and snapshots via the system share; core system
notifications; the same data as JSON through the Debug API routes.

## Data flow

```
app → app log ─┐                                   ┌→ Debug screen / Log
core → level filter → core log ─┤→ merge by time ─┤→ /logs, /diag/applog
     warn/error ─→ file per source ─┘ (↑ prev session) └→ dump: debug_log
core panic → current report → (next launch) archive → rotation 10
     └→ banner (once per failure) · Crashes tab · /files/crash · dump
memory pressure → oom_reports snapshot → rotation 5 → OOM tab · /files/oom · dump
Share dump / GET /diag/dump → versions + settings + sources + config + log
     + reports + snapshots + exit reasons + system log tail
     + goroutine stacks (if the tunnel is up) → one JSON
START → core connection and DNS stream → buffer (retention window) → Profiler tab
     → banners (owner / DNS) · /profiler/live*
```

## Rules and guarantees

- Reading evidence is best-effort: a channel failure is an empty field, not a
  failure of the screen or of startup.
- The core log reaches the app only if forwarding is on; TRACE/DEBUG lines are
  dropped before reaching the app while Verbose is off; when the queue (4096
  lines) overflows, new lines are dropped.
- "Saved from last time" — only warning and error; only entries of the
  current session are written to the file, so the disk holds the last session
  that had warnings.
- Archive rotation runs at app startup, not when the screen is opened.

## Boundaries

- Live tunnel status, speed, connections and statistics — 012-LIVE_STATE;
  here only event recording as an analysis tool.
- Diagnostics of a specific node (checks, pings, which codes a node gets) —
  [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md); here — how notifications
  with codes are shown.
- Resetting core caches after a crash and auto-raising the tunnel —
  [010-VPN_SERVICE](../010-VPN_SERVICE/FUNCTIONS/recovery.md).
- Debug API — [027-DEBUG_API](../027-DEBUG_API/FEATURE.md): the gate,
  the route map, `/help`, writes; here only the routes that read this
  feature's evidence.
- The built-in advanced log viewer (`§023F`) — dropped: its place was taken by
  Profiler and the Debug API.
- Not planned (owner decision 2026-09-29, audit [591](../../tasks/591-spec-kit-revision-audit.md)): an accumulating on-disk log across
  several sessions (`043F` B.5) — after a restart only the previous session is
  available ([app log](FUNCTIONS/app-log.md)).
- The crash report covers only core panics; native failures outside the core
  and the process being killed by the system are visible only in the exit
  reasons and the system log tail.
- Depends on OS capabilities: process exit history (Android 11+), access to
  the system log of the app's own process only, showing notifications (the
  notification permission).

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| App log | Keeps app and core messages in one log with separate quotas, persists warnings and errors across restarts and shows them with filters. | P1–P3 | [app-log.md](FUNCTIONS/app-log.md) |
| Core log | Shows the sing-box core log in the app, with a configurable log level, forwarding, on-the-fly Verbose mode and level parsing of each line. | P4–P6 | [core-log.md](FUNCTIONS/core-log.md) |
| Crash reports | Collects core panic reports, memory snapshots and system exit reasons, keeps a bounded archive and offers to share the report once after a crash. | P7–P9 | [crash-reports.md](FUNCTIONS/crash-reports.md) |
| Diagnostic dump | Collects versions, settings, config, logs, crash reports and memory snapshots into one JSON file and opens the system share. | P10, P11 | [diagnostic-dump.md](FUNCTIONS/diagnostic-dump.md) |
| Core profiling | Captures goroutine, CPU, heap and allocation pprof snapshots of the running core and hands them over as a file. | P24 | [core-profiling.md](FUNCTIONS/core-profiling.md) |
| Live events | Records TCP/UDP and DNS events of the device on an explicit START within a retention window, exports them and raises the owner and DNS banners. | P20, P21 | [live-events.md](FUNCTIONS/live-events.md) |
| Coded notifications | Groups same-code notifications into one entry with a count and opens the link of a notification sent by the core. | P22, P23 | [coded-notifications.md](FUNCTIONS/coded-notifications.md) |

Debug API moved to [027-DEBUG_API](../027-DEBUG_API/FEATURE.md).

## Related features

- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — produces the node check
  results and codes; here they are shown as coded notifications.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — resets core caches and
  restores the tunnel after the crash that this feature reports.
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — owns live status, speed and
  connections; this feature only records events for analysis.
- [027-DEBUG_API](../027-DEBUG_API/FEATURE.md) — the local HTTP interface
  whose `/logs`, `/files`, `/diag` and `/profiler` routes read this feature's
  evidence; the request log is written into the app log.

## Maintenance notes

- Core reports live in the core's working directory, not the app's: reading
  via the app path silently found nothing, and the failure channel "worked"
  empty for months (§316). The old name `stderr.log` does not exist on the
  current core.
- The core bounds neither the panic archive nor the memory snapshots (on the
  test device — 575 snapshots, 427 MB, §318): rotation is kept by the app.
- In Verbose the core buffer (500 lines) lasts seconds on live traffic: enable
  it pointwise and grab the log right away.
