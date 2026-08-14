# Persistent Storage

The complete schema of what L×Box keeps on disk between launches. This document is the source of truth for the shape of those files and for the migration history. `ARCHITECTURE.md` links here.

User state lives in `lxbox_settings.json`; the catalog of presets, vars and sections lives in the template (see [`TEMPLATE.md`](./TEMPLATE.md)).

## `lxbox_settings.json` — full tree

> **Notation**:
> - `object{N keys}` — an object with N keys
> - `list[N]` — an array of N elements; a bare `list` is variable-length
> - `<TypeName>` — the element type of an array (shown separately below)
> - a `?` after the type means the field is optional

```
lxbox_settings.json                          # SettingsStorage (Dart), the main state file
│
├─ vars                          object          template-vars override + app feature flags
│   └─ <key>: string                           ─ e.g. log_level, dns_final, debug_token,
│                                                auto_update_subs, last_known_version, ...
│
├─ server_lists[]                list          §033 — sealed (subscription / user / folder §234)
│   └─ <ServerList>              object          discriminator: type
│       ├─ type                  "subscription"|"user"|"folder"
│       ├─ id                    uuid          stable
│       ├─ name                  string        UI display
│       ├─ enabled               bool
│       ├─ tag_prefix            string        prefix for node tags
│       ├─ detour_policy         object{5 keys}       {register_detour_servers, register_detour_in_auto,
│       │                                       use_detour_servers, override_detour, replace_detour_chain}
│       │                        — subscription only —
│       ├─ url                   string?       the subscription URL
│       ├─ meta                  object?         SubscriptionMeta from the HTTP headers (§027):
│       │   ├─ upload_bytes / download_bytes / total_bytes  int?
│       │   ├─ expire_timestamp  int?          unix seconds
│       │   ├─ support_url / web_page_url      string?
│       │   ├─ profile_title     string?
│       │   └─ update_interval_hours           int?
│       ├─ last_updated          ISO-8601?     on success
│       ├─ last_update_attempt   ISO-8601?     any attempt
│       ├─ last_update_status    "never"|"ok"|"failed"|"inProgress"
│       ├─ update_interval_hours int           default 24; §129 special: -1=never, 0=respect server, N>0=every N h
│       ├─ on_update_action      string?       §323 — reaction to an AUTO update: "rebuild" (default,
│       │                                      key not written) | "reload" | "none"
│       ├─ last_node_count       int
│       ├─ consecutive_fails     int           for the UI's "(N fails)"
│       ├─ disabled_hashes       map?          §283 — {node identity hash: ISO-8601 lastSeen}; per-node disable
│       │                                      (§332: one map for both manual and rule marks; Enable rules
│       │                                       and the "Enable all" button clear them indiscriminately)
│       ├─ identity              object?       §289 — per-sub override of the fetch identity (null=global);
│       │                                      {user_agent?, send_hwid, hwid?, device_os?, ver_os?, device_model?}
│       ├─ import_rules           list?         §302 — rules over a node's emit JSON (conditions → Disable/Replace/
│       │                                      Enable §332; the last enable/disable that fires wins);
│       │                                      [{conditions[], match?, action, target_path?, replacement?,
│       │                                        replace_mode?, substitute?, enabled?}]; conditions[] =
│       │                                      [{path, op, pattern, negate?, case_sensitive?}]; the legacy flat
│       │                                      {action, pattern, …} is read by a migration (a condition on tag)
│       ├─ import_rules_enabled   bool?         §302 — the set's toggle (written only when false; the default is on)
│       │                        — user only —
│       ├─ origin                "paste"|"file"|"qr"|"manual"
│       ├─ created_at            ISO-8601
│       ├─ raw_body              string        the original, for reparsing
│       │                        — folder only (§234) —
│       ├─ created_at            ISO-8601
│       └─ members[]             list          {raw, enabled, detour?} — one fragment per member (member ↔ node 1:1; §237)
│
├─ custom_rules[]                list          §030 — sealed (inline / srs / preset)
│   └─ <CustomRule>              object          discriminator: kind
│       ├─ kind                  "inline"|"srs"|"preset"
│       ├─ id                    uuid
│       ├─ name                  string        user-supplied (for a preset, a read-only snapshot)
│       ├─ enabled               bool
│       │                        — inline (CustomRuleInline) —
│       ├─ domains[]             list?         OR group #1: domain (full match)
│       ├─ domainSuffixes[]      list?         OR group #1: ".ru" etc.
│       ├─ domainKeywords[]      list?         OR group #1: substring match
│       ├─ ipCidrs[]             list?         OR group #1: "10.0.0.0/8"
│       ├─ ports[]               list?         OR group #2: "443"
│       ├─ portRanges[]          list?         OR group #2: "8000:9000"
│       ├─ packages[]            list?         OR group #3: package_name
│       ├─ protocols[]           list?         routing-rule level: bittorrent/tls/http/...
│       ├─ ipIsPrivate           bool?         routing-rule level
│       ├─ outbound              tag           "<outbound-tag>" or the "reject" sentinel
│       ├─ dns                   object? {enabled, serverTag, forceIpv4?}  §117/§256 — a mirror DNS rule plus the AAAA suppressor
│       ├─ resolve               object? {only, strategy, …}   §247 — the resolve option (route action resolve)
│       │                        — srs (CustomRuleSrs) —
│       ├─ srsUrl                string        the URL of the .srs binary
│       ├─ ports / portRanges / packages / protocols / ipIsPrivate / outbound / dns
│       │                        — preset (CustomRulePreset) —
│       ├─ presetId              string        a reference to selectable_rules[].preset_id
│       └─ varsValues            object          user vars overrides (including 'outbound')
│
├─ dns_options                   object          §061 (rules) + §043+§044 (servers)
│   ├─ servers[]                 list          §044 kind-discriminated refs:
│   │   └─ <DnsServerRef>        object
│   │       ├─ kind              "template"|"preset"|"inline"
│   │       ├─ enabled           bool
│   │       ├─ tag               string        single source of truth (NOT duplicated in body)
│   │       ├─ description       string?       an optional override; for inline it is primary
│   │       └─ body              object?         inline only; a partial sing-box server
│   │                                          WITHOUT tag/description/enabled
│   ├─ rules[]                   list          §061 origin-discriminated:
│   │   └─ <DnsRuleRef>          object
│   │       ├─ enabled           bool
│   │       ├─ type              "user"|"template"|"rule"
│   │       ├─ title             string        display
│   │       └─ rule              object?         the sing-box rule body (for type=user)
│   └─ rules_json                string        DEPRECATED legacy single-string (§061)
│
├─ ping_options                  object          §040
│   ├─ url                       string?       global default URL
│   ├─ timeout_ms                int?          global default timeout
│   ├─ presets[]                 list?         pre-built URL options (template-side)
│   └─ groups                    object?         per-group override
│       └─ <groupTag>            object          {url?, timeout_ms?}
│
├─ route_final                   string        override sing-box route.final
├─ route_idle_suspend            string        §215/§128 — idle-suspend threshold (route.lx_idle_suspend);
│                                                a duration ("30s"/"5m"), default "30s" (ENABLED), "" = off; config-significant
├─ excluded_nodes[]              list          §125 cleanup, DEPRECATED — the global node filter (§048) is gone; safe debris
├─ enabled_groups[]              list          §125 DEPRECATED — read only by the channels[] migration. Safe debris.
├─ channels[]                    list          §125 — routing channels (template→storage). See below.
│   └─ <item>                    object
│       ├─ tag                   string        the system's immutable id 'vpn-1'..'vpn-10' (auto-generated; vpn-1 cannot be deleted)
│       ├─ label                 string        the display name (entered by the user)
│       ├─ enabled               bool          on/off (vpn-1 is always true)
│       ├─ include_direct        bool          direct-out as a selector option
│       ├─ include_block         bool          §201 — block (dropping traffic) as a selector option; default false
│       ├─ node_filter           string        a regex over the node's final tag; '' means all
│       ├─ node_filter_invert    bool          §197 — inverts node_filter (the nodes that do NOT match); default false
│       ├─ default_filter        string        a regex; the first match becomes the default; '' means none
│       ├─ interrupt_exist_connections  bool   selector.interrupt_exist_connections
│       └─ auto                  object?       null = the checkbox is OFF; an object yields the urltest twin <tag>-auto (its tag is derived)
│           ├─ url               string        urltest test endpoint
│           ├─ interval          string        duration ("5m")
│           ├─ tolerance         int           ms, uint16 (§161 — clamp 0..65535)
│           ├─ idle_timeout      string        duration ("30m")
│           ├─ interrupt_exist_connections  bool  urltest.interrupt_exist_connections
│           ├─ mode              string        §208 — 'least_test' (default) | 'round_robin'
│           └─ balancer          object{3 keys}  §208 — {pool, pool_tolerance, sticky_hash[]}
├─ channels_migrated             bool          §125 — the guard for the one-shot enabled_groups→channels migration
├─ last_global_update            ISO-8601      the timestamp of the last auto-refresh
├─ presets_migrated              bool          §159 — the "default presets have been seeded" guard (fresh-install seed)
├─ preset_ids_remapped           bool          §228 legacy guard (remapping renamed preset_id). The migration was removed in §229; the key is inert
├─ interrupt_connections_on_switch  bool       §143 — tear down the switched group's connections when the node changes (default false, NOT config-significant)
├─ node_sort_mode                string        §100 — the chosen node sort mode ('' means the template default)
├─ node_manual_order[]           list          §100 — the manual order of node tags (for mode=manual)
├─ profiler_retention_sec        int           §044 — the profiler's live-journal window, default 600 (10 min); NOT config-significant
├─ warp_account                  object?       §025 — the cached WARP account (see the section below)
├─ masque_account                object?       §130 — the cached MASQUE-WARP account (see the section below)
├─ tun_apps                      object        §046 — split tunneling (see the section below)
├─ vpn_mode                      object?       §119 — the inbound mode (see the section below)
└─ native_prefs                  object        §189 — a MIRROR of the Android prefs (`boxvpn_boot.*`).
    │                                            The JSON is the source of truth (disk); native is the working copy.
    ├─ auto_start                bool          default false  — auto-start the VPN at boot
    ├─ keep_on_exit              bool          default true   — §188: do not kill the tun on a swipe-kill
    ├─ background_mode           string        default "never" — never|lazy|always (Doze behaviour)
    ├─ core_logs_enabled         bool          default false  — forwarding of the sing-box logs
    ├─ allow_bypass              bool          default false  — Allow VPN bypass (§069)
    ├─ auto_redirect             bool          default false  — auto-redirect
    └─ memory_limit              string        default "auto" — §271: the core's memory limit
                                                 (auto|off|"200"|"384"|"512"|"768" MB)

# §159 — none of the legacy keys (proxy_sources / app_rules / enabled_rules /
# rule_outbounds / node_overrides / show_detour_servers / vars.auto_rebuild)
# are processed any more: both the migrations and the DENY `.remove()` calls are
# gone. If such a key is still on disk it is harmless (nothing reads it) and will
# be dropped by the allowlist on the first backup import.
```

