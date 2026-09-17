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
├─ storage_version               int           §439 — the form of the document; 1 = contract 1.0 records.
│                                                No key = the 2.23.2 form, migrated on the next _load()
│
├─ vars                          object          template-vars override + app feature flags
│   └─ <key>: string                           ─ e.g. log_level, dns_final, debug_token,
│                                                auto_update_subs, last_known_version, ...
│
├─ sources[]                     list          §439 — node sources, then chains, in the user's list order
│   └─ <record>                  object          discriminator: kind (contract 1.0 record + LxBox fields)
│       ├─ kind                  "subscription"|"server"|"folder"|"chain"
│       │                        — subscription (SubscriptionServers) —
│       ├─ id, name, enabled, url
│       ├─ tag_policy            object?       {prefix} — the separator is part of the prefix ("PR ")
│       ├─ identity              object?       §289 — per-sub fetch identity
│       ├─ update                object        {interval_hours}
│       ├─ disabled              map?          §283/§400 — {node identity: unix seconds}
│       ├─ detour                NodeLink?     {folder_id?, tag} — the shared detour of the source
│       ├─ detour_policy         object?       LxBox: the four flags, only when not default
│       ├─ import_rules[], import_rules_enabled, on_update_action     LxBox (§302, §323)
│       ├─ meta, last_updated, last_update_attempt, last_update_status,
│       │  last_node_count, consecutive_fails                         LxBox runtime
│       │                        — server (UserServer) —
│       ├─ id, tag, enabled
│       ├─ origin                object        {kind: uri|wg_ini|json, raw} — the original text, re-parsed on load
│       ├─ detour                NodeLink?     personal detour of the server
│       ├─ sections              object?       §435 — node sections
│       ├─ detour_policy         object?       LxBox: flags, only when not default
│       ├─ tag_policy            object?       LxBox: {prefix}, only when set
│       │                        — folder (FolderServers, §234) —
│       ├─ id, name, enabled, tag_policy?, detour?
│       ├─ detour_policy?, ping_url?, ping_timeout_ms?, created_at    LxBox
│       ├─ nodes[]               list          members in UI order:
│       │   ├─ kind: server      {tag, enabled, origin, detour?, sections?}
│       │   ├─ kind: unsupported {enabled, origin, reason, detour?, sections?} — text that does not parse
│       │   └─ kind: auto        {tag, enabled, group{group_type, members[]?, strategy, members_rule?, pool_badge?}}
│       │                        — chain (SourceChain, §393 C) —
│       ├─ tag, enabled
│       ├─ label                 string?       LxBox display name
│       ├─ body                  object        {type: chain, idle_timeout?, strip_evasion?, strip?, rewrite?}
│       └─ hops[]                list          NodeLinks in packet order
│
├─ rules[]                       list          §030/§439 — route rules, contract 1.0 records
│   └─ <record>                  object          discriminator: kind
│       ├─ kind                  "inline"|"srs"|"preset"
│       ├─ id, name, enabled, num?              num — §370 ordering axis
│       ├─ body                  object?       the sing-box rule (inline, srs); outbound or action: reject
│       ├─ verbatim              true?         inline only — body kept as is (the former kind json, §225)
│       ├─ refs[]                list          srs — rule-set URLs (§434)
│       ├─ update_interval_hours int?          srs — §366 TTL, only when not default
│       ├─ ref, vars             string, object?  preset — preset_id and var overrides
│       ├─ dns                   object?       §117/§256 — {enabled, serverTag, forceIpv4?}
│       └─ resolve               object?       §247 — {only, strategy?, serverTag?, …}
│
├─ dns                           object          §044/§061/§439 — DNS records
│   ├─ servers[]                 list          {kind: user|preset|template, …}
│   └─ rules[]                   list          {kind: user|preset|srs|template, …}
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
├─ enabled_groups[]              list          §125 DEPRECATED — read only by the directions[] migration. Safe debris.
├─ directions[]                  list          §125 — routing directions (template→storage). See below.
│   └─ <item>                    object
│       ├─ tag                   string        §393 — the immutable id AND the only name; any tag (auto 'vpn-N' if omitted); vpn-1 cannot be deleted
│       ├─ label                 string        §405 — the display name ('' falls back to tag); only LxBox applies it, the launcher carries it silently
│       ├─ enabled               bool          on/off (vpn-1 is always true)
│       ├─ include_direct        bool          direct-out as a selector option
│       ├─ include_block         bool          §201 — block (dropping traffic) as a selector option; default false
│       ├─ node_filter           string        a regex over the node's final tag; '' means all
│       ├─ node_filter_invert    bool          §197 — inverts node_filter (the nodes that do NOT match); default false
│       ├─ default_filter        string        a regex; the first match becomes the default; '' means none
│       ├─ include[]             list          §393 — tags of OTHER directions offered as options (only those listed ABOVE are emitted)
│       ├─ interrupt_exist_connections  bool   selector.interrupt_exist_connections
│       └─ auto                  object?       null = the checkbox is OFF; an object yields the urltest twin <tag>-auto (its tag is derived)
│           ├─ url               string        urltest test endpoint
│           ├─ interval          string        duration ("5m")
│           ├─ tolerance         int           ms, uint16 (§161 — clamp 0..65535)
│           ├─ idle_timeout      string        duration ("30m")
│           ├─ interrupt_exist_connections  bool  urltest.interrupt_exist_connections
│           ├─ mode              string        §208 — 'least_test' (default) | 'round_robin'
│           └─ balancer          object{3 keys}  §208 — {pool, pool_tolerance, sticky_hash[]}
├─ directions_migrated           bool          §125/§393 — the guard for the one-shot directions migration
├─ last_global_update            ISO-8601      the timestamp of the last auto-refresh
├─ presets_migrated              bool          §159 — the "default presets have been seeded" guard (fresh-install seed)
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

# §439 — the 2.23.2 keys (server_lists / chains / custom_rules / dns_options) and the
# keys with no readers (excluded_nodes / preset_ids_remapped / proxy_sources /
# app_rules / enabled_rules / rule_outbounds / node_overrides / show_detour_servers /
# vars.auto_rebuild; channels / channels_migrated are renamed) are converted or
# removed by the storage migration, once. See "Storage form and migration" below.
```

Every key is described in detail in the sections below.

## Disk layout

Every path is relative to the **Android internal documents directory** (`getApplicationDocumentsDirectory()`). On a device that directory is unreachable without root or the Debug API (`GET /state/storage`).

```
getApplicationDocumentsDirectory()/         # Android: Context.getDir("flutter") = app_flutter/
├── lxbox_settings.json                     # [workspace]
├── lxbox_settings.json.bak                 # [device] the previous file, written by _atomicSave
├── lxbox_settings.json.v0.bak              # [device] §439 — the original 2.23.2-form file, copied once before the migration
├── rule_sets/                              # [workspace]
│   ├── <ruleId>.srs
│   └── <ruleId>.meta.json                  # §366 sidecar
├── workspaces.json                         # §417 — the workspace manifest: current, slots, pending
├── workspaces/                             # §417 — saved workspaces, one folder per name
│   └── <name>/
│       ├── lxbox_settings.json
│       ├── lxbox_settings.json.v0.bak      # §439 — the slot's 2.23.2-form original, copied on its first Load
│       ├── rule_sets/
│       └── sub_cache/
├── support_state.json                      # [device] §356
├── applog.txt                              # [device]
└── corelog.txt                             # [device]

Context.filesDir/                           # native `files/` = Dart getApplicationSupportDirectory();
├── singbox_config.json                     #   NOT the documents dir above (§414); rebuilt after a workspace load
├── cache.db                                # libbox cache_file (basePath = filesDir); [device], rebuilt by the core
├── tailscale/<name>/                       # [device] §435/§445 — tsnet state of one Tailscale node (machine/node keys, login)
├── tailscale_state.json                    # [device] §445 — index: workspace → node key → directory name in tailscale/
└── sub_cache/                              # [workspace] HttpCache — the raw subscription bodies (§027/§129)
    ├── <url.hashCode>
    └── <url.hashCode>.headers

