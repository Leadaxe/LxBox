import '../../settings_storage.dart';
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
// rebuild-config alias
// ---------------------------------------------------------------------------

Future<DebugResponse> _rebuildConfig(DebugContext ctx) async {
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