Every key is described in detail in the sections below.

## Disk layout

Every path is relative to the **Android internal documents directory** (`getApplicationDocumentsDirectory()`). On a device that directory is unreachable without root or the Debug API (`GET /state/storage`).

```
getApplicationDocumentsDirectory()/
├── lxbox_settings.json
├── singbox_config.json
├── http_cache/
│   ├── <sha1(url)>.body
│   └── <sha1(url)>.headers
├── rule_sets/
│   └── <tag>.srs
├── applog.txt
└── corelog.txt

Android SharedPreferences:
├── Flutter prefs                # app_theme_mode, haptic_enabled, …
└── boxvpn_boot.*                # pre-Flutter boot flags
```

| File / directory | Written by | What is inside | Spec |
|---|---|---|---|
| `lxbox_settings.json` | `SettingsStorage` (Dart) | App settings, vars, server lists, custom rules, DNS, ping. **The main subject of this document.** | — |
| `singbox_config.json` | `ConfigManager` (Kotlin) | The final sing-box JSON fed to libbox. Regenerated on every `buildConfig`. Not part of a backup. | — |
| `http_cache/<sha1(url)>.body` + `.headers` | `HttpCache` (Dart) | The raw body and headers of a subscription, for the offline rehydrate at startup. | [§027] |
| `rule_sets/<tag>.srs` | `RuleSetDownloader` (Dart) | A cache of binary `.srs` rule-set files. | [§011] |
| `applog.txt` | `AppLog` (Dart) | The app-side warn/error log, JSON lines, a ring buffer of 200 lines / 64 KB. | [§038], [§043][043-applog] |
| `corelog.txt` | `AppLog` (Dart) | The sing-box warn/error log. Lines arrive from Kotlin over `EventChannel lxbox/coreLog` (`BoxService.coreLogDrainer`, in `List<String>` batches); `ClashLogPump` (a legacy name — NOT the Clash API, which was removed in §122) receives them and `AppLog.add(source: core)` writes them here through the same ring-buffer mechanism as `applog.txt`. TRACE and DEBUG are filtered out on the native side. 200 lines / 64 KB. | [§043][043-applog] |
| Android `SharedPreferences` | Kotlin (`BoxApplication`) plus Flutter (`shared_preferences`) | Pre-Flutter boot flags and UI prefs. See the [“SharedPreferences”](#sharedpreferences-android) section below. | — |

---

## `lxbox_settings.json` — top-level

```jsonc
{
  "vars":               { … },     // Map<String,String>
  "server_lists":       [ … ],     // subscription / user
  "custom_rules":       [ … ],     // sealed: inline / srs / preset
  "dns_options":        { … },     // rules + servers
  "ping_options":       { … },
  "route_final":        "<tag>",   // override route.final
  "route_idle_suspend": "30s",     // §215/§128 — idle-suspend threshold (default "30s"; "" = off)
  "excluded_nodes":     [ … ],     // §125 cleanup, DEPRECATED (the global node filter is gone)
  "enabled_groups":     [ … ],     // §125 DEPRECATED (read only by the channels[] migration)
  "channels":           [ … ],     // §125 — routing channels (template→storage)
  "channels_migrated":  true,      // §125 — the guard for the enabled_groups→channels migration
  "last_global_update": "ISO-8601",// the last auto-refresh of subscriptions
  "presets_migrated":   true,      // §159 — the "defaults seeded" guard (fresh-install seed)
  "interrupt_connections_on_switch": false, // §143 — tear down the group's conns on a node switch (NOT config-significant)
  "node_sort_mode":     "",        // §100
  "node_manual_order":  [ … ],     // §100
  "profiler_retention_sec": 600,   // §044 — the profiler's live-journal window (NOT config-significant)
  "warp_account":       { … },     // §025 — the cached WARP account (secrets)
  "masque_account":     { … },     // §130 — the cached MASQUE-WARP account (secrets)
  "tun_apps":           { … },     // §046 — split-tunneling
  "vpn_mode":           { … },     // §119 — the inbound mode
  "native_prefs":       { … }      // §189 — a mirror of boxvpn_boot.* (the JSON is the truth)
}
```

The in-memory cache is `SettingsStorage._cache` (lazily loaded). Writes are atomic through `JsonEncoder.withIndent('  ')`. §159 — on `_save()` nothing is removed any more: the DENY list and the migrations are gone, and the input filter is the allowlist on backup import.

The per-key specs and shapes are in the sections below.

---

## `vars` — template-vars + app flags

A flat `Map<String, String>` (values are stringified on read). It serves both **template substitution** (any `@name` in `wizard_template.json` is filled in from here) and app feature flags — the two live in the same map.

### Known keys

| Key | Default | Spec | What it does |
|---|---|---|---|
| `auto_update_subs` | `'true'` | [§027] | The global gate for auto-refreshing subscriptions. Manual refresh always works. |
| `auto_update_disabled_subs` | `'false'` | §337 | Also refresh disabled subscriptions, so their node snapshot does not go stale. It lives inside `auto_update_subs` and does not override `updateIntervalHours`. |
| `auto_reload_on_change` | `'false'` | §338 | Restart the VPN automatically on any config change, so no banner is left behind. It overrides the per-subscription `on_update_action`. |
| `auto_check_updates` | `'false'` | [§036], §395 | Polls GitHub Releases at startup. Off until the first-run prompt is answered — an unprompted request is the `Tracking` anti-feature under F-Droid's rules. |
| `last_update_check_at` | `''` | [§036] | The last polling timestamp, as UTC ISO-8601. |
| `last_known_version` | `''` | [§036] | The cached latest tag. |
| `dismissed_update_version` | `''` | [§036], §390 | The tag the user dismissed with **Ignore** — the snackbar is not shown for it again. |
| `shown_crash_stamp` | `''` | §316 | The `name@mtime` of the core crash report whose home-screen banner has already been shown. It binds to a SPECIFIC file rather than being a counter, so a new crash shows the banner again. |
| `config_locked_for_debug` | `'false'` | [§037] | `generateConfig()` returns null silently. The user pins their own config through `PUT /config`. |
| `debug_enabled` | `'false'` | [§031] | The runtime toggle for the Debug API server. |
| `debug_token` | `''` | [§031] | The Bearer token for every `/api/*` call. |
| `debug_port` | `'9269'` | [§031] | The TCP port. Range 1024–49151. |
| `dns_final` | template | [§043][043-dns] | The final DNS resolver (`cloudflare_udp` / `google_udp` / `local_dns_resolver` / `yandex_udp`, or any tag from `dns_options.servers`). |
| `auto_record_wifi_history` | `'false'` | [§051] Phase 3 | The native `WifiNetworkObserver` pushes the current SSID/BSSID into `wifi_history` after more than 5 minutes on a network. Off by default, as a privacy default. The toggle is in App Settings → Diagnostics. |
| `probe_ms_green` | `'250'` | §236 | Test servers (folders): the upper bound of the “green” latency, in ms. NOT a config var (it does not mark the config dirty). |
| `probe_ms_yellow` | `'500'` | §236 | Test servers: the upper bound of the “yellow” latency, in ms. |
| `probe_ms_orange` | `'700'` | §236 | Test servers: the upper bound of the “orange” latency, in ms; anything above is red. |
| `wifi_history` | `'[]'` | [§051] Phase 3 | A JSON-encoded `[{ssid, bssid, last_seen}]` (see its own section below). |
| `automation_receive_enabled` | `'false'` | §047 | The Public Intent API: accepting broadcasts from Tasker and friends. Default OFF. |
| `automation_emit_lifecycle` | `'false'` | §047 | Emitting lifecycle events outwards. Default OFF. |
| `automation_emit_state` | `'false'` | §047 | Emitting state events. Default OFF. |
| `automation_emit_subs` | `'false'` | §047 | Emitting subscription events. Default OFF. |
| `automation_emit_health` | `'false'` | §047 | Emitting health events. Default OFF. |
| `automation_explainer_shown_v1` | `'false'` | §047 | One-shot: the automation explainer dialog has been shown. |
| `subscription_user_agent` | — | identity headers | The User-Agent used when fetching subscriptions. |
| `subscription_send_hwid` | — | identity headers | Whether to send the hwid headers on a fetch. |
| `subscription_hwid` | — | identity headers | The HWID (potentially identifying). |
| `subscription_device_os` | — | identity headers | The subscription's OS header. |
| `subscription_ver_os` | — | identity headers | The OS version header. |
| `subscription_device_model` | — | identity headers | The device model header. |
| `haptic_enabled` | `'true'` | §029 | Haptic feedback in the UI. It lives in `vars` (`HapticService.prefsKey`), NOT in SharedPreferences. |
| `auto_ping_on_start` | `'true'` | — | Ping the nodes automatically once the tunnel comes up (App Settings). Read in `ping_orchestration.dart`. |
| `notif_perm_prompted_v1` | `'false'` | §128 | One-shot: the notification permission prompt has been shown. |
| `wizard_update_check_v1` | `'false'` | §395 | One-shot: the update-check consent prompt has been shown. Its answer is what writes `auto_check_updates`. |
| `allow_rotation` | `'false'` | [§220] | Releases the portrait lock: `'true'` yields an empty preferred-orientations list (the system's auto-rotate decides). The default is a hard portrait lock. |
| `resolve_enabled` | template | §263/§265 | The gate for the route-resolve rule of the `traffic-processing` preset. A var of the `internal` section (not visible in VPN Settings), edited inside the rule through a ref-var. |
| `resolve_strategy` | template | §249/§265 | The IP version for route-resolve (`ipv4_only` / `prefer_ipv4` / …). A var of the `internal` section, used as a ref-var in `traffic-processing`. |
| `app_language` | `'system'` | §279 | The app language: `system` \| `en` \| `ru`. **The single source of truth** — this var, not SharedPreferences. |
| `<custom>` | — | — | Any user template vars set through the UI or `PUT /settings/vars/<key>`. |

> The authoritative list of app flags in code is `SettingsStorage._appFeatureFlagVars`; keep this table in sync with it.

`removeVar(k)` is not the same as `setVar(k, '')` — an empty string can be a legitimate value, while an absent key falls back to the default.

---

## `server_lists` — [§033] (v2)

The list of node sources. It used to be `proxy_sources` (v1); §159 removed the migration and the legacy key is ignored.

Sealed on the `type` field:

### `type: "subscription"` — `SubscriptionServers`

```jsonc
{
  "type":                  "subscription",
  "id":                    "<uuid>",          // stable
  "name":                  "<display>",
  "enabled":               true,
  "tag_prefix":            "<str>",           // the prefix for node tags at build time
  "detour_policy":         { … },             // see below
  "url":                   "https://…",       // an online subscription. §129: a file
                                              // subscription becomes "file:<uuid>" (the
                                              // node snapshot lives in HttpCache under
                                              // that key; not a path, no access retained)
  "meta":                  { … }?,            // SubscriptionMeta — HTTP-headers
  "last_updated":          "ISO-8601"?,       // on success
  "last_update_attempt":   "ISO-8601"?,       // any attempt
  "last_update_status":    "never|ok|failed|inProgress",
  "update_interval_hours": 24,                 // §129 special values: -1 = never
                                               // (ignore the server header; set
                                               // automatically for file: subscriptions),
                                               // 0 = not on a schedule, but the server's
                                               // interval is honoured, N>0 = every N h.
                                               // AutoUpdater skips an interval ≤ 0.
  "on_update_action":      "reload"?,          // §323 — what to do after a SUCCESSFUL
                                               // auto update: "rebuild" (the default —
                                               // rebuild the config, the user applies it),
                                               // "reload" (plus an in-place core reload,
                                               // a ~3 s gap), "none" (the node list only).
                                               // The key is written ONLY for a non-default;
                                               // absent or malformed means rebuild. The
                                               // manual ⟳ is not governed by this.
  "last_node_count":       0,
  "consecutive_fails":     0,                 // for the UI's "(N fails)"; freezing is in-memory
  "disabled_hashes": {                        // §283 — per-node disable (optional; an
    "<sha256-hex>": "2026-07-18T10:00:00Z"    // empty map is not written). The key is the
  },                                          // identity hash of the node's substance
                                              // (emit − tag − detour, see
                                              // services/node_hash.dart); the value is
                                              // lastSeen for the TTL GC (clamp(3×interval,
                                              // 24 h, a month)) on a successful refresh.
  "identity": {                               // §289 — a per-sub override of the fetch
    "user_agent": "MyPanel/1.0",              // identity. Optional: null or absent means
    "send_hwid": true,                        // Default mode (the global SubscriptionIdentity).
    "hwid": "550e8400-...",                   // An object means Custom mode: the fetch uses
    "device_os": "android",                   // ONLY these values. Empty strings (user_agent/
    "ver_os": "14",                           // hwid/device_*) are not serialized. Enabled
    "device_model": "Pixel 7"                 // the global ones; discarded on return to Default.
  },
  "import_rules": [                           // §302 — rules over a node's emit JSON (not the body!).
    {                                         // Applied to ALREADY PARSED nodes, in order
      "conditions": [                         // (drag-reorder); the next rule sees the previous
        {                                     // one's patch. Optional (an empty list is not written).
          "path": "tls.utls.fingerprint",     // A condition: path (dot notation over the emit JSON;
          "op": "matches",                    // an EMPTY path searches the whole node), op ∈
          "pattern": "^hello(chrome)_\\d+$"   // {contains|equals|matches}; negate?/case_sensitive?
        }                                     // are written only when true. match ∈ {all|any}
      ],                                      // (the default all=AND; only any is written).
      "action": "replace",                    // action ∈ {replace, disable, enable}.
      "target_path": "tls.utls.fingerprint",  // REPLACE: target_path is required (never empty);
      "replacement": "$1"                     // replacement takes $1..$9 from the matches condition.
    },                                        // replace_mode ∈ {set|substitute} (only substitute
    {                                         // is written); substitute? is what to find in the value.
      "conditions": [
        {"path": "tag", "op": "contains", "pattern": "⚡"}
      ],
      "action": "disable"                     // DISABLE marks the node → its identity hash (of
    },                                        // the FINAL form, after the patches) is put into
    {                                         // disabled_hashes on every refresh (rule > TTL GC).
      "conditions": [
        {"path": "", "op": "matches", "pattern": ".*"}
      ],                                      // §332 — ENABLE clears the mark from disabled_hashes,
      "action": "enable"                      // INCLUDING a manual one (§283). Order matters: the
    }                                         // last enable/disable that fires wins, so an
  ],                                          // enable-everything first is a reset before new
                                              // filters, while disable-everything plus enable-NL
                                              // is an allowlist. An older app version reads
                                              // "enable" as a replace with no target → the rule
                                              // is unusable and is skipped silently (nodes are
                                              // left intact).
                                              // The legacy flat {action, pattern, is_regex?, ...}
                                              // is read by a migration as a condition on tag
                                              // (replace gains substitute semantics); the first
                                              // save rewrites it in the new format.
  "import_rules_enabled": false               // §302 — the set's toggle; written ONLY when
                                              // false (the default, true, means the set is on).
}
```

### `type: "user"` — `UserServer`

```jsonc
{
  "type":          "user",
  "id":            "<uuid>",
  "name":          "<display>",
  "enabled":       true,
  "tag_prefix":    "<str>",
  "detour_policy": { … },
  "origin":        "paste|file|qr|manual",
  "created_at":    "ISO-8601",
  "raw_body":      "<original input>"         // kept for reparsing when something goes wrong
}
```

### `type: "folder"` — `FolderServers` (§234)

A folder of manual servers: a container of members sharing one toggle, `tag_prefix` and
`detour_policy`. A subscription cannot be put into a folder, and there is no nesting.

```jsonc
{
  "type":          "folder",
  "id":            "<uuid>",
  "name":          "<display>",
  "enabled":       true,                        // the toggle for the whole folder
  "tag_prefix":    "<str>",
  "detour_policy": { … },
  "created_at":    "ISO-8601",
  "ping_url":         "<url>",                  // §284 — an optional override of the test URL
  "ping_timeout_ms":  3000,                     // §284 — an optional override of the timeout
  "members": [                                  // the order here is the order in the UI
    { "raw": "vless://…#Alpha", "enabled": true,
      "detour": "Jump" },                            // §237 — a personal detour (optional)
    { "raw": "wg://…#Beta",     "enabled": false }   // per-member toggle
  ]
}
```

`ping_url` and `ping_timeout_ms` (§284) are **the folder's own test options**, and they
override the global `ping_options` when Test is pressed inside the folder. When absent,
the global value is used. They are stored in the folder object, so they travel with a
backup automatically. The “WARP GENERATOR” folder puts an IP URL here
(`1.1.1.1/cdn-cgi/trace`) — a test by IP, with no DNS.

`raw` is a self-contained parseable fragment (a URI, a WG INI or an outbound JSON);
the nodes are reconstructed by re-parsing each `raw` on load (just like `raw_body` for a
user list). In memory `nodes` holds only the enabled members, so the builder needs no
folder-specific branching. A malformed `raw` yields a member with no node (visible in the
UI, and editable or removable).

### `detour_policy` (shared)

```jsonc
{
  "register_detour_servers":  false,
  "register_detour_in_auto":  false,
  "use_detour_servers":       true,
  "override_detour":          "",              // '' = no override
  "replace_detour_chain":     false            // §178 — false appends the override as a tail, true replaces the whole chain
}
```

### `meta` (optional)

From the subscription's HTTP headers ([§027]):

```jsonc
{
  "upload_bytes":          0,
  "download_bytes":        0,
  "total_bytes":           0,
  "expire_timestamp":      <unix>?,
  "support_url":           "…"?,
  "web_page_url":          "…"?,
  "profile_title":         "…"?,
  "update_interval_hours": 24?
}
```

The `nodes` array is **not stored** — it is reconstructed at startup from `raw_body` (for a `user` list) or from `http_cache/` (for a `subscription`).

---

## `custom_rules` — [§030] sealed (inline / srs / preset)

The discriminator is `kind`. For backward compatibility, a JSON object without `kind` is read as `inline`.

**The shared `num` field ([§370])** is the rule's position on a sparse ordering axis.
All four kinds carry it (written next to `kind`). The layout: `0` is the head
(`traffic-processing`), `950..990` are the specific presets, `1000..1100` is the
user-rule zone, and `1110..1150` are the broad catch-alls; the step of 10 between
template rules leaves room for future insertions (see `ui.num` in TEMPLATE.md).

When the key is **absent**, the rule has not been numbered yet (storage written
before §370). Numbering happens on the first load of the Routing screen
(`markRuleOrder`): a preset takes its `num` from the template by `presetId`, and
everything else is numbered consecutively from `1000` in the array's current order.
There is NO separate versioned migration step. The consequence: rules from older
storage land at the start of the user zone and end up with a higher priority than
anything added after the update.

The rule order is a sort by `num` (ties keep the array's order). Dragging in the UI
recomputes the dragged rule's `num` as `target.num + 1`, shifting the neighbours only
when that value is taken (a lazy shift — it preserves the gaps and the template
anchors, see `rule_order.dart`).

### `kind: "inline"` — `CustomRuleInline`

```jsonc
{
  "kind":           "inline",
  "num":            1000?,         // §370 — the position on the ordering axis
  "id":             "<uuid>",
  "name":           "<display>",
  "enabled":        true,
  "domains":        [ … ]?,        // OR group #1
  "domainSuffixes": [ … ]?,
  "domainKeywords": [ … ]?,
  "ipCidrs":        [ … ]?,
  "ports":          [ … ]?,        // OR group #2: "443"
  "portRanges":     [ … ]?,        //              "8000:9000", ":3000", "4000:"
  "packages":       [ … ]?,        // OR group #3
  "protocols":      [ … ]?,        // routing-rule level (subset of kKnownProtocols)
  "ipIsPrivate":    true?,         // routing-rule level
  "outbound":       "<tag>",       // or "reject" (a sentinel → action: reject)
  "dns":            { "enabled": true, "serverTag": "<dns-server tag>", "forceIpv4": true? }?,  // §117 task 3 + §256
  "resolve":        { "only": false, "strategy": "ipv4_only", "serverTag": ""?,
                      "disableCache": true?, "disableOptimisticCache": true?,
                      "rewriteTtl": 60?, "timeout": "5s"?, "clientSubnet": "…"? }?  // §247
}
```

`name` is user-supplied and mutable.

OR semantics inside a category, AND between them. `protocols` and `ipIsPrivate` are not made headless — they are lifted to the routing-rule level.

`dns` ([§117] task 3, “DNS follows the rule”) is optional: the builder emits a mirror DNS rule `{rule_set: <the same headless one>, server: serverTag}` inside an atomic mirror group (ordered like the routing rules). It is absent in older records → null → the old behaviour. The gate: with non-empty `ports` or `protocols` the mirror is not emitted.

`dns.forceIpv4` ([§256], Force IPv4) is optional: it suppresses AAAA (IPv6) for the rule's match through a serverless rule `{rule_set|match, ip_version: 6, action: predefined, rcode: NOERROR}` (so the app cleanly takes the A record). It is **orthogonal** to `enabled` and `serverTag` — the suppressor answers locally and needs no DNS server, so a rule may carry `forceIpv4` alone (`enabled: false`, `serverTag: ""`). It is emitted BEFORE the server mirror (the §253 order). The same port/protocol gate applies (the DNS layer is blind to port and protocol). Older records → false.

`resolve` ([§247]) is optional: the builder emits a non-terminal route rule `{rule_set: <the same headless one>, action: resolve, …}` either BEFORE the terminal route (`only: false`, the flagship case — forcing `ipv4_only` for direct branches) or INSTEAD of it (`only: true`, an advanced fall-through). It is absent in older records → null. The gate: for inline rules it is emitted only when the domain group is non-empty (`resolveEligible`); for srs it is always emitted, since a `.srs` may contain domains.

### `kind: "srs"` — `CustomRuleSrs`

```jsonc
{
  "kind":        "srs",
  "id":          "<uuid>",
  "name":        "<display>",
  "enabled":     true,
  "srsUrl":      "https://…/something.srs",
  "ports":       [ … ]?,          // extra filters at the routing-rule level
  "portRanges":  [ … ]?,
  "packages":    [ … ]?,
  "protocols":   [ … ]?,
  "ipIsPrivate": true?,
  "outbound":    "<tag>",
  "dns":         { "enabled": true, "serverTag": "<dns-server tag>", "forceIpv4": true? }?,  // §117 task 3 + §256
  "resolve":     { "only": false, "strategy": "ipv4_only", … }?          // §247 (as for inline)
}
```

The `.srs` binary itself lives separately in `rule_sets/<tag>.srs` (see the [file table](#disk-layout) above).

`dns` ([§117] task 3) works as it does for inline, except the mirror references an existing `.srs` tag plus the DNS-safe extra filters (`packages` and wifi). It only works when the rule set contains domains — an IP-only list never matches in a DNS context.

### `kind: "preset"` — `CustomRulePreset`

```jsonc
{
  "kind":       "preset",
  "id":         "<uuid>",
  "name":       "<display, snapshot of preset.label>",
  "enabled":    true,
  "presetId":   "<id from template>",
  "varsValues": { "<varName>": "<value>", "outbound": "<tag>" }?
}
```

`name` is read-only in the UI (🔒) and is periodically synced with `preset.label` from the template. The contents are expanded on every `buildConfig` through `expandPreset` ([§033]). `outbound` is kept in `varsValues['outbound']` as a universal override ([§033] Expansion §5).

> **§265 — ref-var values do NOT live in `varsValues`.** When a preset declares a var
> as `{"ref":"<global>"}` (for example `traffic-processing` → `resolve_enabled` /
> `resolve_strategy`), its value lives in the **global** `vars` (top level,
> `setVar` / `getAllVars`) and NOT in the preset's `varsValues` — one source, so that
> editing it in the rule and in the owning section cannot diverge. `varsValues` must
> not contain ref names; `stripRefVarsFromVarsValues`
> (`normalize_pinned_presets.dart`) clears out stuck copies when Routing loads
> (otherwise the subtitle and Debug showed a stale value — `366beec`). See the
> “ref-vars” section of TEMPLATE.md.

### Backward-compat

- The `target` field (up to v1.4.1) became `outbound`. It is read under both names.
- An absent `kind` means `inline` (on the read path).
- The legacy `app_rules` key (a separate tab up to v1.3.2) — §159 removed the `_absorbLegacyAppRules` migration and the key is ignored (dropped by the allowlist on import).

---

## `dns_options` — [§061] (rules) + [§043][043-dns] + [§044] (servers)

```jsonc
{
  "servers":     [ <ServerRef>, … ],
  "rules":       [ <RuleRef>,   … ],
  "rules_json":  "<deprecated>"
}
```

**§294 — typing:** the kind refs in `servers[]` and `rules[]` are typed by the model
`lib/models/dns_ref.dart` (sealed `DnsServerRef` {inline·preset·template} +
`DnsRuleRef` {inline·srs·preset·template}). **The on-disk shape did NOT change** —
`toJson` is byte-compatible (§221 backup); `fromJson` is tolerant on read (a legacy
full body or an unknown kind becomes null and is dropped exactly as the resolver
would). The strict `fromJsonStrict` is used only on the Debug write path
(`PUT /settings/dns_options/*` → 400 on a malformed shape). The resolver
(`resolveDisplayedServers`, the VIEW layer) is untouched.

### `dns_options.servers[i]` — kind-discriminated ref ([§044])

```jsonc
{
  "kind":        "template" | "preset" | "inline",
  "enabled":     <bool>,
  "tag":         "<string>",        // the SINGLE source of truth, not duplicated in body
  "description": "<string>"?,        // an optional override; for inline it is primary
  "body":        { … }?,             // inline only; a partial sing-box server WITHOUT tag/description/enabled
  "varValues":   { "<name>": "<value>", … }?  // §117, template only: the chosen var values
}
```

**What each kind means:**

- `template` — a reference to a server from the template ([§117]: a `{vars, server}` wrapper, with the tag in `server.tag`). The user can override `enabled` and `description` and choose var values (`varValues`: the `outbound` channel, the IP profile, the domain resolver — see TEMPLATE.md); the body is resolved from the template by substituting the `@var`s (`resolveTemplateDnsServerBody`).
- `preset` — the same, but from the active preset bundle (`server_lists` has nothing to do with it; this means a template preset).
- `inline` — a user-defined server. `body` is required. When the tag matches a template or preset one AND the shape matches, the builder may collapse it into a `template` or `preset` ref (see `_serverShapesMatch`).

**Render order in the UI:** `template` → `preset` → `inline` (sorted by `ServerKind.index`, stable within a group).

**The builder** synthesizes `body.tag` back when assembling the final sing-box config. In storage the tag lives **only** at the ref level.

### `dns_options.rules[i]` — [§061]

```jsonc
{
  "enabled": <bool>,
  "type":    "user" | "template" | "rule",
  "title":   "<display>",
  "rule":    { … }?                  // the sing-box rule body, for type=user
}
```

`type` is the origin discriminator (the predecessor of [§044]'s `kind` — historically a different word).

`type: template/rule` — orphan cleanup: when the title is not found in the active template or preset, the entry is discarded in `resolveDnsRulesList`.

⚠ §257: on a `kind: preset` entry the `enabled` field is **dead**: the toggle for a
preset's DNS block moved to the magic var `dns_enable`
(`custom_rules[].varsValues`, see “Magic variables” in TEMPLATE.md). The entry
remains only as a **positional anchor** for the mirror group (§117) — it decides
where the preset's DNS rules sit inside `dns.rules`. Neither the builder nor the UI
reads its `enabled`; auto-discovery keeps writing `enabled: true`, harmlessly. There
is no migration — after an update every preset carrying the var has its DNS block on
(the default is true), and anyone who wants it off can turn it off.

### Migration history

- v1.5.x: `dns_options.rules_json` — a single JSON string (`@Deprecated`). It is ignored now; the field stays on disk for downgrade safety.
- v1.6.0 ([§061]): `dns_options.rules[]` — a structured list with `type` / `enabled` / `title` / `rule`.
- v1.6.0 ([§043][043-dns]): `dns_options.servers[]` — the first kind refs. Back then tag, description and enabled lived inside `body`.
- v1.6.1 ([§044]): `dns_options.servers[]` — the clean schema. Tag, description and enabled were lifted to the ref level, and the underscore annotations (`_kind`, `_overrides`) were removed.
- v1.7.x ([§117]): template servers inside the template became `{description, enabled, vars?, server}` wrappers, and the `kind: template` ref gained `varValues`.
- §228: remapping renamed `preset_id`s inside `custom_rules` — `bittorrent-direct`→`bittorrent`, `private-ip-direct`→`private-ip`, `block_unknown`→`unknown-traffic`.
  **The migration was removed in §229** (it shipped in v2.10.0 and was dropped during development after v2.17.0): everyone upgrading from those versions has already been remapped, and a fresh install never had the old ids.

---

## `ping_options` — [§040]

```jsonc
{
  "url":        "https://…",          // global default URL
  "timeout_ms": <int>,                 // global default timeout
  "presets":   [ … ],                  // pre-built URL-options (template-side)
  "groups": {                          // a per-group override (optional)
    "<groupTag>": {
      "url":        "…"?,
      "timeout_ms": <int>?
    }
  }
}
```

The resolve chain in `HomeController`: `groups[tag]` → root → the template default.

CRUD helpers: `setGlobalPingUrl`, `setGlobalPingTimeout`, `setGroupPing`, `clearGroupPing`. All of them are sugar over `getPingOptions` / `savePingOptions`, which read and write the whole object.

---

## `tun_apps` — [§046]

OS-level split tunneling: which applications go through the VPN tun and which go direct over cellular or Wi-Fi (bypassing sing-box entirely).

```jsonc
{
  "mode": "off" | "allow" | "deny",
  "packages": ["com.example.app", "ru.tinkoff.investing", ...]
}
```

| `mode` | What lands in `inbound[type=tun]` of the final config | Effect |
|---|---|---|
| `"off"` | (nothing is written) | Every app goes through the tun (the Android default) |
| `"allow"` | `"include_package": [...packages]` | Only the listed apps use the tun. The rest go direct |
| `"deny"`  | `"exclude_package": [...packages]` | Everything EXCEPT the listed apps uses the tun |

**The native layer** (`BoxVpnService.kt`) reads `options.includePackage` / `excludePackage` from libbox and calls `VpnService.Builder.addAllowedApplication` / `addDisallowedApplication`.

**The default for existing users** is `{mode: "off", packages: []}`, for backward compatibility. The migration runs unconditionally on the first `_load()` after an upgrade.

**Exposed in `/state/storage` with no scrubbing** — package names are not sensitive.

CRUD: `getTunApps()` / `setTunApps()` (a whole-object replace). API: `GET/PUT /settings/tun_apps` ([the Debug API reference](api/debug-api-reference.md)).

**Interaction with `package_name` rules in custom_rules:** apps in the allow list (or outside the deny list) go through the tun and are then subject to the routing rules; apps outside the tun never reach sing-box at all, so no rule can affect them.

---

## `vpn_mode` — [§119]

The VPN's operating mode (how inbound traffic is treated): how the core captures traffic.

```jsonc
{
  "mode": "vpn" | "proxy" | "vpn_proxy",
  "proxy_protocol": "mixed" | "http" | "socks",
  "proxy_port": 2080,
  "proxy_listen": "127.0.0.1",           // any valid IPv4; anything invalid becomes 127.0.0.1
  "proxy_auth_enabled": true,
  "proxy_username": "user",
  "proxy_password": "<32 hex chars, or empty>"
}
```

`proxy_protocol` is the sing-box inbound `type` of the local proxy: `mixed` (HTTP plus SOCKS5 on one port, the default), `http` (HTTP only) or `socks` (SOCKS5 only).

| `mode` | The inbounds of the final config | `VpnService.establish()` | Effect |
|---|---|---|---|
| `"vpn"` | `tun-in` (auto_route) | yes | all system traffic goes through the tun (the current behaviour, **the default**) |
| `"proxy"` | `mixed-in` (no tun) | **no** (libbox never calls `openTun`) | a local HTTP+SOCKS port; applications are configured manually |
| `"vpn_proxy"` | `tun-in` + `mixed-in` | yes | system-wide capture AND a local port at the same time |

**The builder** (§120). The imperative `applyVpnMode` / `post_steps/vpn_mode.dart` has been **removed** — the whole inbound structure is now assembled declaratively:
- `proxy` yields only `mixed-in` (no `tun-in`); `vpn_proxy` yields `tun-in` plus `mixed-in`.
- `mixed-in` = `{type:mixed, tag:mixed-in, listen, listen_port, users?}`.

**Auth.** `users:[{username,password}]` is written only when `effectiveAuth && password != ""`. For any **non-loopback** listen address the auth is forced on (§120): a proxy reachable from the LAN without a password would be an open relay.

**Changing the mode changes the inbounds, so the VPN restarts fully** (inherited from the config-dirty machinery: the home banner's Apply, or a restart).

**The default for existing users:** an absent key means `mode=vpn` (the current behaviour), so no migration is needed.

CRUD: `getVpnMode()` / `setVpnMode()` (a whole-object replace).

**Native:** nothing changed in Kotlin — the proxy mode is achieved purely through the config (the foreground service, `protect` and the overrides stay as they were).

---

## `warp_account` — [§025]

The cached registered Cloudflare WARP account (the “Get WARP” button). The private key is generated on the device and never leaves it.

```jsonc
{
  "priv_key": "<base64 X25519 — A SECRET, never log it>",
  "peer_pub": "<base64 peer public key>",
  "client_v4": "172.16.0.2",
  "client_v6": "2606:4700:110::…",
  "client_id": "<base64, 3 bytes → the WireGuard reserved field>",
  "account_id": "…",
  "device_id": "…",
  "token": "<bearer — A SECRET, never log it>",
  "endpoint": "engage.cloudflareclient.com:2408",
  "created_at": "<ISO8601>",
  "license": "<a WARP+ key, or null>",
  "warp_plus": false
}
```

**Its purpose is idempotency.** On a repeated “Get WARP” (`reuse=true`, the default) the account is reused instead of registering a new one; *Re-register* creates a fresh one.

**Secrets.** `priv_key` and `token` are real secrets inside the app's local file. They are masked in logs and in the UI, but deliberately **not** scrubbed in `/state/storage` — see [Debug API exposure](#debug-api-exposure).

**`reserved`.** The `client_id` (base64, 3 bytes) is carried to the sing-box endpoint as a per-peer `reserved: [b0,b1,b2]`. Without it WARP drops the traffic.

CRUD: `getWarpAccount()` / `setWarpAccount(account?)` (null clears it). See [features/025](spec/features/025%20warp%20integration/spec.md).

---

## `masque_account` — [§130]

The cached registered MASQUE-WARP account (Cloudflare's QUIC/CONNECT-IP transport, the flagship of v2.9.0). **A separate key pair** from the WireGuard one.

```jsonc
{
  "priv_key_der":  "<base64 DER — A SECRET, never log it>",
  "server_pub_der":"<base64 DER peer public>",
  "client_v4":     "…",
  "client_v6":     "…",
  "server":        "162.159.198.1",       // data-plane endpoint IP
  "port":          443,
  "device_id":     "…",
  "token":         "<bearer — A SECRET, never log it>",
  "created_at":    "<ISO8601>",
  "sni":           "…",
  "idle_timeout":  "…",
  "keep_alive":    "…"
}
```

**Secrets.** `priv_key_der` and `token` are real secrets in the local file; they are masked in logs (`AppLog`) and in the UI.

**§393 — the `network` key is gone from here.** The HTTP version (`h3`/`h2`) is a property of a node rather than of the registration, and it now lives in the node's `vhttp`.

**Not config-significant** — a MASQUE node reaches the config through an ordinary `UserServer` (a `type:masque` outbound from `MasqueSpec`), so the account itself does not mark the config dirty.

CRUD: `getMasqueAccount()` / `setMasqueAccount(account?)` (null clears it, via `.remove('masque_account')`). It is part of the backup allowlist (`backup_service`).

> **Both of the debts noted here have been settled (§219).** `masque_account` is now present in `SettingsStorage.allowedTopLevelKeys` as well as in `backup_service`, so a backup import no longer drops it. The fact that `GET /state/storage` does not scrub `warp_account` / `masque_account` is a **deliberate decision**, not an oversight: the Debug API grants root access to secrets by design (`GET /backup/export` returns `exportRaw()` verbatim), so masking here would protect nothing while making diagnosis harder. Do not add scrubbing for these keys as a “security fix” — see [Debug API exposure](#debug-api-exposure).

---

## `wifi_history` — [§051] Phase 3

A JSON-encoded array of the networks the user has actually visited, used by the custom-rule editor (`Pick saved` picker) so that Wi-Fi rules can be written without typing an SSID by hand.

```jsonc
[
  {"ssid": "HomeWiFi", "bssid": "aa:bb:cc:dd:ee:ff", "last_seen": "2026-05-10T12:34:56.789Z"},
  {"ssid": "OfficeWiFi", "bssid": "11:22:33:44:55:66", "last_seen": "2026-05-09T08:15:32.000Z"},
  ...
]
```

| Field | Type | Notes |
|---|---|---|
| `ssid` | String | Required. Not normalised (case-sensitive — providers do it both ways). |
| `bssid` | String | May be empty. On upsert it is normalised to **lower case** and trimmed. The composite key is `(ssid, bssid)`. |
| `last_seen` | String (ISO-8601 UTC) | When it was last observed. `addToWifiHistory` refreshes it on upsert. |

**Capped at 50 entries** (the `_wifiHistoryCap` constant). LRU eviction, newest first (inserted at index 0), and the oldest falls off the tail on overflow.

**Where the entries come from:**
1. **Auto-record** (`auto_record_wifi_history=true`) — the native `WifiNetworkObserver` through a `NetworkCallback` listener. A stickiness debounce: the network is recorded only after more than 5 minutes on it.
2. **Manual** — from the editor UI: the `Add current` button (which reads sing-box's `readWIFIState` directly) and `Pick saved` (which picks from existing entries).
3. **The Debug API** — `POST /wifi_history` (for test fixtures, restores and the like) — see the [Debug API reference](api/debug-api-reference.md#wi-fi-history--wifi_history).

CRUD: `getWifiHistory()` / `addToWifiHistory(ssid, bssid)` / `removeFromWifiHistory(ssid, bssid)` / `clearWifiHistory()` in `SettingsStorage`.

**A privacy default** — `auto_record_wifi_history=false`. The user opts in through App Settings → Diagnostics. Silent network logging would be a privacy smell.

**Exposed in `/state/storage` with no scrubbing** — an SSID or BSSID is not sensitive in a settings context (if it is already visible in the rules, hiding it here would achieve nothing).

---

## `native_prefs` — [§189], a mirror of `boxvpn_boot.*`

A JSON mirror of the Android prefs that historically lived **only** in the native
`SharedPreferences` (`boxvpn_boot.*`). The implementation is `lib/services/settings_storage/native_prefs.dart`.

```jsonc
{
  "auto_start":        false,    // auto-start the VPN at boot
  "keep_on_exit":      true,     // §188 — do not kill the tun on a swipe-kill (default ON)
  "background_mode":   "never",  // never | lazy | always — the tunnel's Doze behaviour
  "core_logs_enabled": false,    // forwarding of the sing-box logs into Dart
  "allow_bypass":      false,    // §069 — Allow VPN bypass
  "auto_redirect":     false,    // auto-redirect
  "memory_limit":      "auto"    // §271 — the core's memory limit: auto | off | MB as a string
}
```

**The model is “disk is the truth, memory is a working copy”.** This section of
`lxbox_settings.json` is the **source of truth** (the disk). The native
`SharedPreferences` (`boxvpn_boot.*`) are a **working copy in memory**, needed for the
**Dart-less moments** when the Flutter engine is unavailable: `BOOT_COMPLETED`
(`BootReceiver`), a swipe `onTaskRemoved`, and `openTun` / `establish`. The native side
reads its own copy synchronously and **never writes the JSON** (the single exception is
the bootstrap seed, below).

**The write path is write-through.** Any `setX` writes to the JSON first and then
mirrors into native over the method channel. Every writer — the UI
(`vpn_mode_tab` / `settings_screen` / `app_settings_screen`), the import
(`backup_service`) and the Debug API handlers — goes through the single door
`SettingsStorage.setNativeBool` / `setNativeBackgroundMode` / `setNativeMemoryLimit`
(§271: native applies the limit to the running core immediately through
`Libbox.reloadSetupOptions`). Native writes that bypass this layer are ephemeral: the
`sync` at startup (below) rolls them back on the next launch.

**At startup** (`SettingsStorage.bootstrapAndSyncNativePrefs()`, called from
`main.dart` before the UI):
- if the `native_prefs` section is absent (the first launch after §189) → **bootstrap**:
  seed native ⇒ JSON (the only case of a native⇒JSON write);
- if it is present → **sync**: JSON ⇒ native, so the disk overwrites memory for any
  diverging key and the divergence repairs itself.

**Backup.** The block has one serializer — `SettingsStorage.exportNativePrefsBackup()`
/ `applyNativePrefsBackup()`: the field set, the defaults and the types live in one
place (`native_prefs.dart`). `backup_service` and the Debug handler delegate to it (they
used to duplicate it). The wire keys are stable, so old backups still import. The derived
`has_tun` (below) is **not** part of the backup block — it is a computed value, not a
setting.

> **`has_tun` ([§192]) — a seventh native key, NOT in the JSON section.**
> `boxvpn_boot.has_tun` (default `true`) is **derived** from [`vpn_mode`](#vpn_mode--119)
> (§119): `vpn` and `vpn_proxy` yield `true`, `proxy` yields `false`. It is mirrored when
> the mode changes (`vpn_mode_tab._setMode` → `SettingsStorage.setNativeHasTun`) and at
> startup (`bootstrapAndSyncNativePrefs`). It gates `VpnService.prepare()`: in proxy mode
> `prepare` is never called (it would pointlessly claim the VPN slot and revoke whatever
> VPN is active). The gate sits at six entry points (the `BootReceiver.hasTun(...)`
> check). Being a computed value, it lives only in native (`boxvpn_boot.has_tun`) and is
> **not** stored in the JSON `native_prefs` section — it is recomputed from `vpn_mode`.

> **`app_language` and `last_pushed_locale` ([§279]) — two more native keys NOT in the
> JSON section.** `boxvpn_boot.app_language` is a derived cache of the
> [`vars.app_language`](#vars--template-vars--app-flags) var (the JSON var is the source
> of truth; the cache is re-pushed by `setAppLanguage` and
> `bootstrapAndSyncNativePrefs`); the native surfaces (the notification shade, the QS
> tile, the shortcuts) need it while Flutter is dead. `boxvpn_boot.last_pushed_locale`
> mirrors the last value the app itself pushed into `LocaleManager` (Android 13+) and
> anchors the three-way “system versus storage” reconciliation. Both are a documented
> exception from `NativePrefsKeys`: membership would export them into the backup's
> `vpn_settings` block as a second representation of one setting (the backup home of
> `app_language` is `vars` alone).

---

## `channels` — [§125], the routing channels (template→storage)

The channels (`vpn-1..vpn-10`) moved out of the static `wizard_template.json`
(§267 — `group_templates` plus `default_channels`; before §267 it was `preset_groups[]`)
and into storage. The template became a **seed** — the defaults for the first launch.
After the migration the set of channels lives in `channels[]` and is edited by the user
(Routing → the Channels tab → the channel editor).

- `tag` is the **system's immutable** id (`vpn-1`..`vpn-10`), generated on creation
  (the first free `vpn-N`); the user only edits `label`. It is the stable key for
  references (`route_final`, `ping_options`, a custom rule's outbound, a detour).
  §274 — the `⚙ ` prefix in `label` is reserved as the detour-channel marker (like the
  ⚙ mark in detour server tags): flipping the `detour` flag renames the channel (set →
  `⚙ <label>`, unset → the prefix is stripped), and the normalisation lives in
  `Channel.copyWith` / `fromJson` (covering the editor, the Debug API and restores).
- `vpn-1` is privileged by product decision: always `enabled`, undeletable, and the
  default `route_final`. The channel limit is **10**.
- `auto` (nullable) holds the urltest twin's parameters. `null` means the auto
  checkbox is OFF and `<tag>-auto` is not emitted. `auto.tag` is NOT stored (it is
  derived as `${tag}-auto`). The full shape: `{url, interval, tolerance, idle_timeout,
  interrupt_exist_connections, mode, balancer:{pool, pool_tolerance,
  sticky_hash[]}}`. The §208 fields — `mode` (`least_test` by default, or
  `round_robin`) and `balancer` (`pool` ≥ 1, default 3; `pool_tolerance`, a uint16,
  default 0; `sticky_hash[]` drawn from `process` / `domain` / `source_ip` / `dest_ip` /
  `dest_port`, default `[process,domain]`, with `[]` meaning stickiness off) — are
  **always** serialized into storage, but the builder emits `mode` and `balancer` into
  the core's config **only** for `round_robin` (a `balancer` without round-robin kills
  the core's startup). An empty `sticky_hash` reaches the config as the sentinel
  `["none"]` (stickiness disabled, per the core's SPEC 019 contract).
- `detour` (a bool, default `false` — an absent key reads as false, and there is no
  migration; §248/§274) is **permission** to pick the channel as a detour target for
  servers, folders and subscriptions (the reference value is the `tag`; the §239 picker
  offers only flagged channels). Its role in rules is orthogonal: a flagged channel
  remains a valid target for `route_final` and for a custom rule's outbound (§274
  removed both the mutual exclusion of the roles and the `detour ⇒ include_block=false`
  invariant). The one invariant left: `vpn-1` is never a detour (it is the main channel,
  the default target and the heal reserve) — enforced on read (`Channel.fromJson`), so
  neither a backup restore nor hand-editing the file can get around it.
- **Resolution in the builder**: every enabled channel emits a selector `<tag>` holding
  the nodes that survive `node_filter` (a regex over the final tag, §048 style) plus the
  `direct-out` and `block` options (per `include_direct` / `include_block`, §201); when
  `auto != null` and the node set is non-empty it additionally emits the urltest
  `<tag>-auto` (the channel's nodes only, with no direct/block/auto). `default` is the
  first node whose tag matches `default_filter`. An empty or invalid regex means all
  nodes.
- **Inversion through `node_filter_invert`** (§197): `true` puts into the channel the
  nodes whose tag does **NOT** match `node_filter` (an excluding filter). An empty
  `node_filter` makes the inversion moot (all nodes). Example: `node_filter:"bypass"`
  with `node_filter_invert:true` yields every node except those containing “bypass”.
- **An empty set after filtering** (the regex or the inversion cut everything) yields
  the fallback selector `outbounds: ["block","direct-out"]` with `default: "block"`
  (§201 — blocking is safer than letting traffic out past the VPN; direct stays as an
  option). The builder also writes a warning into the config banner (§200) when the
  subscription did have nodes. `block` is always present in `config.outbounds[]` as a
  system outbound and is valid as a `route_final`.
- **The migration** (one-shot, guarded by `channels_migrated`) seeds from
  `template.groupTemplates` (§267): `default_channels[i].default_enabled` or the legacy
  `enabled_groups[]` become `enabled` (vpn-1 is forced to true); `channel.include ∋
  direct` becomes `include_direct`; `channel.include ∋ auto` becomes `auto` from the
  auto template (the `@urltest_*` vars); and `default_filter` is `''`. The global
  `✨auto` preset is **not** migrated (it is no longer a channel — each channel makes
  its own twin). `enabled_groups[]` is deprecated once the migration has run.
- **Reference degradation** (healing): once a channel stops being a valid target of a
  given kind, references of that kind are healed straight in storage, **irreversibly**
  (§202 decision B, extended by §248 and adjusted by §274). Rule references
  (`route_final`, a custom rule's outbound) become `vpn-1` on deletion or disabling
  (setting the detour flag is NOT a heal trigger — per §274 the channel remains a rule
  target); detour references (`override_detour`, `members[].detour`) become `''` (None)
  on deletion, disabling or clearing the detour flag. A “reference to a channel” is its
  `tag` OR `<tag>-auto`; a value that coincides with the bare tag of a member of the same
  folder is an intra-reference and healing leaves it alone. A backup restore does not
  re-run healing (the degradations are accepted — the builder collapses danglers at build
  time). Legacy `✨auto` references fall under the same rule. Details:
  [`spec/features/248 detour-channels/`](spec/features/248%20detour-channels/).
- CRUD: `getChannels` / `setChannels` / `addChannel` (throws at 10) / `updateChannel` /
  `deleteChannel` (throws for vpn-1) / `migrateChannelsIfNeeded`.
- ⚠ **Mutate through `services/channel_mutations.dart`**, never directly (§275):
  `ChannelMutations.add/update/delete` perform the storage heal and the mirroring resync
  of the controller's in-memory `_entries` as one operation — otherwise the next
  `_persist()` resurrects the healed detour references. `addChannel`, `updateChannel` and
  `deleteChannel` are marked `@visibleForTesting`: calling them from `lib/` past the
  service is an analyze error. `setChannels` is a raw bulk overwrite with no healing (for
  persisting the whole list).

Specs: [`docs/spec/features/125 configurable-channels/`](spec/features/125%20configurable-channels/),
[`docs/spec/features/248 detour-channels/`](spec/features/248%20detour-channels/)
(the detour layer).

---

## Other top-level keys

| Key | Type | Purpose |
|---|---|---|
| `route_final` | `String` | An override of `route.final` on top of the template (the chosen default outbound). `''` means the template default. A dangling reference (a deleted channel, or the legacy ✨auto) becomes `vpn-1` at build time (§125). |
| `route_idle_suspend` | `String` | §215/§128 — the idle-suspend threshold (`route.lx_idle_suspend`, kernel SPEC 020). A duration string (`'30s'` / `'5m'`), **default `'30s'`** (enabled since v2.8.2); `''` means off (the field is not emitted into route). **Config-significant** (`markConfigDirty`). CRUD: `getIdleSuspend` / `saveIdleSuspend`. |
| `excluded_nodes` | `List<String>` | §125 cleanup, **DEPRECATED** — the global node filter (§048) was removed along with its screen. The key stays in the allowlist (harmless legacy debris); the per-channel `node_filter` (§125) covers filtering now. |
| `enabled_groups` | `List<String>` | §125, **DEPRECATED** — replaced by `channels[]`. Read only by the one-shot migration; on disk it is harmless debris. |
| `last_global_update` | `String` (ISO-8601) | The timestamp of the last successful auto-refresh of all subscriptions. |
| `presets_migrated` | `bool` | §159 — the “default presets have been seeded” guard (the fresh-install seed). The key's name is historical (it used to drive a legacy migration) and was reused so that users who had already migrated would not be seeded twice. `RoutingScreen._seedDefaultPresets` sets it to true. |
| `interrupt_connections_on_switch` | `bool` | §143 — tear down the switched group's active connections when the node changes (default `false`, NOT config-significant). See `getInterruptOnSwitch` / `setInterruptOnSwitch`. |
| `node_sort_mode` | `String` | §100 — the chosen node sort mode. `''` means the template default. CRUD: `getNodeSort` / `setNodeSort` (written as a pair with `node_manual_order`). |
| `node_manual_order` | `List<String>` | §100 — the manual order of node tags (relevant in manual mode). Written together with `node_sort_mode`. |
| `profiler_retention_sec` | `int` | §044 — the retention window of the profiler's live journal (the rolling buffer), in seconds. Default `600` (10 minutes), the UI offers 60/600/3600, and valid values are `> 0`. **NOT** config-significant. CRUD: `getProfilerRetentionSec` / `setProfilerRetentionSec`. |
| `route_idle_suspend_reachable` | `String` | §272 — the reachable idle window (`route.lx_idle_suspend_reachable`). A duration string, default `'5m'`. **Config-significant** (`markConfigDirty`). CRUD: `getIdleSuspendReachable` / `saveIdleSuspendReachable`. |
| `urltest_passive_check` | `bool` | §272 — passive health checking (`urltest.passive_check`): skip probes while live traffic already proves the node is alive. Default `true`. **Config-significant**. CRUD: `getPassiveCheck` / `setPassiveCheck`. |

> The structural keys have their own sections above: [`tun_apps`](#tun_apps--046), [`vpn_mode`](#vpn_mode--119), [`warp_account`](#warp_account--025), [`masque_account`](#masque_account--130). Together with this table that is the exhaustive list of current top-level keys in `lxbox_settings.json`. The registry that must match it is `SettingsStorage.allowedTopLevelKeys` (§159 — the allowlist filter for backup import): **a new key belongs in both**, or it survives an export and is silently dropped on restore.

---

## Legacy and removed keys

> **§159 — every migration and DENY `.remove()` is gone.** None of the keys below is
> converted or cleaned up on `_save()` any more. If such a key is still on an older
> user's disk it is harmless (nothing reads it) and will be dropped by the strict
> allowlist (`SettingsStorage.replaceRaw`) on the first backup import. Anyone stuck on a
> prehistoric version with no migration will carry their settings over through an
> export/import, or simply tick the boxes again.

| Key | Lived until | Replacement | Status (§159) |
|---|---|---|---|
| `proxy_sources` | up to v1.3.x | `server_lists` ([§033]) | the migration is gone; the key is ignored. |
| `app_rules` | up to v1.3.2 | `custom_rules` (kind=inline, with `packages`) — [§030] | the migration is gone; the key is ignored. |
| `enabled_rules` | up to [§030] | `custom_rules` | both the migration and the API are gone; the key is ignored. |
| `rule_outbounds` | up to v1.3.2 | `custom_rules.outbound` (or `varsValues.outbound` for a preset) | both the migration and the API are gone; the key is ignored. |
| `dns_options.rules_json` | [§061] (an intermediate step) | `dns_options.rules[]` | the field stays for downgrade friendliness; it is not read. |
| `node_overrides` | removed | — | the DENY cleanup is gone; ignored, and dropped on import. |
| `show_detour_servers` | removed | — | the DENY cleanup is gone; ignored, and dropped on import. |
| `vars.auto_rebuild` | up to §107 | — (a rebuild is always automatic) | the DENY cleanup is gone; dropped on import. |

---

## SharedPreferences (Android)

Not part of `lxbox_settings.json`. It serves two categories: **pre-Flutter boot flags** (read by Kotlin before the engine starts) and **UI preferences** (written by Flutter through `shared_preferences`).

> **§189 — `boxvpn_boot.*` is now a MIRROR, not the original.** The six native prefs
> (`auto_start` / `keep_vpn_on_exit` / `background_mode` / `core_logs_enabled` /
> `allow_bypass` / `auto_redirect`) are a **working copy in memory** for the Dart-less
> moments (boot, a swipe `onTaskRemoved`, `openTun`). **The source of truth is the
> [`native_prefs`](#native_prefs--189-a-mirror-of-boxvpn_boot) section of
> `lxbox_settings.json` (the disk)**: every write is write-through (the JSON first, then
> mirrored into native), and the `sync` at startup (JSON ⇒ native) straightens out any
> divergence. The one exception is the computed `has_tun` ([§192]), which lives only here
> (derived from `vpn_mode` and never stored in the JSON).

> **A note (§159):** `haptic_enabled` used to be listed here by mistake — it actually
> lives in `vars` (`lxbox_settings.json`) and is read and written through
> `SettingsStorage.getVar` / `setVar` (see `HapticService.prefsKey`). It is accounted for
> as an app feature flag in the [`vars`](#vars--template-vars--app-flags) section.

| Key | Type | Source | Spec | Purpose |
|---|---|---|---|---|
| `app_theme_mode` | `"system"` / `"light"` / `"dark"` | Flutter | — | UI theme. |
| `boxvpn_boot.auto_start_vpn` | `Boolean` | Kotlin (mirrors the JSON) | [§189] | Auto-start the VPN at boot (when it was running before). |
| `boxvpn_boot.keep_vpn_on_exit` | `Boolean` | Kotlin (mirrors the JSON) | [§189]/§188 | Do not kill the tun on a swipe-kill. |
| `boxvpn_boot.background_mode` | `String` | Kotlin (mirrors the JSON) | [§189] | The foreground-service mode (`never` / `lazy` / `always`). |
| `boxvpn_boot.core_logs_enabled` | `Boolean` | Kotlin (mirrors the JSON) | [§189], [§043][043-applog] | Forward the sing-box logs into Dart. |
| `boxvpn_boot.allow_bypass` | `Boolean` | Kotlin (mirrors the JSON) | [§189]/§069 | Allow VPN bypass. The truth lives in `native_prefs`. |
| `boxvpn_boot.auto_redirect` | `Boolean` | Kotlin (mirrors the JSON) | [§189] | Auto-redirect. The truth lives in `native_prefs`. |
| `boxvpn_boot.has_tun` | `Boolean` | Kotlin (mirrors `vpn_mode`) | [§192] | **Computed**, default `true`. Gates `VpnService.prepare()`; not stored in the JSON. |
| `boxvpn_boot.app_language` | `String` | Kotlin (mirrors `vars.app_language`) | [§279] | `system` \| `en` \| `ru`. A derived cache for the native surfaces. |
| `boxvpn_boot.last_pushed_locale` | `String` | Kotlin | [§279] | The last value the app itself pushed into `LocaleManager` (Android 13+). |

---

## Debug API exposure

`SettingsStorage.dumpCache()` returns a deep copy of the whole `_cache`. `GET /state/storage` ([§031]) uses it with a scrubber:

- `vars.debug_token` → `'***'`
- `server_lists[].url` is masked (`maskSubscriptionUrl`)
- `server_lists[].nodes` is replaced by `nodes_count` (nodes can carry credentials in a UUID or password)
- `server_lists[].rawBody` is replaced by `raw_body_bytes` (its length)
- `server_lists[].members` is replaced by `members_count` (§234 — a member's raw carries credentials)

The scrubber only handles the `vars` and `server_lists` keys; everything else (`meta.*`, `custom_rules`, `dns_options`, the accounts) is returned as-is.

> **Deliberate, not a debt (§219):** `warp_account` / `masque_account` (`priv_key`, `token`, `priv_key_der`) and `meta.support_url` / `meta.web_page_url` are **not** scrubbed in `GET /state/storage`. The Debug API grants root access to secrets by design — `GET /backup/export` returns `exportRaw()` verbatim — so masking here would protect nothing while making diagnosis harder. Do not add it as a “security fix”.

> **§159 — two DIFFERENT filtering models, deliberately not unified:**
> - **output** (`GET /state/storage`, `serializers/storage.dart`) is a **denylist**
>   with a scrubber: the developer sees everything and only secrets are hidden. A new
>   key is visible automatically.
> - **input** (a backup import, plus the Debug API `POST /backup/import`, through
>   `SettingsStorage.replaceRaw`) is a default-deny **allowlist**: only known keys are
>   written ([`allowedTopLevelKeys`] plus the app flags and the template vars), and
>   anything foreign is dropped. The same applies to `PUT /settings/ping_options`,
>   which strips unknown subkeys.
>
> Different jobs (show everything versus admit nothing foreign) call for different
> models. Do NOT “unify” them by mistake.

`PUT /settings/dns_options/servers` accepts three historical formats (the pre-[§043][043-dns] legacy one, [§043][043-dns] and [§044]) — the migration happens on the next `resolveDnsServersList`. See [`api/debug-api-reference.md`](./api/debug-api-reference.md).

---

[§011]: ./spec/features/011%20local%20ruleset%20cache/spec.md
[§027]: ./spec/features/027%20subscription%20auto%20update/spec.md
[§029]: ./spec/features/029%20haptic%20feedback/spec.md
[§030]: ./spec/features/030%20custom%20routing%20rules/spec.md
[§031]: ./spec/features/031%20debug%20api/spec.md
[§033]: ./spec/features/033%20preset%20bundles/spec.md
[§036]: ./spec/features/036%20update%20check/spec.md
[§037]: ./spec/tasks/037-debug-api-write-config-and-lock-rebuild.md
[§038]: ./spec/features/038%20crash%20diagnostics/spec.md
[§040]: ./spec/tasks/040-per-group-ping-test-settings.md
[§061]: ./spec/tasks/061-dns-rules-refactor/spec.md
[§044]: ./spec/tasks/044-dns-servers-clean-schema.md
[§046]: ./spec/features/046%20tunnel%20apps%20split-tunneling/spec.md
[§117]: ./spec/features/117%20dns-rework/spec.md
[§189]: ./spec/tasks/189-native-prefs-mirror-in-json.md
[§192]: ./spec/tasks/192-proxy-mode-prepare-revokes-foreign-vpn.md
[§279]: ./spec/features/279%20localization/spec.md
[§220]: ./spec/tasks/220-allow-rotation-setting.md
[043-applog]: ./spec/features/043%20applog%20per-source%20quotas/spec.md
[043-dns]: ./spec/tasks/043-dns-servers-refs-by-kind.md
