# Diagnostics Playbook

A reference for every diagnostic tool L×Box has on a test device, plus the order
of work when the complaint is “X does not work”.

> **Discipline before anything else:** before triggering any destructive op
> (`POST /action/reset-network`, a reload, a VPN restart, `PUT /config`, storage
> changes) — **take a snapshot**. After a reset the RAM-only state is gone and
> there is no way to tell what degraded. See
> [`scripts/lxbox-diag.sh`](../scripts/lxbox-diag.sh), the one-command collector.
> Trigger anything destructive only after the user has **explicitly confirmed**
> it.

---

## Quick start

```bash
# 1. Bring up wifi-adb (or use USB)
./scripts/ensure-wifi-adb.sh

# 2. Take a full snapshot — in parallel across every API plus adb
./scripts/lxbox-diag.sh

# Saves into /tmp/lxbox-debug-<datetime>/:
#   state.json / storage.json / config.json
#   core_logs.json / app_logs.json
#   profiler_live.json          (system-wide TCP/UDP/DNS events for the window)
#   device_ss_tcp.txt / device_ss_udp.txt
#   device_routes_main.txt / device_routes_all.txt / device_ip_rule.txt
#   device_addrs.txt / device_props.txt
#   device_logcat.txt
```

> ⚠️ §122 — **the Clash API is gone** (removed entirely, see below). Connections,
> groups and DNS are now read through the profiler (`/profiler/live`) rather than
> through Clash `/connections`.

Read them in this order:
1. `state.json` — what the user sees (selected_group / active_in_group / last_error)
2. `profiler_live.json` — **where traffic is going right now**: TCP/UDP open/close plus DNS resolve/fail
   across every package, with the routing chain (`routingLine` / `outboundChain` / `detourChain`) per event
3. `core_logs.json` (filter to `level: error|warning`) — what is failing
4. `device_ss_tcp.txt` (state counts) — the health of the TCP stack
5. `config.json` (route.rules + route.final + dns.rules) — how it is *supposed* to route

---

## Endpoints — where to get what

### The LxBox Debug API (`http://<phone>:9269`, over adb-forward)

The default is a 1:1 forward: `adb forward tcp:9269 tcp:9269` (as in
`scripts/lxbox-diag.sh` and
[debug-api-reference.md](api/debug-api-reference.md)). `scripts/install-apk.sh`
forwards to host port **9270** by default (to avoid clashing with
singbox-launcher) — in that case call `lxbox-diag.sh` with `--port 9270`.

Auth: `Authorization: Bearer $TOKEN` (the token is in `vars.debug_token`).

