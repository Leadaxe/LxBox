[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Routing — rules by domain, IP, app and Wi-Fi, preset bundles, rule sets and Directions

LxBox decides where each connection goes — through the VPN, direct or blocked — with one ordered
list of routing rules for the sing-box core. Rules match by domain, IP, port, protocol, app, Wi-Fi
network or an external `.srs` rule set such as geosite, geoip or ad lists, and preset bundles cover
common cases like the Russian internet segment, BitTorrent and ad blocking. Directions are named
exits with their own node selectors, so different traffic can leave through different servers.

| Field | Value |
|------|----------|
| Feature | 004-ROUTING |
| Type | Product feature |
| Absorbed | `§011F` (local rule-set cache), `§030F` (unified user rules), `§033F` (bundle presets), `§393F` (Directions) |
| State | ✅ written from code, 2026-09-28 |

## Purpose

Decides where each connection goes: into the tunnel via one of the Directions,
direct, into a block — and by which criterion (domain, IP, port, protocol,
app, Wi-Fi network, external list). All of this is one ordered list
of rules on the Routing screen: own rules of three kinds (fields, an external `.srs`,
raw JSON) intermixed with presets from the template. The list order is the matching
order in the core, the first match wins.

Principles the feature protects:

- **The rule list on the screen and `route.rules` are the same thing**, in the same
  order; a disabled rule leaves nothing in the config.
- **A rule cannot bring down the config.** A dangling target, broken JSON, a list that was not
  downloaded, a preset missing from the template — the rule degrades or
  is skipped with a warning, the rest of the config is built.
- **The core downloads nothing by itself.** External lists enter the config only as
  local files; the app goes to the network for them — on a tap or when
  the cache goes stale.

Out of the box: all traffic — to `vpn-1`; the presets Traffic Processing,
Ru internet segment, BitTorrent, VoWiFi, Tailscale networks are enabled.

## Promises

- **P1. List order = `route.rules` order** for all kinds; a preset
  can yield several rules in a row. **Witness:** unit tests "storage [preset,
  inline, preset] → config rules in the same order", "storage [preset, srs,
  preset] → srs middle". **Mutation:** building grouped by kind.
- **P2. Traffic Processing is always first and cannot be removed:** it is seeded
  if lost; it cannot be moved, disabled or deleted. **Witness:**
  unit tests "the head cannot be dragged down by any drag", "the head is seeded
  even if storage lost it", "a rule dropped at the very beginning lands
  BELOW the head". **Mutation:** dragging the head — `sniff` is not first.
- **P3. The order axis is stable:** a new own rule — at the end of the 1000–1100 zone,
  a preset — at the template number; a drag shifts only a contiguous occupied block.
  **Witness:** unit tests "50 random drags — template anchors do not drift",
  "a preset from the catalog lands on the template num even among user rules",
  "the cascade stops at the first gap". **Mutation:** renumbering all
  rules on every drag.
- **P4. A disabled rule produces nothing** (neither route, nor rule_set,
  nor DNS). **Witness:** unit tests "disabled → skipped", "§121 routing = king:
  route disabled suppresses the DNS aspect entirely". **Mutation:** disabling only
  in the UI.
- **P5. Inline conditions:** OR within a category, AND between categories;
  `protocol`, `network`, `ip_is_private`, `source_ip_is_private`, `inbound`
  — at the route rule level; a rule without conditions is not emitted.
  **Witness:** unit tests "protocols go at the routing-rule level", "§240
  network-only (match empty) → routing rule without rule_set", "inline
  source_ip_is_private → routing-rule level", "no match fields → skipped".
  **Mutation:** `protocol` in headless — the core rejects the config.
- **P6. Reject is an action, not a target:** always `action: reject`, never
  `outbound: "reject"`, including the template default. **Witness:** unit tests
  "reject + protocol → action:reject", "outbound override == reject", "§162
  default_value == reject". **Mutation:** without normalization — fatal.
- **P7. Resolve before route.** "Resolve first" — a `resolve` →
  `route` pair with one match; "Resolve only" — a single non-terminal one; for inline without
  domains resolve is not emitted. **Witness:** unit tests "inline + resolve (route
  mode) → TWO rules", "inline + resolve only → ONE non-terminal",
  "inline WITHOUT domain fields + resolve → resolve is NOT emitted". **Mutation:**
  resolve after route.
