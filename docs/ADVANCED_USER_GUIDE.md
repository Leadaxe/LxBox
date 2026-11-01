[English](ADVANCED_USER_GUIDE.md) · [Русский](ADVANCED_USER_GUIDE.ru.md)

# L×Box — Advanced user guide

This guide is for those who know the sing-box config format, edit JSON by
hand and drive the app from a computer through the Debug API. The
[User guide](USER_GUIDE.md) explains the interface: servers, directions,
rules, DNS. This one covers the tools that work on the config itself and
bypass the forms: mixins, Lock config, Raw JSON, import rules, the Debug API
and the Automation API.

## Contents

- [Mixins](#mixins)
  - [A mixin adds what the template does not offer](#a-mixin-adds-what-the-template-does-not-offer)
  - [The Mixins tab sits next to Config](#the-mixins-tab-sits-next-to-config)
  - [The list order is the order of application](#the-list-order-is-the-order-of-application)
  - [The form: Name, Target, Action, Value, Preview](#the-form-name-target-action-value-preview)
  - [Example: a DNS listener for another app](#example-a-dns-listener-for-another-app)
  - [A failed mixin stops the build](#a-failed-mixin-stops-the-build)
- [Lock config pins a manual config](#lock-config-pins-a-manual-config)
- [Raw JSON and the View tab cover fields the form lacks](#raw-json-and-the-view-tab-cover-fields-the-form-lacks)
- [Import rules on a subscription's Filters tab](#import-rules-on-a-subscriptions-filters-tab)
- [Debug API](#debug-api)
- [Automation API](#automation-api)
  - [Automation: the VPN turns on by events](#automation-the-vpn-turns-on-by-events)
  - [Automation opens the VPN to commands from other apps](#automation-opens-the-vpn-to-commands-from-other-apps)

---

## Mixins

### A mixin adds what the template does not offer

The app builds the sing-box config from the template and the settings. When
the config needs something no form offers — an extra inbound, a rule in a
specific place, a field on a group of outbounds — a manual edit in Config
Editor lasts only until the next rebuild. A mixin is a stored edit of the
built config: a target path, an action and a JSON value. It is applied as the
last step of every build, after presets and guards, so rebuilds do not lose
it and Lock config is not needed. Enabled mixins run top to bottom, and each
one sees the result of the ones above it.

> 📖 Path syntax, actions, the full table of examples and errors —
> [Mixins reference](MIXINS.md).

### The Mixins tab sits next to Config

Where: ≡ → Config Editor, screen title Config, tab **Mixins** next to
**Config**. The Config tab shows the config with the mixins already applied:
after a rebuild caused by a mixin the Config tab reloads the text, unless it
holds an unsaved manual edit. On the Mixins tab the Save button and the ⋮ menu
of the Config tab are hidden.

The tab opens with the line `Edits applied to the built config, top to
bottom. They survive rebuilds.` and the list of mixins below it. The (+)
button (Add mixin) opens an empty form.

### The list order is the order of application

Each row of the list holds:

| Element | What it does |
|---|---|
| ≡ drag handle | Moves the mixin up or down; the order is the order of application |
| Name | The mixin's name; an empty name is shown as `target → action` |
| `target → action` | The path and the action, under the name |
| Toggle on the right | A disabled mixin is skipped by the build |
| `⚠ <reason>` under the row | The last build failed because of this mixin |

A long tap opens Duplicate and Delete. Duplicate puts a copy right below the
original. Delete asks `Delete mixin?`. A tap on a row opens the form.

The toggle, reordering, Duplicate and Delete are saved at once and trigger a
rebuild. With the VPN running, the new config reaches the core the same way as
any settings change: a restart from the home banner, or by itself when App
Settings → General → Auto-restart VPN on settings change is on.

### The form: Name, Target, Action, Value, Preview

The form title is Mixin; Save is in the top bar.

**Name** — free text; may be empty.

**Target** — the path in the config
([path language](MIXINS.md#path-language)). Under the field there is a live
status:

| Status | Meaning |
|---|---|
| `✓ 1 match` | The path points at one node |
| `✓ N matches → before first` / `→ after last` | Several matches; for `before` and `after` the status says where the value goes |
| `✗ no match` | Nothing in the config matches the path |
| `✗ syntax: <message>` | The path does not parse |
| `✗ needs a single list` | `append`/`prepend` on a non-list or on several matches |
| `✗ not a list element` | `before`/`after` on an object key, not on a list element |

As you type, suggestions appear under the field: keys of the current level,
fields of list elements after `[`, values of the field after `=`. A tap
inserts the item. The light bulb icon on the right of the field (tooltip
Suggestions) turns suggestions on and off: filled — on, outlined — off. The
choice is remembered and does not trigger a rebuild; the status works either
way.

**Action** — one of seven actions: `append`, `prepend`, `before`, `after`,
`set`, `merge`, `remove` ([what each one does](MIXINS.md#actions)). For
`remove` a Whole node / Keys switch appears; with Keys the Value field is
replaced by `Keys, comma-separated`.

**Value** — a JSON editor with a Format button. It accepts JSON5: comments,
trailing commas. On Save the value is converted to plain JSON.

**Preview** — the target's parent after the mixin is applied, one line per
element, marked `+` inserted, `~` changed, `-` removed. A tap on a line opens
the element's full JSON. Errors that depend on the value — `merge` with a
non-object value, a duplicate tag — are shown as a `⚠` line above Preview.
Status, suggestions and preview are computed on the config of the last build
before mixins, with the enabled mixins above this one applied.

Save is inactive while the status shows ✗, while Value does not parse, and,
for `remove` with Keys, while the key list is empty. Leaving the form with
unsaved changes asks Discard, Keep or Save.

### Example: a DNS listener for another app

A third-party firewall such as Rethink sends DNS queries to a resolver
address of your choice, and you want those queries answered by the sing-box
DNS module with the rules L×Box built. Two mixins, in this order:

| Name | Target | Action | Value |
|---|---|---|---|
| DNS listener | `inbounds` | `append` | `{"type": "direct", "tag": "dns-in", "listen": "127.0.0.1", "listen_port": 5354, "override_address": "1.1.1.1", "override_port": 53}` |
| Hijack DNS from dns-in | `route.rules[action=hijack-dns]` | `before` | `{"inbound": ["dns-in"], "action": "hijack-dns"}` |

The first adds the inbound, the second sends everything that arrives at
`dns-in` to the DNS module. Port 5353 on Android is often held by the system
mDNS service, so the example uses 5354. In the firewall, the DNS server is
`127.0.0.1`, port `5354`. The pair is turned on and off together.

### A failed mixin stops the build

A mixin that cannot be applied — no match, a wrong target type, a duplicate
tag — stops the build: the previous config stays in place, and the mixin's
row gets a `⚠` line with the reason. The mixin stays enabled until you fix it
or turn it off; error texts are in the
[Mixins reference → Errors](MIXINS.md#errors).

---

## Lock config pins a manual config

The Config tab edits the built config by hand; the edit lasts until the next
rebuild. Lock config (debug) pins the saved config and stops rebuilds. The
manual edit is described in the User guide:
[Config Editor edits the core config until the next rebuild](USER_GUIDE.md#config-editor-edits-the-core-config-until-the-next-rebuild).

The **Lock config (debug)** setting stops the app from rebuilding the
config: interface actions change the settings, and the config file stays as
you saved it. Where: App Settings → Diagnostics → Lock config (debug). The
switch is visible only when Debug API is on. Off by default. When on, the
switch reads `Pinned. UI actions skip config rebuild — useful
when testing PUT /config overrides.` Turning Debug API off removes the pin
as well.

> ⚠️ With Lock config on, changes to rules, directions and DNS and
> subscription updates do not reach the config: the VPN runs on the pinned
> file. To make settings apply again, turn Lock config off.

---

## Raw JSON and the View tab cover fields the form lacks

You can write a rule as a sing-box `route.rules` JSON fragment: choose Raw
JSON in Source. The JSON itself sets the action; the editor checks the syntax
as you type.

For a form-built rule, the **View** tab shows the finished sing-box fragment
that goes into the config.

---

## Import rules on a subscription's Filters tab

The **Filters** tab holds node-processing rules; the rules apply on import
and on every update. A rule is a set of conditions plus an action. A
condition reads `path operator value`, where the operator is contains,
equals or matches (regex). The Not and Case-sensitive checkboxes refine a
condition, and several conditions combine by AND or OR. An empty path
searches the whole node. There are three actions:

| Action | What it does |
|---|---|
| Disable | Removes matching nodes from routing |
| Enable | Brings them back, clearing manual disabling too |
| Replace | Writes a new value at the given path — whole or in part, with `$1`, `$2`… groups from the regex: this fixes a non-standard TLS fingerprint across all nodes at once |

Rules apply in order, and the last one that matched wins: the pair "disable
everything → enable NL" works as a whitelist. The **Matches** tab in the
rule editor shows which nodes a rule will apply to and what it will change,
before you save.

---

## Debug API

Where: App Settings → Diagnostics → Developer → Debug API.

**Debug API** starts an HTTP server through which a computer reads the app's
state, logs and config and controls the VPN. The server listens only on the
phone's `127.0.0.1` address; the computer connects to it with the command
`adb forward tcp:9269 tcp:9269`. When you first turn it on, the app creates
an access token. The token is visible only on this screen and stays out of
Backup by default; Copy copies it, Regenerate creates a new one. The Port
field accepts values from 1024 to 49151. The default port is `9269` — the
same as in the adb forward command.

> 📖 [debug-api-reference.md](api/debug-api-reference.md) — Debug API
> requests and their responses.

**Lock config (debug)** pins the config loaded through the Debug API:
actions in the interface do not rebuild it. Turning Debug API off also
removes the pin.

> ⚠️ While the config is pinned, edits in Routing, DNS and on servers do not
> reach the tunnel. Turn off Lock config (debug), and the next action in the
> interface rebuilds the config from the settings.

The diagnostics playbook — [DIAGNOSTICS.md](DIAGNOSTICS.md).

---

## Automation API

### Automation: the VPN turns on by events

Automation apps — Tasker, MacroDroid, Llama, Automate — control L×Box: they
turn the VPN on and off and switch servers by events, without the phone
owner's involvement. Typical scenarios:

- connecting to the home Wi-Fi turns the VPN off, connecting to someone else's
  or a public one turns it on;
- launching a specific app switches to the server or direction it needs;
- a schedule or a geofence turns the tunnel on and off.

Command intake is off by default. Where: App Settings → **Automation** →
Accept automation commands. The same tab allows L×Box to broadcast its events:
connected, disconnected, subscription updated. Then pick L×Box as a plugin in
the automation app and choose a command: Start VPN, Stop VPN, Toggle VPN or
Custom… — seven commands, Switch node and Refresh subscriptions among them.

> 📖 [AUTOMATION.md](AUTOMATION.md) — the full list of commands and events and
> ready-made recipes, including control from shell and ADB.

### Automation opens the VPN to commands from other apps

The **Automation** tab lets Tasker, MacroDroid and other automation apps
control L×Box and receive its events. Scenarios and setup steps are in
[Automation](#automation-the-vpn-turns-on-by-events); below is what the tab
offers beyond that. Where: App Settings → Automation.

The **Accept automation commands** option is off by default. Turning it on
shows the Enable command receiver? dialog. While the option is on, any app
on the phone can control the VPN with broadcast commands. Turn it off if you
do not use an automation app.

The **Commands (intent actions)** list holds 10 commands, each with a copy
button. Paste the string into the automation app's Send Intent action, with
Broadcast Receiver as the target. Four commands take a parameter:

| Command | Parameter |
|---|---|
| `com.leadaxe.lxbox.SWITCH_NODE` | `tag` — the node tag |
| `com.leadaxe.lxbox.SET_GROUP` | `group` — the group tag, for example `vpn-1` |
| `com.leadaxe.lxbox.URLTEST_GROUP` | `group` — the group tag, for example `vpn-1` |
| `com.leadaxe.lxbox.REFRESH_SUBS` | `force` |

The **Outbound events (emit)** section sends L×Box events outward. There
are three categories, all off by default:

| Category | Events |
|---|---|
| Lifecycle | `VPN_CONNECTED`, `DISCONNECTED`, `ERROR`, `REVOKED`, `UPDATE_AVAILABLE`, `PERMISSION_NEEDED` |
| State | `ACTIVE_NODE_CHANGED`, `ACTIVE_GROUP_CHANGED`, `NODE_ALREADY_ACTIVE` |
| Subscription | `SUB_REFRESHED`, `SUB_REFRESH_FAILED` |

Turning on a category for the first time shows the Emitting events outward
dialog: other apps see the events, but the events carry no subscription or
config secrets — only node tags, group names and status. For the automation
app to learn a command's result, turn on Lifecycle and State: success
arrives in State, failure as the `VPN_ERROR` event in Lifecycle.

The **Documentation and Tasker recipes** button opens the full list of
commands and events with ready-made recipes.
