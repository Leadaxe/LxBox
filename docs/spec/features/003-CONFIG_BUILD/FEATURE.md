[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# FEATURE 003 — CONFIG_BUILD — building the core config from nodes and settings

| Field | Value |
|------|----------|
| Type | Product feature |
| Absorbed | `§076F` (settings and config lifecycle: the staleness flag, banners, rebuild on return), `§120F` (template engine: typed variables, `#if`, ref variables) |
| State | ✅ written from code, 2026-09-28 |

## Purpose

The user does not write JSON for the core. They pick nodes, enable presets,
flip toggles — and the app turns this into one sing-box config. The feature
owns the transformation mechanism itself: the config template shipped inside
the app; the language of that template (variables with a declared type, conditions,
repetition over nodes); the pipeline of stages that assembles nodes, groups, rules
and DNS into a whole; the check of the result before start; and the lifecycle
"changed a setting → config rebuilt → core on the new config".

Three principles the feature protects:

1. **A config the core will not accept is not saved and never reaches the core.**
   What can be fixed by degradation is fixed with a warning; what cannot is
   fatal with a clear reason, and the previous config stays on disk.
2. **A setting edit is not lost.** The change is visible to the next build immediately,
   the "config is stale" flag goes out only on a successful build, and survives
   the process being killed.
3. **The banner does not lie.** "Config changed" is shown only when the core
   is actually running a different config; false banners are a defect.

## Promises

- **P1. A variable value is coerced by its declared type, not by its appearance.**
  `bool`/`int` are coerced, `text`/`secret`/`enum`/`outbound`/`dns_servers`
  go as a string verbatim: the password `1234` stays a string, `urltest_tolerance`
  goes as a number. **Witness:** unit tests "secret/text: NOT coerced even if they
  look like a number/bool", "urltest_tolerance is substituted as a number, not
  a string". **Mutation:** guess the type from the string contents.
- **P2. No value the core would reject goes into the config.** `int`
  is clamped to 0..65535; for a variable with bounds (`dns_cache_capacity`
  1024..65535) an out-of-bounds value is replaced with the default; an empty
  required one — with the default (except `secret` and optional ones). **Witness:**
  unit tests "int is clamped to 0..65535", "an out-of-bounds cache size does not get into the
  config — 4000 applies", "empty required int → default",
  "an empty optional one is not replaced with the default". **Mutation:**
  substitute the saved string as is.
- **P3. A condition is evaluated lazily; a false one without `#else` removes the node.**
  The discarded branch is not walked; an array element drops out, a key is removed.
  **Witness:** unit tests "outer condition false — a nested one in the discarded branch
  has no effect", "false without else — the element drops out", the contract corpus
  for the template engine. **Mutation:** walk both branches.
- **P4. A malformed shipped template is rejected at load, not at
  build.** Exception: a preset with an incomplete `for_each` is removed alone, the template
  lives. **Witness:** unit tests "the shipped template passes the check",
  "a broken #enable of the shipped template is rejected at load",
  "for_each without as — only this preset is removed". **Mutation:** validation
  only at build.
- **P5. Something unknown at runtime does not break the build, but is visible.** An undeclared
  `@name` stays a literal, an unknown `#` directive is removed — both with
  a warning code; template warnings go first in the build report
  and do not block saving. **Witness:** unit tests "unknown @name →
  the placeholder stays", "an unknown #-key neighbour is removed", widget test
  "N warnings — a snackbar, the button opens a sheet". **Mutation:** a silent drop.
- **P6. A preset's ref variable reads the global value.** Its own value
  in the preset record is ignored. **Witness:** unit tests "ref variable: value
  from globals → enabled", "no global value, only in the preset
  record → disabled". **Mutation:** read the ref from the preset record.
- **P7. `for_each` yields one body per node that actually made it into the
  config.** Zero nodes — the preset is empty; `filter` (for example `skip_presets`)
  excludes a node. **Witness:** unit tests "zero nodes — the preset is empty", "two nodes —
  repetitions in a row in node order, tags without a namespace", "filter false
  (skip_presets)". **Mutation:** serve a disabled node or one removed by a gate.
- **P8. The fixable is fixed by degradation before the check.** A dangling detour, a ghost
  group member, `route.final` to a vanished Direction (→ `vpn-1`),
  `resolve` to a missing DNS server, an unknown uTLS fingerprint (→
  `chrome`), a broken REALITY — are removed/replaced with a warning.
  **Witness:** unit tests "several broken detours → all removed, the valid one survived",
  "resolve referencing a missing server → server removed", "a garbage
  fingerprint → chrome with a record", "an odd short_id cleared, the node and config
  are alive". **Mutation:** keep the reference — a core fatal at start.
- **P9. The unfixable is fatal; the config is not saved.** A dangling rule reference,
  `route.final`, detour, `dns.final`/resolver; an empty urltest; a selector `default`
  outside its members; a detour/group ring. **Witness:** unit tests "a dangling
  rule reference → fatal", "a ring via a selector node→group→node — one
  culprit"; "not saved" — manual: build a detour ring → Start →
  a sheet with the culprits, the VPN does not start. **Mutation:** return JSON on fatal.
- **P10. An edit is visible to the next build immediately.** A mutation on a settings screen
  goes into the in-memory store right away; the disk write — on leaving the screen
  or minimizing. **Witness:** unit tests "staged rules are visible to a reader before
  the disk write", "an edit immediately raises the flag and is staged in memory".
  **Mutation:** give the build the state only after the disk write.
- **P11. The "config is stale" flag is neither lost nor lit for nothing.** It goes out
  only on a successful build; a mutation during a build keeps it; a disk
  write after the build does not re-raise it; a failed or empty subscription fetch
  does not light it. **Witness:** unit tests "toggling a subscription during
  a build does not lose the flag", "the write on leaving the screen does not re-raise the flag
  after a rebuild", "fetch failures do not raise the flag", "the same composition
  again — the flag is not raised". **Mutation:** clear the flag at the start of the build.
- **P12. Staleness survives the process being killed.** At launch the flag is
  restored by comparing the modification times of the settings and the config (with
  one-second precision) and the config is silently rebuilt. **Witness:** unit tests
  "a fresh config in the native part's directory → not stale", "a settings write
  with the flag raised does not touch the config (honestly stale)", "edit → flag
  cleared by a rebuild → write → clean". **Mutation:** look for the config in the wrong directory
  (§414) — a perpetual "dirty".
- **P13. The VPN starts on the current config.** There are unwritten changes
  or a build in flight — Start first awaits/does a rebuild (one for
  all triggers). **Witness:** no autotest — manual: edit a rule → immediately
  Start → in the log "Config built" comes before the core start.
- **P14. The banners are mutually exclusive.** The blue "Settings changed — tap to
  rebuild config" — the flag is raised and no build is running; "Config changed — restart
  VPN to apply" — the tunnel is up, the flag is cleared, the saved config diverged from
  the running one, and no auto-apply is in progress. **Witness:** unit tests "flag raised, but
  a build is running — no banner", "restart is not shown with the flag raised",
  "restart is not shown with the tunnel off", "restart is suppressed for the
  auto-apply window". **Mutation:** both banners at once.
- **P15. "Restart" does not light up if the core is already on this config.**
  The saved config is compared with the running one in the core's canonical form;
  no answer — the banner stays (an extra one is better than a missed one). **Witness:** unit tests
  "forms matched → fresh", "no snapshot of the running one → unknown, not
  fresh".
  **Mutation:** compare the file bytes with the previous build.
- **P16. Auto-restart — only when there is something to apply.** Checkbox on,
  tunnel up, the config diverged from the running one, the rebuild succeeded, not in
  cooldown. **Witness:** unit tests "all conditions met → restart", "tunnel
  down → no", "the core is already on this config → no", "cooldown → skip,
  the banner stays as the fallback path". **Mutation:** restart on every build.
- **P17. Selecting a member of an own group is applied live.** The core switches
  immediately, no banner; the choice is saved and gets into the config on the next
  start. **Witness:** unit test "live selection: the state is written, the config awaits a
  rebuild at start". **Mutation:** raise the staleness flag.

## Controlled parameters

| Setting | Values | Default | Core config key |
|---|---|---|---|
| Log level | `trace`…`panic` | `warn` | `log.level` |
| Certificate store | `system` · `mozilla` · `chrome` | `system` | `certificate.store` |
| Auto-detect interface | on/off | on | `route.auto_detect_interface` |
| TUN: IPv4 address | CIDR | `172.16.0.1/30` | `inbounds[tun-in].address[0]` |
| TUN: Enable IPv6 | on/off; when enabled the strategies → `prefer_ipv4`, when disabled → `ipv4_only` | off | `address[1]` = IPv6 address |
| TUN: IPv6 address | CIDR | `fdfe:dcba:9876::1/126` | `inbounds[tun-in].address[1]` |
| TUN: Custom tunnel routes | on/off | off | `route_address` (four v4/v6 halves) |
| TUN: interface / MTU / Stack | name · int · `system`/`gvisor`/`mixed` | `lxbox` · 1492 · `system` | `interface_name` · `mtu` · `stack` |
| TUN: Auto route / Strict route | on/off | on / off | `auto_route` · `strict_route` |
| Auto-restart VPN on settings change | on/off | off | — (apply behaviour) |

Immutable keys of the template skeleton: `log.timestamp: true`,
`route.find_process: true`, `outbounds` `direct-out` and `block`,
`experimental.cache_file` (`enabled`, `path: cache.db`, `store_fakeip`),
`services: [{type: oom-killer}]`. Variables of the DNS, VPN Mode, TLS
Fragmentation, Auto Proxy and preset sections live in their own features (see Boundaries).

## Inputs / Outputs

**Inputs:** the shipped template (variable sections, the `config` skeleton,
the preset catalog, group templates, the DNS catalog) with an overlay of locale display
texts; the user's variable values; node sources;
Directions and chains; rules and preset records; DNS records; VPN mode,
split tunneling, tunnel sleep parameters; the core version and its build tags;
a snapshot of the core's running config.

**Outputs:** the final JSON for the core (saved only without a fatal);
build warnings (template codes first, then degradations); fatal
reasons; values the build fixed itself and asks to save
(DNS resolver defaults); the "final tag → source node" map;
banners on the main screen, the snackbar "Config rebuilt: N nodes".

## Data flow

```
 settings ──┐                           change on a screen
 template ──┼─► VARIABLES                │ in-memory store + "stale" flag
 nodes ─────┘   (default ← value,        ▼
                type, bounds, VPN mode)  trigger: return to main · tap on the
                    ▼                    blue banner · Start · launch · subscription
 SKELETON: copy of the template config, substitution of @var and conditions
                    ▼
 NODES: tags (Directions reserve) → detour references → core registry gate →
        source folds → chains → Direction groups
                    ▼
 PRESETS AND RULES (axis order, for_each) → lx.wg → route.final
                    ▼
 POST-STEPS: detour concessions · TLS transformations · DNS · split tunneling ·
             tag migration · healing · graph sanitizer
                    ▼
 CHECK ── fatal → rejection, the config on disk stays the previous one, reason in a snackbar/sheet
                    ▼
 save ─► comparison with the running one ─► "restart" / auto-restart / nothing
```

## Rules and guarantees

- Variable metadata (type, default, options) comes only from the template;
  storage holds only the value. A value equal to the default is not stored in preset
  records and template DNS servers.
- The build is a single point: all paths (return to main, the banner, Start,
  launch, subscription reaction, Debug API) go through it and share one current
  rebuild.
- The "stale" flag is one per process and is not stored on disk; at launch it is
  derived from file modification times.
- If the config is pinned via the Debug API (`PUT /config`), rebuilds
  silently do not happen — see [019-CONFIG_EDITOR](../019-CONFIG_EDITOR/FEATURE.md).
- Settings outside the config (haptic feedback, language) do not raise the flag.

## Boundaries

- Parsing links and files into nodes — [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md).
- Preset contents, user rules, rule order —
  [004-ROUTING](../004-ROUTING/FEATURE.md); the DNS part of the template and the build —
  [005-DNS](../005-DNS/FEATURE.md); detour, chains, Direction groups,
  Auto Proxy — [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md).
- VPN/Proxy modes, `lx.wg.*`, the core reload and its cooldown —
  [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md); split tunneling packages —
  [011-SPLIT_TUNNELING](../011-SPLIT_TUNNELING/FEATURE.md); TLS Fragmentation,
  mixed-case SNI — [016-DPI_HARDENING](../016-DPI_HARDENING/FEATURE.md).
- Reaction to a subscription update (rebuild/reload) —
  [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md); disabling nodes
  rejected by the core at start — [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md).
- Manual editing of the final JSON — [019-CONFIG_EDITOR](../019-CONFIG_EDITOR/FEATURE.md);
  loading a set of settings — [018-WORKSPACES](../018-WORKSPACES/FEATURE.md).
- Native tunnel settings (Allow bypass, Keep on exit, Background mode)
  are not part of the config and are applied on the next tunnel bring-up — depends
  on OS capabilities.

## Functions

| Function | What it does | Promises | File |
|---|---|---|---|
| Config template | Variable sections, skeleton, preset catalog, loading and checking, text localization | P4 | [config-template.md](FUNCTIONS/config-template.md) |
| Template language | Variable types, `@var`, `#if`/`#enable`, predicates, `for_each`/`#tpl`, ref, `on_change`, warnings | P1 P2 P3 P5 P6 P7 | [template-language.md](FUNCTIONS/template-language.md) |
| Build pipeline | Stages from variables to the final JSON, post-steps and healing | P8 P13 | [build-pipeline.md](FUNCTIONS/build-pipeline.md) |
| Final config check | Tag references, empty groups, rings, reaction to fatal | P9 | [config-validation.md](FUNCTIONS/config-validation.md) |
| Settings lifecycle | "Stale" flag, staging, disk write, rebuild triggers, recovery after a kill | P10 P11 P12 P13 | [settings-lifecycle.md](FUNCTIONS/settings-lifecycle.md) |
| Applying to a running tunnel | Banners, comparison with the running one, auto-restart, what applies on the fly | P14 P15 P16 P17 | [apply-to-running-tunnel.md](FUNCTIONS/apply-to-running-tunnel.md) |

## Related features

- [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md) — the subscription update reaction (rebuild/reload) goes through this build.
- [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md) — supplies the parsed nodes the build assembles.
- [004-ROUTING](../004-ROUTING/FEATURE.md) — preset contents, user rules and rule order fed into the build.
- [005-DNS](../005-DNS/FEATURE.md) — the DNS part of the template and the build.
- [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) — detour, chains, Direction groups, Auto Proxy.
- [007-NODE_LIST](../007-NODE_LIST/FEATURE.md) — node emission details (build stages 3–7) and live node selection in a Direction.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — disabling nodes rejected by the core at start.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — VPN/Proxy modes, `lx.wg.*`, the core reload and its cooldown.
- [011-SPLIT_TUNNELING](../011-SPLIT_TUNNELING/FEATURE.md) — split tunneling packages applied in post-steps.
- [016-DPI_HARDENING](../016-DPI_HARDENING/FEATURE.md) — TLS Fragmentation and mixed-case SNI applied in post-steps.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — atomic file writes, backup and import that feed the settings lifecycle.
- [018-WORKSPACES](../018-WORKSPACES/FEATURE.md) — loading a set of settings.
- [019-CONFIG_EDITOR](../019-CONFIG_EDITOR/FEATURE.md) — manual editing of the final JSON; a config pinned via `PUT /config` stops rebuilds.
- [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.md) — node body schema and registry codes behind the core registry gate.

## Maintenance notes

- A screen that saves on leaving must put the edit into memory immediately:
  return to main fires at the moment of pop, and the screen's leave — ~300 ms
  later; otherwise the config lags one visit behind (§107).
- The "stale" flag may be cleared only on the result of a build and only if the composition
  did not change under it (§360); re-staging an edit on leaving the screen
  must not light the flag again (§338).
- The config modification time is aligned to the settings time, not to "now":
  the one-second precision of the file system otherwise gives a false "dirty" (§113).
- A `#if` key with a suffix (`#if1`, `#if tun-only`) is the only way to
  attach two conditions to one object: a second JSON key with the same name silently
  overwrites the first.
- `reject` in a preset's `outbound` is not a tag: the build itself turns it into
  `action: reject`, otherwise it is a dangling reference.
