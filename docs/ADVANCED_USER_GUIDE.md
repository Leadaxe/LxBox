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
  - [The path language picks nodes in the config](#the-path-language-picks-nodes-in-the-config)
  - [Seven actions](#seven-actions)
  - [The number of matches decides the outcome](#the-number-of-matches-decides-the-outcome)
  - [Examples](#examples)
  - [A failed mixin stops the build](#a-failed-mixin-stops-the-build)
  - [Mixins, manual edits and Lock config](#mixins-manual-edits-and-lock-config)
  - [Backup and Debug API](#backup-and-debug-api)
  - [Limits](#limits)
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
last step of every build, so rebuilds do not lose it and Lock config is not
needed.

Typical case: a third-party firewall such as Rethink takes DNS queries to a
resolver address of your choice, and you want those queries answered by the
sing-box DNS module with the rules L×Box built. Two mixins do it: one adds a
`direct` inbound on `127.0.0.1:5354`, the other sends traffic from that
inbound to `hijack-dns`. Port 5353 on Android is often held by the system
mDNS service, so the examples use 5354; any free port works. The full mixins
are in [Examples](#examples).

When the build applies mixins: after presets, after the guards and the
automatic removal of broken nodes, before the final validation. Enabled
mixins run top to bottom, and each one sees the result of the ones above it.

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

**Target** — the path in the config, in the language described in
[The path language picks nodes in the config](#the-path-language-picks-nodes-in-the-config).
Under the field there is a live status:

| Status | Meaning |
|---|---|
| `✓ 1 match` | The path points at one node |
| `✓ N matches → before first` / `→ after last` | Several matches; for `before` and `after` the status says where the value goes |
| `✗ no match` | Nothing in the config matches the path |
| `✗ syntax: <message>` | The path does not parse |
| `✗ needs a single list` | `append`/`prepend` on a non-list or on several matches |
| `✗ not a list element` | `before`/`after` on an object key, not on a list element |

As you type, a list of suggestions appears under the field; it depends on the
cursor position:

| Cursor after | Suggestions |
|---|---|
| start of the line or `.` | Keys of the object at this level; `[` if the level is a list |
| `[` | Fields found in the list's elements, and indexes |
| `=` | Values of this field in the elements, in order of appearance |
| `,` inside brackets | Fields not used in this condition yet |
| `]` | `.` |

The list is filtered by the typed fragment; a tap inserts the item and moves
the cursor on. If the text before the cursor does not parse, there are no
suggestions. The light bulb icon on the right of the field (tooltip
Suggestions) turns suggestions on and off: filled — on, outlined — off. The
choice is remembered between openings of the form and does not trigger a
rebuild. With suggestions off, the live status still works.

**Action** — one of seven actions, see [Seven actions](#seven-actions). For
`remove` a Whole node / Keys switch appears. With Keys the Value field is
replaced by the field `Keys, comma-separated`.

**Value** — a JSON editor with a Format button. It accepts JSON5: comments,
trailing commas. On Save the value is converted to plain JSON. A parse error
is shown under the field.

**Preview** — the target's parent after the mixin is applied, with its path
in the header (`(root)` for the root). One line per element, compact JSON cut
to the screen width, with a marker on the left:

| Marker | Meaning |
|---|---|
| (space) | Unchanged |
| `+` | Inserted |
| `~` | Changed |
| `-` | Removed |

A tap on a line opens the element's full JSON. A scalar target shows one line
`old → new`. Errors that depend on the value — `merge` with a non-object
value, a duplicate tag — are shown as a `⚠` line above Preview; they do not
block Save, but the build fails.

Suggestions, status and preview come from the config of the last build as it
was before mixins, with the enabled mixins above this one applied. A mixin is
therefore checked against what it will actually see during the build.

Save is inactive while the status shows ✗, while Value does not parse, and,
for `remove` with Keys, while the key list is empty. Leaving the form with
unsaved changes asks Discard, Keep or Save.

### The path language picks nodes in the config

The path syntax is the app's own, not JSONPath. Grammar:

```
path       = "" | segment ("." segment)*
segment    = name | name "[" N "]" | name "[" conditions "]"
conditions = condition ("," condition)*
condition  = field "=" value
field      = name ("." name)*
```

Rules:

- Segments are joined by `.`: `route.rules`, `dns.servers`, `log.level`.
- An empty path is the root of the config.
- `name[0]` is a list element by index; `name.0` means the same.
- `name[k=v]` is every element of the list `name` whose field `k` equals `v`.
  Several conditions are joined by commas, and all of them must hold.
- The field in a condition may go deeper into the element:
  `outbounds[tls.enabled=true]`.
- Comparison: a number with a number, `true`/`false` with a bool, anything
  else as strings, case-sensitive.
- If the element's field is a list, `=` means "contains":
  `route.rules[rule_set=Ads]` matches a rule with
  `"rule_set": ["Ads", "Trackers"]`.
- The value runs up to `,` or `]`. Spaces inside are allowed, so tags with
  spaces work as they are: `outbounds[tag=S2 Fastest]`. A value cannot contain
  `,` or `]`.
- There are no regular expressions, no `!=` and no `or`. A path starting with
  `$` is reserved and is a syntax error.

A path denotes a set of nodes, not the first match: `outbounds[type=vless]` is
every VLESS outbound.

Examples with tags of a typical config (the tags in your config differ;
Target suggestions show the real ones):

| Path | What it points at |
|---|---|
| (empty) | The root of the config |
| `log.level` | The log level field |
| `inbounds` | The list of inbounds |
| `inbounds[tag=tun-in]` | The TUN inbound |
| `outbounds[0]`, `outbounds.0` | The first outbound |
| `outbounds[type=vless]` | Every VLESS outbound |
| `outbounds[tag=PR DE-1]` | The outbound tagged `PR DE-1` |
| `outbounds[tag=S2 Fastest]` | The urltest group `S2 Fastest` |
| `outbounds[tls.enabled=true]` | Every outbound with TLS on |
| `route.rules[action=hijack-dns]` | The DNS hijack rule |
| `route.rules[action=resolve,strategy=prefer_ipv4]` | Resolve rules with the `prefer_ipv4` strategy |
| `route.rules[rule_set=Ads]` | Every rule whose `rule_set` is `Ads` or contains it |
| `route.rules[inbound=tun-in]` | Every rule whose `inbound` list contains `tun-in` |
| `dns.servers[tag=google_udp]` | The DNS server `google_udp` |
| `dns.servers[tag=ru-direct:yandex_udp]` | A colon in the value is allowed |

### Seven actions

| Action | Target | Effect |
|---|---|---|
| `append` | One list | Puts the value at the end; a list value adds each element in turn |
| `prepend` | One list | The same at the start; the order of the value is kept |
| `before` | List elements | Puts the value (or each element of a list value, in order) at the same level before the **first** match |
| `after` | List elements | The same after the **last** match |
| `set` | Any node | Replaces the node whole: scalar, list or object. At the root — an object only |
| `merge` | Object(s) | Deep merge: keys of the value are added or replace their own, other keys stay; object into object recursively; a list inside the value replaces the target's list whole. The value must be an object |
| `remove`, Whole node (value `true`) | Any node | Removes the node: a list element drops out, an object key disappears. The root cannot be removed |
| `remove`, Keys (value `["key", "a.b"]`) | Object(s) | Removes only the named keys; a dotted key goes inside the element; a missing key is not an error |

`merge` adds new keys at the end of the object; the core ignores key order.

### The number of matches decides the outcome

| Action | 0 matches | 1 match | Several matches |
|---|---|---|---|
| `set`, `merge`, `remove` | Error | Applied | Applied to each, with the same value |
| `before` | Error | Before it | Before the first |
| `after` | Error | After it | After the last |
| `append`, `prepend` | Error | Into this list | Error |

### Examples

Each example below is a mixin record as the Debug API and LX Backup store it.
In the form `target` is Target, `op` is Action, `value` is Value.

**1. DNS listener for another app.** Two mixins, in this order:

```json
{"name": "DNS listener", "target": "inbounds", "op": "append",
 "value": {"type": "direct", "tag": "dns-in", "listen": "127.0.0.1",
           "listen_port": 5354, "override_address": "1.1.1.1", "override_port": 53}}
{"name": "Hijack DNS from dns-in", "target": "route.rules[action=hijack-dns]", "op": "before",
 "value": {"inbound": ["dns-in"], "action": "hijack-dns"}}
```

The first adds the inbound. The second puts a rule before the existing
`hijack-dns` rule: everything that arrives at `dns-in` goes to the DNS module,
which answers by the DNS rules of the config. In the firewall, the DNS server
is `127.0.0.1`, port `5354`. A check from a computer:

```
adb forward tcp:5354 tcp:5354
dig +tcp @127.0.0.1 -p 5354 example.com
```

Turning the first mixin off removes `dns-in` from the config; the pair is
meant to be turned on and off together.

**2. A local domain goes direct.** The rule goes right after the resolve
rule with the `prefer_ipv4` strategy, ahead of the template's routing rules:

```json
{"name": "NAS direct", "target": "route.rules[action=resolve,strategy=prefer_ipv4]", "op": "after",
 "value": {"domain_suffix": [".nas.home"], "outbound": "direct-out"}}
```

**3. A field on every VLESS outbound:**

```json
{"name": "TFO on VLESS", "target": "outbounds[type=vless]", "op": "merge",
 "value": {"tcp_fast_open": true}}
```

**4. Group settings the form does not offer:**

```json
{"name": "Fastest: check every minute", "target": "outbounds[tag=S2 Fastest]", "op": "merge",
 "value": {"interval": "1m", "tolerance": 100}}
```

**5. Remove keys from one node.** In the form: Action `remove`, Keys,
`tcp_fast_open, tls.utls`:

```json
{"name": "PR DE-1 without uTLS", "target": "outbounds[tag=PR DE-1]", "op": "remove",
 "value": ["tcp_fast_open", "tls.utls"]}
```

**6. Remove a whole rule:**

```json
{"name": "No ad blocking", "target": "route.rules[rule_set=Ads]", "op": "remove", "value": true}
```

**7. Replace a scalar and add a top-level key:**

```json
{"name": "Quiet log", "target": "log.level", "op": "set", "value": "warn"}
{"name": "Empty services", "target": "", "op": "merge", "value": {"services": []}}
```

`prepend` on `route.rules` puts the rule before Traffic Processing (sniff,
hijack-dns). This is allowed; such a rule sees connections before sniffing.

### A failed mixin stops the build

A mixin that cannot be applied stops the build: the config is not built, the
build reports a fatal error, and the mixin's row in the list gets a `⚠` line.
The previously built config stays in place. Error texts:

| Text | Cause |
|---|---|
| `Mixin "<name>": <target>: no match` | Nothing matches the path |
| `Mixin "<name>": <target>: needs a single list` | `append`/`prepend` on a non-list or on several matches |
| `Mixin "<name>": <target>: not a list element` | `before`/`after` on an object key (`inbounds`, `log.level`) |
| `Mixin "<name>": <target>: not an object` | `merge` or `remove` with Keys on a non-object |
| `Mixin "<name>": <target>: merge needs an object value` | The `merge` value is not an object |
| `Mixin "<name>": duplicate tag "x" in outbounds` | After all mixins, two elements share a tag |

An empty path is shown as `(root)`. Tags are checked for uniqueness separately
in `inbounds`, in `outbounds` together with `endpoints` (one name space, as in
the core) and in `dns.servers`.

The mixin stays enabled after an error: fix it or turn it off. A path that
matched yesterday can stop matching after a subscription update renames a
node; the build then fails with `no match`.

### Mixins, manual edits and Lock config

A manual edit on the Config tab and mixins are independent. The next rebuild
discards the manual edit and applies the mixins again. To keep an edit, write
it as a mixin.

Lock config stops rebuilds altogether: the config stays as you saved it, and
neither settings nor mixins reach it. Mixins keep the rebuilds and change only
their own nodes. For everyday use mixins replace the pair "manual edit + Lock
config"; Lock config remains for testing a config pushed through the Debug
API.

### Backup and Debug API

Mixins are part of the settings. LX Backup saves them in the `mixins` section.
Import appends them to the end of the list; a mixin with the same `target`,
`op` and `value` as an existing one is skipped, not duplicated.

The Debug API serves mixins at `/mixins`: list, create, `PATCH`, delete,
reorder and the preview of one mixin (`GET /mixins/{id}/preview`, the same
data the form shows). Writes check the path syntax and the action; a match is
checked only by the build, since the target may appear after another mixin.
Requests and responses —
[Debug API reference → Mixins](api/debug-api-reference.md#mixins-crud--mixins).
The formal description of the function —
[docs/spec/features/019-CONFIG_EDITOR/FUNCTIONS/mixins.md](spec/features/019-CONFIG_EDITOR/FUNCTIONS/mixins.md).

### Limits

- After the app restarts and before the first build, the form shows
  `No config built yet` under Target: no match count, no suggestions, no
  preview. Save checks only the path syntax and Value; matches are checked by
  the next build.
- Mixins work on the finished config: the automatic removal of broken nodes
  and the outbound sanitizer do not see them. A duplicate tag is caught before
  the core; anything else the core does not accept (an unknown field, a wrong
  type) is reported by the core when the VPN starts. For a tagged element the
  error names its tag; for a rule — only its index.
- A path starting with `$` is reserved.
- Mixins cannot be grouped and have no shared toggle.
- The desktop launcher's backup schema does not declare the `mixins` section
  yet; the launcher warns about an unknown field when importing such a
  backup.

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
