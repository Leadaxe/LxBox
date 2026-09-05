# L×Box — how it works

A user guide: what is what, and what each part is responsible for. Not about the
code — about the **logic** and the order in which to set things up.

> Русская версия: [USER_GUIDE.ru.md](USER_GUIDE.ru.md)

---

## What is what

The terms people mix up most often:

| Term | In one line | Analogy |
|---|---|---|
| **Server** | A single exit point (one country/node) you can connect to. | A house a road leads to. |
| **Subscription / folder** | **Where servers come from**: a provider's list (subscription) or your own manual batch (folder). | An address book of houses. |
| **Auto node** | One list entry with **a pool of servers inside** and automatic selection between them. | A house with several doors — the fastest one opens. |
| **Direction** | **A group of servers for a job**: picks the servers it needs with a filter and switches between them. Directions are what you route traffic across. | A shelf you put the houses you need on. |
| **Chain of hops** | **A route through several servers**, built by you: `you → hop 1 → hop 2 → destination`. A source, like a subscription — not a group. | A route drawn through several houses in order. |
| **Tunnel apps** | **Who gets let into** L×Box at all (which phone apps). | The turnstile at the entrance. |
| **Detour** ("through") | One server goes **through** another before reaching the internet (a chain). | The road to the house goes via another house. |
| **Rules (routing / DNS)** | Exceptions: which traffic goes to which direction and which DNS resolves it. | Forks in the road. |

The essentials:

- **Server ≠ direction.** A server is a *where to*. A direction is a group of
  *where to* for a specific job. The same server can belong to several directions.
- **A subscription/folder is NOT a direction.** It is just a source of servers.
  Servers from it carry no traffic on their own until a direction picks them up.
- **Detour is neither a separate server nor a direction.** It is a "go through
  this one" layer on top of a server/direction/folder.

---

## The big picture: how traffic flows through L×Box

App traffic passes **four stages** — each answers its own question:

```
   Apps on the phone
            │
            ▼
 ┌─────────────────────────┐
 │ 1. Allow-list           │   "WHO gets into L×Box at all?"
 │    (Tunnel apps)        │   Not admitted → goes past, as if the VPN were off.
 └─────────────────────────┘
            │  (admitted traffic)
            ▼
 ┌─────────────────────────┐
 │ 2. Directions           │   "WHICH directions exist and WHERE by default?"
 │    (Default traffic)    │   VPN = through the tunnel · Direct = straight out.
 └─────────────────────────┘
            │
            ▼
 ┌─────────────────────────┐
 │ 3. Rules                │   "EXCEPTIONS to the default"
 │                         │   Which domain/app goes to which direction.
 └─────────────────────────┘
            │
            ▼
   VPN direction (server) · Direct · Block
            │
            ▼
 ┌─────────────────────────┐
 │ 4. DNS                  │   "HOW site names get resolved"
 └─────────────────────────┘
```

The same stages in one line each:

- **Allow-list** — *does this traffic enter L×Box at all?*
- **Directions** — *which exit path to use by default (through a server or straight out)?*
- **Rules** — *is there a specific rule overriding the default?*
- **DNS** — *how do we turn a site name into an IP for it?*

Each stage is a separate filter, and they don't substitute for one another.

---

## Operating mode — tunnel or local proxy

Before any of the stages apply, traffic has to reach L×Box somehow. You choose
how in **VPN Settings → Mode**:

- **VPN** (default) — a system-wide tunnel: L×Box takes the Android VPN slot and
  captures app traffic wholesale. The rest of this guide describes this mode.
- **Local proxy** — no tunnel at all (and no key icon either): a local
  HTTP+SOCKS proxy is started, and only the traffic of apps you point at that
  proxy reaches L×Box. The Android VPN slot stays free, so this mode coexists
  with another VPN app.
- **VPN + Proxy** — both the tunnel and the proxy port at once.

The proxy port is configured in the same place. Access to the proxy is either
from this device only or from the whole local network — in the second case
password auth is mandatory (this is how a TV or a second phone can go through
L×Box running on your phone).

Two notes for the proxy modes: Tunnel apps (stage 1) governs the tunnel only —
on the proxy side, "admission" is decided by whatever you pointed at it; and in
routing rules you can tell tunnel traffic from proxy traffic with the **Inbound**
condition.

---

## 1. Allow-list (Tunnel apps) — who gets in

**Responsible for:** which apps come under L×Box's control at all.

Three modes:

| Mode | What it means |
|---|---|
| **Off** | All apps go through L×Box (the default). |
| **Allow-list** | **Only** the selected apps go through L×Box. The rest bypass it (plain network). |
| **Deny-list** | **All apps except** the selected ones go through L×Box. |

An app that is **not** captured (absent from the allow-list / present in the
deny-list) is invisible to L×Box — its traffic goes out directly, as if there
were no VPN, and routing rules **do not apply** to it.

> **Note:** you do **not** need to add L×Box itself to the allow-list — it
> changes nothing. The app doesn't route itself through its own tunnel (its
> service connections and DNS go past the tun over the physical network). If it
> looks like "it started working after I added the app itself", something else
> almost certainly did the trick (usually Default traffic = VPN, see below).

### Allow VPN bypass — for apps that conflict with a VPN

**Why it exists.** Some apps flatly refuse to work under a VPN — banking clients
(anti-fraud sees a "foreign" IP and blocks the login), carrier apps, dialers
with VoLTE/VoWiFi. They simply stop working while the tunnel is up. This switch
gives them a way out without disabling the VPN for everything else.

**Where:** VPN Settings → Mode → Tunnel options → **Allow VPN bypass** (visible
in the modes that have a tunnel).

- **Off (default)** — a strict tunnel: all admitted traffic must go through the
  VPN, and an app cannot step around it.
- **On** — an app that *explicitly asks the system itself* for the physical
  network (via Android ConnectivityManager) is allowed to go past the tunnel.

This is a **permission, not a route**: turning it on moves nothing by itself —
only apps that specifically know how to do this will start bypassing. Don't
confuse it with the deny-list: a deny-list **forces** the selected apps out of
the VPN (works with any app), while Allow VPN bypass merely **permits** the
bypass to those who ask for it.

Which to pick: to take a specific app out of the VPN for certain — deny-list. If
the app conflicts with VPNs and knows how to request a bypass — this switch.
Most users don't need it. Restart the VPN after changing it.

---

## Servers, subscriptions and folders — where exits come from

> This part is not about traffic stages but about **where servers appear from**
> in the first place. People confuse three things: a server, a subscription and
> a folder. The difference is simple.

Everything that provides servers lives on the **≡ (menu) → Servers** screen
("Subscriptions & proxy"). There are three kinds of "sources" there; they look
alike but behave differently:

| Source | What it is | How many servers | Updates |
|---|---|---|---|
| **Standalone server** | A single server added by hand. | 1 | Never (you pasted it yourself). |
| **Subscription** | A list of servers **from a provider**, behind a link. | many | On its own, on a schedule (or via "Update"). |
| **Folder** | **Your own manual batch** of servers grouped under one name. | as many as you put in | Never (you manage it by hand). |