Android SharedPreferences:
├── Flutter prefs                # app_theme_mode, haptic_enabled, …
└── boxvpn_boot.*                # pre-Flutter boot flags
```

`[workspace]` — part of a saved workspace (§417): copied into `workspaces/<name>/` on Save as and back on Load. `[device]` — stays with the device, never copied.

| File / directory | Written by | What is inside | Spec |
|---|---|---|---|
| `workspaces.json` | `WorkspaceStore` (Dart) | The workspace manifest: `current` (the name of the workspace on the working paths), `slots[]` (`name`, `saved_at`), `pending` (a journal of an unfinished load — replayed on the next start). Absent until the first Save as. | [§417] |
| `workspaces/<name>/` | `WorkspaceStore` (Dart) | A saved workspace: a copy of `lxbox_settings.json`, `rule_sets/` and `sub_cache/`. Not `singbox_config.json` (rebuilt after a load) and not `cache.db` (open under a running core; the core rebuilds it). | [§417] |
| `lxbox_settings.json` | `SettingsStorage` (Dart) | App settings, vars, sources, rules, DNS, ping. **The main subject of this document.** | — |
| `lxbox_settings.json.v0.bak` | `SettingsStorage` (Dart) | §439 — the bytes of the 2.23.2-form file as they were before the storage migration. Written once (never overwritten), kept while the app is installed, not part of a workspace or a backup. `GET /backup/export?include=storage&from=v0_bak` returns it for downgrade tests. | [§439] |
| `singbox_config.json` | `ConfigManager` (Kotlin) | The final sing-box JSON fed to libbox. Regenerated on every `buildConfig`. Not part of a backup. Lives in native `Context.filesDir` (`files/`), not in the documents dir — Dart reaches it via `BoxVpnClient.getFilesDir()` (§316/§414). | [§414] |
| `tailscale/<name>/` | the core (tsnet) | The state directory of one Tailscale node: `tailscaled.state` (machine and node keys, login), logs. Created by the core on the node's first start; the path comes from `state_directory`, which the build sets from `tailscale_state.json`. Deleted with the node (while the core is stopped) and when no workspace references it. Not part of a workspace copy or a backup. | [§435], [§445] |
| `tailscale_state.json` | `TailscaleStateStore` (Dart) | The index of Tailscale state directories: `slots` (workspace name → node key → directory name; the key is the server `id`, or the folder/subscription `id` + the raw tag), `legacy` (directories found when the index was created, kept while a workspace has no records). Renaming or moving a node rewrites the key, the directory name never changes. Save as copies a workspace's records, Delete drops them. Not part of a workspace copy or a backup. | [§445] |
| `sub_cache/<url.hashCode>` + `.headers` | `HttpCache` (Dart) | The raw body and headers of a subscription, for the offline rehydrate at startup. **The only persisted source of subscription nodes** — `nodes` is not stored, it is re-parsed from here on every launch. Lives in native `files/` (Dart App Support), not in the documents dir. | [§027], [§129] |
| `rule_sets/<ruleId>.srs` + `.meta.json` | `RuleSetDownloader` (Dart) | A cache of binary `.srs` rule-set files plus the §366 sidecar (`lastUpdated`, `etag`, `lastError`). The config references them by absolute path; the core never downloads them itself. | [§011] |
| `applog.txt` | `AppLog` (Dart) | The app-side warn/error log, JSON lines, a ring buffer of 200 lines / 64 KB. | [§038], [§043][043-applog] |
| `corelog.txt` | `AppLog` (Dart) | The sing-box warn/error log. Lines arrive from Kotlin over `EventChannel lxbox/coreLog` (`BoxService.coreLogDrainer`, in `List<String>` batches); `ClashLogPump` (a legacy name — NOT the Clash API, which was removed in §122) receives them and `AppLog.add(source: core)` writes them here through the same ring-buffer mechanism as `applog.txt`. TRACE and DEBUG are filtered out on the native side. 200 lines / 64 KB. | [§043][043-applog] |
| Android `SharedPreferences` | Kotlin (`BoxApplication`) plus Flutter (`shared_preferences`) | Pre-Flutter boot flags and UI prefs. See the [“SharedPreferences”](#sharedpreferences-android) section below. | — |

---

## `lxbox_settings.json` — top-level

```jsonc
{
  "storage_version":    1,         // §439 — the form of the document (no key = the 2.23.2 form)
  "vars":               { … },     // Map<String,String>
  "sources":            [ … ],     // §439 — subscription / server / folder records, then chain records
  "rules":              [ … ],     // §439 — route rule records: inline / srs / preset
  "dns":                { … },     // §439 — {servers[], rules[]} records
  "ping_options":       { … },
  "route_final":        "<tag>",   // override route.final
  "route_idle_suspend": "30s",     // §215/§128 — idle-suspend threshold (default "30s"; "" = off)
  "enabled_groups":     [ … ],     // §125 DEPRECATED (read only by the directions[] migration)
  "directions":         [ … ],     // §125 — routing directions (template→storage)
  "directions_migrated": true,     // §125/§393 — the guard for the one-shot directions migration
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

The in-memory cache is `SettingsStorage._cache` (lazily loaded). Writes are atomic through `JsonEncoder.withIndent('  ')`. §159 — on `_save()` nothing is removed: the input filter is the allowlist on backup import, and the only conversion of old keys is the storage migration inside `_load()` (§439, next section).

The per-key specs and shapes are in the sections below.

---

## Storage form and migration (§439)

`lxbox_settings.json` keeps node sources, chains, route rules and DNS records as
**contract 1.0 records** — the same records the LX Backup 1.0 file carries
(`contract/docs/ONE_NAMESPACE.md` §1, `BACKUP.md` §2). A record is the contract's
fields plus LxBox fields next to them (`import_rules`, `detour_policy`, `ping_url`,
`label`, `verbatim`, …). One codec reads and writes them for storage, the LX Backup,
the rules file and the Debug API: `lib/models/codec/` (`source_record.dart`,
`chain_record.dart`, `rule_record.dart`, `dns_record.dart`, `auto_group_record.dart`,
`node_link_record.dart`; `lib/models/record_codec.dart` re-exports them). The key
names live in `lib/services/settings_storage_keys.dart`.

Layers (§439 §2.5): the file layer (`settings_storage.dart`, `storage_migration/`)
reads and writes the document; the codec maps model ↔ record and is tolerant on
read; models are immutable values; repositories (`settings_storage/<entity>.dart`)
give typed get/save per entity and keep the invariants between records (the rule
axis, DNS references, the node-link registry); everything above — the builder,
screens, backup, Debug API — works on models only.

**LX Backup 1.0 is a slice of these records** (`lib/services/lx_backup_slice.dart`, one
table per record key). Contract fields travel. LxBox fields that are user settings
travel too: contract 1.0.1 declares them in `BACKUP.md` §2 "LxBox-side fields"
(`detour_policy`, `import_rules`, `import_rules_enabled`, `on_update_action` of a
subscription; `detour_policy`, `tag_policy` of a server; `detour_policy`, `ping_url`,
`ping_timeout_ms` of a folder; `label` of a chain; `group.members_rule`,
`group.pool_badge` of an auto node; `update_interval_hours` of an srs rule; `verbatim`;
`description` and `vars` of a DNS server). The launcher ignores them silently; the
LxBox import applies them, and a file without such a field does not reset the value of
a matching record. Runtime (`meta`, `last_*`, `consecutive_fails` of a subscription,
`created_at` of a folder, the node cache) is cut silently. Named losses
(`backup_local_only_dropped`) are left for a DNS rule of `kind: srs` and a JSON rule
whose text never parsed (`verbatim` without `body`); `kind: template` DNS rules are not
written. A key missing from the table is cut and named, so a new codec field
cannot leave or get lost silently.

### What changed against the 2.23.2 form

| 2.23.2 | 2.23.3 |
|---|---|
| `server_lists[]` with `type: subscription\|user\|folder` | `sources[]` with `kind: subscription\|server\|folder` |
| `chains[]` with `order` | `kind: chain` records at the tail of `sources[]`; the place is the record index |
| `custom_rules[]`, matchers in camelCase (`domainSuffixes`, `srsUrl`, `presetId`, `varsValues`) | `rules[]`, `body` with sing-box keys, `refs[]`, `ref`, `vars` |
| rule `kind: json` with the text in `json` | `kind: inline` + `verbatim: true`, the object in `body`; a JSON array is split into one record per object (`name`, `name #2`, …) |
| `dns_options{servers[], rules[], rules_json}` | `dns{servers[], rules[]}`; `rules_json` removed |
| DNS `kind: inline` with `rule` / `varValues` / preset `tag` | `kind: user` with `body` / `vars` / preset `ref: "<preset_id>:<tag>"` |
| `tag_prefix: "PR"` | `tag_policy: {prefix: "PR "}` — one trailing space added on write, exactly one removed on read |
| `raw_body` string of a server, `raw` of a folder member | `origin{kind: uri\|wg_ini\|json, raw}` plus `tag` of the parsed node |
| `members[]` of a folder | `nodes[]` with `kind: server\|unsupported\|auto` |
| folder member `raw: "autogroup://…"` | `kind: auto` record with `group{group_type: urltest, members[], strategy}` |
| `disabled_hashes{identity: ISO-8601}` | `disabled{identity: unix seconds}` |
| `detour_policy.override_detour`, member `detour`, chain `hops[]` — final config tags as strings | `detour` / `hops[]` as NodeLinks `{folder_id?, tag}` |
| — | `storage_version: 1` |

Not written any more: `name` of a server (empty since §243), `origin` of a server
(`paste|file|qr|manual`, write-only diagnostics), `created_at` of a server.

### Migration in `_load()`

The marker is `storage_version`. A document without it, or with any of the 2.23.2
keys (`server_lists`, `chains`, `custom_rules`, `dns_options`), or with a folder
member `autogroup://…` (early 2.23.3 builds), is migrated inside `_load()`
(`settings_storage/io.dart`) right after the main file or `.bak` is parsed. App
start, a workspace load (`clearCache` → `_load`) and tests all pass through it.

1. `presetIdByDnsServerTag` from the template; a template load error does not stop
   the migration — preset DNS servers get `ref` = tag.
2. `migrateStorageDoc` (`storage_migration/migrate_storage.dart`, a pure function):
   the frozen 2.23.2 readers (`legacy_form_v0.dart`) → models → the record codec;
   node references → NodeLinks (`migrate_node_links.dart`, below); `autogroup://`
   members → `kind: auto` records (`migrateAutogroupMembers`); keys with no readers
   removed; `channels`/`channels_migrated` renamed to `directions`/`directions_migrated`
   when the new names are absent; `storage_version: 1`.
3. A copy of the original bytes goes to `lxbox_settings.json.v0.bak` — only when there
   is no copy yet (tmp + rename; the first original is never overwritten).
4. The new document is written by `_atomicSave` (§072); `.bak` then holds the old file.
5. One info line in AppLog; losses (unreadable records, unreadable json rules,
   non-numeric ports, DNS shapes older than §044) as a warning with names.

`configDirty` is not raised: the migration does not change `config.json`. The golden
tests (`test/storage_migration/golden_config_test.dart`) build the config from two
2.23.2 fixtures before and after the migration and compare bytes.

| Crash | On disk | Next start |
|---|---|---|
| before step 3 | old file | migrates again |
| between 3 and 4 | old file + `.v0.bak` | migrates again, the copy is kept |
| inside the rename of step 4 | old or new file | migrates again, or nothing |
| after step 4 | new file, `.bak` = old file | nothing; a broken main file restores `.bak` of the old form and migrates it |

Idempotent: a document with `storage_version: 1` and no legacy keys is not touched.
A document with both the version and 2.23.2 keys (2.23.2 installed over 2.23.3 data
with `adb install -r -d`) keeps its `sources`/`rules`/`dns` records and drops the
2.23.2 keys with a warning. A version higher than known is read as the current form,
unknown top-level keys are kept, an error goes to AppLog.

**Node references (`migrate_node_links.dart`).** Resolved against the state before
the migration: a detour inside a folder onto the tag of an enabled member becomes a
pair `{folder_id, tag}`; otherwise the final tag is looked up in a dictionary built
by the same node assembly as the builder (prefixes, unique tags, subscription nodes
from `sub_cache`); outside the dictionary the "prefix + tag" form is matched across
containers when exactly one candidate exists. Targets on disabled sources (a disabled
server, a member of a disabled folder, a node of a disabled subscription) are looked up
by the tags the build would give them once enabled, so they are not dangling.
Directions, `direct-out`, template service tags and chains stay root `{tag}`. Not found
or ambiguous — root `{tag}` with a warning. A member's detour onto a neighbour written
with the folder prefix (`EU de-1`, a hand edit) and the bare tag the 2.23.2 UI wrote
(`de-1`) become the same pair; 2.23.2 did not count the prefixed form as a folder chain
link (§239), so after the migration the neighbour leaves Direction groups by the
folder's register flags (an accepted config difference, §439 §6.6). A personal detour
onto the node itself and the edge that closed a ring inside a folder (2.23.2 did not
emit them) are removed with a warning.

**Autogroup members.** `RuleMembers` are kept; explicit members keyed by
`protocol|server|port|credential` become pairs by the nodes of the same folder (among
namesakes by key — the single enabled one). A key without a node, an ambiguous key, a
node without a tag or with a namesake tag, unreadable group text — warning, the
member is removed.

### Workspaces (§417)

A slot keeps its own copy of `lxbox_settings.json`. On Load, before the slot is copied
onto the scene, `WorkspaceStore` copies a slot file without `storage_version` to
`workspaces/<name>/lxbox_settings.json.v0.bak` (only when there is no copy); the scene
then migrates in `_load()`. The copy is not in `kSlotEntries` and never reaches the
scene. Sleeping slots are not migrated until loaded; Save as writes the new form.

### Inputs of the old form

| Input | Behaviour |
|---|---|
| `lxbox_settings.json` on disk | migration in `_load()` |
| a workspace slot | migration on Load plus a `.v0.bak` copy in the slot folder |
| internal backup (`app: lxbox`, `kind: backup`) from 2.23.2 or older | `BackupService` migrates the `storage` block before the category filter; the preview counts the migrated block |
| Debug `POST /backup/import` with a `storage` block without `storage_version` | migrated; `applied.migrated: true` and `applied.migration {info, warnings}` in the response; node references use the same dictionary as `_load()` (below the table) |
| LX Backup `lx_backup: 1` (0.x) | the legacy 0.x decoder, as before |
| rules file `kind: rules`, `format: 1` (§396) | the frozen readers of `legacy_form_v0.dart`; export writes `format: 2` |
| Debug `PUT /settings/dns_options/servers` and `/rules` | records only; the 2.23.2 kind refs and the pre-§043 full body → 400 with a sample record |

The internal backup restore, `POST /backup/import` and `replaceRaw` migrate node
references with the same dictionary as `_load()`: subscription bodies come from
`sub_cache` (`SettingsStorage.subscriptionBodiesForMigration`). Without them a chain
position on a subscription node stayed a root link, and the chain dropped out of the
config.

### Downgrade to 2.23.2

Android does not install a lower versionCode over an installed app, and uninstalling
removes the app data together with `.v0.bak`. For a user a downgrade is a clean
2.23.2 plus a restore from a file.

| Scenario | Result |
|---|---|
| clean 2.23.2 + internal backup made on 2.23.2 or older | restores as before |
| clean 2.23.2 + internal backup made on 2.23.3 | the 2.23.2 allowlist drops `sources`, `rules`, `dns`, `storage_version`: no sources, chains, rules or DNS records; directions, `vars`, WARP accounts and modes survive |
| clean 2.23.2 + LX Backup 1.0 or rules file `format: 2` | refused as newer than supported |
| 2.23.2 over 2.23.3 data (`adb install -r -d`) | empty source list, no rules, DNS re-seeded from the template; 2.23.2 leaves the 2.23.3 keys in the file. Back on 2.23.3 the document has both the version and 2.23.2 keys: the 2.23.2 keys are dropped, the records stay |

For test benches: `GET /backup/export?include=storage&from=v0_bak` returns `.v0.bak`
(the state at migration) in the internal backup envelope, which 2.23.2 accepts through
`POST /backup/import`. There is no UI button for it.

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
| `dns_final` | template | [§043][043-dns] | The final DNS resolver (`cloudflare_udp` / `google_udp` / `local_dns_resolver` / `yandex_udp`, or any tag from `dns.servers`). |
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

A full replace (`replaceRaw` with `merge=false`: backup restore in Replace mode, `POST /backup/import`) keeps some device keys from the current storage when the incoming `vars` lack them: `debug_enabled` / `debug_token` / `debug_port` (§413, `SettingsStorage.debugApiVarKeys`) and the one-shot startup prompt flags `wizard_battery_v1`, `wizard_addtile_v1`, `wizard_update_check_v1`, `notif_perm_prompted_v1` (§447, `SettingsStorage.startupPromptVarKeys`). The `wizard_*` keys are not in the import allowlist, so a file never brings them.

`removeVar(k)` is not the same as `setVar(k, '')` — an empty string can be a legitimate value, while an absent key falls back to the default.

---

## `sources` — [§033], §439: node sources and chains

The list of sources in the order the user sees them: subscriptions, standalone servers
and folders, then chains (see [`sources[]` — `kind: chain`](#chains--kind-chain-in-sources-393-c-spec-110)).
Before §439 the same data lived under `server_lists` (sealed on `type`) and `chains`;
the migration converts them once (see [Storage form and migration](#storage-form-and-migration-439)).

The discriminator is `kind`. The record is read by `sourceFromRecord` /
`chainFromRecord` (`lib/models/codec/`). Reading is tolerant: a link given as a
string is a root link, a record with `body` and no `origin` (the launcher's form) is
read as a JSON outbound with the record's `tag`, unknown keys are collected by path,
and anything read not verbatim (a record `tag` that differs from the parsed text, a
dropped member or section record) is a note in AppLog. A record without `kind` or
`id` is skipped.

The repositories: `settings_storage/sources_rules.dart` rewrites the part without
chains (`saveServerLists`), `settings_storage/chains.dart` the chain part
(`setChains`); neither touches the other part of the array.

### `kind: "subscription"` — `SubscriptionServers`

```jsonc
{
  "kind":                  "subscription",
  "id":                    "<uuid>",          // stable
  "name":                  "<display>",
  "enabled":               true,
  "url":                   "https://…",       // an online subscription. §129: a file
                                              // subscription becomes "file:<uuid>" (the
                                              // node snapshot lives in HttpCache under
                                              // that key; not a path, no access retained)
  "tag_policy":            { "prefix": "PR " }, // written only when a prefix is set; the
                                              // separator is part of the prefix (contract
                                              // form). The model keeps "PR": one trailing
                                              // space is added on write and exactly one is
                                              // removed on read, so a prefix with spaces set
                                              // through the Debug API survives.
  "identity": {                               // §289 — a per-sub override of the fetch
    "user_agent": "MyPanel/1.0",              // identity. Optional: absent means Default
    "send_hwid": true,                        // mode (the global SubscriptionIdentity).
    "hwid": "550e8400-...",                   // An object means Custom mode: the fetch uses
    "device_os": "android",                   // ONLY these values. Empty strings (user_agent/
    "ver_os": "14",                           // hwid/device_*) are not serialized.
    "device_model": "Pixel 7"
  },
  "update": { "interval_hours": 24 },         // always written. §129 special values: -1 = never
                                              // (ignore the server header; set automatically
                                              // for file: subscriptions), 0 = not on a
                                              // schedule, but the server's interval is
                                              // honoured, N>0 = every N h. AutoUpdater skips
                                              // an interval ≤ 0. Absent on read = 24.
  "disabled": {                               // §283/§400 — per-node disable (not written when
    "NL-42": 1784368800                       // empty). The key is the node's IDENTITY (contract
  },                                          // 0.10.0): the raw provider tag, made unique within
                                              // the source (first X, then X-2, X-3; the counter is
                                              // per-source and shared with the source's groups,
                                              // which take their names after all nodes; the tag
                                              // is taken BEFORE tag_policy). A group node (§322)
                                              // and a node with an empty tag have no identity and
                                              // cannot be disabled per-node. Node content (server,
                                              // port, credentials, SNI, transport) is NOT part of
                                              // it: a provider rotating the address under the same
                                              // name keeps the mark, renaming the node loses it.
                                              // The value is lastSeen in unix seconds for the TTL
                                              // GC (clamp(3×interval, 24 h, a month)) on a
                                              // successful refresh. A key that is 64 lowercase hex
                                              // is a legacy content hash written before §400: on
                                              // the source's first parse it migrates onto the
                                              // matching node's identity or is dropped.
  "detour":                { "tag": "vpn-2" }, // the shared detour of the source, a NodeLink
                                              // (see "Node references" below); absent = none
  "detour_policy": {                          // LxBox. Written only when a flag differs from
    "register_detour_servers": false,         // the default; see "detour_policy" below
    "register_detour_in_auto": false,
    "use_detour_servers":      true,
    "replace_detour_chain":    false
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
      "action": "disable"                     // DISABLE marks the node → its identity (§400: the
    },                                        // tag, which a Replace patch does not touch) is put
    {                                         // into disabled on every refresh (rule > TTL GC).
      "conditions": [
        {"path": "", "op": "matches", "pattern": ".*"}
      ],                                      // §332 — ENABLE clears the mark from disabled,
      "action": "enable"                      // INCLUDING a manual one (§283). Order matters: the
    }                                         // last enable/disable that fires wins, so an
  ],                                          // enable-everything first is a reset before new
                                              // filters, while disable-everything plus enable-NL
                                              // is an allowlist.
                                              // The legacy flat {action, pattern, is_regex?, ...}
                                              // is read as a condition on tag (replace gains
                                              // substitute semantics); the first save rewrites it.
  "import_rules_enabled": false,              // §302 — the set's toggle; written ONLY when false.
  "on_update_action":      "reload",          // §323 — what to do after a SUCCESSFUL auto update:
                                              // "rebuild" (the default, key not written), "reload"
                                              // (plus an in-place core reload, a ~3 s gap), "none"
                                              // (the node list only). The manual ⟳ is not governed
                                              // by this.
  // LxBox runtime of the machine — written only when not default:
  "meta":                  { … },             // SubscriptionMeta from the HTTP headers, see below
  "last_updated":          "ISO-8601",        // on success
  "last_update_attempt":   "ISO-8601",        // any attempt
  "last_update_status":    "ok",              // never|ok|failed|inProgress; "never" is not written
  "last_node_count":       12,
  "consecutive_fails":     0                  // for the UI's "(N fails)"; freezing is in-memory
}
```

The `nodes` of a subscription are **not stored**: they are re-parsed from `sub_cache/`
(the raw body, §027/§129) on every launch.

### `kind: "server"` — `UserServer`

```jsonc
{
  "kind":          "server",
  "id":            "<uuid>",
  "tag":           "Tokyo",                   // the tag of the parsed node (the first one, when the
                                              // text holds several — records before §368). Written for
                                              // the contract; NOT applied on read: the node is re-parsed
                                              // from origin.raw and the text wins, a mismatch is a note.
  "enabled":       true,
  "origin":        { "kind": "uri", "raw": "vless://…#Tokyo" },
                                              // the original input, byte for byte. kind is derived from
                                              // the text: a JSON object → json, a WG INI → wg_ini,
                                              // anything else → uri. The node is re-parsed from raw on load.
  "detour":        { "tag": "vpn-2" },        // personal detour, a NodeLink; absent = none
  "sections":      { … },                     // §435 — optional, see “Node sections” below
  "detour_policy": { … },                     // LxBox, only when a flag is not default
  "tag_policy":    { "prefix": "Home " }      // LxBox, only when set. The prefix is part of the
                                              // server's root address: changing it rewrites the
                                              // links that point at the server.
}
```

`name` (empty since §243), the `origin` of the model (`paste|file|qr|manual`) and
`created_at` are not written.

**`origin.kind: json` is a build mode (§455).** A server (or folder member)
whose source is a JSON object goes into the config **verbatim**: the source
object itself, not the model's re-emission — the same rule the launcher applies
to a manual object. The model still parses it for the form, the list, the
identity and the warnings, but its gates do not run; the gate is the core
(`Libbox.checkConfig`) at Save in the node editor. `body` is a cache derived
from `origin.raw` and is **not written** for servers; a `body` found in an
imported backup is ignored and the node is re-parsed from `origin.raw`
(BACKUP §9 p.2). No flag: the kind is derived from the text, so replacing the
source with a JSON object (the editor's "Edit JSON" button) is what switches
the mode, and pasting a link back switches it off.

#### Node sections (§435, contract ## 13)

A free node (a `kind: server` record or a folder member) may carry the config fragment it
needs — route rules and DNS records — in `sections`. The record form is the contract's
form (ONE_NAMESPACE.md §2): **record = app metadata + `body` = the sing-box object
as is**, the same records as the root `rules[]` and `dns{}`. The `@self` / `@{self}`
placeholders stay in storage verbatim; the final node tag is substituted at build time
and when displayed.

```jsonc
"sections": {
  "rules": [                                   // only kind inline | srs
    { "kind": "inline", "id": "<uuid>", "name": "@{self} network", "enabled": true, "num": 945,
      "body": { "domain_suffix": [".ts.net"],
                "ip_cidr": ["100.64.0.0/10", "fd7a:115c:a1e0::/48"], "outbound": "@self" },
      "resolve": { "only": false, "serverTag": "@{self}-dns" } }
  ],
  "dns": {
    "servers": [                               // only kind user (tag in metadata, body without tag)
      { "kind": "user", "tag": "@{self}-dns", "enabled": true,
        "body": { "type": "tailscale", "endpoint": "@self" } }
    ],
    "rules": [                                 // only kind user
      { "kind": "user", "name": "", "enabled": true,
        "body": { "domain_suffix": [".ts.net"], "server": "@{self}-dns" } }
    ]
  }
}
```

`resolve` (§437) is app metadata, not part of `body`: at build time it emits a
non-terminal `action: resolve` rule with the node's own DNS server right before the route
rule, so a name resolved to a FakeIP address still reaches the node and a UDP flow gets an
address before routing.

Empty sections are not written. A foreign `kind` inside a section is dropped on read
(the rest of the records survive). `lib/models/node_sections.dart` holds the model. The
LX Backup (contract 1.0, `lx_backup: 2`, [§438]) carries them as `sources[].sections` of
the node, in this same form. On import, records the section may not hold are dropped
with `backup_section_record_dropped`, and a node matched by body takes the file's
`sections` wholesale when the field is present. A legacy 0.12 file's `servers[].sections`
is ignored silently.

### `kind: "folder"` — `FolderServers` (§234)

A folder of manual servers: a container of members sharing one toggle, `tag_policy` and
detour. A subscription cannot be put into a folder, and there is no nesting.

```jsonc
{
  "kind":            "folder",
  "id":              "<uuid>",
  "name":            "<display>",
  "enabled":         true,                      // the toggle for the whole folder
  "tag_policy":      { "prefix": "F " },
  "detour":          { "tag": "vpn-2" },        // the folder's shared detour, a NodeLink
  "detour_policy":   { … },                     // LxBox, only when not default
  "ping_url":        "<url>",                   // LxBox, §284 — an optional override of the test URL
  "ping_timeout_ms": 3000,                      // LxBox, §284 — an optional override of the timeout
  "created_at":      "ISO-8601",                // LxBox; returned by Debug API /folders
  "nodes": [                                    // the order here is the order in the UI
    { "kind": "server", "tag": "Alpha", "enabled": true,
      "origin": { "kind": "uri", "raw": "vless://…#Alpha" },
      "detour": { "folder_id": "<this folder id>", "tag": "Jump" } },  // §237 — personal detour
    { "kind": "server", "tag": "Beta", "enabled": false,
      "origin": { "kind": "wg_ini", "raw": "[Interface]\n…" } },       // per-member toggle
    { "kind": "unsupported", "enabled": true,
      "origin": { "kind": "uri", "raw": "foo://…" },
      "reason": "the member text does not parse into a node" },         // visible in the UI, editable
    { "kind": "server", "tag": "ts", "enabled": true,
      "origin": { "kind": "json", "raw": "{\"type\":\"tailscale\",…}" },
      "sections": { … } },                                               // §435 — node sections
    { "kind": "auto", "tag": "Auto", "enabled": true,                    // §322 — autoselect node
      "group": {
        "group_type": "urltest",
        "members": [ { "folder_id": "<this folder id>", "tag": "Alpha" } ],
        "strategy": { "mode": "least_test", "url": "…", "interval": "15m", "tolerance": 50,
                      "idle_timeout": "30m", "interrupt_exist_connections": false },
        "pool_badge": "…" } }                                            // LxBox, inside group, only when not default
  ]
}
```

`ping_url` and `ping_timeout_ms` (§284) are **the folder's own test options**, and they
override the global `ping_options` when Test is pressed inside the folder. When absent,
the global value is used. The “WARP GENERATOR” folder puts an IP URL here
(`1.1.1.1/cdn-cgi/trace`) — a test by IP, with no DNS.

A member's `origin.raw` is a self-contained parseable fragment (a URI, a WG INI or an
outbound JSON); the nodes are reconstructed by re-parsing each text on load, as for a
server. On read the member `kind` does not decide anything (`server` and `unsupported`
read the same way: the text wins). In memory `nodes` holds only the enabled members, so
the builder needs no folder-specific branching.

**`kind: auto`** (§322, §439 track N2) — an autoselect node inside the folder.
`group.group_type` is always `urltest` on write; `strategy` has the shape of a
direction's `auto` (`$defs/directionAuto`: `mode`, `url`, `interval`, `tolerance`,
`idle_timeout`, `interrupt_exist_connections`, and `pool` / `pool_tolerance` /
`sticky_hash` for `round_robin` or when not default; an empty sticky list is written as
`["none"]`). Explicit membership is `group.members[]` — NodeLink pairs onto members of
the same folder. Membership by rule is `group.members_rule: {include, exclude}`
(regexes, not links); such a group has no `members`. `members_rule` and `pool_badge`
are LxBox-side fields inside `group` (contract 1.0.1, `BACKUP.md` §2); early 2.23.3
builds wrote them next to `group`, and that form is still read silently (`group` wins).
A non-empty `group.members` wins over `members_rule`. Tolerant read: a member `{tag}`
becomes a pair with the folder's id; `default` as a string becomes a pair when exactly
one member has that tag (a LxBox urltest group has no `default`, it is named as a loss);
`selector` is read as `urltest`, and the LX Backup import names it
`backup_group_degraded`. Before §439 the group was stored as the member text
`autogroup://…`; the migration converts it, and the URI form is gone. An `autogroup://`
member of a legacy 0.x backup file is imported as a group by the same conversion
(`storage_migration/legacy_autogroup.dart`); a key that matches no member (or several
enabled ones) is removed from the group with `backup_group_degraded`.
A folder member of `kind: chain` is not supported and is dropped with a note.

### `detour_policy` (shared)

```jsonc
{
  "register_detour_servers":  false,
  "register_detour_in_auto":  false,
  "use_detour_servers":       true,
  "replace_detour_chain":     false            // §178 — false appends the detour as a tail, true replaces the whole chain
}
```

Written only when a flag differs from the default. The detour target itself is the
record's `detour` (a NodeLink), the model field `DetourPolicy.overrideDetour`.

### Node references — NodeLink (§439, D-112)

A reference to a node is `{folder_id?, tag}` (`lib/models/node_link.dart`,
`contract/docs/NODE_LINK.md`), never a final config tag. Carriers: `detour` of a
subscription, server or folder (`DetourPolicy.overrideDetour`), `detour` of a folder
member (`FolderMember.detour`), `hops[]` of a chain (`SourceChain.hops`) and
`group.members[]` of a `kind: auto` member.

| Target | Link |
|---|---|
| a folder member | `{folder_id: <folder id>, tag: <raw tag before tag_policy>}` |
| a subscription node or a subscription group | `{folder_id: <subscription id>, tag: <raw tag>}` |
| a standalone server | `{tag: <its final tag>}` |
| a direction, `direct-out`, a template service tag, another chain | `{tag}` |

- **Resolve** only at build, in a second pass once every source has final tags
  (`services/builder/node_link_resolve.dart`): `byFolder[id][raw tag]` for folders and
  subscriptions, root nodes, root names (directions and their `-auto`, service outbounds,
  chains). Screens build the same pool (`node_link_pool.dart`) to show final tags.
- **Fail-closed.** A detour that does not resolve, points at the node itself, or loops
  drops its carrier from the config with a warning, and the drop cascades to nodes that
  went through it; it never becomes a direct connection. A chain position that does not
  resolve drops the whole chain.
- **The registry** (`settings_storage/node_link_registry.dart`, one for all carriers):
  a rename (body edit), a move between containers, moving out of a folder, dissolving a
  folder, reordering namesakes and a change of a standalone server's prefix **rewrite**
  the links; deleting a node or a whole source **clears** them (the detour is removed,
  the position leaves the chain, the member leaves the auto node) and the Servers screen
  names the affected sources, chains and auto nodes in one SnackBar, group members
  counted apart from detours. A change of a folder's `tag_policy` or name does not
  change any address.
- **Tolerant read** on foreign inputs (the LX Backup import, the Debug API): S1 — a root
  `{tag}` inside a container onto its member becomes a pair; S3 — a pair carrying a
  group's final tag becomes its raw tag when exactly one candidate exists. Storage does
  not apply them: a root link onto a namesake of a member is legal.

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

---

## `rules` — [§030], §439: route rules (inline / srs / preset)

Contract 1.0 records: metadata plus `body` — the sing-box rule as is. Before §439 the
list was `custom_rules` with camelCase matcher keys. Codec: `ruleToRecord` /
`ruleFromRecord` (`lib/models/codec/rule_record.dart`); on the storage path an inline
record whose body the model cannot express is read as a verbatim rule, not truncated.
Strings (`id`, `name`) are not trimmed: the name of an srs rule is the `rule_set` tag in
the config.

**The shared `num` field ([§370])** is the rule's position on a sparse ordering axis.
All kinds carry it. The layout: `0` is the head (`traffic-processing`), `950..990` are
the specific presets, `1000..1100` is the user-rule zone, and `1110..1150` are the broad
catch-alls; the step of 10 between template rules leaves room for future insertions (see
`ui.num` in TEMPLATE.md).

When the key is **absent**, the rule has not been numbered yet. Numbering happens on the
first load of the Routing screen (`markRuleOrder`): a preset takes its `num` from the
template by preset id, `traffic-processing` gets `0`, and everything else is numbered
consecutively from `1000` in the array's current order.

The rule order is a sort by `num` (ties keep the array's order). Dragging in the UI
recomputes the dragged rule's `num` as `target.num + 1`, shifting the neighbours only
when that value is taken (a lazy shift — it preserves the gaps and the template
anchors, see `rule_order.dart`).

### `kind: "inline"` — `CustomRuleInline`

```jsonc
{
  "kind":    "inline",
  "id":      "<uuid>",
  "name":    "<display>",
  "enabled": true,
  "num":     1000,                  // §370 — the position on the ordering axis
  "body": {
    "domain":           [ … ],      // OR group #1 (full match)
    "domain_suffix":    [ … ],
    "domain_keyword":   [ … ],
    "ip_cidr":          [ … ],
    "port":             [ 443 ],    // OR group #2: numbers (non-numeric ports are dropped)
    "port_range":       [ "8000:9000" ],
    "package_name":     [ … ],      // OR group #3
    "protocol":         [ … ],      // routing-rule level (subset of kKnownProtocols)
    "network":          [ "udp" ],
    "ip_is_private":    true,       // routing-rule level
    "source_ip_cidr":   [ … ],
    "source_ip_is_private": true,
    "inbound":          [ … ],
    "wifi_ssid":        [ … ],
    "wifi_bssid":       [ … ],
    "outbound":         "<tag>"     // or "action": "reject" instead of outbound
  },
  "dns":     { "enabled": true, "serverTag": "<dns-server tag>", "forceIpv4": true },  // §117 task 3 + §256
  "resolve": { "only": false, "strategy": "ipv4_only", "serverTag": "",
               "disableCache": true, "disableOptimisticCache": true,
               "rewriteTtl": 60, "timeout": "5s", "clientSubnet": "…" }                 // §247
}
```

Only non-empty matchers are written. `name` is user-supplied and mutable.

OR semantics inside a category, AND between them. `protocol` and `ip_is_private` are not made headless — they are lifted to the routing-rule level.

`dns` ([§117] task 3, “DNS follows the rule”) is optional: the builder emits a mirror DNS rule `{rule_set: <the same headless one>, server: serverTag}` inside an atomic mirror group (ordered like the routing rules). Absent → the old behaviour. The gate: with non-empty `port` or `protocol` the mirror is not emitted.

`dns.forceIpv4` ([§256], Force IPv4) is optional: it suppresses AAAA (IPv6) for the rule's match through a serverless rule `{rule_set|match, ip_version: 6, action: predefined, rcode: NOERROR}` (so the app cleanly takes the A record). It is **orthogonal** to `enabled` and `serverTag` — the suppressor answers locally and needs no DNS server, so a rule may carry `forceIpv4` alone (`enabled: false`, `serverTag: ""`). It is emitted BEFORE the server mirror (the §253 order). The same port/protocol gate applies (the DNS layer is blind to port and protocol).

`resolve` ([§247]) is optional: the builder emits a non-terminal route rule `{rule_set: <the same headless one>, action: resolve, …}` either BEFORE the terminal route (`only: false`, the flagship case — forcing `ipv4_only` for direct branches) or INSTEAD of it (`only: true`, an advanced fall-through). The gate: for inline rules it is emitted only when the domain group is non-empty (`resolveEligible`); for srs it is always emitted, since a `.srs` may contain domains.

#### `verbatim: true` — a raw sing-box rule (§225)

```jsonc
{ "kind": "inline", "id": "<uuid>", "name": "raw", "enabled": true, "num": 1001,
  "verbatim": true, "body": { "action": "sniff", "inbound": ["tun-in"] } }
```

The former rule kind `json` (the model `CustomRuleJson`). The body goes to the config as
is: `method: drop`, actions other than `reject`, logical rules, `rule_set` in the body.
One record holds **one** object: a JSON array is split before the codec into one record
per object (`name`, `name #2`, …; the first keeps `id`, `enabled` and `num` are shared),
and the rule editor refuses to save an array. Text that does not parse into an object is
kept as `verbatim: true` without `body` (the build skips it; the text itself is in
`.v0.bak` when it came from 2.23.2).

### `kind: "srs"` — `CustomRuleSrs`

```jsonc
{
  "kind":    "srs",
  "id":      "<uuid>",
  "name":    "<display>",
  "enabled": true,
  "num":     1010,
  "refs":    [ "https://…/a.srs", "https://…/b.srs" ],   // §434 — all rule sets, always a list
  "update_interval_hours": 24,                           // §366 — TTL, written only when not default
  "body": {                                              // no domain matchers — they are in the .srs
    "port": [ … ], "port_range": [ … ], "package_name": [ … ], "protocol": [ … ],
    "network": [ … ], "ip_is_private": true, "wifi_ssid": [ … ], "outbound": "<tag>"
  },
  "dns":     { … },                                      // §117 task 3 + §256
  "resolve": { … }                                       // §247 (as for inline)
}
```

The `.srs` binary itself lives separately in `rule_sets/<id>.srs` (see the [file table](#disk-layout) above).

`refs` ([§434], contract ## 12 / D-100): one rule may carry several rule sets.
The builder registers a `rule_set` per URL (tags `<name>`, `<name>-2`, …) and emits
one route rule with the list of tags; a single URL still emits a string tag. Each URL
has its own cache file: index 0 is `rule_sets/<id>.srs`, index i is
`rule_sets/<id>~<i>.srs`, with its own `.meta.json`. The rule counts as downloaded only
when every file is cached; a partial download keeps the rule off. A legacy 0.12 backup
carries `rules[].ref` (first) plus `rules[].refs` (all, only with 2+), and the importer
reads `refs` before `ref`.

`dns` ([§117] task 3) works as it does for inline, except the mirror references an existing `.srs` tag plus the DNS-safe extra filters (`package_name` and wifi). It only works when the rule set contains domains — an IP-only list never matches in a DNS context.

### `kind: "preset"` — `CustomRulePreset`

```jsonc
{
  "kind":    "preset",
  "id":      "<uuid>",
  "name":    "<display, snapshot of preset.label>",
  "enabled": true,
  "num":     960,
  "ref":     "<preset_id from the template>",
  "vars":    { "<varName>": "<value>", "outbound": "<tag>" }
}
```

`name` is read-only in the UI (🔒) and is periodically synced with `preset.label` from the template. The contents are expanded on every `buildConfig` through `expandPreset` ([§033]). `outbound` is kept in `vars['outbound']` as a universal override ([§033] Expansion §5).

> **§265 — ref-var values do NOT live in `vars`.** When a preset declares a var
> as `{"ref":"<global>"}` (for example `traffic-processing` → `resolve_enabled` /
> `resolve_strategy`), its value lives in the **global** `vars` (top level,
> `setVar` / `getAllVars`) and NOT in the preset's `vars` — one source, so that
> editing it in the rule and in the owning section cannot diverge. The preset's `vars`
> must not contain ref names; `stripRefVarsFromVarsValues`
> (`normalize_pinned_presets.dart`) clears out stuck copies when Routing loads
> (otherwise the subtitle and Debug showed a stale value — `366beec`). See the
> “ref-vars” section of TEMPLATE.md.

### Backward-compat

The 2.23.2 form (`custom_rules`, camelCase keys, `srsUrl` + `srsUrls`, `presetId`,
`varsValues`, `kind: json`, the `target` alias of `outbound`, an absent `kind` = inline) is
read only by the frozen readers of `storage_migration/legacy_form_v0.dart`: the storage
migration and the rules file `format: 1`.

---

## `dns` — [§044], [§061], §439: DNS servers and rules

```jsonc
{
  "servers": [ <server record>, … ],
  "rules":   [ <rule record>,   … ]
}
```

Records of the contract 1.0 dictionary (`lib/models/codec/dns_record.dart`), typed by
the models `DnsServerRef` {inline·preset·template} and `DnsRuleRef`
{inline·srs·preset·template} (`lib/models/dns_ref.dart`). Every consumer — the
resolvers, the builder, the DNS screens, the backup — reads the models through
`settings_storage/network.dart`, not raw maps. Before §439 the key was `dns_options` with
the model's own words (`inline`, `rule`, `presetId`, `varValues`) and a dead `rules_json`.

### `dns.servers[i]`

```jsonc
{ "kind": "user", "tag": "my-doh", "enabled": true,
  "body": { "type": "https", "server": "1.1.1.1" },     // a partial sing-box server WITHOUT tag
  "description": "…" }                                  // optional

{ "kind": "preset", "ref": "ru-direct:yandex_udp", "enabled": true }   // "<preset_id>:<tag inside the preset>"

{ "kind": "template", "tag": "google_doh", "enabled": true,
  "vars": { "<name>": "<value>" } }                      // §117 — the chosen var values
```

- `template` — a reference to a server from the template ([§117]: a `{vars, server}` wrapper, with the tag in `server.tag`). The user can override `enabled` and `description` and choose var values (`vars`: the `outbound` direction, the IP profile, the domain resolver — see TEMPLATE.md); the body is resolved from the template by substituting the `@var`s (`resolveTemplateDnsServerBody`).
- `preset` — a server declared by a template preset. The identity is `ref` = `<preset_id>:<tag inside the preset>`, split on the first `:`; that string is also the server's config tag (the builder namespaces preset tags, `namespacePresetTags`) and the model's `tag`, so `ref` and tag are one string. Auto-discovery fills the preset id when the server is added; a `ref` without `:` (the preset was not found) is the tag, and orphan cleanup follows. A repeated namespace written by early 2.23.3 builds (`ru-direct:ru-direct:dns_ru`) is read as `ru-direct:dns_ru` and never written.
- `user` — a user-defined server (the model's `inline`). `body` is required.

The tag lives **only** at the record level; the builder synthesizes `body.tag` back when assembling the config. **Render order in the UI:** `template` → `preset` → `user`.

### `dns.rules[i]`

```jsonc
{ "kind": "user", "name": "corp", "enabled": true,
  "body": { "domain_suffix": [".corp"], "server": "my-doh" } }   // the sing-box rule; enabled always written

{ "kind": "preset", "ref": "<preset_id>", "enabled": true }

{ "kind": "srs", "name": "<rule-set tag>", "id": "<uuid>",       // an LxBox kind
  "srsUrl": "https://…", "server": "<dns tag>", "rule": { … }, "body": { … }, "enabled": false }

{ "kind": "template", "name": "<template rule name>", "enabled": true }  // an LxBox kind
```

`template` rules — orphan cleanup: when the name is not found in the active template, the entry is discarded in `resolveDnsRulesList`. A `template` record without `enabled` reads as off. `srs` writes `enabled` only when false.

§439: the resolvers keep records of every kind. Before, `resolveDnsRulesList` dropped
`kind: user` as a §033 leftover and `resolveDnsServersList` dropped unknown kinds, and
both saved the result. Two build fixes came with the move to models: a user rule without
an `enabled` key is emitted, and an srs DNS rule reaches the config.

⚠ §257: on a `kind: preset` rule record the `enabled` field is **dead**: the toggle for a
preset's DNS block moved to the magic var `dns_enable`
(`rules[].vars` of the preset rule, see “Magic variables” in TEMPLATE.md). The entry
remains only as a **positional anchor** for the mirror group (§117) — it decides
where the preset's DNS rules sit inside `dns.rules`. Neither the builder nor the UI
reads its `enabled`; auto-discovery keeps writing `enabled: true`, harmlessly.

### Migration history

- v1.5.x: `dns_options.rules_json` — a single JSON string (`@Deprecated`), ignored since §061.
- v1.6.0 ([§061]): `dns_options.rules[]` — a structured list.
- v1.6.0 ([§043][043-dns]): `dns_options.servers[]` — the first kind refs. Back then tag, description and enabled lived inside `body`.
- v1.6.1 ([§044]): `dns_options.servers[]` — the clean schema. Tag, description and enabled were lifted to the ref level.
- v1.7.x ([§117]): template servers inside the template became `{description, enabled, vars?, server}` wrappers, and the `kind: template` ref gained `varValues`.
- §294: the kind refs typed by `DnsServerRef` / `DnsRuleRef`; the on-disk shape unchanged.
- §228/§229: remapping renamed `preset_id`s inside `custom_rules` (`bittorrent-direct`→`bittorrent`, `private-ip-direct`→`private-ip`, `block_unknown`→`unknown-traffic`); the migration was removed in §229.
- 2.23.3 ([§439]): `dns{servers, rules}` in the contract 1.0 dictionary; `rules_json` removed; the migration of pre-§044 server shapes (`_migrateLegacyDnsServers`) removed — the storage migration drops such records with a warning.

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

**The keys of `groups` are direction tags — [§408] holds them to living ones.** A key
counts as living when a direction with that `tag` exists (in any state, enabled or not)
or when it is that direction's urltest twin `<tag>-auto` — the same reading of "a
reference to a direction" the other heals use (§248). The UI only ever writes a plain
selector tag (the ping dialog keys the map by `state.selectedGroup`, which comes from
`selectorGroupTags` — selectors only, so never a chain and never a twin), but
`PUT /settings/ping_options/groups/{tag}` does not validate the tag and a hand-edited
backup carries whatever it carries.

The invariant is kept at two points:

- **Deleting a direction** drops its key and its `<tag>-auto` key in the same
  transaction that heals the other four kinds of reference (`route_final` and a rule's
  `outbound`, the detour references, `include[]`, the chain positions) — one write to
  disk. Unlike those four, the drop is **not** reported back to the user: they change the
  route, this only changes how the nodes of a direction that no longer exists were being
  measured. **Disabling** a direction and clearing its detour flag leave the override
  alone, exactly as they leave `include[]` alone (§393 A3): disabling is reversible,
  and switching the direction back on must return what was there.
- **Loading the set of directions** prunes orphans — any key with no living tag behind
  it. It runs inside `migrateDirectionsIfNeeded`, which every load path goes through
  (app start, an internal backup restore, `/backup/import`), for the same reason the
  "`vpn-1` exists" invariant lives there. There is no separate one-shot with its own
  guard on purpose: a restored archive brings `ping_options` back whole (it is in the
  §221 allowlist), and a guarded one-shot would have run once, before the restore, and
  never again. No ordering hazard: `directions` and `ping_options` share the one storage
  file and one `_load()`, so the set of directions is already final when the prune reads
  it.

Whenever the last key goes, the `groups` container goes with it rather than staying `{}`
— `ping_options` reaches the backup and `/state/storage`, where an empty container would
read as "there were per-direction overrides and they were all reset" rather than the
plain truth that there never were any.

**A `groups` entry travels in the portable backup too — [§409].** It rides inside the
direction it belongs to, as `directions[].ping_url` / `directions[].ping_timeout_ms`
(contract 0.12.6, declared in the schema and applied by LxBox only; the launcher carries
them silently). A missing key means there is no override; an empty URL or a
non-positive timeout is never written. Not to be confused with `auto.url` /
`auto.idle_timeout` of the same record: those configure the kernel's urltest twin, these
are the app's own measuring budget. On import the fields land in `groups[tag]` only for
directions the file actually **created** — a record whose tag is taken is skipped whole
(`backup_direction_exists`), and its budget is skipped with it, so a file never rewrites
the settings of a direction it did not create. The global `url` / `timeout_ms` are not
part of this: they are an app setting, and their home in the portable format is `vars`.

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

**Interaction with `package_name` rules in `rules`:** apps in the allow list (or outside the deny list) go through the tun and are then subject to the routing rules; apps outside the tun never reach sing-box at all, so no rule can affect them.

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

## `directions` — [§125], the routing directions (template→storage)

The directions moved out of the static `wizard_template.json`
(§267 — `group_templates` plus `default_directions`; before §267 it was `preset_groups[]`)
and into storage. The template became a **seed** — the defaults for the first launch.
After the migration the set of directions lives in `directions[]` and is edited by the user
(Routing → the Directions tab → the direction editor).

- `tag` is the **immutable** id. It is generated on creation (the first free `vpn-N`) or
  supplied by the user — §393 lifted the fixed `vpn-1..vpn-10` vocabulary, so any tag is
  accepted as long as it is non-empty, not reserved (`direct-out`, `block`, `dns-out`…),
  not already taken and not colliding with an existing `<tag>-auto` twin (the rejection
  carries a machine reason: `empty` | `reserved` | `duplicate` | `auto_twin`).
  The user only edits `label`. The tag is the stable key for
  references (`route_final`, `ping_options`, a custom rule's outbound, a detour), which is
  exactly why it is read-only after creation; renaming a direction means changing its
  `label`. §405 — `label` is declared in the backup schema and
  **only LxBox applies it** (the "Support" column of the contract's `docs/BACKUP.md` §2, D-094):
  the launcher has no second name for a direction, so it neither applies the key nor
  warns about it — it carries it through silently.
  §274 — the `⚙ ` prefix in `label` is reserved as the detour-direction marker (like the
  ⚙ mark in detour server tags): flipping the `detour` flag renames the direction (set →
  `⚙ <label>`, unset → the prefix is stripped), and the normalisation lives in
  `Direction.copyWith` / `fromJson` (covering the editor, the Debug API and restores).
- `vpn-1` is privileged by product decision: always `enabled`, undeletable, and the
  default `route_final`. §393 removed the cap: there is **no limit** on the number of
  directions.
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
  migration; §248/§274) is **permission** to pick the direction as a detour target for
  servers, folders and subscriptions (the reference value is the `tag`; the §239 picker
  offers only flagged directions). Its role in rules is orthogonal: a flagged direction
  remains a valid target for `route_final` and for a custom rule's outbound (§274
  removed both the mutual exclusion of the roles and the `detour ⇒ include_block=false`
  invariant). The one invariant left: `vpn-1` is never a detour (it is the main direction,
  the default target and the heal reserve) — enforced on read (`Direction.fromJson`), so
  neither a backup restore nor hand-editing the file can get around it.
- **Resolution in the builder**: every enabled direction emits a selector `<tag>` holding
  the nodes that survive `node_filter` (a regex over the final tag, §048 style) plus the
  `direct-out` and `block` options (per `include_direct` / `include_block`, §201); when
  `auto != null` and the node set is non-empty it additionally emits the urltest
  `<tag>-auto` (the direction's nodes only, with no direct/block/auto). `default` is the
  first node whose tag matches `default_filter`. An empty or invalid regex means all
  nodes.
- **Inversion through `node_filter_invert`** (§197): `true` puts into the direction the
  nodes whose tag does **NOT** match `node_filter` (an excluding filter). An empty
  `node_filter` makes the inversion moot (all nodes). Example: `node_filter:"bypass"`
  with `node_filter_invert:true` yields every node except those containing “bypass”.
- **An empty set after filtering** (the regex or the inversion cut everything) yields
  the fallback selector `outbounds: ["block","direct-out"]` with `default: "block"`
  (§201 — blocking is safer than letting traffic out past the VPN; direct stays as an
  option). The builder also writes a warning into the config banner (§200) when the
  subscription did have nodes. `block` is always present in `config.outbounds[]` as a
  system outbound and is valid as a `route_final`.
- **The migration** (one-shot, guarded by `directions_migrated`) seeds from
  `template.groupTemplates` (§267): `default_directions[i].default_enabled` or the legacy
  `enabled_groups[]` become `enabled` (vpn-1 is forced to true); `direction.include ∋
  direct` becomes `include_direct`; `direction.include ∋ auto` becomes `auto` from the
  auto template (the `@urltest_*` vars); and `default_filter` is `''`. The global
  `✨auto` preset is **not** migrated (it is no longer a direction — each direction makes
  its own twin). `enabled_groups[]` is deprecated once the migration has run.
- **§393 A2 — the key rename.** The list used to live under `channels` with the guard
  `channels_migrated`. Since §439 the rename belongs to the storage migration
  (`migrateStorageDoc`): on the file in `_load()` and on the import boundaries (internal
  backup, Debug API `/backup/import`) before `replaceRaw`, `channels` /
  `channels_migrated` become `directions` / `directions_migrated` when the new names are
  absent (the new name wins; a legacy pair next to a list sets the guard). The merge-upsert
  then collides on the single `directions` name and the archive wins over live data. The
  legacy pair is **not** in any allowlist. `migrateDirectionsIfNeeded` has three
  branches: `directions` present → no-op; `directions_migrated == true` with no list →
  migrated-and-empty, stamp the marker but do **not** re-seed; otherwise → seed from the
  template. `applyImport` still runs it right after `replaceRaw` — it covers the
  fresh-seed case when the archive carried no directions at all. Export writes the new
  names only.
- **Reference degradation** (healing): once a direction stops being a valid target of a
  given kind, references of that kind are healed straight in storage, **irreversibly**
  (§202 decision B, extended by §248 and adjusted by §274). Rule references
  (`route_final`, a custom rule's outbound) become `vpn-1` on deletion or disabling
  (setting the detour flag is NOT a heal trigger — per §274 the direction remains a rule
  target); detour references (`detour` of a source or a folder member) are removed (None)
  on deletion, disabling or clearing the detour flag. A “reference to a direction” is a
  root link `{tag}` with its `tag` OR `<tag>-auto`; a pair `{folder_id, tag}` addresses a
  node of a container and is never a direction (D-112), so healing leaves it alone. A backup restore does not
  re-run healing (the degradations are accepted — the builder collapses danglers at build
  time). Legacy `✨auto` references fall under the same rule. Details:
  [`spec/features/248 detour-channels/`](spec/features/248%20detour-channels/).
- CRUD: `getDirections` / `setDirections` / `addDirection` / `updateDirection` /
  `deleteDirection` (throws for vpn-1) / `migrateDirectionsIfNeeded`.
- ⚠ **Mutate through `services/direction_mutations.dart`**, never directly (§275):
  `DirectionMutations.add/update/delete` perform the storage heal and the mirroring resync
  of the controller's in-memory `_entries` as one operation — otherwise the next
  `_persist()` resurrects the healed detour references. `addDirection`, `updateDirection`
  and `deleteDirection` are marked `@visibleForTesting`: calling them from `lib/` past the
  service is an analyze error. `setDirections` is a raw bulk overwrite with no healing
  (for persisting the whole list).

Specs: [`docs/spec/features/125 configurable-channels/`](spec/features/125%20configurable-channels/),
[`docs/spec/features/248 detour-channels/`](spec/features/248%20detour-channels/)
(the detour layer).

---

## Chains — `kind: chain` in `sources[]` (§393 C, SPEC 110)

A chain is a **source** — the same kind of thing as a subscription or a standalone
server, not a direction. It holds an explicit route (`you → hop 1 → hop 2 → …`)
and is emitted as one outbound of type `chain`. The model is `SourceChain`
(`models/source_chain.dart`); the record codec is `codec/chain_record.dart`.

```jsonc
{
  "kind":    "chain",
  "tag":     "chain-1",
  "enabled": true,
  "label":   "Work",                                     // LxBox, only when set
  "body":    { "type": "chain", "idle_timeout": "5m", "strip_evasion": false,
               "strip": { "tls.fragment": true }, "rewrite": { … } },
  "hops":    [ { "folder_id": "<subscription id>", "tag": "NL-1" }, { "tag": "Tokyo" } ]
}
```

Chain records sit at the **tail** of `sources[]`, after subscriptions, servers and
folders, in their own order (BACKUP §4: the record order is normative). There is no
separate key and no position field: before §439 the list was `chains[]` with an `order`
index into the common source list, and the migration placed the records by that order.

- `tag` — the future outbound's tag, and the record's id. **Immutable** after
  creation, like `Direction.tag`: direction filters, `route_final` and the
  positions of *other* chains reference it. A tag is validated against **both**
  chains and directions — two outbounds sharing a tag kill the config.
- `label` — display name; empty falls back to `tag` (inventing a name for a chain
  the user did not name would lie about its contents). §405 — applied **only by
  LxBox**.
- `enabled` — a disabled chain is neither emitted nor pooled, like a disabled
  subscription. A reference to it from another chain degrades **that whole chain**
  (`chain_hop_missing`): a route missing a hop is a different route.
- `hops` — NodeLinks (see [Node references](#node-references--nodelink-439-d-112)) **in
  packet order**: `[0]` is the first hop from the client, the last one is the address
  the destination sees. This is deliberately **not** “who goes through whom” —
  `detour`'s arrow points the other way, and confusing the two builds a *working but
  wrong* route (SPEC 110 T3), a mistake the user only notices by geolocation. A
  position may be a node, a subscription group, a direction, a template service tag,
  or **another chain** — the latter only at position 0 and only one declared **above**
  in the list; that ordering is what rules out cycles between chains.
  The core's invariants (`protocol/chain/chain.go`): at least two positions,
  non-empty, no duplicates, no self-reference. Breaking **any** of them stops the
  **whole config** from starting, not just the one chain — hence `chainEmitError`
  checks them and a chain that fails is not emitted at all. A position that does not
  resolve at build drops the chain too.
- `body.idle_timeout` — how long a link with no live connections survives. Empty = the
  core's default (5m), `"0s"` = live until shutdown.
- `body.strip_evasion` — whether to strip one-sided DPI-evasion tricks off the links.
  Nullable for **tristate**, not for decoration: absent = the core's default (true),
  `false` = the user turned it off explicitly (the key is written). A plain bool could
  not tell the two apart, and an explicit “off” would silently become “default” if the
  core ever flipped its default.
- `body.strip` — a targeted patch on top of `strip_evasion`: `false` = do not strip,
  `true` = strip additionally. Keys only from `kChainStripKeys`
  (`tls.fragment`, `multiplex.padding`, `xhttp.padding`, `tls.utls`).
- `body.rewrite` — a JSON merge-patch (RFC 7396) over a node's options, keyed by
  outbound type, applied to links (position 1 onwards) after `strip`. **Not editable
  through the form and not meant to be**: a reduced form would silently drop an
  arbitrary patch across every protocol type. A `null` inside the patch **deletes** the
  key (RFC 7396), so it is stored and round-trips verbatim, with no “empty cleanup”.

The invariant “a position may reference only a chain **above**” is computed over the
mutual order of chains: dragging a subscription between two chains is legal and breaks
no reference. The Servers screen draws chains after the controller's records, where
they lie.

**Core requirement**: `type: chain` needs sing-box-lx **v1.14.0-lx.27** or newer.

**Heal on deletion**: deleting a node or a source removes its **positions** from every
chain that used them through the node-link registry, and the Servers screen names the
affected chains — a route that silently got shorter must be noticed. A chain that drops
below two positions is not emitted until repaired. Deleting a chain on the Servers
screen removes its positions from other chains (§393 D2); `DELETE /chains/{tag}` in the
Debug API does not and lists them in `dangling_refs`. A subscription refresh never
touches positions.

**In backup**: the LX Backup 1.0 ([§438], §439) carries the record as is, `label`
included: it is an LxBox-side field declared by contract 1.0.1 (`BACKUP.md` §2), the
launcher ignores it, and a file without it does not reset the label of a matching
chain. Chains merge by `tag`; a local chain wins over an arriving namesake,
with a warning. A legacy 0.12 file carries a root `chains[]` section (contract 0.7.1).

---

## Other top-level keys

| Key | Type | Purpose |
|---|---|---|
| `route_final` | `String` | An override of `route.final` on top of the template (the chosen default outbound). `''` means the template default. A dangling reference (a deleted direction, or the legacy ✨auto) becomes `vpn-1` at build time (§125). |
| `route_idle_suspend` | `String` | §215/§128 — the idle-suspend threshold (`route.lx_idle_suspend`, kernel SPEC 020). A duration string (`'30s'` / `'5m'`), **default `'30s'`** (enabled since v2.8.2); `''` means off (the field is not emitted into route). **Config-significant** (`markConfigDirty`). CRUD: `getIdleSuspend` / `saveIdleSuspend`. |
| `enabled_groups` | `List<String>` | §125, **DEPRECATED** — replaced by `directions[]`. Read only by the one-shot migration; on disk it is harmless debris. |
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

> **§159 — no migration on `_save()`, no DENY `.remove()`.** Keys from older versions
> are not converted on write. **§439** — the storage migration inside `_load()` runs once
> per document without `storage_version`: it converts the 2.23.2 keys, renames
> `channels`, and deletes the keys with no readers listed below. The strict allowlist
> (`SettingsStorage.replaceRaw`) drops anything else foreign on a backup import.

**The 2.23.2 form — converted by the storage migration (§439):**

| Key | Lived until | Replacement |
|---|---|---|
| `server_lists` | 2.23.2 | `sources[]` records `kind: subscription\|server\|folder` |
| `chains` | 2.23.2 | `kind: chain` records at the tail of `sources[]` |
| `custom_rules` | 2.23.2 | `rules[]` |
| `dns_options` | 2.23.2 | `dns{servers, rules}` |
| `channels`, `channels_migrated` | §393 A2 | `directions`, `directions_migrated` |

**Keys with no readers — deleted by the storage migration (§439):**

| Key | Lived until | Replacement |
|---|---|---|
| `dns_options.rules_json` | [§061] (an intermediate step) | `dns.rules[]` |
| `excluded_nodes` | §125 cleanup | the per-direction `node_filter` |
| `preset_ids_remapped` | §228 guard, migration removed in §229 | — |
| `proxy_sources` | up to v1.3.x | `sources` ([§033]) |
| `app_rules` | up to v1.3.2 | `rules` (kind=inline, with `package_name`) — [§030] |
| `enabled_rules` | up to [§030] | `rules` |
| `rule_outbounds` | up to v1.3.2 | `body.outbound` of a rule (or `vars.outbound` for a preset) |
| `node_overrides` | removed | — |
| `show_detour_servers` | removed | — |
| `vars.auto_rebuild` | up to §107 | — (a rebuild is always automatic) |

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
- `sources[]` (§439) are read into models by the repository and written back by the record codec, with secrets replaced in place:
  - `url` of a subscription is masked (`maskSubscriptionUrl`)
  - `origin.raw` of a server is replaced by `origin.raw_bytes` (its length; an inline URI carries credentials)
  - `nodes[]` of a folder is replaced by `nodes_count` (§234 — a member's text carries credentials)
  - chain records go as they are (no secrets)
  - a record the repository cannot read is not in the dump: there is nothing to hide its secret with

The scrubber only handles the `vars` and `sources` keys; everything else (`meta.*`, `rules`, `dns`, the accounts) is returned as-is. Before §439 the scrubber looked for a `rawBody` key that storage never had (it was `raw_body`), so the length of a standalone server was not hidden.

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

`PUT /settings/dns_options/servers` and `PUT /settings/dns_options/rules` accept only `dns{}` records of the contract 1.0 form (§439); the 2.23.2 kind refs (`kind: inline`, `varValues`, `presetId`, `rule`) and the pre-[§043][043-dns] full body return 400 with a sample record and leave storage untouched. The URL paths keep the old name: they are API addresses, not file keys. See [`api/debug-api-reference.md`](./api/debug-api-reference.md).

---

[§011]: ./spec/features/011%20local%20ruleset%20cache/spec.md
[§027]: ./spec/features/027%20subscription%20auto%20update/spec.md
[§414]: ./spec/tasks/414-config-dirty-check-files-dir.md
[§029]: ./spec/features/029%20haptic%20feedback/spec.md
[§030]: ./spec/features/030%20custom%20routing%20rules/spec.md
[§031]: ./spec/features/031%20debug%20api/spec.md
[§033]: ./spec/features/033%20preset%20bundles/spec.md
[§036]: ./spec/features/036%20update%20check/spec.md
[§037]: ./spec/tasks/037-debug-api-write-config-and-lock-rebuild.md
[§038]: ./spec/features/038%20crash%20diagnostics/spec.md
[§040]: ./spec/tasks/040-per-group-ping-test-settings.md
[§408]: ./spec/tasks/408-ping-options-groups-heal.md
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
[§438]: ./spec/tasks/438-lx-backup-1-0-read-write.md
[§439]: ./spec/features/439%20storage-contract-1-0/spec.md
[§370]: ./spec/tasks/370-rule-order-num-axis.md
[§434]: ./spec/tasks/434-srs-rule-multiple-rule-sets.md
[§435]: ./spec/features/435%20node-sections-tailscale/spec.md
[§445]: ./spec/tasks/445-tailscale-state-dir-lifecycle.md
