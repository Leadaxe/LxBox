# L×Box — how it works

A user guide: what is what, and what each part is responsible for. Not about the
code — about the logic and the order in which to set things up.

> Русская версия: [USER_GUIDE.ru.md](USER_GUIDE.ru.md)

## Contents

- [What is what](#what-is-what)
- [Traffic passes four stages](#traffic-passes-four-stages)
- [Operating mode: tunnel, local proxy or both](#operating-mode-tunnel-local-proxy-or-both)
- [1. Tunnel apps decides which apps enter L×Box](#1-tunnel-apps-decides-which-apps-enter-lbox)
  - [Allow VPN bypass lets apps go past the tunnel](#allow-vpn-bypass-lets-apps-go-past-the-tunnel)
- [Setting up from scratch](#setting-up-from-scratch)
- [Servers come from three sources: server, subscription, folder](#servers-come-from-three-sources-server-subscription-folder)
  - [Standalone server — one entry added by hand](#standalone-server--one-entry-added-by-hand)
  - [Subscription — a provider's server list that updates itself](#subscription--a-providers-server-list-that-updates-itself)
  - [Folder — a group of servers assembled by hand](#folder--a-group-of-servers-assembled-by-hand)
  - [Auto node — one list entry with a pool of servers inside](#auto-node--one-list-entry-with-a-pool-of-servers-inside)
  - [Servers carry traffic only through directions](#servers-carry-traffic-only-through-directions)
  - [The subscription screen has four tabs: Nodes, Settings, Source, Filters](#the-subscription-screen-has-four-tabs-nodes-settings-source-filters)
- [2. Directions sets the exits and the default path](#2-directions-sets-the-exits-and-the-default-path)
  - [Interrupt connections on switch — three switches for three events](#interrupt-connections-on-switch--three-switches-for-three-events)
- [3. Rules sets exceptions to the default](#3-rules-sets-exceptions-to-the-default)
  - [A rule can assign a DNS server to its own domains](#a-rule-can-assign-a-dns-server-to-its-own-domains)
  - [Raw JSON and the View tab cover fields the form lacks](#raw-json-and-the-view-tab-cover-fields-the-form-lacks)
- [4. DNS decides which server resolves each name](#4-dns-decides-which-server-resolves-each-name)
  - [Group and Shield DNS combine several servers under one tag](#group-and-shield-dns-combine-several-servers-under-one-tag)
  - [DNS Rules assign a DNS server to a domain](#dns-rules-assign-a-dns-server-to-a-domain)
- [Detour sends a server to the internet through another server](#detour-sends-a-server-to-the-internet-through-another-server)
  - [Detour is set on a server, subscription or folder](#detour-is-set-on-a-server-subscription-or-folder)
  - [Detours form a chain but not a loop](#detours-form-a-chain-but-not-a-loop)
  - [A direction with Use as detour serves as a switchable relay](#a-direction-with-use-as-detour-serves-as-a-switchable-relay)
  - [The whole detour chain runs inside one tunnel](#the-whole-detour-chain-runs-inside-one-tunnel)
  - [Statistics shows which servers a connection went through](#statistics-shows-which-servers-a-connection-went-through)
  - [A node with a ping error flags its dependents with ⚠](#a-node-with-a-ping-error-flags-its-dependents-with-)
- [Hop chains — a route you build yourself](#hop-chains--a-route-you-build-yourself)
  - [A chain builds a route; a detour builds a relay in front of a server](#a-chain-builds-a-route-a-detour-builds-a-relay-in-front-of-a-server)
  - [Positions follow packet order](#positions-follow-packet-order)
  - [The editor refuses to save a chain that breaks four rules](#the-editor-refuses-to-save-a-chain-that-breaks-four-rules)
  - [The Diagnostics tab shows which hop breaks the chain](#the-diagnostics-tab-shows-which-hop-breaks-the-chain)
  - [A chain needs a recent core and compatible hops](#a-chain-needs-a-recent-core-and-compatible-hops)
- [IPv6 in the tunnel is off; turn it on only if your network supports it](#ipv6-in-the-tunnel-is-off-turn-it-on-only-if-your-network-supports-it)
- [Common problems: symptom, cause, action](#common-problems-symptom-cause-action)
- [If something goes wrong — where to look](#if-something-goes-wrong--where-to-look)
- [Recipes](#recipes)
  - [Share the VPN with other devices over Wi-Fi](#share-the-vpn-with-other-devices-over-wi-fi)
  - [ByeDPI and other local proxies connect as an ordinary server](#byedpi-and-other-local-proxies-connect-as-an-ordinary-server)
  - [Double hop: the last server does not see your IP](#double-hop-the-last-server-does-not-see-your-ip)
- [Get WARP adds a server without a subscription](#get-warp-adds-a-server-without-a-subscription)
- [The server list filters, labels and copies servers as links](#the-server-list-filters-labels-and-copies-servers-as-links)
- [Regular expressions (regex)](#regular-expressions-regex)
  - [The ! toggle negates the whole pattern](#the--toggle-negates-the-whole-pattern)
  - [Patterns use JavaScript syntax](#patterns-use-javascript-syntax)
  - [Examples by task](#examples-by-task)
  - [Lookahead and lookbehind negate part of a condition](#lookahead-and-lookbehind-negate-part-of-a-condition)
  - [The filter ignores case and matches anywhere in the name](#the-filter-ignores-case-and-matches-anywhere-in-the-name)
- [Quick connect: the VPN turns on without opening the app](#quick-connect-the-vpn-turns-on-without-opening-the-app)
- [Automation: the VPN turns on by events](#automation-the-vpn-turns-on-by-events)
- [App language](#app-language)
- [Workspaces — named sets of settings](#workspaces--named-sets-of-settings)
- [Backup moves settings to another device](#backup-moves-settings-to-another-device)

---

## What is what

The terms people mix up most often:

| Term | In one line |
|---|---|
| Server | A single exit point you can connect to. One server can belong to several directions. |
| Subscription / folder | A source of servers: a provider's list (subscription) or one built by hand (folder). On their own they carry no traffic until their servers land in a direction. |
| Auto node | One list entry that holds a pool of servers and selects between them automatically. |
| Direction | A set of servers built for a task: it picks servers with a filter and switches between them. L×Box splits traffic across directions. |
| Hop chain | A route through several servers in order: "you → hop 1 → hop 2 → destination". A source, like a subscription, not a group. |
| Tunnel apps | Which phone apps enter L×Box. |
| Detour | A setting of a server, subscription or folder: exit through another server. Other clients call the same thing a jump server, relay or chain. Not a separate server and not a direction. |
| Rules (routing / DNS) | Exceptions: which traffic goes to which direction and which DNS resolves it. |

---

## Traffic passes four stages

App traffic passes four stages, and each answers its own question:

```
   Apps on the phone
            │
            ▼
 ┌─────────────────────────┐
 │ 1. Tunnel apps          │   Which apps enter L×Box.
 │                         │   Anything left out goes direct, as without a VPN.
 └─────────────────────────┘
            │  (traffic of admitted apps)
            ▼
 ┌─────────────────────────┐
 │ 2. Directions           │   Which directions exist and where traffic goes
 │    (Default traffic)    │   by default: a direction, direct or block.
 └─────────────────────────┘
            │
            ▼
 ┌─────────────────────────┐
 │ 3. Rules                │   Exceptions to the default:
 │                         │   which domain or app goes to which direction.
 └─────────────────────────┘
            │
            ▼
   Direction (server) · direct · block
            │
            ▼
 ┌─────────────────────────┐
 │ 4. DNS                  │   How site names turn into IP addresses.
 └─────────────────────────┘
```

The stages do not replace one another: an app left out of L×Box at the first
stage never reaches Directions, Rules or DNS.

---

## Operating mode: tunnel, local proxy or both

The **Mode** setting decides how traffic reaches L×Box: through the system
tunnel, through a local proxy or through both at once. Where: VPN Settings →
Mode. Three options:

| Option | What it does |
|---|---|
| **VPN** (default) | L×Box takes the Android VPN slot and receives all app traffic. This guide describes this mode. |
| **Proxy** | No tunnel and no key icon. L×Box starts a local proxy, and only apps with the proxy set by hand send traffic to it. The Android VPN slot stays free: the mode coexists with another VPN app. |
| **VPN + Proxy** | The tunnel and the proxy port at the same time. |

The proxy is configured on the same tab, with four options:

| Option | Default | What it does |
|---|---|---|
| Local proxy protocol | Mixed | Mixed — HTTP and SOCKS5 on one port; HTTP only; SOCKS5 only. |
| Listen address | `127.0.0.1` | `127.0.0.1` — the proxy is reachable from this device only; `0.0.0.0` — from the whole local network: a TV or a second phone goes out through L×Box on this phone. |
| Listen port | `2080` | The proxy port. |
| Require auth | off | Username and password from the Proxy username and Proxy password fields. With any Listen address other than `127.x`, it is on and cannot be turned off. |

In the proxy modes Tunnel apps has no effect: the tab controls the tunnel only,
and the proxy receives traffic from the apps configured to use it. In routing
rules the INBOUND condition separates tunnel traffic from proxy traffic.

---

## 1. Tunnel apps decides which apps enter L×Box

The **Tunnel apps** tab decides which phone apps come under L×Box control.
Where: Routing → Tunnel apps. Three modes:

| Mode | What it does |
|---|---|
| **Off** (default) | All apps go through L×Box. |
| **Allow-list** | Only the selected apps go through L×Box; the rest go direct. |
| **Deny-list** | All apps go through L×Box except the selected ones. |

An app left out of L×Box (not in the Allow-list, or in the Deny-list) goes out
directly, as without a VPN; L×Box does not see it, and Rules do not apply to it.

L×Box itself does not need to be in the Allow-list: its service connections and
DNS go past the tunnel over the physical network, and the entry changes
nothing. If the VPN started working after you added L×Box to the Allow-list,
the entry did not fix it; Default traffic, changed at the same time, did.

### Allow VPN bypass lets apps go past the tunnel

This setting allows apps to go out to the network past the tunnel if they ask
the system for it themselves. Banking clients, carrier apps and dialers with
VoLTE/VoWiFi behave this way: under a VPN they stop working; with this
permission they work again, but the privacy of their traffic is no longer
guaranteed.

Where: VPN Settings → Mode → Tunnel options → **Allow VPN bypass**; the switch
is visible in the VPN and VPN + Proxy modes. Off by default: a strict tunnel,
all admitted traffic goes through the VPN, and an app cannot get around it. On:
an app that asks Android (ConnectivityManager) for the physical network itself
goes out past the tunnel. After switching, restart the VPN.

The switch is a permission, not a route: by itself it moves no app past the
tunnel; only apps that can do this go around it. A Deny-list, by contrast,
forces the selected apps out of the VPN, whatever the app.

| Situation | What to choose |
|---|---|
| Take a specific app out of the VPN regardless of its behaviour | Deny-list |
| The app conflicts with a VPN on its own and can request a bypass | Allow VPN bypass |

---

## Setting up from scratch

Sections open from the side menu: swipe from the left edge or tap the ≡ icon
on the home screen. Servers holds servers, subscriptions and folders; Routing
holds directions, rules and Tunnel apps; DNS Settings holds DNS.

1. A source of servers. Servers → add the source that fits the situation:
   - one config — a standalone server: link, QR or file;
   - a provider's link — a subscription by URL, updates itself;
   - your own set of servers — a folder.

   Without a subscription, Get WARP provides a working server (see below).
2. **Directions** (Routing → Directions). To send all traffic through the
   tunnel by default, check that Default traffic = VPN.
3. **Tunnel apps** (Routing → Tunnel apps), optional. Off — all apps go through
   L×Box; Allow-list — only the selected ones.
4. **Rules** (Routing → Rules). Exceptions: ads → Block, local domains →
   Direct; ready-made sets are in Presets.
5. **DNS** (DNS Settings). The default is the Shield DNS group, which survives
   the failure of any single resolver. Change anything here only if you need
   strictly encrypted DNS or your own resolvers.
6. Detour, optional. Set an exit through a chain of servers in the settings of
   a server, subscription or folder (see the detour section).
7. **Start** on the home screen. The VPN connects, and the button changes to
   Stop.

---

---

## Servers come from three sources: server, subscription, folder

The **Servers** screen gathers every place the app gets servers from. Where:
≡ → Servers (the menu label reads Subscriptions & proxy). There are three
sources; they look alike but behave differently:

| Source | What it is | Servers | Updates | When to create |
|---|---|---|---|---|
| Standalone server | One server added by hand | 1 | Never: the entry is static | You have one config |
| Subscription | A provider's list of servers behind a link | Many | On its own, on a schedule, or via Update | You have a link from a provider |
| Folder | A group of servers assembled by hand under one name | As many as you put in | Never: you manage the contents | A set of your own `.conf` files and links you want to keep together: "my Mullvad" |

Sources do not touch the traffic stages: they only supply servers, and
directions carry the traffic (section below).

### Standalone server — one entry added by hand

You add a standalone server by link (`vless://…`, `vmess://…`, `wg://…`),
QR code or file. It has nothing to update: the entry is static.

The **Masquerade** section of your own WireGuard or AmneziaWG server adds
decoy packets before the handshake: the client sends packets that look like
QUIC, DNS, STUN or SIP. Where: server screen → Settings → Masquerade.
Options:

| Option | Domain |
|---|---|
| Off (default) | No decoys |
| QUIC | Required: becomes the SNI in the decoy ClientHello |
| DNS | Visible on the wire; left empty, the core makes one up |
| STUN | Not set |
| SIP | Visible on the wire; left empty, the core makes one up |

The app saves the choice at once, as it does for the detour server: it
writes the `ip`/`id`/`ib` keys into the server's source — link, `.conf` or
JSON — and leaves the rest of the source text unchanged. A plain WireGuard
server drops the decoys, so masquerade does not break it; the node is then
labelled AmneziaWG.

If the source sets `I1` itself, the section is off: `I1` takes priority.

### Subscription — a provider's server list that updates itself

A subscription is a link from a VPN provider that stands for a whole list
of servers. L×Box looks after that list this way:

- downloads it on its own on a schedule: the Update interval setting, 24h
  by default; by hand — the **Update** item in the subscription menu;
- on a failed update, keeps the old list and goes on working with it;
- shows the provider's details when the provider sends them: traffic left,
  expiry date, a link to the site or support.

A file subscription is a server list imported from a file instead of a
link. It behaves like a subscription: many servers under one name. It does
not update on its own; you supply a new file through **Edit source**.

The **Get WARP** item in the ⋮ menu of the Servers screen registers
Cloudflare WARP for free and adds it as a server — for those without a
subscription of their own. Details at the end of the guide.

### Folder — a group of servers assembled by hand

A folder gathers servers you added yourself under a shared name, with a
shared on/off switch and an order you change by dragging. A folder answers
where the servers are kept; a direction answers which servers to use for a
job (Directions section).

You enable, disable and reorder each server in a folder (the settings label
it member) separately and can give it its own detour (detour section). A
subscription does not go into a folder: folders hold only servers added by
hand.

### Auto node — one list entry with a pool of servers inside

An auto node is one list entry that holds several servers and automatic
selection between them. It appears in two ways.

The first way is a subscription. Providers put an entry like "Auto | Best
server" in it — a pool of many servers. In the list this entry is one node,
and its row shows the mode and contents: `🔀 [15/7]` — a pool of 15 with 7
in use (load-balance mode), `🎯 [3]` — the single fastest of three.

The second way is your own folder. The **Add auto node…** item in the folder
menu creates an auto node from the folder's servers. You set its membership
in one of three ways:

| Method | What goes into the auto node |
|---|---|
| All | Every server in the folder |
| Rule | Servers matched by include/exclude regex; a live preview shows `12 of 37 servers` |
| Pick | Servers you tick by hand |

The Mode field sets the selection mode; in Load balance mode, Sticky session
by appears below it — session stickiness. The test interval and the
Interrupt connections on switch checkbox sit in the Advanced section. The
app has three checkboxes with that name; which one fires when is covered in
[Directions](#interrupt-connections-on-switch--three-switches-for-three-events).

A direction's auto twin (`<direction>-auto`, Directions section) is a
different object: it collects the direction's nodes by the direction's
filter, while an auto node lives in the general server list alongside the
others.

### Servers carry traffic only through directions

Servers from subscriptions, folders and standalone entries carry no traffic
on their own. They go into a common pool, and directions pick the ones they
need from the pool by filter and connect to them. Hence the order: first add
a subscription, folder or server, then a direction picks them up.

The **Tag prefix** setting adds a short label to the names of all servers in
a subscription or folder. Where: subscription or folder screen → Settings →
Tag prefix; empty by default. Direction filters rely on the prefix: give a
folder the prefix `mullvad-`, and a direction with the filter `^mullvad-`
collects exactly its servers. Without direction filters you do not need the
prefix.

### The subscription screen has four tabs: Nodes, Settings, Source, Filters

A tap on a subscription on the Servers screen opens its screen: here you
disable individual nodes, change update parameters and see what exactly the
provider sent. The tabs split these jobs: Nodes holds the nodes, Settings
holds updates and how the subscription presents itself to the provider,
Source holds the raw response, and Filters holds the rules that change
nodes on import.

The **Nodes** tab shows the node list, and each node has its own switch.
You switch off an unwanted node and the subscription stays on: a disabled
node appears dimmed and does not reach the config. The choice survives
subscription updates and provider-side renames. The master switch at the
left of the bar above the list turns all nodes on or off at once.

A short tap on a node opens its breakdown. The JSON tab shows how the node
goes into the config; the Source tab shows the original subscription
fragment the node was built from. If import rules changed the node, a
Replacements tab appears and shows what exactly they changed.

A mark under a node appears when the app finds something in it worth
reporting: a field the core does not know; a value outside the allowed
range; a setting the app had to clean up or drop. There are three levels:

| Mark | Meaning | How the node list shows it |
|---|---|---|
| ✖ red | Error: the node will most likely not work as it came | As text |
| ⚠ yellow | Something was cleaned up or substituted; worth a look | As text |
| ⓘ blue | Information; nothing to do | A dimmed icon without text |

The node list shows only red and yellow notifications as text: a short
headline of the most severe one and a `(+N more)` counter, which also counts
only those. This way the lines that need attention do not drown among the
rest. The dimmed ⓘ sits at the start of the protocol line if the node has
nothing else, and at the end of the warning line if the node also has a
yellow or red one. The node's name stays clean, and the node gets no third
line.

A tap on the warning line or on the ⓘ opens the node's **Notifications**.
The top shows counters by level (`✖ 1 · ⚠ 2 · ⓘ 3`; levels without
notifications are left out), followed by the Errors, Warnings and Info
sections. A notification is a one-line headline; a tap expands it into the
field it concerns, What happened, Why it happens, What you can do and a
Details link to the full page about that code. The same list appears as the
Notifications section at the bottom of the Settings tab on the node's own
screen; a node without notifications has no such section. Most often a
notification does not mean the node is broken: usually it reports a setting
the app quietly dropped because the core would have rejected the whole
config over it.

The red line "The core rejected this server" is the only one after which
the server is switched off rather than marked. The core checks the whole
configuration and refuses to start on the first server it cannot accept;
otherwise one broken line would cut off every server. So the app switches
that server off, quotes the core's reply word for word and starts again. If
several servers are bad, a banner on the main screen says how many, and the
**Show** button lists them.

You can bring such a server back in two ways. The first is to turn it on
with its switch: the core checks the server at the next start and, if it
refuses again, the server goes off again with the same explanation. The
second is to update the subscription: the provider may have fixed the server
already, and a server whose contents changed turns back on by itself. None
of this affects servers you switched off by hand.

The gauge icon in the bar above the node list pings the subscription's
nodes without starting the VPN. With the VPN running, a dialog appears with
**Stop VPN** and Cancel buttons: on top of a live tunnel the measurements
would be wrong.

The **Settings** tab holds Tag prefix, detour, Update interval and the two
settings below. The On update setting decides what to do when an update
brings a new set of nodes:

| Option | What it does |
|---|---|
| Rebuild config (default) | The app rebuilds the config; you apply it |
| Rebuild and reload core | Applies at once; the connection drops for a few seconds |
| Do nothing | The new set applies at the next config rebuild |

The **Fetch identity** section sets which client the subscription presents
itself as when it downloads from the provider. With the Custom identity
switch off, the subscription sends the global User-Agent, HWID and device
headers; with it on, a set of its own for this subscription only. A custom
set helps when you have several panels, each with its own HWID limit or
User-Agent-dependent response format.

A subscription that brings a single "App not supported" node instead of a
list is not broken: the provider's panel requires a device identifier
(HWID) and returns a placeholder node until it gets one. Turn on **Send
HWID** — globally (App Settings → Subscriptions) or in this subscription's
Fetch identity — and update the subscription.

The **Source** tab shows the provider's raw response. If the body is
base64-encoded, the Decode base64 checkbox expands it into the form the
subscription parser works with.

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

## 2. Directions sets the exits and the default path

The **Directions** tab lists the exits traffic takes to the outside and sets
which one works by default. Where: Routing → Directions.

There are three kinds of exit:

| Exit | Where it takes traffic |
|---|---|
| Direction | Out through a server picked from the server group of your subscriptions and folders |
| direct | Straight out, past the tunnel but through L×Box |
| block | Nowhere: the connection is dropped |

A fresh install lists two directions: `vpn-1` is on, `vpn-2` is off. You can
neither turn off nor delete `vpn-1`; when you delete another direction,
references to it move to `vpn-1`. The **Add direction** button adds
directions: for example, different servers for different jobs.

The **Default traffic** setting at the bottom of the tab sets the exit for
captured traffic that no rule in Rules matched. The options are direct, any
enabled direction and block. On a fresh install `vpn-1` is selected.

> ⚠️ An app in the Allow-list with Default traffic = direct goes out
> directly, and the VPN looks broken. The Allow-list decides whether traffic
> enters L×Box; Default traffic decides where it goes next. To send traffic
> through the tunnel, choose a direction in Default traffic.

A direction does not store servers; it selects them from the common pool: all
subscriptions, folders and standalone servers. The **Node filter (regex)**
field in the direction editor sets the selection:

- empty field — every server enters the direction;
- text or regex (`🇩🇪`, `^mullvad-`) — only servers whose name matched;
- the `!` toggle left of the field — every server except the matches.

Pattern syntax, examples and negation are in
[Regular expressions](#regular-expressions-regex).

One server belongs to several directions at once: a direction is a rule for
selecting servers for a job, not a place to keep them. A "Streaming" direction
with the filter `🇩🇪` collects German servers from every source, and they stay
available in `vpn-1`.

An auto twin picks a node of the direction by itself and gets the tag
`<direction>-auto`. The **Include auto (urltest)** box in the direction editor
controls it. On `vpn-1` and `vpn-2` the box is ticked out of the box; on a
direction you add, you tick it yourself. The **Mode** switch sets how the node
is chosen: `vpn-1` and `vpn-2` ship with Fastest, and when you turn on Include
auto on your own direction, the form sets Hold until failure. There are three
options:

| Mode | How the node is chosen |
|---|---|
| **Fastest** | All traffic goes to the single node with the lowest measured latency. |
| **Load balance** | Connections spread across a pool of several live nodes. A session stays on one node by the keys in Sticky session by, by default by app and domain, so rotation does not break connections. With no keys ticked, nodes alternate freely. |
| **Hold until failure** | The current node stays while it works; after a failure the choice moves to the next live one. |

You set the direction's tag: `ru-exit`, `streaming`, `vpn-1`. There is no cap
on the number of directions. A direction created without a name gets the next
free tag `vpn-N`. The form refuses a tag that is empty, reserved (`direct`,
`block`, `reject`), already taken or equal to someone's auto twin tag
`<tag>-auto`, and names the reason.

Besides the selected servers, a direction can offer direct, block and other
directions as options. The boxes sit in the **What goes into this direction**
section of the editor. Only directions listed above can be included: this
order rules out loops. Reorder the list and you change both what can be
included and the order of groups in the config.

### Interrupt connections on switch — three switches for three events

To move open connections to the new server as soon as the node changes, turn
on **Interrupt connections on switch**. Without this option, open connections
keep running through the old server until they close on their own: a download
finishes through the same exit, a messenger's long-lived socket stays where it
is. Usually that is what you want.

The option exists in three places, and each one answers its own event:

| Where | What it reacts to | How it works |
|---|---|---|
| VPN Settings → System → Interrupt connections on switch (off by default) | You tap a node on the home screen | The app closes the open connections of the switched group. Nothing goes into the config; switches made by the core stay uncovered. |
| Direction editor → Behavior (on by default) | The direction's choice changes from any source: a tap, Quick connect, an automation action, the API | Goes into the direction in the config; the core drops the connections. |
| Direction editor → Include auto (urltest), and the same box in an [auto node](#auto-node--one-list-entry-with-a-pool-of-servers-inside) (off by default) | The auto group changes node by itself: a faster node appeared or the current one failed | Goes into the auto group in the config; the core drops the connections. |

From the table:

- for a manual node change inside a direction, the first two switches
  duplicate each other; either one is enough;
- for an automatic change, only the third one works;
- to drop connections in every case, turn on all three.

The VPN Settings switch is one for the whole app; each direction and auto node
has its own copy of the other two. You can keep a work direction gentle and
make a streaming one strict.

---

## 3. Rules sets exceptions to the default

The **Rules** tab sets exceptions to Default traffic: which traffic goes to
which direction. Where: Routing → Rules → Add rule.

A rule consists of conditions and an action. The **Source** switch sets where
the conditions come from: Inline — form fields, Remote (.srs) — an external
list, Raw JSON — a config fragment. The form groups its conditions into
sections:

| Section | What it checks |
|---|---|
| MATCH | Domains (exact name, suffix, substring), IP subnets (CIDR), Private IP — destination on the local network, Private source IP — source with a local address. Shown when Source = Inline. |
| RULE-SET URL | An external list of domains and IPs in `.srs` format. The app downloads it and checks for updates at the interval in Check for updates; matching runs locally. Shown when Source = Remote (.srs). |
| PORT | Ports and port ranges. |
| APPS | Specific apps. |
| NETWORK & PROTOCOL | Traffic type TCP, UDP or ICMP and the application protocol recognised from the first packets: tls, quic, bittorrent, dns and others. |
| INBOUND | The entrance through which the packet reached L×Box: the VPN tunnel or the local proxy. The proxy option appears in the Proxy and VPN + Proxy modes. |
| WI-FI NETWORK | Name (SSID) or BSSID of the current Wi-Fi network: "at home → direct". |

Fields inside MATCH combine with OR; sections combine with each other with
AND. The rule "app Chrome, domain `*.youtube.com`, network UDP" fires only when
all three conditions match.

The **Action & Resolve** gear next to the direction picker sets the rule's
action. There are two modes:

- **Route to outbound** — matched traffic goes to the chosen direction, direct
  or block. The Resolve first box resolves the domain first and then picks the
  route.
- **Resolve only** — the rule only resolves; later rules or Default traffic
  pick the route. The mode is for advanced setups.

When Resolve first or Resolve only is on, the Resolve options panel opens.
Strategy sets the address family (`ipv4_only`); DNS server is auto by default,
following the route; Advanced DNS options cover cache, TTL, timeout and client
subnet.

Typical rules:

- ads and trackers → block;
- Russian domains (`.ru`, `.рф`) → direct: they do not need the tunnel;
- BitTorrent → the direction you need;
- a specific app → a specific direction;
- UDP (games, calls) → direct, TCP through the tunnel.

Rules apply top to bottom; the first match wins. If none matched, traffic goes
to Default traffic from Directions.

The **Presets** tab is a read-only catalog of ready-made rules. A preset does
nothing on its own: the Add to Rules button copies it into Rules, and from then
on it is your rule.

The Traffic Processing preset is pinned first in the rule list. It holds the
pre-processing the rest of routing depends on: protocol detection (sniff), DNS
query interception (Hijack DNS) and destination resolution. You cannot turn it
off, delete or move it; you change its settings inside the preset itself.

### A rule can assign a DNS server to its own domains

To have one rule decide both where traffic goes and which server resolves its
domains, turn on **Send DNS to dedicated server** in the DNS section of the
rule editor. The box adds a paired DNS rule: DNS queries for this rule's
domains go to the chosen server, `google_udp` by default. You do not build the
DNS rule by hand.

In the same section, the **Force IPv4 (drop AAAA)** box answers AAAA queries
for the rule's domains locally, and traffic goes over IPv4. It needs no
dedicated DNS server. The box helps on networks with broken IPv6.

Limitations the editor itself warns about:

- the pairing is unavailable with port and protocol filters: they are unknown
  at the time of the DNS query;
- with a rule-set the pairing works only if the list contains domains: IP-only
  lists never match DNS queries.

### Raw JSON and the View tab cover fields the form lacks

A rule can be written as a sing-box `route.rules` JSON fragment: choose Raw
JSON in Source. The JSON itself sets the action; the editor checks the syntax
as you type.

For a form-built rule, the **View** tab shows the finished sing-box fragment
that goes into the config.

---

## 4. DNS decides which server resolves each name

The **DNS Settings** screen sets how a site name becomes an IP. It has its own
server list and its own rules, separate from the routing rules. Where: DNS
Settings.

The DNS server catalog includes Google, Cloudflare, OpenDNS, Quad9 and Yandex
over UDP, DoT and DoH. Each server has an IP or profile and a direction it
travels through — the **Outbound (detour)** field. To send DNS queries through
the tunnel so the resolver sees the server's IP rather than your provider's,
set the server's Outbound to your VPN direction.

### Group and Shield DNS combine several servers under one tag

The **Group** DNS server type combines several servers under one tag. The
group picks who answers by one of three strategies:

| Strategy | How the server is chosen |
|---|---|
| **Stable** | Sticks to a working server until it fails. |
| **Fastest** | Races the servers, then stays with the winner. |
| **Parallel** | Races all servers on every query. |

The group remembers a member's error for a limited time: a server that works
again returns to service on its own. A group goes anywhere a single server
goes: as the default resolver, as the target of a DNS rule.

You build your own group in the DNS server editor: among the types UDP, DoT,
DoH, DoQ, DoH3 and Tailscale there is Group. Instead of an address, you tick
members — any of your DNS servers. Next to them you pick the **Selection mode**
and how long errors and wins are remembered: Error TTL and Win TTL, the latter
shown only for Fastest. A disabled or deleted member does not break the group:
the editor marks it as skipped, and once you re-enable it, it returns to its
place. In the server list a group carries the badge
`group · mode · member count`; with the tunnel up, it shows the current target
and each member's state: errors, RTT.

Shield DNS is the ready-made `dns_shield` group of six servers from five
providers: Google, Cloudflare, OpenDNS, Quad9 and Yandex, in Fastest mode.
Every server in the group is encrypted (DoT and DoH); part of them go direct,
the rest through `vpn-1`. No single failure turns resolution off:

- a provider fails — the others answer;
- the tunnel drops — the direct paths work;
- the direct path is unreachable — the tunnelled ones work.

The **DNS Final** setting sets the resolver for app queries that no DNS rule
matched. On a fresh install it is `dns_shield`. Installs upgraded from older
versions may still have `cloudflare_udp`; you can select the group yourself.
For encrypted DNS, use `google_doh`, `cloudflare_dot` or a server with
Outbound = VPN direction.

The **Default Domain Resolver** setting sets the resolver for sing-box itself:
server addresses and domains in routing rules. On a fresh install it is
`dns_shield`.

> ⚠️ `local_dns_resolver` in Default Domain Resolver sends queries to the
> system DNS past the VPN, and your provider sees them. Choose `dns_shield` or
> another server from the catalog.

### DNS Rules assign a DNS server to a domain

The **DNS Rules** list on the DNS Settings screen sets which server resolves
which domains. Like routing rules, DNS rules apply in order: you can drag
them, and each has a switch. Rules in the list come from four sources:

- your own — the **Add user rule** button; you write the rule as a sing-box
  `dns.rules` JSON fragment, an advanced-level tool;
- from presets — an enabled routing preset brings its own DNS rules;
- from the template — the baseline configuration rules;
- mirrors of routing rules — rules with Send DNS to dedicated server (see the
  Rules section); they appear as the From routing rules group, and you edit
  them in the parent rule.

The Ru internet segment preset resolves ru domains with its own `dns_ru` group
of three paths: UDP through the preset's direction, DoT through `vpn-1`, DoH
direct. A failed node on one path does not stop ru sites.

For the task "these domains → that DNS", enabling the DNS section in a routing
rule is simpler than writing a DNS rule by hand.

---

## Detour sends a server to the internet through another server

The **Detour server** setting sends a server to the internet through another
server instead of directly. Other clients call the same thing a jump server,
relay or chain.

```
  you → [Server A] → [Server B] → internet
                     ▲
              detour of server A: A goes out through B
```

Detour solves three problems:

- exit with an IP from the country you need: you enter through the nearby
  server A and exit with the IP of server B;
- reach a server whose IP your network cannot reach directly: A is reachable,
  and A can see B;
- split knowledge of the route: no single server sees both you and the final
  site.

Detour is a property of a server, subscription or folder, not a separate
server and not a direction. It has three kinds of target:

| Target | What happens |
|---|---|
| **None (direct)** (default) | The server goes out to the internet directly. |
| Another server | A standalone server or a folder member: a fixed relay. |
| A direction | The server goes out through whichever server the direction selects at the moment; by default the direction picks by speed. This target is called a detour direction. |

### Detour is set on a server, subscription or folder

You pick a detour in the same **Detour server** window every time; you open it
from the settings of whatever you assign the relay to.

| Assigning to | Where | Applies to |
|---|---|---|
| One server | Node Settings (tap the server) | This server only |
| A whole subscription | Subscription → **Settings** tab | All servers of the subscription |
| A whole folder | Folder → **Settings** tab | All folder members |
| One folder member | Folder → the member | This member only |

The window has four sections:

- **None (direct)** — no detour;
- **This folder** — members of the same folder; the section appears in the
  settings of a folder and of its members;
- **Directions** — detour directions; the section appears when such
  directions exist;
- **Standalone servers** — standalone servers.

### Detours form a chain but not a loop

Detours can form a chain: A through B, B through C, and traffic goes
`you → A → B → C → internet`. This is a chain of detours; the
[Hop chain](#hop-chains--a-route-you-build-yourself) source is a different
thing, compared in its own section. Inside a folder such chains link its
members: a member goes out through another member of the same folder. A member
that serves as an intermediate hop for another carries the ⚙ icon.

L×Box will not start a loop of detours. When it builds the config, the app
finds the cycle, the VPN does not start, and the **Routing loop — VPN not
started** window opens with the list of culprits. Tapping a culprit takes you
to its source: change or remove the detour there, and the loop breaks.

### A direction with Use as detour serves as a switchable relay

The **Use as detour** checkbox in the direction editor lets you pick this
direction as a detour target. Any server can then go out through the
direction, and the direction's own selection decides which server inside it
carries the traffic: by default, the fastest one. The relay is no longer
pinned to one server.

The checkbox takes no other role away from the direction: it stays a target
for rules and for Default traffic. Pickers mark it with the ⚙ icon.

### The whole detour chain runs inside one tunnel

Detour does not start a second VPN on top of the first at the Android level:
the whole chain lives inside one L×Box tunnel, and the phone spends no
resources on a second tunnel.

### Statistics shows which servers a connection went through

To check a detour, open **Statistics**: the item is available while the VPN is
on. In a connection's details, the Detour line shows the chain of exits
(`A → B → …`), and the Chain line sits next to it. Together they show whether
traffic went through the intermediate server.

### A node with a ping error flags its dependents with ⚠

A node with an ERR ping that other nodes or DNS servers go out through gets
the **⚠** icon next to its name. The app counts dependencies both direct and
through a direction where this node is selected. Tapping the icon opens the
list of affected entries with the dependency path: you see who this hop takes
down with it.

If DNS servers depend on the node, a banner appears as well. Domains of such a
DNS server stop resolving without an error message, and without the banner
this looks like the internet has gone.

---

## Hop chains — a route you build yourself

A hop chain (in the app, **Hop chain**) is a source of servers, like a
subscription or a standalone server; it holds a route of several servers in
the order you set. Where: Servers → ⋮ menu → Add hop chain….

```
  you → [hop 1] → [hop 2] → [hop 3] → internet
```

L×Box builds one exit from this order. In the common source list a chain is an
ordinary row: you can switch it off, drag it and pick it with a direction's
filter.

### A chain builds a route; a detour builds a relay in front of a server

A chain and a detour solve the same problem from opposite ends:

| | Hop chain | Detour |
|---|---|---|
| What it is | A route, a source in its own right | A property of one server |
| What you set | This route goes through these servers in this order | This server goes out through that one |
| Where you edit it | In the chain editor | On the server, subscription or folder |
| When to choose it | You need the route itself | One server needs a relay |
| Can traffic exit through the last server directly | Yes: chain positions stay standalone servers, and a direction with an empty filter offers them one by one | No: the relay belongs to the server, and no direct path to it remains |

The last row decides. If the last server must not see your IP (WARP behind
Proton), use a detour; see the recipe
[Double hop: the last server never sees your IP](#double-hop-the-last-server-does-not-see-your-ip).

### Positions follow packet order

Position 1 is the first hop from you; the last position is where traffic exits
to the internet. Drag positions to reorder them.

The editor offers two kinds of position:

| Position | What it does |
|---|---|
| Server (Servers section) | A fixed hop. |
| Direction (Directions section) | The hop switches on the fly: when the direction's selection changes, the hop changes. The list holds only directions with the Use as detour checkbox. |

The editor does not offer a group or another chain as a new position.
Existing positions of these kinds keep working and go through the checks
below.

### The editor refuses to save a chain that breaks four rules

The core passes these mistakes during its config check and fails only at
start-up, so the editor catches them before saving:

- At least two positions. One hop is not a chain. A chain left with fewer
  than two positions is not built until you fix it.
- No empty, duplicate or self-referencing positions.
- A nested chain only at position 1. A chain can start with another chain but
  cannot hold one in the middle.
- References only upwards. A chain points only at a chain listed above it.
  This order rules out loops.

Deleting a server or subscription removes its positions from every chain, and
the app reports how many positions dropped out: the route does not get shorter
unnoticed. A subscription refresh leaves positions alone.

### The Diagnostics tab shows which hop breaks the chain

The **Diagnostics** tab on the chain's node screen measures each hop as part
of the route so far and shows the hop's own cost. The Probe by position button
starts the measurement; Probe again repeats it.

```
  hop 1   67 ms
  hop 2   91 ms  (+24)
  hop 3   96 ms  (+5)
```

The number in brackets is the difference from the previous hop: a hop cannot
be measured apart from the path that leads to it. If a hop does not answer,
the core's error text appears next to it, and the hops behind it show
`not reached`. You see where the route breaks at once, without trial and
error.

The measurement needs the VPN on: the per-hop measuring points exist only in a
running core.

### A chain needs a recent core and compatible hops

- Core version. Chains build on the sing-box-lx core
  `v1.14.0-lx.27-rc.5` and newer; as of October 2026, L×Box builds ship with
  `v1.14.3-lx.15`. On an older core a chain does not build.
- MASQUE after a TCP hop needs `vhttp: auto`. With a fixed `h3`, a MASQUE hop
  behind a TCP hop sends QUIC datagrams with no handshake budget and runs into
  a timeout. `Auto (h3 → h2)` gives HTTP/3 3 seconds, then switches to HTTP/2
  over TCP.
- WireGuard behind a TCP hop needs a server that proxies UDP. WireGuard works
  only over UDP and has no fallback transport. You cannot spot the bad case in
  advance: the connection looks successful, and the server either forwards the
  datagrams or drops them without a word.

---

## IPv6 in the tunnel is off; turn it on only if your network supports it

The **Enable IPv6** setting gives the tunnel an IPv6 address. It is off by
default, and the resolve strategies are set to `ipv4_only`. On a network where
global IPv6 half-works, the device gets an address, but connections over it
hang: sites with an IPv6 address stop opening while the VPN is on. If you are
not sure IPv6 works on your network, leave the switch off.

IPv6 settings sit on several screens:

| Setting | Where | Default | What it does |
|---|---|---|---|
| **Enable IPv6** | VPN Settings → Core → TUN | Off | Gives the tunnel an IPv6 address. The main switch. |
| **IPv6 address** | VPN Settings → Core → TUN | `fdfe:dcba:9876::1/126` | The tunnel's IPv6 address. Applies only when Enable IPv6 is on. |
| **Strategy** | DNS Settings | `ipv4_only` | Which addresses to prefer in DNS resolution: `prefer_ipv4`, `prefer_ipv6`, `ipv4_only`, `ipv6_only`. |
| **Resolve strategy** | Routing → Rules → Traffic Processing → Params | `ipv4_only` | Which addresses to prefer when routing rules resolve domains. You cannot turn the preset off, but you can change the value in it. |
| **Force IPv4** | Routing → Presets, inside presets that resolve domains | On | Resolves the preset's domains to IPv4 only. |
| **Force IPv4 (drop AAAA)** | Your own rule's editor → Params → DNS section | Off | Answers IPv6 queries for the rule's domains with an empty response, and traffic goes over IPv4. |

Enable IPv6 keeps the strategies in sync by itself. Turn it on, and Strategy
and Resolve strategy switch to `prefer_ipv4`: IPv6 is in use, IPv4 takes
priority. Turn it off, and both return to `ipv4_only`. VPN Settings has no
Resolve strategy: you change it by hand in the Traffic Processing preset (which
cannot be turned off), and Strategy in DNS Settings. `prefer_ipv6` suits a
network with full IPv6.

A user rule has its own resolve strategy: Action & Resolve (the gear next to
Action) → Resolve first → Strategy. By default the rule inherits Strategy
from DNS Settings.

Order of enabling:

1. Check the network: resources reachable only over IPv6 open without the VPN.
2. Turn on VPN Settings → Core → TUN → **Enable IPv6**.
3. Restart the VPN: Stop, then Start; re-saving is not enough. Android flushes
   its system DNS cache only when the tunnel restarts; otherwise old addresses
   keep coming back for a while.
4. If sites start hanging, open Routing → Presets: enabled presets with
   the **Force IPv4** checkbox keep their domains on IPv4. If you need IPv6 for
   those domains, clear the checkbox; if not, leave it.

---

## Common problems: symptom, cause, action

**The app is in the Allow-list, but the VPN does not affect it.**
The Allow-list only admits traffic into L×Box; Default traffic in Routing →
Directions decides where it goes. With Default traffic = Direct, admitted apps
go out directly. Set **Default traffic** = VPN.

**The VPN started working after L×Box was added to the Allow-list.**
That was not the cause: Default traffic = VPN was, if it changed at the same
time. L×Box's own service traffic and DNS bypass the tunnel; L×Box does not
need the tunnel.

**Only the browser needs the VPN; everything else goes direct.**
Tunnel apps → Allow-list with only the browser in the list; Default traffic =
VPN. L×Box does not see the other apps.

**Everything needs the VPN, but without ads and with `.ru` direct.**
Tunnel apps → Off; Default traffic = VPN; two rules in Rules: ads → Block,
`.ru` → Direct.

**After a node switch, a download or call keeps going through the old server.**
Open connections stay on the server where they started until they close. To
make a node switch break them, turn on **Interrupt connections on switch**.
There are three switches: in VPN Settings → System for your own taps, in a
direction for any switch, in an auto group for automatic switches. Which one to
turn on is in the
[Directions](#interrupt-connections-on-switch--three-switches-for-three-events)
section.

**DNS queries are visible to the ISP or bypass the VPN.**
By default, app DNS queries do not go through the ISP's resolver: DNS Final =
the `dns_shield` group, six encrypted resolvers, part of them through the VPN.
To hide domains from everyone on the path, set **DNS Final** to an encrypted
server (`google_doh`, `cloudflare_dot`) or to a server with Outbound = the VPN
direction. For internal resolution, Default Domain Resolver must not be
`local_dns_resolver`.

**Servers of a new subscription or folder get no traffic.**
A subscription and a folder are sources of servers; they carry no traffic by
themselves (see [What is what](#what-is-what)). Check that their servers land
in the active direction (the direction's filter is empty or matches their
names) and that **Default traffic** = VPN.

**Sites stopped opening after IPv6 was turned on, Russian ones more often.**
A network with broken IPv6 behaves this way: a domain resolves to an IPv6
address, and the connection hangs. Turn off **Enable IPv6** (VPN Settings →
Core → TUN) and restart the VPN. Details are in the IPv6 section above.

**Settings changed, but behaviour did not.**
Changes reach the running tunnel after the config is rebuilt and the VPN
restarts; a banner on the home screen reminds you. The banner checks against
the running core: if there is nothing to apply, it does not appear. To make
the VPN restart by itself, turn on App Settings → General → **Auto-restart VPN
on settings change**.

**The subscription holds a single "App not supported" node instead of servers.**
The provider's panel requires a device identifier (HWID) and returns a
placeholder until it gets one. Turn on **Send HWID**, in App Settings →
Subscriptions or in the subscription's settings, Fetch identity section, and
refresh the subscription.

**After a direction switch, pings disappeared or turned grey with `~`.**
Each direction has its own measurements: directions have different test
addresses and timeouts. A grey number with `~` is the latest measurement from
another direction, shown for reference. Run a mass ping in the current
direction, and the numbers become its own.

**The subscription's "Auto | Best server" entry shows as a single row.**
This is an auto node: one entry with a pool of servers inside and automatic
selection. The row shows the mode and contents, for example `🔀 [15/7]`. You
do not need to expand it into separate servers: the core keeps to the live
ones by itself.

**After an app crash, the VPN does not start.**
After a core crash, the app resets the core's service caches on the next start:
a corrupted cache often causes a crash right at start-up. Configs,
subscriptions and settings stay untouched. If that does not help, the crash
report is in Debug → **Crashes**; you can send it to the developer.

---

## If something goes wrong — where to look

Diagnostic tools, from simple to detailed:

| Tool | Where | What it shows |
|---|---|---|
| Ping and the ⚠ icon | Home screen | ERR: the node does not answer. ⚠: other entries go out through the node and fail with it; tap to see which ones. |
| Stats | Statistics, while the VPN is on | Traffic per direction: where the bytes go. |
| Conns | Statistics | Live connections: app, host, rule, chain of exits. Connections with traffic in one direction only are highlighted: replies get lost on the way, for example when the carrier cuts the protocol. |
| Profiler | Statistics | A real-time recording of connections and DNS resolves, with filters by app, domain and IP: which domain fails to resolve, which direction a request took, where an app connects. For DNS groups you see which members answered and which stayed silent. |
| Log | Debug (side menu) | The app and core log. **Verbose (TRACE/DEBUG)** in App Settings → Diagnostics turns on the detailed log; the Log tab links there. |
| Crashes, OOM, Profiling | Debug | Core crash reports, core memory snapshots on low memory, pprof profiles for the developer. |

If the phone gets hot or uses too much memory, open VPN Settings → System →
Optimization → **Memory limit**: in Auto mode the limit follows the device's
RAM. The System → WireGuard connections section puts idle WireGuard tunnels
to sleep.

---

## Recipes

### Share the VPN with other devices over Wi-Fi

The phone with L×Box shares its tunnel as a proxy: a laptop, a TV or a second
phone on the same network reach the internet through it. These devices need
no client of their own — a proxy in their Wi-Fi settings is enough.

On the phone with L×Box:

1. In VPN Settings → Mode pick **VPN + Proxy** or **Proxy**. VPN + Proxy keeps
   the tunnel as usual and opens a proxy port. Proxy runs without a tunnel and
   leaves the Android VPN slot free: the option for a phone that already runs
   another VPN.
2. In the **Local proxy** block set the options from the table:

| Option | Value | What it gives |
|---|---|---|
| Local proxy protocol | Mixed (default) | HTTP and SOCKS5 on one port: fits both Android devices and Wi-Fi proxy settings that understand only HTTP. |
| Listen address | `0.0.0.0` | The proxy is reachable from the whole local network. The default `127.0.0.1` opens the proxy to this phone only, and other devices cannot connect to it. |
| Listen port | `2080` (default) | 1024–65535 allowed. |
| Require auth | on | With any Listen address other than `127.x` it is on and cannot be turned off. The clients need the username and password from the Proxy username and Proxy password fields. |

3. Connect the VPN and find the phone's local IP: Android → Settings →
   Wi-Fi → current network → IP address. It usually looks like `192.168.x.y`.

On the client device open the Wi-Fi network → modify → Proxy: manual. The
address is the phone's IP, the port is `2080` or yours, the username and
password come from Proxy username and Proxy password. On a computer set the
same in the system proxy settings or in the browser.

Limitations of this approach:

- The phone and the client must share a network: one router, or a hotspot on
  this same phone. Over mobile internet from outside the `192.168.x.y` address
  is unreachable.
- The proxy does not receive all of the client's traffic. The system Wi-Fi
  proxy is honoured by browsers and by apps that read it; games, messengers and
  everything else that bypasses the system proxy go out directly. This does not
  replace a VPN on the client itself.
- A hotspot does not tunnel traffic by itself: its clients go out past the VPN
  until they set the proxy by hand.
- Do not turn on the LAN proxy on someone else's or a public network: every
  device on that network sees the open port. For the same reason the password
  is mandatory with the `0.0.0.0` address.

Routing rules apply to proxy traffic. The INBOUND condition in the rule editor
separates traffic from the tunnel and traffic from the proxy: proxy guests can
go to a separate direction.

### ByeDPI and other local proxies connect as an ordinary server

ByeDPI (ByeByeDPI) is a separate app: it bypasses DPI restrictions on the
phone itself, without a server, and hands the result over through a local
SOCKS5 proxy. L×Box adds this proxy as an ordinary server, and from then on it
follows the common rules: it enters directions, serves as a detour, takes part
in automatic selection.

The pairing solves two tasks. Sites that ByeDPI alone gets through open
without a foreign server — faster and without spending VPS traffic. And in
front of your own VPN ByeDPI works as an extra masking layer.

Setup (verified):

1. In ByeDPI turn on proxy mode. It opens `127.0.0.1:1080`; the port may
   differ — ByeDPI's settings show it. A password in ByeDPI is advisable.
2. In L×Box open Routing → **Tunnel apps**, pick Deny-list mode and add
   ByeDPI. Without this step ByeDPI's own traffic returns into the tunnel and
   loops.
3. Add ByeDPI as a server: Servers → paste the link
   `socks5://127.0.0.1:1080#ByeByeDpi` into the input field → **+**. With a
   password the link reads `socks5://логин:пароль@127.0.0.1:1080#ByeByeDpi`.
   To add the server by hand, use Servers → ⋮ → Add server… → SOCKS5 tab.
4. From here the node works like any server, in three scenarios:
   - a separate direction: a filter on this node and a rule that sends the
     chosen domains (YouTube) into it, while the rest of the traffic goes
     through the foreign server;
   - detour: ByeDPI becomes the detour of the VPN server, and traffic passes
     through ByeDPI first, then enters the tunnel;
   - automatic selection: the node joins the pool alongside ordinary ones.

Limitations:

- A `127.0.0.1` node exists only on this phone. In a backup moved to another
  device it is useless, and here it fails if ByeDPI is off or has changed its
  port. A ping of such a node with ByeDPI stopped shows ERR.
- ByeDPI and ByeByeDPI are different builds, and the forum reported different
  behaviour: for one group of users the pairing worked only with the original
  ByeDPI, for another both builds worked the same. If traffic does not flow,
  try the other build before looking for the cause in L×Box.
- Any local proxy on the phone connects the same way — another service's
  SOCKS5 or HTTP client: a `socks://` or `socks5://` link to its address plus
  Deny-list, so the traffic does not loop.

### Double hop: the last server does not see your IP

The scheme `you → server A → server B → internet` serves when B must not be
reached from your IP. The typical case: Proton, Mullvad or your own VPS as A,
WARP as B — Cloudflare must see A's exit IP, not yours.

The detour goes on B itself. Every server in the pool is an exit in its own
right: a chain or a direction adds a route to it but does not remove the direct
path. A chain `[A, B]` leaves B a standalone server, and a direction with an
empty filter offers it on its own: manual selection, the auto twin's test and
the ping in the server list reach B directly. A detour changes B itself, and
the config keeps no direct path to it.

1. Detour on B: Servers → tap B → Settings tab → **Detour server** → A →
   Save.
2. Only B in the direction: Routing → Directions → VPN ① (`vpn-1`) →
   **Node filter (regex)** — a pattern that matches B's name and nothing else:
   `WARP` (see [Regular expressions](#regular-expressions-regex)). Turn
   Include auto (urltest) off: one server leaves nothing to choose from.
   Without the filter A lands in the direction too. That is not a leak, but
   traffic may leave through A instead of B.
3. Default traffic = VPN ①. DNS servers with Outbound `vpn-1` take the same
   route.
4. Check: with the VPN on, open **Statistics** → any connection; the Detour
   line lists both A and B.

If a chain `[A, B]` already exists, delete it: it adds nothing to the detour,
and B stays in sight as a standalone server.

---

## Get WARP adds a server without a subscription

The **Get WARP** wizard registers a free Cloudflare WARP account and adds it
as a server. The phone generates the private key, and the key never leaves it.
Where: Servers → ⋮ → Get WARP. Two transports are available: WireGuard and
MASQUE (Cloudflare QUIC/CONNECT-IP). MASQUE gets through more often on networks
that cut plain WireGuard.

If the standard WARP address is unreachable directly on your network or loses
packets, set the endpoint by hand or search for one:

- for WireGuard — your own `IP:port` endpoint in the wizard's Advanced;
- for MASQUE — the **Endpoint IP** and Port fields in the MASQUE block;
- the Make experiment button creates the WARP GENERATOR folder with WARP
  variants (WireGuard, AWG, MASQUE) across Cloudflare's address ranges. The
  button does not test them: start the test with the speedometer icon in that
  folder. The variants that answer are working endpoints on your network.

---

## The server list filters, labels and copies servers as links

The server list on the home screen filters by name, subscription, protocol and
transport: above it sit a text field for a pattern and chips. The **`!`**
toggle to the left of the text field inverts the filter, and the list shows
everything that did not match; each chip group has the same toggle. Filter
settings are kept per direction while the app is running. Pattern syntax is in
[Regular expressions](#regular-expressions-regex).

The app fills in the emoji label in a server's tag on adding, by country or
name. The emoji picker button in **Node Settings** changes it by hand.

The **Copy URI** item in the server menu (long press) copies the node's link to
the clipboard. If the link carries a private key — an SSH node with the key in
the link, any WireGuard or AmneziaWG, MASQUE — L×Box first shows the "Link
contains a private key" dialog. Whoever receives the link can use the key, so
Copy anyway is for moving the node to your own second device, not for sharing.
Cancel and a tap outside the dialog leave the clipboard untouched. The key
stays in the link: the node is stored in this same form, and without the key it
would not survive a reload.

Latency measurements are stored per direction. Each direction has its own test
URL and timeout, so "180 ms" from different tests are different quantities.
Switching directions does not wipe the other results. If a node has no
measurement in the current direction yet, the row shows the latest measurement
from another direction — dimmed and marked `~`: the number exists, but a
different test produced it.

---

## Regular expressions (regex)

A regular expression (regex) is a pattern for searching text. L×Box takes a
regex in four places, and the syntax is the same everywhere:

| Where | What it filters |
|---|---|
| Node filter (regex) in the direction editor | which servers enter the direction |
| The search field above the server list | what the list shows |
| A folder auto node's membership rule: Include (regex) and Exclude (regex) | which servers enter the pool |
| The `matches` condition on a subscription's Filters tab | which nodes the rule applies to |

Plain text is already a working pattern: `Germany` finds every server with
that word in its name. Special characters serve when a plain match falls short.

### The `!` toggle negates the whole pattern

"Everything except this" is clumsy to write in the pattern itself, so negation
lives in the **`!`** toggle to the left of the input field. The toggle inverts
the result: the list or the direction gets everything that did not match the
pattern. The chip filters by subscription, protocol and transport carry the
same toggles, and each group inverts on its own.

The pattern `🇷🇺` with `!` on gives a direction with "everything except Russian
servers"; the same pattern with `!` off gives "Russian only".

On a subscription's Filters tab the **Not** checkbox on a condition plays the
toggle's role.

### Patterns use JavaScript syntax

The syntax is standard JavaScript- and Perl-style regex on the Dart RegExp
engine. The essentials:

| You write | It means | Example |
|---|---|---|
| `\|` | OR | `🇩🇪\|🇳🇱` — German or Dutch |
| `^` | start of the name | `^Premium` — the name starts with "Premium" |
| `$` | end of the name | `2$` — the name ends with "2" |
| `.` | any character | `A.1` — "A", anything, "1" |
| `.*` | any text, including none | `DE.*Fast` — "DE", then "Fast" somewhere |
| `\d` | any digit | `\d\d` — two digits in a row |
| `[abc]` | one of the listed characters | `[123]` — "1", "2" or "3" |
| `( )` | a group; needed for `$1` substitutions in subscription rules | `^(\w+)-` |
| `\.` | a dot as a literal character | `\.ru` — literally ".ru" |

Test a pattern on [regex101.com](https://regex101.com/) with the ECMAScript
(JavaScript) flavour.

> 📖 [Dart RegExp documentation](https://api.dart.dev/stable/dart-core/RegExp-class.html) —
> the full syntax description; the engine matches
> [ECMAScript regular expressions](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Regular_expressions).

### Examples by task

| Task | Pattern | `!` toggle |
|---|---|---|
| German and Dutch only | `🇩🇪\|🇳🇱` | off |
| Everything except trials and test nodes | `test\|trial\|пробн` | on |
| Only servers of your folder with the `mullvad-` prefix | `^mullvad-` | off |
| Servers numbered 1–3 at the end of the name | `[123]$` | off |
| Everything except servers with a lightning bolt in the name | `⚡` | on |
| Turn off several countries at once by name | `\b(?:Russia\|China\|Hong Kong\|Singapore)\b` | on |
| Finnish nodes except the `#2`, `#3`… duplicates | `🇫🇮(?!.*#)` | off |
| Premium nodes only, but not the trial ones | `^(?=.*Premium)(?!.*trial)` | off |

The last two examples use lookahead from the next section; for most tasks the
`!` toggle is enough.

### Lookahead and lookbehind negate part of a condition

The `!` toggle flips the whole result. It does not fit when only part of a
condition needs negating: in the task "German except trials" one condition is
positive ("has DE"), the other negative ("no trial"), and turning `!` on would
flip both.

Lookahead and lookbehind express such conditions. A lookaround checks what
stands next to a position and does not capture the text itself:

| Construct | It means | Example |
|---|---|---|
| `(?!…)` | what follows is not this | `^(?!.*trial)` — "trial" appears nowhere |
| `(?=…)` | what follows is this | `^(?=.*Premium)` — "Premium" appears somewhere |
| `(?<!…)` | what precedes is not this | `(?<!trial )DE` — "DE", but not after "trial " |
| `[^…]` | any character except the listed ones | `[^0-9]$` — the name does not end with a digit |

"German except trials" reads `^(?!.*trial).*DE`. The pattern first checks that
"trial" appears nowhere in the name, then looks for "DE". The `!` toggle stays
off: the negation already sits inside the pattern.

Conditions combine: `^(?=.*Premium)(?!.*trial)` means "has Premium and has no
trial". The engine does not support atomic groups `(?>…)` or possessive
quantifiers `X++` and rejects such a pattern.

The general form is "what we look for, and what must not follow":

```
(condition)(?!.*(forbidden))
```

Finnish nodes without the `🇫🇮 Finland #2`, `#3` duplicates are written like
this:

```
🇫🇮(?!.*#)
```

Read the pattern as: the 🇫🇮 flag, and no hash sign later in the name. The `!`
toggle is off — the negation already sits inside the pattern.

A frequent mistake is a missing `.*` inside the parentheses. The pattern
`🇫🇮(?!2)` takes all Finnish nodes, `#2` included: `(?!2)` checks for a 2 right
after the flag (`🇫🇮2`), while the name has " Finland #" in between. No node has
that combination, so the condition holds for all of them.

| Pattern | Result |
|---|---|
| `🇫🇮(?!2)` | all Finnish: looks for `2` right after the flag |
| `🇫🇮(?!.*#)` | Finnish without a number: `#2`, `#3`, any |
| `🇫🇮(?!.*#2)` | Finnish except `#2` |

The same rule holds for positive lookahead: `(?=Premium)` requires Premium
right after, `(?=.*Premium)` — somewhere later in the name.

> ⚠️ Emoji in square brackets cut off extra servers. The pattern
> `^(?![✨⭐🏁🏳️🏴])(?:.*?\()` removes 🇩🇪, 🇫🇷, 🌍 and other flags along with the
> listed ones. The engine parses the pattern in 16-bit chunks, an emoji takes
> two such chunks, and the class `[…]` falls apart into halves; the half shared
> by all flags matches on its own. List emoji with `|`:
> `^(?!(?:✨|⭐|🏁|🏳️|🏴))(?:.*?\()`; a single emoji needs no brackets.

### The filter ignores case and matches anywhere in the name

- The filter ignores case in three places out of four: `warp`, `WARP` and
  `Warp` match the same. The auto node's membership rule is case-sensitive. On
  a subscription's Filters tab the **Case-sensitive** checkbox on a condition
  turns case matching on. The Dart engine does not support the `(?i)` prefix
  at the start of a pattern, and the prefix breaks the pattern.
- The filter matches anywhere in the name: `DE` finds both "DE-1" and
  "Nord-DE". `^` and `$` anchor the start and the end.
- An empty field means no filter: all servers enter the direction.
- The field flags a broken pattern with the message "Invalid regex". The config
  build ignores such a direction filter, and the direction gets all servers,
  not zero.
- If the filter finds no servers, the app shows the warning "Direction "…"
  matched no nodes": a direction without servers cannot carry traffic.
- The filter does not hide auto nodes and service rows. Auto-selection nodes
  (`🔀`/`🎯`), Block and similar service
  rows stay in the list under any pattern: they are switching points. If
  `Europe | Auto` and Block remain in the list after the filter "🇫🇮 only", the
  pattern does not apply to them.

The direction editor shows a preview under the field before saving:
`matched: 12 / 37 nodes` — how many servers the pattern caught; with `!` on,
the line starts with `excluded →`. The auto node's membership rule has its own
preview, `12 of 37 servers`; Exclude (regex) applies after Include (regex), and
negation there comes from the Exclude field, not the `!` toggle. The preview
"No node snapshot (connect to preview)" means the server list has not loaded
yet: connect to see the numbers.

---

## Quick connect: the VPN turns on without opening the app

The L×Box tile in the shade (Quick Settings) turns the VPN on and off with the
current configuration. Add the tile to the quick settings panel: shade → edit
tiles (pencil). On the first tap the tile opens the app so that Android can
request the VPN permission.

The app icon shortcut does the same: a long press on the icon shows
**Connect** or **Disconnect**, depending on the VPN state.

While connected, the notification carries **Stop** and **Reconnect** buttons:
reconnect straight from the shade.

---

## Automation: the VPN turns on by events

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

---

## App language

The **Language** setting sets the interface language. Where: App Settings →
Appearance → Language.

| Option | What it does |
|---|---|
| System default (default) | The system language; English if the system language is not supported. |
| English, Русский, 中文（简体） | The chosen language regardless of the system. |

The language switches at once, without restarting the app or the VPN. System
surfaces are translated too: the notification with Stop and Reconnect buttons,
the Quick Settings tile, the shortcuts. Logs, Debug API and automation events
stay in English under any choice.

---

## Workspaces — named sets of settings

A workspace is a saved copy of everything the app knows: subscriptions with
their node cache, directions, chains, rules, DNS, Tunnel apps, the operating
mode, app settings. "Home" and "Work" sets switch from the home screen: the
button to the right of "L×Box" shows the current workspace and opens the
**Workspaces** menu. It offers three actions:

| Action | What it does |
|---|---|
| Load — tap a workspace | The app saves the current state under its own name, so nothing is lost. It copies the chosen workspace in its place, re-reads the settings and rebuilds the config. A running VPN stops for the switch and comes back up with the new config — a few seconds without a tunnel. |
| Save as… | Saves the current state under a new name or overwrites an existing one. From then on the auto-save on Load goes to that name. |
| ⋮ on a workspace row | Rename or Delete. The current workspace cannot be deleted: the auto-save goes into it. |

Until anything is saved, there is one workspace, Default, and nothing changes
on disk. A workspace holds the settings file, the subscription content cache
and the downloaded rule files; the core rebuilds its own cache after a load.
Workspaces stay on the device only. To move a workspace to another phone, load
it and make a Backup.

## Backup moves settings to another device

The **Backup & restore** screen saves the configuration to a JSON file and
restores it from a file: subscriptions, directions, chains, rules (Rules) and
app settings. Where: menu → App Settings → General → Backup & restore. Export
saves the configuration to a file; Import restores it and shows a preview
before applying. The screen serves to move settings to a new phone and to save
them before a reinstall.
