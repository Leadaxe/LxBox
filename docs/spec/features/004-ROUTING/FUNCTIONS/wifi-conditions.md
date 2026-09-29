[English](wifi-conditions.md) · [Русский](wifi-conditions.ru.md)

# Wi-Fi conditions

| Field | Value |
|------|----------|
| Feature | [004-ROUTING](../FEATURE.md) |
| Promises | P20 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Makes a rule conditional on the network: it applies only when the phone
is connected to one of the listed Wi-Fi networks (by SSID name and,
optionally, by access point BSSID). For example, "at home — direct, on other
networks — via VPN".

## Parameters

| Field | Format | Core key |
|---|---|---|
| Network (chip) | SSID, optionally BSSID `xx:xx:xx:xx:xx:xx` | `wifi_ssid`, `wifi_bssid` |

Ways to add a chip: **Add current** (the current network), **Pick saved** (from
the history of seen networks), manually. Available for inline and `.srs` rules.

## Inputs / Outputs

**Inputs:** the current network from the OS; network history; user input.
**Outputs:** for inline — into the headless rule_set; for `.srs` — at the route
rule level. The condition is checked at runtime by the core, asking the OS about the current
Wi-Fi.

## Rules and invariants

- No chips — no condition, the rule applies on any network ("No Wi-Fi
  conditions — rule is active on every network").
- The Wi-Fi condition is combined by AND with the rest of the rule's match.
- BSSID is normalized to lower case; an empty BSSID is allowed (match only
  by name). Repeats are not written.
- Several chips with different pairs give independent SSID and BSSID lists —
  a cross match is possible (the SSID of one pair + the BSSID of another);
  a conscious risk, in practice a BSSID is unique.
- Reading the current network names the specific reason for a failure: no permission
  for nearby Wi-Fi devices, no precise location, location
  is off, no background location; "Not connected to Wi-Fi" if there is
  no network. The advice "toggle Wi-Fi" is not given where the reason lies in
  permissions.
- Without the needed permissions the core does not see the network name — the condition does not match.

## Boundaries

- There are no "mobile network", "network type", "no network" conditions — only Wi-Fi.
- Reading SSID/BSSID depends on OS capabilities and granted permissions
  (location, including background and precise; nearby devices on newer OSes).
- Permission diagnostics in the log — [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [051](../../../tasks/051-custom-rule-wifi-conditions.md) | released v14010 | Conditions `wifi_ssid`/`wifi_bssid`, Add current, network history |
| 2 | [030F/new_fields](../../../tasks/030F-custom-routing-rules/new_fields.md) | — | With core 1.14 the Wi-Fi condition of an inline rule is in the headless rule_set |
| 3 | [567](../../../tasks/567-wifi-ssid-read-preflight-and-diagnostics.md) | Done | Checking precise location and whether it is enabled, an honest failure reason |
| 4 | [569](../../../tasks/569-wifi-ssid-transport-info-api31.md) | Done | Reading SSID on newer OSes via network transport info |