- **P8. An external list — only from the local cache:** `type: local`, without a URL
  and `update_interval`. An own rule without the file of at least one set is
  skipped with a warning; a preset drops only the set that was not downloaded.
  **Witness:** unit tests "srs without cached path → skip + warning", "remote rule_set
  + cached path → type: local", "§045 geoip on + .srs NOT cached → downgrade
  to single ru-domains". **Mutation:** `type: remote` in the config.
- **P9. A download failure does not take away the working file;** `304` extends
  freshness without rewriting. **Witness:** unit tests "404 does not delete an already downloaded
  file", "304 — the file is not rewritten, but lastUpdated is moved". **Mutation:**
  delete the file before downloading.
- **P10. Auto-update by staleness:** files of enabled rules older than the
  TTL, "Never" is not touched, a conditional GET; once per session, 30 s after
  app start or tunnel bring-up, only in the foreground.
  **Witness:** unit tests "TTL 0 = Never", "a fresh cache within the TTL →
  skip", "If-None-Match goes into the request"; the schedule — `no
  witness`. **Mutation:** a background timer.
- **P11. The Routing screen never turns a rule off by itself.** `enabled` is only the
  user's intent; a missing file is a separate state of the row:

  | # | enabled | file | switch | icon / caption | in the config |
  |---|---|---|---|---|---|
  | 1 | on | yes | on | ✅ | yes |
  | 2 | on | no | on, dimmed | ☁, "Waiting for download"; a spinner while downloading | no |
  | 3 | off | no | off | ☁ | no |
  | 4 | off | yes | off | ✅ | no |

  2 → 1 by itself: auto-update (or a tap on ☁) downloads the file, an open screen
  updates the row; a download failure keeps 2. Switch in 2 → 3; switch in 3 →
  download, enabled on full success. "In the config — no" is about the set: an own
  `.srs` rule is skipped whole, a preset drops the missing set (P8).
  **Witness:** unit tests "включённые правила без файлов остаются включёнными",
  "включённое правило без файла берётся в работу, выключенное — нет",
  "§601 — включённые правила без скачанного файла: сборка без ошибки", widget
  "§601 «ждёт скачивания»: свич включён, приглушён, ☁". **Mutation:** the screen
  writes `enabled=false` for a rule without a file — auto-update skips it forever.
- **P12. Raw JSON does not break the build:** a broken/empty body — skipped with
  a warning, `//…` keys are removed; the editor does not save invalid JSON or
  an array. **Witness:** unit tests "broken JSON → skip + warning", "§350: //-keys
  are cleaned recursively", widget "Save in the AppBar is blocked, the text stays in
  place". **Mutation:** `//` in the config — the core rejects it.
