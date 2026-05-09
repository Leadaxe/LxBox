import '../../settings_storage.dart';
import '../../../vpn/box_vpn_client.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';
import '_shared.dart';

/// `/settings/*` — scoped writes на `SettingsStorage`. Не generic
/// `PUT /state/storage?key=X` по двум причинам:
///
/// 1. Некоторые ключи критичны и ломают доступ к Debug API
///    (`debug_token`, `debug_enabled`, `debug_port` — blocklist ниже).
/// 2. Для некоторых полей нужна модельная валидация / strict-type
///    (excluded_nodes — set of strings, dns_options.servers — list of
///    object), а не просто String.
///
/// Routes:
/// - `PUT    /settings/route_final`             body `{"outbound":"..."}`
/// - `PUT    /settings/excluded_nodes`          body `{"nodes":["tag",...]}`
/// - `PUT    /settings/vars/{key}`              body `{"value":"..."}`
/// - `DELETE /settings/vars/{key}`              — удалить var
/// - `PUT    /settings/dns_options/servers`     body `{"servers":[...]}`
/// - `PUT    /settings/dns_options/rules`       body `{"rules":"<json-string>"}`
/// - `POST   /settings/rebuild-config`          alias `/action/rebuild-config`
///
/// Все `PUT`/`POST` принимают `?rebuild=true`.
Future<DebugResponse> settingsHandler(DebugRequest req, DebugContext ctx) async {
  final path = req.path;

  switch (path) {
    case '/settings/route_final':
      if (req.method != 'PUT') throw _methodNotAllowed(req.method, path);
      return _putRouteFinal(req, ctx);

    case '/settings/excluded_nodes':
      if (req.method != 'PUT') throw _methodNotAllowed(req.method, path);
      return _putExcludedNodes(req, ctx);

    case '/settings/dns_options/servers':
      if (req.method != 'PUT') throw _methodNotAllowed(req.method, path);
      return _putDnsServers(req, ctx);

    case '/settings/dns_options/rules':
      if (req.method != 'PUT') throw _methodNotAllowed(req.method, path);
      return _putDnsRules(req, ctx);

    case '/settings/rebuild-config':
      if (req.method != 'POST') throw _methodNotAllowed(req.method, path);
      return _rebuildConfig(ctx);

    case '/settings/config_locked':
      if (req.method != 'PUT') throw _methodNotAllowed(req.method, path);
      return _putConfigLocked(req);

    case '/settings/core_logs_enabled':
      if (req.method == 'GET') return _getCoreLogsEnabled();
      if (req.method == 'PUT') return _putCoreLogsEnabled(req);
      throw _methodNotAllowed(req.method, path);

    case '/settings/ping_options':
      if (req.method == 'GET') return _getPingOptions();
      if (req.method == 'PUT') return _putPingOptions(req, ctx);
      throw _methodNotAllowed(req.method, path);

    case '/settings/tun_apps':
      if (req.method == 'GET') return _getTunApps();
      if (req.method == 'PUT') return _putTunApps(req, ctx);
      throw _methodNotAllowed(req.method, path);
  }

  // /settings/ping_options/groups/{tag}
  if (path.startsWith('/settings/ping_options/groups/')) {
    final tag =
        path.substring('/settings/ping_options/groups/'.length);
    if (tag.isEmpty || tag.contains('/')) {
      throw NotFound('settings path: $path');
    }
    return switch (req.method) {
      'GET' => _getGroupPing(tag),
      'PUT' => _putGroupPing(tag, req, ctx),
      'DELETE' => _deleteGroupPing(tag, ctx),
      _ => throw _methodNotAllowed(req.method, path),
    };
  }

  // /settings/vars/{key}
  if (path.startsWith('/settings/vars/')) {
    final key = path.substring('/settings/vars/'.length);
    if (key.isEmpty || key.contains('/')) {
      throw NotFound('settings path: $path');
    }
    return switch (req.method) {
      'PUT' => _putVar(key, req, ctx),
      'DELETE' => _deleteVar(key, req, ctx),
      _ => throw _methodNotAllowed(req.method, path),
    };
  }

  throw NotFound('settings path: $path');
}

BadRequest _methodNotAllowed(String method, String path) =>
    BadRequest('method $method not allowed on $path');

// ---------------------------------------------------------------------------
// route_final
// ---------------------------------------------------------------------------

