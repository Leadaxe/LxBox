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

GET /state                          HomeState dump (tunnel, groups, nodes_count, last_delay, traffic, busy)
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
                                                                 "ib":"chrome","jc":4,"jmin":40,"jmax":70}}
                                                  ?rebuild=true → regenerate config + reload core.

=== Rules CRUD (custom routing rules, spec 030) ===

GET    /rules                                  alias /state/rules
GET    /rules/{id}                             Single rule
POST   /rules[?rebuild=true]                   Create. Body: CustomRule JSON, kind=inline|srs|preset
PATCH  /rules/{id}[?rebuild=true]              Partial update (any subset of fields)
DELETE /rules/{id}[?rebuild=true]              Delete
POST   /rules/reorder                          Body: {"order":[id1,id2,...]} — all ids required

`?rebuild=true` on any write method → automatically triggers rebuild-config.

=== Subscriptions CRUD (user servers + subscriptions) ===

GET    /subs[?reveal=true]                     alias /state/subs. reveal=true → unmasked URLs
GET    /subs/{id}[?reveal=true]                Single entry
POST   /subs[?rebuild=true]                    Create. Body {"input":"<url|URI|WG-conf|JSON-outbounds>"}.
                                                 input runs through the parser pipeline (same as UI paste);
                                                 JSON with multiple outbounds may create several entries.
PATCH  /subs/{id}[?rebuild=true][?reveal=true] Update meta, any subset: {enabled,name,url,tag_prefix,
                                                 update_interval_hours,override_detour,register_detour_servers,
                                                 register_detour_in_auto,use_detour_servers,replace_detour_chain}.
                                                 url applies to SubscriptionServers only (no-op for UserServer).
DELETE /subs/{id}[?rebuild=true]               Remove
POST   /subs/{id}/refresh                      Force HTTP re-fetch (SubscriptionServers only). Fire-and-forget.
POST   /subs/reorder                           Body {"order":[id1,id2,...]} — exactly the current ids

`?rebuild=true` on any write → auto rebuild-config. Writes go through
SubscriptionController (fetch-state machine + UI notify), not SettingsStorage directly.

=== Wi-Fi history (saved networks for routing rule editor) ===

GET    /wifi_history                           list [{ssid, bssid, last_seen}]
POST   /wifi_history                           upsert. body {"ssid": "...", "bssid": "..."}
DELETE /wifi_history                           remove specific. body {"ssid": "...", "bssid": "..."}
DELETE /wifi_history/all                       clear all

Cap 50 entries (LRU evict by last_seen). BSSID is normalized to lower-case.

=== Files (read-only) ===

GET /files/srs/list                            Cached SRS files: [{rule_id, size, mtime}]
GET /files/srs?ruleId=<id>                     Binary SRS dump (octet-stream)
GET /files/local?name=<n>                      Whitelisted internal-storage files (cache.db, stderr.log). `/files/external` — legacy alias.

=== Traffic Profiler (per-app + system-wide) ===

Per-app session (only one active at a time):
POST   /profiler/start                         Body: {"package":"<pkg>", "verbose":false, "secondary_packages":["<pkg>",...]}.
                                                 verbose=true → log_level toggle to debug; secondary_packages →
                                                 events from related apps arrive with confidence=secondary.
                                                 409 if already active (with current id).
POST   /profiler/stop                          Stop active session. 404 if nothing active.
GET    /profiler/active                        Current session metadata. 404 if nothing.
GET    /profiler/sessions                      Last 5 completed sessions (FIFO ring).
DELETE /profiler/sessions                      Clear all completed.
GET    /profiler/session/{id}?include=events,domains,ips
                                                 events — full event log; domains — by-domain agg;
                                                 ips — by-IP agg. Without include — meta only.
DELETE /profiler/session/{id}                  Delete one session.
GET    /profiler/stream                        SSE per-session live stream (requires active session).
PATCH  /profiler/secondary-packages            Body: {"secondary_packages":[...]}; updates live on active.
                                                 Returns 404 if no active session.

System-wide (inclusive observer — Live tab in Statistics):
POST   /profiler/live/start                    startGlobalRecording — subscribes to core logs +
                                                 starts _pollConnections (5s). Idempotent.
POST   /profiler/live/stop                     stopGlobalRecording. Idempotent.
GET    /profiler/live/state                    {recording, started_at, buffer_count, unattributed_count, banner_active}.
GET    /profiler/live?seconds=60               Snapshot of the global rolling buffer for the window (default 60s).
                                                 Returns {window_seconds, count, events:[...]}.
