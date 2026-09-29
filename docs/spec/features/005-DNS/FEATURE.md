[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# DNS — encrypted DNS servers, DNS rules, failover groups, FakeIP and cache

LxBox manages the DNS section of the sing-box config: which servers resolve names, over which
channel, in which order and with what fallback. Out of the box, queries go to `dns_shield`, a race
of encrypted DoH and DoT providers, and Russian domains get their own `dns_ru` group. Without
writing JSON you can add servers of any core type, DNS rules, failover groups, FakeIP and cache
settings; a DNS setup the core would reject is never built, and a server that loses its channel
refuses queries instead of leaking them to a direct resolver.

| Field | Value |
|------|----------|
| Feature | 005-DNS |
| Type | Product feature |
| Absorbed | `§014F` (DNS Settings screen), `§117F` (DNS rework: server variables, DNS on a rule, server editor, lifecycle), `§312F` (DNS groups) |
| State | ✅ written from code, 2026-09-28 |

## Purpose

The DNS section of the config determines privacy (whether the ISP sees the
queries), availability (whether the server is alive) and route correctness
(which IP a Russian site ends up on). The feature lets the user manage it
without hand-written JSON: a server catalog with channel selection, custom
servers of any core type, DNS rules, strategy, groups with failover,
FakeIP, cache.

The feature protects two principles. First, **a config built from the DNS
settings is either accepted by the core or not built at all — with a clear
reason.** Second, **fail-closed**: when a server is dropped because of its
channel, its domains are refused instead of leaking to a direct resolver.

DNS works out of the box without configuration: `dns.final` and the core
resolver are the `dns_shield` group (a race of encrypted providers); Russian
domains (with the `ru-direct` preset, enabled by default) get their own
`dns_ru` group.

## Promises

- **P1. A template server is resolved with variables; a direct channel —
  without `detour`.** The user's value from the server record, otherwise
  `default_value`; an empty one — the key is dropped. `detour` = `direct-out`
  or empty → the key is not written.
  **Witness:** unit "kind:template → server.tag, vars defaults, direct-out erased".
  **Mutation:** `detour: "direct-out"` gets into the config.
- **P2. Fail-closed on the channel.** A server whose `detour` points to a tag
  absent from the config is not emitted; DNS rules pointing to it become
  `action: reject`; `dns.final` pointing to it is removed and
  `{"action":"reject"}` is added as the last rule; resolvers
  (`route.default_domain_resolver`, `domain_resolver` of nodes and servers)
  switch to the template default. The build does not touch the user's choice
  in storage; only deleting or disabling the Direction itself heals it, by
  rewriting the channel to `vpn-1` (owner's decision 2026-09-29, §441).
  **Witness:** units "detour to a vanished Direction → server not
  emitted, warning", "rules → reject, final removed + reject stub, resolvers —
  template default". **Mutation:** remove only the `detour` key, keeping the
  server (queries go direct).
- **P3. A server that an active preset or rule relies on cannot be switched
  off.** It gets into `dns.servers` in any position of the toggle; in the UI
  the toggle is locked "on", deletion is hidden, a "used by …" label is
  shown. **Witness:** units "lifecycle (locked #7): a disabled server
  referenced by a rule — force-include in dns.servers", "locked (used by
  preset): editor sees lock and label". **Mutation:** filter by `enabled`
  with no exception for referenced servers.
- **P4. A disabled preset leaves no DNS tails.** A preset with routing
  switched off gives neither servers, nor DNS rules, nor locks. **Witness:**
  unit "§121 routing = king: route disabled suppresses the DNS aspect
  entirely". **Mutation:** the preset's DNS aspect is read regardless of
  whether it is enabled.
- **P5. An unavailable group member drops out with a warning; an empty group
  blocks the build.** Disabled / unknown / itself / duplicate — thrown out
  of emission with its own reason, storage unchanged. A group empty after
  filtering is not silently fixed → fatal before the core starts; the
  exception is a group emptied because of P2 — it drops out itself (and is
  healed like a server). **Witness:** units "disabled member thrown out with
  warning", "empty group → EmptyDnsGroup (fatal)", "a group emptied by a
  dangling detour drops out together with the enclosing one". **Mutation:**
  throw out an empty group silently.
- **P6. Core prohibitions are caught before start.** `fakeip`/`hosts` under
  `dns.final`, `route.default_domain_resolver` or as a group member; a group
  cycle — build fatal. `detour` on a group and on `tailscale` is removed at
  build time. **Witness:** units "dns.final = fakeip → fatal", "fakeip/hosts
  member → BadDnsGroupMember", "group cycle → DnsGroupCycle, one per ring",
  "§319 detour on a group is cleaned out of emission". **Mutation:** let
  `detour` through on a group — the core crashes on an extra key.
- **P7. A vanished resolver is healed by the build.** `dns.final` /
  `route.default_domain_resolver` pointing to a server absent from the built
  list are replaced with the template default (or the first suitable
  non-`fakeip`/`hosts` one) and the replacement is saved. **Witness:** unit
  "both references broken → template defaults, var names for persistence".
  **Mutation:** keep the broken reference — a perpetual "Settings changed"
  banner with a fatal.
- **P8. Defaults come from the template, one place.** On a clean install the
  screen and the build show/build the same thing: Final and Default Domain
  Resolver — `dns_shield`, Strategy — `ipv4_only`. **Witness:** unit "clean
  install — Final/Resolver/Strategy = template default_value".
  **Mutation:** a literal default on the screen that differs from the
  template.
- **P9. The order of DNS rules is the user's order; mirrors of routing rules
  are an atomic group.** The resulting `dns.rules` repeats the list order;
  DNS mirrors of presets and rules go as one group in routing order; a
  mirror pointing to a missing server is silently not emitted. **Witness:**
  units "linear order: storage order == final dns.rules order", "group order
  = order of routing rules (preset + rule)", "missing server → DNS rule
  silently not emitted (decision #3)". **Mutation:** sort rules by kind.
- **P10. Renaming a server does not break references.** The new tag is
  cascaded into `domain_resolver` of other servers, server variables, DNS
  rules, `dns.final`, the resolver and DNS options of routing rules.
  **Witness:** unit "cascade: domain_resolver, dns_servers vars, §061 rules,
  resolvers". **Mutation:** rename without cascade.
- **P11. A legacy `strategy` in DNS rules does not break start.** If the
  config contains `query_type` or `ip_version` (FakeIP, Force IPv4),
  `strategy` is removed from all DNS rules. **Witness:** unit "strategy +
  query_type in config (FakeIP) → strategy removed". **Mutation:** do not
  remove it — core 1.14 fatal.
- **P12. FakeIP switches off destination resolving.** Enabling the FakeIP
  preset with DNS enabled sets `resolve_enabled=false`; disabling it sets it
  back. **Witness:** units "FakeIP enabled + dns_enable(default true) →
  resolve_enabled=false", "FakeIP disabled → resolve_enabled=true".
  **Mutation:** FakeIP with real destination resolving.
- **P13. Cache: out-of-range values are not saved.** Cache size is
  1024..65535; out-of-range input shows an error and gets neither into
  storage nor into the config (4000 applies). **Witness:** unit "out of range
  ($bad) does not get into config — 4000 applies", widget test "size: within
  range is saved, out of range is not". **Mutation:** saving any number.
- **P14. DNS cache reset.** "Clear DNS cache" deletes `cache.db` entirely
  (FakeIP allocations, DNS records); with the tunnel up the core is reloaded.
  **Witness:** manual check — tunnel up, Clear → snackbar "DNS cache
  cleared — reloading", FakeIP addresses are allocated anew. No autotest,
  not confirmed on a device (§263). **Mutation:** delete only the FakeIP
  part.
- **P15. Live group state — a snapshot on screen open.** With the tunnel up,
  the current target and per-member ✓/✗, RTT, errors are shown under the
  group; a core without the method or a tunnel down — no line, the screen
  does not break. **Witness:** unit "empty/broken map does not crash"
  (mapping); display — manual check. **Mutation:** timer polling.
- **P16. `dns_shield` — encrypted members only, all declared** in the base
  server list. **Witness:** units "§527 every dns_shield member is declared in
  the BASE dns_options.servers", "the fastest group of the dns_shield preset
  has no open udp servers". **Mutation:** a group member missing from the
  list.
- **P17. Russian domains — through a group of three independent paths.**
  `ru-direct` gives `dns_ru` (`fastest`) over UDP through the preset's
  channel, DoT through `vpn-1` and DoH direct; with Force IPv4, AAAA for ru
  domains is suppressed. **Witness:** units "ru-direct (defaults) → dns_ru +
  three members over different paths", "ru-direct: force_ipv4=false → route
  without resolve, DNS without AAAA gate". **Mutation:** a single server
  through the preset's channel.

## Controlled parameters

| Setting (DNS screen) | Values | Default | Core config key |
|---|---|---|---|
| Servers: on/off, custom, overrides | list | template catalog (see [servers](FUNCTIONS/dns-servers.md)) | `dns.servers[]` |
| Strategy | `prefer_ipv4` · `prefer_ipv6` · `ipv4_only` · `ipv6_only` | `ipv4_only` | `dns.strategy` |
| DNS Final | tag of an enabled server, not `fakeip`/`hosts` | `dns_shield` | `dns.final` |
| Default Domain Resolver | same | `dns_shield` | `route.default_domain_resolver` |
| DNS rules | custom / template / preset / by rule-set | preset mirrors | `dns.rules[]` |
| DNS cache size | 1024..65535 | 4000 | `dns.cache_capacity` |
| Serve stale answers | on/off | on | `dns.optimistic` |
| Keep DNS cache after restart | on/off | on | `experimental.cache_file.store_dns` |
| Clear DNS cache | action | — | deletes `cache.db` |

Related settings of other features: "Hijack DNS", "Resolve destination IP"
(the Traffic Processing preset, [004-ROUTING](../004-ROUTING/FEATURE.md)),
DNS on a preset (`dns_enable`) and on a rule, the IPv6 toggle (it changes
Strategy).

Server keys the feature hands to the core: `type` (`local`, `udp`, `tcp`,
`tls`, `https`, `quic`, `h3`, `fakeip`, `group`, `tailscale`, …), `tag`,
`server`, `server_port`, `path`, `tls{server_name}`, `detour`,
`domain_resolver`; for a group — `servers`, `mode`
(`stable`/`fastest`/`parallel`), `error_ttl`, `win_ttl`; for FakeIP —
`inet4_range`, `inet6_range`; `experimental.cache_file.store_fakeip: true`.

## Inputs / Outputs

**Inputs:** the template's DNS section (wrapper servers with variables,
presets with `dns_servers`/`dns_rules`); user records (servers by kind,
rules, variables); routing rules with a DNS option; the list of active
Directions and nodes (for `detour`, the Tailscale `endpoint`); the group
snapshot from the core (`getDNSGroups`).

**Outputs:** the keys from the table above; build warnings (snackbar and
log); fatal reasons of the pre-start check; live group lines on the screen.

## Data flow

```
template (servers, presets)   user records   routing rules
          │                        │                 │
          ▼                        ▼                 ▼
  LIST COMPLETION: new servers/rules of the template and active presets
  are appended, orphans (vanished preset/template) removed, own items intact
          ▼
  SERVER BODIES: variable substitution → removal of service fields →
  filter out disabled (except referenced ones, P3) → detour: direct-out
  removed, dangling → server dropped (P2) → Tailscale without endpoint
  dropped → filter group members by emitted ones (P5)
          ▼
  RULES: the user's list in order, mirrors as an atomic group (P9);
  srs rule without a downloaded file — skipped
          ▼
  HEALING: rules/final/resolvers pointing to dropped ones → reject/replace (P2);
  broken resolvers → template default (P7); legacy strategy (P11)
          ▼
  PRE-START CHECK: dangling final/resolver, fakeip/hosts,
  empty groups, cycles (P5, P6) ── fatal → config not built
          ▼
  core config  ──►  core  ──►  getDNSGroups (snapshot on screen, P15)
```

## Rules and guarantees

- Server kinds: **template** (from the catalog, only variables and the
  description are editable), **preset** (from an active preset, read-only,
  parameters live in the preset's rule), **custom** (any body). A custom one
  with the tag of a template or preset server is an **override**
  ("Overridden"); it can be reset to the original.
- The tag is the server's only identifier (on a repeat, the first wins);
  preset server tags live in the preset's namespace (`ru-direct:dns_ru`).
- `detour` — only from active Directions; a vanished channel stays in
  storage (the channel comes back — the server comes back).
- The Final/Resolver pickers do not offer `fakeip`/`hosts`; neither do group
  members.
- A rule's DNS option references a server by tag; the rule does not touch
  its detour.
- Changes on the screen mark the config for rebuild; writing to disk is
  deferred, on leaving the screen.

## Boundaries

- The overall config build, the template language, variables and the
  "Settings changed" banner — [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md).
- Routing rules, presets as such, Hijack DNS, "Resolve destination IP", the
  DNS option in the rule editor — [004-ROUTING](../004-ROUTING/FEATURE.md);
  here — only their DNS trace.
- The core's DNS query stream (`subscribeDNSQueries`) —
  [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md); the group trace in the
  profiler and the "DNS failing en masse while the link is alive" detector —
  [028-TRAFFIC_PROFILER](../028-TRAFFIC_PROFILER/FUNCTIONS/dns-trace.md); the
  Debug API `/settings/dns_options/*` —
  [027-DEBUG_API](../027-DEBUG_API/FUNCTIONS/write-operations.md).
- Carrying DNS records in a backup and merging — [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md).
- Tailscale nodes and their preset — not here; the feature only provides
  the `tailscale` server type in the form. In detail —
  [030-TAILSCALE](../030-TAILSCALE/FEATURE.md).
- There are no regional DNS sets: `ru-direct` is enabled by default for
  everyone, the usage region does not affect DNS. Regional DNS presets
  (`014F`) are not planned (owner decision 2026-09-29, audit [591](../../tasks/591-spec-kit-revision-audit.md)).
- There is no one-off "test DNS servers" button and there will not be one
  (§365).
- Deleting `cache.db` and reloading the core depend on OS capabilities.

## Functions

| Function | What it does | Promises | File |
|---|---|---|---|
| DNS server catalog | Lists template, preset and custom DNS servers with a form by type, channel choice, name resolver, safe rename and override. | P1 P2 P3 P4 P10 | [dns-servers.md](FUNCTIONS/dns-servers.md) |
| DNS groups | Combines servers into a `group` with `stable`/`fastest`/`parallel` mode, filters out unavailable members and shows live state. | P5 P6 P15 | [dns-groups.md](FUNCTIONS/dns-groups.md) |
| DNS rules | Builds one ordered `dns.rules` list from custom, template and rule set rules plus mirrors of presets and routing rules. | P4 P9 P11 | [dns-rules.md](FUNCTIONS/dns-rules.md) |
| Default resolvers and strategy | Sets `dns.final`, the core resolver and the IP strategy, and heals references to vanished servers. | P6 P7 P8 | [resolvers-and-strategy.md](FUNCTIONS/resolvers-and-strategy.md) |
| Built-in DNS sets | Provides the encrypted `dns_shield` group by default and the `dns_ru` group with Force IPv4 in the `ru-direct` preset. | P16 P17 | [builtin-dns-sets.md](FUNCTIONS/builtin-dns-sets.md) |
| FakeIP | Answers name queries with substitute addresses from a reserved pool and turns off destination IP resolving. | P6 P11 P12 | [fakeip.md](FUNCTIONS/fakeip.md) |
| DNS cache | Sets cache size, stale answers and persistence across restarts, and clears the whole cache on request. | P13 P14 | [dns-cache.md](FUNCTIONS/dns-cache.md) |

## Related features

- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — the DNS section is assembled, variables
  resolved and the "Settings changed" banner shown by the general config build.
- [004-ROUTING](../004-ROUTING/FEATURE.md) — presets, routing rules with a DNS option, Hijack DNS
  and "Resolve destination IP" leave their DNS trace here.
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — the core's DNS query stream and group trace live there.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — core cache reset on a failure.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — DNS records are carried and merged in a backup.
- [027-DEBUG_API](../027-DEBUG_API/FEATURE.md) — the Debug API `/settings/dns_options/*` routes.
- [028-TRAFFIC_PROFILER](../028-TRAFFIC_PROFILER/FEATURE.md) — the DNS query trace, the group trace and the mass DNS failure detector.
- [030-TAILSCALE](../030-TAILSCALE/FEATURE.md) — Tailscale nodes, the MagicDNS server per node and the tailnet DNS preset.

## Maintenance notes

- A template server's tag lives inside the wrapper's `server.tag`; changing the
  wrapper format without updating the build makes all template servers
  silently disappear (§117 task 1).
- An empty group must not be "healed" by throwing it out — the user would not
  see that their choice stopped working; only a group emptied because of its channel is
  thrown out (P2).
- The core treats `detour` on a group and on `tailscale` as an extra key and
  crashes; it is cleaned at build time, not only in the form, because old
  records already carry it (§319).
- Editing SNI in the form replaces the whole `tls` (defect §530); a custom
  DNS rule's reference to a deleted server is not checked by the client.
