[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Tailscale — the phone as a node of your tailnet inside the VPN

LxBox joins a Tailscale network from inside the sing-box tunnel: a Tailscale
node is a `tailscale` endpoint of the core, added from the "Add server" wizard
or pasted as sing-box JSON, and the app gives it a per-node device identity, a
MagicDNS server and the routes into the tailnet. On the home screen such a node
appears under NETWORKS with its live state; its Network tab lists the tailnet
devices, switches the exit node on the fly and pings peers. With an `exit_node`
the node becomes an ordinary Direction and carries the internet traffic.

| Field | Value |
|-------|-------|
| Feature | 030-TAILSCALE |
| Type | Product feature |
| Absorbed | `§435` (a former feature, cancelled by §575/§578) · tasks 437, 445, 449, 578, 579, 581 |
| State | ✅ written from code, 2026-09-29 |

## Purpose

The user wants to reach the machines of their tailnet (home NAS, office
server, a router with subnets) through LxBox without a second VPN app, and,
when a peer offers an exit node, to send the whole internet through it. The
core runs the Tailscale client (tsnet) in user space; the app's job is
everything around it: a node that carries only its body, a stable device
identity that survives renames, folder moves and Workspace switches, the
tailnet DNS and routes that come from a template preset rather than from the
node, and a screen that shows what the tailnet looks like from the phone.

Principles: **the node is just a body** — no route or DNS rules travel with it,
the `tailscale` preset serves every Tailscale node in the config (§575, §578);
**identity is issued once** — a state directory is bound to the node's stable
key, not to its tag, so a rename does not register a new device (§445); **the
config never changes behind the user's back** — an exit node chosen on the fly
lives in the core until "Save choice" writes it into the node.

## Promises

- **P1. A Tailscale node is an endpoint without an address.** It is read from
  sing-box JSON (`outbounds[]` or `endpoints[]`) with the body kept as is, an
  empty tag becomes `tailscale`, and it is always emitted into `endpoints[]`
  with `type` and `tag` first. **Witness:** units "parse: no address, body as
  is, kind endpoint", "an empty tag → tailscale", "accepted from outbounds[]
  and endpoints[]", "registry: kind sets the config section". **Mutation:**
  emission into `outbounds[]`.
- **P2. The node carries no bundle.** A pasted config with a `tailscale`
  endpoint imports the node only; the `route`/`dns` blocks next to it, a bare
  body and a folder member get no rules of their own. **Witness:** units "a
  bare body → a node without sections", "a config with one node and a route →
  a node without sections", "folder: a bare body as a member → no sections",
  "a multi-node config with references: no bundle is extracted".
  **Mutation:** rules extracted from the pasted config into the node.
- **P3. A core without `with_tailscale` drops the node, not the config.** The
  node is excluded at build with the `tailscale_core_unsupported` warning and
  stays in storage; the rest builds. **Witness:** units "tailscale: no tag →
  refusal with a code; with the tag or with unknown tags → fit", "the core
  gate by build tag: without with_tailscale the node is removed with a code".
  **Mutation:** the whole config refused by the core.
- **P4. Without `exit_node` the node is not a Direction candidate.** The
  registry decides (`exit_capable_when`): with `exit_node` the node is a
  candidate like any other. **Witness:** units "contract 1.1.63: exit — by the
  registry's exit_capable_when", "Tailscale without exit_node is included (in
  NETWORKS)", "Tailscale with exit_node is not included". **Mutation:** a
  node without an exit listed in a selector.
- **P5. Tailscale nodes are split out of a multi-node paste.** Each becomes its
  own server; the remainder goes the usual way as text without `tailscale`
  entries, so a file subscription's cache cannot bring the node back as a
  duplicate. **Witness:** units "endpoint + proxy → two servers", "endpoint +
  two proxies → a server and a file subscription without tailscale in the
  cache", "endpoint + a group: a remainder without nodes is not an error".
  **Mutation:** the node re-appears from the subscription cache at startup.
- **P6. A state directory is issued once and follows the node.** Rename, tag
  prefix change, member rename, a move between folders or into a server, a
  swap of namesakes and disabling keep the same directory. **Witness:** units
  "rename of a single server and a prefix change — same directory", "folder
  prefix change — same directory", "member rename — the record moves to the
  new key, same directory", "a member moved to another folder", "a server
  moved into a folder and back", "a swap of namesakes — directories stay with
  their nodes", "disabling a member, a folder and a server — untouched";
  controller "tag edit and folder prefix — same directory; deletion —
  directory removed". **Mutation:** the directory named by the final tag.
