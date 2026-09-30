[English](tailscale-node.md) · [Русский](tailscale-node.ru.md)

# Tailscale node — a tailnet endpoint from the wizard or sing-box JSON

A Tailscale node is a `tailscale` endpoint of the core: it has no address, its
body is stored as is, and it reaches the config only on a core built with
`with_tailscale`.

| Field | Value |
|-------|-------|
| Feature | [030-TAILSCALE](../FEATURE.md) |
| Promises | P1–P5, P11 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Creates a Tailscale node from the "Add server → Tailscale" form or from pasted
sing-box JSON, keeps it as a body with a `tag` (there is no share link for
this type), emits it into `endpoints[]`, drops it with a coded warning when the
core cannot run it, and decides whether it may be a Direction: only a node
with `exit_node` reaches the internet, so only such a node is offered in the
Direction lists.

## Parameters

| What | Value |
|------|-------|
| Wizard fields | Tag (optional, empty → `tailscale`, emoji 🕸️ added), Auth key (required, masked), Control URL, Hostname (prefilled `LxBox-<model>`), Ephemeral, Accept routes, Exit node |
| Body written by the wizard | `auth_key` plus only the filled fields; booleans only as `true` |
| Body from JSON | as is, minus `type`, `tag`, `detour`; unknown keys kept with the `json_field_unknown` code |
| Registry checks | `exit_node` conflicts with `advertise_exit_node`; `exit_node_allow_lan_access` requires `exit_node`; a default route in `advertise_routes` is dropped with `tailscale_default_route_advertised` |
| Core gate | build tag `with_tailscale`; missing → the node is dropped with `tailscale_core_unsupported` |
| Direction candidate | `exit_capable_when: any_set [exit_node]` |

## Inputs / Outputs

**Inputs:** the form; a single body, a whole config, an array of configs or an
outbound array; a subscription body; the core's build tags.

**Outputs:** an own server (or a folder member, a subscription node) whose
title is the tag; the `endpoints[]` entry; the coded warning on the node when
the core lacks the tag; the wizard's hints under Auth key ("A one-time key is
consumed on the first login…") and under Exit node (pick the node as the
Direction to route the internet through it).

## Rules and invariants

- **A tailscale entry is an endpoint wherever it came from**: `outbounds[]`
  and `endpoints[]` are both accepted, the registry's `kind` puts the node
  into `endpoints[]` at emission (P1). The share form of the node is the
  compact JSON of the body with `tag`, and it parses back as a single
  outbound.
- **No bundle travels with the node** (P2): the wizard writes a bare body; a
  config pasted with the node loses its `route`/`dns` blocks like any config;
  the tailnet route and DNS come from the preset
  ([tailnet-dns-and-routes.md](tailnet-dns-and-routes.md)).
- **A multi-node paste is split** (P5): every Tailscale entry becomes its own
  server; the rest of the text, with the Tailscale entries cut out, goes the
  usual way — one node → a server, several → a file subscription. A
  remainder that holds only groups is not an error when Tailscale nodes were
  added. An empty `endpoints` left after the cut is removed.
- **The core gate drops the node, never the config** (P3): the node stays in
  storage and comes back after a core update; the warning is shown on the
  node with the reason and the fix.
- **Without `exit_node` the node is not a Direction candidate** under any
  detour policy (P4); it is still a legal `detour` target, a chain link and a
  rule target, and it appears on the home screen under NETWORKS
  ([012-LIVE_STATE](../../012-LIVE_STATE/FEATURE.md)).
- **The default hostname** `LxBox-<model>` is only the initial value of the
  form field (P11): the user may edit or erase it; an erased field writes no
  `hostname`, and the core takes the system host name. Uniqueness is not
  checked — a second device of the same model gets a `-1` suffix from
  Tailscale. The hostname of a device that already signed in does not change
  by editing the body: the identity lives in the state directory.
- Node rows and pickers show the type only, without `:0`; the node screen says
  "No address (Tailscale)"; the node is not probed and the row shows "—".
- With the VPN on, the row of a node with an exit node reads
  `tailscale·via <device>`. When that device is offline, `exit offline`
  (orange) takes the place of the endpoint state; a node turned off by hand
  keeps `off`. Direct vs relay is not shown: the core's status has no path,
  only the device check in the Network tab knows it.
- Less than 7 days before the device key expires, the row warns
  `key expires Nd` / `key expires <1d` / `key expired` (orange): on a node
  with an exit — in the endpoint-state slot, below `exit offline`; on a
  NETWORKS row — instead of `running` only. `keyExpiry == 0` (expiry off in
  the admin console) — no label.
- Editing a subscription node is not possible; a Tailscale node inside a URL
  subscription is served by the preset like any other.

## Boundaries

- Parsing of the four sing-box JSON shapes and the registry-driven field
  checks — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md); the wizard
  itself — [008-NODE_EDITOR](../../008-NODE_EDITOR/FEATURE.md).
- Sign-in without an auth key (an interactive link) is the core's own
  notification — [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FEATURE.md).
- The probe skips the node (`no witness`).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [435](../../../tasks/435-node-sections-tailscale.md) | Cancelled, replaced by §575/§578 | The Tailscale node, the wizard form, the core gate, no Direction without an exit |
| 2 | [437](../../../tasks/437-tailscale-bundle-import.md) | Released v2.24.0 | Tailscale nodes split out of a multi-node paste; the Exit node hint |
| 3 | [449](../../../tasks/449-tailscale-default-hostname.md) | Implemented, no device-verify | Default hostname `LxBox-<model>` |
| 4 | [474](../../../tasks/474-contract-116-conflicts-declarant-advisory-bool-dialer.md) | — | Registry: `exit_node` vs `advertise_exit_node` conflict |
| 5 | [575](../../../tasks/575-remove-node-sections.md) | Implemented (phases 1–3) | Node sections abolished: the wizard and import give a bare body |
| 6 | [585](../../../tasks/585-unknown-node-type-accepted.md) | Implemented | Unknown node types accepted; endpoint list in code |
| 7 | [586](../../../tasks/586-endpoint-types-from-registry.md) | Implemented | The endpoint section comes from the registry's `kind`, not from code |
| 8 | [608](../../../tasks/608-tailscale-exit-node-in-node-row.md) | Implemented | Node row: exit node name, `exit offline`, key expiry |
