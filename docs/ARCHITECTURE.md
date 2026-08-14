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
> Flutter has no clean runtime GPU detection. Details: [§131](spec/tasks/131-impeller-adreno-crash.md).

### Why 24 is the minSdk

- **24 is the absolute floor**: Flutter 3.41.x supports API 24 at the lowest (`FlutterExtension.minSdkVersion = 24`), and libbox.aar is built with `minSdkVersion=23`. Below 24 the app cannot be built at all.
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
reduces to calling the facade. The reference shapes: `ChannelMutations` (an atomic
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
| `group_templates` + `default_channels` | §125/§267 — the **SEED** for `channels[]` (on the first launch). The builder reads `channels[]` from storage. |
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
  └── channels[] (storage) ──► _buildChannelGroups(per-channel node_filter)  ──► config.outbounds
      (§125/§267: the channels come from channels[], seeded from group_templates plus default_channels; with the block/direct options)
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
channel.dart                 # §125 Channel — the configurable channels (vpn-1 cannot be deleted)
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
                                #   §096), plus the §083 per-channel memory
home/node_filter.dart           # a pure NodeFilter helper (the match predicates plus the inverts) plus extractEmojis
home/node_actions.dart          # the node's long-press actions; §099 — the copy-JSON variants (node /
                                #   server+detours(N)) moved into a dropdown inside View JSON
home/home_menus.dart            # showSortOptionsMenu (+ Custom/manual §100) + showPingSettings
home/home_dialogs.dart          # the top-level dialog and snackbar functions (update/permission/battery/revoked)
home/restore_backup.dart        # empty-state quick-restore flow (SAF)
home/subscription_lookup.dart   # the §091 prefix filter: a node belongs to a subscription ⇔ its tag
                                #   starts with '$prefix '; it replaced the §077 reverse map over node lists
home/channel_filters.dart       # §083 an immutable snapshot of a channel's match filters (plus the §103 variants)
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
#   app_picker · auto_group_edit (§322, an auto-select node) · channel_edit (§125) ·
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
settings_storage/channels.dart      #   §125 the channels (Channel CRUD plus the vpn-1 seed)
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
                             #     /files /diag /backup /wifi_history /help /ping /warp /channels (§275)
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
├── group_templates         # §267 — the magic_nodes registry plus the channel/auto templates (the SEED for channels)
├── default_channels[]      # §267 — the channel seed (vpn-1..2); the builder reads channels[] from storage
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
│                           #   route_final / channels[] (§125, replaces enabled_groups) /
│                           #   excluded_nodes (§048 sandbox) / last_global_update /
│                           #   presets_migrated / channels_migrated
├── singbox_config.json     # ConfigManager (Kotlin) — the final sing-box JSON
├── http_cache/             # HttpCache — the raw body plus headers of the subscriptions
│   └── <sha1(url)>.{body,headers}
├── rule_sets/              # §011 — the cache of binary .srs files
│   └── <tag>.srs
├── applog.txt              # §038/§043 — JSON lines, a 200-line / 64 KB ring
└── corelog.txt             # §043 — JSON lines, a 200-line / 64 KB ring

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
  - `masque`: `v4_cidr` · **`h3_v4_cidr`** · `ports_h3` · `ports_h2` · `sni_pool`.

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
                              the statics: node/dns --detour--> node|channel; the group membership
delayByChannel (measurements) ──┐
groups stream (the selection) ──┴─► HomeController._recomputeDependencyHealth()
                              computeSick: a dead node (every measurement is ERR) → a BFS upward
                              along the reverse edges (a selector's choice infects the channel;
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

Четыре независимых `CommandClient` — развязка частоты обновления от состава данных и lifecycle:

| Клиент | Команды | Lifecycle |
|---|---|---|
| `statusClient` | `CommandStatus` (+ `setStatusInterval`) | always-on пока туннель жив; в фоне (`onAppPaused`) гасится (0 тиков/0 drain); §164 адаптивная частота NORMAL 0.5с (главный экран) / FAST 0.1с (Stats) — пересоздаётся с новым интервалом |
| `screenClient` | `CommandOutbounds` + `CommandGroup` + `CommandConnections` | поднимается по `connectScreen()` (refs>0), гасится в фоне |
| `profilerClient` | `CommandConnections` + `subscribeDNSQueries` (SPEC 018, §180) | поднимается по `connectProfiler()` для recording; §164 **не паузится** в фоне → recording живёт при свёрнутом app |
| `pingClient` | голый `PingHandler`, без подписок — только unary RPC | §175/§209 — поднимается лениво, **lifecycle-независим** (`pauseClients` его НЕ трогает). Носитель ВСЕХ unary-снапшотов/действий (`urlTestOutbound` + `getPool`/`getGroups`/`getRules` + `selectOutbound`/`close*`). Дисконнект только в `cancelPing`/`resyncForReopen`/`shutdownAll`. Подписок нет → 0 нагрузки в покое. Следствие: снапшоты работают и при свёрнутом приложении |

Подписка в gomobile-фасаде = `CommandClientOptions.addCommand(int)` + колбэки `CommandClientHandler.write*` (прямых `subscribe*`-методов в AAR нет).

### Dart-слой (`CcChannel`)

Push-стримы поверх EventChannel `lxbox/cc/*` (`status` · `outbounds` · `groups` · `connections` · `dns`). **§122 sink-leak-guard:** каждый EventChannel держит РОВНО ОДИН native sink; `CcChannel` делает один внутренний `listen` и фан-аутит через `StreamController.broadcast` (native sink ставится при первом Dart-подписчике, снимается при уходе последнего) — иначе cancel одного потребителя (dispose Stats) обнулял бы sink главного экрана → watchdog видел бы тишину → ложный dead-tunnel.

| Стрим / метод | Тип | Назначение |
|---|---|---|
| `status` | push `Stream<CcStatus>` | up/down + traffic snapshot; питает heartbeat-watchdog |
| `outbounds` | push `Stream<List<CcOutbound>>` | список outbound'ов |
| `groups` | push `Stream<List<CcGroup>>` | selector/urltest группы + selected/active |
| `connections` | push `Stream<List<CcConnection>>` | active TCP/UDP + bytes + packageName/processPath. **Pull нет** (см. §193 ниже) — ядро шлёт полный список ОДИН раз (reset-снапшот на подписку), дальше только дельты |
| `dnsQueries` | push `Stream<List<CcDnsQuery>>` | §180 (SPEC 018) — DNS-запросы из ядра (domain/queryType/rcode/answers/cnameChain + dnsServer/outbound); `subscribeDNSQueries` на `profilerClient`; питает профайлер (`dnsResolve`/`dnsFail`) |
| `getGroups()` | unary-pull `List<CcGroup>?` | детерминированный снапшот групп (lifeline на дыру стартового push'а; `null` = клиент недоступен, не трогать state) |
| `getRules()` | unary-pull `List<CcRule>` | снапшот route+DNS правил (диагностика) |
| `getPool(tag)` | unary-pull `List<CcPoolSlot>?` | §208/§209 — снапшот пула round_robin-группы (`slot/tag/delay`). `null` = клиент недоступен, `[]` = пул пуст (не round_robin). Питает UI «View pool» + Debug `/pool` |
| `urlTestOutbound(tag)` | unary-RPC `CcDelayResult` | per-node delay. **Инвариант:** `error` — единственный признак провала; `delay==0 && error==''` = успех 0мс |
| `selectOutbound(group, tag)` | unary-RPC | selector switch |
| `closeConnection(id)` / `closeConnections()` | unary-RPC | закрыть одно/все соединения |

**§209 — все unary-методы выше идут через `pingClient`** (lifecycle-независим), не через `anyClient()` (status/screen/profiler паркуются в фоне §164). Поэтому снапшоты (`getPool`/`getGroups`/`getRules`) и действия работают и при свёрнутом приложении. Контракт ошибки: при недоступном клиенте List-снапшот возвращает `null` (не пустой список) — «нет клиента» отличимо от «нет данных»; действия возвращают честный `false`.

Lifecycle-сигналы (`connectScreen`/`disconnectScreen`, `connectProfiler`/`disconnectProfiler`, `pauseClients`/`resumeClients`, `setStatusFast`) дёргают соответствующие native-клиенты.

### Wiring

`HomeController` на `connected` event подписывается на `status` + `groups`-стримы и поднимает `screenClient` (`connectScreen()`), затем делает unary `getGroups()`-pull (с короткими ретраями пока сервис не STARTED) для детерминированного наполнения дерева групп — на случай если стартовый groups-push потерялся в гонке `waitForStarted`. На disconnect — отписка + `disconnectScreen()` + сброс кэшей. Per-node delay и selector switch идут через `urlTestOutbound` / `selectOutbound`.

### Gotchas

- **Empty groups-push поверх живого** — ядро может прислать пустой groups-push поверх непустого state; guard в `_onCcGroups` игнорит пустой push если `ccGroups` непуст. Детерминированный источник истины — `getGroups`-pull.
- **No external subscribers** — командный server слушает localhost; сторонние Clash-дашборды (yacd / clash-meta) больше не поддерживаются в принципе (Clash API нет).
- **§193 — connections single-shot, нет pull (асимметрия с groups).** `connections`-под-поток `screenClient`'а принципиально хрупче `groups`. Ядро (sing-box-lx) отдаёт полный список соединений **только один раз** — reset-снапшот при подписке (`SubscribeConnections`); дальше идут только дельты. У `groups` есть unary-pull `getGroups()` плюс повторные снапшоты на urlTest, у `connections` pull'а **нет** (`getConnections` в libbox отсутствует — javap rc.10 подтвердил). Поэтому при **повторном** открытии Stats (`screenClient` не пересоздаётся, refcount>0) нового reset-снапшота не приходит — UI остался бы пустым. Фикс §193: native-сторона при появлении нового connections-sink'а пере-эмитит накопленный `screenAccumulator` — [`BoxCommandClient.reEmitScreenConnections()`](../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxCommandClient.kt) зовётся из `VpnPlugin.onListen` connections-канала (идемпотентно: пустой/null acc → пустой list). Плюс `resyncForReopen` (§185, рвущий `screenClient`/`pingClient`) гейтнут до cold-start: флаг `_didColdStartResync` в [`home_controller.dart`](../app/lib/controllers/home_controller.dart) выполняет полный resync ровно один раз за жизнь движка, чтобы не рвать connections на каждом реконнекте. **Долг ядра:** добавить unary `GetConnections` симметрично `GetGroups`.
- **§194 — три счётчика соединений считают РАЗНОЕ.** Не путать:
  - **Главный экран** ([`traffic_bar.dart`](../app/lib/screens/home/widgets/traffic_bar.dart)) — два раздельных чипа: `connectionsIn` (🔗 = `trafficManager.ConnectionsLen()` ядра = соединения **приложений**, ТЕ ЖЕ что в `CommandConnections`-списке = на Stats) и `connectionsOut` (🗄 = `connectionManager.Count()` = **физические** соединения наружу к серверам). Раньше шапка складывала In+Out в одно число — путало, т.к. не сходилось со списком на Stats.
  - **Stats** — активные из списка (`closedAt==0`) ≈ `connectionsIn`.
  - **Conns** — живые + closed-история, показывает «N active / M total».

---

## Локализация (l10n, §279 / §285)

en (базовый) + ru; новый язык = один natural-key словарь + один
template-overlay + один `values-<lang>/` без структурных изменений.
Runtime-переключение без рестарта приложения, включая нативные поверхности при
живом VPN-сервисе. С §285 UI-строки локализуются через **natural keys**
(английский текст call-site'а И ЕСТЬ ключ; ARB/gen_l10n снесены). Полная
архитектура — [спека §279](spec/features/279%20localization/spec.md) +
[ревизия getLocalText](spec/features/279%20localization/getlocaltext.md);
translator-guide — [`l10n.md`](l10n.md).

| Компонент | Роль |
|---|---|
| `lib/services/l10n/get_local_text.dart` | `GetLocalText` — natural-key движок: `.s("en text", args)` / `.plural("%d en", n)`, printf `%s/%d/%1$s/%%`, форма-индекс, fallback = сам ключ; `GetLocalText.en` — пиненный английский рендерер |
| `lib/services/l10n/plural_resolver.dart` | `PluralResolver` + `En`/`RuPluralResolver` (CLDR формы: ru one/few/many/other) — набор форм диктует shape plural-объекта в словаре |
| `assets/l10n/ru/ui.json` | Natural-key словарь: `englishKey → { value: String\|pluralObj, special: {"N": {value}} }`. `en`-файла нет by design — английский базовый, в коде (fallback на сам ключ) |
| `lib/services/l10n/locale_controller.dart` | `LocaleController` — **единственный владелец** смены локали + глобальный `getLocalText` getter (dict-reload в пайплайне); `didChangeLocales` ловит смену системного языка при `setting=='system'` |
| `lib/services/l10n/template_overlay.dart` | Pre-parse оверлей display-текста `wizard_template.json` (адреса по machine-id, см. [TEMPLATE.md](TEMPLATE.md#localizing-the-display-text--the-l10n-overlay-279)) |
| `lib/services/l10n/template_aware_state.dart` | Mixin: refetch template-derived состояния в `didChangeDependencies` по `Localizations.localeOf` (initState переживает rebuild — снапшот локали там запрещён checker'ом) |
| `lib/services/l10n/app_language_reconcile.dart` | Трёхсторонний reconciliation `LocaleManager`↔storage на старте (Android 13+, зеркало `last_pushed_locale`) |
| `lib/models/ui_msg.dart` | sealed `UiMsg` — хранимые ошибки/статусы как типизированные объекты; `render()` через ambient `getLocalText` в момент показа, `renderEn()` → `GetLocalText.en` — путь UiMsg→String на machine-поверхностях (automation/AppLog/notification) |
| `app/tool/l10n/` | 4 CI-checker'а (`--strict` на каждом PR): ui_check (natural-key словарь↔код) / template_check / hardcoded_check (+ rendering-locality) / kotlin_check |
| `android … L10n.kt` | Нативный резолвер: читает `boxvpn_boot.app_language`, `createConfigurationContext` **в момент рендера, без кэша** — работает в сервис-процессе при мёртвом Flutter |

`MaterialApp.localizationsDelegates` несёт только Flutter-встроенные делегаты
(Global Material/Widgets/Cupertino chrome); строки приложения идут через
`getLocalText`, не через `Localizations`-делегат.

**Пайплайн смены языка** (любой путь записи `app_language` — picker, Debug API
side-effect hook, restore, смена системного языка — сходится в
`LocaleController.set()` / `_applyLocale()`):

```
LocaleController.set(v)
  ├─ SettingsStorage.setAppLanguage(v)      # JSON-var (истина) + MethodChannel-зеркало
  │     └─ native: BootReceiver pref → resubmit notification-канала →
  │        ServiceNotification.relabel → updateShortcuts (+onResume retry) →
  │        tile.requestListeningState → Libbox.setLocale → LocaleManager (33+)
  └─ _applyLocale(effective)
        ├─ _text = GetLocalText(dict<tag>, resolver<tag>)  # natural-key словарь новой локали
        ├─ await TemplateLoader.reload(tag)  # ПРОГРЕВ ДО notify (кэш ключуется тегом локали)
        ├─ RuleNameResolver.relocalize(...)  # display-зеркала билдера без ребилда конфига
        ├─ LazyPersistFlush.flushAll()
        └─ notifyListeners()                 # merged Listenable с themeNotifier → rebuild MaterialApp
```

**Границы** (английские навсегда): логи, Debug API-ответы, automation/Tasker-payload'ы,
`emitWarnings`, wire-значения и теги, имена файлов, user data, payload
OS/ядра (passthrough `RawMsg.detail`). Единицы (`B/KB/MB`, `Mbps`, `ms`) и
суффиксы длительности — латиница в обеих локалях.

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
  │   │                 (§188 — «Allow VPN bypass» и «Keep VPN on exit» переехали в Mode-вкладку)
  │   │       • Core   — sing-box engine vars (`chapter: core`, mtu / log_level / dns_final / …)
  │   ├─ App Settings → AppSettingsScreen — 2 tabs (§052 Phase 2):
  │   │       • General      — theme, autostart, haptic
  │   │       • Diagnostics  — system permissions block + verbose / share / wipe + Quit&reopen
  │   │       (Background tab удалён; `keep_on_exit` + `background_mode` переехали в VPN Settings → System,
  │   │        permissions block — в Diagnostics)
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
          (§099 — copy-JSON варианты в dropdown внутри View JSON:
           Copy node JSON / Copy server JSON / Copy server + detours(N))
```

---

## Key Decisions

| Decision | Reason |
|----------|--------|
| Native VPN service (no plugin) | flutter_singbox_vpn was unmaintained (0 stars), config in SharedPreferences |
| File-based config storage | Large JSON configs don't belong in SharedPreferences |
| serviceScope vs GlobalScope | Structured concurrency — coroutines die with service |
| libbox CommandClient for management (§122) | Server-stream push вместо Timer-polling; Clash HTTP API выпилен (на 1.14 без `with_clash_api` он fatal). Нет localhost HTTP-порта → нет surface для port-scan |
| 10 concurrent mass ping (`_pingConcurrency`) | Sequential was too slow for 50+ nodes; cap балансирует latency vs sing-box load |
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
| **Shared `asBroadcastStream` for status events** (v1.4.0) | `BoxVpnClient.onStatusChanged` cached as `late final` — один native `onListen`, `statusSink` стабилен. Раньше каждый вызов getter'а перезаписывал sink и ломал основной listener после первого reconnect'а. См. tasks/001. |
| **Blocking `stopVPN` через Completer** (v1.4.0) | Method channel ждёт `setStatus(Stopped)` на native (5с timeout) — caller получает control только после реального завершения. Убирает race в `onStartCommand` guard в reconnect'е. См. tasks/002. |
| **Intent-based sticky reset** (v1.4.0) | `configChangedNeedRestart=false` в `_stopInternal`/`_startInternal` по факту применённого намерения, не только по transition event'у. Robust к Doze/OOM потерям broadcast'ов. |
| **`TunnelStatus.unknown`** (v1.4.0) | Default для неизвестного raw вместо `disconnected` — убирает ложные срабатывания `firstWhere` predicate'ов на мусорных events. UI маппит в Disconnected label. |
| **`ConfigCache` в HomeState** (v1.4.0; superseded §091 → `ParsedConfig`) | Outbound JSON парсился один раз при `saveParsedConfig`, не в itemBuilder'е. §091 заменил пару `protoByTag`/`detourTags` полноценной моделью `ConfigNode` (см. строку §091 ниже). |
| **`kDetourTagPrefix` single source of truth** (v1.4.0) | Константа `⚙ ` в `lib/config/consts.dart` — used by node_settings UI, builder, home filter, node_filter screen. Раньше литералы дублировались. |
| **Two persist patterns: Lazy vs Eager** (v1.9.0, §076) | Editing screens с toggle-flood UX (`tun_apps_tab`, `routing_screen`, `dns_settings_screen`, `settings_screen` Core) используют **lazy** — mutations in-memory + `_markDirty` (sync `configDirty=true`), flush on `dispose()` + `paused`, rebuild lazy на возврат к home. Discrete-event screens (`subscriptions`, `app_settings`, `custom_rule_edit`, `node_filter`) — **eager** immediate-write + snackbar. 1 settings + 1 config write per editing session вместо до 10 (per-toggle eager). |
| **Global `HomeReturnObserver`** (v1.9.0, §076) | Universal `NavigatorObserver` в `MaterialApp.navigatorObservers`. Срабатывает при `previousRoute.isFirst == true` (home стал top). Покрывает все navigation пути — drawer, long-press, system back, swipe, programmatic pop, cross-nav. Раньше rebuild trigger был в `_pushRoute.then()` callback'е — терялся при опен screen через non-drawer пути. |
| **mtime-based bootstrap** (v1.9.0, §076; §113) | `ConfigDirtyCheck.isDirty()` сравнивает `lxbox_settings.json.mtime > singbox_config.json.mtime` (**секундная резолюция**, §113) на launch. Восстанавливает `configDirty` после kill mid-edit без persist'а флага. `subController.init` set'ит флаг, `home._initSubsAndAutoUpdate` триггерит тихий bootstrap rebuild. **§113**: после §107 порядок дисковых записей инвертирован (конфиг пишется на возврате к home, настройки — позже на `dispose`), из-за чего `settings>config` стало нормой → ложный «config changed» после kill. Фикс: (а) `configDirty` владеется `SettingsStorage` — config-значимые сейверы (typed + config-var allowlist, **не** `saveServerLists`) сами поднимают флаг (`SubscriptionController.configDirty` — делегат); (б) `_save()` при снятом флаге выравнивает mtime конфига к mtime настроек (`ConfigDirtyCheck.touchConfig`). |
| **`markConfigChangedNeedRestart` external mark** (v1.9.0, §076) | `HomeController` method для настроек применяемых вне config pipeline. Native VPN-тогглы (allow_bypass / keep_on_exit / background_mode) — с §189 пишутся write-through через `SettingsStorage.setNativeBool`/`setNativeBackgroundMode` (JSON-истина + зеркало в native) — вызывают этот метод → home banner вместо локального snackbar'а. Gated на `tunnelUp`. |
| **Cohesion over line-count + `part`/`mixin` декомпозиция** (§089) | Монстры (home_screen 2370, home_controller 1089, …) раздроблены не по числу строк, а по ответственности: тонкий экран + `<screen>/widgets/` + presenter/VM; контроллер + `part`-mixin'ы (та же библиотека → library-private доступ сохранён, поведение bit-identical). ~600 строк легитимны для cohesive-файла; крупные исключения задокументированы (см. [Обзор](#принцип-cohesion-over-line-count-089)). |
| **`ConfigNode` структурная мета вместо reverse-parse тега** (§091, реализовано) | `config-tag == нода в Clash`; протокол/detour достаются из конфига по тегу без reverse-map. Один `ParsedConfig` (parsed раз на `configRaw`, поле `HomeState.configModel`) заменил `ConfigCache.protoByTag/detourTags` + `ConfigIntrospection` + reverse-map `subscriptionsOfTag` (теперь prefix-фильтр, `home/subscription_lookup.dart`). Класс багов §077/§079/§080 устранён структурно. §102/§103 — eager `transportLabel`/`securityLabel` для subtitle и variant-фильтра. +14 тестов. |
| **`VarValuesModel` — per-key реактивная модель настроек** (§232) | Однонаправленный поток а-ля Vue («props down, events up»): значения template-vars экрана живут в `VarValuesModel` (`Map<String, ValueNotifier>` + dirty-set), каждое поле `TemplateVarListView` подписано `ValueListenableBuilder`'ом на СВОЙ ключ — программные изменения (`on_change`: галка ipv6 → стратегии) видны в UI мгновенно и точечно. Заменила ДВЕ рассинхронизирующиеся копии (`_varValues` в State + приватная `_values` виджета), из-за которых on_change-записи терялись. `model.set` — только память; storage пишет ЕДИНСТВЕННОЕ место — `_persist` на dispose/paused по `dirtyKeys` (уточнение lazy-паттерна §076: до выхода изменения нигде, кроме модели). Кросс-экранная доставка (dns_strategy на DNS Settings) — через cache при следующем `_load()` того экрана; app-global модель отвергнута (экраны не co-mounted). §161-edge: пустое required — `set(markDirty:false)`+`unstage`, до storage не доезжает. |
| **`preset_on_change.dart` — on_change ПРЕСЕТА** (§266) | Отдельный от §232 движок: источник — не значение var, а **состояние пресета** (псевдо-vars `@rule_enable`=`cr.enabled`, `@dns_enable`=`presetDnsEnableVar`); приёмник — **глобальный `userVars`** (`SettingsStorage.setVar`, сразу на диск), не in-memory модель. `applyPresetOnChange(preset, cr)` собирает on_change со всех vars пресета, резолвит `#if`-цель в namespace `{...userVars, rule_enable, dns_enable}` через `evalIfScalar`, пишет каждую цель. Применение: FakeIP гасит `resolve_enabled` пока активен (`@rule_enable AND @dns_enable → false`). Зовётся из **5 точек** смены состояния (routing-свич/создание, редактор `onBoolVarToggle`, DNS Settings `_togglePresetDnsEnable`) — пропуск любой = цель не пересчитается на этом пути. Псевдо-var **обязана** нести `default_value`+`required:false`, иначе `expandPreset` выходит рано и DNS-блок пресета молча не эмитится (`29fe61c`). См. TEMPLATE.md § «on_change пресета». |

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
| **libbox** (native) | sing-box core — fork [`Leadaxe/sing-box-lx`](https://github.com/Leadaxe/sing-box-lx) (`with_awg` + `with_xhttp`, §097/§104; §122 — без `with_clash_api`). Пин — `app/android/libbox.version` (single source of truth; при бампе версии сверяться с файлом и `KERNEL.md`, не с этой строкой); AAR скачивает `scripts/fetch-libbox.sh` из GH Releases форка (SHA256-verify) в gitignored `libs/` — и локально (`build-local-apk.sh`), и в CI (`ci.yml` → «Fetch sing-box-lx core»). Maven-строка стокового libbox удалена из `build.gradle.kts` (исторически: JitPack `com.github.singbox-android:libbox:1.13.11`, миграция из `io.github.sagernet:libbox` — spec 039) |

---

## Known limitations

### Config Editor — one-way pipeline (issue [#3](https://github.com/Leadaxe/LxBox/issues/3))

Source of truth для всех экранов настроек (Subscriptions, Routing, DNS, VPN settings, App settings) — **structured app state** (`SubscriptionEntry[]`, `NodeSpec`, `CustomRule[]`, `SettingsStorage`). [`buildConfig`](../app/lib/services/builder/build_config.dart) собирает sing-box JSON из этого состояния, поток односторонний:

```
state ──buildConfig──▶ configRaw ──save──▶ libbox
```

Config Editor (`ConfigScreen.saveConfigRaw` → [`HomeController.saveConfigRaw`](../app/lib/controllers/home_controller.dart)) сохраняет введённый JSON в sing-box и в `state.configRaw`, но **не парсит его обратно в models**. Поэтому:

- Ручные правки в JSON не видны в menu screens — state о них не знает.
- Любое изменение в UI вызывает `buildConfig` поверх state и затирает manual edits.
- Connection statistics видят правки, потому что sing-box рантаймится с тем JSON'ом, что в editor'е сохранён.

Полноценный round-trip требует sing-box JSON → state parser'а покрывающего все формы outbound'ов / routing rules / DNS servers / inbound configs. Это эффективно вторая product surface, в near-term roadmap не входит. Mitigations для пользователей: выражать кастомизацию через **Routing → Custom rules** (state-bound, выживают пересборку); хранить «чистый» JSON-конфиг отдельно и переподавать его через editor после auto-update подписок.

---

## Feature Specs

Живут в [`docs/spec/features/`](./spec/features/). Каждая фича — папка `NNN name/spec.md`. Только **живые** продуктовые / архитектурные концепции; исторические / superseded / one-shot миграции — в [`docs/spec/tasks/`](./spec/tasks/) (см. [§054 spec reorg](./spec/tasks/054-spec-reorg-features-vs-tasks.md)).

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
| 025 | WARP integration — *Released* (v2.3.0; §130 MASQUE-транспорт) |
| **026** | **Parser v2** (sealed NodeSpec, 3-layer pipeline) |
| **027** | **Subscription auto-update** (4 triggers, spam gates) |
| **028** | **AntiDPI: mixed-case SNI** |
| **029** | **Haptic feedback** |
| 030 | Custom routing rules (unified `CustomRule` model: inline + local-only SRS) |
| 031 | Debug API (localhost HTTP server для dev introspection) |
| 032 | Quick Connect (QS tile + home shortcut) |
| 033 | Preset bundles (selectable rules с `preset_id`, expansion + merge) |
| 034 | App icon |
| 035 | MCP server — *Draft* |
| 036 | Update check (GitHub Releases polling, sideload-flow) |
| 037 | Naive proxy support |
| 038 | Crash diagnostics (`getHistoricalProcessExitReasons`) |
| 040 | Backup & restore UI (4 toggleable categories) |
| 042 | Health watchdog (heartbeat metrics + auto-recovery) |
| 043 | AppLog per-source quotas + diagnostics platform (Debug API + AppLog + Crash diagnostics) |
| **044** | **Per-app traffic profiler** (recording per-app DNS/connections/routing chain — Live/Domains/IPs/Connections sub-tabs, connection-issue detection, Debug API + SSE) |
| 045 | TLS ECH (Encrypted Client Hello) — anti-DPI extension прячущий SNI целиком — *Draft* |
| 046 | Tunnel apps split-tunneling (per-app include/exclude через VpnService.Builder) |
| 047 | Public Intent API (Tasker / Macrodroid automation через Android broadcast intents) — *Draft* |
| 048 | Home node filters (двухфазная pool/match модель — фундамент Filter mode §095/§096/§103) |
| 070 | Sort options (меню сортировки нод) |
| 071 | Manual node reorder (drag; §100 — manual в карусели + персист) |
| 074 | Add server wizard |
| 076 | Settings & config lifecycle (lazy/eager persist, HomeReturnObserver, mtime-bootstrap) |
| **097** | **AWG2 (AmneziaWG 2.0) + смена ядра на `sing-box-lx`** (`with_awg`/`with_xhttp`: AWG/AWG2 end-to-end, нативный XHTTP, MTU-кламп 1280; §104 — fork-ядро во всех сборках через `fetch-libbox.sh`) |
| 105 | Support message (support/web URLs в meta подписки) |
| 117 | DNS rework |
| 118 | Subscription fetch identity (User-Agent / identity headers) |
| 120 | Template engine — typed vars + `if` (общее ядро подстановки, §120) |
| 119 | VPN mode (vpn / vpn_proxy / proxy — §119, has_tun) |
| **121** | **libbox 1.14 adoption** (миграция обвязки на ядро 1.14) |
| **122** | **CommandClient migration** (полный отказ от Clash HTTP API → libbox CommandClient) |
| 123 | Subscription model (три CC-клиента: status/screen/profiler; §123/§164 энергомодель; notification text) |
| 124 | Background mode — tunnel sleep (Doze-поведение туннеля) |
| **125** | **Configurable channels** (CRUD-каналы поверх channels[]; enabled_groups DEPRECATED) |
| 126 | First-run wizard |
| **127** | **XHTTP full URL params** (нативный XHTTP: mode/x_padding_bytes/no_grpc_header) |
| **128** | **Idle-suspend** (`route.lx_idle_suspend`, ядро SPEC 020; default `30s`) |
| **129** | **File subscription** (url=file:<uuid>, HttpCache-снапшот, транзакционная смена online↔file) |
| **130** | **MASQUE WARP transport** (флагман v2.9.0 — MasqueSpec, Cloudflare QUIC/CONNECT-IP; services/warp/) |
| **234** | **Server folders** (папки ручных серверов: FolderMember + per-member toggle + tag_prefix/detour-политика) |
| 236 | Folder server testing (headless probe членов папки) |
| **248** | **Detour channels** (каналы как detour-цели; §254 циклы → fatal с виновниками) |
| **279** | **Localization** (en+ru: ARB + template-overlay + values-<lang>; §280 фазы 0-7) |
| **283** | **Subscription node disable** (per-node toggle в подписке: identity-хеш сути узла + TTL-GC отметок) |

**Демотированные (через §054) — теперь в `tasks/`:**

| Был | Теперь |
|-----|--------|
| ~~001~~ Mobile stack | [`tasks/055-mobile-stack-decision/`](./spec/tasks/055-mobile-stack-decision/spec.md) — historical architectural decision |
| ~~002~~ MVP scope | [`tasks/056-mvp-scope-historical/`](./spec/tasks/056-mvp-scope-historical/spec.md) — historical milestone |
| ~~004x~~ Subscription parser | [`tasks/057-subscription-parser-v1-superseded/`](./spec/tasks/057-subscription-parser-v1-superseded/spec.md) — superseded by §026 |
| ~~005x~~ Config generator | [`tasks/058-config-generator-wizard-v1-superseded/`](./spec/tasks/058-config-generator-wizard-v1-superseded/spec.md) — superseded by §026 |
| ~~013~~ Routing | [`tasks/059-routing-v1-superseded/`](./spec/tasks/059-routing-v1-superseded/spec.md) — superseded by §030 |
| ~~039~~ libbox 1.13 migration | [`tasks/060-libbox-1-13-migration/`](./spec/tasks/060-libbox-1-13-migration/spec.md) — one-shot migration (Done) |
| ~~041~~ DNS rules refactor | [`tasks/061-dns-rules-refactor/`](./spec/tasks/061-dns-rules-refactor/spec.md) — refactor, live spec — §014 |

Освобождённые номера (001, 002, 004, 005, 013, 039, 041) **не переиспользуются** — archive-ссылки сохраняются.

Дополнительно — летопись отдельных рабочих циклов (баги, рефакторинги): [`docs/spec/tasks/`](./spec/tasks/). Процессы (например, ночная работа): [`docs/spec/processes/`](./spec/processes/).

---

## Reusable layers (extraction targets)

LxBox monolith — но архитектурно есть несколько self-contained слоёв, которые **в принципе** можно вынести в отдельные packages (Flutter pub.dev) или хотя бы в `packages/` подпапку monorepo. Этот раздел — чек-лист для будущей extraction'а: что reusable, что coupled с LxBox, что надо параметризовать перед публикацией.

### Layer 1 — Sing-box VPN engine (Kotlin + Dart channel)

**Что:** Native обёртка над libbox + Dart MethodChannel client. Без UI, без opinion'ов о config-формате.

| Файлы | Lines |
|---|---|
| `app/android/.../vpn/{BoxApplication, BoxVpnService, BoxService, PlatformInterfaceWrapper, VpnPlugin, ConfigManager, ServiceNotification, VpnStatus, DefaultNetworkMonitor, DefaultNetworkListener, LocalResolver, BootReceiver, Extensions}.kt` | ~3000 |
| `app/lib/vpn/box_vpn_client.dart` | ~600 |
| `app/lib/models/{tunnel_status, background_mode, app_info}.dart` | ~150 |

**Public API surface:** `BoxVpnClient.I` (см. раздел [Dart `BoxVpnClient` API surface](#dart-boxvpnclient-api-surface)) + EventChannel'ы status/coreLog.

**Coupling с LxBox (надо разорвать перед extraction):**
- **Channel names hardcoded** — `com.leadaxe.lxbox/methods`, `com.leadaxe.lxbox/status_events`, `lxbox/coreLog`. Параметризовать через plugin config.
- **SharedPreferences keys hardcoded** — `boxvpn_boot.{auto_start_vpn, keep_vpn_on_exit, background_mode, core_logs_enabled}`. Префикс должен быть configurable или общий fallback.
- **Notification icon / channel name** — `ServiceNotification.kt` ссылается на `R.drawable.ic_notification` + строки. Должно браться из host app.
- **Manifest declarations** — package должен **документировать** требуемые permissions (location, NEARBY_WIFI_DEVICES, FGS, etc.) и intent-filters (BootReceiver, TileService) для host app.
- **`WifiNetworkObserver` зависит от Dart-side `wifi_history` MethodChannel** — это §051 фича LxBox, не general-purpose. Извлекать **отдельно** или сделать optional.

**Quality gates пройдены:** §049 audit (atomic CAS, F1 split, F2-F26 fixes), §050 closeout (refnum 42 root cause = `SecurityException` через JNI). Wrapper зрелый.

**iOS:** отсутствует. Для cross-platform package — отдельная задача (Network Extension + Packet Tunnel Provider + Swift bridges).

### Layer 2 — CommandClient channel

**Что:** libbox `CommandClient`-канал управления (§122) — нативный `BoxCommandClient.kt` + Dart-клиент `CcChannel`.

| Файлы | Lines |
|---|---|
| `app/android/.../BoxCommandClient.kt` | ~native |
| `app/lib/vpn/cc_channel.dart` | ~700 |

**Coupling с LxBox:** **средний**. Dart-сторона generic (push-стримы + unary-RPC поверх MethodChannel/EventChannel), но привязана к нативному `BoxCommandClient` (три клиента, §164-энергомодель) и именам каналов `lxbox/cc/*` — extraction идёт в паре с VPN-engine (Layer 1), не отдельно.

**API surface:** см. раздел [CommandClient (libbox)](#commandclient-libbox) — status/outbounds/groups/connections push + `getGroups`/`getRules`/`urlTestOutbound`/`selectOutbound`/`closeConnection`.

**Готовность к extraction:** **средняя**. Идёт вместе с Layer 1 (общий native command-server + channel names).

### Layer 3 — Sing-box subscription parser / builder

**Что:** Sealed `NodeSpec` (11 protocol variants, вкл. Masque §130) + URI/JSON/INI parsers + builder NodeSpec → sing-box config JSON.

| Файлы | Lines |
|---|---|
| `app/lib/models/{node_spec, node_spec_emit, tls_spec, transport_spec, ...}.dart` | ~2000 |
| `app/lib/services/parser/*.dart` | ~1500 |
| `app/lib/services/builder/*.dart` | ~2000 |

**Coupling с LxBox:** **высокий**. Builder зависит от `wizard_template.json` shape (наш формат preset'ов / vars / sections), `SettingsStorage` (server_lists, vars, custom_rules), и от наших sealed моделей (`ServerList`, `CustomRule`).

**Готовность к extraction:** **низкая**. Нужен серьёзный refactor — отделить `NodeSpec` parser/emit (reusable) от builder pipeline (LxBox-specific). Имеет смысл только если есть конкретный re-use case.

### Layer 4 — TrafficProfiler

**Что:** Per-app + system-wide observer DNS/TCP/UDP events.

**Coupling:** **высокий** — см. coupling notes в [секции 6.5](#65-per-app-traffic-profiler-044). Зависит от `CcChannel` connections- и dnsQueries-стримов (core-лог **не** парсится, §044/§180). Расцеплять для extraction нужно через интерфейс connection/DNS source.

**Готовность:** низкая. Имеет смысл только если LxBox VPN engine уже extracted и кто-то строит на нём свой profiler.

### Дорожная карта extraction (если решим идти)

1. **Phase 1** — Sing-box VPN engine + CommandClient-канал (Layer 1 + Layer 2) в `packages/flutter_singbox/` (path dependency monorepo). Refactor channel names (`lxbox/*`, `lxbox/cc/*`) + SharedPreferences keys + notification config. Не публикуем на pub.dev пока — верифицируем что LxBox работает.
2. **Phase 2** — выделить из Layer 3 reusable `NodeSpec` parser/emit (без builder pipeline).
3. **Phase 3** — Решение про публикацию: GPLv3 viral от libbox = main blocker. Если ОК с GPLv3-only userbase — публикуем.
4. **Phase 4** — iOS support (если нужен).

**Текущий статус:** ничего не extracted. VPN-engine (Layer 1) + CommandClient-канал (Layer 2) — связка для первого extraction'а.
