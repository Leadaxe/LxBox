[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Live state — VPN traffic statistics, connections and running config

LxBox shows live traffic, open connections and the running config of the
sing-box core, with the owner app, rule and node of each connection. The data
appears in the home-screen traffic bar and on the Statistics screen with the
Stats and Conns tabs; the Profiler tab is described in 028-TRAFFIC_PROFILER.

| Field | Value |
|-------|-------|
| Feature | 012-LIVE_STATE |
| Type | Product feature |
| Absorbed | `§016F` `§122F` `§123F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

With the tunnel up, the user wants to see what is going on inside: how much has
been transferred, how many connections are open, where a particular app goes,
through which rule and which node it went out, which config the core is
actually running. The feature turns the core's internal state into observable
screens and numbers — without open ports, manual dumps or external tools.

The feature protects four principles:

- **The two worlds of status do not mix.** "Tunnel up / stopped" is said by the
  tunnel service; the core's data channels give only statistics. A break or
  sleep of a data channel does not look like the tunnel going down.
- **Observation does not cost battery.** Data frequency is cut at the source:
  the home screen needs two ticks per second, statistics — ten, background —
  zero. In the background only what the user explicitly started lives (profiler
  recording).
- **The truth about a packet's path comes from the core.** The chain "rule →
  groups → node → detour → target" and the owner of a connection are taken
  from the core, not guessed by the client.
- **An honest "don't know".** The verdict "config is stale" has a third value —
  "cannot answer"; a failed comparison is not reported as a match.

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
  open 0.1 s, background — 0. **Witness**: unit
  `test/vpn/cc_status_fast_test.dart` (Dart-side contract only —
  `CcChannel.setStatusFast` calls `ccSetStatusFast{fast}`, called by
  `StatsScreen.initState`/`dispose`; the native interval switch itself is
  device-only, one-off check §164). **Mutation**: `setStatusFast` stops
  sending `fast` as an argument or uses the wrong key/method.
- **P3. Only profiler recording lives in the background.** Status and
  groups/connections go to sleep on backgrounding and wake on return; a
  profiler recording already started continues. **Witness**: manual check —
  START in the profiler, background for 2 min, return: the log has events from
  the background period. **Mutation**: the profiler pauses together with the
  other channels.
- **P4. Connection counters are consistent.** On the home screen — separately
  "app connections" and "connections to servers"; the first equals the number
  on the Connections card in statistics and the "active" number in the Conns
  tab. **Witness**: unit
  `test/controllers/connection_counters_consistency_test.dart` — pins that
  `HomeController._onCcStatus` copies `CcStatus.connectionsIn/Out` 1:1 into
  `HomeState.traffic` (the same field Stats reads verbatim), with
  `activeConnections` as their sum, not an independent count. **Mutation**:
  `_onCcStatus` swaps or stops copying `connectionsIn`/`connectionsOut`
  1:1.
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
- **P9.** moved to [028-TRAFFIC_PROFILER · P5](../028-TRAFFIC_PROFILER/FEATURE.md#promises).
- **P10.** moved to [028-TRAFFIC_PROFILER · P6](../028-TRAFFIC_PROFILER/FEATURE.md#promises).
- **P11.** moved to [028-TRAFFIC_PROFILER · P7](../028-TRAFFIC_PROFILER/FEATURE.md#promises).
- **P12.** moved to [028-TRAFFIC_PROFILER · P1](../028-TRAFFIC_PROFILER/FEATURE.md#promises).
- **P13.** moved to [028-TRAFFIC_PROFILER · P3](../028-TRAFFIC_PROFILER/FEATURE.md#promises).
- **P14.** moved to [028-TRAFFIC_PROFILER · P11](../028-TRAFFIC_PROFILER/FEATURE.md#promises).
- **P15.** moved to [028-TRAFFIC_PROFILER · P13](../028-TRAFFIC_PROFILER/FEATURE.md#promises).
- **P16.** moved to [028-TRAFFIC_PROFILER · P14](../028-TRAFFIC_PROFILER/FEATURE.md#promises).
- **P17.** moved to [028-TRAFFIC_PROFILER · P15](../028-TRAFFIC_PROFILER/FEATURE.md#promises).
- **P18.** moved to [028-TRAFFIC_PROFILER · P16](../028-TRAFFIC_PROFILER/FEATURE.md#promises).
- **P19. NETWORKS shows nodes outside the selection lists.** Tailscale nodes
  from `endpoints[]` without `exit_node` are visible as a separate
  pseudo-direction with the VPN up, with a state instead of latency; such a
  node cannot be chosen as the exit. **Witness**: units "NETWORKS
  composition", "VPN off — NETWORKS is not shown", "a state in place of
  latency, a tap does not select the node". **Mutation**: NETWORKS is written
  to the config as a group. In detail — [030-TAILSCALE](../030-TAILSCALE/FEATURE.md).
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
  closed; in Conns they become closed. **Witness**: unit
  `test/controllers/interrupt_on_switch_test.dart` — with the toggle on,
  `switchNode` closes only live connections whose `chains` contains the
  switched group (not closed ones, not other groups' connections); with the
  toggle off, nothing closes. **Mutation**: `_connectionIdsInGroup` stops
  filtering by `chains.contains(group)` (e.g. closes all live connections).

## Controlled parameters

| Setting | Values | Default | Where |
|---------|--------|---------|-------|
| Showing closed connections | 30 s / all until turned off | 30 s | a toggle in the Conns tab; only while the screen is open |
| Interrupt connections on switch | on/off | off | belongs to 010-VPN_SERVICE; here — the observable effect |

Fixed values (not configurable): status tick 0.5 s / 0.1 s / 0 in the
background; home-screen counters redrawn at most once per 1 s; statistics
and connection lists recomputed at most once per 0.7 s; the core keeps closed
connections for 5 min; status channel reconnect — from 0.5 s to 8 s. The
profiler's knobs and quotas — 028-TRAFFIC_PROFILER.

**Contract with the core.** The feature emits no config keys. Consumed core
calls and subscriptions: `CommandStatus` (volume, memory, goroutines,
`connectionsIn` / `connectionsOut`, the interval is set by the subscriber),
`CommandGroup`, `CommandOutbounds`, `CommandConnections` (deltas; the `chain`,
the `detour` tail, owner, `createdAt`/`closedAt`), `CommandDNS` (stream of DNS
queries, consumed by 028-TRAFFIC_PROFILER),
`GetGroups`, `GetOutbounds`, `GetRunningConfig`, `FormatConfig`,
`closeConnection`, `closeConnections`, `SubscribeTailscaleStatus`
(`BackendState`, `StateText`).

## Inputs / Outputs

**Inputs:** the tunnel service status; core subscriptions and replies (see
"Contract with the core"); the app lifecycle; gestures — Statistics,
START/STOP of the profiler recording, closing connections; the saved config;
the rule catalog.

**Outputs:** the home-screen traffic bar (↑/↓ volume, app connections and
connections to servers, the "Live" indicator, connection time); the Statistics
screen with the Stats / Conns tabs; connection details; NETWORKS node
rows; the running-config snapshot and the freshness verdict for the "restart
needed" banner; `closeConnection` / `closeConnections` calls.

## Data flow

```
core ──CommandStatus──► status (0.5 / 0.1 / 0 s) ──► traffic bar, Stats
     ──Group/Outbounds──► groups ─(+ GetGroups pull)─► node list
     ──Connections (deltas)──► per-client accumulator ──► snapshot
          ├─► Stats: live only → by rule
          ├─► Conns: live + closed (30 s / all)
          └─► profiler channel (when recording) ──► 028-TRAFFIC_PROFILER
     ──CommandDNS──► profiler channel ────────────────► 028-TRAFFIC_PROFILER
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
- On tunnel stop the channel caches are reset.
- One-off calls distinguish "unavailable" from "empty"; "unavailable" does not
  touch the screen.

## Boundaries

- Start, stop, reconnect, recognizing a "silent core" by status silence —
  010-VPN_SERVICE.
- The profiler and the DNS trace — 028-TRAFFIC_PROFILER: recording,
  attribution, filters, DNS health, the `/profiler/*` routes.
- The app and core log, crash reports — 013-DIAGNOSTICS; the Debug API —
  027-DEBUG_API.
- The "restart needed" banner and when to raise it — 003-CONFIG_BUILD; here
  only the verdict that can clear it.
- Latency measurement, the probe — 009-NODE_HEALTH; the Tailscale Network tab
  — 030-TAILSCALE; node selection and the list of directions — 007-NODE_LIST
  (NETWORKS is only added).
- There is no per-app traffic breakdown on the Stats screen, and it is not
  planned (owner decision 2026-09-29, audit [591](../../tasks/591-spec-kit-revision-audit.md)) — that is the profiler's log.
- Depends on OS capabilities: "foreground / background" events, the traffic
  owner.

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Status and traffic bar | Shows the tunnel state and the traffic bar on the home screen: volume, app and server connections, connection time and the VPN bypass warning. | P1, P4 | [connection-status.md](FUNCTIONS/connection-status.md) |
| Core data channels and energy model | Delivers core subscriptions to the screens at the rate the user sees, sleeps in the background and recovers after the app is reopened. | P2, P3, P5 | [data-channels.md](FUNCTIONS/data-channels.md) |
| Traffic statistics | Shows the session volume, the number of live connections, process memory and traffic per routing rule down to a single connection. | P6 | [traffic-statistics.md](FUNCTIONS/traffic-statistics.md) |
| Live connections | Lists live and recently closed connections with the routing line, highlights one-way ones and closes one, all, or those of a switched group. | P7, P8, P22 | [live-connections.md](FUNCTIONS/live-connections.md) |
| NETWORKS pseudo-direction | Shows Tailscale nodes without `exit_node` as a separate row on the home screen, with their live state instead of latency. | P19 | [networks-direction.md](FUNCTIONS/networks-direction.md) |
| Running config and freshness verdict | Keeps a snapshot of the config the core runs and answers whether the saved config matches it: "matches", "stale" or "don't know". | P20, P21 | [running-config.md](FUNCTIONS/running-config.md) |

Traffic profiler moved to [028-TRAFFIC_PROFILER](../028-TRAFFIC_PROFILER/FEATURE.md).
DNS query trace moved to [028-TRAFFIC_PROFILER](../028-TRAFFIC_PROFILER/FEATURE.md).

## Related features

- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — owns the "restart
  needed" banner; this feature only supplies the freshness verdict that can
  clear it.
- [004-ROUTING](../004-ROUTING/FEATURE.md) — the user rule catalog that names
  rules in statistics and connections.
- [007-NODE_LIST](../007-NODE_LIST/FEATURE.md) — node selection and the list of directions, to which NETWORKS is added.
- [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md) — the Tailscale node's
  Network tab, sharing the state subscription with NETWORKS.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — latency measurement and
  the node probe; the speed test defers home-screen speed to this feature.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — the tunnel service that
  owns the status, "Connection lost" on status silence and the "Interrupt
  connections on switch" setting.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — app and core logs,
  crash reports.
- [019-CONFIG_EDITOR](../019-CONFIG_EDITOR/FEATURE.md) — viewing the resulting config.
- [027-DEBUG_API](../027-DEBUG_API/FEATURE.md) — the Debug API: `/state/*`
  and `/config/running` read what this feature shows.
- [028-TRAFFIC_PROFILER](../028-TRAFFIC_PROFILER/FEATURE.md) — the profiler
  and the DNS trace built on the profiler channel of this feature.
- [030-TAILSCALE](../030-TAILSCALE/FEATURE.md) — the Tailscale node behind
  the NETWORKS row: its identity, the Network tab and the tailnet route.

## Maintenance notes

- Connections are deltas, not a snapshot. Any "optimization" that drops deltas
  with no subscriber gives an empty Stats with live traffic (§122, §193).
- One connection accumulator for two channels crashes the core — only separate
  ones (§170).
- After swiping from recents the data channels are orphaned: on the first
  start of the new engine they must be resynced, but only on the first —
  otherwise every tunnel reconnect loses connections (§185, §193).
- The list of fields the core overlays on top of the config at start lives in
  two places (the freshness verdict and the service); a divergence gives an
  eternal "stale" or a missed change — held by an invariant test (§324).
- After a reload the core keeps answering with the previous config for another
  ~1 s without an error; the replies are told apart by content, and an
  identical config is accepted after ~5 s (§311, §384).
