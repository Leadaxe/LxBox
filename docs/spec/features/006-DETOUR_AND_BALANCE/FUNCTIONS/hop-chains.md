[English](hop-chains.md) · [Русский](hop-chains.ru.md)

# Hop chains — multi-hop routes built by the core

A hop chain sends traffic through several servers in a fixed order and
appears in the rest of the app as an ordinary node.

| Field | Value |
|------|----------|
| Feature | [006-DETOUR_AND_BALANCE](../FEATURE.md) |
| Promises | P7 P8 P9 P10 |
| State | ✅ written from code, 2026-09-28 |

## What it does

A chain is the third kind of source next to a subscription, a server and a
folder: a "`tag · N hops`" row in the shared Servers list ("Add hop
chain…"), dragged on a par with the others. It is a **route**
`client → position 1 → … → position N → destination`, assembled by the core
at runtime (the `chain` outbound of the sing-box-lx core, core feature
015-CHAIN). For the rest of the application a chain is a node: Direction
filters select it, it can be chosen on the main screen.

## Parameters

| Field | Values | Default | Core key |
|---|---|---|---|
| Tag | `chain-N` (first free) or custom; editable — references to the old tag are rewritten | `chain-N` | `tag` |
| Enabled | on/off | on | a disabled one is not emitted |
| Positions | ≥2, in packet order; a position is a node, a subscription group, a Direction, `direct-out`, a chain higher in the list (first position only) | — | `outbounds` |
| Idle timeout, Strip evasion, Per-key overrides | dropped on read, not stored | — | not written (task 761: core `v1.14.4-lx.37-rc.2` rejects `idle_timeout`, `strip_evasion`, `strip`; contract 1.1.184) |
| rewrite | merge-patch by node type | `{}` | `rewrite` |

## Inputs / Outputs

**Inputs:** the list of chains in declaration order; final tags of nodes,
Directions, service outbounds, chains above; the core version.
**Outputs:** the outbound `{"type":"chain","outbounds":[…], …}` before
Direction groups; the chain tag in Direction pools; warnings with codes
`chain_unsupported_by_core`, `chain_invalid`, `chain_hop_missing`,
`chain_nested_position`, `chain_cycle_through_direction`.

## Rules and invariants

- The position order goes out verbatim — it is packet order (P7).
- Degradation — whole, the rest of the config is built (P8), in this order:
  1. core older than `1.14.0-lx.27-rc.5` — "Hop chain … was skipped" (a
     malformed version string — the chain is emitted);
  2. core invariants: <2 positions, an empty position, self-reference, a
     repeat, an empty type name in `rewrite`;
  3. the tag is taken by a node, a Direction or another chain;
  4. a position did not resolve — "A route without a hop is a different
     route, so the whole chain is skipped."; this also covers a reference to
     a chain lower in the list (cycles between chains are excluded by
     order);
  5. a nested chain not in the first position.
- One path per node or group (task 761), no copies: a ring (reached at the
  entry and higher in the same chain, or an entry node's `detour` into a higher
  position), a conflict (needed on position ≥ 1 and met on another position
  ≥ 1 or in another chain; a shared entry is fine), a taken hop tag
  `<chain>#<i>` — the chain is dropped with a warning that says which copy to
  make. Of two conflicting chains the lower one in the list drops.
- A node past the first position (or a group member there) with WireGuard/AWG
  `listen_port`, Tailscale `listen_port`/`relay_server_port`, OpenConnect
  `dtls_local_port` (non-zero) drops the chain with a build warning; the port
  is not removed, as in the launcher (`chain_hop_local_port`). Socket options
  stay (the core accepts them under `detour`).
- A Direction does not take a chain going through it, including transitively
  (P9): "Hop chain "…" runs through direction "…" and was left out of
  it…". The subtraction is not counted as a fault of the Direction's filter.
- The build additionally drops a chain whose position was emptied by a
  cascade, and removes chains from the leaves of groups standing at
  position ≥2.
- Healing (P10): deleting a server, a folder member, a subscription, a folder
  with its servers, a Direction, another chain removes the corresponding
  **positions**; counter "N chain position(s) removed". A chain with <2
  positions stays visible and is not built. Dissolving a folder while
  keeping its servers and updating a subscription do not touch positions.
- Disabling a Direction keeps the positions: a chain standing on it is not
  built at all (fail-closed, not shortened) and comes back when the
  Direction is re-enabled; only deletion removes the positions.
- Storage — `kind: chain` records in the shared source list; record order =
  declaration order. Backup — in the servers category.

## Boundaries

- Disabling a position at runtime, link state, MTU and sleep of WireGuard
  links — on the core side, the application does not show them.
- A group at a position ranks its nodes by direct measurements, not "through
  the lower hops" — core behaviour.
- A chain is not offered as a detour target or as a position in the picker
  (see [chain-editor.md](chain-editor.md)); existing positions of that kind
  are valid.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [018F](../../../tasks/018F-detour-server-management/spec.md) | Policy in 026 | The original idea of a chain as node copies (not implemented in this form) |
| 2 | [393F](../../../tasks/393F-directions/spec.md) | released v2.21.0 | C1–C5, D2: chain source, `type: chain`, core gate, T9, position healing |
| 3 | [401](../../../tasks/401-backup-state-serialization.md) | DEVICE-VERIFIED | Chains in the backup |
| 4 | [402](../../../tasks/402-direction-chain-label-removed.md) | Done | Chain name removed (reverted by 405) |
| 5 | [405](../../../tasks/405-direction-chain-label-mobile-only.md) | Done | Name returned as a client-side field |
| 6 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released v2.24.0 | A position is a node address `{folder_id?, tag}` |
| 7 | [524](../../../tasks/524-unified-source-entries.md) | Released v2.25.3 | A chain is a row of the shared source list |
| 8 | [594](../../../tasks/594-chain-label-removed-tag-only.md) | Done | The chain name (label) removed again: the tag is the one name |
| 9 | [609](../../../tasks/609-chain-tag-editable.md) | Done | The tag is editable, like a node's: the place in the list stays, references follow the new tag |
| 10 | [761](../../../tasks/761-core-rc2-chain-detour.md) | Done (develop, core rc2) | No `idle_timeout`/`strip_evasion`/`strip`; one path per node; a fixed local port past the first position drops the chain |
