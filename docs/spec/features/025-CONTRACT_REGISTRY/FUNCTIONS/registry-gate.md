[English](registry-gate.md) · [Русский](registry-gate.ru.md)

# Registry gate at build — what the pinned core cannot run stays out of the config

Before the config reaches the core, every node body is judged once more by the registry schema for
the pinned core version and its build tags; what the core would reject is removed, authored JSON is
only commented on.

| Field | Value |
|------|----------|
| Feature | [025-CONTRACT_REGISTRY](../FEATURE.md) |
| Promises | P7 P8 P9 P10 P11 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Stage 5 of the [build pipeline](../../003-CONFIG_BUILD/FUNCTIONS/build-pipeline.md). Parsing
judged the node without a core (P3 of the feature); the gate is where the core finally matters. It
receives only entries that came from node sources — service outbounds of the template and Direction
groups are not node bodies and do not enter. Three checks, in this order:

1. **Type insurance.** An entry without a non-empty string `type` is not a sing-box body: it is
   removed with `field_missing` (`field: type`). This runs before and without the registry, because
   one such entry makes the core reject the whole config without naming the node.
2. **Core gate of the node.** A protocol, a field or a range form with
   `on_core_unsupported: drop_node` whose requirement — `build_tag` against the app's tag set,
   `min_core` against the core version — the core does not meet removes the entry whole with the
   registry code (`tailscale_core_unsupported`, AWG range and 3.x codes).
3. **Sanitizer by body schema** for the core version: a field the core does not know is removed
   with `unknown_key`, invalid values by `on_invalid`, `min_core`/platform fields removed; a
   `drop_node` verdict removes the entry.

## Parameters

| Input | Value | Effect |
|---|---|---|
| Core version | the pinned core (`v1.14.2-lx.8`); empty when unknown | empty — `min_core` gates do not fire (fail-open) |
| Build tags | the app's tag mirror of the AAR; `null` — unknown | `null` — `build_tag` gates do not fire |
| Body source | `singbox` for an authored body, `other` for everything else | decides soft vs. hard rules (below) |
| Registry | loaded from the bundle | not loaded — the gate is a no-op apart from the type insurance |

## Inputs / Outputs

**Inputs:** the emitted `outbounds[]` and `endpoints[]` from node sources, with the "authored"
flag per entry; the core version and tags.
**Outputs:** bodies cleaned in place; the list of removed entries (they leave Direction pools and
the tag map too); warning lines for the build report; warnings by final config tag — the node
card and the Debug API read them from there.

## Rules and invariants

- **A refusal is a registry code, not a build error.** The config is still written; the node is
  out and named.
- **An authored body is only commented on** ([577](../../../tasks/577-authored-json-registry-reports-only.md)):
  a soft rule leaves the value and gives the code with `applied: false`; the report line gets the
  mark `(not applied)`. Hard rules are applied even to an authored body: `core_rejects` rules,
  a bad `type`, the core gate of the node.
- **Edits are in place.** The same map objects already sit in Direction pools; replacing the
  reference would leave half of them with the old body.
- **Unknown is not "too old".** An unknown core version or an unknown tag set never removes a node.
- **Report lines are deduplicated** per `tag: text [path=value]`.
- **The probe config** (node checks) goes through the same gate; a node the core cannot run is not
  probed either.
- Duplicated parse codes: a code the parse already put on the node can appear again from the
  gate under the final tag — the card groups entries by code.

## Boundaries

- Stage order, detour resolution, folds and chains, healing — [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md);
  chain capability gate by core version — [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).
- The core pin and the build-tag set — [021-CORE_CONTRACT](../../021-CORE_CONTRACT/FEATURE.md).
- Rejections the core makes at start despite the gate — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).
- The gate does not touch `tag` and `detour`: the build writes them.

## Revisions

| # | Revision | Status | Summary |
|---|---------|--------|------|
| 1 | [455](../../../tasks/455-node-editor-source-json-tabs.md) | Released v2.24.3 | A JSON source goes to the core verbatim — the gate becomes its only judge |
| 2 | [460F](../../../tasks/460F-contract-registry-bundle/spec.md) | Released v2.25.0 | W1: the registry guard at build, sanitizer by body schema |
| 3 | [477](../../../tasks/477-vless-encryption-grammar.md) | Released v2.25.0 | A node with an invalid `encryption` does not reach the core |
| 4 | [505](../../../tasks/505-home-node-badge-user-server.md) | Released v2.25.0 | Build warnings by final config tag reach the main screen badge |
| 5 | [556](../../../tasks/556-registry-debt-1157-1170.md) | Partial | Core gate of the node: `build_tag` + `on_core_unsupported` (contract 1.1.60) |
| 6 | [577](../../../tasks/577-authored-json-registry-reports-only.md) | Done | Authored JSON: the registry reports, does not edit |
| 7 | [586](../../../tasks/586-endpoint-types-from-registry.md) | Implemented | Endpoint types from the registry |