- **P7. The path is substituted at emission only.** `state_directory` is
  written into the config entry when the root is known and the body has no
  value of its own; the stored body never gets a path. **Witness:** units
  "state_directory substituted with a known root, the body untouched",
  "without a root not written; an own value untouched". **Mutation:** the path
  saved into the body.
- **P8. Deleting a node deletes its identity — when the core is stopped.** The
  record goes at once; the directory goes when the core is stopped and no
  Workspace references it, otherwise at the next build with the core stopped.
  **Witness:** units "member deleted with the core stopped — directory
  removed", "deletion under a live core: record removed at once, directory at
  the build", "folder and subscription deleted whole — directories removed",
  "an orphan: removed with the core stopped, kept while running", "the core
  status is not asked when there is nothing to remove". **Mutation:** the
  directory removed under a live core.
- **P9. Directories from 2.24.0 are adopted once.** On the first build of a
  Workspace slot a directory named by the final tag is bound to its node; a
  node with a record never takes an old directory. **Witness:** units
  "migration: a 2.24.0 directory by the final tag is adopted", "migration is
  one-off: a record exists — the old directory is not taken", "a slot without
  records keeps the 2.24.0 directories until built". **Mutation:** adoption
  overwrites an existing record.
- **P10. Nothing is written until a Tailscale node exists.** No index, no
  directory; the index and the directories live outside the settings file.
  **Witness:** units "without nodes, index and directories nothing is written
  to disk", "without a Tailscale index Workspaces operations create no
  files"; their absence from the backup — `no witness` (by construction,
  [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md)).
  **Mutation:** the index created at startup.
- **P11. The default hostname is `LxBox-<device model>`.** The model is
  lowered to a DNS label (Latin letters and digits, the rest → `-`, runs
  collapsed, 63 characters in all); an empty or fully collapsed model gives
  `LxBox`. **Witness:** units "the model as is → prefix and lower case through
  dashes", "underscores and runs of separators collapse", "edges are cleaned",
  "a model without Latin letters or digits → the bare prefix", "an empty model
  → the bare prefix", "a long model is cut to a DNS label without a trailing
  dash"; widget "Hostname with the LxBox default, erasing returns an empty
  body". **Mutation:** the hostname substituted at build.
- **P12. The `tailscale` preset serves every Tailscale node in the config.**
  Per node: a route rule `preferred_by: [<node>] → <node>`, a `resolve` action
  through `<node>-dns` right before it, a DNS server `{type: tailscale, tag:
  <node>-dns, endpoint: <node>}` and a DNS rule `preferred_by: [<node>-dns] →
  <node>-dns`, in config order. **Witness:** units "two nodes: the records of
  the spec table, config order", "one node — the records of the spec table",
  "two nodes — repeats in node order, tags without a namespace".
  **Mutation:** the DNS rule's `preferred_by` names the node (the core refuses
  `DNS server not found`).
- **P13. Skipped, disabled and gated nodes are not served.** **Witness:** units
  "skip_presets and a disabled node are not served", "a node removed by the
  core gate — the preset does not see it", "filter false (skip_presets) — not
  served", "a node with skip_presets is not served, no nodes — empty".
  **Mutation:** a DNS server for a gated node (dangling `endpoint`).
- **P14. Without Tailscale nodes the config is byte for byte the same.**
  **Witness:** unit "without Tailscale nodes the config is byte for byte the
  same". **Mutation:** an empty preset emits stray entries.
- **P15. The DNS switch of the preset leaves only the route rule.**
  **Witness:** unit "dns_enable off — only the route rule". **Mutation:** the
  DNS server emitted regardless.
- **P16. The preset reaches existing users once.** An install whose defaults
  were seeded earlier gets the preset enabled at its template position; a
  deleted preset does not return; a fresh install is not touched. **Witness:**
  units "defaults seeded earlier: the preset is added once", "the preset is
  already there — no duplicate", "a fresh install is untouched; the first seed
  closes the step". **Mutation:** the preset re-added after deletion.
- **P17. `skip_presets` survives a backup round trip.** Only `true` is stored;
  an import that matches the node by body does not reset it. **Witness:** units
  "a single node: skip_presets=true of the own record is not reset", "a folder
  member: skip_presets=true is not reset on a repeated import". **Mutation:**
  a missing field on import resets the flag.
