[English](build-pipeline.md) · [Русский](build-pipeline.ru.md)

# Build pipeline — fixed stages from settings to the final sing-box JSON

Every rebuild runs the same fixed sequence of stages: variables, skeleton, nodes, groups, rules,
post-steps, healing and the check.

| Field | Value |
|------|----------|
| Feature | [003-CONFIG_BUILD](../FEATURE.md) |
| Promises | P8 P13 |
| State | ✅ written from code, 2026-09-28 |

## What it does

A single point that makes the final JSON for the core from the template, node sources and all
settings. All launch paths (return to the main screen, a tap
on the banner, Start, cold launch, reaction to a subscription update, Debug
API) go through it. The stages are fixed in order: each next one
sees the result of the previous one, and healing comes after everything that can
produce a broken reference.

## Parameters

No knobs of its own. Stage order:

| # | Stage | What happens |
|---|---|---|
| 1 | Variables | Template defaults ← user values; empty required and out-of-bounds → default; VPN mode and proxy parameters — by direct assignment over the saved ones |
| 2 | Skeleton | A copy of the template `config`, substitution of `@var` and conditions (inbounds by mode, TUN addresses) |
| 3 | Nodes | Emission of source nodes, unique tags; Direction tags (including disabled ones) are reserved — a namesake gets a `-N` suffix |
| 4 | Detour references | Node-to-node references — into final tags; an unresolved one — the carrier drops out (fail-closed) |
| 5 | Core registry gate | Node bodies are cleaned by the contract schema and the core version/tags; an unacceptable entry is removed |
| 6 | Folds and chains | A fold source → a group; chains → nodes with the core capability gate |
| 7 | Direction groups | Selectors and `-auto` twins; Tailscale gets `state_directory` |
| 8 | Rules | Normalizing the order axis (`traffic-processing` first), expanding presets (including `for_each`) and user rules → `route.rule_set`, `route.rules` |
| 9 | Tunnel sleep | `lx.wg.*` when a threshold is set |
| 10 | `route.final` | A target not among the emitted ones → `vpn-1` with a warning; rules to an empty fold → to `route.final` or removed |
| 11 | Post-steps | Concessions to an assembled `detour` (WireGuard port, `tls.fragment`); TLS transformations; the DNS section; split tunneling packages (the last tun transform) |
| 12 | Healing | Migrating preset tags into the namespace; `resolve` to a missing DNS server — `server` removed; broken `dns.final`/resolver → template default (saved); legacy `strategy` of DNS rules removed; unknown uTLS fingerprint → `chrome`; broken REALITY — `short_id` cleared or the block removed |
| 13 | Graph sanitizer | A dangling detour removed (one line per target), ghost group members excluded, a `default` outside the members fixed, rings broken at the minimal edge; urltest timings corrected |
| 14 | Check | [Final config check](config-validation.md) |

## Inputs / Outputs

**Inputs:** see the feature. The core version and its build tags affect the gates of stages
5–6; an empty version — fail-open (chains are emitted).
**Outputs:** JSON; warnings (template codes first, then degradation
lines); values fixed by the build, to be saved; the
"final tag → source node" map; the list of Directions left without nodes
(a transient snackbar); the map of node warnings by tag.

## Rules and invariants

- A config built from the same inputs has the same composition, except for
  random fields that the setting itself randomizes (mixed-case SNI).
- Healing never changes the user's choice in storage, except for explicitly
  returned values (DNS resolver defaults) — a broken reference is fixed
  in the config, and if the target comes back, the reference comes back too.
- A node removed at any stage gets neither into Direction pools, nor into
  `for_each`, nor into the tag map.
- The registry only comments on a node's authored JSON, it does not edit it (except for what
  the core will not start without).
- One rebuild at a time: a second trigger joins the current one; the VPN
  start awaits the current one and, with unwritten changes, starts its own.
- A config pinned via the Debug API is not overwritten by a rebuild.

## Boundaries

- Details of stages 3–7 — [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md),
  [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md); stage 8 — [004-ROUTING](../../004-ROUTING/FEATURE.md);
  DNS in stages 11–12 — [005-DNS](../../005-DNS/FEATURE.md); TLS transformations —
  [016-DPI_HARDENING](../../016-DPI_HARDENING/FEATURE.md); `lx.wg.*` —
  [010-VPN_SERVICE](../../010-VPN_SERVICE/FEATURE.md).
- Body schema and registry codes — [021-CORE_CONTRACT](../../021-CORE_CONTRACT/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [026F](../../../tasks/026F-parser-v2/spec.md) | Implemented | The single build point, stages and check |
| 2 | [119F](../../../tasks/119F-vpn-mode/spec.md) | Implemented | Inbounds by mode — declaratively in the template |
| 3 | [172](../../../tasks/172-heal-dangling-detour.md) | Implemented | A broken detour — degradation instead of fatal |
| 4 | [247](../../../tasks/247-custom-rule-resolve-action.md) | — | `resolve` to a missing DNS server is healed |
| 5 | [281](../../../tasks/281-utls-fingerprint-normalize.md) | Implemented | Unknown uTLS fingerprint → `chrome` |
| 6 | [343](../../../tasks/343-reality-short-id-validation.md) | Released v2.19.2 | A broken REALITY does not bring down the whole config |
| 7 | [351](../../../tasks/351-channel-tags-reserved-in-allocator.md) | — | Direction tags are reserved when tags are allocated |
| 8 | [377](../../../tasks/377-detour-removed-warning-aggregation.md) | Done | One warning line per missing target |
| 9 | [393F](../../../tasks/393F-directions/spec.md) | — | Graph sanitizer before the check |
| 10 | [419](../../../tasks/419-dangling-dns-resolver-heal-in-build.md) | Done | A broken DNS resolver is healed in the build, the value is saved |
| 11 | [574](../../../tasks/574-tls-fragment-yields-to-detour.md) | Released v2.25.7 | `tls.fragment` yields to an assembled `detour` |
| 12 | [577](../../../tasks/577-authored-json-registry-reports-only.md) | Done | Authored JSON: the registry reports, does not edit |
| 13 | [578](../../../tasks/578-tailscale-preset-template-for-each.md) | Spec. Implementation started | Nodes for `for_each` — after all gates |
