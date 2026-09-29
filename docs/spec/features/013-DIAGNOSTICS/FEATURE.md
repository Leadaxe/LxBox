[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# FEATURE 013 — DIAGNOSTICS — diagnostics for the user and the developer

| Field | Value |
|-------|-------|
| Type | Product feature |
| Absorbed | `§023F` `§031F` `§038F` `§043F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

When "it doesn't work", the developer does not have the user's device, and the
user does not have `adb`. The feature gives both of them the same body of
evidence: the app log and the core log, core crash reports and its memory
snapshots, the system reason for process death, a single "everything at once"
dump file, profiler snapshots of the live core, recording of live network
events and — for a developer on a test device — a local HTTP interface (Debug
API) through which all of the same can be read and changed without the screen.

The feature protects three principles:

- **Evidence survives the failure.** Everything needed to analyse a crash is
  written so that it survives process death: log warnings, the core panic
  report, the memory snapshot. The user does not need to enable anything in
  advance.
- **Diagnostics do not get in the way.** Every channel is best-effort: a
  failure to read evidence does not break startup; noisy sources are off by
  default, archives are rotated, event recording runs only on an explicit
  command.
- **Root access — only with explicit consent.** The Debug API behind a token
  sees and changes everything, secrets included; so it is off by default,
  listens only on the device's own address and rejects foreign host names.

## Promises

- **P1. Log sources do not evict each other.** The app log and the core log
  have separate quotas (300 and 500 entries); a flood from one does not push
  out the other; overflow evicts the oldest entry of its own source.
  **Witness:** units "app spam не вытесняет core entries", "core spam не
  вытесняет app entries", "per-source cap drop oldest". **Mutation:** a shared
  limit for both sources.
- **P2. The combined view is strictly by time.** The mixed log is returned
  newest-first across both sources; clearing one source does not touch the
  other. **Witness:** units "merged result отсортирован newest-first по обоим
  source", "clearSource(app) очищает только app, core нетронут".
  **Mutation:** concatenating the lists without a time merge.
- **P3. Warnings survive a restart.** Warning and error entries of each source
  are persisted (up to 200 lines and 64 KB per source) and after a restart are
  shown marked "↑ prev session"; debug and info live only in memory.
  **Witness:** manual check — cause an error (for example, `POST
  /action/emulate-error?kind=plain`), kill the process, open Debug.
  **Mutation:** persisting without distinguishing levels.
- **P4. A core line's level is determined from its text.** ERROR/FATAL/PANIC →
  error, WARN → warning, INFO → info, TRACE/DEBUG → debug, unrecognised →
  info; with several markers the highest wins. **Witness:** units
  "FATAL → error", "error приоритетнее warn в смешанной строке", "неизвестный
  формат → fallback info", "default-formatter формат WARN[NNNN]".
  **Mutation:** an unknown line gets the error level.
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
  failure raises it again. **Witness:** units "новый краш → показываем;
  повторный старт → молчим", "следующий (более свежий) краш → снова
  показываем". **Mutation:** a "shown" mark not tied to a specific report.
- **P8. The failure archive is bounded and intact.** The 10 freshest panic
  reports and the 5 freshest memory snapshots are kept; the excess is deleted
  whole at startup; rotation does not touch the current report.
  **Witness:** units "оставляет 10 свежих, лишние каталоги удаляет целиком",
  "текущий репорт ротация не трогает", "оставляет keep свежих, удаляет
  остальные". **Mutation:** deleting only the trace without the directory.
- **P9. "There were no failures" is an honest answer.** An empty current
  report means "there were no panics" and does not appear in the list; the
  Crashes tab is always present and itself says that the channel covers only
  core panics. **Witness:** units "пустой файл = паник не было", "пустой
  текущий в список не попадает". **Mutation:** the tab appears only when the
  report is non-empty.
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
- **P12. The Debug API is closed by default.** Off until explicitly enabled;
  listens only on the device's own address; the token is 32 hex characters
  (128 bits), generated on first enable. **Witness:** units "даёт 32 hex
  символа", "разные токены при последовательных вызовах"; loopback — manual
  check (a request to the device's LAN address does not connect).
  **Mutation:** an empty token allows startup.
- **P13. Without a token — only /ping and /help.** Everything else without the
  exact `Authorization: Bearer <token>` header returns 401. **Witness:** units
  "GET /state без токена → 401", "/ping пропускает без auth", "схема должна
  быть именно `Bearer `". **Mutation:** a case-insensitive scheme.
- **P14. A foreign host name is rejected.** A request whose Host is not
  `127.0.0.1` / `localhost` gets 403 even with the correct token.
  **Witness:** units "evil.com → InvalidHost", "GET /ping с Host: evil.com →
  403". **Mutation:** the host check after authorisation, only for protected
  paths.
- **P15. Access to the Debug API cannot be lost via the API itself or a backup
  import.** The enable, port and token keys cannot be written through
  `/settings/vars` (409); a replace import that lacks them keeps the current
  ones. **Witness:** units "replaceRaw merge=false keeps device Debug API keys
  absent in snapshot", "Debug API keys from snapshot win"; the ban in
  `/settings/vars` — `no witness`. **Mutation:** a replace import rewrites
  `vars` entirely.
- **P16. File routes do not leave their directories.** Names with path
  traversal and names outside the whitelist are rejected (404/400).
  **Witness:** units "traversal в &file= отвергается", "не-whitelist имя →
  404, даже если файл существует". **Mutation:** the file name is joined to
  the directory without a check.
- **P17. The API map does not lie.** `/help` lists every mounted prefix; error
  codes are stable. **Witness:** units "каждый смонтированный префикс роутера
  есть в /help?format=json", "коды стабильные (API contract)".
  **Mutation:** a route without an entry in `/help`.
- **P18. A hung handler does not hang the server.** After 30 s — 504.
  **Witness:** unit "долгий handler → RequestTimeout". **Mutation:** waiting
  without a deadline.
- **P19. The secret does not leak into copyable API snapshots.** The token in
  the storage snapshot is `***`; sensitive request parameters are masked in
  the request log. **Witness:** unit "debug_token маскируется, остальные vars
  pass-through"; the request log — `no witness`. **Mutation:** a storage
  snapshot without the scrubber.
- **P20. Live events are recorded only on an explicit command.** Without START
  events do not accumulate; recording continues when leaving the tab.
  **Witness:** unit "recording off → events ignored". **Mutation:** recording
  starts on opening the tab.
- **P21. Live event banners are not noisy.** "Owner not determined" — more than
  5 unattributed events in 30 s, successful DNS does not count; "DNS failing"
  — at least 3 failures and 20 % in 30 s, and only while the connection is
  alive. **Witness:** units "§177-A successful unattributed DNS resolves do
  NOT light the banner", "2 fail (< минимума 3) → healthy", "5 fail 100%, но
  НЕТ conn-активности → healthy". **Mutation:** a threshold on the absolute
  number of failures without the activity gate.
- **P22. Same-kind notifications collapse.** Notifications of one code at one
  level form one group with a count and a list of entries; the header counters
  count entries. **Witness:** widget tests "семь записей одного кода → одна
  плитка", "счётчик шапки считает записи, а не группы". **Mutation:** grouping
  across levels.
- **P23. A core notification with a link leads to the link.** Tapping a system
  notification that came from the core opens its address; the address is
  duplicated into the core log. **Witness:** manual check with an
  unauthorised Tailscale node. **Mutation:** a notification with no tap
  action.
- **P24. A profiler snapshot — only with a live core.** Without the tunnel up
  the snapshot is not taken ("VPN must be running…"); the snapshot server
  exists only for the duration of one request. `no witness`.

## Controlled parameters

| Setting | Where | Values | Default | When it applies |
|---------|-------|--------|---------|-----------------|
| Log level | core settings → General | `trace` / `debug` / `info` / `warn` / `error` / `fatal` / `panic` | `warn` | config rebuild and restart |
| Forward sing-box logs | App Settings → Diagnostics | on/off | off | after a process restart |
| Verbose (TRACE/DEBUG) | same place, active while forwarding is on | on/off | off | immediately |
| Debug API | App Settings → Diagnostics → Developer | on/off | off | immediately |
| Port | same place | 1024..49151 | 9269 | immediately (the server restarts) |
| Token | same place, Copy / Regenerate | 32 hex | generated on first enable | immediately; the old one gets 401 |
| Lock config (debug) | same place, visible only while the Debug API is on | on/off | off; cleared by turning the Debug API off | immediately |
| Live retention window | Stats → Profiler | 1m / 10m / 1h | 10m | immediately |

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
notifications sent by the core; HTTP requests to `127.0.0.1:<port>`.

**Outputs:** the Debug screen (Log / Crashes / OOM / Profiling tabs, Share
dump); the "core crashed" banner on the home screen; the Profiler tab in
Stats; the dump file and snapshots via the system share; core system
notifications; Debug API JSON responses.

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
HTTP → host check → token → 30 s deadline → route → JSON / error
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
- The Debug API starts when the home screen opens and on every change of the
  toggle, port or token; with an empty token the server does not start.

## Boundaries

- Live tunnel status, speed, connections and statistics — 012-LIVE_STATE;
  here only event recording as an analysis tool.
- Diagnostics of a specific node (checks, pings, which codes a node gets) —
  [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md); here — how notifications
  with codes are shown.
- Resetting core caches after a crash and auto-raising the tunnel —
  [010-VPN_SERVICE](../010-VPN_SERVICE/FUNCTIONS/recovery.md).
- An MCP wrapper over the Debug API (`§035F`) — spec only, not implemented
  (cancelled by the owner).
- The built-in advanced log viewer (`§023F`) — dropped: its place was taken by
  Profiler and the Debug API.
- The crash report covers only core panics; native failures outside the core
  and the process being killed by the system are visible only in the exit
  reasons and the system log tail.
- Depends on OS capabilities: process exit history (Android 11+), access to
  the system log of the app's own process only, showing notifications (the
  notification permission), a loopback shared by all apps (protection — the
  token).

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| App log | Sources, quotas, persisting warn/error, viewing and filters | P1–P3 | [app-log.md](FUNCTIONS/app-log.md) |
| Core log | Log level, forwarding, Verbose, level parsing | P4–P6 | [core-log.md](FUNCTIONS/core-log.md) |
| Crash reports | Core panics, memory snapshots, exit reasons, banner | P7–P9 | [crash-reports.md](FUNCTIONS/crash-reports.md) |
| Diagnostic dump | One JSON with all channels | P10, P11 | [diagnostic-dump.md](FUNCTIONS/diagnostic-dump.md) |
| Core profiling | pprof snapshots of the live core | P24 | [core-profiling.md](FUNCTIONS/core-profiling.md) |
| Debug API | Local HTTP: reading, writing, protection | P12–P19 | [debug-api.md](FUNCTIONS/debug-api.md) |
| Live events | Recording system events, window, export, banners | P20, P21 | [live-events.md](FUNCTIONS/live-events.md) |
| Coded notifications | Grouping by code; core notifications with a link | P22, P23 | [coded-notifications.md](FUNCTIONS/coded-notifications.md) |

## Related features

- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — produces the node check results and codes; here they are shown as coded notifications.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — resets core caches and restores the tunnel after the crash that this feature reports.
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — owns live status, speed and connections; this feature only records events for analysis.

## Maintenance notes

- Core reports live in the core's working directory, not the app's: reading
  via the app path silently found nothing, and the failure channel "worked"
  empty for months (§316). The old name `stderr.log` does not exist on the
  current core.
- The core bounds neither the panic archive nor the memory snapshots (on the
  test device — 575 snapshots, 427 MB, §318): rotation is kept by the app.
- In Verbose the core buffer (500 lines) lasts seconds on live traffic: enable
  it pointwise and grab the log right away.
- The Debug API is root access by design: the audit checks the boundary
  (token, bind, default-off, host), not the masking of secrets behind it.
