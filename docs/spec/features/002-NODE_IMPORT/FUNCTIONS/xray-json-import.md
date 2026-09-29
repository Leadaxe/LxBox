[English](xray-json-import.md) · [Русский](xray-json-import.ru.md)

# Xray JSON import

| Field | Value |
|------|----------|
| Feature | [002-NODE_IMPORT](../FEATURE.md) |
| Promises | P4 P8 P9 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Accepts Xray configs in any of four forms — an array of standalone configs
(a typical panel subscription), a full config, a single outbound, an array of
outbounds — and turns their servers into sing-box nodes. One element can hold
several servers, and all of them become nodes.

## Parameters

| Xray `protocol` | Node | Notes |
|-----------------|------|---------|
| `vless`, `vmess`, `trojan`, `shadowsocks` | the same type | `vnext[]` / `servers[]`, `streamSettings` → `tls`/`transport` |
| `hysteria` with `version: 2` | `hysteria2` | the fork's form; `finalmask.quicParams` does not go into the body |
| `hysteria` with `version: 1` | — | no node |
| `wireguard` | endpoint `wireguard` | |
| `http` | `http` | |
| `socks` | — does not become a standalone node | only as a link |
| `freedom`, `blackhole`, `dns`, `loopback` | — service ones | |
| `routing.balancers` + observatory | an auto-select group | the group's meaning — [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md) |

## Inputs / Outputs

**Input:** JSON recognized as Xray ([body recognition](body-recognition.md)).
**Output:** nodes, auto-select groups, rejects with the entry tag. The node
source is the original Xray object verbatim; the "extended source" is the whole element,
with neighbouring sections.

## Rules and invariants

- **Two passes.** The first (draft) goes from single elements to
  multi-node ones: the right to emit a server and give it a name goes to the element with
  a meaningful `remarks`, not to the pool. The second emits nodes strictly in file
  order. Sorting is stable with any number of elements.
- **Name.** The element's `remarks` goes to exactly one entity: the only
  node, or the group if there is one; other nodes get the tag; a repeated tag —
  an index suffix.
- **Dedup** — by node content plus the dial path, across the whole subscription. A different
  SNI, transport, credentials or "direct vs via a relay" — different nodes.
- **Tag synonyms.** Group members written with tags of a neighbouring element
  (`selector: ["proxy"]`) are resolved via the "tag → server" table.
- **`dialerProxy`.** Target is a proxy: the node gets a `detour` chain.
  Target is `freedom` with `settings.fragment`: the node gets `tls.fragment`, not
  a chain. An unreachable target — the node is rejected with code
  `dialer_proxy_unusable`.
- **`finalmask.tcp` with `type: fragment`** → `tls.fragment`.
- **Rejecting an entry:** an unsupported `protocol` → `protocol_unsupported`
  in the rejects (the element neighbour is clean); a `network` the core does not have, and
  header obfuscation `header.type: http` → no node, the code is named.
- Unknown keys inside declared containers → an info code with the full path;
  the `sockopt` subtree stays silent.
- Rejects go only into the source's `dropped[]`, they are not attached to neighbouring nodes.

## Boundaries

- Xray routing, DNS, `inbounds` are not carried over.
- Dedup does not cross subscription boundaries.
- Balancer strategies and their translation into group modes — [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---------|--------|------|
| 1 | [310](../../../tasks/310-xray-array-multi-node-import.md) | implemented | An array element yields all its nodes |
| 2 | [321F](../../../tasks/321F-xray-json-parsing/spec.md) | Implemented | All Xray protocols, name from a single, dedup, synonyms, loss reason |
| 3 | [342](../../../tasks/342-xray-preserve-subscription-order.md) | Released v2.19.2 | Two passes: the author's node order |
| 4 | [404](../../../tasks/404-dialer-proxy-signature.md) | Code complete | Entry signature with the dial path for dedup |
| 5 | [472F](../../../tasks/472F-unified-parse-pipeline/spec.md) | Released v2.25.0 | Xray outbound via the shared pipeline (step 8) |
| 6 | [480F](../../../tasks/480F-registry-driven-mapper/spec.md) | Released v2.25.0 | The Xray mapper — registry sections; a single outbound and an array of outbounds accepted |
| 7 | [488](../../../tasks/488-xray-dialer-proxy-freedom-fragment.md) | Released v2.25.0 | `dialerProxy` → freedom with fragment gives `tls.fragment` |
| 8 | [514](../../../tasks/514-contract-sync-11152.md) | Released v2.25.2 | Rejects by transport and header obfuscation |
| 9 | [560](../../../tasks/560-xray-body-parse-gaps.md) | partial | Gaps in parsing Xray bodies per the corpus |
| 10 | [561](../../../tasks/561-dropped-only-in-source-summary.md) | Done | Rejects only in `dropped[]`, not on the first node |
| 11 | [573](../../../tasks/573-xray-finalmask-tcp-fragment.md) | Released v2.25.7 | `finalmask.tcp` fragment → `tls.fragment` |