| Endpoint | When to use it |
|---|---|
| `GET /ping` | A sanity check that needs no auth |
| `GET /state` | A snapshot of HomeState: tunnel/group/active_node/traffic/last_delay/last_error |
| `GET /state/storage` | The full `lxbox_settings.json` (sensitive values scrubbed) — vars / server_lists / custom_rules / dns_options / ping_options |
| `GET /state/subs` | Subscriptions (with `?reveal=true` — clear URLs) |
| `GET /state/rules` | Custom rules plus the `srs_cached` / `srs_mtime` flags |
| `GET /state/vpn` | auto_start / keep_on_exit / battery-optimisation status |
| `GET /state/config_locked` | §037 — is auto-rebuild locked |
| `GET /device` | Android version / model / ABI / app version and build / core version (libbox, sing-box-lx) / VPN permission / uptime |
| `GET /config` | The **saved** sing-box JSON (the file; §311 — with a live tunnel it can be *ahead* of the core: a rebuild before a restart) |
| `GET /config/pretty` | The same with indent 2 |
| `GET /config/running` | §311 — a snapshot of the **running core's** config (kernel SPEC 036, captured at start). It is re-marshalled, so compare it with `/config` only semantically. `409` = tunnel down / core older than lx.16-rc.3 / not fetched yet. A running↔saved divergence shows up as `running_config_length` vs `config_length` in `/state`. **§324** — “semantically” means bringing both sides to a canonical form using the core itself: `/config` → `formatConfig` (plus applying `OverrideOptions`, which `formatConfig` does not, while the snapshot is post-override), then comparing with `/config/running` byte for byte. A difference in length alone does **not** mean a divergence: re-marshalling reorders fields and drops defaults |
| `GET /pool?tag=vpn-1-auto` | §208 — a snapshot of a round_robin group's pool: `{tag, count, slots:[{slot, tag, delay, alive}]}`. Which N servers occupy the slots right now, and their ping. A non-round_robin group → `200 slots:[]`; a tunnel that is down → `409` (not an empty response — §209) |
| `GET /logs?source=core&limit=500` | sing-box internal logs (requires `core_logs_enabled=true`) |
| `GET/PUT /settings/core_logs_verbose` | §345 — toggling the core's TRACE/DEBUG filter live, without restarting the VPN. The buffer (500 lines) survives seconds under live traffic — switch it on narrowly and pull `/logs?source=core` immediately |
| `GET /files/crash/list` | §316 — **core crashes**: the archive of Go panics, `[{name,size,mtime}]`, newest first. `[]` means there were none |
| `GET /files/local?name=CrashReport-lxbox.log` | §316 — the CURRENT core crash report (a Go panic with a trace); `.old` is the previous one |
| `GET /files/oom/list` | §318 — **core OOM snapshots**: `[{name,size,mtime,memory_usage,heap_inuse,num_goroutine}]`, newest first. `size` covers the whole directory (the pprof profiles carry the weight). `[]` means the oom-killer never fired |
| `GET /files/oom?name=<from list>[&file=heap.pb]` | §318 — a file from the snapshot; `metadata.json` by default. `&file=` accepts `heap.pb`/`allocs.pb`/`goroutine.pb`/`go.log`/`configuration.json`/`connections.json` |
| `GET /logs?source=app&limit=300` | App-side warnings and errors |
| `GET /logs?source=core&q=tinkoff&level=error,warning` | Filtering by substring plus level |
| `GET /diag/*` | §038 runtime diagnostics (see api/debug-api-reference.md) |
| `GET /diag/pprof?profile=P` | §207 — a pprof snapshot of the live core. `P` = `heap` (what is holding memory; `?query=gc=1` forces a GC) \| `allocs` \| `profile` (CPU, `?query=seconds=10`) \| `goroutine` (`?query=debug=2` for full stacks). Requires the tunnel up. `.pb` → `go tool pprof`; `goroutine?debug=*` returns text |
| `POST /profiler/live/start` | Turn on the system-wide rolling buffer (or tap START in the Profiler tab) |
| `POST /profiler/live/stop` | Turn it off |
| `GET /profiler/live?seconds=N` | §048 — **where traffic is going now**: system-wide events over an N-second window (TCP/UDP open/close plus DNS resolve/fail for every package, with a routing chain per event). Requires a preceding `live/start` |
| `GET /profiler/live/stream` | An SSE stream of system-wide events (live push) |
| `GET /profiler/live/unattributed` | §177 — recent unattributed events (a DNS failure with no owner UID, and the like) |
| `GET /profiler/live/state` | `{recording, started_at, buffer_count, unattributed_count, banner_active}`. `buffer_count=0` while `recording=true` means no events are arriving (the profiler is recording, but into nothing) |

**Read-only and safe.** The one exception in the table is
`PUT /settings/core_logs_verbose`: it only changes the log filter
(SharedPreferences, not `lxbox_settings.json`), triggers no rebuild and spoils no
evidence. Every other write endpoint (`POST /action/*`, `PUT /config`,
`PUT /settings/*`) is destructive — see below.

### ~~Clash API~~ — REMOVED (§122)

> **The Clash API is gone.** §122 dropped Clash HTTP entirely: the UI and
> diagnostics go through the libbox CommandClient (push streams out of the core),
> and the Clash port (`63130` / `9091`) is **no longer opened**. `ClashApiClient`
> was deleted from the code. Do not try to forward or curl Clash — the channel
> does not exist.

**What replaced it — a mapping table:**

| Was (Clash) | Now |
|---|---|
| `GET /connections` (chains plus the rule per connection) | **The profiler**: `GET /profiler/live?seconds=N`, or the **Conns** / **Profiler** tab in Stats. Every event carries `routingLine` (§181), `outboundChain` (`[rule, group, …auto…, node]`) and `detourChain` (the transport tail, e.g. `["WARP"]`) |
| `GET /proxies` (`now` plus per-node `history`) | The CommandClient `groups` stream → `/state` (`active_node` / `last_delay`) and the UI groups |
| `GET /proxies/<tag>/delay?url=` (ping) | `POST /action/urltest` (Debug API), or tapping ping in the UI |
| `GET /rules` (live-resolved) | `GET /config` → `route.rules` (as the core actually assembled them) |
| `GET /traffic` (SSE up/down) | The CommandClient `status` stream → `/state` (traffic) |
| `GET /logs?level=info` (SSE) | `GET /logs?source=core` (Debug API) |

> **“Where is the TCP traffic going right now” is now answered by the profiler** —
> it shows what info-level sing-box logs do not (see the invisible `direct-out`
> below): the routing chain per connection.

### ADB, device-side