- **P18. The `tailscale` DNS server picker offers the enabled Tailscale nodes
  of all sources**, with the final tag of the last build. **Witness:** units
  "an own Tailscale server — an option; non-Tailscale — none", "a disabled
  source, member and folder are not listed", "a subscription Tailscale node —
  an option", "the final tag of the last build wins over the display tag", "a
  duplicate tag — one option". **Mutation:** a disabled node offered (its
  server would be dropped at build).
- **P19. The Network tab exists only on a Tailscale node, before
  Diagnostics**; from a NETWORKS row the screen opens on it. **Witness:**
  widgets "a Tailscale node: Network before Diagnostics", "a non-Tailscale
  node: no Network tab", "from NETWORKS: the initial tab is Network, Save
  choice present". **Mutation:** the tab on a WireGuard node.
- **P20. The tab says why there is nothing to show.** VPN off — "Start VPN to
  see the network."; no core record yet — a waiting indicator; the node is not
  in the running config — "The node is not in the running config."
  **Witness:** widgets "VPN off", "no data from the core yet — waiting", "the
  node is not in the running config". **Mutation:** an endless spinner with
  the VPN off.
- **P21. An exit node chosen on the fly does not touch the body.** A mismatch
  between the recorded `exit_node` and the active exit shows a warning sign
  and "Save choice"; Save choice writes the active peer's Tailscale address
  (IPv4 first) or removes the field; a subscription node and a node without
  a source record have no Save choice. **Witness:** units "match — no sign",
  "none in the node, chosen on the fly", "recorded in the node, cleared on the
  fly", "one in the node, another on the fly", "the IPv4 address is written
  into the body", "the field appears / changes with the key order kept / None
  removes it"; widgets "differ — the sign and Save choice, the address is
  written", "cleared on the fly — Save choice writes empty", "a subscription
  node — the sign, no Save choice", "picking an item switches on the fly, the
  body is untouched", "no record: Save choice hidden". **Mutation:** Save
  choice writes the `StableID`.
- **P22. Devices are listed online first, then by name, with marks.**
  **Witness:** unit "device order: online first, then by name"; widget
  "devices: order and marks". **Mutation:** plain alphabetical order.
- **P23. A node without an active exit hides the external check on
  Diagnostics.** With the VPN up the core state decides, otherwise the
  recorded `exit_node`. **Witness:** widgets "no exit — the check is hidden,
  a line instead", "an exit exists — the check is available"; units "VPN on —
  by the core state", "VPN off or no data — by the recorded value".
  **Mutation:** a check that always fails with "context deadline exceeded".
- **P24. The Debug API sees only the state and the device count.** No device
  names, addresses, network name, owners or sign-in link. **Witness:** unit
  "Debug API: state and device count, no names or addresses". **Mutation:**
  the peer list in `GET /state`.

## Controlled parameters

| Knob | Values | Default |
|------|--------|---------|
| Wizard → Tailscale: Tag, Auth key, Control URL, Hostname, Ephemeral, Accept routes, Exit node | strings, two switches; Auth key required, masked with Show/Hide | `tailscale` · — · empty · `LxBox-<model>` · off · off · empty |
| Node screen → "Skip presets" | on/off; visible on an own server or folder member when the template has a `for_each` preset for the node type | off |
| Preset "Tailscale networks" (`tailscale`) | on/off, sortable, `num` 945; variable "DNS" (`dns_enable`) | on · DNS on |
| DNS server of type `tailscale` | `endpoint` (a Tailscale node, required), `accept_default_resolvers` | — |
| Network tab → Exit node | a peer with `ExitNodeOption` or None; "Save choice" | from the body |
| Network tab → Log out | after confirmation | — |

Core config keys the feature emits: `endpoints[]` entry `{type: tailscale, tag,
…body, state_directory}`; from the preset — `route.rules` entries with
`preferred_by`, `action: resolve`, `server`, `outbound`; `dns.servers` entry
`{type: tailscale, tag: <node>-dns, endpoint: <node>}`; `dns.rules` entry with
`preferred_by` and `server`. Save choice writes `exit_node` into the node body.
Core RPC: `SubscribeTailscaleStatus`, `SetTailscaleExitNode`, `TailscaleLogout`,
`StartTailscalePing`. Data files: `tailscale/<name>/` (the core's state of one
node), `tailscale_state.json` (the index slot → node key → directory name).
Warning code: `tailscale_core_unsupported`. Debug API: `GET /state` field
`tailscale`, record field `skip_presets` (read-only).

## Inputs / Outputs

**Inputs:** the wizard form; pasted sing-box JSON (a single body, a config, an
array of configs) or a subscription body; the core's build tags; the tunnel
status; the core stream of tailnet state (`BackendState`, `AuthURL`, self,
exit node, peers by owner); taps on the Network tab; Workspace operations.