### Standalone server

A single server. You added it by pasting a link (`vless://…`, `vmess://…`,
`wg://…`, a QR code and so on) or from a file. There is nothing to update — it's
a static entry. Fits the "I just have one config from a friend/provider" case.

### Subscription

A link from a VPN provider hiding **a whole list of servers** behind it. L×Box:

- downloads the list and keeps it fresh on its own (once a day by default; there
  is a manual refresh button);
- on a failed update it does **not** wipe the old servers — it keeps working
  with the previous list;
- shows useful metadata from the provider when it is offered: traffic left,
  expiry date, a link to the site/support.

There is also a **file subscription** — when you import the list of servers from
a file rather than a URL. It behaves like a subscription (many servers under one
name) but doesn't update itself — you update it by supplying a new file
(**Edit source**).

> **No subscription of your own?** The same screen has **Get WARP** — it
> registers Cloudflare WARP for free and adds it as a server. Details at the end
> of this guide.

### Folder

A folder is **your own group of servers** assembled by hand. Not to be confused
with a direction:

- A **folder** answers "*where these servers are kept*" (like a folder of files:
  a shared name, a shared on/off switch, drag-to-reorder).
- A **direction** answers "*which* servers to use for a job" (see the next
  section).

Inside a folder there are **members**. Each member is exactly one server. A
member can be individually enabled/disabled, reordered, and given its own
**detour** (see the detour section). You cannot put a subscription inside a
folder — folders are for manual servers only.

**When to create what:**

- one config → **standalone server**;
- a provider's link → **subscription**;
- a set of your own `.conf` files/links you want to keep together (e.g. "my
  Mullvad") → **folder**.

### Auto nodes — one entry, a pool inside

An auto node is a single list entry containing **several servers and automatic
selection** between them. It appears in two ways:

- **From a subscription.** Providers include an entry like "Auto | Best server" —
  a pool of many servers. It used to fall apart into separate rows; now it is one
  node, and its row shows the mode and contents: `🔀 [15/7]` — a pool of 15 with
  7 in use (load-balance mode), or `🎯 [3]` — "single fastest" out of three.
- **Your own, in a folder.** Folder menu → **Add auto node…** — an auto node
  built from that folder's servers. Membership is defined in three ways: all
  servers in the folder, a rule (include/exclude regex with a live preview) or an
  explicit checkbox list. Test interval, mode and session stickiness are under
  Advanced.

Not to be confused with a direction's auto twin (`<direction>-auto`, see the
Directions section): the twin collects the nodes of a **direction** by its filter,
while an auto node is a standalone node living in the general server list like
any other.

### How all of this reaches directions

Servers from subscriptions, folders and standalone entries **carry no traffic on
their own**. They go into a common pool of servers, and it is **directions** that
pick what they need from that pool (by filter) and connect. Hence the order:
first add a subscription/folder/server → then a direction picks them up.

> **About the "tag prefix".** In a subscription's or folder's settings you can
> set a prefix — a short label prepended to the names of all its servers. It is
> handy for direction filters: give a folder the prefix `mullvad-`, and a direction
> filtered by `^mullvad-` collects exactly its servers. If you don't use direction
> filters, leave the prefix alone.

### The subscription screen — what's inside

Tapping a subscription opens its screen with these tabs:

- **Nodes** — the node list. Every node has a switch: an unwanted node can be
  **disabled** without touching the subscription itself (disabled ones are shown
  struck through and never reach the config; the choice survives subscription
  updates and provider-side renames). The "Enable all / Disable all" button
  clears accumulated state at once. A short tap on a node opens its
  **breakdown**: the JSON tab — how the node goes into the config, and the
  Source tab — the original subscription fragment it was built from.
- **Filters** — node processing rules; applied on import and on every update. A
  rule = conditions + an action. A condition is `path operator value` (contains
  / equals / regex, Not and Case-sensitive checkboxes, several conditions
  combined by AND/OR; an empty path means "search the whole node"). Actions:
  **Disable** — hide matching nodes from routing; **Enable** — bring them back
  (it also clears manual disabling; rules are applied in order and the last one
  that matched wins, so "disable everything → enable NL" works as a whitelist);
  **Replace** — write a new value at the given path (wholly or partially, with
  `$1`, `$2`… backreferences from regex groups) — for example, fixing a
  non-standard TLS fingerprint across every node at once. The **Matches** tab in
  the rule editor shows which nodes it will apply to and what exactly it will
  change, before you save.
- **Source** — the provider's raw response. If the body is base64-encoded, the
  **Decode base64** checkbox expands it into the same form the parser works with.
- **Settings** — tag prefix, detour, update interval, plus:
  - **On update** — what to do when an update brought a new set of nodes:
    *Rebuild the config* (the default — you apply it yourself), *Rebuild and
    reload the core* (applied immediately, connections drop for a few seconds)
    or *Do nothing*.
  - **Fetch identity** — how to introduce yourself to the provider when
    downloading: Default — the global User-Agent / HWID / device headers;
    Custom — a set of its own for this subscription only (handy when you have
    several panels, each with its own HWID limit or User-Agent-dependent
    response format).
- The **Test servers** button — ping the subscription's nodes without starting
  the VPN (while the VPN is running you'll be asked whether to stop and test, or
  cancel — measuring through a live tunnel isn't possible and the results would
  lie).

> **Got a single node saying "App not supported"?** Nothing is broken: the
> provider's panel requires a device identifier (HWID) and returns a placeholder
> node until it gets one. Enable HWID sending — globally (App Settings →
> Subscriptions) or in this subscription's Fetch identity — and refresh it.

---

## 2. Directions — exit paths

**Responsible for:** the **exit paths** — where traffic can leave, and which
path is used **by default**.

By default there are **three** directions: one **VPN direction** (`vpn-1`, your main
tunnel) plus two service ones — **Direct** and **Block**. You can **add more**
VPN directions (for example different servers/groups for different jobs).

Every direction is an "exit":
- **VPN direction** (a group of servers from your subscriptions) — out through a
  server (the tunnel);
- **Direct** — straight out (past the tunnel, but still through L×Box);
- **Block** — nowhere (blocked).

**Default traffic** — which exit path is the default: **VPN** (through a server)
or **Direct**. It applies to captured traffic that no rule matched.

> **This is the classic source of confusion.** If an app is in the allow-list but
> **Default traffic = Direct**, its traffic goes out **directly** — and it looks
> like "the VPN doesn't work". Set **Default traffic = VPN** and it will go
> through the tunnel. The allow-list decides "let it in or not", Directions decides
> "where to take it". Two different things.

**Automatic node selection.** A VPN direction can have an auto twin
(`<direction>-auto`) that picks a node from the group by itself. The direction editor
offers two modes:

- **Fastest** — all traffic goes to the single fastest node (by latency).
- **Load balance** — traffic is spread across a pool of several live nodes;
  sessions stick to their node so connections aren't broken by rotation.

**How a direction collects servers (the filter).** A direction doesn't store servers
inside itself — it **selects** them from the common pool (all your subscriptions
+ folders + standalone servers). The direction editor has a **Node filter** — a
filter on the server name:

