# L×Box Automation API

Controlling L×Box from **Tasker / MacroDroid / Llama / Automate** (§047 Public
Intent API) — in two ways:

- **Plugin** (recommended) — L×Box appears in the host's plugin list and you pick
  a command by hand (the Locale/Tasker standard);
- **Raw broadcast intents** — `am broadcast` / Send Intent with our action string
  (for shell, ADB, and apps without plugin support).

The feature is **opt-in**: accepting commands is off by default and no events are
sent out. Turn it on in **App Settings → Automation**.

> Русская версия: [AUTOMATION.ru.md](AUTOMATION.ru.md)

> **Two automation channels — do not mix them up.** This document covers the
> **Public Intent API**: the phone automating itself from events
> (Tasker/MacroDroid, Wi-Fi triggers) — no PC, no USB, no token. If instead you
> need to drive L×Box **from the outside with a script** (CI, debugging,
> adb-forward from a computer), that is the **Debug API** (HTTP, Bearer token,
> port 9269, full CRUD over subscriptions and rules): see
> [api/debug-api-reference.md](api/debug-api-reference.md) and the live
> `GET /help`. An overview of every control channel is in the
> [documentation index](README.md).

---

## Quick start

1. **L×Box → App Settings → Automation** → enable “Accept automation commands”
   (confirm the explainer). While that toggle is OFF the receivers are
   `enabled=false` and no command is accepted at all. That toggle is the
   admission barrier — there is no separate per-app pass (see §157).
2. Enable the **Emit** categories you want if you would like L×Box to send events
   out (Lifecycle / State / Subscription / Health).
3. In the host application, pick L×Box:
   - **Plugin** (simpler): Action / State → **Plugin → L×Box** → choose a command;
   - **Raw**: **Send Intent** → Action = one of the commands below, Target =
     **Broadcast Receiver**.

---

## Two ways to integrate

L×Box supports **both** mechanisms — choose whichever is more convenient:

| | Plugin (recommended) | Raw broadcast intents |
|---|---|---|
| How | Host → **Action / State → Plugin → L×Box** | Send Intent plus the action string, by hand |
| For whom | most people — you click through a plugin list | shell `am broadcast`, ADB, apps without plugin support |
| Setup | pick from a list, plus a node/group selector | type the action and extras yourself |

Both require the master toggle in **App Settings → Automation**. The plugin route
is described right below; the raw actions are in the tables further down.

### Hosts

These understand the plugin standard (`twofortyfouram` Locale):

| Host | Price | Plugin block |
|---|---|---|
| **MacroDroid** | free | ✅ available (verified) |
| **Tasker** | ~€3.5 one-off | ✅ |
| **Llama** | free | ✅ |
| **Automate** (LlamaLab) | free | ⚠️ the plugin block is premium; raw actions through “Broadcast send” are free |

Raw actions work **from anywhere** — Termux, a shell, or ADB through
`am broadcast`, with no host application at all.

### Plugin — actions (Setting)

In the host's plugin list L×Box offers **four entries**:

| Plugin entry | What it does |
|---|---|
| **L×Box: Start VPN** | one tap — select it and you are done, no screen |
| **L×Box: Stop VPN** | one tap |
| **L×Box: Toggle VPN** | one tap |
| **L×Box: Custom…** | opens a screen for choosing the remaining commands |

“Custom…” lists the commands (Switch node · Set group · URL-test group · Refresh
subscriptions · Rebuild config · Reset network). **Switch node** shows a
**dropdown of the real nodes** in the active group; **Set group** and
**URL-test group** show the real groups. These are pulled from the app, so open
L×Box once after installing or changing a subscription to let the list cache
itself — otherwise you have to type the tag by hand.

Example (MacroDroid): Action → **Tasker/Locale plugin** → **L×Box: Custom…** →
choose “Switch node” → pick a node from the list in Value → **Save**.

### Plugin — conditions (State)

