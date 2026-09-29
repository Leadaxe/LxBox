[English](fakeip.md) · [Русский](fakeip.ru.md)

# FakeIP

| Field | Value |
|------|----------|
| Feature | [005-DNS](../FEATURE.md) |
| Promises | P6 P11 P12 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Answers an application's name query instantly — with a substitute address
from a service pool, without going to the network; the core recalls the real
name by that address and resolves it inside the tunnel along the route.
Gives DNS speed and removes DNS queries before the tunnel. It is not a DPI
bypass — the preset description says so.

## Parameters

The "FakeIP" preset (disabled by default):

| Variable | Visible | Meaning | Default |
|---|---|---|---|
| `dns_enable` ("DNS") | yes | FakeIP processing on/off without removing the preset | on |
| `force` ("Block HTTPS records") | yes | answer `HTTPS`/`SVCB` with an empty response so the application takes A/AAAA | on |
| `dns_server` | no | the issuing server | `fakeip` |

Hands to the core:

- the server `{type: fakeip, tag: fakeip, inet4_range: 198.18.0.0/15, inet6_range: fc00::/18}`
  (in the config — in the preset namespace);
- rules: with `force` — `{query_type: [HTTPS, SVCB], action: predefined, rcode: NOERROR}`,
  then `{query_type: [A, AAAA], server: <fakeip>}`;
- `experimental.cache_file.store_fakeip: true` (always, in the template) —
  allocations survive a restart.

## Inputs / Outputs

**Inputs:** enabling the preset, its variables.
**Outputs:** server and rules in the config; the `resolve_enabled` variable
of the global "Resolve destination IP".

## Rules and invariants

- Enabling the preset with `dns_enable` on sets `resolve_enabled=false`: real
  destination resolving would bypass FakeIP and could fail on a broken
  resolver. Disabling the preset or its DNS — `resolve_enabled=true` (P12).
- The `fakeip` server is not allowed under `dns.final`, the core resolver or
  as a group member: the pickers do not offer it, otherwise — fatal before
  start (P6). In a DNS rule it is legal.
- `query_type` in FakeIP rules switches the core into non-legacy DNS mode;
  `strategy` in any DNS rules is removed (P11).
- FakeIP's place relative to other DNS rules is the preset's place in
  routing order (the atomic mirror group); the preset description advises
  placing it below special domains so that direct routing by GeoIP keeps
  working.
- "Clear DNS cache" also resets FakeIP allocations.

## Boundaries

- The "Resolve destination IP" and "Hijack DNS" toggles — the Traffic
  Processing preset, [004-ROUTING](../../004-ROUTING/FEATURE.md); FakeIP
  does not work without Hijack DNS (the toggle's hint says so).
- Display of substitute addresses in connections — [012-LIVE_STATE](../../012-LIVE_STATE/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [228](../../../tasks/228-fakeip-preset.md) | — | FakeIP preset: server, A/AAAA rule, `store_fakeip` |
| 2 | [246](../../../tasks/246-preset-rule-array.md) | — | Removal of legacy `strategy` with `query_type` |
| 3 | [253](../../../tasks/253-preset-dns-rules-array.md) | — | Preset DNS rule array, HTTPS/SVCB suppressor |
| 4 | [263-resolve](../../../tasks/263-resolve-enabled-toggle.md) | device-verified | FakeIP switches off destination resolving |
| 5 | [263-cache](../../../tasks/263-clear-dns-cache.md) | implemented | FakeIP allocations reset together with the cache |
| 6 | [384](../../../tasks/384-fakeip-resolver-gate-and-lost-running-snapshot.md) | Done | FakeIP cannot be the default resolver |
