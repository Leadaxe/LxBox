[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Automation — Quick Settings tile, Tasker commands and VPN events

LxBox can start and stop the VPN without opening the app: from a Quick
Settings tile, the app icon menu, or Tasker and MacroDroid commands. It also
broadcasts events about the tunnel, nodes and subscriptions; command intake
and events stay off until the user enables them.

| Field | Value |
|-------|-------|
| Feature | 014-AUTOMATION |
| Type | Product feature |
| Absorbed | `§032F` `§047F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

Turning the tunnel on should not require "open the app, wait for the screen,
press the button". The feature gives the tunnel entry points outside the app:
one touch in the system shade or in the icon menu on the home screen, commands
from automation apps (Tasker, MacroDroid, Llama, Automate, `am broadcast` from
the shell) and events by which an automation app learns what happened.

The feature protects three principles:

- **Closed by default.** Command intake and event emission are off until the
  user explicitly turns them on; turning intake on requires confirmation.
- **An external entry does not bypass the app's rules.** A command from outside
  does the same as the button in the app, with the same preconditions; "Stop"
  from outside is as final as "Stop" in the app.
- **A refusal answers, it does not stay silent.** An automation app waiting for
  an answer to a command gets either a success event or an error event with a
  code.

## Promises

- **P1. One touch of the tile toggles the tunnel.** Off → start, on → stop;
  the tile immediately draws the target state, then the real one
  ("Connecting…", "Connected", "Stopping…", "Disconnected"). A touch in a
  transitional phase is ignored. **Witness:** manual check — add the tile,
  touch it when Stopped and when Started, touch it while connecting.
  **Mutation:** a touch in the "Connecting…" phase launches a second start.
- **P2. The icon menu reflects the state.** Off — a single "Connect" item, on
  — "Disconnect", in a transitional phase — both. **Witness:** manual check by
  long-pressing the icon in the three states. **Mutation:** a static "Toggle"
  item ignoring the state.
- **P3. The VPN permission is asked once and explained.** If there is no
  system VPN permission yet, quick connect opens the app with the "one-time
  permission" explanation, after consent starts the tunnel and returns the
  user where they came from; a refusal — a message, without asking again. In
  Proxy mode the permission is not asked. **Witness:** manual check on a clean
  install. **Mutation:** an attempt to show the system dialog directly from
  the shade.
- **P4. A failure of the quick toggles does not break the tunnel.** An error
  updating the tile or the icon menu (old OS versions, vendor firmwares) does
  not hinder start and stop. `no witness` — **только на устройстве
  2026-09-30:** проверить на старой прошивке/OS, что ошибка обновления
  `LxBoxTileService`/иконки-меню (`app/android/.../LxBoxTileService.kt`) не
  мешает старту/остановке туннеля; логика нативная (Kotlin), юнит-тестом
  Dart не воспроизводится.
- **P5. External commands are off by default.** While "Accept automation
  commands" is off, neither a direct command nor an automation plugin is
  executed. **Witness:** manual check — `am broadcast -a
  com.leadaxe.lxbox.START_VPN` with the toggle off does nothing.
  **Mutation:** intake enabled on a clean install.
- **P6. Command preconditions are checked before the action.** An empty
  `tag`/`group` → `bad_request`; no group selected, the tunnel down or the app
  not ready → `conflict`; a non-existent group → `not_found` and no
  `ACTIVE_GROUP_CHANGED`. **Witness:** units "empty tag → BadRequest", "no
  home → Conflict", "group selected, tunnel down → Conflict", "non-existent
  group → NotFound (no false event)". **Mutation:** `SET_GROUP` on a
  non-existent group emits a group change.
- **P7. A command failure answers with an event, without leaks.** A command
  refusal yields `VPN_ERROR` with `code`/`message`; an internal error is
  returned as `error`/`internal error`, details go only to the log.
  **Witness:** units "DebugError → its code/message", "arbitrary exception →
  generic (details do not leak)". **Mutation:** the exception text goes into
  `message`.
- **P8. Re-selecting the active node is a confirmation, not a switch.**
  `SWITCH_NODE` on the already active node does not drop connections and
  answers `NODE_ALREADY_ACTIVE`. **Witness:** unit "switchNode on the already
  active node — no-op + NODE_ALREADY_ACTIVE". **Mutation:** re-selecting the
  node again.
- **P9. Events go out only for enabled categories.** Lifecycle, State,
  Subscription, Health are enabled independently; all are off by default.
  **Witness:** units "all OFF — emit no-op", "lifecycle gate independent of
  state/subs", "state gate emits node/group only". **Mutation:** a shared
  gate for all categories.
- **P10. Subscription failures do not spam.** `SUB_REFRESH_FAILED` — no more
  than once a minute per subscription; other events are unlimited.
  **Witness:** units "SUB_REFRESH_FAILED capped 1/min per sub_id",
  "SUB_REFRESHED not throttled". **Mutation:** a shared limit for all
  subscriptions.
- **P11. "Stop" from outside is final.** Stopping from the tile, the icon
  menu, a command or the plugin shuts down the running node safeguard cycle —
  the tunnel does not come back up. **Witness:** unit "native Stop
  (vpn-stop-requested) in the checking phase → no start". **Mutation:** the
  external stop is not reported to the app.
- **P12. An automation condition answers right away.** The checks "VPN is
  up", "Active node =", "Active group =" answer without launching the UI; no
  data or no value → "unknown", the profile is not activated. **Witness:**
  manual check — a condition in MacroDroid/Tasker with the app closed.
  **Mutation:** the answer waits for the UI to start.
- **P13. Events carry no secrets.** Only labels: node tags, group names,
  status, the masked subscription host. **Witness:** unit "SUB_REFRESHED /
  SUB_REFRESH_FAILED — sub_id masked, no token" — **покрыто 2026-09-30:**
  `test/subscription/automation_event_masking_test` «успешный fetch:
  SUB_REFRESHED.sub_id замаскирован», «провал fetch:
  SUB_REFRESH_FAILED.sub_id замаскирован». **Mutation:** the raw
  subscription URL is passed as `sub_id` instead of the masked host.

## Controlled parameters

| Setting | Values | Default |
|---------|--------|---------|
| Accept automation commands | on/off; turning on — via a warning dialog | off |
| Emit: Lifecycle / State / Subscription / Health | on/off each; first enable — via an explanation | all off |
| Quick Settings tile → Add | system request to add the tile (Android 13+) | — |
| First run: offer to add the tile | shown once, where the OS supports it | — |

The feature emits no core config keys. Public contracts — command and event
strings, the plugin settings format (see functions). The source of truth for
the user is `docs/AUTOMATION.md` (+ `AUTOMATION.ru.md`).

## Inputs / Outputs

**Inputs:** a tile touch and its long press; an icon menu item; commands
`com.leadaxe.lxbox.<ACTION>` with extras; automation plugin calls (action and
condition check); tunnel status; node/group changes, subscription update
results, a found app update.

**Outputs:** tunnel start/stop and app actions (node and group change, config
rebuild, subscription update, network reset, URL test); the tile look and the
icon menu contents; events `com.leadaxe.lxbox.event.<EVENT>`; the condition
answer (satisfied / not satisfied / unknown); log lines with the `automation`
filter.

## Data flow

```
tile touch / menu item / command / plugin
  → intake (quick entries — always; commands — only with intake enabled)
  → start/stop/toggle: straight to the tunnel service (without the UI);
    no VPN permission → the app opens for one-time consent
  → other commands → shared handlers (the same as the Debug API's)
      → preconditions → action | error → VPN_ERROR(code, message)
  → status / node / group / subscription change
      → mirror for plugin conditions and pick lists
      → event, if the category is enabled (rate-limited)
      → redraw of the tile and the icon menu
```

## Rules and guarantees

- Start, stop, tunnel toggle — identical for all external entries; other
  commands — the same handlers and error codes as the Debug API.
- `START_VPN` with the tunnel up does nothing; `TOGGLE_VPN` without the VPN
  permission opens the app for consent.
- A command's success is confirmed by the corresponding event (State), a
  failure — by `VPN_ERROR` (Lifecycle); request-response needs both
  categories.
- There is one intake barrier — the main toggle; there is no "trusted apps
  only" permission, events are open to any subscriber.

## Boundaries

- Does not do: choosing a node or group from the tile; a home screen widget;
  watches and car interfaces; an SDK for third-party developers; a filter of
  "trusted" senders.
- Health events (`HEARTBEAT_FAILED`, `LATENCY_DEGRADED`, `UNATTRIBUTED_BURST`)
  and `PERMISSION_NEEDED` — the names are reserved, there is no source; the
  Health category exists in the settings but sends nothing.
- Commands other than start/stop/toggle, and all events, require a live app;
  with the UI unloaded the command is skipped without an answer.
- `ACTIVE_NODE_CHANGED` comes only on an explicit node choice, `reason` is
  always `user`; changes by auto-select and automation with `reason` `urltest` /
  `automation` (`047F`) are not planned (owner decision 2026-09-29, audit [591](../../tasks/591-spec-kit-revision-audit.md)).
- The service notification with Stop / Reconnect buttons — 010-VPN_SERVICE.
- Remote control over HTTP with a token — Debug API,
  [027-DEBUG_API](../027-DEBUG_API/FEATURE.md).
- **Depends on OS capabilities:** the shade tile, the dynamic icon menu, the
  system request to add the tile (Android 13+), the one-time VPN permission
  dialog, delivery of broadcast commands and events, firmwares that forbid
  autostart (MIUI, ColorOS). Live updates of the tile and the menu are
  guaranteed from Android 11; on older versions the tile updates when the
  shade opens, and there is no icon menu.

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Quick toggle | Turns the tunnel on or off with one touch from the Quick Settings tile or the app icon menu; both show the current state. | P1–P4, P11 | [quick-toggle.md](FUNCTIONS/quick-toggle.md) |
| Command intake | Executes public `com.leadaxe.lxbox.*` commands behind one main toggle, checks preconditions and answers a failure with an error event. | P5–P8, P11 | [command-intake.md](FUNCTIONS/command-intake.md) |
| Outbound events | Sends `com.leadaxe.lxbox.event.*` broadcasts for enabled categories with rate limiting, and confirms or rejects commands in request-response scenarios. | P7–P10, P13 | [outbound-events.md](FUNCTIONS/outbound-events.md) |
| Automation plugin | Adds LxBox actions and conditions to Tasker-compatible apps, with node and group pick lists and condition answers without starting the UI. | P5, P12 | [automation-plugin.md](FUNCTIONS/automation-plugin.md) |

## Related features

- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — the tunnel service that
  external start/stop drives directly; owns the service notification with Stop
  / Reconnect.
- [027-DEBUG_API](../027-DEBUG_API/FEATURE.md) — the Debug API, whose
  handlers and error codes the commands reuse; remote control over HTTP
  ([automation-recipes](../027-DEBUG_API/FUNCTIONS/automation-recipes.md)).

## Maintenance notes

- Names of commands, events, extras and the plugin settings format are a
  public API: renaming silently breaks users' scenarios. When the contract
  changes, `docs/AUTOMATION.md` and its Russian version are edited in the same
  change.
- All external start entries must check the mode the same way: in Proxy the
  VPN permission request tears down a foreign VPN (§192). A new entry — check
  them all.
- A new "Stop" path bypassing the app must report the stop to the app,
  otherwise the safeguard cycle will bring the tunnel back up (§510 M2).
- The rate limit is checked against the wall clock; the unit does not catch the
  exact 60-second boundary (§219).
