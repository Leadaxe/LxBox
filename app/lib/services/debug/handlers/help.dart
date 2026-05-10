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

Localhost HTTP сервер для dev-introspection и control. Запущен в Flutter-app'е,
если в App Settings → Developer включён "Debug API toggle". Bind на 127.0.0.1,
порт по умолчанию 9269. Auth: `Authorization: Bearer <token>` (token виден
в App Settings → Developer; копируется через UI кнопку Copy).

Доступ с хоста: `adb forward tcp:9269 tcp:9269`, далее curl на 127.0.0.1:9269.

Спека: docs/spec/features/031 debug api/spec.md
Clash API нюансы: docs/api/clash-api-reference.md

=== Health ===

GET /ping                           Health-check. Без auth. → {"pong":true,"server":"lxbox-debug","uptime_seconds":N}
GET /help[?format=text|json]        Эта карта. Без auth. text (default) — markdown; json — structured.

=== State (read-only) ===

GET /state                          HomeState dump (tunnel, groups, nodes_count, last_delay, traffic, busy)
GET /state/clash                    Clash endpoint info (secret замаскирован)
GET /state/subs[?reveal=true]       Подписки. URL masked default; reveal=true — full URL
GET /state/rules                    CustomRule[] — sealed: inline | srs | preset (с per-kind полями)
GET /state/storage                  Raw SettingsStorage._cache JSON (для отладки)
GET /state/vpn                      { auto_start, keep_on_exit, allow_bypass, background_mode, is_ignoring_battery_optimizations }
GET /state/config_locked            { "locked": bool } — состояние §037 lock'а auto-rebuild

=== Device ===

GET /device                         Android version / SDK / model / ABI / app version / locale / timezone / network type / uptime

=== Config ===

GET /config                         Saved sing-box JSON (raw bytes, no re-encode)
PUT /config                         Перезаписать config.json + reload sing-box. Body: raw
                                      sing-box JSON (Map). Sing-box валидирует на reload —
                                      ошибки прилетают через status events / /logs?source=core.
                                      ВАЖНО: этот override временный — следующий
                                      rebuild-config (или любое UI-действие) сотрёт его.
                                      Чтобы pin'нуть постоянно — PUT /settings/config_locked
                                      {"locked": true} перед write. См. §037.
GET /config/pretty                  То же с indent
GET /config/path                    Абсолютный путь к файлу на устройстве

=== Logs ===

GET /logs?limit=N&source=app|core&q=substr&level=error,warning,info,debug
                                    AppLog entries (§043 per-source quotas:
                                      app=300, core=500 in-memory).
                                      limit  — default 200, max 1000
                                      source — фильтр по источнику
                                      q      — substring search в message
                                      level  — multi-filter, comma-separated
GET /logs/app                       Alias для /logs?source=app. Те же query params.
GET /logs/core                      Alias для /logs?source=core. Те же query params.
POST /logs/clear[?source=app|core]  Очистить AppLog. Без source — всё; иначе только указанный.

=== Clash API (transparent proxy with auto-auth) ===

GET    /clash/version                          sing-box version + meta flags
GET    /clash/proxies                          Все proxies + groups + chains
GET    /clash/proxies/{tag}                    Single proxy/group. emoji-tag URL-encode'ить (или python urllib).
PUT    /clash/proxies/{tag}                    Selector switch. Body: {"name":"<child-tag>"}
GET    /clash/proxies/{tag}/delay?url=&timeout=  Single delay test (ms)
GET    /clash/group/{tag}/delay?url=&timeout=    Force URLTest на группе. ВАЖНО: .now не обновляется
                                                 от этого вызова — sing-box quirk (только первый
                                                 urltest_interval tick меняет .now).
GET    /clash/connections                      { uploadTotal, downloadTotal, memory, connections[] }
DELETE /clash/connections                      Закрыть все
DELETE /clash/connections/{id}                 Закрыть одно
GET    /clash/traffic                          Streaming traffic (curl получает первый фрейм)

=== Actions (mutating, POST) ===

POST /action/start-vpn                         Запустить туннель → {"ok":true,"action":"start-vpn"}
POST /action/stop-vpn                          Остановить
POST /action/reset-network                     Light recovery: closeAllConnections + DNS flush + dialer
                                                  rebind. БЕЗ recreate'а box/Service/TUN. Spec 031.
                                                  Требует tunnel up. → {"ok":true,"action":"reset-network","native_ok":<bool>}
