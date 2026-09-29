[English](dns-cache.md) · [Русский](dns-cache.ru.md)

# DNS cache — size, stale answers, persistence and reset

The user sets how many DNS answers the core keeps, whether it serves stale answers while refreshing
and whether the cache survives a restart, and can clear the cache.

| Field | Value |
|------|----------|
| Feature | [005-DNS](../FEATURE.md) |
| Promises | P13 P14 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Manages the core's answer cache: how many answers to keep, whether to answer
from the cache immediately with a background refresh, whether the cache
survives a restart. Provides a one-off action — reset the whole cache when
it is "stuck".

## Parameters

| Setting | Template variable | Values | Default | Core key |
|---|---|---|---|---|
| DNS cache size | `dns_cache_capacity` | 1024..65535 | 4000 | `dns.cache_capacity` |
| Serve stale answers | `dns_optimistic` | on/off | on | `dns.optimistic` |
| Keep DNS cache after restart | `dns_store_cache` | on/off | on | `experimental.cache_file.store_dns` |
| Clear DNS cache | — | action with confirmation | — | deletes `cache.db` |

The cache file (`experimental.cache_file`, `path: cache.db`) is always on;
`store_fakeip: true` — always.

## Inputs / Outputs

**Inputs:** input on the DNS screen, saved variables, tunnel state.
**Outputs:** three config keys; a deleted `cache.db`; a core reload with the
tunnel up; a snackbar with the result.

## Rules and invariants

- A variable not set or saved out of range — the template default applies
  (4000, on, on); the screen shows the same.
- Size input outside 1024..65535 — error "Range 1024..65535" under the
  field, the value is not saved and does not get into the config. The
  bounds are inclusive.
- Any change of the three settings marks the config for rebuild.
- Clear DNS cache:
  - the dialog explains the consequence: with the tunnel up — "The VPN will
    briefly reload to apply", otherwise — "It will be rebuilt clean on the
    next connect";
  - the whole `cache.db` is deleted: FakeIP allocations, stored DNS records
    and anything else the core keeps in it;
  - tunnel up — the core is reloaded (connectivity is interrupted for a few
    seconds); tunnel down — only the file is deleted;
  - result: "DNS cache cleared — reloading" / "DNS cache cleared" /
    "Could not clear DNS cache".
- Reset is an action, not a setting: it does not trigger a config rebuild.

## Boundaries

- Record lifetime and the stale answer strategy — core behaviour.
- Deleting the file and reloading the core depend on OS capabilities.
- Resetting the core cache on an application failure — [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [014F](../../../tasks/014F-dns-settings/spec.md) | Spec | "Independent cache" on the screen (not implemented) |
| 2 | [263](../../../tasks/263-clear-dns-cache.md) | implemented, not device-verified | "Clear DNS cache" button |
| 3 | [580](../../../tasks/580-dns-cache-settings.md) | Done | Size, stale answers, persistence between launches |
