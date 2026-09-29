[English](direction-model.md) · [Русский](direction-model.ru.md)

# Direction model — the named exit that rules, nodes and groups refer to

A Direction is a named exit with its own set of nodes — `vpn-1`, `vpn-2` or one with a
custom tag — that rules, Default traffic, DNS servers and detour fields point to by tag.

| Field | Value |
|------|----------|
| Feature | [026-DIRECTIONS](../FEATURE.md) |
| Promises | P1 P2 P3 P4 P5 P6 P7 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Holds the list of Directions and everything that refers to them. Each Direction has an
immutable **tag** (the system id), a **title** (a client-only name), an on/off switch and a
description of its members: which nodes it takes and which service options it offers.
Three tags are built in and cannot be taken by a Direction: `direct-out` (leave the phone
directly) and `block` (drop the traffic) are template outbounds offered inside a Direction
as options, and `vpn-1` is the required primary Direction — the default target of Default
traffic and the fallback every healed reference lands on. The **Directions** tab of the
Routing screen lists them with "Add direction (N)" and the **Default traffic** tile; each
row shows the tag, the node count from the running core's snapshot ("all nodes" or
"filtered" with the tunnel down), " · auto" and " · required".

`NETWORKS` in the home-screen dropdown is not a Direction: it is a view of nodes outside
the selection lists — [012-LIVE_STATE · P19](../../012-LIVE_STATE/FEATURE.md#promises).

## Parameters

| Field | Values | Default | Where it goes |
|---|---|---|---|
| Tag | `vpn-N` (the first free one) or custom; "System id, cannot be changed later" | `vpn-N` | the `selector` tag; the reference in rules, DNS, detour |
| Title | any text; "optional — defaults to the tag" | "VPN ⓝ" for `vpn-N` (1–10; "VPN 11" above), otherwise the tag | client only; carries the `⚙ ` marker of a detour Direction |
| On/off | switch in the row; `vpn-1` locked on | `vpn-1` on, `vpn-2` off | a disabled Direction is not emitted |
| Include direct-out / Include block | checkboxes | off | options `direct-out` / `block` |
| Other directions | "only directions listed above this one" | — | option tags of other selectors |
| Node filter (regex) + Exclude matching (invert) | case-insensitive | empty = all nodes | membership |
| Default (regex) | "first matching node becomes default" | empty | `default` |
| Interrupt connections on switch | on/off | on | `interrupt_exist_connections` |
| Include auto (urltest) + its fields | see [groups](direction-groups-in-config.md) | off | `<tag>-auto` |
| Use as detour | checkbox (hidden for `vpn-1`) | off | [detour layer](direction-as-detour.md) |
| Default traffic | `direct` · Direction · `block` | `vpn-1` | `route.final` |

Debug API: `GET/POST /directions`, `GET/PATCH/DELETE /directions/{tag}`,
`POST /directions/reorder`; a `PATCH` setting the flag on `vpn-1` gets 409.

## Inputs / Outputs

**Inputs:** the stored list; the template's `default_directions` on first run; user
actions in the tab, the editor and the "New direction" dialog; Debug API; a restored backup.
**Outputs:** one `selector` per enabled Direction and its `-auto` twin (built in
[groups](direction-groups-in-config.md)); targets for the rule, preset, DNS and Default
traffic pickers; one notification "Direction "…" deleted/disabled — …" with the healed
counters; the tag conflict reason in the dialog.

## Rules and invariants

- **Identity is the tag.** Only the title is edited; references (rules, `route.final`,
  DNS servers, detour fields, `include`, chain positions, ping overrides) name the tag or
  `<tag>-auto` and therefore survive renames. A node is not referenced by the Direction:
  membership is a regex over final node tags, so node addresses `{folder_id?, tag}`
  ([017-BACKUP_AND_STORAGE · P17](../../017-BACKUP_AND_STORAGE/FEATURE.md#promises)) play
  no part here.
- A new tag is rejected with a reason: "Tag cannot be empty", "This tag is reserved by the
  config" (`direct-out`, `block`, `block-out`, `dns-out`, `direct`, `reject`, `drop`), "A
  direction with this tag already exists", "This tag collides with an auto twin
  (<tag>-auto)". There is no ceiling on the number of Directions; `vpn-N` numbering takes
  the first free slot, not max + 1, and custom tags do not occupy numbers.
- `vpn-1` cannot be disabled or deleted; a loaded list without it (edited backup, Debug API
  import) gets it inserted first, enabled, with the default title.
- Role is a permission (274): "Use as detour" does not remove a Direction from rule targets.
- The target picker: `direct` first, then enabled Directions (`vpn-1` always, detour ones
  with ⚙), `block` last, in red; disabled ones are hidden.
- **Deleting or disabling** moves references to `vpn-1` in storage: rule targets, preset
  target overrides, Default traffic, and DNS servers that named the Direction (a template
  server's `outbound` variable or a user server's `detour`, 441); detour references are
  reset ([detour layer](direction-as-detour.md)). Re-enabling does not bring them back.
- Deletion additionally removes the tag from "Other directions" of the rest, from chain
  positions and from the per-Direction ping override; disabling keeps all three (it is
  reversible). Counters go into one notification: "N rule reference(s) switched to vpn-1",
  "N detour reference(s) reset to None", "N direction option(s) removed", "N chain
  position(s) removed", "N DNS server(s) switched to vpn-1".
- Healing storage and the in-memory source list is one operation, otherwise the next save
  would resurrect the reference; a bulk rewrite of the whole list (tab, Debug API reorder)
  heals nothing by design.
- Changing a subscription or folder **tag prefix** rewrites literal occurrences of the old
  prefix in Node filter and Default of every Direction; an occurrence inside a regex
  construct (`R.`, `RU:?`, a character class) is left alone and reported.
- The first run seeds the list from the template; a list that was migrated and then emptied
  is never reseeded. A key missing from a stored record gets its default; garbage in
  `include` (non-strings, blanks, duplicates) is dropped on read; an empty `include` is not
  written.
- A rule or Default traffic whose target is not in the config is a fatal of the pre-start
  check ([003-CONFIG_BUILD · P9](../../003-CONFIG_BUILD/FEATURE.md#promises)); the healing
  above keeps it from getting there.

## Boundaries

- Membership, `-auto` twin and `route.final` in the config —
  [direction-groups-in-config.md](direction-groups-in-config.md); the home-screen
  selection — [direction-selection.md](direction-selection.md).
- The row's node count ignores "Exclude matching": it counts matches even when the
  Direction takes the rest. Reordering Directions is available only through the Debug API.
- The DNS side of a healed server (fail-closed on a channel that vanished at build time,
  419) — [005-DNS · P2](../../005-DNS/FEATURE.md#promises).
- Rule import healing a dangling target — [004-ROUTING · P19](../../004-ROUTING/FEATURE.md#promises).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [125F](../../../tasks/125F-configurable-channels/spec.md) | IMPLEMENTED | Configurable channels: on/off, regex filter, default, healing `route.final` |
| 2 | [184](../../../tasks/184-add-vpn4-channel.md) | — | A fourth channel |
| 3 | [201](../../../tasks/201-block-outbound-for-channels.md) | IMPLEMENTED | The `block` option in members, fallback for an empty filter |
| 4 | [202](../../../tasks/202-heal-channel-refs-on-disable.md) | IMPLEMENTED | Healing references on disabling, without resurrection |
| 5 | [267](../../../tasks/267-group-templates-magic-nodes.md) | — | Seeding Directions from the template (`default_directions`) |
| 6 | [274](../../../tasks/274-detour-role-to-permission.md) | RELEASE v2.15.6 | A detour Direction is available to rules again |
| 7 | [275](../../../tasks/275-channel-mutations-detour-resync.md) | RELEASE v2.15.6 | A single point of changing Directions with healing |
| 8 | [393F](../../../tasks/393F-directions/spec.md) | released v2.21.0 | Channels → Directions: own tags, no ceiling, `include`, `vpn-1` insured, prefix cascade |
| 9 | [402](../../../tasks/402-direction-chain-label-removed.md) | Done | The Direction name removed (reverted by 405) |
| 10 | [405](../../../tasks/405-direction-chain-label-mobile-only.md) | Done | The name returned as a client field |
| 11 | [408](../../../tasks/408-ping-options-groups-heal.md) | Done | The ping override is removed together with the Direction |
| 12 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released v2.24.0 | Storage in contract form; `channels` renamed to `directions` on read |
| 13 | [441](../../../tasks/441-template-preset-vars-in-record.md) | Released v2.24.0 | Healing the target in preset and DNS server variables → `vpn-1` |
