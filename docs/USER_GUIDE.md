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
  - [Replace with a group folds a subscription or folder into one group](#replace-with-a-group-folds-a-subscription-or-folder-into-one-group)
- [2. Directions sets the exits and the default path](#2-directions-sets-the-exits-and-the-default-path)
  - [Interrupt connections on switch — three switches for three events](#interrupt-connections-on-switch--three-switches-for-three-events)
- [3. Rules sets exceptions to the default](#3-rules-sets-exceptions-to-the-default)
  - [Presets — a catalog of ready-made rules to copy into Rules](#presets--a-catalog-of-ready-made-rules-to-copy-into-rules)
  - [A rule can assign a DNS server to its own domains](#a-rule-can-assign-a-dns-server-to-its-own-domains)
  - [Raw JSON and the View tab cover fields the form lacks](#raw-json-and-the-view-tab-cover-fields-the-form-lacks)
- [4. DNS decides which server resolves each name](#4-dns-decides-which-server-resolves-each-name)
  - [Group and Shield DNS combine several servers under one tag](#group-and-shield-dns-combine-several-servers-under-one-tag)
  - [DNS Rules assign a DNS server to a domain](#dns-rules-assign-a-dns-server-to-a-domain)
- [Detour sends a server to the internet through another server](#detour-sends-a-server-to-the-internet-through-another-server)
  - [Detour is set on a server, subscription or folder](#detour-is-set-on-a-server-subscription-or-folder)
  - [Detours form a chain but not a loop](#detours-form-a-chain-but-not-a-loop)
  - [A direction with Use as detour serves as a switchable intermediate server](#a-direction-with-use-as-detour-serves-as-a-switchable-intermediate-server)
  - [The whole detour chain runs inside one tunnel](#the-whole-detour-chain-runs-inside-one-tunnel)
  - [Statistics shows which servers a connection went through](#statistics-shows-which-servers-a-connection-went-through)
  - [A node with a ping error flags its dependents with ⚠](#a-node-with-a-ping-error-flags-its-dependents-with-)
  - [The Dependents tab shows who goes out through the node](#the-dependents-tab-shows-who-goes-out-through-the-node)
  - [The Diagnostics tab sends a test request through one node](#the-diagnostics-tab-sends-a-test-request-through-one-node)
- [Hop chains — a route you build yourself](#hop-chains--a-route-you-build-yourself)
  - [A chain builds a route; a detour adds an intermediate server in front of one server](#a-chain-builds-a-route-a-detour-adds-an-intermediate-server-in-front-of-one-server)
  - [Positions follow packet order](#positions-follow-packet-order)
  - [The editor refuses to save a chain that breaks four rules](#the-editor-refuses-to-save-a-chain-that-breaks-four-rules)
  - [The Diagnostics tab shows which hop breaks the chain](#the-diagnostics-tab-shows-which-hop-breaks-the-chain)
  - [A chain needs a recent core and compatible hops](#a-chain-needs-a-recent-core-and-compatible-hops)
- [IPv6 in the tunnel is off; turn it on only if your network supports it](#ipv6-in-the-tunnel-is-off-turn-it-on-only-if-your-network-supports-it)
- [VPN Settings configures the core and the tunnel, not servers and routes](#vpn-settings-configures-the-core-and-the-tunnel-not-servers-and-routes)
  - [System controls tunnel sleep and core memory](#system-controls-tunnel-sleep-and-core-memory)
  - [Core passes settings to the sing-box core](#core-passes-settings-to-the-sing-box-core)
  - [Mode selects the operating mode and tunnel options](#mode-selects-the-operating-mode-and-tunnel-options)
- [App Settings controls the app's behavior, not the traffic path](#app-settings-controls-the-apps-behavior-not-the-traffic-path)
  - [General controls VPN startup and update checks](#general-controls-vpn-startup-and-update-checks)
  - [Appearance changes the theme, layout and language](#appearance-changes-the-theme-layout-and-language)
  - [Subscriptions sets when subscriptions download and which client fetches them](#subscriptions-sets-when-subscriptions-download-and-which-client-fetches-them)
  - [Diagnostics shows Android permissions and turns on debugging](#diagnostics-shows-android-permissions-and-turns-on-debugging)
  - [Automation opens the VPN to commands from other apps](#automation-opens-the-vpn-to-commands-from-other-apps)
- [Common problems: symptom, cause, action](#common-problems-symptom-cause-action)
- [If something goes wrong — where to look](#if-something-goes-wrong--where-to-look)
- [Speed Test measures speed to a test server over the current route](#speed-test-measures-speed-to-a-test-server-over-the-current-route)
- [Config Editor edits the core config until the next rebuild](#config-editor-edits-the-core-config-until-the-next-rebuild)
  - [Lock config pins a manual config](#lock-config-pins-a-manual-config)
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
  - [Export saves the chosen categories to a file](#export-saves-the-chosen-categories-to-a-file)
  - [Import shows the file's contents before applying](#import-shows-the-files-contents-before-applying)
  - [Set up a TV from your phone](#set-up-a-tv-from-your-phone)
  - [Transfer to desktop moves the shared part of settings to the desktop launcher](#transfer-to-desktop-moves-the-shared-part-of-settings-to-the-desktop-launcher)

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

You configure the proxy on the same tab, with four options:

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
holds directions, rules, DNS and Tunnel apps.

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
5. **DNS** (Routing → DNS). The default is the Shield DNS group, which survives
   the failure of any single resolver. Change anything here only if you need
   strictly encrypted DNS or your own resolvers.
6. Detour, optional. Set an exit through a chain of servers in the settings of
   a server, subscription or folder (see the detour section).
7. **Start** on the home screen. The VPN connects, and the button changes to
   Stop.

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

Servers from subscriptions, folders and standalone servers carry no traffic
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
Notifications section at the bottom of the Diagnostics tab on the node's own
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

The speedometer icon in the bar above the node list pings the subscription's
nodes without starting the VPN. With the VPN running, a dialog appears with
**Stop VPN** and Cancel buttons: on top of a live tunnel the measurements
would be wrong.

The **Settings** tab holds Tag prefix, detour, Update interval, Replace
with a group (section
[Replace with a group](#replace-with-a-group-folds-a-subscription-or-folder-into-one-group))
and the two settings below. The On update setting decides what to do when an
update brings a new set of nodes:

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

### Replace with a group folds a subscription or folder into one group

The **Replace with a group** setting turns all servers of a subscription or
folder into one group: directions and rules see it as one entry instead of
each server. Where: Servers → subscription or folder → Settings → Replace
with a group; a standalone server has no such setting. Off by default: each
server of the source enters the common pool on its own.

Folding fits when the source is one choice, not a set of servers: a
provider's subscription with 200 servers has to sit in a direction as one
line with its own auto-selection, or you switch between two providers with
one choice in the direction.

| Option | What it does | Default |
|---|---|---|
| Replace with a group | Turns folding on. | Off |
| Group name | The group's name; directions show it under this name. | Subscription or folder name |
| Manual / Auto / Both | Manual — you pick the server in the group. Auto — the group picks a server by latency. Both — you pick, and the first option `<name>-auto` picks by latency. | Both |
| Test URL, Interval, Tolerance (ms), Idle timeout | Latency test parameters; visible in Auto and Both modes. Tolerance (ms) is editable in the Fastest auto-select mode, inactive in Load balance and hidden in Hold until failure. | `https://cp.cloudflare.com/generate_204`, `15m`, `50`, `30m` |
| Mode | Auto-selection method: Fastest, Load balance or Hold until failure — as in a direction's auto twin. | Hold until failure |
| Pool size, Pool tolerance (ms), Sticky session by | Load balance mode parameters. | `3`, `0`, `process` and `domain` |
| Interrupt connections on switch | Visible in Auto and Both modes. Drops connections when the auto group switches server. Picking a server in the group by hand always drops connections. | Off |

Section [2. Directions](#2-directions-sets-the-exits-and-the-default-path)
describes the auto-selection modes, and section
[Interrupt connections on switch](#interrupt-connections-on-switch--three-switches-for-three-events)
describes the Interrupt connections on switch box. The group's
auto-selection leaves out the provider's auto nodes from the same
subscription; manual selection lists them.

The group name must not match a name already taken. The editor warns but
still lets you save:

| Warning | What happens at build |
|---|---|
| `A server already has this name — it will get a numeric suffix.` | The server with the same name gets a numeric suffix; the group keeps the name. |
| `A direction already has this name.` | The group does not build: the source enters the pool unfolded. |
| `Another replace group already has this name.` | The name goes to the group higher in the list; the other one enters the pool unfolded. |

The editor warns about a clash with a direction name; at build time the app
also checks other reserved tags. If the group does not build, the app moves
the rules that pointed to it to the default exit or deletes them.

If the source has no working server left, the app creates no group: the core
rejects an empty group. Nothing from such a source reaches a direction.

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
included and the order of directions in the config.

### Interrupt connections on switch — three switches for three events

To move open connections to the new server as soon as the node changes, turn
on **Interrupt connections on switch**. Without this option, open connections
keep running through the old server until they close on their own: a download
finishes through the same exit, a messenger's long-lived socket stays where it
is. Usually that is what you want.

The option exists in three places, and each one answers its own event:

| Where | What it reacts to | How it works |
|---|---|---|
| VPN Settings → System → Interrupt connections on switch (off by default) | You tap a node on the home screen | The app closes the open connections of the switched direction. Nothing goes into the config; switches made by the core stay uncovered. |
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

### Presets — a catalog of ready-made rules to copy into Rules

The **Presets** tab is a catalog of ready-made rules: ads, BitTorrent,
Russian domains, Google push notifications and other common tasks. Where:
Routing → Presets. A preset in the catalog changes nothing: the Add to Rules
button copies it to the Rules tab, and that copy sets the routing.

After copying, the button in the catalog turns into an inactive **In Rules**
label with a check mark: each preset enters Rules once. The copy takes its
place in the rule list by preset order, not at the end. The app adds a
preset that needs a downloadable rule list (`.srs`) turned off and shows
`Added "…" — tap ☁ to download, then enable`. Turn the rule on with its
switch: the switch downloads the list and turns the rule on once it loads.

A fresh install has six presets in Rules, turned on: Traffic Processing, Ru
internet segment, BitTorrent, Tailscale networks, VoWiFi (carrier calling)
and Unknown traffic. The app does not add a deleted preset back; you can return it
from the catalog.

Catalog presets, in the order the tab shows them:

| Preset | What it does | On a fresh install |
|---|---|---|
| Traffic Processing | Traffic pre-processing: detects the protocol and domain from the first packets, intercepts apps' DNS queries and resolves destinations so that IP rules match. | In Rules, on |
| Block Ads | Rejects connections to ad domains by a downloadable 1 MB list; the list updates every 7 days. | No |
| Ru internet segment | Sends Russian domain zones (`.ru`, `.su`, `.рф` and others), domains of Russian services, Russian IP ranges and Russian apps by package name direct. The Yandex DNS server group `dns_ru` resolves the domains. | In Rules, direct |
| FakeIP | DNS answers at once with a substitute address from `198.18.0.0/15`, and the name resolves inside the tunnel. DNS answers arrive faster, and DNS queries do not reach the network ahead of the tunnel. Does not help against DPI. | No |
| Russia-only services | Routes services available only from Russia by a downloadable list. Direct by default; from abroad, change the exit to a Russian direction. | No |
| BitTorrent | Sends traffic detected as BitTorrent to the chosen exit. | In Rules, direct |
| Tailscale networks | Sends each Tailscale network's traffic through its Tailscale node; that node's DNS resolves the network's names. Works when the servers include a Tailscale node. | In Rules |
| Private IPs | Routes local network addresses: router, NAS, printer. Direct gives access to your own network; a direction gives access to a remote network over the VPN. | No |
| Unknown traffic | Sends tunnel traffic that belongs to no installed app (system background processes) out directly, past the VPN, so a process bound to the tunnel cannot learn the server address. The Reject option drops it instead. | Yes |
| VoWiFi (carrier calling) | Lets carrier Wi-Fi calls out past the VPN: the domains `pub.3gppnetwork.org` and UDP ports 500 and 4500. Through the VPN, voice gets delay, and the carrier sees the registration come from a foreign address. | In Rules, direct |
| Google push (FCM) | Lets only Google push notifications out past the VPN: ports 5228–5230 and the FCM hosts. Notifications arrive with the screen off, and the Google Play region does not change. | No |

> ⚠️ With DNS through the tunnel, Google push (FCM) needs a matching direct
> DNS rule for the same hosts in Routing → DNS. Without it the hosts resolve
> to a foreign region, and notifications do not arrive.

#### A preset's parameters change in its copy on the Rules tab

The **Params** tab of a preset copy shows the preset's parameters. Where:
Routing → Rules → tap the preset → Params. At the top sits the Based on
preset banner with the preset's name and description. The Name field is
read-only: the name comes from the preset. Next to it is the copy's on/off
switch; on Traffic Processing the switch is inactive. A preset that adds a
DNS server or a DNS rule carries a DNS chip and the line
`This rule changes DNS settings`: its entries appear on the DNS tab.

The **Outbound** parameter sets the exit for matching traffic: direct, block
or a direction. Ru internet segment, Russia-only services, BitTorrent,
Private IPs, VoWiFi and Google push have it, with direct as the default. On
Unknown traffic the parameter label is lowercase — `outbound` — and the
default is reject. The same exit changes right in the preset's row on the
Rules tab, without opening the editor.

The other parameters:

| Preset | Parameter | Default | What it does |
|---|---|---|---|
| Traffic Processing | Packet sniffing | On | Detects the protocol and domain from packets. Turning it off disables protocol conditions (BitTorrent, TLS, QUIC), and without FakeIP domain conditions as well. |
| Traffic Processing | Sniff timeout | `300ms` | How long to wait for the domain in a packet: `100ms`, `300ms`, `500ms`, `1s`, `3s`. |
| Traffic Processing | Hijack DNS | On | Sends all DNS queries to the L×Box DNS engine. Turning it off disables FakeIP and all DNS rules: apps ask their own DNS directly. |
| Traffic Processing | Resolve destination IP | On | Resolves the domain to an IP before choosing a route, so that IP and GeoIP rules match. |
| Traffic Processing | Resolve strategy | `ipv4_only` | Which addresses to take in that resolution; for the link with IPv6, see [IPv6 in the tunnel](#ipv6-in-the-tunnel-is-off-turn-it-on-only-if-your-network-supports-it). |
| Ru internet segment | DNS | On | The preset's DNS group resolves the preset's domains; without it Force IPv4 does not work. |
| Ru internet segment | UDP server IP | `77.88.8.8 · Base` | The address of the Yandex UDP server. DoH and DoT stay on `77.88.8.88`. |
| Ru internet segment | GeoIP IP-range fallback | On | Also checks the IP against Russian ranges: catches connections where the domain is not detected. Downloads a 150 KB list. |
| Ru internet segment | Russian apps by package | On | Routes Russian apps (banks, marketplaces, Gosuslugi, Yandex, VK) by package name, whatever domains they open. Downloads a 4 KB list. |
| Ru internet segment, Russia-only services | Force IPv4 | On | Resolves the preset's domains to IPv4 only: on a network without working IPv6, connections do not hang. |
| FakeIP | DNS | On | Turns on substitute addresses; turning it off removes FakeIP without deleting the preset. |
| FakeIP | Block HTTPS records | On | Answers HTTPS and SVCB DNS records with an empty response, and apps fall back to plain A and AAAA. |
| Tailscale networks | DNS | On | The node's DNS resolves the Tailscale network's names. |
| VoWiFi | Match IKE ports (500/4500) | On | Catches calls by port as well: a modem can get the carrier gateway address without a DNS query. |
| Google push (FCM) | Limit to Google Play Services | Off | Limits the preset to the `com.google.android.gms` app. The app condition works only in VPN mode. |

Presets affect one another: FakeIP turned on with the DNS box ticked
automatically turns off Resolve destination IP in Traffic Processing, and turning FakeIP off
brings it back. FakeIP sits below Ru internet segment: Russian domains first
get addresses from Yandex DNS, not substitute ones, and the rules by Russian
IP ranges match. A copy from the catalog takes this order on its own.

#### Traffic Processing cannot be turned off, deleted or moved

The Traffic Processing preset stays first in the rule list: the rest of the
routing depends on its pre-processing. The switch in its row is inactive,
the row has no long-press menu, you cannot drag it, and the editor has no
delete button. Its parameters change as in other presets.

A preset missing from the installed app version opens with the message
Preset not found: the config build skips the rule. Delete it with the Delete
rule button or update the app to a version that has this preset.

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
  lists do not match DNS queries.

### Raw JSON and the View tab cover fields the form lacks

You can write a rule as a sing-box `route.rules` JSON fragment: choose Raw
JSON in Source. The JSON itself sets the action; the editor checks the syntax
as you type.

For a form-built rule, the **View** tab shows the finished sing-box fragment
that goes into the config.

---

## 4. DNS decides which server resolves each name

The **DNS** tab of the Routing screen sets how a site name becomes an IP. It
has its own server list and its own rules, separate from the routing rules.
Where: Routing → DNS, after the Rules tab.

The DNS server catalog includes Google, Cloudflare, OpenDNS, Quad9 and Yandex
over UDP, DoT and DoH. Each server has an IP or profile and a direction it
travels through — the **Outbound (detour)** field. To send DNS queries through
the tunnel so the resolver sees the server's IP rather than your ISP's,
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
> system DNS past the VPN, and your ISP sees them. Choose `dns_shield` or
> another server from the catalog.

### DNS Rules assign a DNS server to a domain

The **DNS Rules** list on the DNS tab sets which server resolves
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
| Another server | A standalone server or a folder member: a fixed intermediate server. |
| A direction | The server goes out through whichever server the direction selects at the moment; by default the direction picks by speed. This target is called a detour direction. |

### Detour is set on a server, subscription or folder

You pick a detour in the same **Detour server** window every time; you open it
from the settings of whatever you assign the detour to.

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
that serves as an intermediate link for another carries the ⚙ icon.

L×Box will not start a loop of detours. When it builds the config, the app
finds the cycle, the VPN does not start, and the **Routing loop — VPN not
started** window opens with the list of culprits. Tapping a culprit takes you
to its source: change or remove the detour there, and the loop breaks.

### A direction with Use as detour serves as a switchable intermediate server

The **Use as detour** checkbox in the direction editor lets you pick this
direction as a detour target. Any server can then go out through the
direction, and the direction's own selection decides which server inside it
carries the traffic: by default, the fastest one. The detour is no longer
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
list of affected nodes with the dependency path: you see who this link takes
down with it.

If DNS servers depend on the node, a banner appears as well. Domains of such a
DNS server stop resolving without an error message, and without the banner
this looks like the internet has gone.

### The Dependents tab shows who goes out through the node

The **Dependents** tab lists the servers and DNS servers that go out to the
internet through this node. Where: home screen → long press on the node →
View details → Dependents. The tab appears only if the node has dependents.

What the tab shows depends on the node's state:

| Node | Header | Who is listed |
|---|---|---|
| Working | `These route through this node:` | Servers and DNS servers whose detour points straight at this node. Row label: `Node — direct detour` or `DNS server — direct detour`. |
| Ping ERR in all directions | `These depend on dead node "<node>" and are not working:` | Everyone that stopped working with the node, including those that go out through an intermediate node or a direction: `Node — via "<node or direction>"`, `DNS server — via "<node or direction>"`. Tapping the ⚠ icon leads here too, see [A node with a ping error flags its dependents with ⚠](#a-node-with-a-ping-error-flags-its-dependents-with-). |

A node counts as not working only if it has measurements and all of them
fail in every direction; one successful measurement in any direction clears
the alarm. Through a direction, only those that go out through a direction
with this node currently selected count as affected. An auto direction (auto
twin `<direction>-auto`) is affected only if none of its members works.

DNS servers come first in the list. Tapping a server opens its owner — the
subscription, folder, standalone server, direction or chain — where you
change the detour. DNS server rows do not respond to taps: a DNS server's
exit changes in Routing → DNS → server → Params → Outbound (detour).

The tab sees only detour. A hop chain that contains this node does not
appear in the list: a chain position is not a detour. For a working node,
the list also leaves out those that go out through a direction with this
node.

### The Diagnostics tab sends a test request through one node

The **Diagnostics** tab sends an HTTP request to the chosen service through
this node and shows the raw response: the node's external IP and whatever
else the service sends. Where: on three node screens — Node Settings (tap a
standalone server or a folder member), the subscription node breakdown (tap
a node on the Nodes tab) and View details. The request goes through this
node even if the direction has a different one selected.

Pick the service in the **Endpoint** field; its address shows under the
field before the run: this service will see the node's exit IP.

| Endpoint | Address |
|---|---|
| Cloudflare trace (default) | `https://1.1.1.1/cdn-cgi/trace` — by IP, without DNS |
| Cloudflare trace (hostname) | `https://cloudflare.com/cdn-cgi/trace` — by name |
| IP & location | `https://api.ip2location.io/` |
| IP info | `https://ipinfo.io/json` |

The **Run** button starts the request; the app waits 10 seconds for a
response. The Response section shows the status code and time
(`200 · 143ms`), with the response body and a copy button below. An empty
body shows as `(empty response)`. The app cuts a body longer than 64 KiB and
labels it `Response was longer and got cut off.` The line
`Connected to <address> from inside the tunnel` under the response names
the address the core connected to from inside the tunnel, not the node's
exit IP. The request goes through the node like ordinary traffic; per the
core documentation, an idle WireGuard node wakes up on it.

The request path depends on the VPN:

| VPN | How the request goes | Label above the response |
|---|---|---|
| On | Through the node in the running core | `Through this node in the running core — not through your current route` |
| Off | Through the node in a temporary core session; available on Node Settings and in the subscription node breakdown | `Through this node in a temporary core session` |

Limits:

- In View details with the VPN off, the request does not go out: the screen
  knows the node only from the built config. Turn on the VPN or open the node
  from its subscription.
- An auto node has no connection of its own. With the VPN off, the tab shows
  `This is an auto-select node — it has no connection of its own. Open a
  member to diagnose it.` With the VPN on, the request goes through the auto
  group, and the response comes from the node the group picked.
- A Tailscale node without internet exit has no check on Node Settings or in
  the subscription node breakdown: the Network tab shows the network's
  devices. View details has the check.

If the node has notifications, the Diagnostics tab ends with a Notifications
section, and the tab name carries a dot: yellow, or red on an error. The
layer-by-layer probe of a hop chain is in
[The Diagnostics tab shows which hop breaks the chain](#the-diagnostics-tab-shows-which-hop-breaks-the-chain).

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

### A chain builds a route; a detour adds an intermediate server in front of one server

A chain and a detour solve the same problem from opposite ends:

| | Hop chain | Detour |
|---|---|---|
| What it is | A route, a source in its own right | A property of one server |
| What you set | This route goes through these servers in this order | This server goes out through that one |
| Where you edit it | In the chain editor | On the server, subscription or folder |
| When to choose it | You need the route itself | One server needs an intermediate server |
| Can traffic exit through the last server directly | Yes: chain positions stay standalone servers, and a direction with an empty filter offers them one by one | No: the detour belongs to the server, and no direct path to it remains |

The last row decides. If the last server must not see your IP (WARP behind
Proton), use a detour; see the recipe
[Double hop: the last server does not see your IP](#double-hop-the-last-server-does-not-see-your-ip).

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
unnoticed. A subscription update leaves positions alone.

### The Diagnostics tab shows which hop breaks the chain

The **Diagnostics** tab on the chain's node screen measures each hop as part
of the route so far and shows the hop's own cost. The Probe by position button
starts the measurement; Probe again repeats it.

```
  hop 1   67 ms
  hop 2   91 ms  (+24)
  hop 3   96 ms  (+5)
```

The number in brackets is the difference from the previous hop: you cannot
measure a hop apart from the path that leads to it. If a hop does not answer,
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
| **Strategy** | Routing → DNS | `ipv4_only` | Which addresses to prefer in DNS resolution: `prefer_ipv4`, `prefer_ipv6`, `ipv4_only`, `ipv6_only`. |
| **Resolve strategy** | Routing → Rules → Traffic Processing → Params | `ipv4_only` | Which addresses to prefer when routing rules resolve domains. You cannot turn the preset off, but you can change the value in it. |
| **Force IPv4** | Routing → Rules → preset → Params, in presets that resolve domains | On | Resolves the preset's domains to IPv4 only. |
| **Force IPv4 (drop AAAA)** | Your own rule's editor → Params → DNS section | Off | Answers IPv6 queries for the rule's domains with an empty response, and traffic goes over IPv4. |

Enable IPv6 keeps the strategies in sync by itself. Turn it on, and Strategy
and Resolve strategy switch to `prefer_ipv4`: IPv6 is in use, IPv4 takes
priority. Turn it off, and both return to `ipv4_only`. VPN Settings has no
Resolve strategy: you change it by hand in the Traffic Processing preset (which
cannot be turned off), and Strategy in Routing → DNS. `prefer_ipv6` suits a
network with full IPv6.

A user rule has its own resolve strategy: Action & Resolve (the gear next to
Action) → Resolve first → Strategy. By default the rule inherits Strategy
from Routing → DNS.

Order of enabling:

1. Check the network: resources reachable only over IPv6 open without the VPN.
2. Turn on VPN Settings → Core → TUN → **Enable IPv6**.
3. Restart the VPN: Stop, then Start; re-saving is not enough. Android flushes
   its system DNS cache only when the tunnel restarts; otherwise old addresses
   keep coming back for a while.
4. If sites start hanging, open Routing → Rules → preset → Params: enabled
   presets with the **Force IPv4** checkbox keep their domains on IPv4. If you
   need IPv6 for those domains, clear the checkbox; if not, leave it.

---

## VPN Settings configures the core and the tunnel, not servers and routes

The **VPN Settings** screen holds the settings of the VPN itself: how much
memory the core takes, when tunnels go to sleep, which parameters the virtual
interface comes up with and in which mode L×Box receives traffic. Servers,
directions and rules are not configured here: they live on the Servers and
Routing screens, DNS on the DNS tab of Routing. Where: main menu ≡ → VPN
Settings.

The screen has three tabs:

| Tab | What it configures |
|---|---|
| System | Dropping connections on a node switch, WireGuard tunnel sleep, core memory, tunnel pause while the screen is off |
| Core | sing-box core parameters: log, certificates, network, virtual interface, TLS fragmentation |
| Mode | Operating mode, local proxy, tunnel options |

The defaults work without changes; the sign that a group needs changing is
named under each group below. Changes take effect at different times:

| What you changed | When it applies |
|---|---|
| Interrupt connections on switch, Memory limit, Keep VPN on exit | Immediately |
| WireGuard connections, the Core tab, local proxy options, System HTTP proxy | After a VPN restart. These changes alter the config, and while the VPN runs the home screen shows the banner `Config changed — restart VPN to apply`. |
| Tunnel sleep mode, Allow VPN bypass | After a VPN restart that you make yourself: the home screen shows the same banner, but Auto-restart VPN on settings change does not apply these settings. |

You can leave the restart after config changes to the app: App Settings →
General → **Auto-restart VPN on settings change**. The app then restarts the
running VPN itself whenever the new config differs from the running one.

### System controls tunnel sleep and core memory

The **System** tab decides how much of the phone's resources the VPN spends
while traffic is low or absent. Where: VPN Settings → System. The top of the
tab holds the Interrupt connections on switch switch; what it does and how it
differs from the switches of the same name in a direction is described in
[Interrupt connections on switch](#interrupt-connections-on-switch--three-switches-for-three-events).
Below it are the WireGuard connections and Optimization groups.

#### WireGuard connections puts idle WireGuard tunnels to sleep

The **WireGuard connections** group puts WireGuard and AmneziaWG tunnels to
sleep when no traffic has passed through them for a while, and wakes them on
the first request. Sleep frees memory and saves battery; the cost is that the
first connection through a woken tunnel waits longer than usual. Where: VPN
Settings → System → WireGuard connections.

The group splits tunnels into two kinds. A tunnel on the active route is the
node selected in a direction, or a node in the pool of an auto twin: the group
that picks the direction's node by itself when the Include auto (urltest)
checkbox is on in the direction editor (see
[Directions](#2-directions-sets-the-exits-and-the-default-path)). The other
WireGuard nodes from subscriptions and folders are off the route: no traffic
goes to them until someone selects them.

| Option | What it does | Default |
|---|---|---|
| **Suspend idle tunnels** | Puts off-route tunnels to sleep after idle time. Options: Off, 30 seconds, 2 minutes, 5 minutes. | 30 seconds |
| **Suspend active-route tunnels** | Also puts tunnels on the active route to sleep after a long silence, for example at night. Options: Off, 5, 15, 30 minutes, 1 hour. The first connection after sleep takes one extra round trip to the server. | 5 minutes |
| **Lazy tunnel build** | Builds a tunnel on the first request to the node, not at VPN start. With dozens of WireGuard nodes it saves memory; the first connection to a node waits for the build. | On |
| **Built tunnels limit** | How many tunnels stay built at the same time: 0 (no limit), 3, 5, 8, 12. The core tears down the extra ones and builds them again on request. | 5 |

The three lower options work only while Suspend idle tunnels is on. At Off
their rows grey out, tunnels do not sleep, and the app does not pass lazy
build to the core: the core builds tunnels by its own rules. Built tunnels
limit also requires Lazy tunnel build to be on. After a change the app shows
`Applies on next connect.`

A direction's auto twin has its own node check. Where: direction editor →
Include auto (urltest). The group tests the pool's nodes once per Interval
(`15m` by default). Idle timeout (`30m` by default) is the time without
traffic through the group after which the tests stop. If Suspend active-route
tunnels is shorter than Idle timeout, a test wakes a sleeping tunnel for one
handshake. With the defaults this is what happens: pool tunnels fall asleep
after 5 minutes of silence and wake for every test while traffic goes through
the group.

| Situation | What to do |
|---|---|
| The first connection through a WireGuard node after a pause waits noticeably longer | Suspend active-route tunnels → Off: the selected node does not sleep |
| There are dozens of WireGuard nodes, and the core hits Memory limit | Built tunnels limit → 3 |
| Every new node answers with a delay when you switch | Lazy tunnel build → off: the app stops passing lazy build to the core, and the core builds tunnels by its own rules |
| Tunnels must not sleep at all | Suspend idle tunnels → Off |

#### Memory limit sets the core's memory ceiling

The **Memory limit** setting caps the memory the VPN core can take. A ceiling
set too low makes the core clean up memory all the time: the processor stays
busy, and the phone heats up. Where: VPN Settings → System → Optimization →
Memory limit. The default is Auto (recommended); a change applies to the
running core at once, without a restart.

Auto picks the ceiling by the phone's memory:

| Memory Android sees | Core ceiling |
|---|---|
| Less than 3.5 GiB | 200 MB |
| From 3.5 to 7 GiB | 384 MB |
| 7 GiB and more | 512 MB |

Android sees a "4 GB" phone as 3.7 GiB, and Auto sets 384 MB; an "8 GB" phone
as 7.5 GiB, and Auto sets 512 MB.

The other options: Off removes the ceiling, but the core keeps watching for
low memory in the system; 200, 384, 512 and 768 MB set the ceiling
explicitly. Raise the ceiling if the phone heats up under the VPN or core
memory snapshots appear in Debug → OOM; what else to check is described in
[If something goes wrong](#if-something-goes-wrong--where-to-look).

#### Tunnel sleep mode pauses the whole tunnel on a screen event

The **Tunnel sleep mode** setting decides when the core pauses the tunnel to
save battery. Unlike WireGuard connections, it acts on the whole tunnel and
fires not on idle time but when the screen turns off or Doze starts. Where:
VPN Settings → System → Optimization → Tunnel sleep mode. Applies from the
next VPN connection.

| Mode | When the tunnel is paused | Cost |
|---|---|---|
| **Never sleep (recommended)**, default | Never | Higher battery use; push notifications and long-lived connections do not break |
| **Lazy sleep** | Only in deep Doze: the screen has been off for a long time and the phone lies still. The pause ends when the phone leaves Doze. | While the phone is in Doze, the tunnel stands still |
| **Aggressive battery saving** | Every time the screen turns off. The pause ends when the screen turns on. | Push notifications, incoming calls and background sync do not arrive while the screen is off |

Aggressive battery saving suits a phone that lies with its screen off for
long periods when incoming messages are not needed. If messenger
notifications go missing, switch back to Never sleep (recommended).

### Core passes settings to the sing-box core

The **Core** tab shows the sing-box core parameters, grouped into four
sections: General, Network, TUN and TLS Fragmentation. Where: VPN Settings →
Core. The app saves the values when you leave the screen and rebuilds the
config on the home screen. What it reports depends on two conditions:

- the VPN is off, or the config does not differ from the running one —
  `Config rebuilt: N nodes`;
- the VPN runs, the config differs, Auto-restart VPN on settings change is
  on — `Config rebuilt: N nodes — reloading VPN`;
- the VPN runs, the config differs, Auto-restart VPN on settings change is
  off — `Config rebuilt: N nodes — restart VPN to apply`.

#### General sets the core log and root certificates

The **General** section sets what the core writes to its log and which
certificates it trusts. Where: VPN Settings → Core → General.

The **Log level** setting sets the level from which the core writes events to
the log: trace, debug, info, warn, error, fatal, panic. The default is `warn`:
warnings and errors only. The core log shows in Debug → Log when App
Settings → Diagnostics → Forward sing-box logs is on (off by default). The app
drops DEBUG and TRACE lines while Verbose (TRACE/DEBUG) in the same place is
off. To see them, you need both conditions: Log level `debug` or `trace`, and
Verbose (TRACE/DEBUG) on.

The **Certificate store** setting picks the root certificates the core uses
to verify TLS servers: `system` (default), `mozilla`, `chrome`. On Android 7.x
and older the system store is outdated: it lacks Let's Encrypt and other
current certificate authorities, and nodes with TLS do not connect. On such
phones pick `mozilla` or `chrome`: a certificate set built into the app.

#### Network sets interface selection and the wait for direct connections

The **Network** section sets which phone network interface the core uses to
go out and how long it waits for direct connections. Where: VPN Settings →
Core → Network.

The **Auto-detect interface** setting is on by default: the core detects the
default network interface by itself.

The **Direct connect timeout** setting sets how long the core waits for a TCP
connection through direct before it gives up. The default is `15s`; the
options run from `5s` to `2m`, and you can type your own value in the form
`15s`, `1m`, `1m30s`. The sing-box core's own value, without L×Box, is `5s`,
and on a mobile network that loses connection setup packets it is not enough.
If sites through direct on a mobile network do not open on the first try,
raise the value to `20s` or `30s`.

#### TUN sets the addresses and parameters of the virtual interface

The **TUN** section describes the virtual network interface through which the
phone's apps hand traffic to L×Box. Where: VPN Settings → Core → TUN. IPv6 is
turned on here too, but the decision and the order of steps are described in
[IPv6 in the tunnel](#ipv6-in-the-tunnel-is-off-turn-it-on-only-if-your-network-supports-it).

| Option | What it does | Default |
|---|---|---|
| **IPv4 address** | The tunnel's IPv4 address in CIDR form | `172.16.0.1/30` |
| **Enable IPv6** | Gives the tunnel an IPv6 address; see the IPv6 section | Off |
| **IPv6 address** | The tunnel's IPv6 address; applies only when Enable IPv6 is on | `fdfe:dcba:9876::1/126` |
| **Custom tunnel routes** | Sends all IPv4 and IPv6 into the tunnel with explicit range halves (`0.0.0.0/1`, `128.0.0.0/1`, `::/1`, `8000::/1`) instead of the core's default routes | Off |
| **TUN interface** | The system name of the interface | `lxbox` |
| **MTU** | The largest packet size in the tunnel; 1492 suits both a mobile network and Wi-Fi | `1492` |
| **Auto route** | The core manages the routing table by itself | On |
| **Strict route** | The on-screen hint warns: `May break connectivity on some devices` | Off |
| **Stack** | The tunnel's network stack: `system`, `gvisor` (in user space), `mixed` | `system` |

Turn on Custom tunnel routes only if the default routing works incorrectly.

#### TLS Fragmentation splits the first hop's TLS handshake

The **TLS Fragmentation** section changes the start of a TLS connection to the
server so that no single packet carries a recognisable signature. The
technique targets DPI behaviour: a traffic classifier that looks for the whole
signature in one packet does not recognise such a connection. All options are
off by default. Where: VPN Settings → Core → TLS Fragmentation.

| Option | What it does | Default |
|---|---|---|
| **TLS Fragment** | Cuts the ClientHello into small TCP segments | Off |
| **TLS Record Fragment** | Splits the handshake into several TLS records. The on-screen hint advises starting with this one. | Off |
| **Fallback delay** | The wait time when automatic detection fails. Applies only if TLS Fragment or TLS Record Fragment is on. The app replaces a value the core cannot parse with `500ms`. | `500ms` |
| **Mixed-case SNI** | Changes the letter case in the server name: `WwW.gOoGle.CoM`. Servers accept any case (RFC 6066); it helps only against letter-by-letter name matching. | Off |

The options act on the first hop only: the server the phone connects to
directly. Hops behind a detour and in a chain run inside the tunnel, and the
classifier does not see their TLS. Exceptions:

- REALITY nodes get neither fragmentation nor Mixed-case SNI: a REALITY server
  does not accept a split ClientHello, and the server name must match byte for
  byte;
- NaiveProxy and MASQUE nodes over HTTP/3 do not get fragmentation;
- Mixed-case SNI leaves Punycode parts of the name (`xn--…`) untouched.

The app chooses the letter case for Mixed-case SNI once, when it builds the
config, and keeps it while the tunnel runs.

The section sets the default for all servers. The same four options can be
overridden for one subscription or folder (its settings tab, **TLS** section)
and for one server (the server's Settings tab, **TLS** section, under
Detour). Each option is resolved on its own: server, then
subscription or folder, then the global section; **Default** takes the value
from the level above, and the row shows which one. **Off** on a server turns
the option off for it even when it is on globally. A checkbox set on a REALITY
server itself does fragment it; the global and subscription/folder levels
still skip REALITY. A server behind a detour gets nothing — its section says
so.

### Mode selects the operating mode and tunnel options

The **Mode** tab sets how traffic reaches L×Box. Where: VPN Settings → Mode.
The VPN / Proxy / VPN + Proxy selector and the local proxy options are
described in
[Operating mode](#operating-mode-tunnel-local-proxy-or-both), the Allow VPN
bypass switch in
[Allow VPN bypass](#allow-vpn-bypass-lets-apps-go-past-the-tunnel).

The **Tunnel options** group is visible in the VPN and VPN + Proxy modes and
hidden in Proxy: without a tunnel its options have nothing to apply to.

| Option | What it does | Default |
|---|---|---|
| **Keep VPN on exit** | The VPN keeps running when the app is swiped away from the recent apps list. Off: a swipe stops the VPN. | On |
| **Allow VPN bypass** | See the Allow VPN bypass section | Off |
| **System HTTP proxy** | Tells apps on the VPN network the address of the local HTTP proxy. Apps that honour the system proxy (Chrome, Play) connect through it to the core over TCP, without QUIC. | Off |

System HTTP proxy works on Android 10 and later; on Android 9 and older the
switch toggles, but apps do not receive the proxy address. Apps that do not
read the system proxy go through the tunnel as usual.

---

## App Settings controls the app's behavior, not the traffic path

The **App Settings** screen gathers the settings of L×Box itself: startup and
updates, appearance, subscription downloads, Android permissions, debugging
and automation. Routes, DNS and the operating mode live on other screens —
Routing and VPN Settings. Where: main menu ≡ → App Settings. The screen has
five tabs: General, Appearance, Subscriptions, Diagnostics, Automation.

The defaults work without any setup. Open the screen when the VPN has to
come up and restart on its own, when a subscription returns no nodes, or
when the developer asks for a core log.

### General controls VPN startup and update checks

The **General** tab decides what the app does without you: brings up the
VPN after the phone boots, applies edits, checks for new versions. Where:
App Settings → General.

| Option | What it does | Default |
|---|---|---|
| Usage region | The country where you use the app. Get WARP picks its set of SNI domains by it. | Auto |
| Auto-start on boot | Brings up the VPN after the phone boots. | off |
| Auto-restart VPN on settings change | Applies every config change to the running tunnel by itself. | off |
| Quick Settings tile | The Add button adds the L×Box tile to the notification shade. | — |
| Home-screen shortcut | A hint without a switch: shortcuts on the app icon. | — |
| Check for updates on launch | Asks github.com for a new version once every 24 hours. | set by your answer to the question on first launch |
| Auto-ping after connect | Pings the nodes of the current direction 5 seconds after connecting. | on |
| Haptic feedback | Vibrates when you tap the connect button, pick a node, refresh a subscription by hand, and when the core stops responding. | on |
| Backup & restore | Opens the screen that moves settings through a file. | — |

To have an edit in Routing, DNS or on a server reach the tunnel without
tapping the banner, turn on **Auto-restart VPN on settings change**. The
cost is a drop: per the on-screen hint, each apply stops the tunnel for
about 3 seconds and closes open connections. Without the option, edits wait
for a VPN restart, and the home screen shows the banner Config changed —
restart VPN to apply.

| Situation | What to choose |
|---|---|
| The edit must work at once; dropped connections are acceptable | Auto-restart VPN on settings change on |
| Edits pile up; the restart happens at a moment you choose | Option off; you restart the VPN from the banner |

While the option is on, subscriptions hide their On update setting: the new
node set after a subscription refresh also applies at once. Turning the
option off gives each subscription back its own choice — see
[The subscription screen](#the-subscription-screen-has-four-tabs-nodes-settings-source-filters).

**Auto-start on boot** brings up the VPN after the phone boots, so a reboot
does not leave the phone without a tunnel. To keep Android from stopping
the VPN while idle, also check the Battery optimization row on the
Diagnostics tab.

**Usage region** sets the country for which Get WARP picks SNI domains for
WARP servers — WireGuard and MASQUE. Tapping the row opens a list:

| Choice | What it does |
|---|---|
| Auto (default) | The mobile network's country; without one, the SIM card's country; without one, the country from the phone's language settings. The row shows the result: `Auto · RU` or Auto · country not detected. |
| Not set | No region: the common domain set. |
| RU | A regional domain set. In v2.25.12 it is the only regional set. |
| Other country code… | Any two-letter country code. A country without its own set gets the common one. |

The **Quick connect** section adds a tile to the notification shade and
reminds you of the icon shortcuts; how to use them is in
[Quick connect](#quick-connect-the-vpn-turns-on-without-opening-the-app).
On Android 13 and later, the Add button on the Quick Settings tile row
brings up the system prompt to add the tile. On older versions, L×Box shows
how to drag the tile into the shade by hand. The Connect and Disconnect
shortcuts on the icon work on Android 11 and later.

**Check for updates on launch** asks github.com for the latest version
number once every 24 hours. If a new one is out, a message about it appears
at the bottom of the screen on the next app launch, not on top of the
running app. Tapping the message opens the release page where the app was
installed from: GitHub, Google Play or F-Droid. The Later button closes the
message until the next launch; Ignore closes it for this version for good.
Below the switch are the time of the last check (Last check) and the Check
now button: it checks at once, regardless of the switch and the interval.

The default is set by the Check for updates? question on first launch:
Enable turns the check on, Skip turns it off. If you close the question with
the Back button, the check turns on for a GitHub install and stays off for a
Google Play or F-Droid install: the store installs updates there. While the
option is off, the app contacts GitHub neither for updates nor for the
author's messages on the home screen: they come from a copy inside the app.

**Auto-ping after connect** pings the nodes of the direction selected on the
home screen 5 seconds after connecting: during this pause the core brings up
the exits. The ping repeats after the core reloads with a new node set. Each
node is checked once: a direction with 200 nodes means 200 checks on every
connect. Turn the option off if you want pings only on the button.

**Haptic feedback** vibrates when you tap the connect button and when you
pick a node. A manual subscription refresh gives different vibrations for
success and failure. A separate vibration fires when the core stops
responding and the app considers the tunnel dead. If Touch feedback is off
in Android, there is no vibration whatever the option's value.

The **Backup & restore** row opens the screen for moving settings — see
[Backup moves settings to another device](#backup-moves-settings-to-another-device).

### Appearance changes the theme, layout and language

The **Appearance** tab sets how the interface looks. Options apply at once,
without restarting the app. Where: App Settings → Appearance.

| Option | What it does | Default |
|---|---|---|
| Appearance: System, Light, Dark | The theme. System follows the Android theme. | System |
| Allow rotation | Allows landscape orientation when the device rotates. Respects the system auto-rotate setting. Off — the screen stays in portrait. | off |
| Two columns on wide screens | Shows the node list in two columns if the window is at least 600 dp wide and manual sorting is off: tablet, landscape, split screen. | on |
| Language | The interface language. | System default |

Turn on Allow rotation on a tablet or on a phone in a dock, where the app
stays in landscape. The Language choices and what gets translated are in
[App language](#app-language).

### Subscriptions sets when subscriptions download and which client fetches them

The **Subscriptions** tab sets how subscriptions update and which client
L×Box presents itself as to the provider when downloading. The values are
shared by all subscriptions; a single subscription sets its own in the Fetch
identity section of its screen — see
[The subscription screen](#the-subscription-screen-has-four-tabs-nodes-settings-source-filters).
Where: App Settings → Subscriptions.

| Option | What it does | Default |
|---|---|---|
| Auto-update subscriptions | Updates subscriptions on events and on a timer. | on |
| Update disabled subscriptions | Updates disabled subscriptions too. Active only while Auto-update subscriptions is on. | off |
| Custom User-Agent | The User-Agent string for subscription downloads. | `LxBox-android/<version>` |
| Send HWID | Sends the device identifier and headers about the device. | off |

**Auto-update subscriptions** checks subscriptions when the app launches,
when the app returns from the background, 2 minutes after the VPN connects
and after the VPN disconnects. While the app runs, the check repeats once an
hour. Only a subscription whose Update interval has expired gets updated:
24 hours by default, or the period the provider sent. A subscription with
`Don't auto-update (manual only)` selected in Update interval never updates
automatically. The ⟳ button on the Servers screen updates subscriptions
whatever the option's value.

If 5 attempts to update a subscription fail in a row, it stops updating
automatically until the app restarts. A retry for one subscription comes 15
minutes or more after the previous attempt. The ⟳ button lifts these limits.

**Update disabled subscriptions** keeps the node list of disabled
subscriptions fresh: when you enable such a subscription, it has the current
node set at once. Nodes of a disabled subscription do not enter the config.

Some panels choose the response format by User-Agent and give the full
config only to specific clients. If a subscription loads but its nodes do
not work, change **Custom User-Agent** and refresh the subscription. The
Client presets icon in the dialog fills in the string of a popular client:
Happ, v2RayTun, Streisand, Karing, v2rayNG, Hiddify, sing-box. The LxBox
(default) choice and an empty field restore the standard string.

**Send HWID** sends the device identifier (HWID) and three headers about the
device with every subscription download. Panels with a device limit require
it, Remnawave for example: without the HWID, such a panel returns a single
node instead of the list, with a name the panel sets, for example "App not
supported". Once the option is on, four rows appear below the switch:

| Row | Default value |
|---|---|
| HWID · x-hwid | A UUID; the app creates it when you first turn the option on. The Regenerate button creates a new one. |
| x-device-os | `android` |
| x-ver-os | The phone's Android version |
| x-device-model | The phone's model |

Each row is edited with the pencil. An empty field restores the default:
`android` for `x-device-os`, the phone's data for `x-ver-os` and
`x-device-model`.

### Diagnostics shows Android permissions and turns on debugging

The **Diagnostics** tab shows whether Android interferes with the VPN in the
background and turns on logs for troubleshooting. It has two sections:
System setup — Android permissions; Developer — logs and the Debug API.
Where: App Settings → Diagnostics.

The rows of the **System setup** section are not switches but permission
states: a green icon means the permission is granted, a red one means it is
not. Tapping a row leads to where the permission is granted; when you return
to the screen, the app re-reads the state.

| Row | What it checks | If red |
|---|---|---|
| Battery optimization | Whether L×Box is excluded from battery optimization | Android may suspend the VPN while idle. A tap brings up the system prompt to exclude L×Box; on some firmware, the general optimization list opens instead. |
| Notifications | Whether notifications are allowed | Android may restrict the VPN service. A tap requests the permission; after a refusal, it opens the app settings. |
| Location (background) | Background location access | Rules with the WI-FI NETWORK condition cannot see the network name. The caption names the cause: Precise location permission missing — precise location is not selected; Location is turned off — location is off. |
| Nearby Wi-Fi devices | Access to nearby Wi-Fi devices, required on Android 13 and later | The network name and BSSID are unavailable. |
| App info (OEM power settings) | Nothing: the row leads to the system App info screen | — |

If the VPN disconnects when the screen is off, check Battery optimization
and App info (OEM power settings). Before opening App info, the app shows
the Find these toggles hint: allow autostart and background activity, remove
battery restrictions. Where these switches are depends on the manufacturer:
Xiaomi, Samsung, Oppo, Huawei and Google Pixel hide them in different
places.

Location (background) and Nearby Wi-Fi devices are required by rules with
the WI-FI NETWORK condition and by recording of visited networks: without
them, Android returns `<unknown ssid>` instead of the network name. The
condition is described in [Rules](#3-rules-sets-exceptions-to-the-default).

The **Developer** section is for troubleshooting — your own or at the
developer's request in an issue:

| Option | What it does | Default |
|---|---|---|
| Debug API | An HTTP server for debugging from a computer over adb. | off |
| Lock config (debug) | Actions in the interface do not rebuild the config. Visible while Debug API is on. | off |
| Forward sing-box logs | Writes the core log to Debug → Log, Core filter. Applies after an app restart. | off |
| Verbose (TRACE/DEBUG) | Adds the detailed TRACE and DEBUG levels to the core log. The switch is active while Forward sing-box logs is on; no lines appear until the app restarts after Forward sing-box logs is turned on. | off |
| Auto-record visited Wi-Fi networks | Remembers Wi-Fi networks for WI-FI NETWORK rules. | off |

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

**Forward sing-box logs** writes the core log into the app's common log.
The core reads this option once, when the process starts, so a VPN restart
is not enough: the app has to restart. The Quit & reopen app button below
the options does this: it closes the app process and stops the VPN; you
open the app again by tapping its icon.

**Verbose (TRACE/DEBUG)** fills the log fast on live traffic. Turn it on
while you reproduce the problem and turn it off right after.

#### A core log for an issue takes six steps

1. App Settings → Diagnostics → turn on **Forward sing-box logs**. The
   message Saved. Force-stop & reopen app to apply. appears.
2. Tap **Quit & reopen app** → Quit. The app closes and the VPN stops.
3. Open the app by tapping its icon and connect the VPN.
4. If the details are not enough, turn on **Verbose (TRACE/DEBUG)**.
5. Reproduce the problem and open Debug → Log, Core filter. Core lines
   appear in the log.
6. Copy the log with Copy log in the Debug screen menu and turn off
   Verbose (TRACE/DEBUG).

**Auto-record visited Wi-Fi networks** builds the network list for rules
with the WI-FI NETWORK condition. A network where the phone stayed for 5
minutes or longer enters the Pick saved list of the rule editor: Routing →
Rules → rule → WI-FI NETWORK → Pick saved. Short connections in passing are
not recorded. The list is stored only on the phone. Without the option, only
the Add current and Manual buttons add to it.

> ⚠️ Turning off Auto-record visited Wi-Fi networks does not delete the
> recorded networks. Remove a network with the Remove from history cross in
> the Pick saved list.

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

---

## Common problems: symptom, cause, action

**The app is in the Allow-list, but the VPN does not affect it.**
The Allow-list only admits traffic into L×Box; Default traffic in Routing →
Directions decides where it goes. With Default traffic = Direct, admitted apps
go out directly. Set **Default traffic** = VPN.

**The VPN started working after you added L×Box to the Allow-list.**
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

**Sites stopped opening after you turned IPv6 on, Russian ones more often.**
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
update the subscription.

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
| Ping and the ⚠ icon | Home screen | ERR: the node does not answer. ⚠: other servers go out through the node and fail with it; tap to see which ones. |
| Stats | Statistics, while the VPN is on | Traffic per direction: where the bytes go. |
| Conns | Statistics | Live connections: app, host, rule, chain of exits. Connections with traffic in one direction only are highlighted: replies get lost on the way, for example when the carrier cuts the protocol. |
| Profiler | Statistics | A real-time recording of connections and DNS resolves, with filters by app, domain and IP: which domain fails to resolve, which direction a request took, where an app connects. For DNS groups you see which members answered and which stayed silent. |
| Log | Debug (side menu) | The app and core log. **Verbose (TRACE/DEBUG)** in App Settings → Diagnostics turns on the detailed log; the switch is inactive until Forward sing-box logs is on, and the lines appear after the app restarts. The Log tab links there. |
| Crashes, OOM, Profiling | Debug | Core crash reports, core memory snapshots on low memory, pprof profiles for the developer. |

If the phone gets hot or uses too much memory, open VPN Settings → System →
Optimization → **Memory limit**: in Auto mode the limit follows the device's
RAM. The System → WireGuard connections section puts idle WireGuard tunnels
to sleep.

---

## Speed Test measures speed to a test server over the current route

The **Speed Test** screen measures latency, download speed and upload speed
between the phone and a test server. Where: ≡ → Speed Test. With the VPN on,
requests go through the tunnel and the routing rules decide where each one
exits; with it off, they go directly. The line above the results shows the
route:

- `Direct (no VPN)` — the VPN is off.
- `Route depends on your rules, shown after the test` — the VPN is on and the
  selected server has not been tested yet.
- `Via: <outbound>` — after a test: the outbound the core used for the
  requests to the server, taken from the core's connection list. A node
  name means the requests went through that node; `direct-out` means a rule
  sent them directly, past the node.
- `Route depends on your rules` — the test ran, but the core did not report
  a connection to the server.

To run a test:

1. Pick **Server** — the test server; Cloudflare by default. To measure a
   node, take a server in the node's exit country or near it.
2. Pick **Streams** — the number of parallel downloads: 1, 4 or 10; 4 by
   default.
3. Tap **Start Test**. The line under the gauges shows the stage: Testing
   ping..., Testing download..., Testing upload... (only on servers that
   measure Upload), and Complete at the end.

Each of the three results has its own method:

| Result | How the app measures it | How to read it |
|---|---|---|
| Ping | Five HTTP requests to the server; a response with a status below 400 counts as a success. With three or more successes, the app drops the fastest and the slowest and averages the rest; with fewer, it averages all of them. Each request includes connection setup and TLS. | The number is higher than an ICMP ping to the same server. `Failed` means no request finished successfully; each request gets 5 seconds. |
| Download | Streams parallel downloads of one file: 25 MB from Cloudflare, 10 MB from the others. The measurement stops after 15 seconds. | Mbit/s. One stream shows the speed of a single download; 4 and 10 come closer to the link capacity. |
| Upload | Two parallel 5 MB uploads to the server's upload address, 30 seconds at most. A request counts only when the server answers with a status below 400. Hostkey servers accept at most 1 MB per request, so the app sends them 1 MB requests one after another. | Mbit/s. `n/a` — the server has no upload address, and the app does not measure Upload there. `Failed` — the server accepted no request. |

A run uses traffic: with Cloudflare and 4 streams it downloads up to 100 MB.
On mobile data, pick 1 stream.

The **Session History** list under the button keeps the last 10 runs: time,
VPN icon, route, test server, ping, ↓ and ↑. The route is the outbound
from the core, `Direct` without VPN, or `—` if the core did not report it.
The list records a failed ping as `-1ms`, a failed Download as `↓0.0`, a
server without Upload as `↑n/a`, and an Upload the server rejected as `↑—`.
The list lasts
until the app restarts. To compare nodes, switch the node on the home screen
and run the test with the same Server and the same Streams: the rows line
up next to each other.

> ⚠️ The Hostkey (Moscow) and Selectel (RU) servers sit in the `.ru` zone.
> With the Ru internet segment preset on, as it is by default, requests to
> them go direct, past the node, and after the test the screen shows
> `Via: direct-out`. To measure a node, pick servers outside `.ru`.

Measurement limits:

- Upload is measured on the servers with a published upload address:
  Cloudflare, Tele2 (EU), Hostkey (Moscow), Hostkey (Frankfurt), Hostkey
  (Helsinki) and Hostkey (New York). Selectel (RU), Hostkey (Amsterdam), OVH
  (France) and ThinkBroadband (UK) only serve files, so Upload there is
  `n/a`.
- If the selected server does not serve the file, Download comes from the
  first server from the top of the list that serves it, other than the
  selected one. Session History records the selected one.

---

## Config Editor edits the core config until the next rebuild

The **Config Editor** screen shows the sing-box config that L×Box built from
the settings and passes to the core when the VPN starts, and lets you edit
it by hand. Where: ≡ → Config Editor; the screen title is Config. A manual
edit lasts until the next rebuild: a settings change in the interface or a
subscription update builds the config again, and the edit is lost.

The screen serves to see what exactly the core received, to check a field
the forms lack, or to attach the config to an issue. For rule fields the
form lacks, the rule editor has Raw JSON, see
[Raw JSON and the View tab cover fields the form lacks](#raw-json-and-the-view-tab-cover-fields-the-form-lacks);
such an edit survives a rebuild.

| Element | What it does |
|---|---|
| Editor field | JSON with indents, line numbers and sticky block headers. Accepts JSON5: `//` and `/* */` comments. |
| Find | Searches the text; Previous match and Next match move between matches. |
| Copy | Copies the whole text. |
| Save | Checks the syntax and writes the config. |
| ⋮ → Paste from clipboard, Load from file | Replace the editor text with the clipboard or a file. The text reaches the config only on Save. |
| ⋮ → Copy to clipboard, Share | Hand the text out; Share sends the file `lxbox_config.json` to another app. |

The saved config applies at the next VPN start. With the VPN running, the
home screen shows the banner `Config changed — restart VPN to apply`. After
Save the app reminds you that the next rebuild overwrites the edit, and that
pinning the config in App Settings → Diagnostics keeps it. Leaving the
screen with an unsaved edit asks Discard, Keep or Save.

> ⚠️ Save checks only the JSON syntax; it does not check sing-box fields.
> The core finds errors in them when the VPN starts. Before editing, save a
> copy: ⋮ → Copy to clipboard.

A config longer than 1,048,576 characters opens read-only, with the label
`Config is too large to edit on device. Share it, edit it elsewhere, then pick
the edited file in Load from file: it is saved right away.` Save is inactive
on such a screen. Share hands the file to an external editor. Here
⋮ → Load from file and ⋮ → Paste from clipboard save the loaded text at once,
without editing and without a size limit: the JSON check and the error are
the same as for Save. As with Save, Lock config does not block this save; with
Lock config on, the next rebuild does not overwrite the saved file. The
screen stays read-only until you open it again.

### Lock config pins a manual config

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
- The proxy does not receive all of the client's traffic. Browsers and some
  other apps use the system Wi-Fi proxy; games, messengers and everything else
  that bypasses the system proxy go out directly. This does not replace a VPN
  on the client itself.
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
would not survive a restart.

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

Finnish nodes without the `🇫🇮 Finland #2`, `#3` duplicates look like
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
Shortcuts work on Android 11 and newer.

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
| ⋮ on a workspace row | Rename or Delete. You cannot delete the current workspace: the auto-save goes into it. |

Until anything is saved, there is one workspace, Default, and nothing changes
on disk. A workspace holds the settings file, the subscription content cache
and the downloaded rule files; the core rebuilds its own cache after a load.
Workspaces stay on the device only. To move a workspace to another phone, load
it and make a Backup.

## Backup moves settings to another device

The **Backup & restore** screen saves L×Box settings to a JSON file and
restores them from a file. Where: App Settings → General → Backup &
restore. The screen serves to move to a new phone and to keep a copy before
a reinstall. The screen has three cards: Export, Import and Transfer to
desktop. A phone with a camera also shows Send to TV; an Android TV shows
Receive from phone as the first card.

| Task | What to choose |
|---|---|
| New phone, L×Box reinstall, a spare copy | Export, then Import |
| Empty home screen right after install | Restore from backup under the + button on the home screen |
| Moving settings to or from the desktop launcher | Transfer to desktop |
| Setting up L×Box on an Android TV | Receive from phone on the TV, Send to TV on the phone |

### Export saves the chosen categories to a file

The **Export** card writes five categories to the file; each has its own
check box. Where: Backup & restore → Export.

| Category | What it includes | Default |
|---|---|---|
| Server lists | Subscriptions, folders, standalone servers, hop chains. The file holds no subscription nodes: subscriptions download again. | On |
| Routing | Rules, directions, Default traffic, Tunnel apps, operating mode (Mode), DNS settings, WireGuard connections parameters. | On |
| App settings | App settings and VPN Settings values, ping parameters, subscription auto-update, Wi-Fi network history, WARP accounts, Interrupt connections on switch, node order. | On |
| VPN system toggles | Autostart, Keep on exit, background mode, Allow VPN bypass, Auto redirect, Memory limit, the core log and its verbose levels. | On |
| Debug API config | Debug API settings together with the access token. | Off |

> ⚠️ The Debug API token opens access to the app through Debug API. Do not
> forward or post a file exported with the Debug API config box ticked.

The **Export...** button offers three ways: Save to file — a folder on the
device, Save to Downloads — straight to Downloads, Share — send to another
app. The first two appear if the device supports them. The file name is
`lxbox-backup-v<version>-<YYYYMMDD-HHMM>.json`. After writing, the app shows
the result:

| Way | Line |
|---|---|
| Save to file | `Saved as … (N bytes)` |
| Save to Downloads | `Saved to Downloads: … (N bytes)` |
| Share | `Backup exported (N bytes)` |

The file gets the current workspace: to save another one, load it and repeat
Export. Details in
[Workspaces](#workspaces--named-sets-of-settings).

### Import shows the file's contents before applying

The **Pick file...** button in the Import card opens a file and shows the
Import backup window. Where: Backup & restore → Import. The window shows the
creation date (Created), the app version that made the file (App version),
and check boxes for the categories present in the file, with counters:
`12 server lists (3 subs, 9 custom)`, `Routing — 18 rules, final: vpn-1`.
An unticked box leaves its category untouched.

The mode sits below the list:

| Mode | What it does |
|---|---|
| **Merge with existing (recommended)** (default) | Adds what you don't have and keeps everything you do. Servers, chains, rules, directions, DNS servers and DNS rules from the file join yours; an entry you already have stays yours. New rules go after your own, so yours keep priority. A preset is on if it is on in either place. Tunnel apps: the app lists are joined, your mode stays unless it is Off. A setting you already have keeps your value; one you don't have comes from the file. Under each category the window shows `new: 3, already here: 12`. |
| **Replace all (destructive)** | The file's contents replace the ticked categories entirely; unticked ones stay untouched. Before applying, the app asks Replace all data?; the replacement cannot be undone. Debug API settings missing from the file stay yours. |

After import the app shows the summary: `Imported: 2 server lists,
routing (18 rules), 40 app settings`; after Merge — `Merged: 5 added,
40 already here`. The app skips keys this version does
not know and counts them in the same summary: `3 unknown keys skipped`.
Language and automation apply at once. The other screens show the old
settings until a restart: the **Restart now** button in the summary closes
the app, and then you open it again. Subscription nodes appear after the
subscriptions update.

The **Restore from backup** button on the empty home screen does the same
without the selection window: it restores all categories of the file in
Replace all mode and updates the subscriptions right away.

### Set up a TV from your phone

An Android TV gets the phone's settings over the local network: the TV
shows a QR code, the phone scans it and sends. Nothing is typed with the
remote. Both devices must be on the same network; a guest Wi-Fi often keeps
devices from seeing each other.

1. On the TV: Backup & restore → Receive from phone → **Show code**. On an
   empty home screen the same item sits above Restore from backup. The
   Receive settings screen shows the code, the device name, the address and
   the time left; a code lives 10 minutes, **New code** makes another one.
2. On the phone: Backup & restore → tick the categories in the Export card
   → Send to TV → **Scan code**, point the camera at the TV and confirm
   `Send to <TV name>?`.
3. On the TV the Import backup window opens, the same as for a file:
   choose categories and Merge or Replace all, apply, then **Restart now**.
   From the empty home screen subscriptions update right away.

The settings travel encrypted with a one-time key that only the QR code
carries; the code works for one transfer. The phone sends past its own
VPN, so the transfer works with the tunnel up. Debug API config stays off
unless ticked, as in Export.

| Line on the phone | What it means |
|---|---|
| `Sent. Confirm the restore on the TV.` | The TV accepted the settings; finish on the TV |
| `Cannot reach the TV…` | Different networks or a guest Wi-Fi |
| `The code has expired or was already used…` | Show a new code on the TV |
| `The TV did not accept the code…` | The code is from another session; show a new one and scan again |
| `This is not a LxBox transfer code` | The scanned QR code is something else |

After five sends with a wrong code the TV closes the code. The receive
item appears only on a TV, the send item only on a device with a camera.

### Transfer to desktop moves the shared part of settings to the desktop launcher

The **Transfer to desktop** card moves subscriptions, servers, rules and
settings between L×Box and the desktop launcher. It writes the file in a
shared format both sides understand; an Export file does not replace it, as
that file keeps a snapshot for L×Box itself. Where: Backup & restore →
Transfer to desktop.

The **Export** button saves the file in the same three ways. Settings that
have no place in the shared format stay out of the file, and after writing
the Not included in the file window lists them.

The **Import** button opens a file and, before applying, shows the Import
backup window: the app and version that made the file (`From …`), and how
many directions, chains, rules, subscriptions, servers, variables, DNS
entries and WARP accounts it holds. Below comes the Not applied as-is list:
what does not apply in the form it arrived in.

> ⚠️ Import in Transfer to desktop replaces the current rules entirely: the
> window warns about it with the line `Importing replaces the current rules`.
> A file without a `rules` key (one server, a folder) leaves the current
> rules as they were.
> Before importing, run Export in the Export card.