GET    /profiler/live/stream                   SSE — all system-wide events live (DNS resolves +
                                                 TCP/UDP open/close across all packages).
GET    /profiler/live/unattributed             Recent unattributed ring (DNS-fail without owner / TCP without
                                                 process attribution). Used for banner detection.

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
GET|PUT /settings/vpn/allow_bypass              VpnService.Builder.allowBypass(). body {"enabled":bool}.
                                                 Effect at next establish() — reload VPN.
GET|PUT /settings/vpn/keep_on_exit              keep VPN running when app closed. body {"enabled":bool}.
GET|PUT /settings/vpn/background_mode           foreground-service tunnel sleep mode.
                                                 body {"mode":"never|lazy|always"}.
                                                 never (default) — always-on; lazy — pause in deep Doze;
                                                 always — pause on screen-off. Effect at next VPN connect.
POST   /settings/rebuild-config                Alias /action/rebuild-config

=== Backup ===

GET  /backup/export?include=config,vars,subs   Pure-data snapshot for restore (no diag noise). `include` optional; default — all three.
POST /backup/import?merge=false&rebuild=false  Accepts the same shape export returns (plus /diag/dump — diag fields ignored).
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
    {'method': 'GET', 'path': '/state', 'description': 'HomeState dump (tunnel, groups, nodes, traffic)'},
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
    // Logs
    {'method': 'GET', 'path': '/logs', 'params': {'limit': 'N (default 200)', 'source': 'app|core', 'q': 'substring search', 'level': 'comma-separated: error,warn,info,debug'}, 'description': 'AppLog entries'},
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
    {'method': 'POST', 'path': '/rules/reorder', 'body': '{"order":[id,...]}', 'description': 'Reorder (all ids required)'},
    // Subscriptions CRUD (user servers + subscriptions)
    {'method': 'GET', 'path': '/subs', 'params': {'reveal': 'true|false (default false → URLs masked)'}, 'description': 'Alias /state/subs'},
    {'method': 'GET', 'path': '/subs/{id}', 'params': {'reveal': 'true|false'}, 'description': 'Single entry'},
    {'method': 'POST', 'path': '/subs', 'params': {'rebuild': 'true|false'}, 'body': '{"input":"<url|URI|WG-conf|JSON-outbounds>"}', 'description': 'Create via parser pipeline (JSON may create several entries)'},
    {'method': 'PATCH', 'path': '/subs/{id}', 'params': {'rebuild': 'true|false', 'reveal': 'true|false'}, 'body': 'Any subset: {enabled,name,url,tag_prefix,update_interval_hours,override_detour,register_detour_servers,register_detour_in_auto,use_detour_servers,replace_detour_chain}', 'description': 'Update meta. url is SubscriptionServers-only (no-op for UserServer).'},
    {'method': 'DELETE', 'path': '/subs/{id}', 'params': {'rebuild': 'true|false'}, 'description': 'Remove entry'},
    {'method': 'POST', 'path': '/subs/{id}/refresh', 'description': 'Force HTTP re-fetch (SubscriptionServers only). Fire-and-forget.'},
    {'method': 'POST', 'path': '/subs/reorder', 'body': '{"order":[id,...]}', 'description': 'Reorder (exactly the current ids)'},
    // Wi-Fi history (saved networks for routing rule editor)
    {'method': 'GET', 'path': '/wifi_history', 'description': 'List [{ssid, bssid, last_seen}], cap 50'},
    {'method': 'POST', 'path': '/wifi_history', 'body': '{"ssid":"...","bssid":"..."}', 'description': 'Upsert entry; bssid lower-cased'},
    {'method': 'DELETE', 'path': '/wifi_history', 'body': '{"ssid":"...","bssid":"..."}', 'description': 'Remove specific entry'},
    {'method': 'DELETE', 'path': '/wifi_history/all', 'description': 'Clear all entries'},
    // Files
    {'method': 'GET', 'path': '/files/srs/list', 'description': 'Cached SRS [{rule_id,size,mtime}]'},
    {'method': 'GET', 'path': '/files/srs', 'params': {'ruleId': 'id'}, 'description': 'Binary SRS dump'},
    {'method': 'GET', 'path': '/files/local', 'params': {'name': 'cache.db|stderr.log'}, 'description': 'Whitelisted internal-storage files (filesDir). `/files/external` — legacy alias.'},
    // Profiler (per-app + system-wide)
    {'method': 'POST', 'path': '/profiler/start', 'body': '{"package":"<pkg>","verbose":false,"secondary_packages":[...]}', 'description': 'Start per-app session. 409 if already active.'},
    {'method': 'POST', 'path': '/profiler/stop', 'description': 'Stop active session. 404 if none.'},
    {'method': 'GET', 'path': '/profiler/active', 'description': 'Active session metadata or 404.'},
    {'method': 'GET', 'path': '/profiler/sessions', 'description': 'Last 5 completed sessions (FIFO ring).'},
    {'method': 'DELETE', 'path': '/profiler/sessions', 'description': 'Clear all completed.'},
    {'method': 'GET', 'path': '/profiler/session/{id}', 'params': {'include': 'events,domains,ips (any subset)'}, 'description': 'Session details. include=events for full log.'},
    {'method': 'DELETE', 'path': '/profiler/session/{id}', 'description': 'Delete one session.'},
    {'method': 'GET', 'path': '/profiler/stream', 'description': 'SSE per-session live events (requires active).'},
    {'method': 'PATCH', 'path': '/profiler/secondary-packages', 'body': '{"secondary_packages":[...]}', 'description': 'Update secondary packages on active session. POST also accepted.'},
    {'method': 'POST', 'path': '/profiler/live/start', 'description': 'startGlobalRecording (system-wide). Idempotent.'},
    {'method': 'POST', 'path': '/profiler/live/stop', 'description': 'stopGlobalRecording. Idempotent.'},
    {'method': 'GET', 'path': '/profiler/live/state', 'description': '{recording,started_at,buffer_count,unattributed_count,banner_active}'},
    {'method': 'GET', 'path': '/profiler/live', 'params': {'seconds': 'window (default 60)'}, 'description': 'Global rolling buffer snapshot — TCP/UDP open/close + DNS resolves of all packages.'},
    {'method': 'GET', 'path': '/profiler/live/stream', 'description': 'SSE — system-wide events live.'},
    {'method': 'GET', 'path': '/profiler/live/unattributed', 'description': 'Recent unattributed ring (DNS-fail / TCP without attribution).'},
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
    {'method': 'PUT', 'path': '/settings/config_locked', 'body': '{"locked":true|false}', 'description': 'Toggle auto-rebuild lock — true pins config from UI rebuilds'},
    {'method': 'GET', 'path': '/settings/vpn/allow_bypass', 'description': 'VpnService.Builder.allowBypass() state'},
    {'method': 'PUT', 'path': '/settings/vpn/allow_bypass', 'body': '{"enabled":true|false}', 'description': 'Toggle allowBypass — apply on next establish()'},
    {'method': 'GET', 'path': '/settings/vpn/keep_on_exit', 'description': 'keep-VPN-on-app-exit state'},
    {'method': 'PUT', 'path': '/settings/vpn/keep_on_exit', 'body': '{"enabled":true|false}', 'description': 'Toggle keep-on-exit'},
    {'method': 'GET', 'path': '/settings/vpn/background_mode', 'description': 'tunnel sleep mode (never|lazy|always)'},
    {'method': 'PUT', 'path': '/settings/vpn/background_mode', 'body': '{"mode":"never|lazy|always"}', 'description': 'Set tunnel sleep mode — apply on next VPN connect'},
    // Backup
    {'method': 'GET', 'path': '/backup/export', 'params': {'include': 'config,vars,subs (default all)'}, 'description': 'Pure-data snapshot (no diag noise)'},
    {'method': 'POST', 'path': '/backup/import', 'params': {'merge': 'true|false', 'rebuild': 'true|false'}, 'body': '{config?, vars?, server_lists?}', 'description': 'Restore from export or /diag/dump'},
    // Action additions
    {'method': 'POST', 'path': '/action/preview-empty-state', 'params': {'on': 'true|false'}, 'description': 'Toggle empty-state preview in HomeScreen UI without losing data'},
  ],
  'errors': {
    'envelope': '{"error": {"code": "...", "message": "...", "details": {...}}}',
    'codes': {
      400: 'BadRequest',
      401: 'Unauthorized (no/wrong token)',
      403: 'Forbidden (Host check)',
      404: 'NotFound',
      409: 'Conflict (state precondition fail)',
      500: 'Internal',
    },
  },
  'notes': [
    'Emoji in URL path (✨auto etc.) — must be URL-encoded',
    'Subscription URLs masked default; ?reveal=true for full URL',
    '/rules CRUD: snake_case both ways (domain_suffixes, preset_id, vars_values, dns.server_tag)',
    'Timestamps — ISO-8601 UTC',
    '`?rebuild=true` on /rules write → automatically rebuild-config',
  ],
};
