import 'dart:convert';

import '../context.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `GET /help` — самодокументируемая карта Debug API. Без auth (как `/ping`),
/// чтобы агент мог discover-нуть capability-карту до подсовывания токена.
///
/// Два формата:
/// - `?format=text` (default) — markdown-текст, удобно для LLM-агента
///   читать прямо из ответа.
/// - `?format=json` — структурированный JSON со списком endpoint'ов,
///   их методов, параметров и описаний. Для auto-tooling (генерация
///   MCP-обёртки, OpenAPI-spec'а etc.).
///
/// Содержимое hand-maintained — синхронизировано с реальными handler'ами
/// при добавлении endpoint'а. Не auto-generated через reflection: проще
/// отредактировать строку, чем строить interrop с router'ом.
Future<DebugResponse> helpHandler(DebugRequest req, DebugContext ctx) async {
  final format = req.q('format') ?? 'text';
  if (format == 'json') {
    return JsonResponse(_capabilityJson, pretty: true);
  }
  if (format != 'text') {
    return BytesResponse(
      utf8.encode('format must be text|json, got "$format"\n'),
      status: 400,
      contentType: 'text/plain; charset=utf-8',
    );
  }
  return BytesResponse(
    utf8.encode(_capabilityText),
    contentType: 'text/markdown; charset=utf-8',
  );
}

// ─── Hand-maintained capability map ─────────────────────────────────────
//
// При добавлении / удалении / переименовании endpoint'а — обновить здесь.
// Это **единственный источник правды** о публичной поверхности Debug API
// для LLM-агентов, шпаргалок, и потенциальных wrapper'ов (MCP etc.).