- empty → **all** servers enter the direction;
- text/regex (e.g. `🇩🇪` or `^mullvad-`) → only servers whose name matched;
- the **`!`** toggle to the left of the field → the opposite, everything
  **except** the matches.

Pattern syntax, examples and how negation works — see
[Regular expressions](#regular-expressions-regex).

That's why **the same server can belong to several directions at once**. A direction
is not "the place a server is kept" but "a rule for selecting servers for a job".
Example: a "Streaming" direction filtered by `🇩🇪` collects every German server
from every source; they remain available in the main `vpn-1` direction too.

> **`vpn-1` is special.** The first direction always exists, cannot be deleted, and
> references fall back to it when another direction is removed. Treat it as the
> default direction.

**Names and how many.** A direction's tag is yours to choose — `ru-exit`,
`streaming`, anything — and **there is no cap on how many you have**. The old
`vpn-1 … vpn-10` names are just ordinary tags now: existing ones keep working,
and a new direction created without a name gets the next free `vpn-N`. A tag is
refused if it is empty, reserved (`direct-out`, `block`, `dns-out`…), already
taken, or collides with someone's `<tag>-auto` twin — the form says which.

**What goes into a direction.** Besides servers picked by the filter, a
direction can offer **Direct**, **Block** and **other directions** as options
inside it. Only directions **listed above** it are available — that ordering is
what rules out loops. Reorder the list and you change both what can be included
and the order things are emitted in the config.

---

## 3. Rules — how traffic is sorted out

**Responsible for:** exceptions to the default. Which specific traffic goes to
which direction.

A rule = **conditions + an action**. The editor offers plenty of conditions,
grouped into sections:

| Section | What it matches |
|---|---|
| **Match** | domains (exact name / suffix / substring), IP subnets (CIDR), "Private IP" (destination on the local network), "Private source IP" (source is a local address) |
| **Ports** | ports and port ranges |
| **Apps** | specific applications (per-app) |
| **Network & Protocol** | traffic type **TCP / UDP / ICMP** and the application protocol detected by sniffing (tls, quic, bittorrent, dns, …) |
| **Inbound** | which entrance the packet came through: the VPN tunnel or the local proxy (visible in proxy modes) |
| **Wi-Fi** | the name (SSID) or BSSID of the current Wi-Fi network — "at home → direct" |
| **Rule set** | an external domain/IP list in `.srs` format (downloaded by the app, used locally; re-checked on its own expiry, see the rule editor) |

Within one category it's OR, across categories it's AND (as in sing-box): a rule
"app Chrome AND domain `*.youtube.com` AND network UDP" fires only when all three
match.

**The action** is more than "which direction". Next to the action picker there is
the **Action & Resolve** gear:

- **Route to outbound** — the plain route: matched traffic to the chosen direction
  (VPN group / Direct / Block);
- **Resolve first** — resolve the domain first, then route; you can force an
  address family and set resolve parameters (own DNS server, strategy, cache,
  TTL, client subnet, timeout);
- **Resolve only** — the advanced mode: the rule only resolves, and the route is
  chosen by later rules (or by Default traffic);
- **Force IPv4 (drop AAAA)** — answer AAAA queries for the rule's domains
  locally so the traffic uses IPv4; no DNS server is needed for this. A lifesaver
  on networks with half-broken IPv6.

Typical rules:
- ads/trackers → **Block**;
- local country domains → **Direct** (faster and needs no VPN);
- BitTorrent → a dedicated direction;
- a specific app → a specific direction;
- UDP (games, calls) → direct, TCP → through the tunnel.

Order matters: rules apply top to bottom, the first match wins; if nothing
matched → **Default traffic** from Directions.

### Pairing a rule with DNS

The rule editor has a DNS block — the **Send DNS to dedicated server** switch. It
attaches a **paired DNS rule** to the rule: DNS queries for this rule's domains
go to a dedicated server (auto by default, following the route's direction; you can
pick a specific one, enable Force IPv4 and fine-tune options). One rule then
decides both "where the traffic goes" and "how it is resolved" — no need to build
a DNS rule by hand. Two limitations the editor warns about itself: the pairing is
unavailable with port/protocol filters (they are still unknown at DNS-query
time), and a rule-set works only if the list contains domains (IP-only lists
never match DNS queries).

### When the form isn't enough

- **Raw-JSON rule** — a rule can be written as raw JSON (a sing-box
  `route.rules` fragment) for fields the form doesn't expose. The action is part
  of that JSON; syntax is checked as you type.
- **The View tab** — for a normal rule it shows the exact sing-box fragment that
  will go into the config.

> **Presets** are a read-only catalog of ready-made rules. They don't apply by
> themselves: you copy the one you need into Rules (Copy to Rules), and from
> then on it's your rule.

> **Traffic Processing** is a pinned preset at the top of the rule list. It holds
> the traffic pre-processing everything else depends on: protocol detection
> (sniff), DNS query interception (Hijack DNS) and destination resolution. It
> cannot be disabled, deleted or moved — you change its settings inside the
> preset itself.

---

## 4. DNS — how names get resolved

**Responsible for:** turning a site name into an IP. A separate layer with rules
of its own.

- **DNS servers** — a catalog (Cloudflare/Google/Yandex/Quad9/AdGuard/OpenDNS,
  UDP/DoT/DoH). For each you choose which direction it travels through
  (**Outbound/detour**) and its IP/profile. If you want the DNS of "important"
  apps to go through the tunnel (so a foreign resolver sees the server's IP
  rather than your provider's), set that server's Outbound to your VPN direction.
- **DNS groups** — several servers under one tag. The group decides who answers,
  using one of three strategies: **Stable** — stick to a working server until it
  fails; **Fastest** — race, then stick to the winner; **Parallel** — race on
  every query. Members are never "dead" forever: errors are remembered for a
  limited time, and a revived path returns to service on its own. A group can go
  anywhere a single server can: as the default resolver, as the target of a DNS
  rule.

  **Building your own group is simple**: in the DNS server editor, next to the
  UDP / TLS / HTTPS types there is a fourth one — **Group**. Instead of an
  address you get checkboxes for members (any of your DNS servers), a strategy
  picker, and how long errors and wins are remembered (**Error TTL** / **Win
  TTL**; the latter is only shown for Fastest). A disabled or deleted member
  doesn't break the group: it is simply skipped at config build time with a
  warning, and when you re-enable it, it returns on its own. In the server list a
  group carries a `GROUP · mode · member count` badge, and with the tunnel up you
  see the current target and each member's state (errors, RTT).
- **Shield DNS** — the ready-made `dns_shield` group; on a fresh install it is
  the default for both DNS Final and Default Domain Resolver. Inside are Google,
  Cloudflare, OpenDNS, Quad9 and Yandex at once, across three transports
  (UDP / DoT / DoH) and two paths (direct and through the VPN). The point: no
  single failure takes resolution down — a provider goes down, the others work;
  UDP:53 gets throttled, DoT/DoH work; the tunnel drops, the direct paths work;
  direct access is blocked, the tunnelled ones work.
- **DNS Final** — the default resolver for app queries when no DNS rule matched.
  On a fresh install it is `dns_shield` (installs upgraded from older versions
  may still have the former `cloudflare_udp` — you can select the group
  yourself). If you want strictly encrypted DNS, set `google_doh` /
  `cloudflare_dot` or a server with Outbound = VPN direction.
- **Default Domain Resolver** — sing-box's own internal resolution (server
  addresses, domains inside routing rules). On a fresh install it is
  `dns_shield`. **Do not set `local_dns_resolver` here** — the system DNS leaks
  to your provider past the VPN.
- **DNS Rules** — which domains are resolved by which DNS server. This is a
  separate list on the DNS Settings screen; like routing rules, DNS rules apply
  in order (drag to reorder) and each has a switch. The rules in the list come
  from four sources:
  - **your own** — the **Add user rule** button (the rule is written as a
    sing-box `dns.rules` JSON fragment — an advanced-level tool);
  - **from presets** — an enabled routing preset brings its own DNS rules (for
    instance, "Russian domains & IPs" resolves ru domains through its own
    `dns_ru` group of three independent paths: UDP via the preset's direction, DoT
    via `vpn-1`, DoH direct — so a dead node in one path doesn't hang ru sites);
  - **from the template** — the baseline configuration rules;
  - **mirrors of routing rules** — the very "Send DNS to dedicated server"
    pairing from the rule editor (see the Rules section): such entries are shown
    as a group and are edited on the parent rule's side.

  For the typical "these domains → that DNS", it is easiest not to write a DNS
  rule by hand but to enable the DNS block right inside the routing rule.

---

## Detour — "going through" (server chains)

**What it is.** A detour is when one server reaches the internet **not directly
but through another server**. The "through" that people usually explain it with:

```
  you → [Server A] → [Server B] → internet
                     ▲
              this is A's detour: "server A goes THROUGH server B"
```

Why you'd want it:

- **work around exit-geography blocking** — you enter through server A (fast,
  nearby) but reach the internet from server B's IP (the country you need);
- **punch through a block on the server itself** — if server B is unreachable
  directly from your network but A is, and A can see B;
- **a double hop for privacy** — no single server sees both you and the final
  site.

A detour is a **layer**, not a separate entity. You take an existing server and
tell it "go through this one instead". The target of a detour can be:

- **another server** (a standalone one or a folder member);
- **a direction** — then the target isn't fixed: the core picks the best server in
  that direction at connect time (this is a **detour direction**);
- **None (direct)** — no detour, the server goes out directly (the default).

### Where it is configured

A detour is set **at the source of the servers**, through a single "choose what
to go through" picker. The entry point depends on who you're assigning it to:

| Assigning a detour to | Where | Applies to |
|---|---|---|
| **One server** | Node Settings (tap the server) | that server only |
| **A whole subscription** | Subscription → **Settings** tab | all of the subscription's servers |
| **A whole folder** | Folder → **Settings** tab | all folder members |
| **One folder member** | inside the folder, on the member | that member only |

The picker shows sections: **None (direct)**, **Directions** (if detour directions
exist), **This folder** (members of the same folder, when configuring a member)
and **Standalone servers**. Pick one, save.

### Detour chains

Detours can be built into a chain of their own: A through B, B through C —
traffic then goes `you → A → B → C → internet`. (This is a chain *assembled
out of detours*; the explicit **Chain of hops** source described below is a
different thing — see the comparison at the end of that section.) Inside a folder you can build such chains
directly between its members. L×Box will not let you close a chain into a loop:
at config build time the cycle detector fires — the start is halted and the error
dialog names the culprits; tapping a culprit navigates to the node's owner, where
the loop can be broken. A member serving as an intermediate hop for another is
marked with a ⚙ icon.

### Detour directions

A regular direction can be marked with the "Use as detour" checkbox (direction
editor). Such a direction becomes **a switchable relay layer**: any server can go
"through this direction", and which server inside it gets used is decided by the
core (by speed). Useful when you want the intermediate hop to be "the best of a
group" rather than nailed down. The checkbox is precisely a permission to pick
the direction as a relay: such a direction **remains** available as a target for
rules and route final (it is marked with ⚙ in the pickers).

### Limitations

- **You cannot chain AmneziaWG into plain WireGuard** — it hangs the core, so
  such targets simply aren't offered in the picker, and a previously saved choice
  that became invalid is reset to None.
- A detour **is not OS-level VPN-over-VPN** — the whole chain lives inside a
  single L×Box tunnel, which is cheaper in resources.

### How to verify a detour works

Turn the VPN on, open **Statistics** (available while the tunnel is up) and look
at a connection's details — there is a **Detour** line showing the chain of exits
(`A → B → …`) and a **Chain** line. That's how you see whether traffic really
went through the intermediate server.

### A dead hop is visible immediately

If a node with an ERR ping serves as an intermediate hop for others — other nodes
or DNS servers route through it (directly or via a direction where it is selected) —
a **⚠** icon appears next to its name. Tapping the icon opens the list of
affected entries with the dependency path: you see exactly who this hop will drag
down with it. If DNS servers depend on the node, a banner is shown as well —
domains of such a server silently fail to resolve, and without a hint that looks
like "the internet died for no reason".

---

## Chains of hops — a route you build yourself

**What it is.** A chain is a **source**, on the same footing as a subscription
or a standalone server, and it holds an explicit route:

```
  you → [hop 1] → [hop 2] → [hop 3] → internet
```

You spell out the order; L×Box builds one exit out of it. A chain shows up in
the common source list as an ordinary row — it can be switched off, dragged and
caught by filters like anything else.

### Chain or detour?

They solve the same physical problem from opposite ends, and mixing them up is
the usual mistake:

| | **Chain of hops** | **Detour** |
|---|---|---|
| What it is | a **route** — a source in its own right | a **property of one node** |
| You are saying | "this route goes through these servers, in this order" | "this server goes through that one" |
| Where you edit it | in the chain's own editor | on the server / subscription / folder |
| Reach for it when | the route itself is the thing you're building | a single server needs a relay in front of it |

### Positions

A chain's positions are listed **in packet order**: position 1 is the first hop
away from you, the last one is where traffic reaches the internet. You reorder
them by dragging.

A position can be:

- **a server** — a fixed hop;
- **a group** — the core picks inside it;
- **a direction** — that step becomes switchable on the fly: change what the
  direction selects and the hop changes with it;
- **another chain** — but only as the *first* position (see the rules below).

### The rules a chain must obey

The editor checks these as you type, and refuses to save a chain that breaks
them. This is deliberate: this exact class of mistake passes the core's own
config check and only kills it at start-up, so the form is the only place it can
be caught.

- **At least two positions** — one hop is not a chain; a chain that falls below
  two stops being emitted until you repair it.
- **No empty, duplicate or self-referencing positions.**
- **A nested chain only at position 1** — a chain can start with another chain,
  but cannot swallow one in the middle.
- **References only upwards** — a chain may point at a chain listed **above** it,
  never below. That ordering is what makes loops impossible.

Deleting a server or subscription **removes its positions** from every chain that
used them, and tells you how many were dropped — a route that quietly got shorter
is exactly what you must not miss. Refreshing a subscription never touches
positions.

### Seeing where a chain breaks

Open the chain's node → **Diagnostics**. Every hop is measured as part of the
whole route so far, and its own price is shown next to it:

```
  hop 1   67 ms
  hop 2   91 ms  (+24)
  hop 3   96 ms  (+5)
```

The number in brackets is the difference from the previous hop — a hop cannot be
measured on its own, only as part of the path leading to it. If a hop is dead,
it shows **the core's own error text**, and everything behind it is marked "not
reached", so "where does the route break?" is one look rather than a guessing
game. **Probe again** re-runs the measurement. Diagnostics needs the VPN to be
running — the per-hop measuring points only exist inside a live core.

### What to watch out for in practice

- **Core version.** Chains need core **sing-box-lx v1.14.0-lx.27** or newer
  (v2.21.0 ships `v1.14.0-lx.28-rc.1`). On an older core they aren't built.
- **MASQUE after a TCP hop needs `vhttp: auto`.** With the fixed `h3` setting,
  a MASQUE hop placed behind a TCP hop sends its QUIC datagrams with no
  handshake budget and reliably times out. `Auto (h3 → h2)` gives HTTP/3 a
  3-second budget and then falls back to HTTP/2 over TCP.
- **WireGuard behind a TCP hop needs a server that really proxies UDP.**
  WireGuard is UDP-only and has no fallback path. There is no way to detect the
  bad case in advance: the connection looks successful, and the server either
  forwards the datagrams or silently drops them.

---

## IPv6 — when to enable it (usually: don't)

By default IPv6 in the tunnel is **off**, and all resolve strategies are set to
`ipv4_only`. This is deliberate: on many networks (mobile ones especially) global
IPv6 half-works — an address is handed out but connections over it hang. Sites
that have an IPv6 address then stop opening, even though the VPN is formally
"working". If you aren't sure IPv6 is alive on your network, don't enable it.

There are several IPv6-related settings, scattered across different places:

| Setting | Where | What it does |
|---|---|---|
| **Enable IPv6** | VPN Settings → Core → TUN | Gives the tunnel an IPv6 address. The main switch. |
| **IPv6 address** | same place | The tunnel's IPv6 address. Only applies when Enable IPv6 is on. |
| **Preferred IP version** | VPN Settings → Core → DNS | Which addresses to prefer when resolving (`ipv4_only` / `prefer_ipv4` / …). |
| **Resolve strategy** | VPN Settings → Core → Network | The same, but for resolving domains inside routing rules. |
| **Force IPv4** | a checkbox inside some presets (Routing → Presets, the ones that resolve domains) and on user rules (the **Action & Resolve** gear next to Action) | Resolve those domains to IPv4 only. Where present, on by default. |

You don't need to keep all of this in sync by hand — the main switch does it for
you. Turn **Enable IPv6** on → both strategies switch to `prefer_ipv4` (IPv6 is
used, but IPv4 takes priority — the safe mode). Turn it off → back to
`ipv4_only`. Changing the strategies manually makes sense only if you know why
(e.g. `prefer_ipv6` on a network with proper IPv6).

The order of enabling it, if you really need IPv6:

1. Make sure the network hands out working global IPv6 (IPv6-only resources open
   without a VPN).
2. **VPN Settings → Core → TUN → Enable IPv6**.
3. **Restart the VPN** (Stop → Start, not just re-save): Android's system DNS
   cache is only flushed by a tunnel restart, otherwise old addresses keep
   surfacing for a while.
4. If some sites start hanging afterwards, check the enabled presets in Routing →
   Presets: some contain a **Force IPv4** checkbox keeping their domains on IPv4.
   If you genuinely need IPv6 for those domains, uncheck it (otherwise you can
   leave it on).

---

## Common misunderstandings

**"The allow-list doesn't work — I added an app but the VPN doesn't affect it."**
Check **Directions → Default traffic = VPN**. The allow-list only admits traffic;
where to take it is decided by Directions. With Default = Direct, captured apps go
out directly.

**"It only started working when I added L×Box itself to the allow-list."**
Most likely it wasn't the self-addition but Default traffic = VPN (if you changed
both options). L×Box doesn't need its own tunnel — its service traffic and DNS go
past the tun by design.

**"I want only the browser through the VPN, everything else direct."**
Allow-list = the browser only; Directions Default = VPN. L×Box won't touch the
other apps.

**"I want everything through the VPN, but ads blocked and local domains direct."**
Allow-list = Off (or all the apps you need); Directions Default = VPN; Rules: ads →
Block, local domains → Direct.

**"My DNS queries are visible to my ISP / go past the VPN."**
Out of the box, app DNS no longer goes through the ISP's system resolver (DNS
Final = the `dns_shield` group, which includes both encrypted and tunnelled
paths). To hide the domains for certain, set DNS Final to an encrypted server
(`google_doh`/`cloudflare_dot`) or one with Outbound = VPN direction. For internal
resolution: Default Domain Resolver ≠ `local_dns_resolver`.

