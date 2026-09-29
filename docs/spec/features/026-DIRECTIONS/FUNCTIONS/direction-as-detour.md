[English](direction-as-detour.md) · [Русский](direction-as-detour.ru.md)

# Direction as a detour layer — switching the upstream of many nodes at once

A Direction marked "Use as detour" becomes a shared upstream: changing its
node on the main screen moves every server that goes through it.

| Field | Value |
|------|----------|
| Feature | [026-DIRECTIONS](../FEATURE.md) |
| Promises | P18 P19 P20 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Turns a Direction (`vpn-2`, a custom one) into a switchable layer: the
**Use as detour** checkbox in the Direction editor allows picking it as the
detour target of servers, folder members, folders and subscriptions.
Switch the node in the Direction on the main screen — and the whole fleet
going through it moves to a different upstream without editing nodes. With
auto-select the layer is self-steering.

## Parameters

| Knob | Values | Default | Effect |
|---|---|---|---|
| Use as detour ("can be picked as a detour target for servers and folders") | on/off | off | the Direction appears in the Directions section of the detour picker |

`vpn-1` has no checkbox. The other Direction knobs (membership, filter,
`include_block`, auto-select) are shared with an ordinary Direction,
[direction-model.md](direction-model.md).

## Inputs / Outputs

**Inputs:** the flag, the Direction's state (on/off, exists), references to
it in the detour fields of sources.
**Outputs:** `detour: "<tag>"` on nodes going through the layer (the
selector itself is emitted as for any Direction); the name with the `⚙ `
marker everywhere the Direction is shown (pickers, main screen, rule target
picker); a notification about reset references; in the Debug API — `detour`
and the `healed` counters.

## Rules and invariants

- A permission, not a role (P18): a Direction with the flag remains a target
  of rules, `route.final`, presets and DNS; `include_block` is compatible
  with the flag.
- `vpn-1` is never a detour Direction: the flag is coerced on read (an
  edited backup, a hand-written file), the Debug API answers 409 "…is the
  primary direction and cannot be a detour direction".
- The ⚙ marker is stored in the name (P20): enabling the flag renames to
  `⚙ <name>`, disabling removes the prefix; a marker erased by hand comes
  back; an empty name is not touched (`⚙ <tag>` is shown).
- The picker shows only enabled Directions with the flag; the selector's
  current selection — in parentheses when the tunnel is up.
- Healing (P19), by reference to the tag or `<tag>-auto`, root references
  only (a folder member's address is never a Direction):

| Event | detour references (source override, member's personal detour) |
|---|---|
| flag on | nothing |
| flag off | → None |
| disabling | → None |
| deletion | → None; chain positions pointing to it are removed too |

- Healing is irreversible: re-enabling does not bring references back. The
  result — one notification "Direction "…" …" with the counters "N detour
  reference(s) reset to None", "N chain position(s) removed" and others.
- Healing storage and the in-memory source list is one operation;
  otherwise the next save would resurrect the reference.
- An empty Direction (the filter caught nothing) behaves for a layer like
  for any other: membership `[block, direct-out]`, default `block` — nodes
  that went through it are blocked rather than going direct, and the build
  names them in a separate warning.
- A layer member node with a detour to the same layer is a ring, see
  [detour-graph.md](../../006-DETOUR_AND_BALANCE/FUNCTIONS/detour-graph.md).

## Boundaries

- Healing rule references, `include`, DNS servers on deletion/disabling —
  [direction-model.md](direction-model.md), [005-DNS](../../005-DNS/FEATURE.md).
- The detour picker, source detour policy and the ring sanitizer —
  [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).
- Compatibility of AmneziaWG with WireGuard within a layer is not checked
  (neither a prohibition nor a warning).
- A possible ring is not highlighted right in the picker.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [248F](../../../tasks/248F-detour-channels/spec.md) | IMPLEMENTED, device-verified | "Use as detour" channel, ⚙, healing detour references |
| 2 | [254](../../../tasks/254-detour-cycle-fatal-detector.md) | AGREED | Rings through a layer — not a silent edge strip |
| 3 | [274](../../../tasks/274-detour-role-to-permission.md) | RELEASE v2.15.6 | Role → permission; ⚙ in the name; block and empty fallback as for everyone |
| 4 | [275](../../../tasks/275-channel-mutations-detour-resync.md) | RELEASE v2.15.6 | A single mutation point: healing + in-memory mirror |
| 5 | [393F](../../../tasks/393F-directions/spec.md) | released v2.21.0 | Channels → Directions; chain positions in healing |
| 6 | [441](../../../tasks/441-template-preset-vars-in-record.md) | Released v2.24.0 | DNS server counter in the same notification |
