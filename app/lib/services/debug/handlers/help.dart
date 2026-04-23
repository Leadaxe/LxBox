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
GET /state/vpn                      { auto_start, keep_on_exit, is_ignoring_battery_optimizations }

=== Device ===

GET /device                         Android version / SDK / model / ABI / app version / locale / timezone / network type / uptime

=== Config ===

GET /config                         Saved sing-box JSON (raw bytes, no re-encode)
GET /config/pretty                  То же с indent
GET /config/path                    Абсолютный путь к файлу на устройстве

=== Logs ===

GET /logs?limit=N&source=app|core&q=substr&level=error,warn,info,debug
                                    AppLog entries. Все параметры опциональны.
                                      limit  — default 200
                                      source — фильтр по источнику
                                      q      — substring search в message
                                      level  — multi-filter, comma-separated
POST /logs/clear                    Очистить AppLog

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
POST /action/ping-all                          Mass-ping (все ноды активной группы)
POST /action/ping-node?tag=<tag>               Ping одной ноды
POST /action/run-urltest?group=<tag>           Force urltest на группе (см. .now caveat выше)
POST /action/switch-node?tag=<tag>             HomeController.switchNode
POST /action/set-group?group=<tag>             Сменить активную группу
POST /action/rebuild-config                    SubscriptionController.generateConfig + saveParsedConfig
POST /action/refresh-subs?force=true|false     Manual sub-refresh (через AutoUpdater, force обходит cap'ы)
POST /action/download-srs?ruleId=<id>          Скачать SRS для правила
POST /action/clear-srs?ruleId=<id>             Удалить cached SRS
POST /action/toast?msg=<text>&duration=short|long  Android Toast (sanity-check "это моё устройство")
POST /action/emulate-error?kind=<k>            Демо humanizeError в /logs. kind: socket|timeout|http-401|
                                                  http-404|http-410|http-429|http-503|format|fs|plain|all

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
GET /files/external?name=<n>                   Whitelisted внешние файлы (cache.db, stderr.log, stderr.log.old)

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
curl -H "Authorization: Bearer \$TOKEN" -X POST "http://127.0.0.1:9269/action/run-urltest?group=\$TAG"

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
    {'method': 'GET', 'path': '/state/vpn', 'description': 'auto_start, keep_on_exit, battery_whitelisted'},
    // Device
    {'method': 'GET', 'path': '/device', 'description': 'Android version, model, ABI, app version, network, uptime'},
    // Config
    {'method': 'GET', 'path': '/config', 'description': 'Saved sing-box JSON (raw)'},
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
    {'method': 'POST', 'path': '/action/ping-all', 'description': 'Mass-ping active group nodes'},
    {'method': 'POST', 'path': '/action/ping-node', 'params': {'tag': 'node tag'}, 'description': 'Ping one node'},
    {'method': 'POST', 'path': '/action/run-urltest', 'params': {'group': 'group tag (URL-encode emoji)'}, 'description': 'Force urltest on group'},
    {'method': 'POST', 'path': '/action/switch-node', 'params': {'tag': 'node tag'}, 'description': 'Selector switch via HomeController'},
    {'method': 'POST', 'path': '/action/set-group', 'params': {'group': 'group tag'}, 'description': 'Change active group'},
    {'method': 'POST', 'path': '/action/rebuild-config', 'description': 'Regenerate sing-box config'},
    {'method': 'POST', 'path': '/action/refresh-subs', 'params': {'force': 'true|false'}, 'description': 'Manual sub-refresh'},
    {'method': 'POST', 'path': '/action/download-srs', 'params': {'ruleId': 'id'}, 'description': 'Download SRS for a rule'},
    {'method': 'POST', 'path': '/action/clear-srs', 'params': {'ruleId': 'id'}, 'description': 'Clear cached SRS'},
    {'method': 'POST', 'path': '/action/toast', 'params': {'msg': 'text', 'duration': 'short|long'}, 'description': 'Android toast (sanity-check)'},
    {'method': 'POST', 'path': '/action/emulate-error', 'params': {'kind': 'socket|timeout|http-401|http-404|http-410|http-429|http-503|format|fs|plain|all'}, 'description': 'Demo humanizeError in /logs'},
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
    {'method': 'GET', 'path': '/files/external', 'params': {'name': 'cache.db|stderr.log|stderr.log.old'}, 'description': 'Whitelisted external files'},
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