POST /action/urltest?tag=<node>                Single-node URLTest (clash /proxies/<tag>/delay)
POST /action/urltest?group=<group>             Group URLTest (clash /group/<group>/delay, требует tunnel)
POST /action/urltest?all=true                  Mass URLTest всех нод активной группы (concurrency 10)
POST /action/switch-node?tag=<tag>             HomeController.switchNode
POST /action/set-group?group=<tag>             Сменить активную группу
POST /action/rebuild-config                    SubscriptionController.generateConfig + saveParsedConfig
POST /action/refresh-subs?force=true|false     Manual sub-refresh (через AutoUpdater, force обходит cap'ы)
POST /action/download-srs?ruleId=<id>          Скачать SRS для правила
POST /action/clear-srs?ruleId=<id>             Удалить cached SRS
POST /action/toast?msg=<text>&duration=short|long  Android Toast (sanity-check "это моё устройство")
POST /action/emulate-error?kind=<k>            Демо humanizeError в /logs. kind: socket|timeout|http-401|
                                                  http-404|http-410|http-429|http-503|format|fs|plain|all
POST /action/check-updates                     Force update check (bypass 24h cap + auto_check_updates toggle).
POST /action/preview-empty-state?on=true|false UI-only override: рендерить empty-state без потери данных. Полезно для скриншотов/демо/regression UX.
                                                  Returns {kind, tag, html_url, published_at, ...}. Mirrors UI
                                                  "Check now" button. Uses primary api.github.com → fallback
                                                  raw.githubusercontent.com/.../docs/latest.json.

=== Rules CRUD (custom routing rules, spec 030) ===

GET    /rules                                  alias /state/rules
GET    /rules/{id}                             Одно правило
POST   /rules[?rebuild=true]                   Создать. Body: CustomRule JSON, kind=inline|srs|preset
PATCH  /rules/{id}[?rebuild=true]              Partial update (любое подмножество полей)
DELETE /rules/{id}[?rebuild=true]              Удалить
POST   /rules/reorder                          Body: {"order":[id1,id2,...]} — все id обязательны

`?rebuild=true` на любом write-методе → автоматически вызывает rebuild-config.

=== Files (read-only) ===

GET /files/srs/list                            Cached SRS files: [{rule_id, size, mtime}]
GET /files/srs?ruleId=<id>                     Binary SRS dump (octet-stream)
GET /files/local?name=<n>                      Whitelisted internal-storage файлы (cache.db, stderr.log). `/files/external` — legacy alias.

=== Traffic Profiler (§044 per-app + §048 system-wide) ===

Per-app session (в один момент только одна active):
POST   /profiler/start                         Body: {"package":"<pkg>", "verbose":false, "secondary_packages":["<pkg>",...]}.
                                                 verbose=true → log_level toggle на debug; secondary_packages →
                                                 события related apps идут с confidence=secondary.
                                                 409 если уже active (с current id).
POST   /profiler/stop                          Stop active session. 404 если nothing active.
GET    /profiler/active                        Current session metadata. 404 если nothing.
GET    /profiler/sessions                      Last 5 completed sessions (FIFO ring).
DELETE /profiler/sessions                      Clear all completed.
GET    /profiler/session/{id}?include=events,domains,ips
                                                 events — full event log; domains — by-domain agg;
                                                 ips — by-IP agg. Без include — только meta.
DELETE /profiler/session/{id}                  Удалить одну session.
GET    /profiler/stream                        SSE per-session live stream (требует active session).
PATCH  /profiler/secondary-packages            Body: {"secondary_packages":[...]}; обновляет live на active.
                                                 Возвращает 404 если нет active.

System-wide (§048 inclusive observer — Live tab в Statistics):
POST   /profiler/live/start                    startGlobalRecording — подписывает на core logs +
                                                 запускает _pollConnections (5s). Idempotent.
POST   /profiler/live/stop                     stopGlobalRecording. Idempotent.
GET    /profiler/live/state                    {recording, started_at, buffer_count, unattributed_count, banner_active}.
GET    /profiler/live?seconds=60               Snapshot global rolling buffer за окно (default 60s).
                                                 Returns {window_seconds, count, events:[...]}.
GET    /profiler/live/stream                   SSE — все system-wide events live (DNS resolves +
                                                 TCP/UDP open/close по всем packages).
GET    /profiler/live/unattributed             Recent unattributed ring (DNS-fail без owner / TCP без
                                                 process attribution). Используется для banner detection.

=== Diagnostics (§038) ===

GET /diag/dump                                 Полный JSON-pack от DumpBuilder.build (config + vars + subs + log + stderr + exit_info + logcat).
GET /diag/exit-info                            ApplicationExitInfo (последние 5 экзитов от системы); пустой массив на API <30.
GET /diag/logcat?count=N&level=L               Logcat tail нашего процесса (N=50..5000, default 1000; level=V|D|I|W|E|F, default E).
GET /diag/stderr                               Содержимое filesDir/stderr.log (Go panic-stacktrace libbox).
GET /diag/applog?prev=true|false|all           AppLog entries; `prev` фильтрует по fromPreviousSession (default `all`).

=== Settings (scoped writes) ===

PUT    /settings/route_final                   body {"outbound":"..."}
PUT    /settings/excluded_nodes                body {"nodes":["tag",...]}
PUT    /settings/vars/{key}                    body {"value":"..."}; blocklist: debug_token/debug_enabled/debug_port
DELETE /settings/vars/{key}                    Удалить var
PUT    /settings/dns_options/servers           body {"servers":[...]}
PUT    /settings/dns_options/rules             body {"rules":"<json-string>"}
PUT    /settings/config_locked                 §037 toggle auto-rebuild lock. body {"locked":true|false}.
                                                 true → SubscriptionController.generateConfig возвращает null
                                                 silently, custom config через PUT /config не перетирается
                                                 UI-действиями. Default false (обычный flow).
GET    /settings/core_logs_enabled              §043 текущее состояние forwarding sing-box logs в /logs/core.
                                                 → {"enabled": bool}
PUT    /settings/core_logs_enabled              body {"enabled":true|false}. Default false. Применяется
                                                 ТОЛЬКО при рестарте процесса — Libbox.setup one-shot. Stop/
                                                 start VPN НЕ помогает (service пересоздаётся, Application
                                                 живёт). Force-stop приложения + relaunch, либо UI-кнопка
                                                 «Quit & reopen app» в App Settings → Diagnostics или
                                                 Debug screen → Log tab.
GET|PUT /settings/vpn/allow_bypass              §052 VpnService.Builder.allowBypass(). body {"enabled":bool}.
                                                 Effect at next establish() — reload VPN.
GET|PUT /settings/vpn/keep_on_exit              §052 keep VPN running when app closed. body {"enabled":bool}.
GET|PUT /settings/vpn/background_mode           §052 foreground-service tunnel sleep mode.
                                                 body {"mode":"never|lazy|always"}.
                                                 never (default) — always-on; lazy — pause in deep Doze;
                                                 always — pause on screen-off. Effect at next VPN connect.
POST   /settings/rebuild-config                Alias /action/rebuild-config

=== Backup ===

GET  /backup/export?include=config,vars,subs   Pure-data snapshot для restore (без diag-шума). `include` опц.; default — все три.
POST /backup/import?merge=false&rebuild=false  Принимает то же что отдаёт export (плюс /diag/dump — diag-поля игнорятся).
                                                 `merge=true` — append/upsert; `rebuild=true` — auto-rebuild config после restore.

=== Errors ===

Все error responses: {"error": {"code": "...", "message": "...", "details": {...}}}
HTTP status коды: 400 BadRequest, 401 Unauthorized (no/wrong token), 403 Forbidden (Host check),
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

# URLTest на ✨auto (emoji URL-encode'ится)
TAG=\$(python3 -c "import urllib.parse; print(urllib.parse.quote('✨auto'))")
curl -H "Authorization: Bearer \$TOKEN" -X POST "http://127.0.0.1:9269/action/urltest?group=\$TAG"

# Создать inline-правило + rebuild config
curl -H "Authorization: Bearer \$TOKEN" -H "Content-Type: application/json" \\
  -d '{"name":"Block ads","kind":"inline","domain_suffixes":["ads.example.com"],"outbound":"reject"}' \\
  http://127.0.0.1:9269/rules?rebuild=true

# Логи с фильтром
curl -H "Authorization: Bearer \$TOKEN" 'http://127.0.0.1:9269/logs?level=error,warn&q=fetch&limit=20'

=== Notes ===

- emoji в URL path (✨auto и пр.) — обязательно URL-encode. curl сам не делает.
- Subscription URLs masked default (`scheme://host/***`); ?reveal=true для full.
- /rules CRUD принимает snake_case (domain_suffixes, ip_cidrs, preset_id, vars_values),
  возвращает snake_case.
- Все timestamps в ISO-8601 UTC.
- Token stable пока не Regenerate'ut в UI — стабильно для curl-сессий.
''';

const Map<String, dynamic> _capabilityJson = {
  'server': 'lxbox-debug',
  'docs': {
    'spec': 'docs/spec/features/031 debug api/spec.md',
    'clash_reference': 'docs/api/clash-api-reference.md',
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
    {'method': 'GET', 'path': '/state/clash', 'description': 'Clash endpoint info (secret masked)'},
    {'method': 'GET', 'path': '/state/subs', 'params': {'reveal': 'true|false (default false → URLs masked)'}, 'description': 'Subscriptions list'},
    {'method': 'GET', 'path': '/state/rules', 'description': 'CustomRule[] sealed (inline|srs|preset)'},
    {'method': 'GET', 'path': '/state/storage', 'description': 'Raw SettingsStorage._cache JSON'},
    {'method': 'GET', 'path': '/state/vpn', 'description': 'auto_start, keep_on_exit, allow_bypass, background_mode, battery_whitelisted'},
    {'method': 'GET', 'path': '/state/config_locked', 'description': '{locked: bool} — §037 auto-rebuild lock state'},
    // Device
    {'method': 'GET', 'path': '/device', 'description': 'Android version, model, ABI, app version, network, uptime'},
    // Config
    {'method': 'GET', 'path': '/config', 'description': 'Saved sing-box JSON (raw)'},
    {'method': 'PUT', 'path': '/config', 'body': 'raw sing-box JSON (Map)', 'description': 'Overwrite config.json + reload sing-box. Temporary unless /settings/config_locked=true (§037).'},
    {'method': 'GET', 'path': '/config/pretty', 'description': 'Indent-formatted'},
    {'method': 'GET', 'path': '/config/path', 'description': 'On-device file path'},
    // Logs
    {'method': 'GET', 'path': '/logs', 'params': {'limit': 'N (default 200)', 'source': 'app|core', 'q': 'substring search', 'level': 'comma-separated: error,warn,info,debug'}, 'description': 'AppLog entries'},
    {'method': 'POST', 'path': '/logs/clear', 'description': 'Clear AppLog'},
    // Clash proxy
    {'method': 'GET', 'path': '/clash/version', 'description': 'sing-box version + meta flags'},
    {'method': 'GET', 'path': '/clash/proxies', 'description': 'All proxies + groups + chains'},
    {'method': 'GET', 'path': '/clash/proxies/{tag}', 'description': 'Single proxy/group (URL-encode emoji)'},
    {'method': 'PUT', 'path': '/clash/proxies/{tag}', 'body': '{"name":"<child>"}', 'description': 'Selector switch'},
    {'method': 'GET', 'path': '/clash/proxies/{tag}/delay', 'params': {'url': 'test URL', 'timeout': 'ms'}, 'description': 'Single delay test'},
    {'method': 'GET', 'path': '/clash/group/{tag}/delay', 'params': {'url': '...', 'timeout': 'ms'}, 'description': 'Force URLTest on group. NOTE: .now not persisted by this call (sing-box quirk).'},
    {'method': 'GET', 'path': '/clash/connections', 'description': '{uploadTotal,downloadTotal,memory,connections[]}'},
    {'method': 'DELETE', 'path': '/clash/connections', 'description': 'Close all'},
    {'method': 'DELETE', 'path': '/clash/connections/{id}', 'description': 'Close one'},
    {'method': 'GET', 'path': '/clash/traffic', 'description': 'Streaming traffic (curl gets first frame)'},
    // Actions
    {'method': 'POST', 'path': '/action/start-vpn', 'description': 'Start tunnel'},
    {'method': 'POST', 'path': '/action/stop-vpn', 'description': 'Stop tunnel'},
    {'method': 'POST', 'path': '/action/reset-network', 'description': 'Light recovery: closeAll + DNS flush + dialer rebind (spec 031). Requires tunnel up.'},
    {'method': 'POST', 'path': '/action/urltest', 'params': {'tag': 'node tag (single)', 'group': 'group tag (group urltest, URL-encode emoji)', 'all': 'true (mass urltest)'}, 'description': 'URLTest dispatch by query: one of tag/group/all'},
    {'method': 'POST', 'path': '/action/switch-node', 'params': {'tag': 'node tag'}, 'description': 'Selector switch via HomeController'},
    {'method': 'POST', 'path': '/action/set-group', 'params': {'group': 'group tag'}, 'description': 'Change active group'},
    {'method': 'POST', 'path': '/action/rebuild-config', 'description': 'Regenerate sing-box config'},
    {'method': 'POST', 'path': '/action/refresh-subs', 'params': {'force': 'true|false'}, 'description': 'Manual sub-refresh'},
    {'method': 'POST', 'path': '/action/download-srs', 'params': {'ruleId': 'id'}, 'description': 'Download SRS for a rule'},
    {'method': 'POST', 'path': '/action/clear-srs', 'params': {'ruleId': 'id'}, 'description': 'Clear cached SRS'},
    {'method': 'POST', 'path': '/action/toast', 'params': {'msg': 'text', 'duration': 'short|long'}, 'description': 'Android toast (sanity-check)'},
    {'method': 'POST', 'path': '/action/emulate-error', 'params': {'kind': 'socket|timeout|http-401|http-404|http-410|http-429|http-503|format|fs|plain|all'}, 'description': 'Demo humanizeError in /logs'},
    {'method': 'POST', 'path': '/action/check-updates', 'description': 'Force update check (bypass cap + toggle); returns {kind,tag,html_url,...}'},
    // Rules
    {'method': 'GET', 'path': '/rules', 'description': 'Alias /state/rules'},
    {'method': 'GET', 'path': '/rules/{id}', 'description': 'Single rule'},
    {'method': 'POST', 'path': '/rules', 'params': {'rebuild': 'true|false'}, 'body': 'CustomRule JSON (kind: inline|srs|preset)', 'description': 'Create'},
    {'method': 'PATCH', 'path': '/rules/{id}', 'params': {'rebuild': 'true|false'}, 'body': 'Partial CustomRule', 'description': 'Update'},
    {'method': 'DELETE', 'path': '/rules/{id}', 'params': {'rebuild': 'true|false'}, 'description': 'Delete'},
    {'method': 'POST', 'path': '/rules/reorder', 'body': '{"order":[id,...]}', 'description': 'Reorder (all ids required)'},
    // Files
    {'method': 'GET', 'path': '/files/srs/list', 'description': 'Cached SRS [{rule_id,size,mtime}]'},
    {'method': 'GET', 'path': '/files/srs', 'params': {'ruleId': 'id'}, 'description': 'Binary SRS dump'},
    {'method': 'GET', 'path': '/files/local', 'params': {'name': 'cache.db|stderr.log'}, 'description': 'Whitelisted internal-storage files (filesDir). `/files/external` — legacy alias.'},
    // Profiler (§044 per-app + §048 system-wide)
    {'method': 'POST', 'path': '/profiler/start', 'body': '{"package":"<pkg>","verbose":false,"secondary_packages":[...]}', 'description': '§044 Start per-app session. 409 if already active.'},
    {'method': 'POST', 'path': '/profiler/stop', 'description': 'Stop active session. 404 if none.'},
    {'method': 'GET', 'path': '/profiler/active', 'description': 'Active session metadata or 404.'},
    {'method': 'GET', 'path': '/profiler/sessions', 'description': 'Last 5 completed sessions (FIFO ring).'},
    {'method': 'DELETE', 'path': '/profiler/sessions', 'description': 'Clear all completed.'},
    {'method': 'GET', 'path': '/profiler/session/{id}', 'params': {'include': 'events,domains,ips (any subset)'}, 'description': 'Session details. include=events for full log.'},
    {'method': 'DELETE', 'path': '/profiler/session/{id}', 'description': 'Delete one session.'},
    {'method': 'GET', 'path': '/profiler/stream', 'description': 'SSE per-session live events (requires active).'},
    {'method': 'PATCH', 'path': '/profiler/secondary-packages', 'body': '{"secondary_packages":[...]}', 'description': 'Update secondary packages on active session. POST also accepted.'},
    {'method': 'POST', 'path': '/profiler/live/start', 'description': '§048 startGlobalRecording (system-wide). Idempotent.'},
    {'method': 'POST', 'path': '/profiler/live/stop', 'description': '§048 stopGlobalRecording. Idempotent.'},
    {'method': 'GET', 'path': '/profiler/live/state', 'description': '{recording,started_at,buffer_count,unattributed_count,banner_active}'},
    {'method': 'GET', 'path': '/profiler/live', 'params': {'seconds': 'window (default 60)'}, 'description': '§048 global rolling buffer snapshot — TCP/UDP open/close + DNS resolves of all packages.'},
    {'method': 'GET', 'path': '/profiler/live/stream', 'description': '§048 SSE — system-wide events live.'},
    {'method': 'GET', 'path': '/profiler/live/unattributed', 'description': '§048 recent unattributed ring (DNS-fail / TCP без attribution).'},
    // Diagnostics (§038)
    {'method': 'GET', 'path': '/diag/dump', 'description': 'Full DumpBuilder JSON-pack'},
    {'method': 'GET', 'path': '/diag/exit-info', 'description': 'ApplicationExitInfo entries (API 30+; empty on lower)'},
    {'method': 'GET', 'path': '/diag/logcat', 'params': {'count': '50..5000', 'level': 'V|D|I|W|E|F'}, 'description': 'Logcat tail of our process'},
    {'method': 'GET', 'path': '/diag/stderr', 'description': 'filesDir/stderr.log content (Go panic stacktrace)'},
    {'method': 'GET', 'path': '/diag/applog', 'params': {'prev': 'true|false|all'}, 'description': 'AppLog entries (filter by fromPreviousSession)'},
    // Settings (scoped writes — §037 etc)
    {'method': 'PUT', 'path': '/settings/route_final', 'body': '{"outbound":"..."}', 'description': 'Set route.final outbound'},
    {'method': 'PUT', 'path': '/settings/excluded_nodes', 'body': '{"nodes":["tag",...]}', 'description': 'Set hidden-from-auto nodes'},
    {'method': 'PUT', 'path': '/settings/vars/{key}', 'body': '{"value":"..."}', 'description': 'Set var (blocklist: debug_token/debug_enabled/debug_port)'},
    {'method': 'DELETE', 'path': '/settings/vars/{key}', 'description': 'Delete var'},
    {'method': 'PUT', 'path': '/settings/dns_options/servers', 'body': '{"servers":[...]}', 'description': 'Set DNS servers list'},
    {'method': 'PUT', 'path': '/settings/dns_options/rules', 'body': '{"rules":"<json-string>"}', 'description': 'Set DNS rules (legacy json-string shape)'},
    {'method': 'PUT', 'path': '/settings/config_locked', 'body': '{"locked":true|false}', 'description': '§037 toggle auto-rebuild lock — true pins config from UI rebuilds'},
    {'method': 'GET', 'path': '/settings/vpn/allow_bypass', 'description': '§052 VpnService.Builder.allowBypass() state'},
    {'method': 'PUT', 'path': '/settings/vpn/allow_bypass', 'body': '{"enabled":true|false}', 'description': '§052 toggle allowBypass — apply on next establish()'},
    {'method': 'GET', 'path': '/settings/vpn/keep_on_exit', 'description': '§052 keep-VPN-on-app-exit state'},
    {'method': 'PUT', 'path': '/settings/vpn/keep_on_exit', 'body': '{"enabled":true|false}', 'description': '§052 toggle keep-on-exit'},
    {'method': 'GET', 'path': '/settings/vpn/background_mode', 'description': '§052 tunnel sleep mode (never|lazy|always)'},
    {'method': 'PUT', 'path': '/settings/vpn/background_mode', 'body': '{"mode":"never|lazy|always"}', 'description': '§052 set tunnel sleep mode — apply on next VPN connect'},
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
    'Emoji в URL path (✨auto и пр.) — обязательно URL-encode',
    'Subscription URLs masked default; ?reveal=true для full URL',
    '/rules CRUD: snake_case в обе стороны (domain_suffixes, preset_id, vars_values)',
    'Timestamps — ISO-8601 UTC',
    '`?rebuild=true` на /rules write → автоматически rebuild-config',
  ],
};