Future<DebugResponse> _putRouteFinal(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final outbound = fieldString(body, 'outbound');
  if (outbound == null) {
    throw const BadRequest('field "outbound" required (empty string allowed)');
  }
  await SettingsStorage.saveRouteFinal(outbound);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'settings-route-final',
    'outbound': outbound,
    ...extras,
  });
}

// ---------------------------------------------------------------------------
// excluded_nodes
// ---------------------------------------------------------------------------

Future<DebugResponse> _putExcludedNodes(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final nodes = fieldStringList(body, 'nodes');
  if (nodes == null) {
    throw const BadRequest('field "nodes" required (string array)');
  }
  await SettingsStorage.saveExcludedNodes(nodes.toSet());
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'settings-excluded-nodes',
    'count': nodes.length,
    ...extras,
  });
}

// ---------------------------------------------------------------------------
// vars/{key}
// ---------------------------------------------------------------------------

/// Ключи, которые API не вправе перезаписать. Иначе пользователь
/// может заблокировать себе доступ (`debug_token`/`debug_enabled`/`debug_port`).
const Set<String> _varBlocklist = {
  'debug_token',
  'debug_enabled',
  'debug_port',
};

Future<DebugResponse> _putVar(String key, DebugRequest req, DebugContext ctx) async {
  if (_varBlocklist.contains(key)) {
    throw Conflict('var "$key" is managed via App Settings UI only');
  }
  final body = req.jsonBodyAsMap();
  final value = fieldString(body, 'value');
  if (value == null) {
    throw const BadRequest('field "value" required (string)');
  }
  await SettingsStorage.setVar(key, value);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'settings-var-put',
    'key': key,
    'value': value,
    ...extras,
  });
}

Future<DebugResponse> _deleteVar(String key, DebugRequest req, DebugContext ctx) async {
  if (_varBlocklist.contains(key)) {
    throw Conflict('var "$key" is managed via App Settings UI only');
  }
  await SettingsStorage.removeVar(key);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'settings-var-delete',
    'key': key,
    ...extras,
  });
}

// ---------------------------------------------------------------------------
// dns_options
// ---------------------------------------------------------------------------

/// §043: принимает оба формата:
/// - **New (kind-refs):** `[{"enabled":bool, "kind":"inline|preset|template", "tag":str, "body":{...}?}]`.
///   Save as is; render-time resolver `resolveDnsServersList` подхватит.
/// - **Legacy (full-body snapshot):** `[{type, tag, server, server_port, ...}]`.
///   Save as is; на ближайший `resolveDnsServersList` migration auto-конвертирует
///   в kind-refs и persist'нет.
///
/// Detection: presence of `kind` field на любом элементе → new format. Иначе
/// legacy. Mixed формат не поддерживается.
Future<DebugResponse> _putDnsServers(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  if (!body.containsKey('servers')) {
    throw const BadRequest('field "servers" required (list of dns-server objects)');
  }
  final raw = body['servers'];
  if (raw is! List) {
    throw const BadRequest('field "servers" must be array');
  }
  final servers = <Map<String, dynamic>>[];
  for (final s in raw) {
    if (s is! Map) {
      throw const BadRequest('each servers[i] must be an object');
    }
    servers.add(s.cast<String, dynamic>());
  }
  await SettingsStorage.saveDnsServers(servers);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'settings-dns-servers',
    'count': servers.length,
    ...extras,
  });
}

Future<DebugResponse> _putDnsRules(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final rules = fieldString(body, 'rules');
  if (rules == null) {
    throw const BadRequest('field "rules" required (JSON string)');
  }
  await SettingsStorage.saveDnsRules(rules);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'settings-dns-rules',
    'bytes': rules.length,
    ...extras,
  });
}

// ---------------------------------------------------------------------------
// config_locked (§037) — toggle auto-rebuild lock
// ---------------------------------------------------------------------------

/// `PUT /settings/config_locked` — body `{"locked": true|false}`. Когда
/// `true`, `SubscriptionController.generateConfig()` возвращает null
/// silently → UI-driven rebuild'ы не перетирают config записанный через
/// `PUT /config`. Default — `false` (обычный flow).
Future<DebugResponse> _putConfigLocked(DebugRequest req) async {
  final body = req.jsonBodyAsMap();
  final value = body['locked'];
  if (value is! bool) {
    throw const BadRequest('body must be {"locked": true|false}');
  }
  await SettingsStorage.setConfigLockedForDebug(value);
  return JsonResponse({
    'ok': true,
    'action': 'settings-config-locked',
    'locked': value,
  });
}

