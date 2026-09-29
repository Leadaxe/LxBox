[English](dns-groups.md) · [Русский](dns-groups.ru.md)

# DNS groups

| Field | Value |
|------|----------|
| Feature | [005-DNS](../FEATURE.md) |
| Promises | P5 P6 P15 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Combines several DNS servers under one tag so that a failure of one does not
bring resolving down. A group can be placed anywhere a server tag is
expected: in `dns.final`, in the core resolver, in a DNS rule, in another
group. The core picks the target by mode on its own; the client assembles
the group, cuts off unavailable members and shows whom the core has picked
right now.

## Parameters

| Form field | Core key | Values | Default |
|---|---|---|---|
| Members | `servers` | server tags, ≥1, order does not matter | — |
| Selection mode | `mode` | `stable` — stick to one until it fails · `fastest` — race, then stick to the winner · `parallel` — race on every query | `stable` (key not written) |
| Error TTL | `error_ttl` | duration `NNh NNm NNs` | core's (`2m`), key not written |
| Win TTL (only with `fastest`) | `win_ttl` | same | core's (`5m`) |

A group has no other keys: `detour`, address, port, `tls` are removed by the
form when switching to group mode; the build removes `detour` in any case.

## Inputs / Outputs

**Inputs:** the group body (form or JSON), the full list of emitted servers,
the `getDNSGroups` snapshot from the core on screen open.
**Outputs:** `dns.servers[]` with `type: group`; warnings about thrown-out
members; fatal reasons "empty group", "invalid member", "group cycle"; a
live state line under the group.

## Rules and invariants

- The member picker offers all servers except the group itself and
  `fakeip`/`hosts`; a disabled member can be selected but is marked
  "disabled — will be skipped"; a member absent from the list — "unknown
  server — will be skipped".
- The member filter runs after the whole list is built (a member below the
  group is available). Drop reasons in the warning: `disabled`, `unknown`,
  `itself`, `duplicate`, `dangling detour`. Storage does not change: enable
  the member — it is back.
- A group emptied after filtering is emitted empty → fatal before the core
  starts. Exception: all live members dropped out because of a dangling
  `detour` — the group drops out itself (together with enclosing groups
  emptied the same way), references to it are healed by the refusal policy.
- A `fakeip`/`hosts` member (e.g. via JSON) — fatal; a group cycle
  (including self-inclusion bypassing the form) — fatal, one per ring; a
  nested group without a ring is allowed.
- An invalid duration — a hint under the field, saving is not blocked, the
  key is simply not written.
- Changing the mode does not materialize the default: `stable` removes the
  `mode` key.
- In the list the group is labelled `group · <mode> · <member count>`.
- Live state: only with the tunnel up, one request per screen open, no
  timer. Line: `→ <current target>`, per member `tag ✓ 12ms` (for
  `fastest` — `wN` wins) or `tag ✗N (34s)`, `●` on the current one. A core
  without the method or an error — no line.

## Boundaries

- Target selection behaviour (TTL records, survival mode, amnesty on network
  change) — the core, [sing-box-lx FEATURE 013-DNS_GROUP](https://github.com/Leadaxe/sing-box-lx/tree/lx/SPECS/FEATURES/013-DNS_GROUP).
- The group query trace (path, probes, fan-out) — in the profiler,
  [012-LIVE_STATE](../../012-LIVE_STATE/FEATURE.md).
- There is no separate Debug endpoint for group state.
- Template and preset groups (`dns_shield`, `dns_ru`) —
  [built-in sets](builtin-dns-sets.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [312F](../../../tasks/312F-dns-group/spec.md) | implemented | `group` type in the form, member filter with warnings, checks, live status |
| 2 | [315](../../../tasks/315-dns-group-trace-in-profiler.md) | implemented | Group trace in the profiler |
| 3 | [317](../../../tasks/317-dns-group-save-blocked-by-address-gate.md) | fixed, device-pending | A group is saved without an address |
| 4 | [319](../../../tasks/319-dns-group-must-not-have-detour.md) | DEVICE-VERIFIED | A group has no `detour`, it is removed at build time too |
| 5 | [365](../../../tasks/365-dns-one-shot-test-button.md) | Won't-fix | Live group statistics instead of a synthetic test |
| 6 | [384](../../../tasks/384-fakeip-resolver-gate-and-lost-running-snapshot.md) | Done | The `fakeip`/`hosts` prohibition is the same as for resolvers |
| 7 | [443](../../../tasks/443-contract-1-0-2-spec129.md) | Released | A group emptied by a dangling detour drops out itself |