**Outputs:** the `endpoints[]` entry with its state directory; the preset's
route and DNS records; the node row (🕸️, "Tailscale" chip, "No address",
"—" instead of latency; in NETWORKS — the state); the Network tab; the
Diagnostics line; app log lines about kept and deleted directories; the
`tailscale_core_unsupported` notification; the core's own "sign in via the
link" notification ([013-DIAGNOSTICS · P23](../013-DIAGNOSTICS/FEATURE.md#promises)).

## Data flow

```
Wizard / JSON paste → node body as is → source record (own server, folder member, subscription node)
Build: registry gate → core gate (with_tailscale) → endpoints[] {type, tag, body}
       → state_directory = <files>/tailscale/<name from the index; issued once per node key>
       → preset tailscale: for_each over the emitted Tailscale nodes (skip_presets off)
         → route.rules: resolve via <tag>-dns, preferred_by [<tag>] → <tag>   (position 945)
         → dns.servers: {tailscale, <tag>-dns, endpoint <tag>} · dns.rules: preferred_by [<tag>-dns] → <tag>-dns
Core: tsnet joins the tailnet (auth key, or a sign-in link as a notification)
       → SubscribeTailscaleStatus → NETWORKS row state · Network tab · Diagnostics · GET /state
Network tab: pick exit → SetTailscaleExitNode (core only) → "Save choice" → exit_node in the body → rebuild
       → the node moves between NETWORKS and the Direction lists
Delete node / Workspace delete → index record removed → directory removed when nobody references it (core stopped)
```

## Rules and guarantees

- The tailnet route is a live condition, not a subnet list: `preferred_by`
  asks the endpoint whether an address or a name is its own (machine names,
  machine addresses, accepted subnets). Until the tailnet is up the rule does
  not match and traffic follows the other rules. Two nodes in one tailnet
  claim the same machines — the first in config order wins.
- The node's DNS server tag is `<node tag>-dns` without a preset namespace, so
  user references to it keep working; a user server with the same tag wins
  by the general DNS tag dedup rule with a warning.
- A `tailscale` DNS server with a dangling `endpoint`, or a second server on
  the same node, is dropped with a warning; `detour` on this type is always
  removed ([005-DNS](../005-DNS/FEATURE.md)).
- The node key of the identity index: an own server — its id (`#2`, `#3` for
  further Tailscale nodes of the same server); a folder member or a
  subscription node — the container id plus the raw tag. A body with its own
  `state_directory` gets no record and its directory is never deleted.