// ---------------------------------------------------------------------------
// core_logs_enabled (§043) — toggle sing-box log forwarding в AppLog/core.
// Storage хранится в SharedPreferences (`boxvpn_boot.core_logs_enabled`)
// потому что `BoxApplication.initialize` читает его до старта Flutter engine
// (через `BootReceiver.isCoreLogsEnabled`). Доступ через MethodChannel.
//
// Применяется ТОЛЬКО при полном рестарте процесса — `Libbox.setup` с флагом
// `debug` вызывается один раз за жизнь процесса (см. `BoxApplication.kt`,
// гард `if (initialized) return`). Stop/start VPN не помогает: service
// пересоздаётся, но Application/libbox остаются. Caller должен убить процесс
// (force-stop через системные настройки, либо UI-кнопка Quit, которая зовёт
// MethodChannel `quitApp` → `Process.killProcess` + `exitProcess(0)`).
// ---------------------------------------------------------------------------

Future<DebugResponse> _getCoreLogsEnabled() async {
  final enabled = await BoxVpnClient().getCoreLogsEnabled();
  return JsonResponse({'enabled': enabled});
}

Future<DebugResponse> _putCoreLogsEnabled(DebugRequest req) async {
  final body = req.jsonBodyAsMap();
  final value = body['enabled'];
  if (value is! bool) {
    throw const BadRequest('body must be {"enabled": true|false}');
  }
  await BoxVpnClient().setCoreLogsEnabled(value);
  return JsonResponse({
    'ok': true,
    'action': 'settings-core-logs-enabled',
    'enabled': value,
    'note':
        'saved; force-stop & reopen the app to apply (Libbox.setup is '
        'one-shot per process — stop/start VPN does NOT re-apply)',
  });
}

// ---------------------------------------------------------------------------
// ping_options (§040) — global + per-group test settings.
// ---------------------------------------------------------------------------

/// `GET /settings/ping_options` — full structure (`{url?, timeout_ms?, groups?}`).
/// Empty map если не set'нуто (caller fall-through на template default).
Future<DebugResponse> _getPingOptions() async {
  final opts = await SettingsStorage.getPingOptions();
  return JsonResponse(opts);
}

/// `PUT /settings/ping_options` — overwrite целиком. Body: `{url?, timeout_ms?,
/// groups?}`. Caller передаёт final shape; ничего не мержится.
Future<DebugResponse> _putPingOptions(
    DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  // Минимальная валидация — структуры, не URL'ов (sing-box сам не валидирует
  // а delay-call'ом упадёт если URL невалиден).
  if (body.containsKey('url') && body['url'] is! String) {
    throw const BadRequest('field "url" must be string if present');
  }
  if (body.containsKey('timeout_ms') && body['timeout_ms'] is! num) {
    throw const BadRequest('field "timeout_ms" must be number if present');
  }
  if (body.containsKey('groups') && body['groups'] is! Map) {
    throw const BadRequest('field "groups" must be object if present');
  }
  await SettingsStorage.savePingOptions(Map<String, dynamic>.from(body));
  await _reloadHomePingOptions(ctx);
  return JsonResponse({
    'ok': true,
    'action': 'settings-ping-options',
    'url': body['url'],
    'timeout_ms': body['timeout_ms'],
    'groups_count': (body['groups'] is Map) ? (body['groups'] as Map).length : 0,
  });
}

/// `GET /settings/ping_options/groups/{tag}` — override этой группы или 404.
Future<DebugResponse> _getGroupPing(String tag) async {
  final opts = await SettingsStorage.getPingOptions();
  final groups = opts['groups'];
  if (groups is! Map<String, dynamic> || !groups.containsKey(tag)) {
    throw NotFound('group_ping: $tag');
  }
  return JsonResponse(groups[tag] as Map<String, dynamic>);
}

/// `PUT /settings/ping_options/groups/{tag}` — body `{url?, timeout_ms?}`.
/// Минимум одно поле должно быть. Read-modify-write через `setGroupPing`.
Future<DebugResponse> _putGroupPing(
    String tag, DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  String? url;
  int? timeoutMs;
  if (body.containsKey('url')) {
    final v = body['url'];
    if (v is! String) throw const BadRequest('field "url" must be string');
    url = v;
  }
  if (body.containsKey('timeout_ms')) {
    final v = body['timeout_ms'];
    if (v is! num) throw const BadRequest('field "timeout_ms" must be number');
    timeoutMs = v.toInt();
  }
  if (url == null && timeoutMs == null) {
    throw const BadRequest('at least one of "url" / "timeout_ms" required');
  }
  await SettingsStorage.setGroupPing(tag, url: url, timeoutMs: timeoutMs);
  await _reloadHomePingOptions(ctx);
  return JsonResponse({
    'ok': true,
    'action': 'settings-ping-options-group-put',
    'group': tag,
    'url': ?url,
    'timeout_ms': ?timeoutMs,
  });
}

