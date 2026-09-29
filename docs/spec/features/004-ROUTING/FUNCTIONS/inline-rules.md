[English](inline-rules.md) · [Русский](inline-rules.ru.md)

# Rule by conditions (Inline) — matching by domain, IP, port, app, protocol and network

An Inline rule lists the traffic to catch in its own fields — domains, IP networks, ports, apps,
protocol, network, source, inbound, Wi-Fi — and the target to send it to.

| Field | Value |
|------|----------|
| Feature | [004-ROUTING](../FEATURE.md) |
| Promises | P4 P5 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The user describes which traffic to catch directly with the rule's fields: domains,
IP networks, ports, apps, L7 protocol, transport, source, inbound, Wi-Fi
network — and where to send it. This is the default rule kind for "+ Add rule".
A rule by app belongs here too: packages are chosen from the list of
installed apps and matched by the core by `package_name`.

## Parameters

| Editor section | Field | Core key | Where it is emitted |
|---|---|---|---|
| MATCH | Domain | `domain` | headless rule_set |
| | Domain suffix | `domain_suffix` | headless |
| | Domain keyword | `domain_keyword` | headless |
| | IP CIDR (quick inserts: Localhost, Wi-Fi subnet, All) | `ip_cidr` | headless |
| | Private IP | `ip_is_private` | route rule |
| | Source IP CIDR | `source_ip_cidr` | headless |
| | Private source IP | `source_ip_is_private` | route rule |
| PORT | Port / Port range (`8000:9000`, `:3000`, `4000:`) | `port` / `port_range` | headless |
| APPS | app selection | `package_name` | headless |
| NETWORK & PROTOCOL | `tcp` · `udp` · `icmp`; `bittorrent` `dns` `dtls` `http` `ntp` `quic` `rdp` `ssh` `stun` `tls` | `network`, `protocol` | route rule |
| INBOUND | `tun-in` · `mixed-in` | `inbound` | route rule |
| WI-FI NETWORK | see [wifi-conditions](wifi-conditions.md) | `wifi_ssid`/`wifi_bssid` | headless |

The rule name is required and unique among the visible names of the list (including
preset titles). Target and action — [rule-actions](rule-actions.md).

## Inputs / Outputs

**Inputs:** field text (one per line or comma-separated), app selection.
**Outputs:** a `route.rule_set[]` of type `inline` with tag = the rule name and one
route rule `{rule_set: <name>, …, outbound|action}`; with an empty
headless match — a route rule without `rule_set`.

## Rules and invariants

- Within a category conditions are combined by OR, between categories — by AND
  (domains+IPs · ports · apps · protocol · …).
- Input normalization: lower case, `http(s)://` and a trailing
  `/` are cut, the suffix loses a leading dot; IDN → punycode (`.рф` → `xn--p1ai`);
  a bare IPv4 gets `/32`, IPv6 — `/128`.
- Validation: a domain is an FQDN with an alphabetic TLD; a suffix allows a bare TLD
  (`ru`); keyword without spaces; CIDR with a correct mask; port 0..65535;
  a range with at least one bound and `lo ≤ hi`. Invalid elements
  are highlighted with an "N · M invalid" counter, non-numeric ports do not get into
  the config.
- A rule without a single condition is saved but does not go into the config; the list shows
  the caption "Tap to add match fields".
- A disabled rule yields neither a rule_set nor a route rule.
- A rule_set tag collision with an existing one → suffix ` (2)`.
- The View tab shows the storage record and what the rule will produce in the config,
  regardless of the on/off switch.
- A rule by app sees only traffic that already got into the core; in Proxy
  mode app attribution, per the template hint, does not work.

## Boundaries

- There is no condition negation; `domain_regex`, `source_port` are not exposed in the form —
  available via [raw JSON](raw-json-rules.md).
- Which apps go into the tunnel at all —
  [011-SPLIT_TUNNELING](../../011-SPLIT_TUNNELING/FEATURE.md).
- A rule's DNS option — [005-DNS](../../005-DNS/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [030F](../../../tasks/030F-custom-routing-rules/spec.md) | Active (v1.4.0) | A unified rule model: apps, domains, IPs, ports, protocol, private IP |
| 2 | [030F/new_fields](../../../tasks/030F-custom-routing-rules/new_fields.md) | — | Source (`source_ip_cidr`, `source_ip_is_private`) and `inbound` |
| 3 | [011](../../../tasks/011-sealed-customrule-split.md) | ✅ Implemented | Separate rule kinds: inline / srs / preset |
| 4 | [053](../../../tasks/053-custom-rule-editor-split.md) | Done | The editor split into MATCH/PORT/APPS/… sections |
| 5 | [064](../../../tasks/064-view-tab-preview-independent-of-enabled.md) | done | The View preview does not depend on the switch |
| 6 | [144](../../../tasks/144-domain-suffix-validator.md) | Done | A separate suffix check, IDN → punycode |
| 7 | [240](../../../tasks/240-network-matcher.md) | in develop | The `network` filter and the NETWORK & PROTOCOL section |