Host → State / Condition → Plugin → **L×Box** → pick a check:

| Condition | Value |
|---|---|
| **VPN is up** | — |
| **Active node =** | choose a node |
| **Active group =** | choose a group |

The profile stays active while the condition holds. The host polls periodically.

> **How to find out the current active node.** You do not have to wait for a
> “reply” event: the **Active node =** condition is a pull check of the node
> active right now (it reads the cache L×Box refreshes on every switch). Put it
> in a scenario's State and compare it with the tag you want — it is true while
> that node is active. The same goes for **Active group =**. The
> `ACTIVE_NODE_CHANGED` event (below) is a push saying “the node changed”, while
> the condition is a pull asking “which node is it now” — pick whichever fits.

> Under the hood the plugin uses the standard
> `com.twofortyfouram.locale.intent.action.FIRE_SETTING` / `QUERY_CONDITION` and
> the same commands as the raw actions below. The plugin's UI is in English.

---

## Incoming actions (commands → L×Box)

All of them are broadcast intents. The prefix is `com.leadaxe.lxbox.`.

| Action | Extra | Effect |
|---|---|---|
| `START_VPN` | — | Start the VPN (idempotent: a no-op if already up) |
| `STOP_VPN` | — | Stop the VPN |
| `TOGGLE_VPN` | — | Toggle relative to the current status |
| `SWITCH_NODE` | `tag` (String) | Switch the active node inside the current group |
| `SET_GROUP` | `group` (String) | Change the active group |
| `REBUILD_CONFIG` | — | Rebuild the config from subscriptions (respects the §037 lock) |
| `REFRESH_SUBS` | `force` (Bool) | Refresh subscriptions |
| `RESET_NETWORK` | — | closeAll + DNS flush + dialer rebind (requires the tunnel up) |
| `URLTEST_GROUP` | `group` (String) | Force a URL test of the group (requires the tunnel up) |

> **The first `START_VPN`** needs the system VPN consent, which can only be given
> from the UI. Press Connect in the app once; after that automation works without
> a dialog.

---

## Outgoing events (L×Box → outside)

The prefix is `com.leadaxe.lxbox.event.`. They are emitted only if the
corresponding category is enabled in the Emit settings.

| Event | Extras | Category | When |
|---|---|---|---|
| `VPN_CONNECTED` | — | Lifecycle | The tunnel came up |
| `VPN_DISCONNECTED` | `reason` (`user`/`error`/`revoked`) | Lifecycle | The tunnel went down |
| `VPN_ERROR` | `code`, `message` | Lifecycle | Any error path, or a failed automation command. `code` is `tunnel_error` (the tunnel dropped) or `conflict`/`bad_request`/`not_found`/… (the command failed) |
| `VPN_REVOKED` | — | Lifecycle | Another VPN app took over the tunnel |
| `UPDATE_AVAILABLE` | `version`, `url` | Lifecycle | A newer version was found |
| `ACTIVE_NODE_CHANGED` | `old_tag`, `new_tag`, `group`, `reason` | State | The active node changed |
| `NODE_ALREADY_ACTIVE` | `tag`, `group` | State | `SWITCH_NODE` arrived for the already-active node — nothing changed (a confirmation instead of a switch) |
| `ACTIVE_GROUP_CHANGED` | `old_group`, `new_group`, `reason` | State | The active group changed |
| `SUB_REFRESHED` | `sub_id`, `nodes_count`, `delta_count` | Subscription | A subscription refreshed |
| `SUB_REFRESH_FAILED` | `sub_id`, `error` | Subscription | A subscription failed to refresh (throttled to 1/min per sub_id) |

### Reserved (the namespace exists, the source does not yet)

- `HEARTBEAT_FAILED` · `LATENCY_DEGRADED` · `UNATTRIBUTED_BURST` (category
  **Health**) — these arrive together with the §042 health watchdog. The category
  is already present in the UI.