/// `DELETE /settings/ping_options/groups/{tag}` — снять override этой группы.
Future<DebugResponse> _deleteGroupPing(String tag, DebugContext ctx) async {
  await SettingsStorage.clearGroupPing(tag);
  await _reloadHomePingOptions(ctx);
  return JsonResponse({
    'ok': true,
    'action': 'settings-ping-options-group-delete',
    'group': tag,
  });
}

/// HomeController должен перечитать ping_options после write через Debug API
/// — иначе in-memory cache отстаёт. Если controller не registered (early
/// startup) — silently skip; нечего refreshing.
Future<void> _reloadHomePingOptions(DebugContext ctx) async {
  try {
    final home = ctx.registry.home;
    if (home != null) await home.reloadPingOptions();
  } catch (_) {
    // не критично — следующий ping/urltest'оф dialog refresh'нёт
  }
}

// ---------------------------------------------------------------------------
// rebuild-config alias
// ---------------------------------------------------------------------------

Future<DebugResponse> _rebuildConfig(DebugContext ctx) async {
  // §037: явный 409 если lock включён.
  if (await SettingsStorage.getConfigLockedForDebug()) {
    throw const Conflict(
      'config_locked_for_debug=true — rebuild blocked. '
      'PUT /settings/config_locked {"locked":false} to unlock first.',
    );
  }
  final sub = ctx.requireSub();
  final home = ctx.requireHome();
  final json = await sub.generateConfig();
  if (json == null) {
    throw UpstreamError('generate failed: ${sub.lastError}');
  }
  final saved = await home.saveParsedConfig(json);
  if (!saved) {
    throw const UpstreamError('saveParsedConfig returned false');
  }
  return JsonResponse({
    'ok': true,
    'action': 'settings-rebuild-config',
    'config_bytes': json.length,
  });
}

// ─── §046: tun_apps ─────────────────────────────────────────────────────────

Future<DebugResponse> _getTunApps() async {
  final cfg = await SettingsStorage.getTunApps();
  return JsonResponse(cfg.toJson());
}

/// `PUT /settings/tun_apps` — overwrite shape целиком.
/// Body: `{"mode":"off|allow|deny", "packages":["pkg1","pkg2",...]}`.
/// Дубликаты в `packages` schлопываются (idempotent). Невалидные fields → 400.
///
/// Изменения требуют **full VPN restart** для apply (Android tun creates только
/// при `establish()`). Response включает `rebuild_needed: true` как hint клиенту
/// что нужно вызвать `POST /action/rebuild-config` + restart VPN.
Future<DebugResponse> _putTunApps(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();

  final mode = body['mode'];
  if (mode is! String || !['off', 'allow', 'deny'].contains(mode)) {
    throw const BadRequest('field "mode" must be one of: off|allow|deny');
  }

  final pkgsRaw = body['packages'];
  if (pkgsRaw is! List) {
    throw const BadRequest('field "packages" must be array of strings');
  }
  final pkgs = <String>[];
  // Sing-box внутри Android передаёт package в getPackageInfo — там
  // допускается широкий range символов. Отбрасываем явно невалидное:
  // пустые строки + что-то совсем не похожее на package (`/`, whitespace).
  final pkgRe = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)*$');
  for (final p in pkgsRaw) {
    if (p is! String) {
      throw BadRequest('packages[] must be strings; got ${p.runtimeType}');
    }
    final t = p.trim();
    if (t.isEmpty) continue;
    if (!pkgRe.hasMatch(t)) {
      throw BadRequest('invalid package name: $t');
    }
    pkgs.add(t);
  }

  final cfg = TunAppsConfig(mode: mode, packages: pkgs);
  await SettingsStorage.setTunApps(cfg);

  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({
    'ok': true,
    'action': 'settings-tun-apps',
    'mode': mode,
    'count': pkgs.length,
    'rebuild_needed': true,
    ...extras,
  });
}