- Workspace slots share identities by records, never by copying files: "Save
  as" copies the records (both slots are one tailnet device), Rename moves
  them, Delete drops them and removes unreferenced directories at once
  ([018-WORKSPACES · P12](../018-WORKSPACES/FEATURE.md#promises)).
- The backup carries the node body (including `auth_key`) and `skip_presets`,
  never the identity: restored on another device the node registers anew and
  a one-time key already spent gives `invalid key`. Clearing the app data has
  the same effect — the wizard says so under Auth key.
- An exit node chosen on the fly lives in the node's state directory and
  survives a restart while the body has no `exit_node`; with `exit_node` in
  the body the body wins at start. The warning texts of the Exit node block
  name the three cases (not saved: no traffic through the node / no exit until
  saved / lost after restart).
- The state subscription of the core is held while the VPN is up and either
  NETWORKS has nodes or a Network tab is open; a config reload re-establishes
  it. Log out is confirmed with a text that says a node with a stored auth key
  signs in again at the next start.
- Device names, addresses, the network name, owners and the sign-in link are
  not written to the app log, the support dump or the Debug API.

## Boundaries

- The node is not probed: it has no address and a probe would have to join the
  tailnet; the row shows "—" instead of latency (`no witness`). Mass latency
  measurement is unavailable under NETWORKS.
- No Tailscale-specific reaction to a network change or to the Proxy mode:
  the tunnel restart on a network change is
  [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md)'s, and the node rejoins with
  the identity from its state directory; the config is built the same way in
  both modes (`no witness`).
- The wizard has no `exit_node_allow_lan_access`, `advertise_routes`,
  `advertise_exit_node` or SSH fields; they are edited on the JSON tab, and
  the registry checks them (a default route in `advertise_routes` is dropped
  with a code, `exit_node` conflicts with `advertise_exit_node`).
- Subnets behind peers (`accept_routes`) are matched by the same `preferred_by`
  condition; a subnet that collides with the home LAN is the user's call
  (position 945 comes before "Private IPs" at 950).
- MagicDNS answers full `*.ts.net` names only; short names (search domain) are
  not resolved.
- Editing `auth_key` or `control_url` of an existing node does not issue a new
  identity: a node that already signed in keeps its tailnet.
- SSH to a peer, Taildrop, `*.ts.net` certificates, IPv6-only tailnets under
  `prefer_ipv6` and per-device traffic are out of scope. The Android system
  backup includes `files/` with the tailnet keys — stock behaviour, by design
  (see [device identity](FUNCTIONS/device-identity-and-state.md)).
- Sign-in with an interactive link, exit node switching, Log out and Ping have
  not been verified on a device with a live tailnet (tasks 445, 449, 578, 579,
  581: DEVICE-PENDING).

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Tailscale node | Creates and stores a Tailscale endpoint from the wizard or sing-box JSON, gates it by the core build and decides whether it can be a Direction. | P1–P5, P11 | [tailscale-node.md](FUNCTIONS/tailscale-node.md) |
| Device identity and state | Gives every node a state directory bound to a stable key, keeps it through renames, moves and Workspaces, deletes it with the node and keeps it out of the backup. | P6–P10 | [device-identity-and-state.md](FUNCTIONS/device-identity-and-state.md) |
| Tailnet DNS and routes | Serves every Tailscale node with a MagicDNS server and `preferred_by` rules through the `tailscale` preset, with a Skip presets opt-out and the `tailscale` DNS server type. | P12–P18 | [tailnet-dns-and-routes.md](FUNCTIONS/tailnet-dns-and-routes.md) |
| Network tab | Shows the node state, this device, the tailnet devices and the exit node on the node screen, switches the exit on the fly and saves it into the body. | P19–P24 | [networks-tab.md](FUNCTIONS/networks-tab.md) |

## Related features

- [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md) — parsing of the
  `tailscale` endpoint from sing-box JSON and the JSON text as its share form
  (singbox-json-import, share-link-export); the split of a multi-node paste
  is described here.
- [004-ROUTING](../004-ROUTING/FEATURE.md) — the "Tailscale networks" preset
  in the preset table, its position 945 and late seeding (preset-bundles); the
  NETWORKS row among Directions (directions).
- [005-DNS](../005-DNS/FEATURE.md) — the `tailscale` DNS server type in the
  server form, the dangling-`endpoint` sanitizer and `detour` removal
  (dns-servers); the preset's servers on the DNS screen (builtin-dns-sets).
- [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md) — the wizard's Tailscale
  form and its fields ([008-NODE_EDITOR · P13](../008-NODE_EDITOR/FEATURE.md#promises)),
  the Network tab's place on the node screens (node-settings,
  subscription-node), the 🕸️ emoji (name-is-tag).
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — the NETWORKS
  pseudo-direction and the state row mapping
  ([012-LIVE_STATE · P19](../012-LIVE_STATE/FEATURE.md#promises),
  networks-direction); the `SubscribeTailscaleStatus` stream.
- [018-WORKSPACES](../018-WORKSPACES/FEATURE.md) — per-slot identities
  ([018-WORKSPACES · P12](../018-WORKSPACES/FEATURE.md#promises)).
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — the
  storage contract row "Tailscale node state: no backup, per slot".
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — the Diagnostics tab
  where the external check is hidden for a node without an exit.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — the coded
  `tailscale_core_unsupported` notification and the core's sign-in link.
- [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.md) — the `with_tailscale`
  build tag and the Tailscale RPC of the core.

## Maintenance notes

- **The DNS rule's `preferred_by` must name the server, not the node.** The
  core resolves `preferred_by` in `dns.rules` among DNS servers; naming the
  node tag makes the core refuse the whole config at start (contract 1.1.90).
- **Never rename a state directory on disk.** The core writes the state file
  through a temporary file in the same directory; a directory renamed under a
  live core loses records. The index moves keys, files stay.
- **A directory is deleted only when the core is stopped**, because the core
  keeps running the config it started with, not the last built one.
- **Do not give the preset's DNS server a preset namespace**: the storage
  record keeps `ref` equal to the tag; with `preset_id` the tag would become
  `tailscale:<tag>-dns` and the rules would point at nothing.
- **A new default preset does not seed itself** on an install whose defaults
  were seeded earlier — it needs the late-seeding list, and the list only
  grows.
- **Only the text without `tailscale` entries** may become the file
  subscription of a multi-node paste; a filtered node list would resurrect the
  node from the cache at startup.
