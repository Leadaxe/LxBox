[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# FEATURE 012 — LIVE_STATE — live state of the running core

| Field | Value |
|-------|-------|
| Type | Product feature |
| Absorbed | `§016F` `§044F` `§122F` `§123F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

With the tunnel up, the user wants to see what is going on inside: how much has
been transferred, how many connections are open, where a particular app goes,
through which rule and which node it went out, which DNS queries fail to
resolve, which config the core is actually running. The feature turns the
core's internal state into observable screens and numbers — without open
ports, manual dumps or external tools.

The feature protects four principles:

- **The two worlds of status do not mix.** "Tunnel up / stopped" is said by the
  tunnel service; the core's data channels give only statistics. A break or
  sleep of a data channel does not look like the tunnel going down.
- **Observation does not cost battery.** Data frequency is cut at the source:
  the home screen needs two ticks per second, statistics — ten, background —
  zero. In the background only what the user explicitly started lives (profiler
  recording).
- **The truth about a packet's path comes from the core.** The chain "rule →
  groups → node → detour → target", the owner of a connection and of a DNS
  query are taken from the core, not guessed by the client.
- **An honest "don't know".** The verdict "config is stale" has a third value —
  "cannot answer"; an event without an owner is shown as "no owner", not
  hidden.

## Promises

- **P1. Tunnel status does not depend on data channels.** Sleep or a break of
  the core's data channels does not move the tunnel to "disconnected"; turning
  the tunnel off in the background is noticed without them too. **Witness**:
  manual check — tunnel up, background the app for a minute, return: status
  "Connected" without blinking, counters came alive; stop the tunnel from the
  shade with the app in the background — on return the status is
  "Disconnected". **Mutation**: the tunnel status is derived from the data
  channel's connect events.
- **P2. Frequency is cut at the source.** Status tick: home 0.5 s, Statistics
  open 0.1 s, background — 0. `no witness` (one-off check §164).
- **P3. Only profiler recording lives in the background.** Status and
  groups/connections go to sleep on backgrounding and wake on return; a
  profiler recording already started continues. **Witness**: manual check —
  START in the profiler, background for 2 min, return: the log has events from
  the background period. **Mutation**: the profiler pauses together with the
  other channels.
- **P4. Connection counters are consistent.** On the home screen — separately
  "app connections" and "connections to servers"; the first equals the number
  on the Connections card in statistics and the "active" number in the Conns
  tab. `no witness`.
- **P5. Reopening does not lose data.** Re-entering statistics, reconnecting the
  tunnel and returning after swiping from recents show the current groups and
  connections, not an empty screen. **Witness**: manual check — swipe the app
  away with the tunnel up, open it from the icon: groups and the connection
  list are in place (§185 device-verified). **Mutation**: connections
  accumulate only while the screen is subscribed.
- **P6. The rule is named in human terms.** The rule name in statistics and
  connections is taken from the user's rule catalog; one not found — `final`.
  **Witness**: units "match by conditions → title (even when the core truncates
  the list)", "rule not found → fallback final". **Mutation**: showing the raw
  core string.
- **P7. A hung connection is highlighted.** TCP older than 3 s with traffic
  strictly in one direction is marked "One-way"; UDP, fresh and closed ones are
  not. **Witness**: units "TCP, age≥3s, up>0 down=0 → true", "one-sided UDP →
  false", "fresh (<3s) → false", "closed → false". **Mutation**: the age
  threshold removed.
- **P8. One routing line for connections and the profiler.** On the left — how
  the router chose (`rule ⇒ groups`), to the right of `:` — the physical path of
  the packet (entry first, exit before the target); an empty rule — `final`; no
  domain — the host from the address. **Witness**: units "§204 routingLineOf
  1:1 Conn ↔ Event", "chains and detours are carried SEPARATELY".
  **Mutation**: detour glued into the group chain.
- **P9. A short connection is seen whole and once.** A connection opened and
  closed between ticks gives both phases; a closed one that keeps arriving in
  snapshots for another 5 min is closed exactly once. **Witness**: units
  "short conn with closedAt>0 at once → both phases", "the same closed conn for
  2 ticks → ONE close". **Mutation**: the consumer receives only live
  connections.
- **P10. Connection time is by the core's clock.** Duration is computed from
  the core's timestamps; a "probable RST" is a close in under 1 s with no bytes.
  **Witness**: units "kernel timestamps: duration from createdAt/closedAt",
  "TCP RST early flagged on close". **Mutation**: duration from the moment the
  snapshot arrived.
- **P11. The owner comes from the core; no owner is visible.** The app package
  is taken from the core's data (the UID suffix is stripped); an event without
  an owner is marked "no owner". The unattributed warning is lit only by
  failures (DNS failure, TCP/UDP without an owner), more than 5 within 30 s.
  **Witness**: units "UID-suffixed package name → verified", "successful
  unattributed DNS resolves do NOT light the banner". **Mutation**: a
  successful DNS without an owner counts as an alarm.
- **P12. Recording — only on an explicit START.** Without recording, events do
  not accumulate. **Witness**: unit "recording off → events ignored".
  **Mutation**: auto-start of recording.
- **P13. The log retention window is selectable and remembered.** 1 min / 10 min
  / 1 h, default 10 min, survives a restart. **Witness**: unit "profiler
  retention — default + round-trip + persist". **Mutation**: the window is a
  hard-coded constant.
- **P14. The profiler filter lives for the whole app session.** Switching tabs
  and leaving statistics do not reset the filter; reset — "Reset all" or a
  restart. **Witness**: units §244 "the filter survives unmount/remount".
  **Mutation**: the filter is a field of the screen.
- **P15. DNS is attributed to what was asked.** The event carries the original
  domain, the CNAME chain separately and the first answer address as the IP.
  **Witness**: units "DNS chain attribution: CNAME hops in answers, ip = final
  A", "rdata as a FULL RR string → take the value". **Mutation**: the event
  domain = the final CNAME target.
- **P16. A DNS failure is an event with a reason.** The core's failure flag
  decides, not the response code; `-1` — "there was no reply". **Witness**:
  unit "DNS fail produces dnsTimeout issue". **Mutation**: failure by the
  response code.
- **P17. DNS group trace — only on group queries.** The group path, member
  probes, fan-out and survival mode are visible in the event details; ordinary
  queries have none of these fields. **Witness**: units §315 "fan-out: path,
  probes and the fanned flag", "NOT a group query → no trace keys".
  **Mutation**: empty trace fields on every event.
- **P18. DNS degradation is recognized while the link is alive.** The banner "N%
  of DNS queries failing" — at a failure share ≥ 20 % and at least 3 failures
  within 30 s, and only if there were connections in the same window.
  **Witness**: units §262 "3 fails of 10 + activity → unhealthy", "5 fails
  100%, but NO conn activity → healthy". **Mutation**: the activity gate
  removed.
- **P19. NETWORKS shows nodes outside the selection lists.** Tailscale nodes
  from `endpoints[]` without `exit_node` are visible as a separate
  pseudo-direction with the VPN up, with a state instead of latency; such a
  node cannot be chosen as the exit. **Witness**: units "NETWORKS
  composition", "VPN off — NETWORKS is not shown", "a state in place of
  latency, a tap does not select the node". **Mutation**: NETWORKS is written
  to the config as a group.
- **P20. The freshness verdict is three-valued.** "Matches / stale / don't
  know"; "don't know" does not clear the "restart needed" banner. **Witness**:
  units §324 "no canonical form → unknown (NOT fresh)", "no snapshot of the
  running one → unknown". **Mutation**: a comparison failure is treated as
  "matches".
- **P21. The running-config snapshot belongs to its core session.** A core
  reply that came from the previous session after a reload is not accepted;
  after a reload the snapshot is re-captured; with the tunnel down the saved
  config is used. **Witness**: units §311 "the old box's reply does not survive
  reload", "after reload the snapshot is re-captured with retries", "tunnel
  down with a live snapshot → configModel". **Mutation**: a snapshot not bound
  to the session.
- **P22. Breaking on node switch — only the switched group.** With "Interrupt
  connections on switch" the live connections with that group in the chain are
  closed; in Conns they become closed. `no witness`.

## Controlled parameters

| Setting | Values | Default | Where |
|---------|--------|---------|-------|
| Profiler log retention window | 1 min / 10 min / 1 h | 10 min | the `⏱` button in the profiler control row; part of the backup |
| Profiler recording | START / STOP | stopped | Profiler tab header; only until the app restarts |
| Showing closed connections | 30 s / all until turned off | 30 s | a toggle in the Conns tab; only while the screen is open |
| Log grouping | stream / by domain / by IP | stream | the "Grouping" menu |
| Log filter | axes Protocol (DNS/TCP/UDP), App (packages + "no owner"), Rule, Outbound; search by domain/IP/app | empty | the "Filter" window; the whole app session |
| Interrupt connections on switch | on/off | off | belongs to 010-VPN_SERVICE; here — the observable effect |

Fixed values (not configurable): status tick 0.5 s / 0.1 s / 0 in the
background; home-screen counters redrawn at most once per 1 s; statistics,
connections and log lists recomputed at most once per 0.7 s; log ceiling
20,000 events; ring of unowned events — 50; the core keeps closed connections
for 5 min; status channel reconnect — from 0.5 s to 8 s.

**Contract with the core.** The feature emits no config keys. Consumed core
calls and subscriptions: `CommandStatus` (volume, memory, goroutines,
`connectionsIn` / `connectionsOut`, the interval is set by the subscriber),
`CommandGroup`, `CommandOutbounds`, `CommandConnections` (deltas; the `chain`,
the `detour` tail, owner, `createdAt`/`closedAt`), `CommandDNS` (stream of DNS
queries: domain, type, rcode, answer source, failure flag and reason, owner,
server and its type, channel, answers, group path, probes, fan-out, survival),
`GetGroups`, `GetOutbounds`, `GetRunningConfig`, `FormatConfig`,
`closeConnection`, `closeConnections`, `SubscribeTailscaleStatus`
(`BackendState`, `StateText`).

## Inputs / Outputs

**Inputs:** the tunnel service status; core subscriptions and replies (above);
the app lifecycle; gestures — Statistics, START/STOP, closing connections,
filter, grouping, retention window, export; the saved config; the rule
catalog.

**Outputs:** the home-screen traffic bar (↑/↓ volume, app connections and
connections to servers, the "Live" indicator, connection time); the Statistics
screen with the Stats / Conns / Profiler tabs; connection and event details;
log export to JSON; the "no owner" and "DNS degrading" banners; NETWORKS node
rows; the running-config snapshot and the freshness verdict for the "restart
needed" banner; `closeConnection` / `closeConnections` calls.

## Data flow

```
core ──CommandStatus──► status (0.5 / 0.1 / 0 s) ──► traffic bar, Stats
     ──Group/Outbounds──► groups ─(+ GetGroups pull)─► node list
     ──Connections (deltas)──► per-client accumulator ──► snapshot
          ├─► Stats: live only → by rule
          ├─► Conns: live + closed (30 s / all)
          └─► profiler (when recording): open/close events
     ──CommandDNS──► profiler: resolve/fail events ──► log (window, 20,000)
                                   └─► DNS health detector → banner
     ──GetRunningConfig──► session snapshot ──► node model; comparison with
                              the canonical saved one (FormatConfig) → verdict
tunnel service ──status──► Connected/Disconnected (independent of the channels)
```

## Rules and guarantees

- The tunnel status comes from the service; the "data channel connected /
  disconnected" events are used only to reconnect the channel.
- The channels are separated by lifecycle: status, screens
  (groups+connections), profiler, one-off calls; a status frequency change does
  not break the others.
- Connections arrive as deltas: the accumulator applies every delta even when
  no screen is listening; a new subscriber immediately gets what has
  accumulated.
- An empty group snapshot on top of a non-empty one is ignored; initial groups
  are fetched with a one-off `GetGroups` (up to ~5 s in steps of 0.4 s).
- Each connection consumer decides itself what to show: Stats — live only,
  Conns — live and closed, the profiler — everything as events.
- On tunnel stop the channel caches are reset; the profiler log is in memory
  only, an app restart erases it.
- One-off calls distinguish "unavailable" from "empty"; "unavailable" does not
  touch the screen.

## Boundaries

- Start, stop, reconnect, recognizing a "silent core" by status silence —
  010-VPN_SERVICE.
- The app and core log, Debug API (including exporting the profiler log
  outward), crash reports — 013-DIAGNOSTICS.
- The "restart needed" banner and when to raise it — 003-CONFIG_BUILD; here
  only the verdict that can clear it.
- Latency measurement, the probe, the Tailscale Network tab — 009 / 008; node
  selection and the list of directions — 007-NODE_LIST (NETWORKS is only added
  to it).
- There is no per-app traffic breakdown on the Stats screen; per-app sessions
  and a separate App tab were removed — only the shared log with an App filter.
- Depends on OS capabilities: "foreground / background" events, the traffic
  owner.

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Status and traffic bar | Two worlds of status, home counters, connection time, bypass warning | P1, P4 | [connection-status.md](FUNCTIONS/connection-status.md) |
| Data channels and energy model | Core subscriptions, frequency, sleep in the background, recovery after reopening | P2, P3, P5 | [data-channels.md](FUNCTIONS/data-channels.md) |
| Traffic statistics | Summary, traffic by rules, process memory | P6 | [traffic-statistics.md](FUNCTIONS/traffic-statistics.md) |
| Live connections | List, details, closing, hung ones, routing line, breaking on node switch | P7, P8, P22 | [live-connections.md](FUNCTIONS/live-connections.md) |
| Traffic profiler | Recording, a log across all apps, attribution, grouping, filter, export | P9–P14 | [traffic-profiler.md](FUNCTIONS/traffic-profiler.md) |
| DNS trace | DNS events with attribution, CNAME, failures, group trace, health detector | P15–P18 | [dns-trace.md](FUNCTIONS/dns-trace.md) |
| NETWORKS pseudo-direction | Tailscale nodes outside the selection lists with their state | P19 | [networks-direction.md](FUNCTIONS/networks-direction.md) |
| Running config and freshness | Config snapshot from the core, verdict "matches / stale / don't know" | P20, P21 | [running-config.md](FUNCTIONS/running-config.md) |

## Related features

- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — owns the "restart needed" banner; this feature only supplies the freshness verdict that can clear it.
- [004-ROUTING](../004-ROUTING/FEATURE.md) — the user rule catalog that names rules in statistics, connections and the profiler.
- [005-DNS](../005-DNS/FEATURE.md) — DNS groups, DNS and FakeIP settings behind the DNS trace and the "DNS queries are failing" sheet.
- [007-NODE_LIST](../007-NODE_LIST/FEATURE.md) — node selection and the list of directions, to which NETWORKS is added.
- [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md) — the Tailscale node's Network tab, sharing the state subscription with NETWORKS.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — latency measurement and the node probe; the speed test defers home-screen speed to this feature.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — the tunnel service that owns the status, "Connection lost" on status silence and the "Interrupt connections on switch" setting.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — app and core logs, the Debug API (including serving the profiler log), crash reports.
- [019-CONFIG_EDITOR](../019-CONFIG_EDITOR/FEATURE.md) — viewing the resulting config.

## Maintenance notes

- Connections are deltas, not a snapshot. Any "optimization" that drops deltas
  with no subscriber gives an empty Stats with live traffic (§122, §193).
- One connection accumulator for two channels crashes the core — only separate
  ones (§170).
- After swiping from recents the data channels are orphaned: on the first
  start of the new engine they must be resynced, but only on the first —
  otherwise every tunnel reconnect loses connections (§185, §193).
- The core keeps closed connections for 5 min and sends them every tick: a
  consumer that does not remember what it has already closed produces
  duplicates (§176).
- The `rdata` of a DNS answer is the full record string, not the value (§180).
- The list of fields the core overlays on top of the config at start lives in
  two places (the freshness verdict and the service); a divergence gives an
  eternal "stale" or a missed change — held by an invariant test (§324).
- After a reload the core keeps answering with the previous config for another
  ~1 s without an error; one has to tell them apart by content, and accept an
  identical config after ~5 s (§311, §384).