- `PERMISSION_NEEDED` (`permission`, category **Lifecycle**) — reserved for
  runtime-permission prompts; nothing emits it yet.

---

## Symmetric request-response

The real strength of outgoing events is that Tasker can **wait** for a reply:

```
Task "Switch to Russia with confirmation":
  1. Send Intent: SWITCH_NODE extra tag="🇷🇺Россия"
  2. Wait Event: ACTIVE_NODE_CHANGED (new_tag ~ "🇷🇺.*")
       OR  NODE_ALREADY_ACTIVE (tag ~ "🇷🇺.*")
       OR  VPN_ERROR                                        (timeout 10s)
  3. If ACTIVE_NODE_CHANGED  → Vibrate + Notify "✅ switched"
     If NODE_ALREADY_ACTIVE  → Notify "✅ already on this node"
     If VPN_ERROR            → Notify "❌ %code: %message"
     If timeout              → Notify "⚠️ no reply"
```

When a command fails (no such group, the tunnel is down, a non-existent node or
group, and so on) L×Box emits `VPN_ERROR` with a `code`
(`conflict` / `bad_request` / `not_found` / …) and a `message` — so a waiting
Tasker learns about the failure instead of a silent fire-and-forget.

> **Important: enable both `Lifecycle` and `State` for request-response.** A
> successful switch arrives in the **State** category (`ACTIVE_NODE_CHANGED` /
> `NODE_ALREADY_ACTIVE`), while a failure arrives as `VPN_ERROR` in the
> **Lifecycle** category. With only State enabled, a waiting scenario never
> receives `VPN_ERROR` on an error and runs into a timeout instead of the error
> branch. (App Settings → Automation → Outbound events.)

**`SWITCH_NODE` aimed at the already-active node** does not tear down connections
and does not re-select (that would be needless load), but it still sends
`NODE_ALREADY_ACTIVE` — so a waiting scenario gets a deterministic answer instead
of a timeout. If you wait only for `ACTIVE_NODE_CHANGED`, repeating the command
for the same node will hang until the timeout — add `NODE_ALREADY_ACTIVE` to the
Wait Event.

---

## Security

- **Off by default.** Without the master toggle the receiver is disabled and no
  app can send commands. **That is the only admission barrier.** Once the toggle
  is ON, commands are accepted from any application on the device.
- **There is no per-app pass** (§157). The former “Require a pass” checkbox was
  removed: `checkCallingPermission` inside a broadcast `onReceive` is
  non-deterministic (a broadcast carries no caller identity), so it provided no
  real protection. A “trusted apps only” model would be a separate task (a
  shared-secret token, or a UID allowlist on Android 14+).
- **Events carry no secrets** from subscriptions or the config — only labels
  (tags, group names, status); an outgoing broadcast is open to every subscriber.
- **Logs.** In App Settings → Diagnostics, the `automation` log filter shows
  `[automation] action <name> → ok / ERROR …` (handled commands) and
  `[automation] emit <event> …` (outgoing events). The bare fact that a broadcast
  arrived — including direct `START_VPN` / `STOP_VPN` / `TOGGLE_VPN`, which never
  reach Dart at all — is written only to logcat under the `LxBoxIntent` tag:
  `adb logcat -s LxBoxIntent`.

---

## Tasker recipes

### 1. Auto-disable the VPN on the home Wi-Fi
- Profile: Wi-Fi connected = `MyHomeWiFi`
- Task: Send Intent `com.leadaxe.lxbox.STOP_VPN` (Broadcast)

### 2. Auto-enable on any other Wi-Fi
- Profile: Wi-Fi connected = NOT `MyHomeWiFi`
- Task: Send Intent `com.leadaxe.lxbox.START_VPN`

### 3. Switch to a Russia node when a bank app starts (with confirmation)
- Profile: App launched = `ru.bank.app`
- Task:
  1. Send Intent `SWITCH_NODE` extra `tag=🇷🇺Россия`
  2. Wait Event `ACTIVE_NODE_CHANGED` (new_tag ~ `🇷🇺.*`) OR `VPN_ERROR`, timeout 10s
  3. If matched → Vibrate(50); otherwise → Notify the error

