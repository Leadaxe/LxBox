[English](resolvers-and-strategy.md) · [Русский](resolvers-and-strategy.ru.md)

# Default resolvers and strategy — dns.final, the core resolver and IPv4/IPv6 preference

Three global settings decide where unmatched app queries go, which server the core itself uses for
node and rule domains, and which IP version is preferred; the build heals references to vanished
servers.

| Field | Value |
|------|----------|
| Feature | [005-DNS](../FEATURE.md) |
| Promises | P6 P7 P8 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Sets the three global DNS knobs: where application queries that match no
rule go (`dns.final`); what the core itself uses to resolve node server
names and rule domains (`route.default_domain_resolver`); which IP version
to prefer (`dns.strategy`). Keeps their references alive: if the chosen
server vanished, the build substitutes it instead of failing.

## Parameters

| Setting | Template variable | Values | Default | Core key |
|---|---|---|---|---|
| DNS Final ("For apps") | `dns_final` | server tag | `dns_shield` | `dns.final` |
| Default Domain Resolver ("For routing") | `dns_default_domain_resolver` | server tag | `dns_shield` | `route.default_domain_resolver` |
| Strategy | `dns_strategy` | `prefer_ipv4` · `prefer_ipv6` · `ipv4_only` · `ipv6_only` | `ipv4_only` | `dns.strategy` |

The IPv6 toggle (another feature's knob), when switched, sets Strategy to
`prefer_ipv4` (on) or `ipv4_only` (off); after that Strategy is edited
freely.

## Inputs / Outputs

**Inputs:** saved variables, their `default_value` in the template, the list
of available servers (enabled + locked), the built `dns.servers`.
**Outputs:** three config keys; the saved replacement of a broken
reference; an on-screen warning about the system resolver.

## Rules and invariants

- Not set or an empty string — the template's `default_value` applies; the
  screen shows what will be built (P8).
- Choice — only among available servers; `fakeip` and `hosts` do not get
  into the pickers. If a reference still points to `fakeip`/`hosts` (JSON,
  import) — fatal before start "invalid resolver type".
- A vanished server:
  - on the screen — on open the value is reset to the template default and
    the config is marked for rebuild;
  - in the build — replaced with the template default if it is emitted and
    suitable, otherwise the first suitable server; the replacement is saved
    so the next build is clean. No suitable ones — left untouched, the
    pre-start check gives the fatal "dangling reference to a DNS server".
- A server dropped because of a dangling channel: `dns.final` is removed,
  `{"action":"reject"}` is added as the last rule (without `final` the core
  would take the first server — the system resolver); the core resolver is
  replaced, but the replacement is not saved — the channel comes back, the
  choice comes back.
- `local_dns_resolver` as Default Domain Resolver — a yellow warning "System
  DNS leaks lookups to your ISP" with a "Switch to cloudflare_udp" button
  (if such a server exists). As DNS Final it is allowed.
- A Strategy outside the four values is displayed on the screen as
  `ipv4_only`.

## Boundaries

- `resolve_strategy` of the Traffic Processing preset (destination resolving
  during routing) — [004-ROUTING](../../004-ROUTING/FEATURE.md).
- Strategy inside an individual DNS rule — a rule field, see
  [DNS rules](dns-rules.md).
- The variable mechanism and the "Settings changed" banner —
  [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [014F](../../../tasks/014F-dns-settings/spec.md) | Spec | Strategy, Final and Default Resolver on the screen |
| 2 | [039](../../../tasks/039-empty-template-dns-rules.md) | Implemented | Remaining queries go to `dns.final`, not to a catch-all rule |
| 3 | [121](../../../tasks/121-preset-routing-king-dns-orphans.md) | Released | Reset of a vanished resolver and check of dangling references |
| 4 | [206](../../../tasks/206-dns-final-default-cloudflare.md) | — | The `dns_final` default moved from the system resolver to `cloudflare_udp` (now — `dns_shield`) |
| 5 | [249](../../../tasks/249-ipv4-default-strategy.md) | — | `ipv4_only` by default, the IPv6 toggle changes the strategy |
| 6 | [327](../../../tasks/327-dns-resolver-defaults-from-template.md) | Implemented, device-pending | Defaults — only from the template |
| 7 | [384](../../../tasks/384-fakeip-resolver-gate-and-lost-running-snapshot.md) | Done | `fakeip`/`hosts` are not allowed under resolvers |
| 8 | [419](../../../tasks/419-dangling-dns-resolver-heal-in-build.md) | Done | A broken resolver is healed in the build and saved |
| 9 | [443](../../../tasks/443-contract-1-0-2-spec129.md) | Released | `dns.final` pointing to a server dropped because of its channel — removal + reject |
