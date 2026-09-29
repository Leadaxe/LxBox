[English](detour-graph.md) · [Русский](detour-graph.ru.md)

# Detour dependency graph

| Field | Value |
|------|----------|
| Feature | [006-DETOUR_AND_BALANCE](../FEATURE.md) |
| Promises | P6 P15 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Looks at the "who through whom" links as a whole: a node's `detour`, a group
member, a chain position. Before start it fixes what the core would reject
(rings, dangling references, ghosts in groups) and reports the fix as a
warning; an unresolvable ring is shown with its culprits. On a running
tunnel it shows a node's live path and flags dead nodes that others rely
on.

## Parameters

No knobs of its own. The culprit cap in a fatal is 3; the live path cap is
12 hops.

## Inputs / Outputs

**Inputs:** the built config; group selections of the running core; latency
measurements.
**Outputs:** the fixed config + warning lines; fatal "Routing loop — VPN not
started"; ⚠ on a node; a banner on the main screen for DNS; the Overview
and Dependents tabs in the node window.

## Rules and invariants

Build fixes (repeated to a fixpoint):

| Case | Outcome |
|---|---|
| `detour` in a node body pointing to a non-existent tag | key removed, the node goes direct; one line per target (first five names + counter) |
| a group member does not exist | excluded; an emptied Direction → `[block, direct-out]`, any other group drops out |
| a group's `default` outside the membership | the first member, a warning |
| a node with `detour` to a group it belongs to | out of the membership (and of `<tag>-auto`), detour kept; one line per node |
| any other ring | the closing edge is broken: `detour` removed ("the node dials directly") or the member excluded |
| detour nodes into a Direction that went to block | detour kept, a separate warning "…which is now blocked — their traffic is blocked too" |

- Fatal (P6) — only if a ring remains: the start is cancelled, the "Routing
  loop — VPN not started" sheet lists up to three culprit nodes ("detour →
  X"), "Show loop" expands the cycle, tapping a node leads to its source;
  "More loops may remain — fix these and try again.". A ring made of groups
  only is shown without culprits.
- A ring in a folder is caught already when a personal detour is chosen
  (see [node-detour.md](node-detour.md)); a ring of user detour references —
  by dropping its participants (P1).
- Live path (Overview): "Live path in packet order. Tap a hop to open its
  source." — by the `detour` of the built config and the current group
  selections; it breaks off at a group with no selection ("connect to see
  the full path"); `round_robin` has no selected node — the path breaks off
  at the group.
- Dead supports (P15): a node is `dead` if all its measurements are −1 (at
  least one live — `alive`, no measurements — `unknown`). Sickness
  propagates upward: a selector where a dead node is selected; a `urltest` —
  only when its whole membership is dead; then everyone with a `detour` to
  the sick one. ⚠ — only on a root with dependents; the Dependents tab lists
  "These route through this node:", DNS victims on top. The banner on the
  main screen — only when a DNS server is sick. Recalculation — on new
  measurements and on selection change.
- No background probes and no changing of group selections for the sake of a
  fix.

## Boundaries

- Rings and dangling references of DNS groups and DNS detour — [005-DNS](../../005-DNS/FEATURE.md).
- The pre-start check in general and the "Settings changed" banner —
  [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md).
- The detour tail of live connections — [012-LIVE_STATE](../../012-LIVE_STATE/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [141](../../../tasks/141-deep-code-audit-hardening.md) | In progress | Detour cycle check before start |
| 2 | [172](../../../tasks/172-heal-dangling-detour.md) | Implemented | A dangling detour is removed, the config does not fail |
| 3 | [248F](../../../tasks/248F-detour-channels/spec.md) | IMPLEMENTED | Rings through a layer (edge strip, replaced) |
| 4 | [254](../../../tasks/254-detour-cycle-fatal-detector.md) | AGREED | Fatal with a minimal set of culprits |
| 5 | [258](../../../tasks/258-outbound-view-tabs-runtime-chain.md) | done | Live path on the Overview tab |
| 6 | [355](../../../tasks/355-detour-dependency-health-warnings.md) | DEVICE-VERIFIED | ⚠ of a dead support, Dependents, DNS banner |
| 7 | [377](../../../tasks/377-detour-removed-warning-aggregation.md) | Done | Aggregation of "detour removed" |
| 8 | [393F](../../../tasks/393F-directions/spec.md) | released v2.21.0 | A4: graph sanitizer before fatal |
