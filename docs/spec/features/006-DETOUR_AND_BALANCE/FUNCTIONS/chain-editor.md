[English](chain-editor.md) · [Русский](chain-editor.ru.md)

# Chain editor — building a hop chain and measuring each hop

The chain screen assembles positions in packet order, refuses to save what
the core would reject and, on a running tunnel, measures how much each hop
costs.

| Field | Value |
|------|----------|
| Feature | [006-DETOUR_AND_BALANCE](../FEATURE.md) |
| Promises | P11 P16 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Creating ("New hop chain": Tag only — the tag is the chain's one name) and editing a chain on
the "Hop chain · <tag>" screen: a list of positions with drag-and-drop,
"Add position", the Advanced block, check findings right in the form. From
the chain node's window — the live path and the **per-layer probe**: how
much each hop costs.

## Parameters

| Element | Behaviour |
|---|---|
| Tag | Set on creation and editable in the editor (label icon, emoji picker; the title follows the field); empty or taken by another chain, Direction or node — saving is blocked with a reason; on save the chain keeps its place and references to the old tag (other chains' positions, rules, final, detours, DNS) move to the new one |
| Enabled | "A disabled chain is not built and cannot be used as a position" |
| Positions | caption "In packet order: the first position is the hop closest to you, the last one is what the destination sees."; each position shows its kind (node, group, direction, chain, built-in, loading…, not found) |
| Add position | picker: sections **Directions** (only with "Use as detour") and **Servers** (nodes of the built config alphabetically, `TYPE · server:port`); those already used are excluded; nothing to add — "Nothing left to add…" |
| Advanced | Idle timeout; "Strip evasion tricks from links"; "Per-key overrides" — a three-state checkbox per catalog key with the result "stripped"/"kept" |
| Deletion | "Delete hop chain?" with confirmation |
| Leaving with unsaved edits | Save / Keep / Discard |

## Inputs / Outputs

**Inputs:** the last built config (final tags: prefixes, uniquification),
Directions, the list of chains with their order, the `strip` catalog from
the registry.
**Outputs:** the saved chain; form findings; for a running tunnel — layer
measurements.

## Rules and invariants

- Blocking findings forbid saving (P11):

| Finding | Text (abridged) |
|---|---|
| <2 positions | "At least two positions are needed…" |
| empty position (from a backup/API) | "Positions … are empty — remove them…" |
| self-reference | "Position … references this chain itself…" |
| repeat | "Position … is used more than once…" |
| nested chain not first | "A nested chain (…) is only allowed at the first position…" |
| chain lower in the list | "Chains … are declared below this one…" |
| empty / occupied name | "A chain needs a name…" / "The name "…" is already taken…" |

- Warnings and notes do not prevent saving: missing positions (only once
  the target snapshot has been parsed), detour on the first position ("the
  real path is longer than shown"), detour on links ("does not apply inside
  a chain"), WireGuard behind a TCP hop, MASQUE with fixed h3 on a link, a
  `strip` key that the build will keep for the sake of a link.
- Candidates are rebuilt every time the picker opens — the "Use as detour"
  flag may have changed while the form was open.
- Groups, `direct-out`, chains are not offered in the picker, but positions
  of those kinds already in place are valid and shown.
- Per-layer probe (P16): path prefixes `<chain>#0…#N-1` are measured through
  the running core; a hop's cost is the difference of adjacent prefixes, a
  negative one is clamped to zero; the budget and URL come from the ping
  settings. A layer with an error — "error", the following ones — "not
  reached". Tunnel off — the probe is unavailable.
- The chain tag in the node window leads to the chain editor.

## Boundaries

- `rewrite` is not editable in the form; it is saved as is.
- No probe without the tunnel up: the internal position tags exist only in
  the running core.
- General ping settings — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [018F](../../../tasks/018F-detour-server-management/spec.md) | Policy in 026 | First sketch of the Chain Editor |
| 2 | [393F](../../../tasks/393F-directions/spec.md) | released v2.21.0 | C6–C7: form checks, chain screen, position picker |
| 3 | [558](../../../tasks/558-chain-owner-navigation.md) | Done | Navigation to the chain from the node window |