const _capabilityText = '''
=== L×Box Debug API ===

Localhost HTTP server for dev introspection and control. Runs inside the
Flutter app when "Debug API toggle" is enabled in App Settings → Developer.
Binds to 127.0.0.1, default port 9269. Auth: `Authorization: Bearer <token>`
(token is shown in App Settings → Developer; copy it via the UI Copy button).

Access from host: `adb forward tcp:9269 tcp:9269`, then curl 127.0.0.1:9269.

Spec: docs/spec/features/031 debug api/spec.md

=== Health ===

GET /ping                           Health-check. No auth. → {"pong":true,"server":"lxbox-debug","uptime_seconds":N}
GET /help[?format=text|json]        This map. No auth. text (default) — markdown; json — structured.

=== State (read-only) ===

GET /state                          HomeState dump (tunnel, groups, nodes_count, last_delay, traffic, busy).
                                      last_start_error / last_start_error_at — last VPN start/stop
                                      failure reason; cleared only by a successful start; in-memory
                                      (empty after process restart)
GET /state/subs[?reveal=true]       Subscriptions. URL masked default; reveal=true — full URL
GET /state/rules                    CustomRule[] — sealed: inline | srs | preset (with per-kind fields)
GET /state/storage                  Raw SettingsStorage._cache JSON (for debugging)
GET /state/vpn                      { auto_start, keep_on_exit, allow_bypass, background_mode, is_ignoring_battery_optimizations }
GET /state/config_locked            { "locked": bool } — auto-rebuild lock state

=== Device ===

GET /device                         Android version / SDK / model / ABI / app version + build / core version (libbox) / locale / timezone / network type / uptime

=== Config ===

GET /config                         Saved sing-box JSON (raw bytes, no re-encode)
PUT /config                         Overwrite config.json + reload sing-box. Body: raw
                                      sing-box JSON (Map). Sing-box validates on reload —
                                      errors arrive via status events / /logs?source=core.
                                      IMPORTANT: this override is temporary — the next
                                      rebuild-config (or any UI action) wipes it.
                                      To pin it permanently — PUT /settings/config_locked
                                      {"locked": true} before the write.
GET /config/pretty                  Same with indent
GET /config/path                    Absolute on-device file path
GET /config/running                 Running kernel snapshot (409 if none)

=== Pool (round_robin balancer) ===

GET /pool?tag=<autoTag>             Snapshot of a round_robin urltest pool (e.g. tag=vpn-1-auto).
                                      → {"tag","count","slots":[{slot,tag,delay,alive}]}. delay=0 → dead/untested.
                                      non-round_robin group → 200 slots:[] (pool is empty, not an error).
                                      tunnel down / command client unavailable → 409 Conflict (NOT empty 200).
                                      Works while the app is backgrounded (tunnel must be up).

=== Logs ===

GET /logs?limit=N&source=app|core&q=substr&level=error,warning,info,debug
                                    AppLog entries (per-source quotas:
                                      app=300, core=500 in-memory).
                                      limit  — default 200, max 1000
                                      source — filter by source
                                      q      — substring search in message
                                      level  — multi-filter, comma-separated
GET /logs/app                       Alias for /logs?source=app. Same query params.
GET /logs/core                      Alias for /logs?source=core. Same query params.
POST /logs/clear[?source=app|core]  Clear AppLog. No source — everything; otherwise only the given one.

=== Actions (mutating, POST) ===

POST /action/start-vpn                         Start the tunnel (via Activity, may show consent) → {"ok":true}
POST /action/start-vpn-headless                Start WITHOUT Activity/consent (needs permission already granted)
                                                  → {"started":bool,"needs_consent":bool}. For automation/self-test.
POST /action/stop-vpn                          Stop it
POST /action/force-stop-vpn                    Hard force-stop (doForceStop): teardown→stopSelf, frees CommandServer
                                                  port 63130 when a normal stop hung. Fire-and-forget.
POST /action/set-transient-timeout?connecting=<ms>&stopping=<ms>  Override transient-timeout thresholds (§140).
                                                  Any param optional (unset unchanged), ≥1 required. E.g. connecting=500
                                                  to arm the timeout fast for on-device force-stop testing.
POST /action/reconnect                         Stop→Start under one busy-wrap (delegates to start if down)
POST /action/reload-vpn                        In-place sing-box reload (no service kill). → {"applied":<bool>}
POST /action/clear-error                       Dismiss the lastError banner
POST /action/reset-network                     Light recovery: closeAllConnections + DNS flush + dialer
                                                  rebind. WITHOUT recreating box/Service/TUN. Spec 031.
                                                  Requires tunnel up. → {"ok":true,"action":"reset-network","native_ok":<bool>}
POST /action/quic-knobs?gso=on|off&ecn=on|off  §341: quic-go env knobs (QUIC_GO_DISABLE_GSO/ECN) via static
                                                  Libbox call. off = force-disable offload/marking, on = library
                                                  auto-detect. Affects NEW QUIC sockets only — follow with
                                                  reload-vpn / reset-network. At least one param.
                                                  native_ok=false per knob = AAR older than §341.
POST /action/urltest?tag=<node>                Single-node URLTest (CommandClient urlTestOutbound)
POST /action/urltest?group=<group>             Group URLTest (CommandClient, requires tunnel)
POST /action/urltest?all=true                  Mass URLTest of all nodes in the active group (concurrency 10)
POST /action/urltest?cancel=1                  Cancel in-flight mass URLTest (epoch-bump)
POST /action/switch-node?tag=<tag>             HomeController.switchNode
POST /action/set-group?group=<tag>             Change the active group
POST /action/rebuild-config                    SubscriptionController.generateConfig + saveParsedConfig
POST /action/refresh-subs?force=true|false     Manual sub-refresh (via AutoUpdater, force bypasses caps)
POST /action/download-srs?ruleId=<id>          Download SRS for a rule
POST /action/clear-srs?ruleId=<id>             Delete cached SRS
POST /action/toast?msg=<text>&duration=short|long  Android Toast (sanity-check "this is my device")
POST /action/emulate-error?kind=<k>            Demo humanizeError in /logs. kind: socket|timeout|http-401|
                                                  http-404|http-410|http-429|http-503|format|fs|plain|all
POST /action/check-updates                     Force update check (bypass 24h cap + auto_check_updates toggle).
POST /action/preview-empty-state?on=true|false UI-only override: render the empty-state without losing data. Useful for screenshots/demos/UX regression.
                                                  Returns {kind, tag, html_url, published_at, ...}. Mirrors UI
                                                  "Check now" button. Uses primary api.github.com → fallback
                                                  raw.githubusercontent.com/.../docs/latest.json.

=== WARP (register Cloudflare WARP node) ===

POST /warp[?rebuild=true]                      Registers a WARP node (same path as the Get WARP button).
                                                  Private key is generated on-device, registration with Cloudflare.
                                                  Node is added to subscriptions automatically. All body fields optional:
                                                  {"licenseKey":"...",       // null/empty → free WARP
                                                   "endpoint":"IP:port",     // default engage.cloudflareclient.com:2408
                                                   "obfuscate":true,         // QUIC masquerade
                                                   "forceNew":false,         // ignore cache, re-register
                                                   "includeReserved":false,  // null → default by obfuscate
                                                   "quicParams":{"sni":"www.google.com","ip":"quic",
                                                                 "ib":"curl","jc":4,"jmin":40,"jmax":70}}
                                                  ?rebuild=true → regenerate config + reload core.

=== Rules CRUD (custom routing rules, spec 030) ===

GET    /rules                                  alias /state/rules
GET    /rules/{id}                             Single rule
POST   /rules[?rebuild=true]                   Create. Body: CustomRule JSON, kind=inline|srs|preset
PATCH  /rules/{id}[?rebuild=true]              Partial update (any subset of fields)
DELETE /rules/{id}[?rebuild=true]              Delete
POST   /rules/reorder                          Body: {"order":[id1,id2,...]} — all ids required; renumbers the num axis
POST   /rules/move                             Body: {"id":"<uuid>","after":"<uuid>"|null} — §370 mirror of the UI drag:
                                                 rule takes target.num+1, neighbours shift only if that number is taken
                                                 (after:null = start of the user zone). Pinned rules refuse to move.

`?rebuild=true` on any write method → automatically triggers rebuild-config.

=== Subscriptions CRUD (user servers + subscriptions) ===

GET    /subs[?reveal=true]                     alias /state/subs. reveal=true → unmasked URLs
GET    /subs/{id}[?reveal=true]                Single entry
POST   /subs[?rebuild=true]                    Create. Body {"input":"<url|URI|WG-conf|JSON-outbounds>"}.
                                                 input runs through the parser pipeline (same as UI paste);
                                                 JSON with multiple outbounds may create several entries.
PATCH  /subs/{id}[?rebuild=true][?reveal=true] Update meta, any subset: {enabled,name,url,tag_prefix,
                                                 update_interval_hours,override_detour,register_detour_servers,
                                                 register_detour_in_auto,use_detour_servers,replace_detour_chain,
                                                 on_update_action,import_rules_enabled,identity}.
                                                 url applies to SubscriptionServers only (no-op for UserServer).
                                                 on_update_action: rebuild|reload|none.
                                                 identity is a tristate: omit = keep, null = Default (global
                                                 identity), object = Custom. The object is a PATCH over the
                                                 snapshot (initialised from globals when switching to Custom):
                                                 {user_agent,send_hwid,hwid,device_os,ver_os,device_model}.
                                                 So {"identity":{"send_hwid":true,"hwid":"<uuid>"}} enables
                                                 HWID for this subscription only, leaving globals untouched.
DELETE /subs/{id}[?rebuild=true]               Remove
POST   /subs/{id}/refresh                      Force HTTP re-fetch (SubscriptionServers only). Fire-and-forget.
POST   /subs/reorder                           Body {"order":[id1,id2,...]} — exactly the current ids

Import rules (per subscription, applied to parsed nodes on the NEXT refresh —
existing nodes are not re-parsed in place). Ordered collection without ids:
addressed by position, like folder members. Indexes shift after DELETE/reorder —
build the next call from the snapshot returned in "rules". Non-subscription
entries → 409.

GET    /subs/{id}/rules                        List: {import_rules_enabled, rules:[{index,usable,...}]}
POST   /subs/{id}/rules[?index=N]              Create (201). ImportRule shape:
                                                 {conditions:[{path,op,pattern,negate,case_sensitive}],
                                                 match:all|any, action:replace|disable|enable, target_path,
                                                 replacement, replace_mode:set|substitute, substitute, enabled}.
                                                 op: contains|equals|matches. index inserts at position
                                                 (default: append). "usable":false = rule parses but will be
                                                 skipped on apply (e.g. Replace without target_path) — allowed.
GET    /subs/{id}/rules/{idx}                  Single rule
PATCH  /subs/{id}/rules/{idx}                  Partial update, same field subset
DELETE /subs/{id}/rules/{idx}                  Remove rule
POST   /subs/{id}/rules/reorder                Body {"order":[old indexes in new order]} — full permutation

`?rebuild=true` on any write → auto rebuild-config. Writes go through
SubscriptionController (fetch-state machine + UI notify), not SettingsStorage directly.

=== Directions CRUD (routing directions) ===

GET    /directions                               List directions (storage shape, snake_case)
GET    /directions/{tag}                         Single direction (tag = the direction's outbound tag,
                                                 e.g. vpn-1 or a custom one)
POST   /directions[?rebuild=true]                Create. Body optional: {"label":"...","tag":"..."} plus any
                                                 PATCH field below. No tag → first free vpn-N; a custom tag is
                                                 accepted as-is. There is NO cap on the number of directions.
                                                 Rejected tags → 409 with the machine reason in the message:
                                                 empty | reserved (direct-out/block/dns-out/…) | duplicate |
                                                 auto_twin (collides with an existing "<tag>-auto" twin).
PATCH  /directions/{tag}[?rebuild=true]          Partial update: {label,enabled,include_direct,include_block,
                                                 node_filter,node_filter_invert,default_filter,include,
                                                 interrupt_exist_connections,auto,detour}.
                                                 include = tags of OTHER directions offered as options inside
                                                 this one; only targets declared ABOVE in the list are emitted
                                                 (order is set by /directions/reorder).
                                                 auto is MERGED into current urltest options (nested balancer
                                                 merges too); "auto":null disables the urltest twin.
                                                 tag is immutable; vpn-1 cannot be disabled (409).
                                                 node_filter/default_filter are validated as regex (400 on bad).
                                                 detour:true allows picking the direction as a server/folder/
                                                 subscription detour target (gear direction). The direction stays
                                                 a valid rule target (route_final / custom-rule outbound);
                                                 include_block is allowed alongside detour.
                                                 vpn-1 cannot be a detour direction (409).
                                                 Toggling detour RENAMES the direction: the reserved gear
                                                 prefix is added to / stripped from the stored label
                                                 (like detour-server tag marks) — responses carry the
                                                 normalized label, which may differ from what was sent.
DELETE /directions/{tag}[?rebuild=true]          Remove. vpn-1 is not deletable (409). References to the removed
                                                 direction (route_final / custom-rule outbound) degrade to vpn-1;
                                                 detour references (override_detour / members[].detour) reset
                                                 to None.
POST   /directions/reorder[?rebuild=true]        Body {"order":["vpn-1",...]} — exactly the current tags.
                                                 Direction order = emit order in the config.

Disabling a direction (enabled:false) degrades rule references to vpn-1 and
resets detour references to None; clearing detour (detour:false) resets
detour references to None. Setting detour:true heals nothing — the direction
stays a rule target. Re-enabling / re-flagging does NOT restore healed
references (same semantics as the UI toggle). Deleting a direction ALSO
strips its tag from the include[] of every other direction; disabling does
not (include survives a disable, the builder just degrades the emitted
group). Every mutation response carries
"healed": {"rules": N, "detours": M, "includes": K} — how many references
were reset.

=== Chains CRUD (hop chains — third source kind, SPEC 110) ===

A chain is a ROUTE ("client → hop 1 → hop 2 → … → target"), not a choice
between routes: it lives next to subscriptions and servers as a source, and
for the rest of the app it looks like a NODE (own tag, picked up by direction
filters, emitted as one outbound of type "chain"). Stored in the `chains[]`
key; ORDER IS NORMATIVE — a chain may reference only chains declared ABOVE it,
which is what rules out cycles.

GET    /chains                                   List chains (storage shape, snake_case)
GET    /chains/{tag}                             Single chain (404 if unknown)
POST   /chains[?rebuild=true]                    Create → 201. Body optional: {"tag":"...","label":"..."} plus
                                                 any PATCH field below. No tag → first free chain-N. The tag is
                                                 checked against BOTH chains and directions (two outbounds with
                                                 one tag → the core rejects the whole config): rejected → 409
                                                 with the machine reason: empty | reserved | duplicate |
                                                 auto_twin. A body without hops creates an EMPTY chain (same as
                                                 the UI: the record exists, the route is not filled in yet).
PATCH  /chains/{tag}[?rebuild=true]              Partial update: {label,enabled,hops,idle_timeout,strip_evasion,
                                                 strip,rewrite}. tag is immutable (400) — direction filters,
                                                 route_final and other chains' positions point at it.
                                                 hops = positions IN PACKET ORDER: [0] is the first hop from the
                                                 client, the last one is what the target sees. NOT "who through
                                                 whom" — detour's arrow points the other way.
                                                 idle_timeout: "" = core default (5m), "0s" = live until stop.
                                                 strip_evasion is a TRISTATE: omit = keep, null = core default
                                                 (true, key not written), bool = explicit choice.
                                                 strip = per-key patch over strip_evasion, REPLACES the map;
                                                 keys only from tls.fragment | multiplex.padding |
                                                 xhttp.padding | tls.utls (unknown key → 400).
                                                 rewrite = JSON merge-patch (RFC 7396) per outbound type, kept
                                                 verbatim (a null inside DELETES a key — no "empty cleanup").
DELETE /chains/{tag}[?rebuild=true]              Remove. Positions of OTHER chains pointing at the removed tag
                                                 are NOT cleaned up (dropping a position makes it a DIFFERENT
                                                 route) — the build degrades such a chain as a whole
                                                 ("chain_hop_missing"). The response lists them in
                                                 "dangling_refs":[tag,...].
GET    /chains/{tag}/probe[?url=&timeout_ms=]    Layer-by-layer probe: what EACH hop of the route costs.

Layer probe measures PREFIXES, not hops: position i is unreachable except
through i-1, so a hop's price is always a subtraction of two neighbouring
measurements, never a measurement of its own. Layer k is addressed by the tag
the CORE registers for it — `<chain>#<k>` (protocol/chain, `hopTag`) — the
same scheme the desktop launcher uses (`config.ChainLayerTag`), so a probe
reads the same on both apps.

Needs a RUNNING VPN (409 otherwise): those `#k` tags exist only in the running
core, and chain positions reference tags of the BUILT config, so there is no
way to raise a probe-only session for a chain the way single nodes do.
Positions come from the built config, not from storage — the core runs what
was built, and a chain edited without a rebuild is a different route.
Sequential by construction; worst case positions × timeout_ms, so lower
timeout_ms on long chains to stay inside the 30s request timeout. Defaults for
url/timeout_ms are the global ping_options — the same budget as the node test.
Response: {layers:[{pos, tag, probe_tag, cumulative_ms?, delta_ms?, error?,
not_reached?}]}. cumulative_ms is the whole path up to that hop; delta_ms is
what that hop added (absent when it cannot be computed: first layer, or a
broken neighbour — a zero would read as "this hop is free"). The first layer
that fails carries the CORE's own text, and every layer behind it is
not_reached: the packet does not get there, so measuring them would spend the
budget proving what is already known. 409 also when the chain is not in the
built config at all (disabled, degraded at build time, never built).

Writes go through the SAME validation gate as the edit form (`sing-box check`
does NOT catch chain start-up errors — a config with tls.utls stripped off a
reality node passes `check` and dies on `run`, and the core then rejects the
WHOLE config). A blocking finding → 400 carrying its machine code:
tooFewHops (<2 positions) | emptyHop | duplicateHop | selfReference |
nestedNotFirst (a nested chain is only legal at position 0) |
forwardChainReference (referencing a chain declared below) |
realityUtlsStripped | tagEmpty | tagTaken. Non-blocking findings (a
position that is no longer among the targets, a first hop with its own detour)
do NOT block the write — same line the form draws.

=== Folders CRUD (server folders) ===

A folder is a /subs entry (kind=FolderServers) — folder meta (name/enabled/
tag_prefix/detour policy) is edited via PATCH /subs/{id}. Members are addressed
by POSITIONAL index (no per-member id): indexes shift after remove/ungroup/
reorder — every write response returns a fresh folder snapshot, use it for
follow-up calls. Member raw carries credentials → hidden unless ?reveal=true.

GET    /folders[?reveal=true]                  List folder entries + members
POST   /folders[?rebuild=true]                 Create empty folder. Body {"name":"..."} → 201
GET    /folders/{id}[?reveal=true]             Single folder + members
DELETE /folders/{id}[?keep_servers=true][?rebuild=true]
                                               Delete. keep_servers=true → members become standalone
                                                 single servers in place of the folder (default false)
POST   /folders/{id}/members[?rebuild=true]    Add members. Body: exactly one of
                                                 {"input":"<uri|WG-ini|JSON>", "name_fallback"?:"..."} (paste)
                                                 or {"url":"..."} (one-shot snapshot: fetch → static members,
                                                 URL is not stored, no auto-update)
PATCH  /folders/{id}/members/{idx}[?rebuild=true]
                                               Subset {raw,enabled,detour}. raw must parse (400 keeps old);
                                                 detour = personal member detour tag ('' clears)
DELETE /folders/{id}/members/{idx}[?rebuild=true]  Remove member
POST   /folders/{id}/members/reorder[?rebuild=true]
                                               Body {"order":[old indexes in new order]} — full permutation
POST   /folders/{id}/members/{idx}/ungroup[?rebuild=true]
                                               Member → standalone single server right after the folder
                                                 (personal detour becomes its override_detour)
POST   /folders/{id}/members/{idx}/move[?rebuild=true]
                                               Body {"to":"<folder id>"} — move member to another folder
POST   /folders/{id}/move-server[?rebuild=true]
                                               Body {"server_id":"<subs entry id>"} — move a standalone
                                                 single server INTO the folder (splits 1:1 by nodes; its
                                                 personal override detour moves onto the members)
POST   /folders/{id}/probe                     Headless "Test servers" run; results in the response.
                                                 Body optional {"url":"...","timeout_ms":N} (defaults =
                                                 global ping_options). Per-member statuses: ok|failed|broken|
                                                 invalid|not_in_config|pending (+delay_ms on ok).
                                                 With VPN running, disabled members are not in the live
                                                 config → not_in_config. Synchronous: worst-case
                                                 ~members/6 × timeout_ms; lower timeout_ms for big folders
                                                 to fit the 30s request timeout.

=== Wi-Fi history (saved networks for routing rule editor) ===

GET    /wifi_history                           list [{ssid, bssid, last_seen}]
POST   /wifi_history                           upsert. body {"ssid": "...", "bssid": "..."}
DELETE /wifi_history                           remove specific. body {"ssid": "...", "bssid": "..."}
DELETE /wifi_history/all                       clear all

Cap 50 entries (LRU evict by last_seen). BSSID is normalized to lower-case.

=== Files (read-only) ===

GET /files/srs/list                            Cached SRS files: [{rule_id, size, mtime}]
GET /files/srs?ruleId=<id>                     Binary SRS dump (octet-stream)
GET /files/local?name=<n>                      Whitelisted internal-storage files (cache.db, stderr.log,
                                               CrashReport-lxbox.log[.old] — Go panics of the core). `/files/external` — legacy alias.
GET /files/crash/list                          Archived core crash reports: [{name, size, mtime}], newest first
GET /files/crash?name=<n>                      Body of an archived crash report
GET /files/oom/list                            Core OOM snapshots: [{name, size, mtime, memory_usage, ...}], newest first
GET /files/oom?name=<n>[&file=<f>]             File of an OOM snapshot; default metadata.json,
                                               &file=heap.pb|allocs.pb|goroutine.pb|go.log|configuration.json

=== Traffic Profiler (system-wide) ===

System-wide (inclusive observer — Live tab in Statistics):
POST   /profiler/live/start                    startGlobalRecording — subscribes to core connections +
                                                 DNS streams. Idempotent.
POST   /profiler/live/stop                     stopGlobalRecording. Idempotent.
GET    /profiler/live/state                    {recording, started_at, buffer_count, unattributed_count, banner_active}.
GET    /profiler/live?seconds=60               Snapshot of the global rolling buffer for the window (default 60s).
                                                 Returns {window_seconds, count, events:[...]}.
GET    /profiler/live/stream                   SSE — all system-wide events live (DNS resolves +
                                                 TCP/UDP open/close across all packages).
GET    /profiler/live/unattributed             Recent unattributed ring (DNS-fail without owner / TCP without
                                                 process attribution). Used for banner detection.

=== Support feed (§356/§357) ===

GET  /support/state                            Raw support_state.json (read/baseline/snooze/active) + app_version + total_active_seconds.
POST /support/reset                            Wipe read/baseline/snooze/cache — feed starts over. ?keep_active=false also zeroes the activity counter.
POST /support/preview                          Body = ONE feed-format message object → immediate fullscreen show, ALL gates bypassed.
                                                 ?dry=true (default) — buttons work but markRead/snooze are NOT persisted; ?dry=false — persisted.
                                                 ?snooze_hours=N — snooze_active_hours of the synthetic feed (default 10). Requires UI process (409 otherwise).

=== Diagnostics ===

GET /diag/dump                                 Full JSON pack from DumpBuilder.build (config + vars + subs + log + stderr + exit_info + logcat).
GET /diag/exit-info                            ApplicationExitInfo (last 5 system exits); empty array on API <30.
GET /diag/logcat?count=N&level=L               Logcat tail of our process (N=50..5000, default 1000; level=V|D|I|W|E|F, default E).
GET /diag/stderr                               filesDir/stderr.log content (Go panic stacktrace from libbox).
GET /diag/applog?prev=true|false|all           AppLog entries; `prev` filters by fromPreviousSession (default `all`).
GET /diag/pprof?profile=P&query=Q            pprof snapshot via libbox PProfServer (tunnel must be up). P=goroutine|profile|heap|allocs|block|mutex|threadcreate (default goroutine). query=raw pprof query w/o `?` (e.g. gc=1, debug=1, seconds=20); default per profile (goroutine→debug=2, profile→seconds=10, heap→gc=1). Only goroutine?debug=* → text/plain; rest → .pb (go tool pprof). heap inuse_space: go tool pprof -inuse_space heap.pb.

=== Settings (scoped writes) ===

PUT    /settings/route_final                   body {"outbound":"..."}
GET|PUT /settings/interrupt_on_switch          body {"enabled":bool} — рвать conns при switchNode
GET|PUT /settings/node_sort                    body {"mode":"latency|manual|", "order"?:["tag",...]}
GET|PUT /settings/enabled_groups               body {"groups":["tag",...]} (config-significant, ?rebuild)
GET|PUT /settings/vpn_mode                     body partial {mode,proxy_protocol,proxy_port,proxy_listen,proxy_auth,proxy_user,proxy_pass} (?rebuild)
GET|PUT /settings/ping_options                 URLTest defaults. body partial {url?,timeout_ms?,groups?} (groups = per-group overrides map)
GET|PUT|DELETE /settings/ping_options/groups/{tag}  Per-group URLTest override. PUT body {url?,timeout_ms?} (≥1 required); DELETE clears
GET|PUT /settings/tun_apps                     Per-app tunnel list. body {"mode":"off|allow|deny","packages":["pkg",...]} (config-significant, ?rebuild)
PUT    /settings/vars/{key}                    body {"value":"..."}; blocklist: debug_token/debug_enabled/debug_port
DELETE /settings/vars/{key}                    Delete var
PUT    /settings/dns_options/servers           body {"servers":[...]}
PUT    /settings/dns_options/rules             body {"rules":"<json-string>"}
PUT    /settings/config_locked                 toggle auto-rebuild lock. body {"locked":true|false}.
                                                 true → SubscriptionController.generateConfig returns null
                                                 silently, the custom config from PUT /config is not overwritten
                                                 by UI actions. Default false (normal flow).
GET    /settings/core_logs_enabled              current state of forwarding sing-box logs into /logs/core.
                                                 → {"enabled": bool}
PUT    /settings/core_logs_enabled              body {"enabled":true|false}. Default false. Takes effect
                                                 ONLY on a process restart — Libbox.setup is one-shot. Stop/
                                                 start VPN does NOT help (the service is recreated, the Application
                                                 stays alive). Force-stop the app + relaunch, or use the UI button
                                                 "Quit & reopen app" in App Settings → Diagnostics or
                                                 Debug screen → Log tab.
GET|PUT /settings/core_logs_verbose             §345: pass TRACE/DEBUG core lines through (default false —
                                                 they are dropped for volume). body {"enabled":bool}. Applies
                                                 IMMEDIATELY (no restarts); no effect while core_logs_enabled
                                                 is off. Very chatty — enable, reproduce, grab /logs/core, disable.
GET|PUT /settings/vpn/allow_bypass              VpnService.Builder.allowBypass(). body {"enabled":bool}.
                                                 Effect at next establish() — reload VPN.
GET|PUT /settings/vpn/keep_on_exit              keep VPN running when app closed. body {"enabled":bool}.
GET|PUT /settings/vpn/background_mode           foreground-service tunnel sleep mode.
                                                 body {"mode":"never|lazy|always"}.
                                                 never (default) — always-on; lazy — pause in deep Doze;
                                                 always — pause on screen-off. Effect at next VPN connect.
POST   /settings/rebuild-config                Alias /action/rebuild-config

=== Backup ===

GET  /backup/export?include=storage,vpn_settings  Pure-data snapshot for restore (no diag noise). `include` optional; default — both parts.
POST /backup/import?merge=false&rebuild=false  Accepts the same shape export returns (body {storage?, vpn_settings?}).
                                                 `merge=true` — append/upsert; `rebuild=true` — auto-rebuild config after restore.

=== Errors ===

All error responses: {"error": {"code": "...", "message": "...", "details": {...}}}
HTTP status codes: 400 BadRequest, 401 Unauthorized (no/wrong token), 403 Forbidden (Host check),
404 NotFound, 409 Conflict (state precondition fail), 500 Internal.

=== Quick Examples ===

# Setup
adb forward tcp:9269 tcp:9269
TOKEN=<your-token-from-app-settings>

# Health (no auth)
curl http://127.0.0.1:9269/ping

# State snapshot
curl -H "Authorization: Bearer \$TOKEN" http://127.0.0.1:9269/state | jq '.tunnel, .groups, .nodes_count'

# Connect
curl -H "Authorization: Bearer \$TOKEN" -X POST http://127.0.0.1:9269/action/start-vpn

# URLTest on ✨auto (emoji gets URL-encoded)
TAG=\$(python3 -c "import urllib.parse; print(urllib.parse.quote('✨auto'))")
curl -H "Authorization: Bearer \$TOKEN" -X POST "http://127.0.0.1:9269/action/urltest?group=\$TAG"

# Create an inline rule + rebuild config
curl -H "Authorization: Bearer \$TOKEN" -H "Content-Type: application/json" \\
  -d '{"name":"Block ads","kind":"inline","domain_suffixes":["ads.example.com"],"outbound":"reject"}' \\
  http://127.0.0.1:9269/rules?rebuild=true

# Logs with a filter
curl -H "Authorization: Bearer \$TOKEN" 'http://127.0.0.1:9269/logs?level=error,warn&q=fetch&limit=20'

=== Notes ===

- emoji in URL path (✨auto etc.) — must be URL-encoded. curl does not do it for you.
- Subscription URLs masked default (`scheme://host/***`); ?reveal=true for full.
- /rules CRUD accepts snake_case (domain_suffixes, ip_cidrs, preset_id, vars_values,
  dns: {enabled, server_tag}) and returns snake_case.
- /rules resolve option (inline/srs): resolve: {only, strategy, server_tag,
  disable_cache, disable_optimistic_cache, rewrite_ttl, timeout, client_subnet}.
  only=false emits a non-terminal resolve rule BEFORE the route rule; only=true
  emits resolve without routing (fall-through). "resolve": null clears it.
- All timestamps are ISO-8601 UTC.
- Token stays stable until you Regenerate it in the UI — stable for curl sessions.
''';

