[English](preset-bundles.md) · [Русский](preset-bundles.ru.md)

# Bundle presets

| Field | Value |
|------|----------|
| Feature | [004-ROUTING](../FEATURE.md) |
| Promises | P2 P13 P14 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Provides ready-made rules from the app template: a catalog on the **Presets** tab,
the "Add to Rules" button (after adding — "In Rules"). A preset in the rule
list is a reference to the template plus the values of its variables: the app
updated — the behaviour updated for everyone. A preset can carry
rule_sets, several route rules, DNS servers and DNS rules at once.

## Parameters

| Preset | Default | Number | What it does | Variables |
|---|---|---|---|---|
| Traffic Processing | on, pinned | 0 | `sniff`, `hijack-dns` for `protocol: dns`, `resolve` | Packet sniffing, Sniff timeout, Hijack DNS, Resolve destination IP¹, Resolve strategy¹ |
| Tailscale networks | on | 945 | for each Tailscale node: `preferred_by` → the node, resolving its DNS | DNS |
| Private IPs | off | 950 | `ip_is_private` | Outbound (`direct-out`) |
| Block Ads | off | 960 | external `ads-all` → reject | — |
| Google push (FCM) | off | 970 | FCM hosts and ports 5228–5230 | Outbound, Limit to Google Play Services |
| BitTorrent | on | 980 | `protocol: bittorrent` | Outbound (`direct-out`) |
| VoWiFi (carrier calling) | on | 990 | `pub.3gppnetwork.org`, UDP 500/4500 | Outbound, Match IKE ports |
| Russia-only services | off | 1110 | an external list "available only from Russia" | Outbound, Force IPv4 |
| Ru internet segment | on | 1120 | ru TLDs, services, GeoIP-RU, Russian apps | Outbound, DNS, UDP server IP, GeoIP IP-range fallback, Russian apps by package, Force IPv4 |
| FakeIP | off | 1130 | DNS only (see 005) | DNS, Block HTTPS records |
| Unknown traffic | off | 1150 | traffic without an owning app | outbound (`reject`) |

¹ a global variable: shared by the whole app, not per rule.

Variable kinds in the preset editor: a switch, a choice from a list,
text/number, a target (Direction), a DNS server. Hidden template variables are not
shown.

## Inputs / Outputs

**Inputs:** the template's `selectable_rules`; variable values; global
variables; the external set cache; nodes (for Tailscale).
**Outputs:** fragments in `route.rule_set`, `route.rules` (at the preset's position),
the DNS part — in [005-DNS](../../005-DNS/FEATURE.md).

## Rules and invariants

- Only the preset id and values different from the default are stored; choosing
  the default removes the key. The name in the editor is read-only — the live title
  from the template of the current locale.
- The preset target chosen by the picker replaces the template's decision entirely:
  reject ↔ Direction ↔ `direct`; intermediate `resolve`/`sniff` are not
  affected. `reject` always becomes `action: reject`.
- A fragment disabled by a variable (`#if`/`#enable`) is not emitted; a rule
  left with neither a target nor conditions after substitution drops out with
  a warning.
- A preset missing from the template: skipped by the build, the list shows "Preset not
  found — tap to fix".
- Identical rule_sets of two presets are registered once; different ones with the same
  tag — the first wins, a warning.
- **Traffic Processing:** always seeded if missing; its switch
  is unavailable, deletion is hidden, drag is forbidden. Turning off Packet sniffing
  disables matching by protocol (and by domain without FakeIP); turning off Hijack
  DNS disables FakeIP and all DNS rules — a warning in the hint.
- Seeding on a clean install: presets with `default: true`, once. A preset
  that became default later (Tailscale networks) is added to existing
  users once.
- Copies of the same preset collapse at load — the last one stays.
- Enabling FakeIP toggles "Resolve destination IP" — see 005.
- A preset row in the list: a caption from the changed variables, a "DNS" chip if
  the preset touches DNS; a target picker — only for presets with a target.

## Boundaries

- The template language (`#if`, `#enable`, `for_each`, ref variables) —
  [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md).
- Presets are not carried over by rule exchange — [rule-transfer](rule-transfer.md).
- The user does not create own presets.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [033F](../../../tasks/033F-preset-bundles/spec.md) | Active (v1.5.0) | A preset as a self-contained bundle with variables, a reference instead of a copy |
| 2 | [010](../../../tasks/010-preset-bundles.md) | ✅ Implemented | The first implementation of bundles, `ru-direct` |
| 3 | [067](../../../tasks/067-selectable-rule-legacy-cleanup.md) | Released v1.9.0 | Every preset must have a `preset_id` |
| 4 | [121](../../../tasks/121-preset-routing-king-dns-orphans.md) | Released v2.1.0 | A disabled preset leaves no DNS tails |
| 5 | [162](../../../tasks/162-block-unknown-default-reject-outbound.md) | Done | Default `reject` → `action: reject` |
| 6 | [228](../../../tasks/228-fakeip-preset.md) | implementation | The FakeIP preset, cleanup of outbound variables |
| 7 | [246](../../../tasks/246-preset-rule-array.md) | — | A preset yields several rules: `resolve ipv4_only` + route |
| 8 | [264](../../../tasks/264-traffic-processing-preset.md) | device-verified | Traffic Processing: first, pinned |
| 9 | [265](../../../tasks/265-ref-vars.md) | device-verified | Variables referencing global values |
| 10 | [266](../../../tasks/266-preset-on-change.md) | device-verified | A preset's reaction to a change (FakeIP → resolve) |
| 11 | [364](../../../tasks/364-fcm-push-bypass-preset.md) | implemented | The Google push (FCM) preset |
| 12 | [371](../../../tasks/371-vowifi-direct.md) | implemented, device-pending | The VoWiFi preset, the ePDG suffix in Ru internet segment |
| 13 | [441](../../../tasks/441-template-preset-vars-in-record.md) | Released v2.24.0 | Variable defaults are not stored |
| 14 | [571](../../../tasks/571-rule-conditions-allowlist.md) | Done | A rule without conditions drops out |
| 15 | [578](../../../tasks/578-tailscale-preset-template-for-each.md) | Spec, implementation started | The Tailscale preset: a rule per node, late seeding |
