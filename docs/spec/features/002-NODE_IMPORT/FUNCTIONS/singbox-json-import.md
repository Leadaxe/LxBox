[English](singbox-json-import.md) · [Русский](singbox-json-import.ru.md)

# sing-box JSON import — nodes, groups and detour chains from sing-box configs

A sing-box outbound, an array of outbounds, a full config or an array of configs yields the nodes,
groups and `detour` chains its author wrote.

| Field | Value |
|------|----------|
| Feature | [002-NODE_IMPORT](../FEATURE.md) |
| Promises | P4 P8 P9 P16 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Carries nodes over from JSON in core form: a single outbound, an array of outbounds,
a full config, an array of configs. A sing-box user pastes their config
and gets the same nodes, groups and chains.

## Parameters

| Entry type | Result |
|------------|-----------|
| `vless`, `vmess`, `trojan`, `anytls`, `shadowsocks`, `hysteria2`, `naive`, `tuic`, `ssh`, `socks`, `http`, `masque` | a node with a model |
| `wireguard`, `tailscale` (in `outbounds[]` or `endpoints[]`) | an endpoint node |
| `openvpn-client` | a node, the body as written, without checks and warnings |
| a type outside the registry | from an own source — a node with the warning `unknown_node_type`; from a subscription — a reject `protocol_unsupported` |
| `urltest`, `selector` | a group of the same kind; `selector` keeps `default` |
| `direct`, `block`, `dns` | not nodes |

## Inputs / Outputs

**Input:** JSON recognized as sing-box ([body recognition](body-recognition.md));
the "own source" flag. **Output:** nodes (source — the outbound itself verbatim,
extended source — the whole config), groups after their members,
rejects with the entry tag.

## Rules and invariants

- **Name** — the entry's `tag`; empty — `<type>-<host>-<port>`; a repeated tag in the
  config — an index suffix.
- **Two passes and dedup** — as with Xray: the name from a single config, file
  order, one server in two configs under different tags — one node.
- **`detour`.** The chain target is not duplicated as a node, but becomes a link of the
  owner; one target with two owners — a copy for each. Chains of any
  length are unfolded, any type can be a link; deeper than 8 —
  truncated with code `detour_chain_too_deep`. A cycle is broken with code
  `detour_cycle_broken`, nodes do not disappear. A dangling reference —
  `detour_target_missing`; `detour` to a group — `detour_to_group`;
  `detour: direct` is silently ignored.
- **Groups.** Members — exact references to parsed nodes (not regex); members
  written with tags of a neighbouring config are resolved via synonyms; duplicates collapse;
  a nested group drops out of the members with a code; empty members — no group.
  Missing `urltest` parameters get the app's defaults.
- **Only nodes and groups are taken from the config**: `route`, `dns`, `inbounds`,
  `log`, `experimental`, node sections — are dropped.
- **A broken entry** (a garbage field type) → `form_unrecognized` in the rejects,
  neighbours live. A known type with an unusable form (no `server`) is dropped
  rather than becoming a "foreign" node.
- **Authored body** (own server or folder member, a single outbound):
  the registry sets codes but does not change values — the body goes to the core as written.
  A body from a subscription is cleaned by the sanitizer.
- The `tailscale` body is passed as is; exit via a node — by the registry flag
  ([030-TAILSCALE](../../030-TAILSCALE/FUNCTIONS/tailscale-node.md)).

## Boundaries

- Where the result goes (one node → own server, more → file
  subscription) — [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md).
- Checking the `openvpn-client` body and foreign types — the core at start; the build tag
  gate `with_openvpn` — [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md).
- **An OpenVPN `.ovpn` profile is not parsed**: the profile text goes to the link-list
  branch and yields zero nodes. Only a ready
  `openvpn-client` body is accepted.

## Revisions

| # | Revision | Status | Summary |
|---|---------|--------|------|
| 1 | [026F](../../../tasks/026F-parser-v2/spec.md) | Implemented | Parsing a sing-box outbound into the model |
| 2 | [368F](../../../tasks/368F-singbox-config-import/spec.md) | Implemented | Full config: nodes, groups, `detour`, parity with Xray |
| 3 | [437](../../../tasks/437-tailscale-bundle-import.md) | Released v2.24.0 | Tailscale from a multi-node config |
| 4 | [454](../../../tasks/454-tls-certificate-round-trip.md) | Released v2.24.3 | The source of a JSON node is the object verbatim; TLS fields are not lost |
| 5 | [545](../../../tasks/545-singbox-json-entries-through-registry-sanitizer.md) | Done | sing-box nodes are built from the sanitizer map |
| 6 | [575](../../../tasks/575-remove-node-sections.md) | Implemented | Only nodes are taken from a whole config |
| 7 | [576](../../../tasks/576-node-source-is-bare-body.md) | Implemented | The source of an own node is only the node body |
| 8 | [577](../../../tasks/577-authored-json-registry-reports-only.md) | Done | Authored body: the registry reports, does not edit |
| 9 | [582](../../../tasks/582-authored-body-go-dart-parity.md) | Done | Authored body: parity with the launcher |
| 10 | [584F](../../../tasks/584F-openvpn-import/spec.md) | Postponed | `.ovpn` import — there is a spec, not implemented |
| 11 | [585](../../../tasks/585-unknown-node-type-accepted.md) | Implemented | An unknown type is accepted from an own source |
| 12 | [586](../../../tasks/586-endpoint-types-from-registry.md) | Implemented | `endpoints`/`outbounds` sections from the registry; `openvpn-client` is a known type |