const Map<String, dynamic> _capabilityJson = {
  'server': 'lxbox-debug',
  'docs': {
    'spec': 'docs/spec/features/031 debug api/spec.md',
  },
  'auth': {
    'header': 'Authorization: Bearer <token>',
    'token_source': 'App Settings → Developer (Copy button)',
    'no_auth_paths': ['/ping', '/help'],
  },
  'transport': {
    'bind': '127.0.0.1',
    'default_port': 9269,
    'host_check': 'Host header must be 127.0.0.1 or localhost (DNS-rebind defense)',
  },
  'endpoints': [
    // Health
    {'method': 'GET', 'path': '/ping', 'auth': false, 'description': 'Health-check', 'response': '{"pong":true,"server":"lxbox-debug","uptime_seconds":N}'},
    {'method': 'GET', 'path': '/help', 'auth': false, 'description': 'This capability map', 'params': {'format': 'text|json (default text)'}},
    // State
    {'method': 'GET', 'path': '/state', 'description': 'HomeState dump (tunnel, groups, nodes, traffic). last_start_error/last_start_error_at — last VPN start/stop failure reason; cleared only by a successful start; in-memory (empty after process restart)'},
    {'method': 'GET', 'path': '/state/subs', 'params': {'reveal': 'true|false (default false → URLs masked)'}, 'description': 'Subscriptions list'},
    {'method': 'GET', 'path': '/state/rules', 'description': 'CustomRule[] sealed (inline|srs|preset)'},
    {'method': 'GET', 'path': '/state/storage', 'description': 'Raw SettingsStorage._cache JSON'},
    {'method': 'GET', 'path': '/state/vpn', 'description': 'auto_start, keep_on_exit, allow_bypass, background_mode, battery_whitelisted'},
    {'method': 'GET', 'path': '/state/config_locked', 'description': '{locked: bool} — auto-rebuild lock state'},
    // Device
    {'method': 'GET', 'path': '/device', 'description': 'Android version, model, ABI, app version, network, uptime'},
    // Config
    {'method': 'GET', 'path': '/config', 'description': 'Saved sing-box JSON (raw)'},
    {'method': 'PUT', 'path': '/config', 'body': 'raw sing-box JSON (Map)', 'description': 'Overwrite config.json + reload sing-box. Temporary unless /settings/config_locked=true.'},
    {'method': 'GET', 'path': '/config/pretty', 'description': 'Indent-formatted'},
    {'method': 'GET', 'path': '/config/path', 'description': 'On-device file path'},
    {'method': 'GET', 'path': '/config/running', 'description': 'Config of the running kernel (SPEC 036); 409 when unavailable'},
    // Logs
    {'method': 'GET', 'path': '/logs', 'params': {'limit': 'N (default 200)', 'source': 'app|core', 'q': 'substring search', 'level': 'comma-separated: error,warn,info,debug'}, 'description': 'AppLog entries'},
    {'method': 'GET', 'path': '/logs/app', 'description': 'Alias for /logs?source=app (same params)'},
    {'method': 'GET', 'path': '/logs/core', 'description': 'Alias for /logs?source=core (same params)'},
    {'method': 'POST', 'path': '/logs/clear', 'description': 'Clear AppLog'},
    // Actions
    {'method': 'POST', 'path': '/action/start-vpn', 'description': 'Start tunnel (via Activity, may show consent)'},
    {'method': 'POST', 'path': '/action/start-vpn-headless', 'description': 'Start without Activity/consent (needs permission granted) → {started,needs_consent}'},
    {'method': 'POST', 'path': '/action/stop-vpn', 'description': 'Stop tunnel'},
    {'method': 'POST', 'path': '/action/reconnect', 'description': 'Stop→Start under one busy-wrap (start if down)'},
    {'method': 'POST', 'path': '/action/reload-vpn', 'description': 'In-place sing-box reload (no service kill) → {applied}'},
    {'method': 'POST', 'path': '/action/clear-error', 'description': 'Dismiss lastError banner'},
    {'method': 'POST', 'path': '/action/force-stop-vpn', 'description': 'Hard force-stop (doForceStop path): teardown→stopSelf, frees CommandServer port 63130. fire-and-forget.'},
    {'method': 'POST', 'path': '/action/set-transient-timeout', 'params': {'connecting': 'ms (optional)', 'stopping': 'ms (optional)'}, 'description': 'Override transient-timeout thresholds (ms) for on-device force-stop test. At least one param.'},
    {'method': 'POST', 'path': '/action/reset-network', 'description': 'Light recovery: closeAll + DNS flush + dialer rebind (spec 031). Requires tunnel up.'},
    {'method': 'POST', 'path': '/action/quic-knobs', 'params': {'gso': 'on|off (optional)', 'ecn': 'on|off (optional)'}, 'description': '§341: quic-go env knobs (GSO/ECN) via static Libbox call; affects new QUIC sockets, follow with reload-vpn/reset-network. At least one param.'},
    {'method': 'POST', 'path': '/action/urltest', 'params': {'tag': 'node tag (single)', 'group': 'group tag (group urltest, URL-encode emoji)', 'all': 'true (mass urltest)', 'cancel': '1 (abort in-flight mass urltest)'}, 'description': 'URLTest dispatch by query: one of tag/group/all/cancel'},
    {'method': 'POST', 'path': '/action/switch-node', 'params': {'tag': 'node tag'}, 'description': 'Selector switch via HomeController'},
    {'method': 'POST', 'path': '/action/set-group', 'params': {'group': 'group tag'}, 'description': 'Change active group'},
    {'method': 'POST', 'path': '/action/rebuild-config', 'description': 'Regenerate sing-box config'},
    {'method': 'POST', 'path': '/action/refresh-subs', 'params': {'force': 'true|false'}, 'description': 'Manual sub-refresh'},
    {'method': 'POST', 'path': '/action/download-srs', 'params': {'ruleId': 'id'}, 'description': 'Download SRS for a rule'},
    {'method': 'POST', 'path': '/action/clear-srs', 'params': {'ruleId': 'id'}, 'description': 'Clear cached SRS'},
    {'method': 'POST', 'path': '/action/toast', 'params': {'msg': 'text', 'duration': 'short|long'}, 'description': 'Android toast (sanity-check)'},
    {'method': 'POST', 'path': '/action/emulate-error', 'params': {'kind': 'socket|timeout|http-401|http-404|http-410|http-429|http-503|format|fs|plain|all'}, 'description': 'Demo humanizeError in /logs'},
    {'method': 'POST', 'path': '/action/check-updates', 'description': 'Force update check (bypass cap + toggle); returns {kind,tag,html_url,...}'},
    // WARP
    {'method': 'POST', 'path': '/warp', 'params': {'rebuild': 'true|false'}, 'body': '{licenseKey?, endpoint?, obfuscate?, forceNew?, includeReserved?, quicParams?:{sni,ip,ib,jc,jmin,jmax}}', 'description': 'Register Cloudflare WARP node (same path as Get WARP wizard). All fields optional. obfuscate=true → QUIC masquerade via quicParams. ?rebuild=true regenerates config.'},
    // Rules
    {'method': 'GET', 'path': '/rules', 'description': 'Alias /state/rules'},
    {'method': 'GET', 'path': '/rules/{id}', 'description': 'Single rule'},
    {'method': 'POST', 'path': '/rules', 'params': {'rebuild': 'true|false'}, 'body': 'CustomRule JSON (kind: inline|srs|preset)', 'description': 'Create'},
    {'method': 'PATCH', 'path': '/rules/{id}', 'params': {'rebuild': 'true|false'}, 'body': 'Partial CustomRule', 'description': 'Update'},
    {'method': 'DELETE', 'path': '/rules/{id}', 'params': {'rebuild': 'true|false'}, 'description': 'Delete'},
    {'method': 'POST', 'path': '/rules/reorder', 'body': '{"order":[id,...]}', 'description': 'Reorder (all ids required). Renumbers the num axis so the order survives a reload.'},
    {'method': 'POST', 'path': '/rules/move', 'body': '{"id":"<uuid>","after":"<uuid>"|null}', 'description': '§370 — move one rule along the num axis; mirrors the UI drag (lazy neighbour shift, pinned rules refuse).'},
    // Subscriptions CRUD (user servers + subscriptions)
    {'method': 'GET', 'path': '/subs', 'params': {'reveal': 'true|false (default false → URLs masked)'}, 'description': 'Alias /state/subs'},
    {'method': 'GET', 'path': '/subs/{id}', 'params': {'reveal': 'true|false'}, 'description': 'Single entry'},
    {'method': 'POST', 'path': '/subs', 'params': {'rebuild': 'true|false'}, 'body': '{"input":"<url|URI|WG-conf|JSON-outbounds>"}', 'description': 'Create via parser pipeline (JSON may create several entries)'},
    {'method': 'PATCH', 'path': '/subs/{id}', 'params': {'rebuild': 'true|false', 'reveal': 'true|false'}, 'body': 'Any subset: {enabled,name,url,tag_prefix,update_interval_hours,override_detour,register_detour_servers,register_detour_in_auto,use_detour_servers,replace_detour_chain,on_update_action,import_rules_enabled,identity}', 'description': 'Update meta. url is SubscriptionServers-only (no-op for UserServer). on_update_action: rebuild|reload|none. identity is a tristate: omit = keep, null = Default (global identity), object = Custom. The object patches the snapshot (initialised from globals on switch to Custom): {user_agent,send_hwid,hwid,device_os,ver_os,device_model} — so {"identity":{"send_hwid":true,"hwid":"<uuid>"}} enables HWID for this subscription only, leaving globals untouched.'},
    {'method': 'DELETE', 'path': '/subs/{id}', 'params': {'rebuild': 'true|false'}, 'description': 'Remove entry'},
    {'method': 'POST', 'path': '/subs/{id}/refresh', 'description': 'Force HTTP re-fetch (SubscriptionServers only). Fire-and-forget.'},
    {'method': 'POST', 'path': '/subs/reorder', 'body': '{"order":[id,...]}', 'description': 'Reorder (exactly the current ids)'},
    // Import rules CRUD (per subscription)
    {'method': 'GET', 'path': '/subs/{id}/rules', 'description': 'List import rules: {import_rules_enabled, rules:[{index,usable,...}]}. Non-subscription entry → 409.'},
    {'method': 'POST', 'path': '/subs/{id}/rules', 'params': {'index': 'insert position (default: append)', 'rebuild': 'true|false'}, 'body': '{conditions:[{path,op:contains|equals|matches,pattern,negate,case_sensitive}],match:all|any,action:replace|disable|enable,target_path,replacement,replace_mode:set|substitute,substitute,enabled}', 'description': 'Create rule (201). Applied on the NEXT refresh — existing nodes are not re-parsed. "usable":false = parses but will be skipped on apply (allowed, e.g. Replace without target_path).'},
    {'method': 'GET', 'path': '/subs/{id}/rules/{idx}', 'description': 'Single rule by position'},
    {'method': 'PATCH', 'path': '/subs/{id}/rules/{idx}', 'params': {'rebuild': 'true|false'}, 'body': 'Any subset of the rule shape', 'description': 'Partial update of one rule'},
    {'method': 'DELETE', 'path': '/subs/{id}/rules/{idx}', 'params': {'rebuild': 'true|false'}, 'description': 'Remove rule. Indexes shift — rebuild the next call from the returned "rules".'},
    {'method': 'POST', 'path': '/subs/{id}/rules/reorder', 'params': {'rebuild': 'true|false'}, 'body': '{"order":[old indexes in new order]}', 'description': 'Reorder (full permutation of 0..n-1). Order matters: rules apply sequentially, last enable/disable wins.'},
    // Directions CRUD (routing directions)
    {'method': 'GET', 'path': '/directions', 'description': 'List routing directions (storage shape, snake_case)'},
    {'method': 'GET', 'path': '/directions/{tag}', 'description': "Single direction (tag = the direction's outbound tag, e.g. vpn-1 or a custom one)"},
    {'method': 'POST', 'path': '/directions', 'params': {'rebuild': 'true|false'}, 'body': 'optional {"label":"...","tag":"..."} + any PATCH field', 'description': 'Create direction. No tag → first free vpn-N; a custom tag is accepted as-is. No cap on the number of directions. Rejected tag → 409 with the machine reason: empty|reserved|duplicate|auto_twin.'},
    {'method': 'PATCH', 'path': '/directions/{tag}', 'params': {'rebuild': 'true|false'}, 'body': 'Any subset: {label,enabled,include_direct,include_block,node_filter,node_filter_invert,default_filter,include,interrupt_exist_connections,auto,detour}', 'description': 'Partial update. auto merges into current urltest options; "auto":null disables the twin. tag immutable; vpn-1 cannot be disabled. detour:true = direction selectable as detour target (stays a valid rule target; include_block allowed); vpn-1+detour → 409; detour:false resets detour references to None. Toggling detour renames the direction: the reserved gear prefix is added to/stripped from the stored label — responses carry the normalized label. Mutation responses carry "healed":{rules,detours,includes}.'},
    {'method': 'DELETE', 'path': '/directions/{tag}', 'params': {'rebuild': 'true|false'}, 'description': 'Remove direction. vpn-1 not deletable (409). Rule references degrade to vpn-1; detour references reset to None; the tag is stripped from every other direction include[]. Response carries "healed":{rules,detours,includes}.'},
    {'method': 'POST', 'path': '/directions/reorder', 'params': {'rebuild': 'true|false'}, 'body': '{"order":[tag,...]}', 'description': 'Reorder (exactly the current tags). Order = emit order in config.'},
    // Chains CRUD (hop chains, SPEC 110)
    {'method': 'GET', 'path': '/chains', 'description': 'List hop chains (storage shape, snake_case). Order is normative: a chain may reference only chains declared above it.'},
    {'method': 'GET', 'path': '/chains/{tag}', 'description': 'Single chain (404 if unknown)'},
    {'method': 'POST', 'path': '/chains', 'params': {'rebuild': 'true|false'}, 'body': 'optional {"tag":"...","label":"..."} + any PATCH field', 'description': 'Create chain → 201. No tag → first free chain-N. Tag is checked against BOTH chains and directions; rejected → 409 with the machine reason: empty|reserved|duplicate|auto_twin. A body without hops creates an empty chain (same as the UI).'},
    {'method': 'PATCH', 'path': '/chains/{tag}', 'params': {'rebuild': 'true|false'}, 'body': 'Any subset: {label,enabled,hops,idle_timeout,strip_evasion,strip,rewrite}', 'description': 'Partial update. tag is immutable (400). hops = positions in PACKET order ([0] = first hop from the client). strip_evasion is a tristate: omit = keep, null = core default, bool = explicit. strip replaces the map, keys only tls.fragment|multiplex.padding|xhttp.padding|tls.utls. rewrite = RFC 7396 merge-patch per outbound type, kept verbatim. Writes pass the same gate as the edit form; a blocking finding → 400 with its code: tooFewHops|emptyHop|duplicateHop|selfReference|nestedNotFirst|forwardChainReference|realityUtlsStripped|tagEmpty|tagTaken.'},
    {'method': 'DELETE', 'path': '/chains/{tag}', 'params': {'rebuild': 'true|false'}, 'description': 'Remove chain. Positions of other chains pointing at it are NOT cleaned (the build degrades such a chain as a whole, "chain_hop_missing"); the response lists them in "dangling_refs".'},
    {'method': 'GET', 'path': '/chains/{tag}/probe', 'params': {'url': 'probe URL (default: global ping_options)', 'timeout_ms': 'per-layer budget (default: global ping_options)'}, 'description': 'Layer-by-layer probe: measures PREFIXES of the route (layer k = path from the client through position k) via the tag the core registers for it, "<chain>#<k>" — the same scheme as the launcher (config.ChainLayerTag). A hop price is the difference of neighbouring layers, never a measurement of its own. Needs a running VPN (409 otherwise): those tags exist only in the running core. Positions come from the BUILT config; 409 if the chain is not in it (disabled, degraded, never built). Sequential — worst case positions × timeout_ms. Response: layers[{pos, tag, probe_tag, cumulative_ms?, delta_ms?, error?, not_reached?}]; the first failing layer carries the core text and everything behind it is not_reached.'},
    // Folders CRUD (server folders)
    {'method': 'GET', 'path': '/folders', 'params': {'reveal': 'true|false (raw carries credentials, hidden by default)'}, 'description': 'List folder entries + members (members addressed by positional index)'},
    {'method': 'POST', 'path': '/folders', 'params': {'rebuild': 'true|false'}, 'body': '{"name":"..."}', 'description': 'Create empty folder → 201. Folder meta is edited via PATCH /subs/{id}.'},
    {'method': 'GET', 'path': '/folders/{id}', 'params': {'reveal': 'true|false'}, 'description': 'Single folder + members'},
    {'method': 'DELETE', 'path': '/folders/{id}', 'params': {'keep_servers': 'true|false (default false)', 'rebuild': 'true|false'}, 'description': 'Delete folder. keep_servers=true → members become standalone single servers in place.'},
    {'method': 'POST', 'path': '/folders/{id}/members', 'params': {'rebuild': 'true|false', 'reveal': 'true|false'}, 'body': 'exactly one of {"input":"<uri|WG-ini|JSON>","name_fallback"?} (paste) or {"url":"..."} (one-shot snapshot)', 'description': 'Add members. Snapshot: fetch → static members, URL not stored.'},
    {'method': 'PATCH', 'path': '/folders/{id}/members/{idx}', 'params': {'rebuild': 'true|false', 'reveal': 'true|false'}, 'body': 'Any subset: {raw,enabled,detour}', 'description': 'Edit member. raw must parse (400 keeps old); detour = personal member detour ("" clears).'},
    {'method': 'DELETE', 'path': '/folders/{id}/members/{idx}', 'params': {'rebuild': 'true|false'}, 'description': 'Remove member (indexes shift — use the returned folder snapshot)'},
    {'method': 'POST', 'path': '/folders/{id}/members/reorder', 'params': {'rebuild': 'true|false'}, 'body': '{"order":[old indexes in new order]}', 'description': 'Reorder members (full permutation required)'},
    {'method': 'POST', 'path': '/folders/{id}/members/{idx}/ungroup', 'params': {'rebuild': 'true|false'}, 'description': 'Member → standalone single server after the folder (personal detour → override_detour)'},
    {'method': 'POST', 'path': '/folders/{id}/members/{idx}/move', 'params': {'rebuild': 'true|false'}, 'body': '{"to":"<folder id>"}', 'description': 'Move member to another folder'},
    {'method': 'POST', 'path': '/folders/{id}/move-server', 'params': {'rebuild': 'true|false'}, 'body': '{"server_id":"<subs entry id>"}', 'description': 'Move a standalone single server INTO the folder (splits 1:1 by nodes)'},
    {'method': 'POST', 'path': '/folders/{id}/probe', 'body': 'optional {"url":"...","timeout_ms":N} (defaults = global ping_options)', 'description': 'Headless Test servers run, results in response. Statuses: ok|failed|broken|invalid|not_in_config|pending. Synchronous — lower timeout_ms for big folders (30s request timeout).'},
    // Wi-Fi history (saved networks for routing rule editor)
    {'method': 'GET', 'path': '/wifi_history', 'description': 'List [{ssid, bssid, last_seen}], cap 50'},
    {'method': 'POST', 'path': '/wifi_history', 'body': '{"ssid":"...","bssid":"..."}', 'description': 'Upsert entry; bssid lower-cased'},
    {'method': 'DELETE', 'path': '/wifi_history', 'body': '{"ssid":"...","bssid":"..."}', 'description': 'Remove specific entry'},
    {'method': 'DELETE', 'path': '/wifi_history/all', 'description': 'Clear all entries'},
    // Files
    {'method': 'GET', 'path': '/files/srs/list', 'description': 'Cached SRS [{rule_id,size,mtime}]'},
    {'method': 'GET', 'path': '/files/srs', 'params': {'ruleId': 'id'}, 'description': 'Binary SRS dump'},
    {'method': 'GET', 'path': '/files/local', 'params': {'name': 'cache.db|stderr.log|CrashReport-lxbox.log'}, 'description': 'Whitelisted internal-storage files (filesDir); CrashReport-lxbox.log[.old] = Go panics of the core (§316). `/files/external` — legacy alias.'},
    {'method': 'GET', 'path': '/files/crash/list', 'description': 'Archived core crash reports [{name,size,mtime}], newest first (§316)'},
    {'method': 'GET', 'path': '/files/crash', 'params': {'name': '<file>'}, 'description': 'Body of an archived core crash report (§316)'},
    {'method': 'GET', 'path': '/files/oom/list', 'description': 'Core OOM snapshots [{name,size,mtime,memory_usage,heap_inuse,num_goroutine}], newest first (§318)'},
    {'method': 'GET', 'path': '/files/oom', 'params': {'name': '<snapshot>', 'file': 'metadata.json|heap.pb|allocs.pb|go.log'}, 'description': 'File of an OOM snapshot; default metadata.json (§318)'},
    // Profiler (system-wide)
    {'method': 'POST', 'path': '/profiler/live/start', 'description': 'startGlobalRecording (system-wide). Idempotent.'},
    {'method': 'POST', 'path': '/profiler/live/stop', 'description': 'stopGlobalRecording. Idempotent.'},
    {'method': 'GET', 'path': '/profiler/live/state', 'description': '{recording,started_at,buffer_count,unattributed_count,banner_active}'},
    {'method': 'GET', 'path': '/profiler/live', 'params': {'seconds': 'window (default 60)'}, 'description': 'Global rolling buffer snapshot — TCP/UDP open/close + DNS resolves of all packages.'},
    {'method': 'GET', 'path': '/profiler/live/stream', 'description': 'SSE — system-wide events live.'},
    {'method': 'GET', 'path': '/profiler/live/unattributed', 'description': 'Recent unattributed ring (DNS-fail / TCP without attribution).'},
    // Support feed (§356/§357)
    {'method': 'GET', 'path': '/support/state', 'description': 'support_state.json (read/baseline/snooze/active) + app_version + total_active_seconds'},
    {'method': 'POST', 'path': '/support/reset', 'params': {'keep_active': 'true|false'}, 'description': 'Wipe read/baseline/snooze/cache; keep_active=false also zeroes the activity counter'},
    {'method': 'POST', 'path': '/support/preview', 'params': {'dry': 'true|false', 'snooze_hours': 'N'}, 'description': 'Body = one feed-format message → immediate fullscreen show, gates bypassed; dry=true (default) does not persist markRead/snooze'},
    // Diagnostics
    {'method': 'GET', 'path': '/diag/dump', 'description': 'Full DumpBuilder JSON-pack'},
    {'method': 'GET', 'path': '/diag/exit-info', 'description': 'ApplicationExitInfo entries (API 30+; empty on lower)'},
    {'method': 'GET', 'path': '/diag/logcat', 'params': {'count': '50..5000', 'level': 'V|D|I|W|E|F'}, 'description': 'Logcat tail of our process'},
    {'method': 'GET', 'path': '/diag/stderr', 'description': 'filesDir/stderr.log content (Go panic stacktrace)'},
    {'method': 'GET', 'path': '/diag/applog', 'params': {'prev': 'true|false|all'}, 'description': 'AppLog entries (filter by fromPreviousSession)'},
    {'method': 'GET', 'path': '/diag/pprof', 'params': {'profile': 'goroutine|profile|heap|allocs|block|mutex|threadcreate', 'query': 'raw pprof query w/o ? (gc=1, debug=1, seconds=20); default per profile'}, 'description': 'pprof snapshot via libbox PProfServer (tunnel must be up)'},
    // Settings (scoped writes)
    {'method': 'PUT', 'path': '/settings/route_final', 'body': '{"outbound":"..."}', 'description': 'Set route.final outbound'},
    {'method': 'GET|PUT', 'path': '/settings/interrupt_on_switch', 'body': '{"enabled":bool}', 'description': 'Toggle interrupt connections on node switch'},
    {'method': 'GET|PUT', 'path': '/settings/node_sort', 'body': '{"mode":"latency|manual|","order"?:[...]}', 'description': 'Node-list sort mode + manual order'},
    {'method': 'GET|PUT', 'path': '/settings/enabled_groups', 'body': '{"groups":[...]}', 'description': 'Preset selector membership (config-significant, ?rebuild)'},
    {'method': 'GET|PUT', 'path': '/settings/vpn_mode', 'body': 'partial {mode,proxy_protocol,proxy_port,proxy_listen,proxy_auth,proxy_user,proxy_pass}', 'description': 'VPN/proxy mode (config-significant, ?rebuild)'},
    {'method': 'GET|PUT', 'path': '/settings/ping_options', 'body': 'partial {url?,timeout_ms?,groups?}', 'description': 'URLTest defaults (groups = per-group overrides map)'},
    {'method': 'GET|PUT|DELETE', 'path': '/settings/ping_options/groups/{tag}', 'body': '{url?,timeout_ms?} (PUT, ≥1 required)', 'description': 'Per-group URLTest override; DELETE clears it'},
    {'method': 'GET|PUT', 'path': '/settings/tun_apps', 'body': '{"mode":"off|allow|deny","packages":["pkg",...]}', 'description': 'Per-app tunnel list (config-significant, ?rebuild)'},
    {'method': 'PUT', 'path': '/settings/vars/{key}', 'body': '{"value":"..."}', 'description': 'Set var (blocklist: debug_token/debug_enabled/debug_port)'},
    {'method': 'DELETE', 'path': '/settings/vars/{key}', 'description': 'Delete var'},
    {'method': 'PUT', 'path': '/settings/dns_options/servers', 'body': '{"servers":[...]}', 'description': 'Set DNS servers list'},
    {'method': 'PUT', 'path': '/settings/dns_options/rules', 'body': '{"rules":"<json-string>"}', 'description': 'Set DNS rules (legacy json-string shape)'},
    {'method': 'GET', 'path': '/settings/core_logs_enabled', 'description': 'Whether sing-box logs are forwarded into /logs/core'},
    {'method': 'PUT', 'path': '/settings/core_logs_enabled', 'body': '{"enabled":true|false}', 'description': 'Toggle core-log forwarding (default false)'},
    {'method': 'GET', 'path': '/settings/core_logs_verbose', 'description': 'Whether TRACE/DEBUG core lines pass the volume filter'},
    {'method': 'PUT', 'path': '/settings/core_logs_verbose', 'body': '{"enabled":true|false}', 'description': 'Live toggle for TRACE/DEBUG pass-through (no restart needed)'},
    {'method': 'PUT', 'path': '/settings/config_locked', 'body': '{"locked":true|false}', 'description': 'Toggle auto-rebuild lock — true pins config from UI rebuilds'},
    {'method': 'GET', 'path': '/settings/vpn/allow_bypass', 'description': 'VpnService.Builder.allowBypass() state'},
    {'method': 'PUT', 'path': '/settings/vpn/allow_bypass', 'body': '{"enabled":true|false}', 'description': 'Toggle allowBypass — apply on next establish()'},
    {'method': 'GET', 'path': '/settings/vpn/keep_on_exit', 'description': 'keep-VPN-on-app-exit state'},
    {'method': 'PUT', 'path': '/settings/vpn/keep_on_exit', 'body': '{"enabled":true|false}', 'description': 'Toggle keep-on-exit'},
    {'method': 'GET', 'path': '/settings/vpn/background_mode', 'description': 'tunnel sleep mode (never|lazy|always)'},
    {'method': 'PUT', 'path': '/settings/vpn/background_mode', 'body': '{"mode":"never|lazy|always"}', 'description': 'Set tunnel sleep mode — apply on next VPN connect'},
    // Backup
    {'method': 'GET', 'path': '/backup/export', 'params': {'include': 'storage,vpn_settings (default both)'}, 'description': 'Pure-data snapshot (no diag noise)'},
    {'method': 'POST', 'path': '/backup/import', 'params': {'merge': 'true|false', 'rebuild': 'true|false'}, 'body': '{storage?, vpn_settings?}', 'description': 'Restore from export'},
    // Action additions
    {'method': 'POST', 'path': '/action/preview-empty-state', 'params': {'on': 'true|false'}, 'description': 'Toggle empty-state preview in HomeScreen UI without losing data'},
  ],
  'errors': {
    'envelope': '{"error": {"code": "...", "message": "...", "details": {...}}}',
    // Ключи — строки: JsonEncoder требует String-ключи (int-ключи роняли
    // весь /help?format=json на "Converting object ... failed: _ConstMap").
    'codes': {
      '400': 'BadRequest',
      '401': 'Unauthorized (no/wrong token)',
      '403': 'Forbidden (Host check)',
      '404': 'NotFound',
      '409': 'Conflict (state precondition fail)',
      '500': 'Internal',
    },
  },
  'notes': [
    'Emoji in URL path (✨auto etc.) — must be URL-encoded',
    'Subscription URLs masked default; ?reveal=true for full URL',
    '/rules CRUD: snake_case both ways (domain_suffixes, preset_id, vars_values, dns.server_tag)',
    '/rules resolve option: {only, strategy, server_tag, disable_cache, disable_optimistic_cache, rewrite_ttl, timeout, client_subnet}; null clears',
    'Timestamps — ISO-8601 UTC',
    '`?rebuild=true` on /rules write → automatically rebuild-config',
  ],
};
