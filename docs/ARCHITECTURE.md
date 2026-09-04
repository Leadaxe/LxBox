# L×Box architecture

This document describes the structure of the L×Box Flutter application, the boundaries of responsibility, the data flows and the native side.

The current parser and builder version is **v2** (spec 026, phase 5 completed in v1.3.0). Details are in [spec/features/026 parser v2](./spec/features/026%20parser%20v2/spec.md).

---

## Supported platforms

| Parameter | Value |
|----------|----------|
| Android minSdk | **24** (Android 7.0) |
| Android targetSdk | `flutter.targetSdkVersion` (the current target, usually API 34/35) |
| Android compileSdk | `flutter.compileSdkVersion` |
| JVM | Java 17 |
| NDK | 28.2.13676358 |

### Support tiers

| Tier | Android | Status |
|------|---------|--------|
| **Primary** | 11+ (API 30+) | Tested, every feature works, production-ready |
| **Best-effort** | 7.0–10 (API 24–29) | It compiles, installs, and the basic VPN functionality should work |
| **Unsupported** | <7 (API <24) | Installation is blocked by `minSdk=24`; below 24 Flutter itself refuses (the engine's floor) |

> **Android TV (§372).** The app declares itself TV-compatible
> (`uses-feature leanback` / `touchscreen`, both `required="false"`, plus a
> `LEANBACK_LAUNCHER` intent filter), but it remains **best-effort**: the UI is
> designed for touch and there is no separate leanback interface. Two platform
> quirks to keep in mind when editing:
> TV firmware has **no DocumentsUI**, yet the intent never goes unhandled —
> the system stub `frameworkpackagestubs` intercepts it and silently cancels
> the selection (`resolveActivity` finds it, there is no error, the result is empty).
> That is why every picker goes through
> [`services/file_import.dart`](../app/lib/services/file_import.dart),
> which asks the platform (`hasRealFilePicker`, rejecting the stubs by package
> name) **before** launching the picker and suggests the clipboard or a URL.
> Do not rely on a `file_picker` error code — on TV there will not be one.
> Control comes from a **remote**: anything without a focusable node is
> unreachable, so clickable elements need an `InkWell` or a button. Details:
> [§372](spec/tasks/372-android-tv-support.md).

> **The renderer (§131).** On `Build.VERSION.SDK_INT < 31` (Android ≤11) Flutter
> is forced off Impeller and onto **Skia** (`getFlutterShellArgs` →
> `--enable-impeller=false` in [`MainActivity`](../app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt)).
> The Impeller shaders crash older GPU drivers (Adreno 3xx → a SIGSEGV in `libsc-a3xx.so`).
> Impeller is kept on Android 12+. The gate is by OS version rather than by GPU, since
> Flutter has no clean runtime GPU detection. Details: [§131](spec/tasks/131-impeller-adreno-gpu-crash.md).

### Why 24 is the minSdk

- **24 is the absolute floor**: Flutter supports API 24 at the lowest (`FlutterExtension.minSdkVersion = 24` — unchanged through 3.47.x, the pin currently in use), and libbox.aar is built with `minSdkVersion=23`. Below 24 the app cannot be built at all.
- Historically `minSdk=26` was in place from v1.4.0 (“Android 8.0+” in the 1.3.x release notes); it was lowered to 24 in §233 at users' request, since nothing in the code depended on API 26.
- **The VpnService API** (`setMetered`, `setUnderlyingNetworks`) is available from API 29+, with fallbacks for older versions.
- **`ActivityManager.getHistoricalProcessExitReasons`** (API 30+) is needed for silent-kill detection in diagnostics.
- **`NotificationChannel`** (API 26+) sits behind `SDK_INT >= O` gates; both notification builders handle it.
- **`BoxApplication.fixAndroidStack`** is enabled on exactly API 24–25 — a workaround for those versions.

### The `Build.VERSION.SDK_INT` checks

In Kotlin (DefaultNetworkMonitor, ServiceNotification, BoxApplication and others) the version guards are the working tier mechanism.

---

## Overview

L×Box is an Android VPN client built on **sing-box** (through **libbox**). The full cycle:
subscriptions → parsing → config → the VPN tunnel → control through the **libbox CommandClient**.

### The core: the `sing-box-lx` fork

The VPN core is our fork [`Leadaxe/sing-box-lx`](https://github.com/Leadaxe/sing-box-lx)
(upstream sing-box plus AmneziaWG, XHTTP and the LxBox features), controlled through the
libbox CommandClient. The AAR is downloaded by `scripts/fetch-libbox.sh` from the fork's
GitHub Releases, and the version is pinned in `app/android/libbox.version`.

**The full picture — the build tags, the gotchas of a version bump and the rc history — is in
[`KERNEL.md`](KERNEL.md).**

### The layers and their responsibilities

Four layers with one-directional dependencies: **UI → State → Services → Platform**
(never the other way round). Logic never lives in `build()`, and the UI never touches
Platform directly — only through the controllers.

```
┌──────────────────────────────────────────────────────────────────────┐
│  UI   lib/screens · lib/widgets                                        │
│  Thin screens: composition + lifecycle + setState; the logic lives in │
│  a presenter/view-model. The pattern: <screen>.dart (a StatefulWidget │
│  owning the state and every Navigator.push) + <screen>/widgets|tabs/ +│
│  a presenter/VM. Subscribed through AnimatedBuilder/ListenableBuilder.│
├──────────────────────────────────────────────────────────────────────┤
│  STATE   lib/controllers — ChangeNotifier brokers                     │
│  HomeController  — VPN/CommandClient/nodes/ping/heartbeat (split into  │
│                    parts: config_io · heartbeat · ping_orchestration)  │
│  SubscriptionController — entries, fetch, generateConfig (+ part)       │
│  view-models: NodeFilterViewModel · CustomRuleEditController           │
│  An immutable HomeState + copyWith (the _unset sentinel) + ParsedConfig│
├──────────────────────────────────────────────────────────────────────┤
│  SERVICES   lib/services · lib/models · lib/config                     │
│  Parser v2 (parser/) · Builder (builder/) · subscription/ ·            │
│  settings_storage/ · traffic_profiler/ · debug/ (HTTP Debug API) ·     │
│  vpn/cc_channel (libbox CommandClient) · app_log ·                     │
│  the caches (AppInfoCache·HttpCache) ·                                 │
│  ConfigNode/ParsedConfig (§091).                                        │
│  Sealed models: NodeSpec · SingboxEntry · CustomRule · ValidationIssue.│
├──────────────────────────────────────────────────────────────────────┤
│  PLATFORM / NATIVE                                                      │
│  Dart: vpn/box_vpn_client — MethodChannel + status/coreLog Stream.      │
│  Kotlin: VpnPlugin (the bridge) → BoxVpnService (Android VpnService) + │
│  BoxService (libbox runtime, §049-split) + DefaultNetworkMonitor        │
│  (§087 network-reset) + LocalResolver + WifiInfoReader.                │
└──────────────────────────────────────────────────────────────────────┘
```

**The facade invariant (§291):** a domain exposes a **facade** and knows nothing about its
consumers (no `DebugContext`, widgets or intents appear in its signatures); the external
adapters (Debug HTTP, the Automation broadcast, the UI) know the transport and the security
but not what they grant access to; a shared operation is declared once and every adapter
reduces to calling the facade. The reference shapes: `DirectionMutations` (an atomic
heal plus resync, with the raw statics `@visibleForTesting`), `SubscriptionController`
(which owns the server-list mutations, with Debug and Automation delegating to it),
`ProbeController` (`services/probe/` — a shared probe over the whole ServerList subsystem:
the thresholds, the ping and the pure decisions, plus the `probeNodesOf` adapter;
`ProbeGateMixin` is the shared VPN gate), `DnsController` (`services/dns/` — `load()` into a
snapshot plus `stage()` over the DNS section, leaving the screen thin), and
`VpnSettingsFacade` (`services/vpn_settings/` — `applyVpnMode` carries the password-gen,
auth-force and `has_tun`-mirror invariants for the UI **and** for Debug). The typed storage models are the sealed `DnsServerRef` and `DnsRuleRef` (§294).
The full invariant plus the strangler plan is in `docs/spec/features/291 layered-architecture-facades/`.

**The event brokers (push, bottom-up):** §122 moved the UI's control channel onto the
libbox **CommandClient** (a server-stream push instead of Timer polling). The push channels:
the native status `Stream<TunnelStatusEvent>` (the tunnel's lifecycle), the `lxbox/coreLog`
stream (→ `AppLog` → `TrafficProfiler`) and the CommandClient streams over an EventChannel.
`lxbox/cc/*` (status · outbounds · groups · connections · dns — `vpn/cc_channel.dart`).
Unary pull survives in a couple of places — `getGroups()` (a lifeline where the groups push
is leaky) — plus the top-down imperatives (`urlTestOutbound`, `selectOutbound`, `closeConnection`).
The heartbeat is a watchdog over the **silence** of the status stream, with no HTTP polling.
The detailed flows are in the [Data flows](#data-flows) section.

### The invariant: TWO channels of differing reliability (status versus data) — do NOT mix them up

A fundamental separation; breaking it produces bugs of the form “Connected, but the Channel
and Nodes are empty after a swipe” (see §185):

| Channel | What it carries | Reliability / lifecycle |
|---|---|---|
| **The VpnService status broadcast** (the native `Stream<TunnelStatusEvent>` / `BROADCAST_STATUS`) | ONLY the tunnel's **global status** (Connected/Stopped/Connecting/error) | **RELIABLE, always present.** Purely native (an Android Service), it survives the death of the Flutter engine (a swipe-kill under keep-VPN). It is the single source of truth for the status. |
| **The CommandClient streams** (`lxbox/cc/*`: groups · connections · outbounds · status-tick) | **The data shown on screen**: groups and nodes, connections, traffic, per-app | **EPHEMERAL.** Bound to the Flutter engine: the subscriptions live in Dart and the refcount in native. The service and the core live independently of them. |

**keep-VPN-on-exit does NOT stop the core** — that is the CORRECT behaviour (`BoxService.onTaskRemoved` under keep is a no-op, and the core plus the CommandServer keep running). A swipe kills only the UI engine; the status keeps arriving over the broadcast, while the CommandClient data must come back up on the next launch.

**The lifecycle of the CommandClient clients — THREE native↔Dart synchronisation points:**
1. **Going into the background** (the engine is alive) — put screen and status to sleep (`pauseScreen` / `pauseStatus`); leave the profiler alone (it keeps recording in the background, §164).
2. **Returning from the background** (the engine is alive) — bring them back up, in pairs (`resumeScreen` / `resumeStatus`).
3. **A cold start of Flutter** (a new engine) — reset the native CommandClient state to clean (refcount=0, drop the dangling subscriptions and sinks) and let the new UI connect from scratch. The reliable hook is `onAttachedToEngine` (Dart may have died abruptly on a swipe without unsubscribing).

**The profiler keeps its buffer in Dart** (`TrafficProfiler`), while its native `profilerClient` lives on in the background (§164 does not pause it). The consequence: a recording exists only while the Flutter engine is alive — by design the profiler records while the app is open. On a cold start the native side is reset.

### The “cohesion over line count” principle (§089)

The goal of the §089 structural refactor was **a single responsibility plus cohesion**, not
a line count. Six hundred lines are legitimate when the file is one cohesive responsibility.
Large files are decomposed through `part` or `mixin` (the same library, so library-private
access is preserved) or by extracting widget subtrees. The documented large exceptions
(where a split would add risk without benefit):

| File | Lines | Why it stays whole |
|---|---|---|
| `services/traffic_profiler.dart` | 1243 | A monolithic stateful singleton: receiving the CC connections and DNS streams, diffing snapshots, confidence and the dual SSE fan-out — all through shared private state and one `ChangeNotifier` contract. |
| `models/custom_rule.dart` | 618 | Already sealed into `Inline`/`Srs`/`Preset`; the size is inherent to three structurally different kinds. |
| `android/.../VpnPlugin.kt` | 1084 | One `MethodCallHandler` contract; splitting it would scatter the channel contract across files. |

### ConfigNode / ParsedConfig (§091 — implemented)

`ConfigCache` + `ConfigIntrospection` + reverse-map `subscriptionsOfTag`
are collapsed into `ParsedConfig` — a `Map<tag, ConfigNode{tag, type, section, detour,
isMarkedDetour, detourRefCount, raw, transportLabel, securityLabel}>`,
It is parsed once per change of `configRaw` (the `HomeState.configModel` field);
the pings are a separate dynamic layer, joined at render time (`NodeViewItem`).
Membership of a subscription is a **prefix filter** over the emitted tag
(`home/subscription_lookup.dart`), with no membership in node lists. That removed a whole
class of “the UI reverse-parses the display tag” bugs (§077/§079/§080).

`transportLabel` and `securityLabel` (§102/§103) are eager labels for a node's subtitle
(protocol · transport · security: `tcp`/`ws`/`grpc`/`h2`/`httpupgrade`/`quic`/`xhttp`;
`TLS`/`Reality` plus `+Vision` when `flow=xtls-rprx-vision`; for WireGuard, the
obfuscation level `awg`/`awg2`). They are computed once inside `ParsedConfig.parse`,
not in getters. See [`spec/tasks/091`](./spec/tasks/091-config-node-model.md),
[`102`](./spec/tasks/102-subtitle-transport-variant.md),
[`103`](./spec/tasks/103-variant-filter-chips.md).

---

## The three-layer Parser v2 pipeline

> Every guard along this pipeline — the points where a value is dropped,
> normalised, defaulted or a node degraded so that the core does not reject
> the whole config — is catalogued in [`GUARDS.md`](GUARDS.md), by layer,
> with `file:line` and the core error each one prevents.

```
UI / Controller
  │  paste / URL / QR / file  →  SubscriptionSource
  ▼
parseFromSource(source)  ─┐
  │ HTTP fetch (UrlSource)│  → ParseResult{ nodes, meta, rawBody, headers }
  │ body_decoder + parsers│
  └───────────────────────┘
  ▼
ServerList (sealed)  —  SubscriptionServers | UserServer
  │ .build(ctx: EmitContext)
  │   ├─ applies tagPrefix + allocateTag
  │   ├─ per-node emit(vars) → SingboxEntry (Outbound | Endpoint)
  │   ├─ applies detour policy (register/use/override)
  │   └─ registers in selector / auto-proxy-out groups
  ▼
buildConfig(lists, settings)
  │ template (assets/wizard_template.json)
  │ post-steps (in execution order):
  │   1. server_list_build   → outbounds/endpoints from the ServerList
  │   2. applyAllCustomRules → one pass over customRules in storage order
  │                            (dispatched by kind → the preset/inline/srs handler);
  │                            the registry receives the rule_sets and routing rules
  │                            in storage order; the DNS aspects go into UnifiedApplyResult
  │                            (spec 030 + 033 + 062)
  │   3. flush registry      → config.route.{rule_set, rules}
  │   4. applyTlsFragment, applyMixedCaseSni  → TLS obfuscation (spec 028)
  │   5. applyCustomDns      → dns.servers/rules from the template plus the bundle extras
  │   6. validator → ValidationResult{ fatal[], warnings[] }
  ▼
BuildResult{ config, configJson, validation, emitWarnings, generatedVars }
  │
  ▼
HomeController.saveParsedConfig(configJson)  →  native VpnService
```

**Invariants:**
- Each `NodeSpec` has round-trip `parseUri(spec.toUri()) ≈ spec`.
- Polymorphic `emit(vars)` — WireGuard → Endpoint, others → Outbound.
- `EmitContext.allocateTag(baseTag)` guarantees global uniqueness across all lists.
- Warnings bubble up: at parse time into `NodeSpec.warnings`, at emit time appended by the emit. (The XHTTP fallback to `httpupgrade` was removed in §097 — the transport is now native.)

---

## Wizard template (`assets/wizard_template.json`)

An asset template read once through `TemplateLoader.load()` (a singleton, deep-copied on each read).

### The template's sections

| Section | Role | Example / where it is used |
|---|---|---|
| `parser_config` | The sing-box `version` plus the reload interval | Emitted straight into the root |
| `dns_options.servers` | The canonical DNS servers (system/google/cloudflare/quad9/adguard). Storage keeps kind refs. | Resolved into bodies by `resolveDnsServersBodies` |
| `dns_options.rules` | The default DNS rules. Storage keeps kind refs (§061 dns-rules-refactor, formerly feature §041). | Resolved by `resolveDnsRulesList` |
| `ping_options`, `speed_test_options` | UI features (HomeScreen, SpeedTest) | Never reach the sing-box config |
| `group_templates` + `default_directions` | §125/§267/§393 — the **SEED** for `directions[]` (on the first launch). The builder reads `directions[]` from storage. |
| `config` | The base of the sing-box config: log, inbounds, the route skeleton | Deep-copied at the start of `buildConfig` |
| `sections[].vars[]` | The UI's global variables — chapter `core` / `routing` / `dns` | Rendered by `TemplateVarListView` |
| `selectable_rules` | The catalog of preset rules (legacy inline plus bundle — spec 033) | The Presets tab on the Routing screen |

### Selectable rules — two modes

A preset in `selectable_rules[]` works in one of two modes:

**Legacy (up to v1.4.x, with no `preset_id`):**
```json
{
  "label": "BitTorrent direct",
  "default": true,
  "rule": { "protocol": ["bittorrent"], "outbound": "direct-out" }
}
```
The user copies it into a `CustomRule(kind: inline | srs)` through `selectableRuleToCustom` — the contents are copied by value.

**Bundle (v1.5+, with `preset_id` set) — spec 033:**
```json
{
  "preset_id": "ru-direct",
  "label": "Russian domains direct",
  "default": true,

  "vars": [
    {"name": "out", "type": "outbound", "default_value": "direct-out", "title": "Outbound"},
    {"name": "dns_server", "type": "dns_servers", "required": false, "default_value": "yandex_doh", "title": "Transport"},
    {"name": "dns_ip", "type": "enum", "default_value": "77.88.8.88", "options": [
      {"title": "77.88.8.88 · Safe", "value": "77.88.8.88"}, ...
    ]}
  ],
  "rule_set":    [ { "tag": "ru-domains", "type": "inline", "format": "domain_suffix", "rules": [...] } ],
  "dns_rule":    { "rule_set": "ru-domains", "server": "@dns_server" },
  "rule":        { "rule_set": "ru-domains", "outbound": "@out" },
  "dns_servers": [
    {"type": "https", "tag": "yandex_doh", "server": "77.88.8.88", "port": 443, "path": "/dns-query", "tls": {"enabled": true, "server_name": "safe.dot.dns.yandex.net"}, "detour": "@out"},
    ...
    {"type": "udp",   "tag": "yandex_udp", "server": "@dns_ip", "server_port": 53, "detour": "@out"}
  ]
}
```
`CustomRule(kind: preset)` stores a **thin reference** — just `{presetId, varsValues}`. The expansion (`preset_expand.dart`):
1. Resolves the variables from `varsValues` (or from `default_value` when the key is absent; a `required` var with no value aborts the expansion).
2. Recursively substitutes `@var` into `rule_set`, `dns_rule`, `rule` and `dns_servers`.
3. Filters `dns_servers` down to the single one whose `tag == vars['dns_server']`.
4. If `@out` resolves to `"direct-out"`, removes `detour` from the DNS servers (direct needs none).

Merging the fragments from different `CustomRule(kind: preset)` entries is an identical-skip by tag plus first-wins with a warning for real conflicts.

### Vars

`WizardVar` is shared between the global `sections[].vars[]` and the preset-local `selectable_rules[i].vars[]`. The supported types:

| `type` | UI | Substitution |
|---|---|---|
| `bool` | SwitchListTile | `"true"` / `"false"` → Dart bool |
| `text` | A TextField (plus a combo popup when `options` exist) | a string |
| `enum` | A dropdown mapping `title → value` | a string (the `value`) |
| `secret` | A TextField with an eye toggle plus Generate | a string |
| `outbound` (preset only) | An OutboundPicker | a string (a tag) |
| `dns_servers` (preset only) | A dropdown over `preset.dns_servers[].tag` | a string (a tag) |

**`options`** accepts two formats (kept legacy-compatible): a string literal (`"foo"` ≡ `{title: "foo", value: "foo"}`) or an object.

**`required: bool`** (default `true`) — an optional var gets a “— (none)” entry in the UI; choosing it clears the value.

### How the layers connect

```
wizard_template.json
  │  load (TemplateLoader)  →  WizardTemplate (in memory, shared)
  │
  ├── config       ──► _substituteVars(@global vars)                          ──► base config
  ├── customRules (one list of mixed kinds — preset/inline/srs)
  │    │  applyAllCustomRules — a single pass in storage order
  │    │  dispatched by kind. Cross-preset rule_set dedup happens through
  │    │  RuleSetRegistry.tryRegisterRuleSet (identical-skip / first-wins).
  │    │  (spec 062 — preset and inline used to run as two passes and the
  │    │   cross-kind ordering between them was lost)
  │    ├── kind: preset
  │    │    └─ expandPreset (pure) ──► PresetFragments
  │    │       └─ register rule_sets in registry; routing rule (if route enabled);
  │    │           DNS aspect (if dns enabled) → UnifiedApplyResult.{dnsRules, dnsServers}
  │    ├── kind: inline
  │    │    └─ a headless rule_set with non-empty match fields plus a routing rule
  │    │       (the tag auto-suffixed through registry.addRuleSet) (spec 030)
  │    └── kind: srs
  │         └─ a local rule_set at the cached path plus a routing rule (spec 030)
  ├── dns_options  ──► applyCustomDns(template + extras)                      ──► config.dns
  ├── directions[] (storage) ──► _buildDirectionGroups(per-direction node_filter) ──► config.outbounds
  │   (§125/§267: the directions come from directions[], seeded from group_templates plus default_directions; with the block/direct options)
  └── chains[] (storage) ──► the chain outbounds (type: chain, SPEC 110)      ──► config.outbounds
      (§393 C: a chain is a SOURCE — an explicit route through 2+ hops, in packet order)
```

**Why DoH/DoT in a bundle hardcode `server: "77.88.8.88"` plus `tls.server_name`:**
In sing-box 1.12 a DNS server of type `https` or `tls` addressed by hostname requires a `domain_resolver` (the tag of another server), otherwise the config does not load.

`@dns_ip` applies **only** to the UDP server — replacing the IP for DoH/DoT would break TLS (a certificate mismatch).

---

## The source tree

The structure after §089: thin screens with `<screen>/` subfolders, controllers split into
parts, and the large services separated by responsibility through `part`s. The per-file roles follow.

### `app/lib/`

```
main.dart                    # Entry point: ThemeNotifier, MaterialApp,
                             #   home: HomeScreen, navigatorObservers:[homeReturnObserver]
                             #   (there are no named routes — navigation is imperative)
```

#### `vpn/` — the Dart side of the native bridge

```
box_vpn_client.dart          # BoxVpnClient.I — a typed wrapper over the
                             #   MethodChannel/EventChannel; every call is
                             #   timeout-wrapped + safe-default; onStatusChanged stream
box_vpn_client/method_names.dart  # part: _Methods — a mirror of when(call.method) from VpnPlugin.kt
box_vpn_client/timeouts.dart      # part: _Timeouts — per-method Duration (status 3s, start 30s…)
cc_channel.dart              # §122 CcChannel.instance — the Dart client of the libbox CommandClient (it replaced
                             #   ClashApiClient): push streams for status/outbounds/groups/connections/dns (§180)
                             #   over the EventChannel lxbox/cc/* plus the imperatives (urlTestOutbound, getRules,
                             #   the getGroups unary pull, selectOutbound, closeConnection); the fan-out goes through
                             #   a broadcast (ONE native sink per channel, the §122 sink-leak guard)
```

#### `config/`

```
config_parse.dart            # JSON5/JSONC → canonical JSON (for libbox) plus pretty-print (for the editor)
consts.dart                  # kAutoOutboundTag (✨auto), kDetourTagPrefix (⚙) — a mirror of wizard_template
```

#### `models/` — typed data (sealed hierarchies, no I/O)

```
node_spec.dart               # the sealed NodeSpec (11 variants: Vless/Vmess/Trojan/Shadowsocks/…)
                             #   Hysteria2/Naive/Tuic/Ssh/Socks + Wireguard + Masque §130); getEntries detour-chain;
                             #   the Awg value object (§097): the AWG/AWG2 fields of WireguardSpec (jc/jmin/jmax/
                             #   s1–s4/h1–h4/i1–i5), round-tripping parse/emit; null means ordinary WG
node_spec_emit.dart          # the emit()/toUri() implementation per variant (NodeSpec → SingboxEntry); parity-tested
singbox_entry.dart           # sealed SingboxEntry = Outbound | Endpoint (WireGuard → Endpoint)
node_entries.dart            # NodeEntries{main, detours} — the result of getEntries
emit_context.dart            # the abstract EmitContext: allocateTag/addEntry plus selector and auto registration
template_vars.dart           # TemplateVars — the global emit flags (tls_fragment/mux/sniOverride)
tls_spec.dart                # TlsSpec + RealitySpec (utls/reality/alpn) → toSingbox()
transport_spec.dart          # the sealed TransportSpec (Ws/Grpc/Http/HttpUpgrade/Xhttp); XHTTP is a native
                             #   emit (§097, the core's with_xhttp: mode/x_padding_bytes/no_grpc_header)
node_warning.dart            # sealed NodeWarning + WarningSeverity (parse/emit warnings)
validation.dart              # sealed ValidationIssue + ValidationResult (dangling refs/empty urltest → fatal)
parser_config.dart           # the wizard_template.json models: WizardTemplate/PresetGroup/SelectableRule/WizardVar
custom_rule.dart             # the sealed CustomRule = Inline|Srs|Preset (routing rules; →§090, see the Overview)
server_list.dart             # sealed ServerList = SubscriptionServers | UserServer
subscription_meta.dart       # SubscriptionMeta — the userinfo headers (traffic/expire/title/update-interval)
app_info.dart                # AppInfo — the metadata of installed applications (fetched natively)
background_mode.dart         # the BackgroundMode enum (never|lazy|always) — the tunnel's Doze behaviour
tunnel_status.dart           # TunnelStatus enum + TunnelStatusEvent (native status mapping + errorReason)
debug_entry.dart             # DebugEntry plus DebugSource/Level/Filter (a unified log line)
home_state.dart              # immutable HomeState + copyWith; configModel: ParsedConfig (§091,
                             #   re-parsed on a configRaw change); NodeSortMode (default/latency/name/
                             #   manual — §100: manual in the carousel and the menu, the mode plus the manual order
                             #   persisted in settings_storage); memoized sortedNodes
config_node.dart             # §091 ConfigNode plus ParsedConfig — the structural metadata of the assembled
                             #   config's nodes (type/section/detour/isMarkedDetour/detourRefCount/raw);
                             #   the §102/§103 eager transportLabel/securityLabel (the transport slot plus
                             #   TLS/Reality/+Vision, awg/awg2); parsed once per change of configRaw
direction.dart               # §125/§393 Direction — the routing directions (arbitrary tags, no cap; vpn-1 cannot be deleted)
source_chain.dart            # §393 C SourceChain — a hop chain as a SOURCE (SPEC 110): hops in packet order,
                             #   strip/rewrite, `order` = the slot in the COMMON source list
auto_select.dart             # §322 the membership of an auto-select node (a folder) plus its parameters
import_rule.dart             # §302 ImportRule — the rules applied to a subscription's nodes on import
dns_ref.dart                 # §294 typed model dns_options.servers[]/rules[] (kind-discriminated refs)
memory_limit_setting.dart    # §271 the core's memory limit (SetupOptions.oomMemoryLimit)
stop_reason.dart             # §279 a typed reason for an emergency stop or a revoke
traffic_snapshot.dart        # a snapshot of the traffic aggregates for the home screen
ui_msg.dart                  # UiMsg — a user-facing message with lazy rendering
```

#### `controllers/` — the ChangeNotifier state brokers

```
home_controller.dart         # the main VPN broker: _state/_vpn/_cc; the status handler; start/stop/
                             #   reconnect/reload; CommandClient groups (push + getGroups-pull);
                             #   the selection setters; the lifecycle
home_controller/config_io.dart          # part _ConfigIoMixin: load/saveParsedConfig, import, configChangedNeedRestart
home_controller/heartbeat.dart          # part _HeartbeatMixin: a watchdog over the silence of the CommandClient status stream
                             #   (§122, with no HTTP polling) plus dead-tunnel detection
home_controller/ping_orchestration.dart # part _PingMixin: single/group/mass URLTest, ten workers, epoch cancellation
subscription_controller.dart            # the subscriptions: List<ServerList>, add/remove/rename/toggle/move
                                        #   (§098 drag-reorder), fetch, buildConfig; §101 — rehydrationDone
                                        #   (fixing the startup race between rehydrate and bootstrap) plus an empty-fetch guard
                                        #   (an HTTP 200 with 0 nodes does not wipe the cached ones)
subscription_controller/subscription_entry.dart # part SubscriptionEntry: a ChangeNotifier wrapper over an immutable ServerList
```

#### `screens/` — the UI (a thin screen plus its subfolder)

```
home_screen.dart             # the composition root (518 lines): it owns the brokers and the side effects
home/node_list_presenter.dart   # the §089 presenter: the §048 filter/split plus the §070 frozen-sort cache plus
                                #   the chip options; §103 variantsOfTag plus the canonical order of the variant chips
home/node_filter_view_model.dart# a ChangeNotifier VM: the regex/protocol/variants(§103)/sub/ping filters,
                                #   one !-negate per category (§096) plus the detour tri-state (a checkbox,
                                #   §096), plus the §083 per-direction memory
home/node_filter.dart           # a pure NodeFilter helper (the match predicates plus the inverts) plus extractEmojis
home/node_actions.dart          # the node's long-press actions; §099 — the copy-JSON variants (node /
                                #   server+detours(N)) moved into a dropdown inside View JSON
home/home_menus.dart            # showSortOptionsMenu (+ Custom/manual §100) + showPingSettings
home/home_dialogs.dart          # the top-level dialog and snackbar functions (update/permission/battery/revoked)
home/restore_backup.dart        # empty-state quick-restore flow (SAF)
home/subscription_lookup.dart   # the §091 prefix filter: a node belongs to a subscription ⇔ its tag
                                #   starts with '$prefix '; it replaced the §077 reverse map over node lists
home/direction_filters.dart     # §083 an immutable snapshot of a direction's match filters (plus the §103 variants)
home/filter_widgets.dart        # the filter chip and row widgets (the §095 viz-toggle chips, the §096 NegateToggle)
home/widgets/                   # node_list · home_controls · home_drawer (the nav hub) · nodes_header ·
                             #   traffic_bar · status_chip · progress_banner · filter_panel (§095
                             #   Filter mode: the Regex/Protocol/Subscribes/Settings tabs plus the summary chips)
                             #   · add_server_cta
routing_screen.dart          # the routing config (598 lines) plus LazyPersistMixin and _RoutingSrsCacheMixin (a part)
routing_screen/                 # widgets/ (custom_rule/preset_catalog/route_final/routing_group/srs_status) + menus
dns_settings_screen.dart     # the DNS settings (592 lines) plus the editor sheets, dns_server_resolver and widgets/
custom_rule_edit_screen.dart # CustomRule editor (456) + custom_rule_edit/ (edit_controller, tabs/, sections/, widgets/)
subscription_detail_screen.dart # a subscription's details (431 lines, a TabController) plus widgets/ (settings/source/meta)
subscriptions_screen.dart    # the subscription list (445 lines) plus widgets/ and the helpers (clipboard/paste/share/context)
stats_screen.dart            # the TabBarView host: Overview + Connections + LiveEvents (§288 removed PerAppTrace)
stats_screen/overview_tab.dart  # the Overview tab plus overview_models
stats_screen/                   # §264-266 Traffic Processing: trace_explorer + profiler_filter(+_sheet,
                             #   profiler_filters) + traffic_event_detail_sheet · aggregate_detail_sheet ·
                             #   memory_detail_sheet · routing_section (the details are in features/044)
live_events_tab.dart         # the Stats “Profiler” subtab (371 lines): event_tile/recording_header/unattributed_banner
tun_apps_tab.dart            # the per-app VPN routing subtab (384 lines) — shared by Stats and Routing
app_settings_screen.dart     # the application settings (516 lines): the General and Diagnostics tabs plus update_section
backup_screen.dart           # the snapshot export/import (229 lines) plus export_card/import_card/preview
lazy_persist_mixin.dart      # LazyPersistMixin — deferred persistence on the settings screens (flushed on exit)
# the monolithic single screens (no subfolder, 60–505 lines): about · add_server_wizard ·
#   app_picker · auto_group_edit (§322, an auto-select node) · direction_edit (§125/§393) ·
#   chain_edit (§393 C — the hop-chain editor, d&d over positions) ·
#   config · connections · crash_reports (§316, the core's Go panics) · debug ·
#   dns_server_edit · folder_detail (§234, a server folder mirroring
#   subscription_detail) · node_settings · oom_reports (§318, the core's OOM snapshots) ·
#   outbound_view · settings · speed_test · vpn_mode_tab (§119) ·
#   warp_experiment (§284, the endpoint generator) · warp_wizard (§130, the WARP/MASQUE wizard)
# owner_navigation.dart            # §258 the shared jump from a config tag to its owner screen
# probe_gate_mixin.dart            # §296 the probe's VPN gate: two CommandServers per process are impossible
```

#### `services/` — the service layer

```
parser/                      # Parser v2 (text → NodeSpec)
  body_decoder.dart          #   Layer-1: raw body → sealed DecodedBody (base64 sniff + JSON-flavor)
  amnezia_link.dart          #   an Amnezia vpn:// link → WG/AWG INI texts (base64url plus qCompress, §110)
  parse_all.dart             #   Layer-2: exhaustive switch DecodedBody → List<NodeSpec> (per-line null-skip)
  uri_parsers.dart           #   barrel + parseUri scheme-dispatcher
  uri_parsers/<proto>.dart   #   per-protocol URI→NodeSpec (vless/vmess/trojan/ss/hy2/naive/tuic/ssh/socks/wg/masque)
  json_parsers.dart          #   parseXrayElement + parseSingboxEntry (round-trip)
  singbox_config.dart        #   §368: a sing-box config or an array of them → nodes, groups and detours
                             #   (at parity with the Xray branch: two passes, dedup, synonyms)
  ini_parser.dart            #   WireGuard INI → wg:// URI → WireguardSpec
  transport.dart             #   parseTransport (query→TransportSpec) + transportToQuery
  uri_utils.dart             #   shared: base64-safe decode, newUuidV4, tagFromLabel, packet-encoding
                             #   an allow-list; awgClampMtu (§097 — the client MTU of AWG nodes is ≤1280)
builder/                     # NodeSpec + template → sing-box config
  build_config.dart          #   buildConfig() orchestrator → BuildResult; _BuildCtx (EmitContext + tag allocator)
  server_list_build.dart     #   the per-subscription emit: the detour policy, tag allocation, selector/auto registration
  if_engine.dart             #   the §120 typed template engine: var substitution plus the #if construct
  preset_expand.dart         #   expandPreset (CustomRulePreset → fragments, @var) + mergeFragments (§033);
                             #   §265: the globalVars parameter — ref-vars {"ref":…} take their value from the global scope
  normalize_pinned_presets.dart   #   §264 the pinned presets are normalised to the start of the storage order
  rule_set_registry.dart     #   the registry of route.rule_set plus route.rules; it enforces tag uniqueness
  validator.dart             #   validateConfig: dangling refs, empty urltest → ValidationResult
  post_steps.dart            #   a barrel (part): the post-processing steps below
  post_steps/tls_transforms.dart  #   applyMixedCaseSni + applyTlsFragment (§028)
  post_steps/custom_rules.dart    #   applyAllCustomRules (preset/inline/srs in storage order, §062)
  post_steps/dns_rules.dart       #   applyCustomDns / resolveDnsRulesList (§061+§033)
  post_steps/dns_servers.dart     #   resolveDnsServersList/Bodies (§043+§044)
  post_steps/heal_dangling_detours.dart # §172 healDanglingDetours: a detour outside allTags is dropped (with a warning),
                             #   called before validateConfig — a broken detour from a subscription
  post_steps/heal_dangling_resolve_servers.dart # §247 degrading broken server references in resolve rules
  post_steps/heal_legacy_dns_strategy.dart      # §246 a hotfix for an incompatible pair in dns.rules
  post_steps/heal_unknown_utls_fingerprints.dart# §281 insurance against an unknown uTLS fingerprint
  post_steps/heal_invalid_reality.dart          # §343 insurance against a malformed REALITY block (short_id)
  post_steps/tun_packages.dart    #   applyTunPackages — the OS split tunnel (§046, the last step)
subscription/                # fetching and auto-updating subscriptions
  sources.dart               #   sealed SubscriptionSource (Url/File/Clipboard/Inline/Qr) + fetch (3-try backoff);
                             #   §129 a file subscription: url=file:<uuid> (input_helpers.isFileSubscription) reads
                             #   from the cache, not the network; switching online↔file is transactional
  auto_updater.dart          #   a five-trigger refresh plus a per-sub interval, retry/fail caps and dedup (§027)
  http_cache.dart            #   an on-disk cache of the last raw body plus headers (the offline rehydrate);
                             #   §101 — an atomic tmp→rename write (kill-safe under an unawaited save)
  input_helpers.dart         #   isSubscriptionUrl/isDirectLink (including awg://, §097)/isWireGuardConfig/isFileSubscription
settings_storage.dart        # the facade over lxbox_settings.json — thin delegates into the part files
settings_storage/io.dart            #   the atomic load/save/recovery (main→.bak→{}, §072)
settings_storage/vars.dart          #   the vars domain plus the Wi-Fi history (§051)
settings_storage/sources_rules.dart #   server_lists (+v1 migration), rules/groups, custom_rules
settings_storage/network.dart       #   route_final/excluded/dns/ping_options (§040/§061)
settings_storage/backup_tun.dart    #   the snapshot (§031) plus the tun-apps split tunnel (§046)
settings_storage/directions.dart    #   §125/§393 the directions (Direction CRUD plus the vpn-1 seed) and chains[]
settings_storage/native_prefs.dart  #   NativePrefsKeys — the bridge into the Kotlin side's SharedPreferences
settings_storage/vpn_mode.dart      #   §119 the VPN mode (the per-app allow/deny lists)
settings_storage/warp.dart          #   §025/§130 the WARP/MASQUE accounts plus the generator's pool
traffic_profiler.dart        # the TrafficProfiler singleton (1243 lines, see the Overview): the rolling buffer and SSE
traffic_profiler/models.dart        #   part: TrafficEvent/Session + enums + JSON
traffic_profiler/internal.dart      #   part: the _ConnSnapshot correlation structure (§180's _DnsAccumulator and §044's _ConnMeta are gone)
debug/                       # localhost HTTP Debug API (§031)
  bootstrap.dart             #   applyDebugApiSettings — builds the DebugContext and restarts the server
  debug_registry.dart        #   nullable refs to the controllers (bound in HomeScreen.initState)
  context.dart               #   DebugContext — per-handler injection (requireHome/Sub, clock, log, config)
  contract/errors.dart       #   sealed DebugError (NotFound/Unauthorized/Conflict/…) — transport-agnostic
  transport/server.dart      #   DebugServer — an HttpServer on 127.0.0.1, the Router plus pipeline, the lifecycle
  transport/request.dart     #   DebugRequest — immutable snapshot, body read once (maxBodyBytes)
  transport/response.dart    #   sealed DebugResponse (Json/RawJson/Bytes/Stream/Error)
  transport/router.dart      #   longest-prefix mount/resolve
  transport/pipeline.dart    #   onion-chain middleware runner
  transport/config.dart      #   DebugServerConfig (port/token/timeout/maxBody/unauth-paths)
  transport/middleware/      #   error_mapper · access_log · host_check · auth · timeout
  handlers/                  #   /state /settings /action /profiler /rules /subs /config /logs /device
                             #     /files /diag /backup /wifi_history /help /ping /warp /directions (§275/§393)
                             #     /chains + /chains/{tag}/probe (§393 C — CRUD plus the layered probe)
                             #     /folders (§238) /pool (§208) (plus the _shared CRUD helpers)
  serializers/               #   home_state · storage (the denylist scrubber) · rules · subs (URL masking)
warp/                        # §025/§130 WARP plus the MASQUE transport (it feeds warp_wizard_screen)
  warp_client.dart           #   registration with Cloudflare (POST /reg): the X25519 private key never leaves the device
  warp_account.dart          #   the WARP account (client_id→reserved, the keys)
  warp_endpoint_picker.dart  #   the pool of WARP endpoints plus a random endpoint/SNI (§148, curated)
  scan/                      #   the §284/§305 node generator: random seeding (IP × port × protocol)
  masque_account.dart · masque_keys.dart · masquerade_params.dart  #   §130 MASQUE (Cloudflare QUIC/CONNECT-IP)
migration/proxy_source_migration.dart  # one-shot v1 proxy_sources → v2 server_lists
nav/home_return_observer.dart          # a global NavigatorObserver (§076): a rebuild on returning home
app_log.dart                 # AppLog ChangeNotifier-singleton: per-source ring buffers + persistent warn/error (§043)
app_info_cache.dart          # AppInfoCache — a session cache of AppInfo by package plus a revision ValueNotifier
json_clone.dart              # deepCopyJson/deepCloneJson/deepEqualsJson (§089 P6 — shared by the builder and backup)
format_utils.dart            # formatBytes/formatDuration/formatTime (the canonical formatters)
relative_time.dart           # relativeTime(now, past) — "2h ago" (pure and testable)
url_mask.dart                # maskSubscriptionUrl — scheme://host/*** for logs and sharing
tag_resolver.dart            # §085 TagResolver — the single owner of the display tag (displayTag/isDetour)
rule_name_resolver.dart      # §165 — mapping the core's rule.String() (lossy and truncated) onto
                             #   custom_rules[].name for Stats → Traffic by Rule and Conns; with normalisation
template_loader.dart         # the wizard_template.json loader (a singleton, deep-copied per build)
rule_set_downloader.dart     # download+cache remote .srs (parallel, atomic tmp+rename, retry)
backup_service.dart          # exporting and importing a full settings snapshot (§031)
update_checker.dart          # the GitHub release check plus the dismissed-version guard (see §090 on the half-wired stub)
node_emoji.dart              # §094 emoji tags: the palette, the protocol-default emoji and insertion into rawBody
haptic_service.dart · community_servers_loader.dart · dump_builder.dart · url_launcher.dart ·
config_dirty_check.dart · error_humanize.dart · error_format.dart · parse_hints.dart ·
clash_log_pump.dart · logcat_reader.dart · stderr_reader.dart · exit_info_reader.dart ·
selectable_to_custom.dart · version_info.dart · wifi_history_listener.dart  # helpers
automation/                  # the §047 Dart side of automation (complementing the Kotlin Locale/Tasker plugin):
  automation_dispatcher.dart #   the dispatcher of incoming commands (start/stop/toggle/select-node/…)
  event_emitter.dart         #   the outgoing events (VPN up/down, sub-refresh) with throttling (OFF by default)
  handlers.dart              #   the command handlers on top of the controllers
l10n/                        # the §279/§285 localization subsystem (see the Localization section)
  get_local_text.dart        #   GetLocalText (the natural-key engine: .s/.plural, printf, fallback to the key); GetLocalText.en
  plural_resolver.dart       #   PluralResolver plus En/RuPluralResolver (the CLDR plural forms)
  locale_controller.dart     #   LocaleController — the owner of the locale-switch pipeline plus the dictionary
  template_overlay.dart      #   TemplateOverlay.apply/extract — the pre-parse overlay of the template
  app_language_reconcile.dart#   the three-way reconciliation between LocaleManager and storage (Android 13+)
  template_aware_state.dart  #   a mixin: re-reading the template in didChangeDependencies on a locale change
project_links.dart           # §362 — the single source of the project's links plus the @placeholders
install_source.dart          # §390 — the install channel (github/play/fdroid): a dart-define, otherwise
                             #   by installingPackageName. It decides the updateUrl (where to send the user for an update)
support/                     # the §105/§356/§357 support feed plus the active-time counter
  support_message.dart       #   the feed's models (i18n/since_version/mark_read) plus selection/markRead/snooze
  support_nav.dart           #   the §357 pseudo-protocol lxbox://action:payload (route:/add:)
  support_state.dart         #   persisting the support state (SupportState.I): read/baseline/snooze
  active_time_tracker.dart   #   the usage counter: the §187 native uptime plus the legacy wall clock
platform_channels.dart       # §141 — the MethodChannel/EventChannel names (a single source across Dart and Kotlin)
process_name.dart            # §154 — resolving a package to a process name (the profiler's attribution)
profile_dump_writer.dart     # §207 — serializing a pprof dump (goroutine/CPU) to disk
```

#### `widgets/` — the cross-screen widgets

```
node_row.dart                # a node's row: the ACTIVE pill, the protocol label and the ping (it takes a NodeViewItem)
node_view_item.dart          # NodeViewItem — an immutable view row (static metadata plus the dynamics, §068)
emoji_picker_button.dart     # §094 — the emoji palette popup (node_settings, the add-server wizard)
reorder_grab_strip.dart      # §098 — one grab strip for drag-reorder (the routing and DNS rules ·
                             #   subscriptions · the node list in manual-sort mode, §098/§100)
outbound_picker.dart · template_var_list.dart · core_logs_hint_banner.dart ·
wifi_entry.dart · wifi_manual_add_dialog.dart · wifi_permission_dialog.dart · wifi_saved_picker_sheet.dart
```

### `app/android/app/src/main/kotlin/com/leadaxe/lxbox/`

```
MainActivity.kt              # a FlutterActivity: it registers VpnPlugin; the /utils and /wifi_history channels
                             #   VPN-consent flow; QS-tile/shortcut quick actions
vpn/VpnPlugin.kt             # the Flutter plugin (1084 lines, see the Overview): the MethodCallHandler for every /method;
                             #   the status and coreLog EventChannel sinks; the §122 cc methods (ccConnectScreen/
                             #   ccUrlTestOutbound/ccGetGroups/…) + lxbox/cc/* EventChannel sinks;
                             #   the statusReceiver bridge; app-icon encoding
vpn/BoxCommandClient.kt      # §122 — the UI↔core control channel through the libbox CommandClient:
                             #   statusClient/screenClient/profilerClient; the addCommand subscription plus the write* commands
                             #   (§163/§164, the setStatusInterval power model). It replaced Clash HTTP
vpn/BoxVpnService.kt         # the Android VpnService plus the PlatformInterface side (the thin §049 split):
                             #   §122 — it owns the cc*Sinks (status/outbounds/groups/connections/dns §180 push);
                             #   openTun (Builder.establish, allowBypass §069, the per-app routes); it forwards into BoxService
                             #   §119: libbox calls openTun ONLY when a tun inbound exists
                             #   (with vpn_mode=proxy and a config without a tun there is no openTun, no establish and no VPN slot)
                             #   The foreground/protect/override paths are tun-agnostic, so proxy mode is config-only and Kotlin is untouched
vpn/BoxService.kt            # CommandServerHandler — it owns the libbox runtime (fileDescriptor/commandServer)
                             #   AtomicReference, serviceScope); startSingbox/doStop/serviceReload; setStatus broadcast
vpn/BoxApplication.kt        # Application: async Libbox.setup (libboxReady barrier); singleton wifiObserver
vpn/CrashRecovery.kt         # §334 — “the previous run crashed” (a non-empty CrashReport-lxbox.log in
                             #   tempPath). The detection must run STRICTLY before Libbox.setup, which archives it
vpn/PlatformInterfaceWrapper.kt # libbox PlatformInterface: localDNS→LocalResolver, findConnectionOwner, readWIFIState
vpn/PProfClient.kt           # §207 — the libbox PProfServer (goroutine/CPU dumps, ports 6060..6065; loopback only)
vpn/DefaultNetworkMonitor.kt # §087: detect genuine iface switch (prev!=new), debounce 1500ms → resetNetwork
vpn/DefaultNetworkListener.kt# a ConnectivityManager.NetworkCallback inside a coroutine actor (ported from SagerNet)
vpn/LocalResolver.kt         # LocalDNSTransport — DNS queries bound to the underlying network (not the tun)
vpn/ConfigManager.kt         # file-based config store (filesDir) + notificationTitle
vpn/ServiceNotification.kt   # the foreground-service notification (typed SPECIAL_USE on API 34+); the §182 action buttons
vpn/VpnStatus.kt             # the Stopped/Starting/Started/Stopping enum (the native side of the status)
vpn/BootReceiver.kt          # the BOOT_COMPLETED auto-start plus the SharedPreferences native toggles
vpn/LxBoxTileService.kt      # the QS tile toggle (§032) with optimistic rendering
vpn/QuickShortcuts.kt        # dynamic launcher shortcuts (Connect/Disconnect)
vpn/LxBoxIntentReceiver.kt   # the §047 raw broadcast API: nine incoming actions, an optional permission gate, setEnabled
vpn/WifiInfoReader.kt        # §051 the single source of the Wi-Fi SSID/BSSID (a permission preflight, a sealed Result)
vpn/WifiNetworkObserver.kt   # §051 auto-record: NetworkCallback → WifiHistoryBridge → Dart onWifiSeen
vpn/PermissionUtils.kt · Extensions.kt  # the SDK-gated permission check; small Kotlin extensions

automation/                  # the §047 Locale/Tasker plugin (FIRE_SETTING/QUERY_CONDITION) — see ../docs/AUTOMATION.md
automation/LocaleApi.kt              #   the twofortyfouram standard's constants plus JSON bundle (de)serialization
automation/LocaleSettingReceiver.kt  #   FIRE_SETTING → the shared action handlers (start/stop/toggle directly)
automation/LocaleConditionReceiver.kt#   QUERY_CONDITION → currentStatus and the active cache → a result code (SATISFIED)
automation/LocaleQuickActionActivity.kt # a one-tap Start/Stop/Toggle (Theme.NoDisplay, a headless setResult plus finish)
automation/LocaleSettingEditActivity.kt # the “Custom…” edit screen: a RadioGroup of commands plus a selector
automation/LocaleConditionEditActivity.kt # the condition edit screen (VPN up / active node= / active group=)
```

---

## Data flows

### 1. Starting the VPN

```
User tap Start (toggle button)
  │  HapticService.onConnectTap()
  ↓
HomeScreen._startWithAutoRefresh()
  │  (no HTTP fetch — auto-update is a separate concern, spec 027)
  ↓
HomeController.start()
  ↓
BoxVpnClient.startVPN() → MethodChannel → VpnPlugin
  ↓
BoxVpnService.onStartCommand()
  ├─ resetScope() → fresh serviceScope
  ├─ startForeground notification
  └─ serviceScope.launch {
       startCommandServer()
       DefaultNetworkMonitor.start(serviceScope)
       Libbox.newService(config) → libbox creates tunnel
     }
  ↓
Broadcast STATUS_CHANGED → "Started"
  ↓
EventChannel → Dart: HomeController._handleStatusEvent()
  ├─ state.configChangedNeedRestart = false
  ├─ HapticService.onVpnConnected() — medium impact
  └─ AutoUpdater.onVpnConnected() — triggers refresh after 2 min
  ↓
CommandClient: connectScreen() → the groups push stream (selectors only) plus
  getGroups() as a unary pull (deterministic filling, since the push is leaky)
  ↓
UI updates: group dropdown, node list, traffic bar
```

### 2. Adding a subscription and auto-config

```
Paste/QR/file → SubscriptionsScreen._add() | _pasteFromClipboard()
  ↓
SubscriptionController.addFromInput(text)
  ├─ isSubscriptionUrl → add SubscriptionServers entry + _fetchEntry
  ├─ isWireGuardConfig → parseWireguardIni → UserServer entry
  ├─ isDirectLink → parseUri → UserServer entry
  └─ isJsonOutbound → parseAll(decode(json)) → UserServer entries
  ↓
_persist() — writes to lxbox_settings.json
  ↓
_regenerateAndSave() — auto (v1.3.1+)
  ├─ generateConfig() — no HTTP, local assembly only
  └─ homeController.saveParsedConfig(config)
        ├─ changed = canonical(new) != canonical(state.configRaw)   (§116 text diff)
        ├─ needRestart = changed && (tunnelUp || prev)              (§323 — no longer sticky
        │                                                            when changed == false)
        └─ if (needRestart && tunnelUp): ask the core                (§324)
              formatConfig(saved + OverrideOptions) vs runningConfigRaw
                fresh   → needRestart = false   (cosmetic-only difference)
                stale   → keep
                unknown → keep (conservative: core could not answer)
  ↓
UI refreshes row (subtitle: "<PROTOCOL> server") + snackbar
  ↓
If tunnelUp: pink "Config changed — restart VPN" banner (spec 003 §8a)
```

### 3. Subscription auto-update (spec 027)

```
Trigger: appStart | vpnConnected+2min | periodic(1h) | vpnStopped | manual(force)
  ↓
AutoUpdater.maybeUpdateAll(trigger, force)
  ├─ if _running → skip (dedup)
  ├─ candidates = entries.filter(_shouldUpdate)
  │   └─ _shouldUpdate: enabled ∧ !frozen(fails>=5) ∧ !minRetry(15min) ∧ (force ∨ interval elapsed)
  │       (§129: the auto-updater skips subscriptions with url=file:<uuid> — they are read from the cache)
  └─ for entry in candidates:
       ├─ _inFlight.contains(url) → skip
       ├─ refreshEntry(entry, trigger)  → _fetchEntryByRef
       │    ├─ lastUpdateStatus==inProgress → skip (crash-safe guard)
       │    ├─ mark inProgress + persist
       │    ├─ parseFromSource(UrlSource)
       │    ├─ HttpCache.save(url, body, headers)
       │    └─ copyWith(lastUpdated, lastUpdateStatus, nodes, consecutiveFails)
       └─ sleep 10s ± 2s (between subs)
```

### 4. Subscription metadata

```
HTTP Response Headers:
  profile-title: base64:...           → subscription display name
  subscription-userinfo: upload=N; ...→ traffic quota + expire
  profile-update-interval: 24         → updateIntervalHours
  support-url: https://t.me/...
  profile-web-page-url: https://...
  content-disposition: filename="..." → fallback for title (v1.3.0+)
  ↓
Stored in SubscriptionMeta → SubscriptionServers.{name, meta, updateIntervalHours}
  ↓
Displayed in:
  - Subscription list row: "124 nodes · 🔄 24h · 🕐 3h ago · (2 fails)"
  - Subscription detail → Subscription block (URL, interval picker, status, refresh)
  - Source tab: live GET with headers view
```

### 5. Persistent storage

L×Box's state lives in two places with different semantics:

- **`wizard_template.json`** is the **catalog**: what exists at all (the presets, vars, sections and defaults).
- **`lxbox_settings.json`** is the **user state**: what the user chose and configured (the vars overrides, custom_rules, and so on).

#### Catalog (template, bundled in APK)

```
app/assets/wizard_template.json     # rootBundle.loadString(), template_loader.dart
├── parser_config           # §026 — version + reload interval
├── dns_options             # §043+§044 — default DNS servers + rules
├── ping_options            # §040 — default URL + presets
├── speed_test_options      # §015 — speed-test endpoints
├── group_templates         # §267 — the magic_nodes registry plus the direction/auto templates (the SEED for directions)
├── default_directions[]    # §267 — the direction seed (vpn-1..2); the builder reads directions[] from storage
├── sections[]              # §022 — the Wizard UI chapters (the vars grouped by topic)
├── config                  # the native sing-box section with @var placeholders
│   ├── log / dns / inbounds / endpoints / outbounds / experimental
│   └── route               #   rules[] / rule_set[] / final / default_domain_resolver
└── selectable_rules[]      # §033 — the preset catalog: block-ads, ru-direct, and the rest
                            #   ru-inside, bittorrent-direct, private-ip-direct
```

#### The user state (on the device)

```
<getApplicationDocumentsDirectory>/
├── lxbox_settings.json     # SettingsStorage (Dart) — the main state file:
│                           #   vars / server_lists / custom_rules /
│                           #   dns_options / ping_options /
│                           #   route_final / directions[] (§125/§393, replaces enabled_groups) / chains[] (§393 C) /
│                           #   excluded_nodes (§048 sandbox) / last_global_update /
│                           #   presets_migrated / directions_migrated
├── rule_sets/              # §011 — the cache of binary .srs files (+ §366 .meta.json sidecars)
│   └── <ruleId>.srs
├── workspaces.json         # §417 — the workspace manifest (current, slots, pending)
├── workspaces/<name>/      # §417 — saved workspaces: a copy of lxbox_settings.json,
│                           #   rule_sets/ and sub_cache/ — the working paths above never move
├── applog.txt              # §038/§043 — JSON lines, a 200-line / 64 KB ring
└── corelog.txt             # §043 — JSON lines, a 200-line / 64 KB ring

<Context.filesDir>/         # native `files/` = Dart getApplicationSupportDirectory() —
│                           # NOT the documents dir (Android: app_flutter/) (§316/§414)
├── singbox_config.json     # ConfigManager (Kotlin) — the final sing-box JSON
├── cache.db                # libbox cache_file (basePath = filesDir)
└── sub_cache/              # HttpCache — the raw body plus headers of the subscriptions;
    └── <url.hashCode>{,.headers}   # the only persisted source of subscription nodes (§027/§129)

SharedPreferences (Android):
├── app_theme_mode                       # Flutter UI prefs (haptic_enabled → vars, §159)
└── boxvpn_boot.{auto_start_vpn, keep_vpn_on_exit, background_mode,
                 core_logs_enabled, allow_bypass, auto_redirect,
                 has_tun}                # §189 — a MIRROR of the native_prefs JSON section
                                         # (a working copy in memory). The truth lives in the
                                         # lxbox_settings.json. has_tun (§192) —
                                         # JSON; has_tun is computed from vpn_mode and lives only here.
```

##### The three storage levels of the native prefs (§189 / §192)

Six Android settings (`auto_start`, `keep_on_exit`, `background_mode`,
`core_logs_enabled`, `allow_bypass`, `auto_redirect`) live at three levels:

| Level | Where | Role |
|---|---|---|
| **disk / the truth** | `lxbox_settings.json` → the `native_prefs` section | the source of truth |
| **memory** | the native `SharedPreferences` `boxvpn_boot.*` | a working copy for the **Dart-less** moments |
| **in-memory** | `SettingsStorage._cache` | a lazily loaded cache of the JSON inside the Dart process |

**Why a native copy is needed:** some code runs when the Flutter engine is
unavailable and there is nothing to read the JSON with — `BOOT_COMPLETED` (the
`BootReceiver` auto-start), a swipe `onTaskRemoved` (the keep-on-exit decision),
and `openTun`/`establish` (allow_bypass, per-app). These points read the native copy **synchronously**.

**The write-through path plus the sync at startup:** any `SettingsStorage.setNativeBool` or
`setNativeBackgroundMode` writes the JSON first and then mirrors into native (over the method
channel); native **never** writes the JSON. At startup (`bootstrapAndSyncNativePrefs()` from
`main.dart`): no section means bootstrap (a native⇒JSON seed, the only native⇒JSON write);
a section present means sync (JSON⇒native, the disk overwrites memory and the divergence
repairs itself). Every writer (the UI, the `backup_service` import, the Debug API) must go
through this layer — direct native writes are ephemeral (the sync rolls them back).
[`lib/services/settings_storage/native_prefs.dart`](../app/lib/services/settings_storage/native_prefs.dart).

**`has_tun` (§192)** is a seventh native key, **derived** from `vpn_mode` (§119):
`vpn` and `vpn_proxy` yield `true`, `proxy` yields `false`. It is mirrored on a mode change and
at startup; it gates `VpnService.prepare()` (in proxy mode `prepare` is never called — it would
pointlessly claim the VPN slot and revoke another active VPN). Being computed, it is neither in
the backup block nor in the `native_prefs` JSON section — it lives only in `boxvpn_boot.has_tun`.

#### Builder (template + user-state → final config)

`build_config.dart` merges the template's `config` section plus `selectable_rules[*]` (through `expandPreset`) and the storage state into the final config.

**Idle-suspend (§128/§215, the core's SPEC 020).** Configuring the threshold (the storage key `route_idle_suspend`).

The one-shot migrations (`SettingsStorage`):
- `proxy_sources` → `server_lists` (v1 → v2, §033) — `migrateProxySources` on the first read.
- `app_rules` → `custom_rules` with `packages` (up to v1.3.2 → §030) — `_absorbLegacyAppRules`.
- `enabled_rules` plus `rule_outbounds` → `custom_rules` (up to §030) — inside `RoutingScreen._load`, guarded by `presets_migrated`.
- The `dns_options.servers[]` shape: pre-§043 → §043 → §044 — `_migrateLegacyDnsServers` in the builder's post-steps.

Sensitive fields are filtered on `GET /state/storage` by the denylist scrubber in `services/debug/serializers/storage.dart`.

---

### 6.5. Traffic profiler (§044 / §048)

`TrafficProfiler` is a singleton ChangeNotifier holding a system-wide
rolling buffer of events. Everything is in memory; persistence is deliberately absent. Spec: [`docs/spec/features/044 per-app traffic profiler/spec.md`](./spec/features/044%20per-app%20traffic%20profiler/spec.md).

```
              ┌────────────────────────────────────────┐
              │  TrafficProfiler (singleton)            │
              │   _active: Session? + _completed: Q[5]  │
              └────────────────────────────────────────┘
                     ▲                    ▲
                     │ events             │ events
                     │                    │
        ┌────────────┴────────┐  ┌────────┴──────────────────────┐
        │ DNS stream (§180)   │  │ Connections push (§168)       │
        │  CcChannel.dnsQueries│  │  CcChannel.connections        │
        │  (profilerClient,   │  │  (profilerClient,             │
        │   SPEC 018)         │  │   diff vs prev snapshot)      │
        └─────────────────────┘  └────────────────────────────────┘
                     │                    │
                     ▼                    ▼
        dnsResolve/dnsFail         TCP/UDP open/close events
        attribution FROM THE CORE   attribution from the core
        (processInfo) + cnameChain (CcConnection.packageName,
        + dnsServer/outbound(rc.10) chains §174, detours §178)

              ┌────────────────────────────────────────┐
              │ _globalRollingBuffer  (append-only)     │
              │  +  byDomain / byIp aggregates          │
              │     (computed on-demand)                │
              └────────────────────────────────────────┘
                     │
        ┌────────────┴───────────────────────────────────────────┐
        ▼                              ▼                         ▼
  Profiler tab              Debug API /profiler/live*    SSE /profiler/live/stream
  (TraceExplorer:           (start, stop, state,          (a live push for
   the stream/Aggregated +  live, unattributed)           external clients)
   the per-app filter)
```

> The per-app session layer was removed in **§288**: the `App` tab, the `Session` class and
> the routes `/profiler/{start,stop,active,sessions,session/<id>,stream}` are gone.
> Only the system-wide mode remains; one application's traffic is inspected through the
> per-app filter on the Profiler tab.

**The event sources (§180/§044 — with NO core-log parsing):**
- **The DNS stream (§180, the core's SPEC 018)** — `CcChannel.dnsQueries` (the `lxbox/cc/dns` channel, `subscribeDNSQueries`), with the attribution coming from the core.
- **The connections stream (§168)** — the CommandClient `connections` push (`CcChannel.connections` through the background `profilerClient`).
- The connection-issue classifier: `dnsTimeout` (the structural `q.failed` from the DNS stream) plus `tcpReset` (a heuristic).

**Global, system-wide recording (§048).** The **Profiler** tab (formerly Live) in Statistics is the only mode.

**Memory bounds:**
- `_globalRollingBuffer`: a retention window (§044, 10 minutes by default) plus a hard cap of 20000.

**UI plumbing (§160/§044):**
- `StatsScreen` has three tabs: Stats / Conns / **Profiler** (system-wide, formerly Live). The `App` tab was removed in §288.
- The `TraceExplorer` engine: a control row (pause · retention · grouping · the filter window).

**Coupling (important for extraction):**
- **`CcChannel` (the CommandClient) is the only source.** The profiler listens to `CcChannel.connections` plus `CcChannel.dnsQueries`.
- **The core's contract (SPEC 017/018).** The `chain()`, `detour()` and `DnsQuery.*` fields are native methods of the libbox AAR.

---

### 6.6. WARP / MASQUE (§025 · §130)

The Cloudflare WARP integration (`services/warp/`, the wizard `screens/warp_wizard_screen.dart`, storage in `settings_storage/warp.dart`):

- **WARP over WireGuard (§025).** `WarpClient` registers the device itself (a POST to Cloudflare); the private key never leaves the phone.
- **MASQUE (§130, the flagship of v2.9.0).** Separate cryptography (`masque_keys.dart` — ECDSA P-256, not the WireGuard keys).
- **The endpoint generator (§284/§305).** The **“Make experiment”** button in the wizard (`services/warp/scan/`).
- **The endpoint pool (§305, device-verified).** `assets/warp_endpoints.json` is grouped by transport:
  - `wireguard`: `v4_cidr` · `v6_cidr` · `ports` (2408/500/1701/4500 — the verified ones) · `ports_extra`
  - `masque` (§420): общие `hosts_preset` + `recommended_host` (оба транспорта) · `h3.hosts_extra` (h3-only) · `h2.v4_cidr` + `h2.exclude` · `h3.ports` / `h2.ports` · `sni_pool`. Старые плоские ключи (`v4_cidr`, `h3_v4_cidr`, `ports_h3/h2`) читаются как фолбэк.

  The physics of MASQUE (tested for real through a working tunnel): **h2** works on every port.

### 6. AppLog (per-source ring buffers, §043)

`AppLog` keeps in-memory ring buffers **per source** — `app=300`, `core=500`.

```
HomeController/UI                    Sing-box (Go goroutines)
       │                                       │
       │ AppLog.I.info(...)                    │ writeDebugMessage(line)
       │   source: app                         │   ↓
       │                              [PlatformInterface override]
       │                              BoxVpnService.writeDebugMessage:
       │                                ├─ strip ANSI escapes
       │                                ├─ skip TRACE/DEBUG (volume reduction)
       │                                └─ coreLogSink.success(msg)  ← main thread post
       │                                       │
       │                              EventChannel "lxbox/coreLog"
       │                                       │
       │                              ClashLogPump.attach() listener
       │                                       │ parseLevel (regex \bWARN\b etc.)
       │                                       │ AppLog.I.log(level, msg, source: core)
       ▼                                       ▼
┌─────────────────────────────────────────────────────┐
│           AppLog (singleton)                          │
│                                                       │
│  Map<DebugSource, List<DebugEntry>> _entriesBySource  │
│   ├─ app:  [...] cap 300                              │
│   └─ core: [...] cap 500                              │
│                                                       │
│  log(level, msg, source) — O(1) amortized insert      │
│    + per-source trim                                  │
│  entries — an O(n×k) k-way merge on read (k=2)        │
│  entriesForSource(s) — O(1) direct lookup             │
│                                                       │
│  Persistent (warn/error only):                        │
│    app  → applog.txt                                  │
│    core → corelog.txt                                 │
└─────────────────────────────────────────────────────┘
       │                                       │
       │ /logs?source=...&level=...&q=...      │ DebugScreen
       │ /logs/app   /logs/core                │ (segmented "All/Core/App",
       │ /logs/clear?source=...                │  level filter chips,
       ▼                                       ▼ search field)
   Debug API                            Flutter UI
```

**Key design rules:**
- `coreLogSink` (a volatile companion field in `BoxVpnService`) receives the sing-box callbacks from any thread.
- `EventChannel.EventSink.success()` requires the **main thread**, so we dispatch through `coreLogMainHandler`.
- Forwarding is gated by the `Libbox.setup(SetupOptions{debug: ...})` flag (read from the `BootReceiver` prefs).

### 7. The detour dependency graph (§355)

```
activeConfigRaw (on change) ──► DependencyGraph.fromConfig (models/dependency_graph.dart)
                              the statics: node/dns --detour--> node|direction; the group membership
delayByDirection (measurements) ──┐
groups stream (the selection) ──┴─► HomeController._recomputeDependencyHealth()
                              computeSick: a dead node (every measurement is ERR) → a BFS upward
                              along the reverse edges (a selector's choice infects the direction;
                              a urltest is sick only when its whole membership is dead — §308
                              heals itself)
  ↓ (only when the result changes)
HomeState.sickRoots (a root → the affected DNS entries and nodes, with the via path)
  ├─ NodeRow: a ⚠ mark next to the root's name → tap → dependency_sheet
  └─ a DNS victim appears → lastError = DnsViaDeadNodeMsg (a banner; it clears once every
     DNS victim is gone)
```

No new network activity: only the events that already exist.
The health model and the non-goals are in [the §355 spec](spec/tasks/355-detour-dependency-health-warnings.md).

---

## Dart `BoxVpnClient` API surface

A thin client over three channels (`com.leadaxe.lxbox/methods` plus two EventChannels).

**Singleton + DI:**
- In production it is `BoxVpnClient.I` (or `BoxVpnClient()`, an alias of the singleton kept for backward compatibility).
- Tests — `BoxVpnClient.forTest(methods: mock, events: mock)`. `@visibleForTesting`.

**The method groups** (in the same order as the `_Methods` constants):

| Group | Methods | Notes |
|---|---|---|
| Config | `saveConfig` / `getConfig` | `getConfig` falls back to `'{}'` so the builder can parse without a null check |
| VPN lifecycle | `startVPN` / `stopVPN` / `reloadVPN` / `resetNetwork` / `getVpnStatus` / `getCoreVersion` / `quitApp` | — |
| Settings (the boot prefs and native toggles) | auto_start, keep_on_exit, core_logs_enabled, allow_bypass, auto_redirect | — |
| Per-app routing | `getInstalledApps` / `getAppIcon` / `getAppInfo` | Icons are lazy — `getInstalledApps` returns none |
| System helpers | `isIgnoringBatteryOptimizations` / `open*Settings` / `*NotificationPermission` / `*NearbyWifiPermission` | — |
| Quick Settings | `requestAddTile` | API 33+ |

**Status stream design:**

```dart
late final Stream<TunnelStatusEvent> onStatusChanged = _events
    .receiveBroadcastStream()
    .map(...)
    .asBroadcastStream();
```

`late final` matters: before v1.4.0 every getter created a new stream and the native `EventChannel` leaked sinks.

**Timeout policy:**

Every MethodChannel call is wrapped in a `.timeout()` with a per-method value.

| Category | Timeout | Why |
|---|---|---|
| status / settings | 3s | Lightweight read/write of preferences |
| config | 5s | File I/O |
| app metadata (per-package) | 5s | One PackageManager query |
| The installed-apps list | 15 s | `PackageManager.getInstalledApplications` is expensive |
| startVPN | 30s | System dialog timing + libbox setup |
| stopVPN | 10 s | It blocks until `setStatus(Stopped)` |
| reloadVPN / resetNetwork | 5-10s | Wait for `serviceReload` / `closeAll + DNS flush + dialer rebind` |
| requestAddTile | 10s | System dialog confirmation |

**On a timeout** it logs into `AppLog` and falls back to a safe default (for example `tunnel: disconnected`).

---

## Native Architecture (Kotlin)

### Class layout (§049 F1 split)

In the §049 audit we ported the pattern from the SagerNet reference (`bg/BoxService.kt`, commit 3b3883e, libbox 1.12).

```
┌─────────────────────────────────────────┐  ┌────────────────────────────────────┐
│ BoxApplication : Application            │  │ VpnPlugin : MethodCallHandler      │
│  • onCreate (registered in Manifest)    │  │  • setMethodCallHandler            │
│  • §334 CrashRecovery ← STRICTLY BEFORE setup │ • EventChannel sinks (status/log) │
│    one event, two subscribers: the cleanup here, │ • the static currentStatus mirror │
│    the §316 banner in Dart, from the archive │  (read synchronously by HomeController) │
│  • Libbox.setup(SetupOptions) async     │  │                                    │
│  • libboxReady : CompletableDeferred    │  │                                    │
│  • Singleton WifiNetworkObserver        │  │                                    │
└─────────────────────────────────────────┘  └────────────────────────────────────┘
                                                           │ start/stop intent
                                                           ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ BoxVpnService : VpnService, PlatformInterfaceWrapper                            │
│  • Android lifecycle (onCreate/onStartCommand/onRevoke/onDestroy)               │
│  • PlatformInterface impl: defaultNetwork / processInfo / readWIFIState         │
│  • openTun()  ← libbox calls back through PlatformInterface                     │
│  • field: private val service = BoxService(this, this)  ← THIS line is the F1   │
│  • forwards lifecycle: onStartCommand → service.startSingbox(intent), etc.      │
└─────────────────────────────────────────────────────────────────────────────────┘
                                          │ owns
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ BoxService : CommandServerHandler   (plain class, NOT a Service)                │
│  • libbox state: AtomicReference<ParcelFileDescriptor> fileDescriptor           │
│                  AtomicReference<CommandServer>          commandServer          │
│  • serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)              │
│  • startSingbox(intent) / doStop() / serviceReload() / receiver{stop,reload,..} │
│  • CommandServer(this, platformInterface)  ← 2 different Java instances:        │
│       CSH=BoxService  PI=BoxVpnService  (mirrors reference; reduces refnum-42   │
│       JNI race surface compared with prior `CommandServer(this, this)`)         │
│  • status broadcasts via BROADCAST_STATUS → VpnPlugin.statusReceiver → sink     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Why the split:** before §049 `BoxVpnService` implemented both `PlatformInterface` and `CommandServerHandler`.

### Structured Concurrency

```
BoxService (per instance, recreated with every new BoxVpnService)
  └─ serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
       ├─ resetScope() in startSingbox (cancel is terminal)
       ├─ All coroutines tied to service lifecycle
       ├─ DefaultNetworkMonitor receives serviceScope
       │    └─ checkUpdate() uses scope.launch — dies with service
       └─ doStop() calls serviceScope.cancel() as safety net
```

**`AtomicReference` for fileDescriptor and commandServer** (§049 F2/F3): `getAndSet(null)?.close()` guarantees a single close.

### Channel Contract

The three Flutter–Android channels live in `VpnPlugin.kt`:

| Channel | Type | Direction |
|---|---|---|
| `com.leadaxe.lxbox/methods` | MethodChannel | Bidirectional (Dart → Native; Dart ← Native for `wifi_history`) |
| `com.leadaxe.lxbox/status_events` | EventChannel | Native → Dart (TunnelStatus broadcasts) |
| `lxbox/coreLog` | EventChannel | Native → Dart (sing-box log lines) |

**The MethodChannel methods** (the groups follow the `_Methods` constants in `box_vpn_client.dart`):

| Group | Method | Input | Output |
|---|---|---|---|
| **Config** | saveConfig | `config: String` | bool |
| | getConfig | — | String |
| **VPN lifecycle** | startVPN | — | bool (may trigger system VpnService dialog) |
| | stopVPN | — | bool — it **blocks** natively until `setStatus(Stopped)` so the caller can proceed safely |
| | reloadVPN | — | bool — `box.serviceReload()` with no status flap |
| | resetNetwork | — | bool — light recovery: `closeAllConnections + DNS flush + dialer rebind`. Tunnel must be up. |
| | getVpnStatus | — | "Started" \| "Starting" \| "Stopped" \| "Stopping" \| "Unknown" |
| | getCoreVersion | — | String — sing-box version + tags |
| | quitApp | — | bool (it returns immediately and the process dies in about 250 ms) — `finishAffinity` plus `Process.killProcess` |
| **Settings (boot prefs / native toggles)** | getAutoStart / setAutoStart | bool | bool — auto-start VPN on boot (`BootReceiver`) |
| | getKeepOnExit / setKeepOnExit | bool | bool — keep the VPN running when the Flutter process is killed |
| | getCoreLogsEnabled / setCoreLogsEnabled | bool | bool — §043 forwards the sing-box logs into Dart's `AppLog`; it needs a restart |
| | getAllowBypass / setAllowBypass | bool | bool — §049 F15 `VpnService.Builder.allowBypass()`; applied on the next start |
| | getBackgroundMode / setBackgroundMode | "never" \| "lazy" \| "always" | bool — §052 foreground-service tunnel sleep mode |
| **Notifications** | setNotificationTitle | `title: String` | bool — a custom foreground notification title |
| | setNotificationText | `text: String` | bool — §123 a custom foreground notification text |
| **Per-app routing helpers** | getInstalledApps | — | A List<Map> (`package` / `appName` / `isSystemApp`) — icons excluded |
| | getAppIcon | `packageName: String` | String (base64 PNG) |
| | getAppInfo | `packageName: String` | A Map (name plus isSystem, **no icon** — §109) \| `{notFound: true}` |
| **System helpers** | isIgnoringBatteryOptimizations | — | bool |
| | openBatteryOptimizationSettings | — | bool — the primary `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` prompt, with a fallback |
| | openAppDetailsSettings | — | bool |
| | openAppSettings | — | bool — the App Permissions screen (a three-level OEM fallback) |
| | areNotificationsEnabled | — | bool |
| | openNotificationSettings | — | bool |
| | checkNotificationPermission | — | bool — `POST_NOTIFICATIONS` on API 33+, true before that |
| | requestNotificationPermission | — | null — asynchronous; the UI must re-check through `checkNotificationPermission` |
| | checkNearbyWifiPermission | — | bool — `NEARBY_WIFI_DEVICES` on API 33+, true before that |
| | requestNearbyWifiPermission | — | null — async; re-check |
| | showToast | `msg: String, duration: "short"\|"long"` | bool |
| **Quick Settings tile** | requestAddTile | — | bool — `StatusBarManager.requestAddTileService` (API 33+) |
| **Diagnostics** | getApplicationExitInfo | — | List<Map> (API 30+) |
| | getLogcatTail | `count?, level?` | String |

**EventChannel `status_events`** — `TunnelStatusEvent`:
```json
{ "status": "Started" | "Starting" | "Stopped" | "Stopping", "error": "..." }
```

**The `coreLog` EventChannel** carries the sing-box log lines, one line per event. The filter skips TRACE and DEBUG.

---

### Permissions (Manifest + runtime)

**Manifest declarations** ([AndroidManifest.xml](../app/android/app/src/main/AndroidManifest.xml)):

| Permission | Why | Granted at runtime? |
|---|---|---|
| `INTERNET` | sing-box egress | install-time |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_SYSTEM_EXEMPTED` | The VPN service is a visible foreground service | no |
| `RECEIVE_BOOT_COMPLETED` | auto-start on boot | install-time |
| `POST_NOTIFICATIONS` | foreground service notification (API 33+) | runtime, default off |
| `QUERY_ALL_PACKAGES` | per-app split-tunneling list, app-picker | install-time |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | one-tap battery whitelist prompt (API 23+) | install-time + system one-tap dialog |
| `ACCESS_WIFI_STATE` | sing-box wifi rules / WifiInfo helpers | install-time |
| `ACCESS_COARSE_LOCATION` / `ACCESS_FINE_LOCATION` | A pre-API-29 fallback for the WifiInfo SSID | at runtime, off by default |
| `ACCESS_BACKGROUND_LOCATION` | Required on API 29+ for `WifiManager.connectionInfo` from the background | through Settings |
| `NEARBY_WIFI_DEVICES` (`neverForLocation`) | Required on API 33+ for a real SSID/BSSID; without it the SSID reads as unknown | at runtime |

**The `neverForLocation` flag** on `NEARBY_WIFI_DEVICES` declares to Google Play that the permission is not used to derive a location.

**Permission gating in `BoxService.startSingbox`** ([BoxService.kt](../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt)):

After `startOrReloadService` (which parses the config) sing-box exposes `commandServer.needWIFIState()`.

Permission matrix:

| API | What `WifiInfo.ssid` requires |
|---|---|
| API 28- | `ACCESS_FINE_LOCATION` |
| API 29-32 | `ACCESS_BACKGROUND_LOCATION` |
| API 33+ | `ACCESS_BACKGROUND_LOCATION` plus `NEARBY_WIFI_DEVICES` (without NEARBY it reads `<unknown ssid>`) |

**A defensive try/catch in `PlatformInterfaceWrapper.readWIFIState`** ([PlatformInterfaceWrapper.kt](../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/PlatformInterfaceWrapper.kt)):

#### The JNI no-throw invariant (§050 · §151)

A cross-cutting rule for **every** Kotlin callback that libbox invokes.

**Runtime grant flow** (Flutter side):

```
[Connect tap]
   ↓
BoxService.startSingbox detects needWIFIState() && missing permissions
   ↓
stopAndAlert("alert:permission_location:<perms>")
   ↓
HomeController.lastError = "Stopped: alert:permission_location:..."
   ↓
home_screen._handleStatusEvent catches the prefix → an AlertDialog
   ↓
[Allow Wi-Fi info]               [Open Settings]
runtime prompt (NEARBY)          MANAGE_APP_PERMISSIONS intent
                                 → three fallback strategies:
                                   1. MANAGE_APP_PERMISSIONS
                                   2. MANAGE_PERMISSION_APPS
                                   3. ACTION_APPLICATION_DETAILS_SETTINGS
   ↓                                    ↓
re-check via checkNearbyWifiPermission → user re-Connect
```

`POST_NOTIFICATIONS` goes through an **explainer flow** in `home_screen._maybeShowNotificationPermissionDialog`.

---

### VPN Lifecycle & Status Sync

The tunnel's model: **`BoxVpnService` is an Android foreground service that lives separately from the Flutter process.**

1. **The Flutter process is alive and so is the service** — normal operation.

2. **The Flutter process died while the service lives on** — this happens with `keep-on-exit = true`.

3. **The system killed the service** — an OOM, a libbox crash, or a revoke by another VPN.

#### The pull-sync mechanics

The source of truth is `BoxVpnService.companion.currentStatus: VpnStatus` (`@Volatile`, updated on every change).

```
HomeController.init()
  ├─ _loadSavedConfig()
  ├─ _statusSub = _vpn.onStatusChanged.listen(_handleStatusEvent)  ← subscribing to the deltas
  └─ raw = await _vpn.getVpnStatus()                               ← pulling the current value
     └─ _handleStatusEvent({status: raw})  ← the same handler; it decides what to emit
```

Without the `getVpnStatus` pull, case 2 broke: the UI stayed “Disconnected” forever until something happened.

#### Broadcast versus pull — which is used when

| Event | Mechanism |
|---------|----------|
| A transition (`Starting` → `Started`) | broadcast → EventChannel |
| An app reattach (a new Flutter process while the service lives) | a `getVpnStatus` pull in `init` |
| A failed heartbeat (the CommandClient status stream stayed silent past the timeout) | `HomeController._onTunnelDead` |
| A safety timeout (stuck in Starting/Stopping for 10 s) | a `Future.delayed` in `_handleStatusEvent` forces the state |

#### Reconnect flow (v1.4.0+)

`HomeController.reconnect()` composes `_stopInternal` and `_startInternal` with blocking semantics.

```
1. If the tunnel is already down, just start() and return.
2. busy=true.
3. _stopInternal: await _vpn.stopVPN() — native blocks until
   setStatus(Stopped) or a 5 s timeout. An intent-based reset of the sticky flag.
4. If the stop timed out, abort with lastError="Stop timed out".
5. _startInternal: setNotificationTitle + startVPN + intent-based reset.
6. busy=false in the finally block.
```

No `firstWhere` or timeout on the Dart side. The blocking `stopVPN` lives natively.

Before v1.4.0 the reconnect was built on Dart-side coordination through `firstWhere(disconnected)`.

#### The keep-on-exit setting

The toggle lives on the **Mode tab** (§188; before §188 it was VPN Settings → System, §052; before that, App Settings).

With `true`, killing the Flutter process does not oblige the system to stop the service.

The pull sync works regardless of keep-on-exit: if the service happens to be alive, the UI picks up its status.

#### Deep links between the tabs and the settings (§052)

Tabs that depend on a global toggle in the settings (core_logs_enabled, the VPN settings vars) link to it.

Two patterns: a **contextual banner** (a state-dependent hint) and an **overflow item** (state-independent).

- **Statistics → Live and Per-app → the contextual `CoreLogsHintBanner`** ([core_logs_hint_banner.dart](../app/lib/widgets/core_logs_hint_banner.dart))
- **Routing → Tunnel apps → ⋮ → “VPN settings (Core)”** → `SettingsScreen(initialTab: 1)`. State-independent. |
- **Drawer → Debug → ⋮ → “Diagnostics settings”** → `AppSettingsScreen(initialTab: 1)` — a fast path. |

---

## CommandClient (libbox)

§122 — the UI↔core control channel. The Clash HTTP API was removed entirely.

### The model: push streams, not pull snapshots

The core emits changes and the UI subscribes. The old flow of three pollers is gone.

### The native clients (`BoxCommandClient.kt`)

Four independent `CommandClient`s decouple the update rates and the lifecycles.

| Client | Commands | Lifecycle |
|---|---|---|
| `statusClient` | `CommandStatus` (plus `setStatusInterval`) | Always on while the tunnel lives; slowed down in the background |
| `screenClient` | `CommandOutbounds` + `CommandGroup` + `CommandConnections` | Raised by `connectScreen`, paused in the background |
| `profilerClient` | `CommandConnections` + `subscribeDNSQueries` (SPEC 018, §180) | Raised for recording and kept alive in the background |
| `pingClient` | A bare `PingHandler` with no subscriptions — unary RPC only | §175/§209 — lifecycle-independent |

A subscription in the gomobile facade is `CommandClientOptions.addCommand(int)` plus the `CommandClientHandler` callbacks.

### The Dart layer (`CcChannel`)

Push streams over the `lxbox/cc/*` EventChannel (`status` · `outbounds` · `groups` · `connections` · `dns`):

| Stream / method | Type | Purpose |
|---|---|---|
| `status` | a push `Stream<CcStatus>` | up/down plus a traffic snapshot; it feeds the heartbeat watchdog |
| `outbounds` | a push `Stream<List<CcOutbound>>` | the list of outbounds |
| `groups` | a push `Stream<List<CcGroup>>` | the selector and urltest groups plus selected/active |
| `connections` | a push `Stream<List<CcConnection>>` | the active TCP/UDP connections plus bytes and packageName/processPath |
| `dnsQueries` | a push `Stream<List<CcDnsQuery>>` | §180 (SPEC 018) — the DNS queries from the core (domain, rcode, latency) |
| `getGroups()` | a unary pull returning `List<CcGroup>?` | a deterministic snapshot of the groups |
| `getRules()` | a unary pull returning `List<CcRule>` | a snapshot of the route and DNS rules (for diagnostics) |
| `getPool(tag)` | a unary pull returning `List<CcPoolSlot>?` | §208/§209 — a snapshot of a round_robin group's pool |
| `urlTestOutbound(tag)` | a unary RPC returning `CcDelayResult` | the per-node delay. **The invariant:** an `error` is the only signal of failure |
| `selectOutbound(group, tag)` | unary-RPC | selector switch |
| `closeConnection(id)` / `closeConnections()` | a unary RPC | close one connection or all of them |

**§209 — every unary method above goes through `pingClient`** (which is lifecycle-independent).

The lifecycle signals (`connectScreen`/`disconnectScreen`, `connectProfiler`/`disconnectProfiler`, `pauseClients`).

### Wiring

On a `connected` event `HomeController` subscribes to the `status` and `groups` streams.

### Gotchas

- **An empty groups push over a live one** — the core can send an empty groups list.
- **No external subscribers** — the command server listens on localhost; third-party Clash clients cannot attach.
- **§193 — connections are single-shot with no pull (an asymmetry with groups).** The `connections` subscription is one-way.
- **§194 — the three connection counters count DIFFERENT things.** Do not conflate them:
  - **The home screen** ([`traffic_bar.dart`](../app/lib/screens/home/widgets/traffic_bar.dart)) shows the core's counter.
  - **Stats** shows the active ones from the list (`closedAt==0`) ≈ `connectionsIn`.
  - **Conns** shows the live ones plus the closed history, as “N active / M total”.

---

## Localization (l10n, §279 / §285)

en (the base) plus ru; a new language is one natural-key dictionary plus one
template overlay plus one `values-<lang>/`, with no structural changes.
Switching at runtime needs no app restart, including the native surfaces on a
live VPN service. Since §285 the UI strings are localized through **natural keys**
(the English call-site text IS the key; ARB and gen_l10n are gone). The full
architecture is in [the §279 spec](spec/features/279%20localization/spec.md) plus
[the getLocalText review](spec/features/279%20localization/getlocaltext.md);
translator-guide — [`l10n.md`](l10n.md).

| Component | Role |
|---|---|
| `lib/services/l10n/get_local_text.dart` | `GetLocalText` — the natural-key engine: `.s("en text", args)` |
| `lib/services/l10n/plural_resolver.dart` | `PluralResolver` plus `En`/`RuPluralResolver` (the CLDR forms) |
| `assets/l10n/ru/ui.json` | The natural-key dictionary: `englishKey → { value: String\|pluralObj, special: … }` |
| `lib/services/l10n/locale_controller.dart` | `LocaleController` — the **sole owner** of the locale-switch pipeline |
| `lib/services/l10n/template_overlay.dart` | The pre-parse overlay of `wizard_template.json`'s display text (see [TEMPLATE.md](TEMPLATE.md#localizing-the-display-text--the-l10n-overlay-279)) |
| `lib/services/l10n/template_aware_state.dart` | A mixin: it refetches template-derived state in `didChangeDependencies` |
| `lib/services/l10n/app_language_reconcile.dart` | The three-way reconciliation with `LocaleManager` (Android 13+) |
| `lib/models/ui_msg.dart` | The sealed `UiMsg` — stored errors and statuses as typed values |
| `app/tool/l10n/` | Four CI checkers (`--strict` on every PR): ui_check, template_check, hardcoded_check, kotlin_check |
| `android … L10n.kt` | The native resolver: it reads `boxvpn_boot.app_language` and calls `createConfigurationContext` |

`MaterialApp.localizationsDelegates` carries only Flutter's built-in delegates
(the global Material/Widgets/Cupertino chrome); the app's own strings go through
`getLocalText` rather than a `Localizations` delegate.

**The language-switch pipeline** (every path that writes `app_language` — the picker, Debug,
a side-effect hook, a restore, or a system language change — converges here):
`LocaleController.set()` / `_applyLocale()`):

```
LocaleController.set(v)
  ├─ SettingsStorage.setAppLanguage(v)      # the JSON var (the truth) plus the MethodChannel mirror
  │     └─ native: the BootReceiver pref → resubmitting the notification channel →
  │        ServiceNotification.relabel → updateShortcuts (+onResume retry) →
  │        tile.requestListeningState → Libbox.setLocale → LocaleManager (33+)
  └─ _applyLocale(effective)
        ├─ _text = GetLocalText(dict<tag>, resolver<tag>)  # the new locale's natural-key dictionary
        ├─ await TemplateLoader.reload(tag)  # WARMED BEFORE notify (the cache is keyed by tag)
        ├─ RuleNameResolver.relocalize(...)  # the builder's display mirrors, with no rebuild
        ├─ LazyPersistFlush.flushAll()
        └─ notifyListeners()                 # a Listenable merged with themeNotifier → MaterialApp rebuilds
```

**The boundaries** (English forever): the logs, the Debug API responses, the
automation/Tasker payloads, `emitWarnings`, the wire values and tags, filenames,
user data, and the OS/core payloads (the `RawMsg.detail` passthrough). The units
(`B/KB/MB`, `Mbps`, `ms`) and the duration suffixes stay Latin in both locales.

---

## State Management

| Controller | Responsibility |
|-----------|---------------|
| `HomeController` | VPN lifecycle, CommandClient (groups/status/connections), nodes, ping (10 concurrent — `_pingConcurrency`), heartbeat, traffic, configChangedNeedRestart, autoUpdater wiring, haptic on transitions |
| `SubscriptionController` | CRUD entries (server_lists), `refreshEntry`/persist, `generateConfig` (no HTTP), `bindAutoUpdater`, init sweep (inProgress→failed) |
| `ThemeNotifier` | Theme mode, SharedPreferences persistence |
| `HapticService` (singleton) | Event-based haptic with 100 ms throttle, respects system setting (spec 029) |
| `AutoUpdater` | Owned by HomeScreen; wraps SubscriptionController for 4-trigger auto-update with spam gates (spec 027) |

Pattern: `ChangeNotifier` + `AnimatedBuilder`. `HomeState` is immutable with `copyWith` (sentinel `_unset` for nullable fields).

`_needsRestart` in HomeScreen is a derived getter — returns `true` when `_subController.configDirty || (state.tunnelUp && state.configChangedNeedRestart)`. **§076 update**: `configDirty` branch is no longer gated on `tunnelUp` — settings-changed banner shows whenever there are pending changes, independent of tunnel state. Two banners mutually exclusive: blue «Settings changed» for `configDirty`, pink «Restart VPN» for `tunnelUp && configChangedNeedRestart && !configDirty`. Sticky until tunnel up↔down transition (see spec 003 §8a).

**§323/§324 update — the pink banner is no longer purely sticky.** Two things clear it early:

- **§323** — an identical rebuild (`changed == false`) *clears* the flag instead of preserving it. Rationale: if the saved config matches the previous one byte-for-byte, the running instance cannot be stale, regardless of flag history. A successful `reloadVpn()` also clears it (the core re-read the file, so running == saved).
- **§324** — a text diff answers "did the file change", not "is the running instance stale". When the diff says *changed* and the tunnel is up, the core is asked instead: `formatConfig(saved + OverrideOptions)` vs `runningConfigRaw` (§311 snapshot). Both sides pass through the same core parser+encoder (kernel SPEC 037 §3), so field order / `omitempty` / `[] → null` collapse **inside the core** — no client-side list of "differences to ignore". The verdict can only *clear* a false banner, never raise one; `unknown` (core unreachable, snapshot absent, old kernel) keeps the banner. See `services/config_staleness.dart` — it mirrors `OverrideOptions` because `formatConfig` does not apply them while the snapshot is post-override.

---

## Navigation

```
HomeScreen
  ├─ Drawer:
  │   ├─ Servers → SubscriptionsScreen
  │   │              ├─ onTap UserServer → NodeSettingsScreen (editable Tag, Mark as detour)
  │   │              └─ onTap SubscriptionServers → SubscriptionDetailScreen
  │   │                     (Nodes / Settings / Source tabs)
  │   ├─ Routing → RoutingScreen
  │   ├─ DNS Settings → DnsSettingsScreen
  │   ├─ VPN Settings → SettingsScreen — 2 tabs (§052):
  │   │       • System — Tunnel sleep mode (`BackgroundMode`)
  │   │                 (§188 — “Allow VPN bypass” and “Keep VPN on exit” moved to the Mode tab)
  │   │       • Core   — sing-box engine vars (`chapter: core`, mtu / log_level / dns_final / …)
  │   ├─ App Settings → AppSettingsScreen — 2 tabs (§052 Phase 2):
  │   │       • General      — theme, autostart, haptic
  │   │       • Diagnostics  — system permissions block + verbose / share / wipe + Quit&reopen
  │   │       (the Background tab is gone; `keep_on_exit` and `background_mode` moved to VPN Settings)
  │   │        the permissions block moved to Diagnostics)
  │   ├─ Speed Test → SpeedTestScreen
  │   ├─ Statistics → StatsScreen (via traffic bar tap)
  │   ├─ Config: Editor / File / Clipboard
  │   ├─ Debug → DebugScreen (share all dump button)
  │   └─ About → AboutScreen (local build badge + git describe)
  ├─ Start/Stop toggle + sticky restart warning
  ├─ Traffic bar → tap → StatsScreen
  ├─ Group dropdown (selector groups only)
  └─ Node list:
       ├─ NodeRow layout: [ACTIVE pill] [PROTOCOL · transport · security (§102)] ... [ping →]
       └─ long-press: Ping · Use · View JSON · Copy URI
          (§099 — the copy-JSON variants live in a dropdown inside View JSON)
           Copy node JSON / Copy server JSON / Copy server + detours(N))
```

---

## Key Decisions

| Decision | Reason |
|----------|--------|
| Native VPN service (no plugin) | flutter_singbox_vpn was unmaintained (0 stars), config in SharedPreferences |
| File-based config storage | Large JSON configs don't belong in SharedPreferences |
| serviceScope vs GlobalScope | Structured concurrency — coroutines die with service |
| libbox CommandClient for management (§122) | A server-stream push instead of Timer polling; the Clash HTTP API is gone |
| 10 concurrent mass pings (`_pingConcurrency`) | Sequential was too slow for 50+ nodes; the cap balances speed against load |
| SRS rules off by default | Require download, may fail offline |
| App list caching | getInstalledApps (~5s) called once, reused |
| profile-title from headers + content-disposition fallback | Auto-name subscriptions even without profile-title |
| URLTest hidden from dropdown | Users can't manually select in urltest — confusing UX |
| **Sealed `NodeSpec`** (Parser v2, v1.3.0) | Exhaustive switch at compile time; no runtime `type == 'vmess'` checks |
| **3-layer parser/builder** | Separation of concerns: parse ≠ build ≠ emit |
| **UserServer.toJson stores only rawBody** | `nodes` is derivable via `parseAll(decode(rawBody))` on fromJson; saves disk space, avoids NodeSpec serialization drift |
| **AutoUpdater gates** (spec 027) | `minRetryInterval=15min`, `maxFailsPerSession=5`, `_running`/`_inFlight` dedup — subscriptions never spam providers |
| **configChangedNeedRestart sticky flag** | Restart warning doesn't disappear on Stop-dialog cancel |
| **TLS-insecure → info severity** | Providers set it intentionally (REALITY, self-signed); shouldn't crowd out genuine warnings |
| **A shared `asBroadcastStream` for status events** (v1.4.0) | `BoxVpnClient.onStatusChanged` is cached as a `late final` |
| **A blocking `stopVPN` through a Completer** (v1.4.0) | The method channel waits for `setStatus(Stopped)` natively |
| **An intent-based sticky reset** (v1.4.0) | `configChangedNeedRestart=false` in `_stopInternal` and `_startInternal` |
| **`TunnelStatus.unknown`** (v1.4.0) | The default for an unknown raw value, instead of `disconnected` |
| **`ConfigCache` in HomeState** (v1.4.0; superseded by §091 → `ParsedConfig`) | The outbound JSON used to be parsed on every build |
| **`kDetourTagPrefix` as the single source of truth** (v1.4.0) | The `⚙ ` constant lives in `lib/config/consts.dart` |
| **Two persist patterns: lazy versus eager** (v1.9.0, §076) | Editing screens with a toggle-flood UX (`tun_apps_tab`) persist lazily |
| **A global `HomeReturnObserver`** (v1.9.0, §076) | A universal `NavigatorObserver` in `MaterialApp.navigatorObservers` |
| **An mtime-based bootstrap** (v1.9.0, §076; §113) | `ConfigDirtyCheck.isDirty()` compares the mtimes of `lxbox_settings.json` and the config |
| **The external `markConfigChangedNeedRestart` mark** (v1.9.0, §076) | A `HomeController` method for the settings screens |
| **Cohesion over line count, with `part`/`mixin` decomposition** (§089) | The monsters (home_screen and friends) were split by responsibility |
| **`ConfigNode` structural metadata instead of reverse-parsing the tag** (§091, implemented) | It removed a whole class of UI bugs |
| **`VarValuesModel` — a per-key reactive settings model** (§232) | One-way updates with no rebuild of the whole screen |
| **`preset_on_change.dart` — a PRESET's on_change** (§266) | An engine separate from §232, writing into the global userVars |

---

## Dependencies

| Package | Purpose |
|---------|---------|
| `http` | subscription fetch + rule-set/update/WARP HTTP requests |
| `json5` | JSON5/JSONC config parsing |
| `file_picker` | Config import from filesystem |
| `path_provider` | Documents directory for persistent storage |
| `shared_preferences` | Theme mode, haptic toggle |
| `share_plus` | Config/log export via system share sheet |
| **libbox** (native) | The sing-box core — the [`Leadaxe/sing-box-lx`](https://github.com/Leadaxe/sing-box-lx) fork (`with_awg` + `with_xhttp`, §097/§104; §122 — no `with_clash_api`). The pin is `app/android/libbox.version` (the single source of truth; on a version bump check the file and `KERNEL.md`, not this line); the AAR is downloaded by `scripts/fetch-libbox.sh` from the fork's GH Releases (SHA256-verified) into a gitignored `libs/`. |

---

## Known limitations

### Config Editor — one-way pipeline (issue [#3](https://github.com/Leadaxe/LxBox/issues/3))

The source of truth for every settings screen (Subscriptions, Routing, DNS, VPN settings, App settings).

```
state ──buildConfig──▶ configRaw ──save──▶ libbox
```

The Config Editor (`ConfigScreen.saveConfigRaw` → [`HomeController.saveConfigRaw`](../app/lib/controllers/home_controller.dart)) writes the raw JSON.

- Manual edits to the JSON are invisible to the menu screens — the state knows nothing about them.
- Any change in the UI calls `buildConfig` over the state and overwrites the manual edits.
- The connection statistics do see the edits, because sing-box runs with that very config.

A full round trip would require a sing-box JSON → state parser covering everything.

---

## Feature Specs

They live in [`docs/spec/features/`](./spec/features/). Each feature is a `NNN name/spec.md` folder.

| # | Feature |
|---|---------|
| 003 | Home screen |
| 006 | Servers UI |
| 007 | Config editor |
| 008 | Ping and node management |
| 009 | UX and theme |
| 010 | Quick start and offline |
| 011 | Local ruleset cache |
| 012 | Native VPN service |
| 014 | DNS settings |
| 015 | Speed test |
| 016 | Statistics and connections |
| 017 | Custom nodes and node settings |
| 018 | Detour server management |
| 019 | WireGuard endpoint |
| 020 | Security and DPI bypass (TLS fragment) |
| 021 | CI/CD pipeline |
| 022 | App settings |
| 023 | Debug and logging |
| 024 | Load balance — *Released* (§208 round-robin balancer, v2.7.0) |
| 025 | WARP integration — *Released* (v2.3.0; the §130 MASQUE transport) |
| **026** | **Parser v2** (sealed NodeSpec, 3-layer pipeline) |
| **027** | **Subscription auto-update** (4 triggers, spam gates) |
| **028** | **AntiDPI: mixed-case SNI** |
| **029** | **Haptic feedback** |
| 030 | Custom routing rules (unified `CustomRule` model: inline + local-only SRS) |
| 031 | The Debug API (a localhost HTTP server for dev introspection) |
| 032 | Quick Connect (QS tile + home shortcut) |
| 033 | Preset bundles (selectable rules with a `preset_id`, expansion plus merge) |
| 034 | App icon |
| 035 | MCP server — *Draft* |
| 036 | Update check (GitHub Releases polling, sideload-flow) |
| 037 | Naive proxy support |
| 038 | Crash diagnostics (`getHistoricalProcessExitReasons`) |
| 040 | Backup & restore UI (4 toggleable categories) |
| 042 | Health watchdog (heartbeat metrics + auto-recovery) |
| 043 | AppLog per-source quotas + diagnostics platform (Debug API + AppLog + Crash diagnostics) |
| **044** | **Per-app traffic profiler** (recording per-app DNS/connections/routing chain — Live/Domains/IPs/Connections sub-tabs, connection-issue detection, Debug API + SSE) |
| 045 | TLS ECH (Encrypted Client Hello) — an anti-DPI extension that hides the SNI entirely — *Draft* |
| 046 | Tunnel apps split tunneling (a per-app include/exclude through VpnService.Builder) |
| 047 | The Public Intent API (Tasker / MacroDroid automation through Android broadcast intents) — *Draft* |
| 048 | The home node filters (a two-phase pool/match model — the foundation of Filter mode) |
| 070 | Sort options (the node sorting menu) |
| 071 | Manual node reordering (drag; §100 — manual in the carousel, with persistence) |
| 074 | Add server wizard |
| 076 | Settings & config lifecycle (lazy/eager persist, HomeReturnObserver, mtime-bootstrap) |
| **097** | **AWG2 (AmneziaWG 2.0) plus the move to the `sing-box-lx` core** (`with_awg` / `with_xhttp`) |
| 105 | The support message (the support and web URLs in a subscription's meta) |
| 117 | DNS rework |
| 118 | Subscription fetch identity (User-Agent / identity headers) |
| 120 | The template engine — typed vars plus `if` (the shared substitution core, §120) |
| 119 | VPN mode (vpn / vpn_proxy / proxy — §119, has_tun) |
| **121** | **libbox 1.14 adoption** (migrating the bindings to the 1.14 core) |
| **122** | **The CommandClient migration** (dropping the Clash HTTP API entirely for the libbox CommandClient) |
| 123 | The subscription model (three CC clients: status/screen/profiler; the §123/§164 power model) |
| 124 | Background mode — tunnel sleep (the tunnel's Doze behaviour) |
| **125** | **Configurable directions** (CRUD directions over directions[]; enabled_groups is DEPRECATED) |
| 126 | First-run wizard |
| **127** | **XHTTP full URL params** (native XHTTP: mode/x_padding_bytes/no_grpc_header) |
| **128** | **Idle-suspend** (`route.lx_idle_suspend`, the core's SPEC 020; default `30s`) |
| **129** | **File subscriptions** (url=file:<uuid>, an HttpCache snapshot, a transactional source switch) |
| **130** | **The MASQUE WARP transport** (the flagship of v2.9.0 — MasqueSpec, Cloudflare QUIC/CONNECT-IP) |
| **234** | **Server folders** (folders of manual servers: FolderMember plus a per-member toggle and tag_prefix) |
| 236 | Folder server testing (a headless probe of the folder's members) |
| **248** | **Detour directions** (directions as detour targets; §254 turns cycles into a fatal with the culprit named) |
| **279** | **Localization** (en plus ru: the dictionary, the template overlay and values-<lang>; §280 phases 0–7) |
| **283** | **Subscription node disable** (a per-node toggle in a subscription, keyed by the node's identity hash) |
| **393** | **Directions** (the Channel→Direction rename: arbitrary tags, no cap, include[]; the storage key channels→directions with a one-shot migration) plus **hop chains** (SPEC 110: a chain as a third source kind, `type: chain`, a layered probe) |
| 417 | Workspaces (named copies of the whole state — settings + subscription bodies + .srs; Load = auto-save current → copy → re-read in place → rebuild → VPN back up; Save as; the working paths never move) |

**Demoted (through §054) — now in `tasks/`:**

| Was | Now |
|-----|--------|
| ~~001~~ Mobile stack | [`tasks/055-mobile-stack-decision/`](./spec/tasks/055-mobile-stack-decision/spec.md) — historical architectural decision |
| ~~002~~ MVP scope | [`tasks/056-mvp-scope-historical/`](./spec/tasks/056-mvp-scope-historical/spec.md) — historical milestone |
| ~~004x~~ Subscription parser | [`tasks/057-subscription-parser-v1-superseded/`](./spec/tasks/057-subscription-parser-v1-superseded/spec.md) — superseded by §026 |
| ~~005x~~ Config generator | [`tasks/058-config-generator-wizard-v1-superseded/`](./spec/tasks/058-config-generator-wizard-v1-superseded/spec.md) — superseded by §026 |
| ~~013~~ Routing | [`tasks/059-routing-v1-superseded/`](./spec/tasks/059-routing-v1-superseded/spec.md) — superseded by §030 |
| ~~039~~ libbox 1.13 migration | [`tasks/060-libbox-1-13-migration/`](./spec/tasks/060-libbox-1-13-migration/spec.md) — one-shot migration (Done) |
| ~~041~~ DNS rules refactor | [`tasks/061-dns-rules-refactor/`](./spec/tasks/061-dns-rules-refactor/spec.md) — refactor, live spec — §014 |

The freed numbers (001, 002, 004, 005, 013, 039, 041) are **never reused**.

In addition there is a chronicle of individual work cycles (bugs, refactors) in `tasks/`.

---

## Reusable layers (extraction targets)

LxBox is a monolith, but architecturally it holds several self-contained layers that could be extracted.

### Layer 1 — Sing-box VPN engine (Kotlin + Dart channel)

**What:** a native wrapper over libbox plus a Dart MethodChannel client. No UI and no opinions about the config.

| Files | Lines |
|---|---|
| `app/android/.../vpn/{BoxApplication, BoxVpnService, BoxService, PlatformInterfaceWrapper, VpnPlugin, ConfigManager, ServiceNotification, VpnStatus, DefaultNetworkMonitor, DefaultNetworkListener, LocalResolver, BootReceiver, Extensions}.kt` | ~3000 |
| `app/lib/vpn/box_vpn_client.dart` | ~600 |
| `app/lib/models/{tunnel_status, background_mode, app_info}.dart` | ~150 |

**The public API surface:** `BoxVpnClient.I` (see the [Dart `BoxVpnClient` API surface](#dart-boxvpnclient-api-surface) section).

**The coupling with LxBox (to be broken before extraction):**
- **The channel names are hardcoded** — `com.leadaxe.lxbox/methods`, `com.leadaxe.lxbox/status_events`, `lxbox/coreLog`.
- **The SharedPreferences keys are hardcoded** — `boxvpn_boot.{auto_start_vpn, keep_vpn_on_exit, background_mode, core_logs_enabled, …}`.
- **The notification icon and channel name** — `ServiceNotification.kt` references `R.drawable.ic_notification`.
- **The manifest declarations** — the package must **document** the permissions it requires.
- **`WifiNetworkObserver` depends on the Dart-side `wifi_history` MethodChannel** — that is an LxBox feature (§051).

**The quality gates have been passed:** the §049 audit (atomic CAS, the F1 split, the F2–F26 fixes) and the §050 closeout.

**iOS:** absent. A cross-platform package would be a separate task (a Network Extension).

### Layer 2 — CommandClient channel

**What:** the libbox `CommandClient` control channel (§122) — the native `BoxCommandClient.kt` plus the Dart `CcChannel`.

| Files | Lines |
|---|---|
| `app/android/.../BoxCommandClient.kt` | ~native |
| `app/lib/vpn/cc_channel.dart` | ~700 |

**The coupling with LxBox:** **medium**. The Dart side is generic (push streams plus unary RPC over an EventChannel).

**The API surface:** see the [CommandClient (libbox)](#commandclient-libbox) section — status/outbounds/groups/connections.

**Readiness for extraction:** **medium**. It travels with Layer 1 (a shared native component).

### Layer 3 — Sing-box subscription parser / builder

**What:** the sealed `NodeSpec` (11 protocol variants, including Masque §130) plus the URI/JSON/INI parsers and the builder.

| Files | Lines |
|---|---|
| `app/lib/models/{node_spec, node_spec_emit, tls_spec, transport_spec, ...}.dart` | ~2000 |
| `app/lib/services/parser/*.dart` | ~1500 |
| `app/lib/services/builder/*.dart` | ~2000 |

**The coupling with LxBox:** **high**. The builder depends on the shape of `wizard_template.json` (our own format).

**Readiness for extraction:** **low**. It would need a serious refactor to separate the parser from the builder.

### Layer 4 — TrafficProfiler

**What:** a per-app and system-wide observer of DNS/TCP/UDP events.

**The coupling:** **high** — see the coupling notes in [section 6.5](#65-traffic-profiler-044--048).

**Readiness:** low. It only makes sense once the LxBox VPN engine has been extracted.

### The extraction roadmap (should we decide to go)

1. **Phase 1** — the sing-box VPN engine plus the CommandClient channel (Layers 1 and 2) into `packages/flutter_singbox/`.
2. **Phase 2** — extract a reusable `NodeSpec` parser/emit from Layer 3 (without the builder pipeline).
3. **Phase 3** — the publication decision: libbox's viral GPLv3 is the main blocker.
4. **Phase 4** — iOS support (if it is wanted).

**The current status:** nothing has been extracted. The VPN engine (Layer 1) and the CommandClient channel (Layer 2) are the closest candidates.