```bash
adb shell ss -tnp                    # TCP sockets with PID/UID
adb shell ss -unp                    # UDP sockets
adb shell ip route                   # the main routing table
adb shell ip route show table all    # ALL tables (sing-box auto_route puts default in its own)
adb shell ip rule                    # policy-based routing rules
adb shell ip -4 addr                 # interfaces (wlan0/ccmni*/tun*)
adb shell getprop | grep dns         # Android system DNS settings
adb logcat -d -t 500                 # the last 500 logcat lines (system-wide)
adb shell pm list packages           # installed packages (to validate package_name matches)
adb shell dumpsys connectivity       # the network stack overall
adb shell dumpsys netstats --uid-detail   # per-UID byte counters
adb shell dumpsys package <pkg> | grep -E "userId|uid"  # the UID owning a process (for package-match debugging)
```

### Correlating sing-box conn_id

sing-box logs are prefixed with `[<conn_id> <elapsed_ms>]`. Every socket gets its
own `conn_id`. **A DNS query and a TCP connection to the same IP have DIFFERENT
conn_ids** (one for the DNS, another for the TCP).

To follow one socket's life cycle:

```python
import json
es = json.load(open('core_logs.json'))
es = es if isinstance(es, list) else es.get('entries', [])
target = '<conn_id from the interesting log line>'
for e in sorted(es, key=lambda x: x['ts']):
    if f'[{target} ' in e['message']:
        print(e['ts'][11:23], e['level'], e['message'])
```

What a typical TCP socket looks like at info level:
1. `inbound/tun[tun-in]: inbound packet connection from <client>` — a packet entered the tun
2. `inbound/tun[tun-in]: inbound packet connection to <dst>` — the destination
3. `router: route ... → <outbound>` — the routing decision (only with debug level on)
4. `outbound/<type>[<tag>]: outbound connection to <dst>` — the outbound dial (only for non-direct-out)

⚠️ **`outbound/direct-out` prints NOTHING at info level** — direct connections are
invisible in the logs. To see the routing chain for direct-out (or for anything
else) use the **profiler** (`/profiler/live` → `outboundChain` / `routingLine`, or
the **Conns** tab), where a direct connection's chain ends at `direct`.

> **§180/§044 — DNS and package detection are NO LONGER parsed out of the core
> log.** The profiler dropped its log listener: DNS resolutions arrive as a
> structured stream from the core (`CcChannel.dnsQueries`) rather than through a
> regex over `dns: exchanged …` / `router: found package name …` lines. DNS health
> is read in the profiler (the `dnsResolve` / `dnsFail` events, with the domain,
> the DNS server (rc.10) and latency), not in the logs. The
> `dns: exchanged` / `found package name` lines may still flicker past in the core
> log, but they are **not** the source of truth for diagnosis.

---

### §316 — “the core crashed” (SIGABRT in `libbox.so`)

The symptom in logcat: `Fatal signal 6 (SIGABRT) … (DefaultDispatch)` plus a
single `libbox.so` frame with a bare address. The Go panic text **never reaches**
logcat — Go writes it to stderr, and on Android that goes to `/dev/null` (§010).
The core saves the trace to a file by itself
(`SetupOptions.crashReportSource = "lxbox"`):

```bash
curl -s -H "$HDR" "$BASE/files/crash/list" | jq          # was there an archive
curl -s -H "$HDR" "$BASE/files/local?name=CrashReport-lxbox.log"   # the current one
curl -s -H "$HDR" "$BASE/files/crash?name=<from list>"   # a specific archived one
```

**Where this stops working.** `debug.SetCrashOutput` only catches **Go runtime
panics**. It does not cover: a SIGSEGV in cgo or native code outside Go; an
`abort()` from JNI when a callback threw an exception (§050/§128 — the process
dies before anything is written); or a kill by the system (LMK / OOM killer). So
**an empty report alongside a tombstone is itself a conclusion**: the crash did
not come from a Go panic, and the place to look is the JNI glue or a system kill,
not the core's logic.

**A tombstone from a third-party tracker (AppErrorsTracking and friends) does NOT
contain the cause** — do not spend cycles on it. All it gives you is the signal,
the thread, the time, the registers and `#00 … libbox.so` with a bare address.
That address does not resolve: `app/android/app/libs/libbox.aar` is stripped
(`nm` → “no symbols”). Exactly three things in it are worth reading — `SI_TKILL`
plus a non-`main` thread is the signature of a Go `abort()` (look for `go.log`,
not for a segfault); the `abort message` above `backtrace:`, if the runtime
managed to duplicate it there; and the metadata (`System Locale`, the ROM
version), which sets the context. Everything else lives in `Crashes`.