### 4. Notification when a subscription fails
- Profile: Event Received `com.leadaxe.lxbox.event.SUB_REFRESH_FAILED`
- Task: Notify “📡 Sub %sub_id failed: %error”

### 5. Periodic mass ping every 30 minutes
- Profile: Time = every 30 min
- Task: Send Intent `URLTEST_GROUP` extra `group=vpn-1`

### 6. Automatic reset-network on high ping
- Profile: Variable `%CURR_PING > 1000` (set externally)
- Task: Send Intent `RESET_NETWORK`

### 7. Watch notification when the VPN drops
- Profile: Event Received `com.leadaxe.lxbox.event.VPN_ERROR`
- Task: Notify Wear “❌ VPN: %code — %message”

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| The command never arrives | The master toggle is OFF | Enable it in App Settings → Automation |
| Same, but the toggle is ON | Wrong action, the target is not a Broadcast Receiver, or a typo in `com.leadaxe.lxbox.…` | Check against the command list; the fact of receipt is in logcat, `adb logcat -s LxBoxIntent` (the `received <action>` line); command results are under the `automation` log filter |
| **An event never arrives** (for example `ACTIVE_NODE_CHANGED` is not caught) | **The event's category is OFF** — check this first | Enable the right category (for `ACTIVE_NODE_CHANGED` / `NODE_ALREADY_ACTIVE` that is **State**) in App Settings → Automation → Outbound events. While the category is off, the event is not emitted at all |
| The event arrives but the variables (`%new_tag` and friends) are empty | The extras are not declared in Tasker | Add the extra variable names by hand in `Event → System → Intent Received` (see below) — Tasker does not pick them up automatically |
| `SWITCH_NODE` does not select the node | The tag does not exist, or a typo | Check the `automation` log filter |
| “Custom…” shows a text field instead of a node/group list | The cache is empty (L×Box has not been opened since installing or changing a subscription) | Open L×Box, enter the group (that caches the list), then reopen the plugin |
| L×Box is missing from the host's plugin list | The host has no plugin block (for instance the free Automate) | Use MacroDroid (free) or raw `am broadcast` |
| `START_VPN` does not work the first time | VPN consent was never granted | Press Connect in the app once |
| The receiver is dead on MIUI / ColorOS | An OEM auto-start restriction | Add L×Box to “Autostart” in the system settings |

> **Declaring the extras in Tasker.** An event carries its data in intent extras,
> but Tasker does not turn them into variables by itself — the names have to be
> written by hand in `Event → System → Intent Received` (the action filter is the
> event's full name, for example
> `com.leadaxe.lxbox.event.ACTIVE_NODE_CHANGED`), after which they are available
> as `%new_tag` and so on. The keys, per event:
> - `ACTIVE_NODE_CHANGED` — `old_tag`, `new_tag`, `group`, `reason`;
> - `NODE_ALREADY_ACTIVE` — `tag`, `group`;
> - `ACTIVE_GROUP_CHANGED` — `old_group`, `new_group`, `reason`.
>
> `old_tag` is empty on the **first** switch after the app starts (there is no
> previous node yet, so the extra is not attached); `new_tag`, `group` and
> `reason` are always filled in. That is normal, not a bug.

---

## Links

- [§047 — Public Intent API spec](spec/features/047%20public%20intent%20api/spec.md)
- [Android BroadcastReceiver guide](https://developer.android.com/develop/background-work/background-tasks/broadcasts)
- [Tasker — Send Intent](https://tasker.joaoapps.com/userguide/en/help/ah_send_intent.html)
- [Locale plugin API (twofortyfouram)](https://github.com/twofortyfouram/android-plugin-api-for-locale) — the standard behind the plugin route (FIRE_SETTING / QUERY_CONDITION)
