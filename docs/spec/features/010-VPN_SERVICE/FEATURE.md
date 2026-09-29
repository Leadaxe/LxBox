[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# VPN service — starting, stopping and keeping the Android VPN tunnel alive

LxBox runs the sing-box core as an Android VPN service and shows "Connected"
or "Stopped" only after the core has confirmed the transition. The feature
covers the VPN and local proxy modes, autostart after boot, recovery after
process death or a core crash, reaction to Wi-Fi and mobile network changes,
coexistence with another VPN app, and battery and memory savings for
WireGuard and AmneziaWG nodes.

| Field | Value |
|------|----------|
| Feature | 010-VPN_SERVICE |
| Type | Product feature |
| Absorbed | `§012F` `§042F` `§119F` `§124F` `§128F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

The tunnel is what the app exists for: the user taps "Start" and traffic goes
through the chosen node; taps "Stop" and it no longer does. Everything else in
this feature is about keeping that simple promise in the real life of a phone:
on reboot, when the app is closed, when the process dies, when Wi-Fi changes to
mobile data, while the screen sleeps, when another VPN wants to take the same
system slot, and when memory runs short.

The feature protects three principles:

- **Honest status.** "Stopped" is said only when the tunnel is really stopped;
  "connected" — only when the core has confirmed the start. A hang is not
  hidden behind an eternal "Connecting…" — every transitional phase has a
  deadline.
- **The user's explicit will outranks automation.** No watchdog overrides a
  manual "Stop"; auto-restart works only while the tunnel is "wanted".
- **Saving is an option, reliability is the default.** Tunnel sleep is off by
  default; suspending idle WireGuard tunnels does not touch the active route
  until the user allows it.

## Promises

- **P1. Stop is confirmed, not assumed.** "Stop" completes successfully only
  after the actual stop; a slow but successful stop (up to ~9 s on a heavy
  tunnel) is not an error; an unconfirmed one gives "Stop timed out".
  **Witness**: units "slow but successful stop — no error", "a failure of the
  regular stop gives stopTimedOut". **Mutation**: the UI-side wait budget is
  smaller than the service's wait budget.
- **P2. Forced stop — only after the regular one.** The budget ladder strictly
  grows: service wait 9 s < UI wait 10 s < emergency stop 12 s. **Witness**:
  unit "the stopping-timeout escalation is greater than the UI stop budget".
  **Mutation**: an emergency stop threshold of 3 s.
- **P3. A hung start does not hang forever.** The connecting phase is limited
  to 15 s plus 10 s per WireGuard/AmneziaWG node in the config, but no more
  than 4 min; on expiry the tunnel is forcibly shut down, and the reason names
  the threshold and the number of nodes. **Witness**: units "the threshold
  grows linearly", "capped by the ceiling", "the connecting timeout leaves a
  reason". **Mutation**: a threshold without a ceiling.
- **P4. Reconnect does not start on top of an unstopped tunnel.** If the stop
  was not confirmed, the start is cancelled with the message "reconnect
  aborted". `no witness`.
- **P5. The mode determines the core's inputs.** VPN — only the system tunnel;
  Proxy — only the local port, the system tunnel is not brought up;
  VPN+Proxy — both; routing and DNS rules apply to local-port traffic the same
  way as to tunnel traffic. **Witness**: units "mode=proxy → tun removed, mixed
  added", "no dangling tun-in in rules", "mode=vpn_proxy → both inbounds".
  **Mutation**: a rule bound only to the tunnel input in Proxy mode.
- **P6. A port visible outside the device is closed with a password unless
  the user opens it on purpose.** A listen address outside `127.x` forces
  authentication on the screen and in the Debug API, and it cannot be removed
  there; when authentication is enabled with an empty password, a password is
  generated. A record with an empty password that bypasses both entry points
  (a restored backup, a hand-edited store) is honoured as the user's choice:
  the build writes no `users` and the port is open (owner's decision,
  2026-09-29). **Witness**: units "listen 0.0.0.0 → effectiveAuth is
  forced", "an arbitrary LAN IP forces auth", "non-loopback listen forces
  effectiveAuth → a password is generated". **Mutation**: authentication is
  read from the toggle regardless of the address.
- **P7. Proxy mode does not touch another VPN.** Without a system tunnel the
  app does not request the VPN permission and does not show the question about
  another VPN. **Witness**: widget test "proxy + another VPN active → neither
  a poll nor a dialog"; unit "mode → proxy mirrors has_tun=false".
  **Mutation**: requesting the permission regardless of the mode.
- **P8. Taking over another VPN — only with consent.** Before a manual start
  in a mode with a tunnel while another VPN is active — the dialog "Switch /
  Cancel / VPN settings". **Witness**: widget tests "vpn + another VPN active →
  dialog", "Cancel cancels the start". **Mutation**: starting without asking.
- **P9. Losing the slot is distinguishable from a stop and survives the
  background.** If another VPN took the slot, the user sees that, not a
  neutral "Disconnected", including when returning to the app later.
  **Witness**: units "Stopped + revoked → revoked", "map with Stopped + revoked
  → revoked (the takeover survived the background)". **Mutation**: the takeover
  flag is not returned on a status request.
- **P10. Autostart — only if enabled.** After the device boots the tunnel comes
  up by itself if "Auto-start on boot" is on (off by default). **Witness**:
  manual check — enable, reboot, the tunnel is up. **Mutation**: autostart
  without checking the setting.
- **P11. Closing the app does not break the tunnel by default.** With "Keep VPN
  on exit" on (the default) swiping the app from recents does not stop the
  tunnel; with it off — it does. **Witness**: manual check. **Mutation**:
  stopping on swipe regardless of the setting.
- **P12. Process death does not leave the user without a tunnel forever.** If
  the tunnel was up and not explicitly stopped, it comes back by itself (in the
  worst case within ~3.5 min, faster when the screen wakes); a third automatic
  attempt within 5 minutes is not made — the tunnel stays off with a
  notification. An explicit "Stop" is not resurrected. **Witness**: manual
  check (kill the process with the tunnel up — the tunnel came back; §428
  device-verified). **Mutation**: the watchdog is not cleared by an explicit
  stop.
- **P13. A core crash heals caches on the next start.** After an abnormal core
  exit the core cache and temporary files are cleared before the start; the
  config, geo databases and rule-sets are not touched. `no witness`
  (DEVICE-PENDING).
- **P14. A silent core is recognized.** With the app open, two consecutive
  checks without a core status for longer than 8 s move the tunnel to
  "Connection lost — VPN tunnel is not responding" with an attempt at a
  regular stop; the first check after returning from the background is not
  penalized. `no witness`.
- **P15. A network change resets hung connections once.** A real interface
  change (Wi-Fi ↔ mobile) after 1.5 s of quiet gives one `resetNetwork`; the
  first connection, an update of the same network's properties and network
  loss do not give a reset. **Witness**: manual check (switch Wi-Fi → LTE, one
  reset entry in the log). **Mutation**: a reset on every network property
  update.
- **P16. Tunnel sleep does not open a leak.** In sleep modes the tunnel
  interface stays up: while paused, traffic does not go around the tunnel but
  is dropped. `no witness`.
- **P17. WG/AWG suspension is a contract with the core through `lx.wg`.** The
  sleep threshold is written to `lx.wg.idle_suspend`; empty — there is no `lx`
  block; the window for the active route and lazy build are written only
  together with the threshold. **Witness**: units "idleSuspend="30s" →
  lx.wg.idle_suspend, route clean", "reachable is written only with
  idleSuspend on", "lazy_build off → no lazy_build and no build_max".
  **Mutation**: writing the obsolete `route.lx_idle_suspend`.
- **P18. The core memory limit is applied without reconnecting.** Values
  Auto / Off / 200 / 384 / 512 / 768 MB, garbage → Auto. **Witness**: units
  "garbage / null / empty string → auto", "write-through: JSON truth + mirror
  in native"; immediacy — manual check. **Mutation**: an unknown value becomes
  the effective limit.
- **P19. Switching to the already active node breaks nothing.** **Witness**:
  unit "switchNode to the already active node — no-op". **Mutation**: breaking
  connections before comparing with the active node.
- **P20. The service notification controls the tunnel without the app.** While
  the tunnel is up, the shade holds a notification with the active node and
  Stop / Reconnect buttons that work with the app closed. **Witness**: manual
  check (§182 device-verified). **Mutation**: Reconnect via the UI process.

## Controlled parameters

| Setting | Values | Default | When it takes effect |
|---------|--------|---------|----------------------|
| VPN mode | `vpn` / `proxy` / `vpn_proxy` | `vpn` | tunnel restart |
| Local proxy protocol | `mixed` (HTTP+SOCKS5) / `http` / `socks` | `mixed` | restart |
| Listen address | any IPv4; `127.0.0.1` / `0.0.0.0` in the list | `127.0.0.1` | restart |
| Listen port | 1024..65535 | 2080 | restart |
| Require authentication | on/off (outside `127.x` — always on) | on | restart |
| Proxy username / password | string / 32 hex characters, generated | `user` / generated | restart |
| Keep VPN on exit | on/off (visible only with a tunnel) | on | immediately |
| Allow VPN bypass | on/off (visible only with a tunnel) | off | next start |
| Auto-start on boot | on/off | off | next boot |
| Interrupt connections on switch | on/off | off | immediately |
| Tunnel sleep mode | `never` / `lazy` / `always` | `never` | next start |
| Suspend idle tunnels | Off / 30 s / 2 min / 5 min | 30 s | next start |
| Suspend active-route tunnels | Off / 5 / 15 / 30 min / 1 h (only with the sleep above) | 5 min | next start |
| Lazy tunnel build | on/off (only with sleep) | on | next start |
| Built tunnels limit | 0 (no ceiling) / 3 / 5 / 8 / 12 | 5 | next start |
| Memory limit | Auto / Off / 200 / 384 / 512 / 768 MB | Auto | immediately |

Core config keys the feature emits (contract):

| Key | When |
|-----|------|
| `inbounds[]` `type: tun`, `tag: tun-in` | modes `vpn`, `vpn_proxy` |
| `inbounds[]` `type: mixed\|http\|socks`, `tag: mixed-in`, `listen`, `listen_port`, `users[{username,password}]` | modes `proxy`, `vpn_proxy`; `users` — only with effective authentication and a non-empty password |
| `lx.wg.idle_suspend` | the sleep threshold is non-empty |
| `lx.wg.idle_suspend_reachable` | together with the sleep threshold, if the window is non-empty |
| `lx.wg.lazy_build: true`, `lx.wg.build_max` | together with the sleep threshold, if lazy build is on |

Core calls visible as a contract: `resetNetwork` (network change), `pause` /
`wake` (tunnel sleep), `rebindStaleEndpoints` (screen on),
`closeConnection` (breaking on node switch), the memory limit — via
`oomMemoryLimit` of the core start parameters.

## Inputs / Outputs

**Inputs:** user gestures (Start, Stop, core reload, Reconnect and Stop in the
notification); the built core config; OS events — device boot, swiping the app
away, process death, change/loss of the default network, screen on/off, deep
device sleep, takeover of the VPN slot by another app; core replies — start/stop
status, error text, status stream.

**Outputs:** the system tunnel and/or the local proxy port; the tunnel status
(`disconnected`, `connecting`, `connected`, `stopping`, `revoked`) and the stop
reason; the persistent service notification; one-off notifications about a
stop on error and about auto-restart being given up; the core calls listed
above.

## Data flow

```
gesture / OS event
  → mode check (is a system tunnel needed) → question about another VPN
  → service start (notification "Starting") → wait for the core to be ready
  → core start with the config → permission check (Wi-Fi conditions in rules)
  → Started: watchdog armed, notification with the node, status stream
  ↻ life: network change → connection reset; screen on → rebind stale WG;
    sleep (by mode) → pause/wake; core silence → "Connection lost"
  → Stop: Stopping → closing the tunnel, the network observer, the core
  → Stopped (confirmation) → watchdog cleared, notification removed
```

## Rules and guarantees

- There are exactly four service statuses (Starting/Started/Stopping/Stopped);
  the slot takeover is a flag on top of Stopped, not a fifth status.
- A repeat of the same status without an error is not broadcast; a late
  "Started" after a stop has begun is dropped.
- A start while the service is not stopped is silently ignored by the service,
  so any reconnect is "wait for Stopped, then start".
- A core reload is available only with the tunnel connected, no more than once
  per 3 s; it recreates the core without stopping the service, the tunnel
  disappears for ~3 s.
- Changes of mode, address, port, authentication, sleep and suspension
  thresholds mark the config "restart needed"; the memory limit and the
  keep/interrupt toggles do not.
- Rules with Wi-Fi conditions without a granted location permission stop the
  start with an "Open Settings" dialog, not a crash.
- An empty config, a core that is not ready or a core rejection — a stop with a
  reason text the app shows (the raw core text travels alongside for
  analysis).

## Boundaries

- Live status, speed, connections, connection time — [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md).
- Which apps go through the tunnel — [011-SPLIT_TUNNELING](../011-SPLIT_TUNNELING/FEATURE.md).
- Quick settings tile, shortcuts, Intent API, automation apps —
  [014-AUTOMATION](../014-AUTOMATION/FEATURE.md).
- Auto-applying settings changes to a live tunnel and the "restart needed"
  banner — [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md); tunnel
  interface parameters (address, MTU, stack, IPv6) — there as well, as
  template variables.
- Logs, the core crash report — [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md);
  the Debug API — [027-DEBUG_API](../027-DEBUG_API/FEATURE.md).
- An active health watchdog with probes and escalation (§042F, §088) — not
  implemented on purpose (battery).
- Depends on OS capabilities: autostart after boot, surviving in the
  background and after process death, the moment of deep sleep, receiving
  network and screen events, showing notifications, the uniqueness of the
  system VPN slot. Firmware with aggressive background cleanup may break
  P10–P12; there is no workaround other than excluding the app from battery
  optimization.

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Tunnel control | Starts, stops, reloads and reconnects the tunnel from the app and the notification, with a deadline for every transitional phase. | P1–P4, P20 | [tunnel-control.md](FUNCTIONS/tunnel-control.md) |
| Operating modes | Chooses the VPN, Proxy or VPN+Proxy mode, configures the local proxy port and its authentication, and decides whether apps may bypass the tunnel. | P5, P6 | [operating-modes.md](FUNCTIONS/operating-modes.md) |
| Coexisting with another VPN | Asks before taking the system VPN slot from another VPN and recognizes when another VPN has taken it. | P7–P9 | [foreign-vpn.md](FUNCTIONS/foreign-vpn.md) |
| Autostart and exiting the app | Starts the tunnel after the device boots and defines whether it survives closing the app. | P10, P11 | [autostart-and-exit.md](FUNCTIONS/autostart-and-exit.md) |
| Tunnel recovery | Brings the tunnel back after process death, clears caches after a core crash and detects a core that has stopped responding. | P12–P14 | [recovery.md](FUNCTIONS/recovery.md) |
| Reacting to network and node changes | Resets core connections on a real network change, handles network loss, rebinds WireGuard after screen sleep and optionally breaks connections on a node switch. | P15, P19 | [network-changes.md](FUNCTIONS/network-changes.md) |
| Tunnel sleep (background mode) | Pauses the tunnel in the background according to the chosen mode and wakes it up again; it is off by default. | P16 | [tunnel-sleep.md](FUNCTIONS/tunnel-sleep.md) |
| Core resources | Suspends idle WireGuard/AmneziaWG tunnels, builds them lazily with a limit on parallel builds and sets the core's memory limit. | P17, P18 | [core-resources.md](FUNCTIONS/core-resources.md) |

## Related features

- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — builds the config the tunnel starts with; auto-applying settings to a live tunnel, the "restart needed" banner and tunnel interface variables (address, MTU, stack, IPv6).
- [004-ROUTING](../004-ROUTING/FEATURE.md) — rules with Wi-Fi conditions that gate the start on the location permission.
- [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) — the Direction option `interrupt_exist_connections`: the core breaking connections on a group selection change.
- [007-NODE_LIST](../007-NODE_LIST/FEATURE.md) — node switching in groups, which the optional connection break on switch reacts to.
- [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md) — disabling/enabling an individual WG/AWG node on the fly.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — the connecting-phase expiry is the start verdict for the node safety net; passive health check and URLTest intervals.
- [011-SPLIT_TUNNELING](../011-SPLIT_TUNNELING/FEATURE.md) — which apps go through the tunnel this feature brings up.
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — live status, speed, connections, connection time, WG/AWG endpoint state, sleep of data streams in the background.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — logs, the core crash report and the "core crashed" banner.
- [014-AUTOMATION](../014-AUTOMATION/FEATURE.md) — quick settings tile, shortcuts, Intent API: starts without the screen and without the foreign-VPN question.
- [020-APP_SHELL](../020-APP_SHELL/FEATURE.md) — the startup wizard asks for the battery optimization exception that autostart and survival depend on.
- [027-DEBUG_API](../027-DEBUG_API/FEATURE.md) — the Debug API: start, stop, reconnect, reload and network reset over HTTP (`/action/*`), the VPN mode and proxy settings (`/settings/*`).

## Maintenance notes

- The stop budgets are tied by a ladder (9 < 10 < 12 s). Change one step —
  check all three, or the false "Stop timed out" comes back (§415).
- The core's `pause` closes all connections: the `always` mode breaks push
  channels on every screen-off — hence the `never` default.
- WG/AWG sleep keys live in `lx.wg`; the core accepts the old
  `route.lx_idle_suspend` with a warning, and writing both places at once with
  different values keeps the core from starting.
- A connection reset on every network property update is a known regression
  of the sing-box #3400 class; reset only on an interface name change.
- Auto-restart after process death rests on the "tunnel wanted" flag: any new
  stop path must clear it, otherwise the watchdog will resurrect a stopped
  tunnel.
