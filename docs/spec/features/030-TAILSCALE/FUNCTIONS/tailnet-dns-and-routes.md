[English](tailnet-dns-and-routes.md) · [Русский](tailnet-dns-and-routes.ru.md)

# Tailnet DNS and routes — the `tailscale` preset and the MagicDNS server per node

The "Tailscale networks" preset repeats its records for every Tailscale node
in the config: a route into the node's tailnet by `preferred_by`, a MagicDNS
server bound to the node and a DNS rule for it; a node opts out with "Skip
presets".

| Field | Value |
|-------|-------|
| Feature | [030-TAILSCALE](../FEATURE.md) |
| Promises | P12–P18 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Gives a Tailscale node the records it is useless without — the route into
its tailnet and the resolver for tailnet names — from the template preset
rather than from the node. The preset is on by default, reaches existing
users once, serves subscription nodes too, and its DNS half is a switch. The
DNS server form also offers the `tailscale` server type for a hand-made
MagicDNS server bound to a node.

## Parameters

| What | Value |
|------|-------|
| Preset `tailscale` ("Tailscale networks") | on by default, `num` 945, sortable; `for_each` over `node_type: tailscale` with `filter: not skip_presets`; variable "DNS" (`dns_enable`, on) |
| Records per node | `route.rules`: `{preferred_by: [<node>], action: resolve, server: <node>-dns}` then `{preferred_by: [<node>], outbound: <node>}`; `dns.servers`: `{type: tailscale, tag: <node>-dns, endpoint: <node>, description: "MagicDNS of the tailnet"}`; `dns.rules`: `{preferred_by: [<node>-dns], server: <node>-dns}` |
| `dns_enable` off | only the route rule |
| Record field `skip_presets` | own server and folder member; only `true` is stored; subscription node — always served |
| "Skip presets" switch | on the node screen; visible when the template has a `for_each` preset for the node type |
| DNS server type `tailscale` | `endpoint` — a Tailscale node (required), `accept_default_resolvers`; no address, no `detour` |
| Late seeding | the list of late default presets (`tailscale`); the ids already seeded are remembered |

## Inputs / Outputs

**Inputs:** the template's preset; the emitted Tailscale nodes after all
gates, in config order; `skip_presets` of the records; the preset's variable
values; the sources for the screens (routing, DNS, the DNS server form).

**Outputs:** the route rules at position 945, the DNS servers and rules; the
preset row caption on the Routing and DNS screens — the served node tags or
"No matching nodes"; the preset's servers on the DNS screen; the options of
the `endpoint` picker.

## Rules and invariants

- **`for_each` expands after the node set is final** (P12, P13): a node
  disabled, removed by the registry gate, the core gate or degradation is not
  served; the order of repeats is the config order; no nodes — the preset
  emits nothing and the config is byte for byte the previous one (P14). The
  probe config does not expand presets.
- **The DNS rule names the server**, not the node: the core looks
  `preferred_by` up among DNS servers in `dns.rules` and among outbounds in
  `route.rules`.
- **Tags get no preset namespace**: the server stays `<node>-dns`; the storage
  record of such a server keeps `ref` equal to the tag. A user server with the
  same tag — first wins, a warning.
- **The `resolve` action before the route rule** closes FakeIP: without it a
  UDP flow to the endpoint has no addresses and the core refuses to route it.
- **Late seeding** (P16): on an install with seeded defaults the preset is
  added once, enabled, at the template's position, before the build reads
  the rules and on the Routing screen; a deleted preset does not return; a
  fresh install seeds it with the other defaults.
- **`skip_presets`** (P17): written only as `true`; the backup carries it and
  an import matched by body does not reset it; the Debug API shows it
  read-only. The switch marks the config dirty.
- **The screens' node list** uses the same selection as the build minus the
  gates (enabled sources, members and subscription nodes; `skip_presets`),
  with the final tag of the last build when the node was in it, otherwise the
  display tag; before a build the caption may name a node the build will
  drop.
- **The `endpoint` picker** (P18) lists enabled Tailscale nodes of all
  sources, one option per tag; a value outside the list (JSON tab, deleted
  node) is shown first. Saving a `tailscale` server without a node —
  "Tailscale node is required", no save. A dangling `endpoint` or a second
  server on the same node is dropped at build with a warning; `detour` is
  removed ([005-DNS](../../005-DNS/FEATURE.md)).

## Boundaries

- The template language (`for_each`, `@node`, `#tpl`) and an incomplete
  `for_each` removing only its preset — [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md);
  preset editing, positions and seeding in general —
  [004-ROUTING](../../004-ROUTING/FEATURE.md).
- No fixed subnets (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) and no `.ts.net`
  suffix in the preset: the route is the live `preferred_by` condition
  (launcher decision D-120). Until the tailnet is up the rule does not match.
- Two nodes in one tailnet: the first in config order wins.
- A bundle edited by hand in the former node sections was lost with §575.
- The same preset for WireGuard is not made.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [435](../../../tasks/435-node-sections-tailscale.md) | Cancelled, replaced by §575/§578 | Bundle v1 in node sections: `100.64.0.0/10`, DNS server, `.ts.net` rule |
| 2 | [437](../../../tasks/437-tailscale-bundle-import.md) | Released v2.24.0 | Bundle v2: `domain_suffix`, both CIDRs, `resolve` before the route (FakeIP) |
| 3 | [443](../../../tasks/443-contract-1-0-2-spec129.md) | Released v2.24.0 | The dangling-`endpoint` sanitizer of `tailscale` DNS servers kept as is |
| 4 | [575](../../../tasks/575-remove-node-sections.md) | Implemented (phases 1–3) | Node sections abolished; the `endpoint` picker moved to the preset node list |
| 5 | [578](../../../tasks/578-tailscale-preset-template-for-each.md) | Spec, implementation started | The `tailscale` preset with `for_each`, `skip_presets`, late seeding, DNS rule names the server |
