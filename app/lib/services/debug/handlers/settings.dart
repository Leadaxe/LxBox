import '../../../models/background_mode.dart';
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
///    (dns_options.servers — list of object), а не просто String.
///
/// Routes:
/// - `PUT    /settings/route_final`             body `{"outbound":"..."}`
/// - `PUT    /settings/vars/{key}`              body `{"value":"..."}`
/// - `DELETE /settings/vars/{key}`              — удалить var
/// - `PUT    /settings/dns_options/servers`     body `{"servers":[...]}`
/// - `PUT    /settings/dns_options/rules`       body `{"rules":"<json-string>"}`
/// - `GET|PUT /settings/vpn/allow_bypass`        body `{"enabled":bool}`
/// - `GET|PUT /settings/vpn/keep_on_exit`        body `{"enabled":bool}`
/// - `GET|PUT /settings/vpn/background_mode`     body `{"mode":"never|lazy|always"}`
/// - `POST   /settings/rebuild-config`          alias `/action/rebuild-config`
///
/// Все `PUT`/`POST` принимают `?rebuild=true`.
Future<DebugResponse> settingsHandler(DebugRequest req, DebugContext ctx) async {
  final path = req.path;

  switch (path) {
    case '/settings/route_final':
      if (req.method != 'PUT') throw _methodNotAllowed(req.method, path);
      return _putRouteFinal(req, ctx);

    case '/settings/interrupt_on_switch':
      if (req.method == 'GET') return _getInterruptOnSwitch();
      if (req.method == 'PUT') return _putInterruptOnSwitch(req);
      throw _methodNotAllowed(req.method, path);

    case '/settings/node_sort':
      if (req.method == 'GET') return _getNodeSort();
      if (req.method == 'PUT') return _putNodeSort(req);
      throw _methodNotAllowed(req.method, path);

    case '/settings/enabled_groups':
      if (req.method == 'GET') return _getEnabledGroups();
      if (req.method == 'PUT') return _putEnabledGroups(req, ctx);
      throw _methodNotAllowed(req.method, path);

    case '/settings/vpn_mode':
      if (req.method == 'GET') return _getVpnMode();
      if (req.method == 'PUT') return _putVpnMode(req, ctx);
      throw _methodNotAllowed(req.method, path);

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

    case '/settings/vpn/allow_bypass':
      if (req.method == 'GET') return _getAllowBypass();
      if (req.method == 'PUT') return _putAllowBypass(req);
      throw _methodNotAllowed(req.method, path);

    case '/settings/vpn/keep_on_exit':
      if (req.method == 'GET') return _getKeepOnExit();
      if (req.method == 'PUT') return _putKeepOnExit(req);
      throw _methodNotAllowed(req.method, path);

    case '/settings/vpn/background_mode':
      if (req.method == 'GET') return _getBackgroundMode();
      if (req.method == 'PUT') return _putBackgroundMode(req);
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
// §163/§047 — top-level настройки без vars-доступа (нужен типизированный роут).
// ---------------------------------------------------------------------------

/// `GET /settings/interrupt_on_switch` → `{"enabled": bool}`.
Future<DebugResponse> _getInterruptOnSwitch() async {
  final v = await SettingsStorage.getInterruptOnSwitch();
  return JsonResponse({'ok': true, 'enabled': v});
}

/// `PUT /settings/interrupt_on_switch` body `{"enabled": bool}`. Тугл рвёт
/// активные соединения переключаемой группы при switchNode. НЕ config-significant.
Future<DebugResponse> _putInterruptOnSwitch(DebugRequest req) async {
  final body = req.jsonBodyAsMap();
  final enabled = fieldBool(body, 'enabled');
  if (enabled == null) throw const BadRequest('field "enabled" (bool) required');
  await SettingsStorage.setInterruptOnSwitch(enabled);
  return JsonResponse({'ok': true, 'action': 'settings-interrupt-on-switch', 'enabled': enabled});
}

/// `GET /settings/node_sort` → `{"mode": str, "order": [str]}`.
Future<DebugResponse> _getNodeSort() async {
  final s = await SettingsStorage.getNodeSort();
  return JsonResponse({'ok': true, 'mode': s.mode, 'order': s.order});
}

/// `PUT /settings/node_sort` body `{"mode": str, "order"?: [str]}`. Режим
/// сортировки нод (`""`/`latency`/`manual`) + ручной порядок (для manual).
/// UI-only (не config-significant).
Future<DebugResponse> _putNodeSort(DebugRequest req) async {
  final body = req.jsonBodyAsMap();
  final mode = fieldString(body, 'mode');
  if (mode == null) throw const BadRequest('field "mode" (string) required');
  final order = fieldStringList(body, 'order') ?? const <String>[];
  await SettingsStorage.setNodeSort(mode, order);
  return JsonResponse({'ok': true, 'action': 'settings-node-sort', 'mode': mode, 'order_count': order.length});
}

/// `GET /settings/enabled_groups` → `{"groups": [str]}`.
Future<DebugResponse> _getEnabledGroups() async {
  final g = await SettingsStorage.getEnabledGroups();
  return JsonResponse({'ok': true, 'groups': g.toList()});
}

/// `PUT /settings/enabled_groups` body `{"groups": [str]}`. Членство preset-групп
/// в selector'е. Config-significant → `?rebuild=true` пересобирает конфиг.
Future<DebugResponse> _putEnabledGroups(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final groups = fieldStringList(body, 'groups');
  if (groups == null) throw const BadRequest('field "groups" (string array) required');
  await SettingsStorage.saveEnabledGroups(groups.toSet());
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({'ok': true, 'action': 'settings-enabled-groups', 'count': groups.length, ...extras});
}

/// `GET /settings/vpn_mode` → текущий VpnModeConfig.
Future<DebugResponse> _getVpnMode() async {
  final m = await SettingsStorage.getVpnMode();
  return JsonResponse({'ok': true, 'vpn_mode': m.toJson()});
}

/// `PUT /settings/vpn_mode` body — частичное обновление (copyWith поверх
/// текущего): `mode`/`proxy_protocol`/`proxy_port`/`proxy_listen`/`proxy_auth`/
/// `proxy_user`/`proxy_pass`. Config-significant (меняет inbounds) → `?rebuild=true`.
Future<DebugResponse> _putVpnMode(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final cur = await SettingsStorage.getVpnMode();
  final listen = fieldString(body, 'proxy_listen');
  if (listen != null && !VpnModeConfig.isValidListenAddr(listen)) {
    throw BadRequest('invalid "proxy_listen" (IPv4 required): $listen');
  }
  final next = cur.copyWith(
    mode: fieldString(body, 'mode'),
    proxyProtocol: fieldString(body, 'proxy_protocol'),
    proxyPort: fieldInt(body, 'proxy_port'),
    proxyListen: listen,
    proxyAuthEnabled: fieldBool(body, 'proxy_auth'),
    proxyUsername: fieldString(body, 'proxy_user'),
    proxyPassword: fieldString(body, 'proxy_pass'),
  );
  await SettingsStorage.setVpnMode(next);
  final extras = await maybeRebuild(req, ctx);
  return JsonResponse({'ok': true, 'action': 'settings-vpn-mode', 'vpn_mode': next.toJson(), ...extras});
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
  // §189 — из JSON-зеркала native_prefs (истина).
  final enabled =
      await SettingsStorage.getNativeBool(NativePrefsKeys.coreLogsEnabled);
  return JsonResponse({'enabled': enabled});
}

Future<DebugResponse> _putCoreLogsEnabled(DebugRequest req) async {
  final body = req.jsonBodyAsMap();
  final value = body['enabled'];
  if (value is! bool) {
    throw const BadRequest('body must be {"enabled": true|false}');
  }
  // §189 — через NativePrefs (JSON + зеркало; не эфемерно при sync).
  await SettingsStorage.setNativeBool(NativePrefsKeys.coreLogsEnabled, value);
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
  // §159 — strip unknown subkeys: пишем только известные поля ping_options
  // (url/timeout_ms/presets/groups), чтобы произвольный ключ тела не замусоривал
  // storage. Это вход данных → default-deny, как в backup-import allowlist.
  const allowedPingKeys = {'url', 'timeout_ms', 'presets', 'groups'};
  final clean = <String, dynamic>{
    for (final e in body.entries)
      if (allowedPingKeys.contains(e.key)) e.key: e.value,
  };
  await SettingsStorage.savePingOptions(clean);
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

// ─── §052: VPN Settings → System tab toggles ────────────────────────────────
// Storage / apply семантика — native (SharedPreferences), не lxbox_settings.json.
// Apply timing: allow_bypass / background_mode → next openTun (start/reload);
// keep_on_exit → effect at app exit (нет live reload).

Future<DebugResponse> _getAllowBypass() async {
  final v = await SettingsStorage.getNativeBool(NativePrefsKeys.allowBypass);
  return JsonResponse({'enabled': v});
}

Future<DebugResponse> _putAllowBypass(DebugRequest req) async {
  final body = req.jsonBodyAsMap();
  final value = body['enabled'];
  if (value is! bool) {
    throw const BadRequest('body must be {"enabled": true|false}');
  }
  await SettingsStorage.setNativeBool(NativePrefsKeys.allowBypass, value);
  return JsonResponse({
    'ok': true,
    'action': 'settings-vpn-allow-bypass',
    'enabled': value,
    'note': 'reload VPN to apply (allowBypass set at next establish())',
  });
}

Future<DebugResponse> _getKeepOnExit() async {
  final v = await SettingsStorage.getNativeBool(NativePrefsKeys.keepOnExit);
  return JsonResponse({'enabled': v});
}

Future<DebugResponse> _putKeepOnExit(DebugRequest req) async {
  final body = req.jsonBodyAsMap();
  final value = body['enabled'];
  if (value is! bool) {
    throw const BadRequest('body must be {"enabled": true|false}');
  }
  await SettingsStorage.setNativeBool(NativePrefsKeys.keepOnExit, value);
  return JsonResponse({
    'ok': true,
    'action': 'settings-vpn-keep-on-exit',
    'enabled': value,
  });
}

Future<DebugResponse> _getBackgroundMode() async {
  final m = await SettingsStorage.getNativeBackgroundMode();
  return JsonResponse({'mode': BackgroundMode.fromNative(m).wireValue});
}

Future<DebugResponse> _putBackgroundMode(DebugRequest req) async {
  final body = req.jsonBodyAsMap();
  final raw = body['mode'];
  if (raw is! String) {
    throw const BadRequest('body must be {"mode": "never"|"lazy"|"always"}');
  }
  if (!const {'never', 'lazy', 'always'}.contains(raw)) {
    throw BadRequest('mode must be one of: never|lazy|always (got "$raw")');
  }
  final mode = BackgroundMode.fromNative(raw);
  await SettingsStorage.setNativeBackgroundMode(mode.wireValue);
  return JsonResponse({
    'ok': true,
    'action': 'settings-vpn-background-mode',
    'mode': mode.wireValue,
    'note': 'applied on next VPN connect',
  });
}
