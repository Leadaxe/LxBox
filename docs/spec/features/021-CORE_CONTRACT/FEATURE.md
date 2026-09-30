[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Core and contract — sing-box-lx core pinning and the contract shared with the launcher

LxBox has no VPN engine of its own: every tunnel, from VLESS and WireGuard to AmneziaWG and WARP over MASQUE,
runs in the sing-box-lx core, a fork of sing-box. How the app reads links and node bodies is defined by a
contract shared with the desktop launcher. This feature keeps both boundaries moving **explicitly**: the core
is bumped by a ritual, the contract arrives by sync, and divergence is caught by a test, not by a user. It is
written for contributors who bump the core or sync the contract.

| Field | Value |
|------|----------|
| Feature | 021-CORE_CONTRACT |
| Type | Process feature (ongoing work on the boundary with the core and the launcher) |
| Absorbed | `§121F` (+ `§122F` as the explanation of the Clash API removal) |
| Core | [Leadaxe/sing-box-lx](https://github.com/Leadaxe/sing-box-lx), branch `lx`; pin **`v1.14.2-lx.8`** (base — sing-box `1.14.2` + 15 commits of `stable`) |
| Contract | launcher contract registry **`1.1.99`** — the registry itself is [025-CONTRACT_REGISTRY](../025-CONTRACT_REGISTRY/FEATURE.md) |
| State | ✅ written from code, 2026-09-29 · living watchlist |

## Principles it protects

1. **One core version for everyone.** The core pin is one file, read by the
   local build, by CI and by F-Droid. A smoke test on a version other than the
   pin does not count.
2. **The core is stricter than the client, the client is more visible than the
   core.** The core decodes the config strictly: one unknown field takes down
   the **whole** config, not one node. So the client never emits what the core
   does not know and shows a ⚠️, while the core is insurance in case the client
   misses something (defence in depth).
3. **Contract before code.** Everything both LxBox and the launcher see
   (protocol dictionaries, allowlists, warning codes, limits, template
   variables) is described in the contract **before** it is implemented. Code
   is fitted to the corpus fixtures, not the fixtures to the code. A deliberate
   difference is a per-app override with a link to the decision; an orphan
   override is an error.
4. **The core is not patched from the app.** A core bug is feedback to the core
   team, not a patch in the client; a local workaround in the client is allowed
   only as visible protection (dropping a field with a code), not as a silent
   fix on the core's behalf.

## Registry: versions and where they live

| What | Value | Where |
|-----|----------|-----|
| Core pin | `v1.14.2-lx.8` | `app/android/libbox.version` — the single source |
| AAR delivery | the fork's GitHub Releases: `libbox-<ver>.aar` + `SHA256SUMS`, hash check; the AAR is not in git | `scripts/fetch-libbox.sh`; CI — the "Fetch sing-box-lx core" step in the `android` job |
| AAR build tags | `with_gvisor, with_quic, with_wireguard, with_utls, with_naive_outbound, with_xhttp, with_awg, with_lx_command, with_lx_idle_suspend, with_lx_chain, with_openvpn, with_openconnect, with_tailscale` + `ts_omit_*`; **without** `with_clash_api` | baked into the core; libbox does not export them, the app keeps a mirror of the set with its own pin — the unit "the core tag pin matches `libbox.version`" is red until reconciled |
| Core control | libbox CommandClient (push streams + unary RPC) | the Clash HTTP API is removed (§122) |

The contract registry — its version, copy, lock, mirrors, sync and guards — is
[025-CONTRACT_REGISTRY](../025-CONTRACT_REGISTRY/FEATURE.md).

## Registry: what the app hands the core beyond upstream

Keys and RPCs that stock sing-box does not have are a contract with the fork.
The behaviour is described in the neighbouring features; this is the summary,
so that a core bump knows what to check.

| Key / RPC | What | Feature | Condition on the core side |
|------------|-----|------|-------------------------|
| `lx.wg.idle_suspend`, `lx.wg.idle_suspend_reachable` | WG/AWG tunnel sleep | [010 · P17](../010-VPN_SERVICE/FEATURE.md#promises) | core ≥ `v1.14.2-lx.1` (before — `route.lx_idle_*`); tag `with_lx_idle_suspend`, without it any `lx.wg.*` kills startup |
| `lx.wg.lazy_build: true`, `lx.wg.build_max` | WG/AWG lazy build and budget | [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) | written only together with `idle_suspend` |
| not written: `lx.wg.build_overflow`, `lx.masque.idle_timeout`; `lx.naive` | the core default `wait` is fine; WARP MASQUE nodes carry their own `idle_timeout`; `lx.naive` is reserved and rejected | — | — |
| AWG `jc`, `jmin`, `jmax`, `s1`, `s2`, `h1`–`h4`, `ip`, `id`, `ib` | WireGuard obfuscation | [015-WARP](../015-WARP/FEATURE.md), [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md) | the `"lo-hi"` range in `h*` — core ≥ `1.14.0-lx.32` (registry `min_core`) |
| outbound `masque` | WARP over MASQUE | [015-WARP](../015-WARP/FEATURE.md) | — |
| `transport.type: xhttp`, `xmux{}` | XHTTP | [016-DPI_HARDENING](../016-DPI_HARDENING/FEATURE.md) | without `xmux` the core picks `max_connections 3` since `lx.6` |
| VLESS `encryption`, `tls.reality.key_share` | VLESS PQ layer, REALITY hybrid key exchange | [016-DPI_HARDENING](../016-DPI_HARDENING/FEATURE.md) | the `encryption` method name is checked by a registry rule |
| DNS server `type: group` (`servers`, `mode`, `error_ttl`, `win_ttl`) | DNS groups | [005-DNS](../005-DNS/FEATURE.md) | — |
| `balancer{}` on `urltest`, type `chain` | balancer, chains | [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) | chains — core ≥ `1.14.0-lx.27-rc.5` |
| endpoint `tailscale`, `openvpn-client` | endpoint nodes | [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md) | `tailscale` — tag `with_tailscale` (since `lx.38`); otherwise the node stays out of the config |
| `urlTestOutbound`, `urlTestGroup`, `setEndpointEnabled`, `endpointState` | measurement, WG/AWG on/off at runtime, endpoint state | [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) | `setEndpointEnabled` — core ≥ `v1.14.2-lx.4` |
| subscriptions `CommandStatus`, `CommandGroup`, `CommandOutbounds`, `CommandConnections`, `CommandDNS`; `GetRunningConfig`, `SubscribeTailscaleStatus` | live state | [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) | — |

The registry gate at build time: a node that needs a build tag or a `min_core`
the current core lacks stays out of the config — see
[025-CONTRACT_REGISTRY · P8](../025-CONTRACT_REGISTRY/FEATURE.md#promises).

## The ritual for accepting a new core version

1. **The core is released as a GitHub Release of the fork.** Before the release
   (an rc chain) the AAR is taken from the fork's CI run artifact and placed by
   hand; the pin is **not committed** — a pin to a non-existent release breaks
   the fetch for everyone and in CI.
2. **Surface delta.** `javap` over `classes.jar` of the old and new AAR; a diff
   of `option/*.go` — new body fields go into the registry on the launcher side
   first, then arrive by sync (`sync_contract.sh --to <sha>`). Without that the
   sanitiser strips the new fields as `unknown_key`: the node works, but
   quietly without them.
3. **Build tags.** Reconcile the AAR tag set, move the pin of the tag mirror.
4. **Bump gotchas** (details in [KERNEL.md](../../../KERNEL.md)):
   `with_lx_idle_suspend` and `lx.wg.*`; an unknown field kills the whole
   config; the order of crash-report archiving and file truncation (detection
   of the previous crash depends on it); the VLESS `encryption` method name in
   a registry rule.
5. **Raise the pin → fetch → smoke on a device**: start/stop, CommandClient
   streams, AWG/XHTTP/MASQUE nodes. Check the core version only by
   `core_version` from the Debug API `/device` or the dump — a gomobile binary
   does not expose it to `strings`.
6. **CHANGELOG + version history in KERNEL.md.** Rolling back below
   `v1.14.2-lx.1` first requires reverting the emit to `route.lx_idle_*`.

In production — **only the official release AAR**: a local gomobile build is not
byte-reproducible, and the hash from `SHA256SUMS` will not match it.

## Feedback to the core

A core problem is filed as a feedback task: the symptom, what was confirmed on
the client side (the binding is present, the call is regular), the core version
and the device, logcat/dump. Meanwhile the client does not patch the core's behaviour.

| Feedback | Gist | Outcome |
|--------|------|------|
| [180-FEEDBACK](../../tasks/180-FEEDBACK-kernel-dns-unimplemented.md) | `SubscribeDNSQueries` → `Unimplemented` on rc.7 | fixed in rc.8 (service-registry key) |
| [180-FEEDBACK-2](../../tasks/180-FEEDBACK-2-kernel-dns-processinfo-empty.md) | `DnsQuery.ProcessInfo` empty on every event | accepted, fix in rc.9 (process lookup before the fast path) |
| [376-FEEDBACK](../../tasks/376-FEEDBACK-kernel-urltest-goroutines-survive-restart.md) | a URLTest run survives a core restart and leaks goroutines | — |
| [120](../../tasks/120-upstream-bugreport-default-network-vpn.md) | the `defaultNetwork` seed can be our own VPN (upstream client) | PR to SagerNet/sing-box-for-android#61; here — §119 |

Feedback also flows the other way, to the launcher: missing corpus expectations and
registry divergences (for example, [529](../../tasks/529-contract-corpus-local-reds-triage.md)).

## Forbidden

- Editing the core "from the app" and shipping local builds of it in a release.
- Bringing back the Clash API: `experimental.clash_api` in the config is a fatal
  start error, and `with_clash_api` is deliberately absent from the AAR (§122:
  the data contract moved from pull snapshots to CommandClient push deltas with
  a single cancellation).
- Committing a pin to a version that is not in the fork's Releases.

## Revision tasks

| # | Revision | Status | Gist |
|---|---------|--------|------|
| 1 | [060](../../tasks/060-libbox-1-13-migration/spec.md) | Done | libbox 1.12 → 1.13.11, wrapper for the single CommandServer |
| 2 | [104](../../tasks/104-libbox-fork-ci-fetch.md) | DONE | permanent fork AAR delivery: pin file + fetch with hash, locally and in CI |
| 3 | [121F](../../tasks/121F-libbox-1.14-adoption/spec.md) | Implemented | move to 1.14: no breaking edits in the client, the gate is a device smoke |
| 4 | [122F](../../tasks/122F-commandclient-migration/spec.md) | Implemented | CommandClient instead of the Clash API, a change of data contract |
| 5 | [191](../../tasks/191-remove-clash-api-from-core.md) | ✅ | Clash API removed from the core settings and the template |
| 6 | [205](../../tasks/205-libbox-rc12-cold-urltest.md) · [210](../../tasks/210-libbox-rc15-sticky-none.md) · [214](../../tasks/214-libbox-rc16-xhttp-fields.md) · [215](../../tasks/215-libbox-rc18-idle-suspend.md) | — | 1.14.0 rc bumps: urltest, sticky, XHTTP fields, idle-suspend |
| 7 | [213](../../tasks/213-debug-device-core-version.md) · [378](../../tasks/378-dump-app-and-core-version.md) | — · Done | the real core version in `/device` and in the dump |
| 8 | [457](../../tasks/457-kernel-lx4-reality-key-share.md) · [461](../../tasks/461-kernel-lx5-short-id-hotfix.md) · [462](../../tasks/462-kernel-lx7-validation-error-tags.md) · [468](../../tasks/468-kernel-lx8-grpc-service-name-verbatim.md) | Released | core 1.14.1-lx.4…lx.8 |
| 9 | [522](../../tasks/522-kernel-lx9-xmux-local-cancel.md) · [526](../../tasks/526-kernel-lx10-upstream-sync-naive-addr.md) | Released v2.25.3 | 1.14.1-lx.9, lx.10 |
| 10 | [535](../../tasks/535-kernel-1-14-2-lx1-pin-lx-wg-keys-endpoint-state.md) | Implemented | 1.14.2-lx.1: the `lx` block, `endpointState` |
| 11 | [557](../../tasks/557-kernel-lx4-wg-endpoint-toggle.md) | Implemented | 1.14.2-lx.4: WG/AWG on/off at runtime |
| 12 | no task — [KERNEL.md → Version history](../../../KERNEL.md#version-history-the-lxbox-relevant-parts), [CHANGELOG 2.25.8](../../../../CHANGELOG.md) | Released v2.25.8 | 1.14.2-lx.5…lx.8: `stable` sync, three MASQUE hangs, XHTTP `max_connections 3` without `xmux` (lx.6); no client change, so no task was opened — the bump is recorded by the pin, KERNEL.md and the changelog |
| 13 | no task — KERNEL.md, [CHANGELOG 2.25.9](../../../../CHANGELOG.md) | Released v2.25.9 | 1.14.2-lx.9…lx.11: Tailscale control channel over HTTPS (SPEC 111), direct UDP path (SPEC 112), one more `stable` sync; Java surface identical to lx.8 |

Registry revisions (460F, contract syncs, 486, 491, 529) moved to
[025-CONTRACT_REGISTRY](../025-CONTRACT_REGISTRY/FEATURE.md).

## Watch for

- **A core bump without a client change gets no task** (rows 12–13): the
  record is the pin, KERNEL.md's version history and the changelog. A bump
  that changes the Java surface or the config contract does get one.
- **The build-tag mirror** in the app (`kCoreBuildTags`) is a manual copy; the
  guard `node_core_gate_test` checks only that `kCoreBuildTagsPin` equals
  `app/android/libbox.version`, not the set itself — a bump must re-read the
  tag list in `build_libbox` by hand.
- **Upstream strictness changes** (like `format` in an inline rule set on 1.14):
  every "the core became stricter" is a candidate for an import sanitiser.

## Related features

- [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md) — parses nodes without a
  core; `min_core` is off at parse time.
- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — runs the registry gate
  against the pinned core as build stage 5.
- [005-DNS](../005-DNS/FEATURE.md) — the fork's DNS groups.
- [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) — balancer and chains, the minimum core version.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — measurement RPCs and
  endpoint on/off; auto-disabling nodes rejected by the core.
- [010-VPN_SERVICE · P17](../010-VPN_SERVICE/FEATURE.md#promises) — the `lx.wg.*` keys.
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — CommandClient subscriptions.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — the core version in the dump, core crash reports.
- [015-WARP](../015-WARP/FEATURE.md),
  [016-DPI_HARDENING](../016-DPI_HARDENING/FEATURE.md) — AWG, MASQUE, XHTTP,
  VLESS encryption fields.
- [023-BUILD_CI_RELEASE](../023-BUILD_CI_RELEASE/FEATURE.md) — core fetch in CI, core version check in the release APK.
- [025-CONTRACT_REGISTRY](../025-CONTRACT_REGISTRY/FEATURE.md) — the contract registry: schemas,
  sanitizer, build gate, warning codes, sync and guards.
- [027-DEBUG_API](../027-DEBUG_API/FEATURE.md) — the core version in `/device`.
- [030-TAILSCALE](../030-TAILSCALE/FEATURE.md) — the `tailscale` endpoint, the `with_tailscale`
  build tag and the `SubscribeTailscaleStatus` stream in use.

## Maintenance notes

- The full core reference is [KERNEL.md](../../../KERNEL.md); the contract process is
  [CONTRACT.md](../../../CONTRACT.md). The feature is a summary of rules, not a copy of those docs.
- Core specs (SPEC NNN) live in the fork's repo; contract SPEC 103 is in the
  launcher repo (the same-numbered `tasks/103-…` here is a different task).
- A fresh worktree has neither the AAR nor the contract copy — see
  [023-BUILD_CI_RELEASE](../023-BUILD_CI_RELEASE/FEATURE.md).