**"How is a direction different from a subscription/folder?"**
A subscription and a folder are **where servers come from** (a source). A direction
is **a group of servers for a job**; it selects the servers it needs from all
sources by filter. One server can belong to several directions. You add a
subscription/folder → its servers land in the common pool → directions pick them
up.

**"I added a folder/subscription but no traffic goes through it."**
A source of servers carries no traffic by itself. Check that its servers land in
the active direction (the direction's filter is empty or matches their names) and
that **Default traffic = VPN**.

**"What is a detour and what is it for?"**
A detour means "going **through**": a server reaches the internet not directly
but via another server (the chain `you → A → B → internet`). You need it to exit
from another country's IP, to punch through a block on the server itself, or to
take a double hop. It is set on the server/subscription/folder in their settings.
The default value is None (no detour).

**"I picked a server as a detour target and it vanished / reset to None."**
The target is most likely plain WireGuard while the source server is AmneziaWG:
the core can't carry such a chain, so the choice isn't available. Pick a non-WG
server or a direction as the target.

**"I enabled IPv6 and sites stopped opening."**
The signature of a network with broken IPv6: a domain resolves to an IPv6 address
and the connection hangs. Turn **Enable IPv6** off (VPN Settings → Core → TUN)
and restart the VPN. See the IPv6 section above.

**"I changed a setting and nothing changed."**
Changes reach the running tunnel after the config is rebuilt and the VPN is
restarted — the banner on the home screen reminds you about this (it is checked
against the running core: if there is nothing to apply, the banner won't appear).
If you'd rather not do it by hand, App Settings → General has a switch that
restarts the VPN automatically on settings changes.

**"Instead of servers, my subscription has a single 'App not supported' node."**
The provider's panel requires a device identifier (HWID) and returns a
placeholder until it gets one. Enable HWID sending (App Settings → Subscriptions,
or Fetch identity in the subscription's settings) and refresh the subscription.

**"I switched directions and the pings vanished / show greyed numbers with `~`."**
Measurements are per-direction (directions have different test URLs and timeouts). A
grey number with `~` is the latest measurement from another direction, shown for
reference. Run a mass ping in the current direction and the numbers become "its
own".

**"The provider put an 'Auto | Best server' entry in the subscription and it
shows as a single row."**
That's by design: it's an auto node — one entry with a pool of servers inside and
automatic selection (the row shows the mode and contents, e.g. `🔀 [15/7]`).
There is no need to expand it into separate servers — the core holds on to the
live ones itself.

**"The app crashed and now the VPN won't start at all."**
After a core crash the app resets the core's service caches on the next start (a
corrupted cache is a common cause of "crashes right at startup"). Configs,
subscriptions and settings are left alone. If that didn't help, the Debug screen
(side menu) has a Crashes tab with the crash report, which you can send to the
developer.

---

## When something goes wrong — where to look

The tools, from simplest to deepest:

- **Pings and ⚠ marks** on the home screen: ERR on a node means the node doesn't
  answer; a ⚠ icon means other entries route through this node and will suffer
  along with it (tap it to see exactly who).
- **Statistics** (while the tunnel is up), three tabs:
  - **Stats** — traffic per direction: you can see where the bytes actually go;
  - **Conns** — live connections: which app, to which host, matched by which rule
    and through which chain. One-way connections (data in one direction only) are
    highlighted — a common sign of blocking;
  - **Profiler** — a real-time recording of every connection and DNS resolve,
    with filters by app/domain/IP. It answers "which domain fails to resolve",
    "which direction did this request take", "where does this app go". For DNS
    events you also see how DNS groups behaved: which member answered and which
    stayed silent.
- **Debug** (side menu) — the app and core log (the Log tab; the verbose switch
  lifts the debug-message filter on the fly), core crash reports (Crashes),
  snapshots from its memory watchdog (OOM) and pprof profiles for the developer
  (Profiling).
- **The phone gets hot or eats memory** — VPN Settings → System → Optimization →
  **Memory limit**: in Auto mode the limit is chosen by the device's RAM; the
  settings for suspending idle WireGuard tunnels live there too.

---

## Setting up from scratch

> **Where to find things.** Sections open from the **side menu** — swipe from the
> left edge or tap **≡** on the home screen: *Servers* (servers/subscriptions/
> folders), *Routing* (directions, rules, tunnel apps), *DNS Settings*.

1. **A source of servers** — menu → **Servers** → add, choosing the type that
   fits:
   - one config → **standalone server** (paste a link/QR/file);
   - a provider's link → **subscription** (by URL — updates itself);
   - your own batch of servers → **folder**.

   No subscription? **Get WARP** provides a working server without one (see
   below).
2. **Directions** (menu → Routing → Directions) — check that Default traffic =
   **VPN** (if you want everything to go through the tunnel by default).
3. **Allow-list** (Routing → Tunnel apps) — optional: Off (everything through
   L×Box) or Allow-list (only the selected apps).
4. **Rules** (Routing → Rules) — exceptions: ads → Block, local domains →
   Direct, and so on (can be copied from Presets).
5. **DNS** (menu → DNS Settings) — out of the box you get the Shield DNS group,
   which survives the failure of any single path; you only need to touch this if
   you want strictly encrypted DNS or your own resolvers.
6. **Detour** — optional: if you need an exit through a chain of servers, set it
   in the server's/subscription's/folder's settings (see the detour section).
7. **Connect** — the padlock. Done.

---

## Recipes

### Share the VPN with other devices over Wi-Fi

The phone running L×Box acts as a proxy gateway: a laptop, a TV or a second phone
on the same network reach the internet through your tunnel. They don't need a
client of their own — just a proxy configured in their Wi-Fi settings.

**On the phone with L×Box:**

1. **VPN Settings → Mode** → **VPN + Proxy** (the tunnel works as usual, plus a
   proxy port appears) or **Local proxy** (no tunnel, leaving the Android VPN
   slot free — suitable if another VPN is already running on the phone).
2. In the **Local proxy** block:
   - **Protocol** — **Mixed** (HTTP + SOCKS5 on one port): works both for Android
     devices and for Wi-Fi proxy settings that only understand HTTP;
   - **Listen address** — **0.0.0.0** (all interfaces). The default `127.0.0.1`
     is visible only to the phone itself — other devices cannot connect to it;
   - **Port** — 2080, for example (1024..65535 allowed);
   - **auth** — with a LAN address it is enforced and cannot be turned off. Set a
     username and password; you'll need them on the clients.
3. Connect the VPN and look up the **phone's local IP** (Android: Settings →
   Wi-Fi → the current network → IP address). Usually something like
   `192.168.x.y`.

**On the client device** — the Wi-Fi network → modify → **Proxy: manual**: the
address is the phone's IP, the port is yours (2080), the username/password are
the ones set above. On a computer the same is done in the system proxy settings
or in the browser itself.

Limitations of this approach:

- **Both devices must be on the same network** (one router, or a hotspot from
  this very phone). It doesn't work over mobile internet from outside — a
  `192.168.x.y` address doesn't exist beyond the local network.
- **The proxy doesn't capture all of the client's traffic.** Wi-Fi proxy settings
  on Android and most systems are honoured by browsers and some apps; games,
  messengers and anything that ignores the system proxy will go out directly.
  This is not the same as a VPN on the client.
- **Internet sharing (a hotspot) does not tunnel traffic by itself** — hotspot
  clients bypass the VPN until they configure the proxy manually.
- **Don't expose a LAN proxy on someone else's or a public network** — an open
  port is visible to every neighbour on that network. That's exactly why the
  password is mandatory.
- Routing rules do apply to this traffic: the **Inbound** section in the rule
  editor lets you tell "came from the tunnel" from "came from the proxy" — for
  example, sending proxy guests into a separate direction.

### Pairing with ByeDPI (and other local proxies)

ByeDPI (ByeByeDPI) is a separate app that circumvents DPI blocking locally,
without a server, and exposes the result as a **local SOCKS5 proxy**. L×Box can
take such a proxy **as an ordinary server** — and from then on it lives by all
the app's rules: it lands in directions, can be a detour, can take part in
automatic selection.

Why: some sites open with DPI circumvention alone, without a foreign server —
faster and without spending VPS traffic. And the other way around, ByeDPI can sit
*in front of* your VPN as an extra masking layer.

**Setup (verified):**

1. In **ByeDPI**, enable proxy mode — it will listen on `127.0.0.1:1080` (the
   port may differ, check its settings). Setting a password in ByeDPI is
   advisable.
2. In L×Box: **Routing → Tunnel apps** → **Deny-list** mode → add **ByeDPI**
   there. This step is mandatory: otherwise ByeDPI's own traffic re-enters the
   tunnel and you get a loop.
3. Add ByeDPI as a server: **Servers → +** → paste
   `socks5://127.0.0.1:1080#ByeByeDpi` (with a password —
   `socks5://user:password@127.0.0.1:1080#ByeByeDpi`). The add wizard with type
   SOCKS works too.
4. From there it's like any other server. Three working scenarios:
   - **A separate direction** — create a direction filtered to this node and a rule
     sending the domains you want into it (YouTube and so on), while everything
     else goes through the foreign server;
   - **Detour** — make ByeDPI the detour of your VPN server: traffic is then
     obfuscated first and goes into the tunnel afterwards;
   - **In automatic selection** — include it in the pool alongside normal nodes.

Caveats:

- A `127.0.0.1` node exists only on this phone — it is meaningless in a backup
  restored on another device, and it won't work if ByeDPI is off or has changed
  its port. Pinging such a node while ByeDPI is stopped naturally returns ERR.
- Between **ByeDPI** and **ByeByeDPI** (they are different builds) users have
  reported different behaviour: for some the pairing only worked with the
  original ByeDPI, for others both worked equally. If traffic doesn't flow, try
  the other build before looking for the cause in L×Box.
- **Any** local proxy on the phone connects the same way (another service's own
  SOCKS5/HTTP client): a `socks://` or `socks5://` link to its address, plus the
  deny-list so the traffic isn't looped.

---

## Get WARP — a server without a subscription

No subscription of your own? The servers screen has **Get WARP** — a wizard that
registers free Cloudflare WARP and adds it as a server. The private key is
generated on the phone and never leaves it. Two transports are available:
WireGuard and **MASQUE** (Cloudflare QUIC/CONNECT-IP) — MASQUE gets through
better where plain WireGuard is throttled.

If WARP's standard address is blocked or barely alive on your network:

- under *Advanced* in the wizard you can set **your own endpoint** (`IP:port`),
  and for MASQUE pick a port from the known-working list;
- the **Make experiment** button in the same wizard creates the **SCAN WARP**
  experiment folder: it generates a batch of WARP variants (WireGuard / AWG /
  MASQUE) across Cloudflare's address ranges and pings them — the live ones stay
  in the folder, the dead ones disable themselves. That's how you find a working
  endpoint on your particular network without trying them by hand.

---

## The server list — search and labels

**Filters.** Above the server list on the home screen there are filters: a text
one (by name/regex) and chips by subscription, protocol and transport. To the
left of the text field is the **`!`** toggle — it inverts the filter (show
everything that does **not** match); the chips have the same toggle. Filter
settings are remembered separately for each direction. Pattern syntax — see
[Regular expressions](#regular-expressions-regex).

**Emoji labels.** A server carries an emoji label in its tag. You can change it
in **Node Settings** (the emoji picker button); when a server is added, the label
is filled in automatically from the country/name.

**Each direction has its own pings.** Latency measurements are stored per direction:
the test URL and timeout are configured per direction, so "180 ms" measured by
different tests are different quantities. Switching directions doesn't wipe the
other results. If a node hasn't been measured in the current direction yet, the
latest measurement from another one is shown — dimmed and marked `~`
("approximate"): there is a number, but it came from a different test.

---

## Regular expressions (regex)

A regex is a pattern for searching text. In L×Box it shows up in four places, and
**works the same way everywhere**:

| Where | What it filters |
|---|---|
| **Node filter** in the direction editor | which servers enter the direction |
| **Search** above the server list | what is shown in the list |
| **Membership rule** of a folder's auto node | which servers are in the pool |
| **The `matches` condition** in subscription processing rules (Filters) | which nodes the rule applies to |

Plain text is already a working filter: `Germany` finds every server with that
word in its name. Special characters are only needed when a plain match isn't
enough.

### Negation is the `!` toggle, not a character in the pattern

A frequent question: "how do I write *everything except this*?" Doing it through
the pattern itself is clumsy, so negation was moved into a separate button.

To the left of the input field is the **`!`** toggle — it inverts the result:
show (or take into the direction) everything that did **not** match the pattern.
The filter chips (by subscription, protocol, transport) have the same toggles —
each category inverts independently.

- a direction with "everything except Russian servers": pattern `🇷🇺`, toggle
  **`!`** on;
- a direction with "Russian only": the same pattern, toggle off.

In subscription processing rules (Filters) the toggle's role is played by the
**Not** checkbox on a condition — same meaning.

### What to write in the pattern

The syntax is standard JavaScript / Perl-style regex (the Dart RegExp engine).
The essentials:

| You write | It means | Example |
|---|---|---|
| `\|` | OR | `🇩🇪\|🇳🇱` — German or Dutch |
| `^` | start of the name | `^Premium` — the name starts with "Premium" |
| `$` | end of the name | `2$` — the name ends with "2" |
| `.` | any character | `A.1` — "A", anything, "1" |
| `.*` | any text (including none) | `DE.*Fast` — "DE", then "Fast" somewhere |
| `\d` | any digit | `\d\d` — two digits in a row |
| `[abc]` | one of the listed characters | `[123]` — "1", "2" or "3" |
| `( )` | a group (needed for `$1` backreferences in subscription rules) | `^(\w+)-` |
| `\.` | a dot as a literal character | `\.ru` — literally ".ru" |

The full syntax description is in the
[Dart RegExp documentation](https://api.dart.dev/stable/dart-core/RegExp-class.html)
(the engine matches
[ECMAScript regular expressions](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Regular_expressions)).
A convenient place to test a pattern is [regex101.com](https://regex101.com/)
with the **ECMAScript (JavaScript)** flavour selected.

### Examples by task

| Task | Pattern | `!` toggle |
|---|---|---|
| German and Dutch only | `🇩🇪\|🇳🇱` | off |
| Everything except trials and test nodes | `test\|trial` | **on** |
| Only servers of your folder with the `mullvad-` prefix | `^mullvad-` | off |
| Servers numbered 1–3 at the end of the name | `[123]$` | off |
| Everything except servers with a lightning bolt in the name | `⚡` | **on** |
| Disable several countries at once by name | `\b(?:Russia\|China\|Hong Kong\|Singapore)\b` | **on** |
| Finnish nodes except the `#2`, `#3`… duplicates | `🇫🇮(?!.*#)` | off |
| Premium nodes only, but not the trial ones | `^(?=.*Premium)(?!.*trial)` | off |

The last example already uses advanced syntax (see the next section); in most
cases the `!` toggle is simpler.

### Negation inside the pattern

The `!` toggle flips the whole result: "show everything that did **not** match".
But sometimes you need to negate only **part** of a condition rather than the
whole filter. For example: take German servers **except** the trial ones — here
one condition is positive ("has DE") and the other negative ("no trial"), and the
toggle can no longer express that: switching `!` on would flip both at once.

For such cases there are lookahead and lookbehind — a check of "what stands next
to this", without capturing the text itself:

| Construct | It means | Example |
|---|---|---|
| `(?!…)` | what follows is **not** this | `^(?!.*trial)` — "trial" appears nowhere |
| `(?=…)` | what follows is this | `^(?=.*Premium)` — "Premium" appears somewhere |
| `(?<!…)` | what preceded was **not** this | `(?<!trial )DE` — "DE", but not after "trial " |
| `[^…]` | any character **except** the listed ones | `[^0-9]$` — the name doesn't end with a digit |

That very "German except trials" example is written like this:
`^(?!.*trial).*DE` — first the check "there is no trial anywhere in the name",
then the ordinary search for "DE". The `!` toggle stays off: the pattern already
carries the negation inside it.

Negations combine: `^(?=.*Premium)(?!.*trial)` — "has Premium AND no trial". The
constructs `(?>…)` (atomic groups) and `X++` (possessive quantifiers) are not
supported — the engine will reject such a pattern.

**The working formula** — "what we're looking for, what must not follow":

```
(condition)(?!.*(forbidden))
```

Example: you want Finnish nodes, but without the `🇫🇮 Finland #2`, `#3` and so on
duplicates.

```
🇫🇮(?!.*#)
```

Read it as: the 🇫🇮 flag, and nowhere later in the name is there a hash sign. The
`!` toggle is off — the negation is already inside the pattern.

> **The most common mistake: a missing `.*` inside the parentheses.** The pattern
> `🇫🇮(?!2)` looks logical ("the flag, and no 2 after it") but takes **all**
> Finnish nodes, `#2` included. The reason: `(?!2)` requires the digit to stand
> **immediately** after the flag (`🇫🇮2`), while the name has " Finland #" in
> between. No node has that combination — so the condition holds for every one of
> them.
>
> | Pattern | Result |
> |---|---|
> | `🇫🇮(?!2)` | ❌ takes everything: looks for `2` right after the flag |
> | `🇫🇮(?!.*#)` | ✅ Finnish nodes without a number (`#2`, `#3`, any) |
> | `🇫🇮(?!.*#2)` | ✅ Finnish nodes except `#2` specifically |
>
> The same rule applies to positive lookahead: `(?=Premium)` — "Premium
> immediately", `(?=.*Premium)` — "Premium somewhere later in the name".

> **The emoji-in-square-brackets trap.** A pattern like
> `^(?![✨⭐🏁🏳️🏴])(?:.*?\()` looks correct but cuts off **too much**: 🇩🇪, 🇫🇷, 🌍
> and other flags that aren't in the list disappear as well. The cause is not the
> negation — that part works. It's that the engine parses the pattern in 16-bit
> chunks while an emoji consists of a pair of them: the class `[✨⭐🏁🏳️🏴]` falls
> apart into halves, and the half common to all flags starts matching on its own.
>
> The fix is to replace the square brackets with an alternation using `|`:
> `^(?!(?:✨\|⭐\|🏁\|🏳️\|🏴))(?:.*?\()`. The rule is simple: **don't put emoji in
> square brackets**, list them with `\|` instead. For a single emoji you don't
> need brackets at all.

### What to know about the behaviour

- **Case is ignored.** `warp`, `WARP` and `Warp` all match the same way — in all
  four places. The `(?i)` prefix **does not work** (Dart doesn't support it) and
  will simply break the pattern — it isn't needed, since case is ignored anyway.
  The exception is subscription processing rules: there a condition has its own
  **Case-sensitive** checkbox that enables case matching.
- **A match is searched anywhere in the name**, not from the start: the pattern
  `DE` finds both "DE-1" and "Nord-DE". Anchor it with `^` and `$` if you need
  the beginning or the end.
- **An empty field = no filter** (all servers enter the direction).
- **A broken pattern** is flagged with an "Invalid regex" error right in the
  field; at config build time an unusable direction filter is ignored, meaning the
  direction gets all servers (not zero).
- **A filter matching no servers at all** shows a warning — a direction with an
  empty membership cannot carry traffic.
- **The filter doesn't hide auto nodes and service entries.** Auto-selection
  nodes (`🔀`/`🎯`), "Block" and similar service rows stay in the list under any
  pattern — they are switching points and cannot be hidden by a filter. If after
  filtering by "🇫🇮 only" you still see `Europe | Auto` and "Block", the pattern
  has nothing to do with it: it isn't applied to them.
- Under the field in the direction editor there is a **live preview**:
  `matched: 12 / 37 nodes` — how many servers the pattern caught, before you save
  (with `!` on, the line starts with `excluded →`). The auto node's membership
  rule has the same preview. If the preview says "No node snapshot", the server
  list hasn't been loaded yet — connect to see the numbers.

---

## Quick connect

You don't have to open the app to turn the VPN on:

- **Quick Settings tile.** Add the L×Box tile to the quick settings panel (shade
  → pencil/edit tiles). A tap turns the VPN on/off with the last used profile.
- **Home-screen shortcut.** The quick-connect shortcut toggles the VPN with a
  single tap as well, without opening the main screen.

While connected, the notification has **Stop** and **Reconnect** buttons — you
can reconnect straight from the shade.

---

## Automation — turning the VPN on by events

L×Box can be driven by automation apps (**Tasker, MacroDroid, Llama, Automate**)
— the phone turns the VPN on and off and switches servers by events, without your
involvement. Typical scenarios:

- connecting to the home Wi-Fi → **turn the VPN off**; to someone else's/a public
  one → **turn it on**;
- launching a specific app → switch to a particular server/direction;
- on a schedule or by geofence — turn the tunnel on/off.

Automation is **off by default**. Enable it in **App Settings → Automation**
(where you can also allow L×Box to broadcast its own events — connected/
disconnected/subscription updated), then in the automation app pick L×Box as a
plugin and choose the command you need (Start / Stop / Reconnect / select a
server and so on).

> **The full manual** with every command, event and ready-made recipes
> (including control from shell/ADB) is in [AUTOMATION.md](AUTOMATION.md).

---

## App language

**App Settings → General → Language**: System default / English / Русский (the
default is the system language, falling back to English). It switches instantly,
without restarting the app or the VPN; native surfaces are translated too — the
notification with Stop/Reconnect buttons, the Quick Settings tile, the shortcuts.
Technical surfaces (logs, Debug API, automation events) intentionally stay in
English.

---

## Workspaces — named sets of settings

A workspace is a saved copy of everything the app knows: subscriptions with
their cached node lists, directions, chains, rules, DNS, tunnel apps, the
operating mode, app settings. Keep a "Home" set and a "Work" set and switch
between them from the main screen — the button to the right of "L×Box" shows
the current workspace and opens the menu.

- **Load** — pick a workspace from the list. The current state is saved under
  its own name first, so nothing is lost; then the chosen one is copied in,
  the settings are re-read and the config is rebuilt. If the VPN was running,
  it is stopped for the switch and started again with the new config — expect
  a few seconds without a tunnel.
- **Save as…** — save the current state under a new name (or overwrite an
  existing one). From then on the auto-save on Load goes to that name.
- **⋮ on a workspace row** — rename or delete. The current workspace cannot
  be deleted: it is where the auto-save goes.

Until you save anything there is a single workspace called "Default" and
nothing changes on disk. A workspace stores the settings file, the cached
subscription bodies and the downloaded rule-set files; the core's own cache is
rebuilt after a load. Workspaces stay on the device — to move one to another
phone, load it and use Backup.

## Backup — moving your settings

Opens from menu → **App Settings → General → Backup & restore**. The screen takes
a snapshot of your configuration: subscriptions, directions, chains, rules and app
settings. Export saves the snapshot to a file, import restores it (with a preview
before applying). It's a convenient way to move your settings to a new phone or
to save them before a reinstall.
