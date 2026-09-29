[English](builtin-dns-sets.md) · [Русский](builtin-dns-sets.ru.md)

# Built-in DNS sets — encrypted dns_shield and the dns_ru group for Russian domains

DNS works without any setup: the encrypted `dns_shield` group handles everything by default, and the
`ru-direct` preset gives Russian domains their own `dns_ru` group.

| Field | Value |
|------|----------|
| Feature | [005-DNS](../FEATURE.md) |
| Promises | P16 P17 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Provides working DNS out of the box, without a single setting: the encrypted
`dns_shield` group for everything that did not match, and a separate
`dns_ru` group for Russian domains (the `ru-direct` preset, enabled by
default). Both sets are template data; the user changes them via variables,
not by editing bodies.

## Parameters

**`dns_shield`** (a template server, `type: group`, `mode: fastest`,
`error_ttl: 5m`, `win_ttl: 5m`) — the default of `dns.final` and
`route.default_domain_resolver`. Members:

| Member | Type | Default channel |
|---|---|---|
| `google_doh` | DoH, SNI `dns.google` | Direct |
| `google_dot` | DoT | `vpn-1` |
| `cloudflare_dot` | DoT | `vpn-1` |
| `opendns_doh` | DoH, SNI `dns.opendns.com` | Direct |
| `quad9_doh` | DoH, SNI `dns.quad9.net` | `vpn-1` (hard-wired) |
| `yandex_dot` | DoT `77.88.8.8`, SNI `common.dot.dns.yandex.net` | Direct |

**`ru-direct` → DNS** (preset variables):

| Variable | Meaning | Default |
|---|---|---|
| `dns_enable` ("DNS") | the preset's DNS part on/off | on |
| `dns_ip` ("UDP server IP") | address of the UDP member: Base / Safe / Family, v4/v6 | `77.88.8.8` |
| `force_ipv4` ("Force IPv4") | do not return AAAA for ru domains | on |
| `outbound` | the preset's channel (and the UDP member's) | `direct-out` |

The `dns_ru` group (`fastest`, `error_ttl 5m`, `win_ttl 5m`) over three
members on independent paths: `yandex_udp` (`@dns_ip`, through the preset's
channel), `yandex_dot` (`77.88.8.88`, SNI `safe.dot.dns.yandex.net`, via
`vpn-1`), `yandex_doh` (`77.88.8.88`, direct). The preset's DNS rules: for
`ru-domains` + `ru-services` with Force IPv4 —
`{ip_version: 6, action: predefined, rcode: NOERROR}`, then
`{server: dns_ru, action: route}`. In routing, Force IPv4 adds `resolve`
with `strategy: ipv4_only` before the route.

## Inputs / Outputs

**Inputs:** the template, preset variable values, active Directions.
**Outputs:** servers and rules in `dns.servers` / `dns.rules`; in the config
preset servers live in the preset namespace (`ru-direct:dns_ru`,
`ru-direct:yandex_udp`, …).

## Rules and invariants

- All `dns_shield` members are declared in the template's base server list
  and there is no open UDP among them (P16).
- Members whose channel is absent drop out under the general policy; the
  group lives as long as at least one member is alive.
- `dns_enable` off — the preset gives neither `dns_ru` nor its rules;
  `ru-direct` routing works.
- Force IPv4 works through the preset's DNS rule: with `dns_enable` off the
  AAAA suppressor does not act.
- A disabled `ru-direct` (routing) removes the entire DNS part.
- Preset servers on the DNS screen are read-only, with a "used by <preset>"
  lock; they are edited via the preset's variables.

## Boundaries

- The set is not chosen by the user's region, and this is not planned
  (owner decision 2026-09-29, audit [588](../../../tasks/588-spec-kit-revision-audit.md)): `ru-direct` is enabled by
  default for everyone, the region setting does not affect DNS.
- `ru-direct` routing (rule-sets, GeoIP, applications) —
  [004-ROUTING](../../004-ROUTING/FEATURE.md).
- The Tailscale preset gives one MagicDNS server per node — described with
  Tailscale nodes ([030-TAILSCALE](../../030-TAILSCALE/FUNCTIONS/tailnet-dns-and-routes.md)),
  only the server type is here.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [038](../../../tasks/038-ru-direct-dns-defaults.md) | Implemented | `ru-direct`: UDP and the Base address by default |
| 2 | [045](../../../tasks/045-ru-direct-geoip-fallback.md) | Released | GeoIP layer of `ru-direct` (does not change DNS) |
| 3 | [117F](../../../tasks/117F-dns-rework/spec.md) | Released | Template servers with `outbound`/`dns_ip` variables, "Safe DNS" |
| 4 | [253](../../../tasks/253-preset-dns-rules-array.md) | — | Force IPv4 on the DNS layer of `ru-direct` |
| 5 | [257](../../../tasks/257-dns-enable-unify-and-force-ipv4-visibility.md) | — | The preset's `dns_enable` toggle |
| 6 | [354](../../../tasks/354-ru-dns-group.md) | implemented, device-pending | `dns_ru` — a group of three independent paths |
| 7 | [517](../../../tasks/517-editor-selection-and-dns-shield-udp.md) | Released | Open UDP removed from `dns_shield` |
| 8 | [527](../../../tasks/527-dns-shield-yandex-dot-base.md) | Released | Base record `yandex_dot` for the `dns_shield` member |
