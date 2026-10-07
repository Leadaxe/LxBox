[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Detour and balancing — detour servers, hop chains and load balancing for VPN nodes

LxBox sends a VPN node's traffic through another server, a multi-hop chain
or a pool with auto-select and load balancing, all set up without editing
JSON. The feature covers personal detours, provider jump servers (Xray
`dialerProxy`, sing-box `detour`), Directions used as a switchable upstream,
hop chains built by the sing-box-lx core and `urltest` groups in Fastest or
round-robin mode. The config build checks every link, so the core accepts
the result and a broken reference never becomes a direct connection.

| Field | Value |
|------|----------|
| Feature | 006-DETOUR_AND_BALANCE |
| Type | Product feature |
| Absorbed | `§018F` (detour servers, jump servers, chains), `§024F` (Load Balance — implemented as the `round_robin` mode of auto-select, there is no separate outbound), `§248F` (Direction as a detour layer), `§322F` (auto-select node in a folder/subscription) |
| State | ✅ written from code, 2026-09-28 |

## Purpose

Answers the question "how does a node reach the network":
directly, through another server (detour), through a switchable
Direction layer, through a chain of several hops, through a pool of nodes
with auto-select or balancing. The user assembles multi-hop routes without
editing JSON, and the build guarantees that the core accepts a config with
such links.

Principles the feature protects:

- **A reference to a hop never silently turns into a direct connection.** A
  node whose detour reference did not resolve does not get into the config;
  a chain without a hop is a different route, so it drops out entirely
  instead of being shortened at build time.
- **Links do not bring down the whole config.** Rings and dangling
  references are fixed by the build by degrading one element with a
  warning; a ring that cannot be untangled is the only case where the start
  is cancelled, and the user sees the culprits.
- **Order reads unambiguously.** Chain positions are in packet order (the
  first is closer to the phone); the detour path preview too — "Phone → … →
  Internet".

Out of the box: no node has a detour, there are no Directions with "Use as
detour", no chains; native detour chains of subscriptions work, their links
are hidden from node selection.

## Promises

- **P1. An unresolved detour reference gives no direct exit.** A user
  reference (a personal detour, a source detour) to a node that does not
  exist, is disabled, points to itself or into a ring of references → the
  carrier drops out of the config with a warning, and so, in a cascade, do
  those that went through it. **Witness:** units "node not in the container —
  the detour carrier is not emitted", "disabled member — same outcome",
  "detour to itself — the carrier drops out", "cascade: the target dropped —
  the one going through it drops too". **Mutation:** remove the `detour` key
  and keep the node.
- **P2. Append vs Replace.** "Fill missing" (the default) keeps the node's
  native chain and appends the chosen outbound as the tail; "Replace all"
  discards the native chain; "Don't use detour servers" removes detour and
  wins over the chosen outbound. **Witness:** units "append (default):
  main.detour = override (1-hop)", "replace (explicit toggle)",
  "useDetourServers=false + override → no detour". **Mutation:** the
  override is written into `main`, wiping out the native link.
- **P3.** moved to [026-DIRECTIONS · P18](../026-DIRECTIONS/FEATURE.md#promises)
- **P4.** moved to [026-DIRECTIONS · P19](../026-DIRECTIONS/FEATURE.md#promises)
- **P5.** moved to [026-DIRECTIONS · P20](../026-DIRECTIONS/FEATURE.md#promises)
- **P6. Rings are fixed by the build, fatal is the last resort.** A node with a
  detour to a group it belongs to is excluded from the group's membership
  (detour kept); any other ring is broken at the closing edge with a
  warning. An untangled ring — fatal "Routing loop — VPN not started" with
  at most three culprits. **Witness:** units "direct cycle: member.detour=C →
  member out of the membership, detour intact", "transitive cycle — ONE edge
  is broken", "§254 — cycle through a selector: 1 culprit", "cap: show no
  more than … culprits". **Mutation:** break all edges of the ring.
- **P7. A chain is a `type: chain` node in packet order.** Positions go out
  verbatim in the `outbounds` key; `idle_timeout`, `strip_evasion`, `strip`,
  `rewrite` are written only when set; the chain gets into the Direction
  pool on a par with servers. **Witness:** units "hop order = PACKET order",
  "defaults are not written into the config", "a chain is a node: the
  Direction filter catches it". **Mutation:** sorting or deduplicating
  positions.
- **P8. An invalid chain drops out entirely, the config is built.** Fewer
  than two positions, empty/repeated/self-reference, a position pointing
  nowhere, a reference to a chain lower in the list, a nested chain not in
  the first position, an occupied tag, a core older than
  `1.14.0-lx.27-rc.5` → no chain, a warning, the rest is built.
  **Witness:** units "a position pointing nowhere drops the CHAIN", "a FORWARD
  reference drops the chain", "a nested chain at position ≥1 drops the
  chain", "tag collision with a Direction", "old core: chain not emitted,
  the rest is built". **Mutation:** skip one position.
- **P9. A Direction does not take a chain that goes through it.** Including
  transitively through a nested chain; in another Direction the same chain
  stays. **Witness:** units "direct case [proxy-out, exit]",
  "TRANSITIVELY", "the same chain enters ANOTHER Direction".
  **Mutation:** an "all nodes" filter without subtraction.
- **P10. Deleting a source shortens a chain, it does not delete it.** A
  position pointing to a deleted server/member/subscription/Direction/chain
  is removed, a counter is shown; a chain with <2 positions stays in the
  list but is not built; a subscription update does not touch positions.
  **Witness:** units "a 3-hop chain after heal is emitted SHORTENED + counter",
  "a 2-hop chain after heal stays but is not emitted", "BOUNDARY: a
  subscription update does NOT clean positions". **Mutation:** cascading
  deletion of the chain.
- **P11. The chain editor does not allow saving what the core will reject.**
  Blocking: <2 positions, an empty position, self-reference, a repeat, a
  nested chain not in first position, a reference to a chain below,
  empty/occupied name. Not blocking: lost positions, detour on the entry,
  WireGuard behind a TCP hop, MASQUE h3 on a link. **Witness:** units "core
  invariants — blocking", "detour of position 0 — WARNING, does not prevent
  saving". **Mutation:** saving with a blocking finding.
- **P12. A group is never a detour target and has no detour.** Auto-select
  nodes are not offered in the detour picker; they have no Detour block.
  **Witness:** manual check — a folder with an auto-select node, the detour
  picker of a folder member does not show it. **Witness:** unit "a group node
  is not shown among standalone servers or folder members"
  (`test/widgets/detour_target_picker_group_excluded_test.dart`).
  **Mutation:** a group in a picker section.
- **P13. Balancing is an auto-select mode.** "Load balance" gives
  `mode: round_robin` and `balancer{pool, pool_tolerance, sticky_hash}`; an
  empty sticky set → `["none"]`; "Fastest" writes neither `mode` nor
  `balancer`. **Witness:** units "leastTest → NO mode/balancer", "round_robin
  → mode + balancer", "empty stickyHash → ["none"]". **Mutation:** `balancer`
  without `round_robin` — the core does not start.
- **P14. An auto-select node does not break start.** An empty pool → the node
  is not emitted; it is in the Direction's selector, not in `<tag>-auto`; it
  does not take another group into its pool. **Witness:** units "empty pool →
  group NOT emitted", "the group gets into the selector but not into ✨auto",
  "a group does not take another group into its pool". **Mutation:** an
  empty `urltest` in the config.
- **P15. A dead support is flagged.** A node with only −1 measurements that
  nodes or DNS servers transitively depend on gets ⚠; a `urltest` is sick
  only when its whole membership is dead. **Witness:** units "incident
  repro", "a urltest Direction is not sick by choice". **Mutation:** ⚠ on any
  dead node.
- **P16. Per-layer chain probe — only with the VPN up.** Layer k with an
  error → the following ones are "not reached" and are not probed.
  **Witness:** units "VPN off → vpn_down", "layer k with an error → k+1.. not
  reached". **Mutation:** probing with a synthetic config.

## Controlled parameters

| Where | Knob | Values | Default | Core key |
|---|---|---|---|---|
| Node (server, folder member) | Detour server | None · member of its own folder · detour Direction · free server | None | `detour` |
| Subscription / folder | Detour servers (mode) | Use … own detours · Add detour · Don't use | Use | `detour` of links |
| ↳ Add detour | Outbound + Replace all / Fill missing | reference · mode | — · Fill missing | `detour` of the tail |
| ↳ Use / Fill missing | Register detour servers / in auto group | on/off | off/off | links in `selector` / `<tag>-auto` |
| Direction | Use as detour | on/off (hidden for `vpn-1`) | off | — |
| Direction | Include auto (urltest): Mode | Fastest · Load balance | Fastest | `urltest.mode` |
| Auto-select (Direction, node, fold) | Pool size / Pool tolerance / Sticky session by | ≥1 / ms, 0 = the whole live pool / process, domain, source ip, dest ip, dest port | 3 / 0 / process+domain | `balancer{…}` |
| same | Test URL / Interval / Tolerance / Idle timeout / Interrupt | — | cp.cloudflare.com/generate_204 / 15m / 50 / 30m / off | `url` … `interrupt_exist_connections` |
| Auto-select node | Members: All · Rule (Include/Exclude regex) · Pick; Mode: Fastest · Load balance · Manual; Badge in list (regex) | — | All · Fastest · flag emoji | `urltest` / `selector` + `default` |
| Subscription / folder | Replace with a group: Manual · Auto · Both, Group name | — | not folded | `selector` / `urltest` |
| Chain | Tag (`chain-N`), Enabled | — | first free, empty, on | `tag` |
| Chain | Positions | ≥2, in packet order | — | `outbounds` |
| Chain → Advanced | Idle timeout · Strip evasion tricks from links · Per-key overrides (three-state) | empty = core (5m) · on · untouched | — | `idle_timeout`, `strip_evasion`, `strip` |
| Chain | rewrite | JSON merge-patch by node type, not editable in the form | `{}` | `rewrite` |

The catalog of `strip` keys and their defaults is contract registry data,
not application data. The minimum core version for chains is
`1.14.0-lx.27-rc.5`.

## Inputs / Outputs

**Inputs:** nodes of subscriptions, folders, standalone servers (including
native detour links from Xray `dialerProxy` and sing-box `detour`); Xray
`balancers` + `burstObservatory`; the list of Directions; the list of
chains; the core version; group selections and latency measurements of the
running core.

**Outputs:** `detour` on outbounds/endpoints; `selector`/`urltest` with
`balancer{}`; outbounds of `type: chain`; build warnings; fatal "Routing
loop"; ⚠ on dead supports and a banner for DNS; the path preview "Phone → …
→ Internet"; the live path and per-layer probe on the node screen;
notifications about healed references.

## Data flow

```
sources ─► nodes get final tags ─► reference dictionary
   │  (native chain + source policy: Use / Fill missing / Replace all / none)
   ▼
second reference pass: detour → final tag | carrier dropped (cascade)
   ▼
chains in list order: core gate → invariants → tag → positions → nesting
   ▼
Directions: filter → minus chains through itself → selector + <tag>-auto
   ▼
graph sanitizer: dangling / ghosts / default / rings (to a fixpoint)
   ▼
pre-start check: a ring remains → fatal with culprits
   ▼
core ─► group selections + measurements ─► dependency graph ─► ⚠ / banner
```

## Rules and guarantees

- A node reference is stored as an address `{folder_id?, tag}` (contract
  439); only the build computes the final tag. Storing references, renaming
  and deleting them — [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md).
- The detour picker: free servers — always; members of its own folder —
  only in the folder context; other folders and subscription nodes — never;
  groups — never.
- `detour: direct-out` is not offered: a direct exit is "None".
- A Direction with the same name as a folder member is hidden in that
  folder's picker: the value is read as the member.
- Under a build detour the node body yields: `tls.fragment` is removed
  (with the orphaned pause), WireGuard `listen_port` is removed.
- Chains reference only chains above them in the list — cycles between them
  are impossible by construction.
- Detour through WireGuard/AmneziaWG is not forbidden (the former
  prohibition was lifted together with the core's protection).

## Boundaries

- The Direction model — tags, membership filter, `route.final`, healing of
  rule references, the detour layer itself — [026-DIRECTIONS](../026-DIRECTIONS/FEATURE.md);
  rules that target a Direction — [004-ROUTING](../004-ROUTING/FEATURE.md).
  Here a Direction is only an exit for detour and an auto-select pool.
- Node settings in general (protocol, tag, JSON) — [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md).
- A DNS server's channel through a Direction — [005-DNS](../005-DNS/FEATURE.md).
- The main screen filter "Hide detour servers / Show only detour servers",
  node selection in a group, pool badges — [007-NODE_LIST](../007-NODE_LIST/FEATURE.md).
- The detour tail in the connection list — [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md).
- Runtime on/off of a chain position and the state of core links
  (`SetChainPositionEnabled`, `GetChainCloneConfig`) are not used by the
  application.
- There is no separate `loadbalance` outbound; the "consistent hashing" and
  "sticky sessions" strategies are expressed by the `sticky_hash` set.
- Not planned (owner decision 2026-09-29, audit [591](../../tasks/591-spec-kit-revision-audit.md)): the "AWG → channel with WireGuard"
  warning (`248F`) — a detour through WireGuard/AmneziaWG is allowed without it.

## Functions

| Function | What it does | Promises | File |
|---|---|---|---|
| Node detour | Routes a server or folder member through another server first, with a target picker, a path preview and fail-closed handling of broken references. | P1 P12 | [node-detour.md](FUNCTIONS/node-detour.md) |
| Source detour and jump servers | Sets one detour policy for a whole subscription or folder (Use, Add detour with Fill missing or Replace all, Don't use) and decides whether provider chain links are shown as nodes. | P2 | [source-detour-policy.md](FUNCTIONS/source-detour-policy.md) |
| Hop chains | Builds a multi-hop route as a `type: chain` outbound in packet order, drops an invalid chain whole and shortens a chain when one of its sources is deleted. | P7 P8 P9 P10 | [hop-chains.md](FUNCTIONS/hop-chains.md) |
| Chain editor | Edits a hop chain in a form with a position picker and save-blocking checks, and measures each hop with a per-layer probe. | P11 P16 | [chain-editor.md](FUNCTIONS/chain-editor.md) |
| Detour dependency graph | Repairs loops and dangling references before start, cancels the start with named culprits when a loop cannot be broken, and flags dead nodes that others route through. | P6 P15 | [detour-graph.md](FUNCTIONS/detour-graph.md) |
| Auto-select and balancing | Adds auto-select groups (`<tag>-auto`, an auto-select node, "Replace with a group") that keep the fastest node or balance load across a pool. | P13 P14 | [balancing.md](FUNCTIONS/balancing.md) |

Direction as a detour layer moved to [026-DIRECTIONS](../026-DIRECTIONS/FEATURE.md) (as "Direction as a detour layer").

## Related features

- [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md) — parsing native detour links (`dialerProxy`, `detour`) from a subscription.
- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — the pre-start check and the "Settings changed" banner that the graph sanitizer is built into.
- [026-DIRECTIONS](../026-DIRECTIONS/FEATURE.md) — the Direction model and the detour layer (⚙, healing of detour references); here a Direction is a detour exit and an auto-select pool.
- [004-ROUTING](../004-ROUTING/FEATURE.md) — rules that send traffic to a Direction.
- [005-DNS](../005-DNS/FEATURE.md) — a DNS server's channel through a Direction, DNS group rings, DNS victims of dead supports.
- [007-NODE_LIST](../007-NODE_LIST/FEATURE.md) — the detour server filter on the main screen, node selection in a group, pool badges.
- [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md) — the other node settings that host the Detour block.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — measurements and ping settings for auto-select, dead supports and the per-layer probe.
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — the detour tail in the connection list.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — storing detour references, renaming and deleting them, chains in the backup.

## Maintenance notes

- The arrows point in opposite directions: `detour` reads "the node goes
  through whom", a chain reads "in what order the packet travels". A mixed-up order gives a
  working but wrong route — noticeable only by the exit country.
- Healing references to a Direction must be mirrored in the in-memory source
  list, otherwise the next save resurrects the healed reference.
- Owner's decision 2026-09-29 (audit 591 · 36): one failure mode for a
  dangling detour — fail-closed. Today a `detour` in a node body pointing at a
  missing tag and a loop broken by the sanitizer send the node direct
  (fail-open); that is a divergence from P1, closed by a task (audit 591).
