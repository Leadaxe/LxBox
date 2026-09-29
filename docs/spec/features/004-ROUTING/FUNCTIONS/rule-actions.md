[English](rule-actions.md) · [Русский](rule-actions.ru.md)

# Rule action

| Field | Value |
|------|----------|
| Feature | [004-ROUTING](../FEATURE.md) |
| Promises | P6 P7 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Defines what happens to matched traffic: send it to a Direction
or direct, block it, or first resolve the domain (for example,
only to IPv4) and then send it. The target is chosen with a picker in the list row
or in the editor, the mode — in the **Action & Resolve** sheet.

## Parameters

| Choice | What goes into the config |
|---|---|
| `direct` | `outbound: direct-out` |
| Direction (`vpn-1`, …) | `outbound: <tag>` |
| `block` | `outbound: block` (the service block outbound) |
| Reject | `action: reject` |
| Route to outbound | only the route rule (default) |
| Resolve first | `{…match, action: resolve, …}` before the route rule |
| Resolve only | a single `action: resolve` without a route; traffic continues down the list |

Resolve options (empty — the key is not written): Strategy (`prefer_ipv4`,
`prefer_ipv6`, `ipv4_only`, `ipv6_only`; empty — inherits DNS), DNS server
(empty — "auto", DNS routing), Advanced: Disable cache, Disable
optimistic cache, Rewrite TTL (sec), Query timeout (`5s`), Client subnet
(CIDR). The sheet shows a preview of the resulting `route.rules`.

## Inputs / Outputs

**Inputs:** the choice of target and mode; the list of Directions; DNS servers.
**Outputs:** the route rule's `outbound`/`action`; with resolve — one or two
rules with the same match (including `network`, ports, Wi-Fi).

## Rules and invariants

- `reject` is never written as an `outbound` target — only as an action;
  this also holds for preset defaults.
- "Resolve first": the resolve rule always stands immediately before its
  route rule and repeats its match entirely.
- "Resolve only": the chosen target is kept in the rule (a mode change does not
  lose it), but does not go into the config; in the list the rule has the ✳ badge.
- Resolve applies only if there is something to resolve: for inline — when there are
  domain conditions (otherwise the option is hidden and not emitted); for `.srs` — always.
- A resolve DNS server that disappeared from the server list is reset to "auto"
  on rule import; in the sheet it is shown as "… (missing)".
- The actions `hijack-dns`, `sniff`, `route-options` and others — only via
  [raw JSON](raw-json-rules.md) or the Traffic Processing preset.
- The DNS option ("Send DNS to dedicated server", "Force IPv4 (drop AAAA)") is
  a separate section, unavailable with port/protocol/network filters; its
  effect is described in [005-DNS](../../005-DNS/FEATURE.md).

## Boundaries

- `block` and Reject differ for the core (an outbound versus an action); in the
  UI both are red. Choosing between them is up to the user.
- Checking by which rule and where a connection went —
  [012-LIVE_STATE](../../012-LIVE_STATE/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [030F](../../../tasks/030F-custom-routing-rules/spec.md) | Active (v1.4.0) | A rule target or "Reject (block)" |
| 2 | [201](../../../tasks/201-block-outbound-for-channels.md) | IMPLEMENTED | `block` as a target of rules and Default traffic |
| 3 | [247](../../../tasks/247-custom-rule-resolve-action.md) | — | Resolve first / Resolve only for own rules |
| 4 | [256](../../../tasks/256-rule-force-ipv4-dns.md) | IMPLEMENTED | Force IPv4 on a rule (the DNS layer, see 005) |
| 5 | [231](../../../tasks/231-dns-badge-on-rules.md) | implementation | The "DNS" chip on rules that touch DNS |
| 6 | [263](../../../tasks/263-resolve-enabled-toggle.md) | device-verified | The global "Resolve destination IP" |