**If the Debug API is unavailable** (a user's device, no adb) the same material
comes from the app: **Debug → the Crashes tab**, a list with timestamps, tapping
one hands over the file. The whole archive also leaves through `Share dump` in the
`crash_archive` field (bodies are truncated at 64 KB). After a crash the app shows
a banner on the home screen by itself — **exactly once per crash** (the
`shown_crash_stamp` marker is `name@mtime` of the file that was shown).

The path to the screen is **drawer → Debug**, tabs `Log / Crashes / OOM /
Profiling`; `Share dump` is an app-bar icon on the same screen. Not “Settings”: App
Settings → Diagnostics holds only the toggles (`Forward sing-box logs`,
Profiling), and none of the evidence.

**`core_logs_enabled` has no effect on crash reports.** That toggle controls
forwarding the core's logs into `/logs/core`; the trace is written by libbox
itself through `SetupOptions.crashReportSource`. Reports for past crashes exist on
the user's device even with the toggle off — there is no need to ask them to turn
it on **before** collecting `Crashes`.

**What to ask the user for in a single message:** an archived report is a
DIRECTORY of three files (`go.log` + `metadata.json` + `configuration.json`), and
share hands over all three — you need all three, not just the trace:
`metadata.json` says which core build it died on, and `configuration.json` is the
config **at the moment of the crash** (which can differ from whatever the user
sent separately). With a series of crashes take the two or more latest: matching
traces immediately separate one bug from several.

The archive is rotated by the app at startup — the 10 newest (`kCrashKeep`); **the
core does not cap the folder size**, it only adds files to it on every `Setup()`.

### Core OOM snapshots (§318)

The second automatic evidence channel, this one about memory rather than panics.
When the core's oom-killer (§271, `SetupOptions.oomKillerEnabled`) sees RSS cross
the threshold, it drops a full set of pprof profiles **from the moment of the
problem** into `files/oom_reports/<ISO-timestamp>/`: `heap.pb`, `allocs.pb`,
`goroutine.pb`, `block.pb`, `mutex.pb`, `threadcreate.pb`, plus `metadata.json`
(memstats), `go.log`, `configuration.json` and `connections.json`.

The value is that this was captured **by itself, on the user's device** — no need
to reproduce a leak under a profiler.

```bash
curl -s -H "$HDR" "$BASE/files/oom/list" | jq            # were there snapshots
curl -s -H "$HDR" "$BASE/files/oom?name=<from list>" | jq  # the snapshot's memstats
curl -s -H "$HDR" "$BASE/files/oom?name=<from list>&file=heap.pb" -o heap.pb
go tool pprof -top heap.pb
```

What to read in `metadata.json`: `memoryUsage` (RSS) against `heapInuse` — a gap
means growth outside the Go heap (buffers, threads, native code); `numGoroutine`
with a stable heap means a goroutine leak; a seven-digit `numGC` with a small heap
means a GC storm at `GOMEMLIMIT` (§271).

Without the Debug API — **Debug → the OOM tab**: a list with the time, the size
and the RSS; tapping opens the memstats plus the log, and share hands over the
whole directory including the profiles. `Share dump` carries only the metadata
(the `oom_reports` field) — binary profiles have no place in JSON.

Rotation is done by the app at startup, keeping the 5 newest (`kOomKeep` — lower
than `kCrashKeep = 10` because one OOM snapshot is around 750 KB). **The core caps
neither the count nor the size**: the `writeOOMReport` debounce (at most once an
hour) lives in an instance field of the service and resets on every tunnel
restart. On the test device, 575 snapshots totalling 427 MB had piled up before
§318.

### What the pack was collected with (§378)

The first thing to read in someone else's dump is what it was taken on. At the
root of the JSON: `app_version` (the versionName, `X.Y.Z`), `app_build` (the
versionCode — under §379 the last digit encodes the ABI while the higher digits
carry the version and the stage, see [FDROID.md](FDROID.md)), and `core_version`
(`Libbox.version()`).

Before §378 the app version was absent from the pack entirely, and the core
version arrived by accident — as a field inside `oom_reports` / `crash_archive`. A
dump without snapshots gave neither. If you are working through an **old** pack,
look for the core version in those same places; the app version is nowhere to be
had, so ask the user.

## Analysis — what means what

### TCP socket states (`ss -tnp`)

| State | What it means | What it suggests |
|---|---|---|
| `ESTABLISHED` | An active exchange | A healthy connection |
| `SYN-SENT` (stuck) | We sent SYN, no SYN-ACK came back | The remote is unreachable / a DPI block / a firewall drop |
| `SYN-RECV` | We got SYN and are waiting for ACK | Normal, transient |
| `FIN-WAIT-1` (many) | We sent FIN and are waiting for the ACK | If there are **more than 100** — connections are not closing cleanly and the peer is not answering |
| `FIN-WAIT-2` | Our FIN was acked, waiting for the peer's FIN | Normal |
| `CLOSE-WAIT` | The peer closed, we have not | Possibly an application leak |
| `LAST-ACK` | We closed in response, waiting for the ACK of our FIN plus payload | If **send-q > 0**, our payload was never acknowledged — **the peer closed the connection before acking the payload** (a typical TLS reject by the remote) |
| `TIME-WAIT` | After closing, the 2×MSL pause | Normal |

**Health-check counts:** `awk '{print $1}' device_ss_tcp.txt | sort | uniq -c`.
Healthy: ESTAB > 30, FIN-WAIT < 30, SYN-SENT < 5. If ESTAB ≈ 3 with FIN-WAIT > 100
and SYN-SENT > 10, the network has degraded badly (DPI / an RST flood / a dead VPN
node).

### DNS resolutions (the profiler, §180)

DNS is now read in the profiler (`/profiler/live`, or the **Profiler**/**Conns**
tab in Stats) rather than in the logs: a `dnsResolve` (success) or `dnsFail`
(failure) event carrying the domain, the DNS server (rc.10) and the latency. For
failing resolutions with no owner UID there is the unattributed banner (§177) plus
`/profiler/live/unattributed`.

| Event / symptom | Cause |
|---|---|
| `dnsFail` after a long wait (10–20 s) | The DNS server never answered (a context deadline). The server is unreachable or blocked, or the route to it is dead. Look at the event's `dnsServer` and where it detours |
| `dnsFail` immediately, “no address” for the domain | A negative DNS response from the server; either the domain genuinely does not exist or the server is censoring it |
| `dnsResolve`, latency 16–50 ms | A healthy resolution |
| `dnsResolve`, latency above 500 ms | The server is overloaded, far away, or dropping packets |

### App-log warnings (`/logs?source=app`)

| Pattern | Source | What it says |
|---|---|---|
| `errno=113 No route to host` | The Dart httpClient / UpdateChecker | The outbound route to the remote is broken. On a public-internet IP that means the VPN exit is not working |
| `errno=111 Connection refused` | The same | A TCP RST from the peer, or a middlebox (DPI) |
| `urltest <outbound> → timeout/err` | The CommandClient urltest (ping) | The outbound does not answer the ping URL — a candidate for “this node is dead” |
| `[debug-api] ... → 4xx/5xx` | An internal Debug API call | An API error in the app; look at the endpoint |

### The sing-box routing decision (with debug logs)

With `core_logs_enabled=true` and `log.level: debug` in the template (or the
DebugScreen toggle), sing-box prints every routing decision:
`router: route ... matched ... → <outbound>`. Without debug there is only the info
level: `outbound: ...` (for non-direct). For the final routing chain per
connection the profiler is better (`routingLine` / `outboundChain`) — it does not
depend on the log level.

To turn it on temporarily: App Settings → Diagnostics → `Forward sing-box logs`
(requires a force-stop of the app).

### Routing rule precedence

sing-box matches on the **first rule that fits** (top down):

```
[0] resolve  (an action — the DNS resolve config for tun)
[1] sniff    (an action — extracting the SNI / HTTP host)
[2] hijack-dns (DNS packets into the DNS pipeline)
[3..N] custom rules (by rule_set / domain / process / package / port / ip_is_private / protocol)
[final] the default outbound for anything unmatched
```

⚠️ **The sniff race:** rules using `domain_suffix` or `domain_keyword` depend on
the sniffed SNI or HTTP host. `sniff timeout: 1s`. If a connection is established
but the ClientHello does not arrive within that second, the sniffed domain is
empty, the rule misses and traffic falls through.

⚠️ **The package-detection race (Android):** rules using `package_name` need the
owner UID resolved through `NetworkStatsManager.queryDetailsForUidTagState()` or
`/proc/net/tcp6`. Android 12+ adds restrictions. For short-lived transient TCP
sockets the lookup can arrive too late, the rule is silently skipped and traffic
falls through.

⚠️ **Lesson learned (2026-05-08):** ru.tinkoff.investing traffic to
`*.t-bank-app.ru` could land in `final` (vpn-1 = Poland) when **both** the sniff
and the package detection failed. A `Ru Apps` rule keyed on package_name is not
guaranteed for every TCP socket. **Mitigation:** always add explicit
`domain_suffix` entries to the `ru-direct` preset for critical domains.

---

## Common diagnostic flows

### “Site or app X does not open”

1. `/state` — is the tunnel up? Is the active node alive (`last_delay[<active_in_group>] != -1`)?
2. `/profiler/live` (or the **Conns** tab) — is there an active connection for domain X? Through which `outboundChain`?
3. If there is **no connection** to the expected IP, it never got as far as TCP:
   - A DNS failure? Look for a `dnsFail` event for domain X in `/profiler/live` (versus `dnsResolve`)
   - If DNS is fine, the app is not opening TCP at all — it may be queuing, waiting on another backend
4. If the connection **exists but `outboundChain` is unexpected** (say through a bypass VPN instead of `direct`), the routing match is wrong:
   - `config.route.rules` — which rule was supposed to match?
   - A sniff race, a package race, or the domain missing from the rule_set → it falls to final
5. If a connection sits **in LAST-ACK / FIN-WAIT with send-q > 0**, the backend rejected it (TLS / GeoIP / firewall) — fix the routing
6. If SYN-SENT entries are stuck en masse, the outbound node is dead or DPI is blocking it — switch the selector

### “After a long idle, DNS stops working / connections hang”

1. Take a snapshot **immediately**, before any reset or reload — `./scripts/lxbox-diag.sh` first, and destructive ops only after explicit confirmation (see “What **NOT** to do” below)
2. `/profiler/live` — which domains give `dnsFail`, and through which `dnsServer`? Plus `core_logs?level=error,warning` for context
3. `config.dns.servers` — which server serves those domains (per `dns.rules`)?
4. Is that server UDP, or DoH/DoT?
   - **DoH/DoT** — there is a persistent TLS pool that can “gum up” after a long idle. `POST /action/reset-network` cures it (offer that to the user).
   - **UDP** — stateless, there is no pool to break. The symptom is something else:
     - **A stuck DNS cache** (negative caching) — a reset cures that too
     - **An in-flight deadline lock** — a sing-box state issue; a reset helps
     - **A real network block** — a reset will not help; change the server or the detour

### “Some selector switched by itself / is not matching what I expect”

1. `/state` (`active_node` per group) — which node is selected in each selector?
2. `POST /action/urltest` (on the group or the node) — does it actually work?
3. `state.last_delay` history — was there an auto-test?
4. `/state/storage` `vars.dns_final` / `route_final` — what is selected in storage?
5. If the group default is `✨auto` (URLTest), it picks by ping on its own — look at the historical per-node delays

### “The node is alive but the ping is −1” — how to measure liveness (§305)

The measurement lies more often than the node dies. In §305 the conclusion
“MASQUE h3 is dead — 1 alive out of 62” turned out to be a measurement artifact:
after a correct run, h3 answered on all seven ports. **Before declaring a node
dead, check what measured it.**

| Method | Valid | Why |
|---|---|---|
| `POST /folders/{id}/probe` with the VPN **stopped** (headless, §236) | TCP only | A headless probe session **does not bring QUIC up**, so every h3/QUIC node reads as zero alive (a lie). h2/TCP measures fine in the meantime |
| `POST /folders/{id}/probe` with the VPN **running** | no | It refuses: `probe failed to start: __vpn_running__` (two CommandServers per process is impossible) |
| `rebuild-config` plus `urltest` **without a reconnect** | no | The core keeps running the old session, so live nodes report `-1` |
| `rebuild-config` → **`/action/reconnect`** → `urltest` **one at a time** | **yes** | The only trustworthy path |

The order for an honest measurement:

```bash
# 1. the nodes are already in a folder → fold them into the live config
curl -X POST -H "$HDR" "$BASE/action/rebuild-config"
# 2. MANDATORY: the core has to re-read the config
curl -X POST -H "$HDR" "$BASE/action/reconnect"
# 3. ping them ONE AT A TIME (a mass ping gives false -1 for QUIC: the handshakes compete)
curl -X POST -H "$HDR" "$BASE/action/urltest?tag=$(enc '<node tag>')"
sleep 6
curl -s -H "$HDR" "$BASE/state" | jq '.last_delay["<node tag>"]'
```

A live map of MASQUE endpoints (which IPs and ports should answer at all) is in
[spec/tasks/305](spec/tasks/305-masque-endpoint-h2-pool-and-override.md).

### “Load balance: traffic goes the wrong way / piles onto one server” (§208)

1. `/config` → the `balancer` on `<tag>-auto`: is `mode=round_robin`? Are `pool` / `pool_tolerance` / `sticky_hash` what you expect?
2. `/pool?tag=<tag>-auto` → what occupies the slots right now: four distinct live nodes, or duplicates and dead ones (`delay:0`)? Take it a few times — slots keep their numbers, and nodes change only on replacement.
3. Turn on `/profiler/live/start`, generate traffic, then `/profiler/live?seconds=120` → count `outbound_chain[0]` by node: it should be roughly even across the slots (with the default sticky key of `process+domain`, one domain stays on one node).
4. “Everything on one node” was a core bug in rc.14 (an empty sticky `domain`) and was fixed in rc.15. With `dest_ip` in the sticky key, a domain behind round-robin DNS (a CDN) legitimately spreads across nodes — that is not a bug.
5. `pool_tolerance>0` aggressively reshuffles slots as delays fluctuate, so a slot's keys legitimately move to a new node (the SPEC calls for “a reconnect for a slot whose occupant changed”). For a clean stickiness test use `pool_tolerance=0` (the pool then does not evict live nodes).

### “The VPN will not start, the status goes straight to Stopped with an alert”

§050 — sing-box does not start when the config contains `wifi_ssid:` or
`wifi_bssid:` rules but the Android permissions have not been granted.

1. `/state` → `last_error` begins with `Stopped: alert:permission_location:` — a structured alert from `BoxService.startSingbox` (ported from the SagerNet reference).
2. After the colon comes a comma-separated list of the missing permissions, typically:
   - `android.permission.ACCESS_BACKGROUND_LOCATION` — grantable at runtime **only through Settings** on API 30+ (there is no runtime prompt)
   - `android.permission.NEARBY_WIFI_DEVICES` — API 33+; **required** for a real SSID once `targetSdk≥33`. Without it `WifiInfo.ssid` is `"<unknown ssid>"` and Wi-Fi rules silently fail to match
3. Checking the current state:
   ```bash
   adb shell dumpsys package com.leadaxe.lxbox | grep -E "granted=" | grep -iE "location|nearby"
   ```
4. The cure: either grant through the Flutter dialog (there is an `Allow Wi-Fi info` button for one-tap NEARBY plus `Open Settings` for BACKGROUND_LOCATION), or `adb shell pm grant com.leadaxe.lxbox android.permission.NEARBY_WIFI_DEVICES` for a quick test
5. Alternatively, remove the Wi-Fi rules from the config. If `cs.needWIFIState() == false`, the permission check is skipped.

**A diagnostic marker**: on a successful startup logcat shows
`BoxService: [vpn] sing-box uses WIFI state, all permissions granted: [...]`. On a
failure it shows `BoxService: [vpn] config requires WIFI state but missing: [...]`.

### “`<unknown ssid>` in Wi-Fi rules”

If logcat shows `PIW: readWIFIState: <unknown ssid>` (a debug log from
[PlatformInterfaceWrapper](../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/PlatformInterfaceWrapper.kt)),
the permission grants are in place (no SecurityException) but `WifiInfo.ssid`
returned `"<unknown ssid>"`. On Android 13+ that means **`NEARBY_WIFI_DEVICES` is
missing**, even when ACCESS_FINE_LOCATION is granted (Google split Wi-Fi info from
location in API 33). The action: add `NEARBY_WIFI_DEVICES` to the manifest and
grant it through a runtime prompt.

### “The VPN drops by itself / ‘Another VPN app took the system VPN slot’”

Android keeps exactly **ONE** VPN slot. That message (§224/§276) is the system's
`VpnService.onRevoke()`, and Android sends it **only** when another `VpnService`
has taken the slot. Self-revocation is impossible (§224: a single `ServiceRecord`
with no `android:process`; the fd is closed synchronously before Dart is
unblocked). A process death by LMK delivers `SIGKILL` — no Java code runs, no
broadcast goes out, and `START_NOT_STICKY` does not restart it, so the tunnel
would vanish **silently, without this line**. Since the line is there, the
hijacker is real; go find it.

1. **Who owns the slot right now** — the only reliable source:
   ```bash
   adb shell dumpsys vpn_management | grep -iE "Active package|VpnTransportInfo|session"
   ```
   `getOwnerUid()` is unreachable from the app (`@hide`, privacy by design) — which is why the UI does not show a name and instead offers a “VPN settings” button (§241): on the system screen the active VPN is marked Connected.
2. **The chronology of the takeover** (who came up, and when):
   ```bash
   adb shell dumpsys usagestats | grep -iE "FOREGROUND_SERVICE_START|DEVICE_STARTUP|USER_UNLOCKED"
   ```
3. **The usual hijackers:**
   - a second VPN client with **Always-on / kill-switch** — it re-establishes its tunnel on a timer or a network change, which looks like “it drops every N minutes”;
   - **launch at boot** in someone else's VPN. The gotcha (the v2rayNG case, §241): BOOT_COMPLETED is deferred by Direct Boot until USER_UNLOCKED, so the takeover lands a minute or two after unlocking — which reads as “the VPN died on its own after a minute” rather than as a boot race. The setting is not called “autostart” but “Auto-connect on start” (`pref_is_booted`);
   - **Samsung Secure Wi-Fi** (`com.samsung.android.fast`) — a built-in VpnService that can enable itself on Wi-Fi;
   - on weak devices LMK kills **the other** VPN, which restarts through its own auto-start and takes the slot — LMK is the trigger here, but the revoker is still someone else's app.
4. Our pre-check `isForeignVpnActive()` (§211) only catches an occupied slot **before** a manual start; by definition it cannot see a takeover during a running session.

### The workflow for an unfamiliar bug

1. `./scripts/lxbox-diag.sh` (or the same calls by hand, in parallel)
2. To the user: “the snapshot is taken, carry on using it. What exactly is not working — the domain, the app, the time it broke?”
3. Analyse the snapshot (without triggering anything on the device)
4. If one cycle is not enough, ask the user to reproduce it again, take a second snapshot and **diff them**

---

## What **NOT** to do while diagnosing

> Every one of these destroys runtime evidence. Afterwards the root cause is often
> unknowable.

| Op | What it ruins | When it is allowed |
|---|---|---|
| `POST /action/reset-network` | The DNS cache, active connections, transport state | After a snapshot, plus an explicit “go ahead” from the user |
| `POST /action/rebuild-config` | Active connections (closed), routing decisions | At the user's request |
| A reload from the UI button | The same as reset-network | At the user's request |
| `POST /action/stop-vpn` / start-vpn | The tun teardown, RAM state | At the user's request |
| `PUT /config` | The live config is replaced, not gracefully | Only in an experiment, with `config_locked=true` set beforehand |
| `PUT /settings/*` | Changes storage at runtime, which may trigger a rebuild | If changing it for a test, set `config_locked` beforehand |
| `adb shell am force-stop com.leadaxe.lxbox` | A complete RAM wipe | After a snapshot |

**Auto-rebuild safety:** to experiment with the config through `PUT /config`,
first `PUT /settings/config_locked {"locked": true}`. Then any UI-triggered
rebuild silently no-ops (§037) and your custom config will not be overwritten.

---

## Going further (when you need more)

- **tcpdump / packet capture** — when you need to see the TLS ClientHello, RSTs or MTU issues. Requires root (or one of the rare debug builds of Android).
- **sing-box debug level** — `vars.log_level = debug` plus a force-stop. Prints every routing decision and dial event. It increases log volume a lot.
- **Per-app routing testing** — `adb shell am start -n <activity>` launches the target app on cue; capture `ss` and `/profiler/live` at that moment.
- **`adb shell ping`** — usually blocked without root. Use `POST /action/urltest` (which pings nodes and groups through the core) instead.
- **QUIC knobs for GSO/ECN (§341)** — `POST /action/quic-knobs?gso=on|off[&ecn=on|off]`: an A/B check of quic-go offload hypotheses (hysteria2/tuic/masque-h3 dead on a vendor kernel) without rebuilding. `off` sets the `QUIC_GO_DISABLE_*` env vars, `on` restores auto-detection. It only affects NEW QUIC sockets — follow a switch with `reload-vpn` or `reset-network`. `native_ok=false` means the AAR is older than SPEC 044.
- **pprof — CPU heat and core memory leaks (§207)** — for deep diagnosis of the sing-box runtime. The tunnel has to be up.
  ```bash
  TOKEN=...   # forward 9269 to the phone
  H="Authorization: Bearer $TOKEN"
  # A CPU profile (10 s) — busy spin / 100% CPU
  curl -s -H "$H" "http://127.0.0.1:9269/diag/pprof?profile=profile&query=seconds=10" -o cpu.pb
  go tool pprof -top cpu.pb
  # Heap (what holds memory now; gc=1 forces a GC)
  curl -s -H "$H" "http://127.0.0.1:9269/diag/pprof?profile=heap&query=gc=1" -o heap.pb
  go tool pprof -inuse_space -top heap.pb
  # Goroutine stacks (a goroutine leak) — returns text, not a .pb
  curl -s -H "$H" "http://127.0.0.1:9269/diag/pprof?profile=goroutine&query=debug=2"
  ```
  Or from the UI: App Settings → Diagnostics → Profiling (the buttons plus the system share sheet).

---

## Reference

- [Debug API reference](api/debug-api-reference.md) — the full endpoint list (including the destructive ones)
- [STORAGE.md](STORAGE.md) — what is inside the `state/storage` snapshot
- [TEMPLATE.md](TEMPLATE.md) — how to read `wizard_template.json` to work out where the vars, presets and DNS servers are defined
- [spec/tasks/305 — MASQUE endpoint](spec/tasks/305-masque-endpoint-h2-pool-and-override.md) — a device-verified map of live WARP-MASQUE IPs and ports (h3 versus h2), plus the table of “what to measure node liveness with”
- [scripts/lxbox-diag.sh](../scripts/lxbox-diag.sh) — the automatic snapshot collector
- [scripts/ensure-wifi-adb.sh](../scripts/ensure-wifi-adb.sh) — bring up wifi-adb (USB → tcpip 5555)
- [scripts/install-apk.sh](../scripts/install-apk.sh) — install plus an automatic Debug API forward