- **P13.** moved to [024-TEMPLATE · P8](../024-TEMPLATE/FEATURE.md#promises)
- **P14.** moved to [024-TEMPLATE · P9](../024-TEMPLATE/FEATURE.md#promises)
- **P15.** moved to [026-DIRECTIONS · P1](../026-DIRECTIONS/FEATURE.md#promises)
- **P16.** moved to [026-DIRECTIONS · P9](../026-DIRECTIONS/FEATURE.md#promises)
- **P17.** moved to [026-DIRECTIONS · P8](../026-DIRECTIONS/FEATURE.md#promises)
- **P18.** moved to [026-DIRECTIONS · P2](../026-DIRECTIONS/FEATURE.md#promises)
- **P19. Rule import is safe:** presets are outside the exchange; a new id and number in
  its zone; `.srs` disabled; a dangling target → `vpn-1` + disabled; a dangling
  DNS server → the option disabled; a taken name — rejection; format newer than 2 —
  rejection. **Witness:** unit tests "§398 — no preset is importable", "dangling tag
  → vpn-1 + disabling + warning", "parse rejects a format from the future".
- **P20. Wi-Fi conditions:** without conditions — any network; BSSID in lower
  case; reading the current network names the reason for a failure. **Witness:** unit tests
  "inline wifi-only → headless rule_set with wifi_ssid", "inline: BSSID
  lower-case on the read side", "fine_location_missing carries the missing list
  in order".

## Controlled parameters

| Setting (Routing screen) | Values | Default | Core config key |
|---|---|---|---|
| Rule list: on/off, order, deletion | — | seeded presets | `route.rules[]`, `route.rule_set[]` |
| Own rule kind | Inline · Remote (.srs) · Raw JSON | Inline | inline/local rule_set or the body as is |
| Rule target | `direct` · Direction · `block` · Reject | `direct` | `outbound` / `action: reject` |
| Action & Resolve | Route · Resolve first · Resolve only + options | Route | `action: resolve`, `strategy`, `server`, … |
| `.srs` TTL | Never · day · week · 2 weeks · month · 6 months · year | week | — (local) |
| Preset variables | per the template declaration | `default_value` | substituted into bodies |
| Default traffic | `direct` · Direction · `block` | `vpn-1` | `route.final` |
| Directions | tag, name, on, members, filter | `vpn-1` on, `vpn-2` off | `outbounds[type=selector]` |

The Traffic Processing preset (head of the list): Packet sniffing (on) and Sniff
timeout (`100ms`…`3s`, `300ms`) → `action: sniff` on `tun-in`/`mixed-in` by
mode; Hijack DNS (on) → `{protocol: dns, action: hijack-dns}`; Resolve
destination IP (on, a global variable) and Resolve strategy (`ipv4_only`)
→ `action: resolve`.

A rule's DNS option ("Send DNS to dedicated server", "Force IPv4 (drop
AAAA)") and the DNS parts of presets — only a trace in `dns.rules`/`dns.servers`,
described in [005-DNS](../005-DNS/FEATURE.md).

## Inputs / Outputs

**Inputs:** the user's rules; the template's preset catalog
(`selectable_rules`: `preset_id`, `ui{label, description, default, locked,
num, isSortable}`, `vars`, `rule`/`rules`, `rule_set`, DNS parts);
Directions; downloaded `.srs` and their metadata (ETag, confirmation time);
global variables (`vpn_mode`, `resolve_enabled`); nodes for a preset with
`for_each`; a rule exchange file; Wi-Fi state from the OS.

**Outputs:** `route.rules`, `route.rule_set`, `route.final`; DNS mirrors of
rules (in 005); build warnings; the pre-start check fatal (a dangling
target); `.srs` files in the local cache; the file `lxbox-rules-YYYYMMDD-HHMM.json`.

## Data flow

```
rule list ─► NORMALIZATION: seeding the head, numbers, sorting, preset dedup
                    ▼
               WALK IN ORDER (disabled — skipped, P4)
   inline → headless rule_set + route (P5, P7)   srs → local rule_set (P8) ◄ .srs cache
   json   → body, `//` removed (P12)             preset → template expansion (024 · P8, P9)
                    ▼
               reject → action (P6); DNS aspects → DNS build (005)
                    ▼
               route.final (P16); Direction selectors (P17)
                    ▼
               PRE-START CHECK: the rule target exists ── fatal
                    ▼
               core config
```

## Rules and guarantees

- The first match wins; order is only the number axis (0 the head,
  945–990 specific presets, 1000–1100 own rules, 1110–1150 broad
  catch-alls).
- An own rule's name is unique among visible names (including preset
  titles); the name is the rule_set tag in the config, a tag collision gets the suffix
  ` (2)`.
- A preset is added from the catalog once; with external sets — disabled.
- Changing a rule's URL or kind wipes the cache and disables the rule; `vpn-1` cannot be
  disabled or deleted.
- An edit on the screen marks the config for rebuild; the write — on leaving.

## Boundaries

- The pre-start check and the "Settings changed" banner —
  [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md); the preset catalog and
  the preset language, the template language and variables —
  [024-TEMPLATE](../024-TEMPLATE/FEATURE.md).
- A rule's DNS option, DNS parts of presets, FakeIP and its link with "Resolve
  destination IP" — [005-DNS](../005-DNS/FEATURE.md).
- A Direction as a detour target (⚙), auto-select `<tag>-auto`, balancing,
  chains, group folds — [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md).
- The Direction model itself — tags, `vpn-1`, members, `-auto` twin, healing of
  references, node selection on the main screen — [026-DIRECTIONS](../026-DIRECTIONS/FEATURE.md);
  here a Direction is only a rule target. The NETWORKS pseudo-direction —
  [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md).
- Which apps go into the tunnel at all (the Tunnel apps tab) —
  [011-SPLIT_TUNNELING](../011-SPLIT_TUNNELING/FEATURE.md). A rule by
  package here acts inside the core and sees only traffic that already got into the
  tunnel; per the template hint — only in VPN mode.
- Checking which rule a connection went by (the rule name in connections,
  per-app trace) — [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md).
- Debug API `/rules`, `/directions` — [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md);
  backup — [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md).
- Own rules have no condition negation — only `invert` in raw JSON.
- Reading SSID/BSSID depends on OS capabilities and granted permissions.

## Functions

| Function | What it does | Promises | File |
|---|---|---|---|
| Rule by conditions (Inline) | Matches traffic by domains, IPs, ports, apps, protocol, network, source and inbound written in the rule's own fields. | P4 P5 | [inline-rules.md](FUNCTIONS/inline-rules.md) |
| Wi-Fi conditions | Limits a rule to listed Wi-Fi networks by SSID/BSSID, with "Add current" and a named reason when the network cannot be read. | P20 | [wifi-conditions.md](FUNCTIONS/wifi-conditions.md) |
| External rule sets and the local cache | Routes by `.srs` lists that the app downloads, caches and refreshes by TTL; the core gets only local files. | P8 P9 P10 P11 | [remote-rule-sets.md](FUNCTIONS/remote-rule-sets.md) |
| Raw JSON rule | Puts a hand-written sing-box route rule into the config, with any condition or action the form does not expose. | P12 | [raw-json-rules.md](FUNCTIONS/raw-json-rules.md) |
| Rule order and enabling | Keeps one rule list ordered by a number axis, with drag, on/off and deletion; the first match wins. | P1 P2 P3 P4 | [rule-order.md](FUNCTIONS/rule-order.md) |
| Rule action | Sends matched traffic to a Direction, `direct`, `block` or Reject, optionally resolving the domain first; other actions go through raw JSON. | P6 P7 | [rule-actions.md](FUNCTIONS/rule-actions.md) |
| Rule exchange via a file | Exports selected own rules to a file and imports them safely on another device; presets are not transferred. | P19 | [rule-transfer.md](FUNCTIONS/rule-transfer.md) |

Preset bundles moved to [024-TEMPLATE](../024-TEMPLATE/FEATURE.md) (as "Preset language and catalog").
Directions moved to [026-DIRECTIONS](../026-DIRECTIONS/FEATURE.md) (as "Direction model").

## Related features

- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — the pre-start check and the "Settings
  changed" banner.
- [024-TEMPLATE](../024-TEMPLATE/FEATURE.md) — the preset catalog and preset language, the
  template language and variables; the pinned head preset is promised here as P2.
- [005-DNS](../005-DNS/FEATURE.md) — a rule's DNS option, preset DNS parts, FakeIP and its link with
  "Resolve destination IP".
- [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) — a Direction as a detour target,
  `<tag>-auto`, balancing, chains, group folds.
- [026-DIRECTIONS](../026-DIRECTIONS/FEATURE.md) — the Direction model: tags, `vpn-1`, members and
  the `-auto` twin, healing of rule and Default traffic references, node selection on the main screen.
- [007-NODE_LIST](../007-NODE_LIST/FEATURE.md) — the node list of the selected Direction on the main
  screen.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — latency measurement settings per Direction.
- [011-SPLIT_TUNNELING](../011-SPLIT_TUNNELING/FEATURE.md) — which apps enter the tunnel at all;
  package rules here only see tunnelled traffic.
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — shows which rule a connection went by.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — Debug API `/rules`, `/directions`.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — backup of rules and Directions.

## Maintenance notes

- `sniff` must be the first rule: any rule above Traffic Processing
  matches without a domain. That is why the head is the only unsortable preset, and
  its number is healed at load, build and import.
- `ip_is_private`, `protocol`, `network`, `inbound` live at the route
  rule level, while domains are in a headless rule_set: by the core's formula, address
  conditions are combined by OR. A "domain + Private IP" rule matches both
  one and the other, not the intersection.
- Several Wi-Fi pairs in a rule give `wifi_ssid:[A,B] AND wifi_bssid:[X,Y]` —
  a cross match is possible; an accepted risk.
- An own `.srs` rule requires all files, a preset does not (a gate set only
  widens the match). Before §601 the screen disabled a rule without a file, and the
  default Ru internet segment went off for good if Routing was opened before the
  first auto-update; now such a rule waits for the download (P11).
