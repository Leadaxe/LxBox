/// §750 — шлюз ИИ-ассистента к Debug API.
///
/// Натив (`AssistantBridge`, функции `callApi` / `getApiHelp`) зовёт Dart
/// методом канала `assistantCall` `{method, path, body?}` и ждёт
/// `{status, body}`. Запрос проходит политику ([assistantPolicy]) и уходит тем
/// же обработчикам, что обслуживают Debug API ([buildDebugRouter], тот же
/// [DebugContext], то же отображение ошибок `errorMapper`), минуя
/// HTTP-сервер, токен и проверку Host. Включён ли сам Debug API (сервер на
/// порту) — не важно: контекст собирается из [DebugRegistry], который
/// биндится в `HomeScreen.initState` независимо от сервера.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../vpn/box_vpn_client.dart';
import '../app_log.dart';
import '../debug/bootstrap.dart' show appStartedAt;
import '../debug/context.dart';
import '../debug/contract/errors.dart';
import '../debug/debug_registry.dart';
import '../debug/transport/middleware/error_mapper.dart';
import '../debug/transport/middleware/timeout.dart';
import '../debug/transport/pipeline.dart';
import '../debug/transport/request.dart';
import '../debug/transport/response.dart';
import '../debug/transport/router.dart';
import '../debug/transport/server.dart' show buildDebugRouter;
import '../settings_storage.dart';
import '../url_mask.dart' show maskNetworkAddresses;

/// Решение политики шлюза.
enum AssistantAccess {
  /// Чтения, диагностика, VPN и выбор выхода — исполняется всегда.
  allow,

  /// Изменения сохранённой конфигурации — только при включённом тумблере
  /// «Let assistants change settings» (`appfunctions_allow_changes`).
  changes,

  /// Закрыто для ассистента.
  deny,
}

/// Предел тела ответа ассистенту.
const int kAssistantGatewayMaxResponseBytes = 64 * 1024;

/// Предел тела запроса — как у Debug API (`DebugServerConfig.maxBodyBytes`).
const int _kMaxRequestBytes = 1024 * 1024;

/// Путь справки, который обслуживает сам шлюз.
const String kAssistantHelpPath = '/assistant/help';

const String _kForbidden =
    '{"error":"forbidden: this route is not available to assistants"}';
const String _kChangesOff = 'Changing settings is turned off in L×Box: '
    'App Settings → Automation → Let assistants change settings.';
const String _kNotReady = '{"error":"not_ready"}';

/// Параметры запроса, при которых маршрут закрыт целиком: `reveal` отдаёт
/// ссылки подписок и тела узлов (ключи); `warnings` — значения полей узлов
/// (адреса серверов) в предупреждениях разбора.
const Set<String> _kDeniedQueryKeys = {'reveal', 'warnings'};

/// `GET /settings/{…}` — чтения настроек без секретов. `vpn_mode` закрыт:
/// ответ несёт `proxy_password` локального прокси.
const Set<String> _kSettingsReads = {
  'node_sort',
  'enabled_groups',
  'tun_apps',
  'ping_options',
};

/// `PUT /settings/{…}` — изменения (группа «Изменения»). `vpn_mode` закрыт:
/// смена режима открывает локальный прокси (адрес, пароль).
const Set<String> _kSettingsWrites = {
  'route_final',
  'node_sort',
  'enabled_groups',
  'tun_apps',
};

/// `POST /action/{…}` без изменения сохранённой конфигурации.
const Set<String> _kActionsAllow = {
  'check-config',
  'urltest',
  'urltest-all',
  'start-vpn-headless',
  'stop-vpn',
  'reconnect',
  'reload-vpn',
  'reset-network',
  'switch-node',
  'set-group',
};

/// `POST /action/{…}` — изменения.
const Set<String> _kActionsChanges = {'refresh-subs', 'rebuild-config'};

/// `PATCH /subs/{id}` — поля, которые ассистент вправе менять: включить или
/// выключить источник и переименовать его. `url`, `tag_prefix`, обход и
/// прочее закрыты — смена ссылки подменяет выход целиком (как `POST /subs`).
const Set<String> _kSubsPatchKeys = {'enabled', 'name'};

/// §750 — политика шлюза: чистая функция `(method, path, query)`.
///
/// Белый список; всё, чего в нём нет, — [AssistantAccess.deny]. [path] — без
/// строки запроса, [query] — её параметры.
AssistantAccess assistantPolicy(
  String method,
  String path,
  Map<String, String> query,
) {
  if (query.keys.any(_kDeniedQueryKeys.contains)) return AssistantAccess.deny;
  if (!path.startsWith('/') || path.contains('//') || path.contains('..')) {
    return AssistantAccess.deny;
  }
  final m = method.trim().toUpperCase();
  final s = path.substring(1).split('/');
  if (s.any((x) => x.isEmpty)) return AssistantAccess.deny;
  final n = s.length;
  const allow = AssistantAccess.allow;
  const changes = AssistantAccess.changes;
  const deny = AssistantAccess.deny;

  switch (m) {
    case 'GET':
      return switch (s[0]) {
        // Чтения.
        'state' when n == 1 => allow,
        'state' when n == 2 && const {'rules', 'vpn', 'subs'}.contains(s[1]) =>
          allow,
        'rules' || 'directions' when n <= 2 => allow,
        // /subs, /subs/{id}, /subs/{id}/rules, /subs/{id}/rules/{idx}.
        'subs' when n <= 2 => allow,
        'subs' when (n == 3 || n == 4) && s[2] == 'rules' => allow,
        'folders' when n <= 2 => allow,
        // GET /chains, /chains/{tag} закрыты: `rewrite` — произвольный
        // merge-patch опций узла, в нём могут лежать адреса и ключи.
        'chains' when n == 3 && s[2] == 'probe' => allow, // диагностика
        'pool' when n == 1 => allow,
        'assistant' when n == 2 => allow,
        'settings' when n == 2 && _kSettingsReads.contains(s[1]) => allow,
        _ => deny,
      };

    case 'POST':
      return switch (s[0]) {
        'assistant' when n == 2 => switch (s[1]) {
            'check-url' || 'check-exit' || 'exit' => allow,
            'connection' => changes,
            _ => deny,
          },
        'action' when n == 2 && _kActionsAllow.contains(s[1]) => allow,
        'action' when n == 2 && _kActionsChanges.contains(s[1]) => changes,
        'folders' when n == 3 && s[2] == 'probe' => allow,
        'rules' || 'directions' => changes,
        'subs' when n == 3 && s[2] == 'refresh' => changes,
        'settings' when n == 2 && s[1] == 'rebuild-config' => changes,
        _ => deny,
      };

    case 'PATCH':
      return switch (s[0]) {
        'rules' || 'directions' => changes,
        'subs' when n == 2 => changes,
        _ => deny,
      };

    case 'DELETE':
      return switch (s[0]) {
        'rules' || 'directions' => changes,
        _ => deny,
      };

    case 'PUT':
      return s[0] == 'settings' && n == 2 && _kSettingsWrites.contains(s[1])
          ? changes
          : deny;
  }
  return deny;
}

/// Роутер Debug API для шлюза — тот же, что у сервера; строится один раз.
final Router _router = buildDebugRouter();

/// §750 — исполнить вызов ассистента. Исключения наружу не выходят: любой
/// сбой — `500` с сообщением.
///
/// [registry], [maxResponseBytes] — inject-точки тестов.
Future<({int status, String body})> assistantGatewayCall(
  String method,
  String path,
  String? body, {
  DebugRegistry? registry,
  int maxResponseBytes = kAssistantGatewayMaxResponseBytes,
}) async {
  final m = method.trim().toUpperCase();
  try {
    final r = await _call(m, path, body,
        registry: registry ?? DebugRegistry.I,
        maxResponseBytes: maxResponseBytes);
    AppLog.I.info('[assistant] $m ${_pathOnly(path)} → ${r.status}');
    return r;
  } catch (e, st) {
    AppLog.I.error('[assistant] $m ${_pathOnly(path)} → 500: $e\n$st');
    return (status: 500, body: jsonEncode({'error': 'internal error: $e'}));
  }
}

/// §750 — поставить приём `assistantCall` (зовётся из `main()` рядом с
/// мостом автоматизации). Только регистрация: ничего не считается.
void registerAssistantGatewayBridge() =>
    BoxVpnClient.I.registerAssistantCallHandler(assistantGatewayBridgeCall);

/// §750 — ответ по контракту моста (`{status, body}`).
Future<Map<String, Object?>> assistantGatewayBridgeCall(
  String method,
  String path,
  String? body,
) async {
  final r = await assistantGatewayCall(method, path, body);
  return {'status': r.status, 'body': r.body};
}

/// Путь без строки запроса — для журнала (значения параметров не пишем).
String _pathOnly(String path) {
  final i = path.indexOf('?');
  return i < 0 ? path : path.substring(0, i);
}

({int status, String body}) _error(int status, String message) =>
    (status: status, body: jsonEncode({'error': message}));

Future<({int status, String body})> _call(
  String m,
  String rawPath,
  String? body, {
  required DebugRegistry registry,
  required int maxResponseBytes,
}) async {
  final Uri uri;
  final Map<String, String> query;
  try {
    uri = Uri.parse(rawPath.trim());
    query = uri.queryParameters;
  } on FormatException catch (e) {
    return _error(400, 'bad path: ${e.message}');
  }
  if (uri.hasScheme || uri.hasAuthority || !uri.path.startsWith('/')) {
    return _error(400, 'path must start with "/", without host');
  }

  if (m == 'GET' && uri.path == kAssistantHelpPath) {
    return _help(registry, maxResponseBytes);
  }

  final access = assistantPolicy(m, uri.path, query);
  if (access == AssistantAccess.deny) {
    return (status: 403, body: _kForbidden);
  }

  final bytes = Uint8List.fromList(utf8.encode(body ?? ''));
  if (bytes.length > _kMaxRequestBytes) {
    return _error(413, 'request body too large');
  }

  if (access == AssistantAccess.changes) {
    if (!await SettingsStorage.getAppFunctionsAllowChanges()) {
      return _error(403, _kChangesOff);
    }
    if (m == 'PATCH' && uri.path.startsWith('/subs/')) {
      final denied = _subsPatchDeniedKeys(bytes);
      if (denied.isNotEmpty) {
        return _error(
            403,
            'forbidden: assistants may change only '
            '${_kSubsPatchKeys.join(', ')} of a source, not ${denied.join(', ')}');
      }
    }
  }

  if (!registry.ready) return (status: 503, body: _kNotReady);

  final ctx = DebugContext(registry: registry, appStartedAt: appStartedAt);
  final req = DebugRequest(
    method: m,
    uri: uri,
    headers: const {
      'content-type': ['application/json'],
    },
    body: bytes,
    receivedAt: DateTime.now(),
  );
  final resp = await runPipeline(
    req,
    ctx,
    [errorMapper, timeoutMiddleware(ctx.config.requestTimeout)],
    _router.handle,
  );
  return _encode(resp, uri.path, maxResponseBytes);
}

/// Ключи тела `PATCH /subs/{id}` вне [_kSubsPatchKeys]. Не-JSON тело — пусто:
/// его отвергнет сам обработчик (400).
List<String> _subsPatchDeniedKeys(Uint8List bytes) {
  if (bytes.isEmpty) return const [];
  try {
    final parsed = jsonDecode(utf8.decode(bytes));
    if (parsed is! Map) return const [];
    return [
      for (final k in parsed.keys)
        if (!_kSubsPatchKeys.contains(k)) '$k',
    ];
  } on FormatException {
    return const [];
  }
}

({int status, String body}) _encode(
  DebugResponse resp,
  String path,
  int maxResponseBytes,
) {
  final String text;
  switch (resp) {
    case ErrorResponse(:final error):
      // «controller not ready» — та же неготовность, что пустой реестр.
      if (error is Conflict && error.message.contains('controller not ready')) {
        return (status: 503, body: _kNotReady);
      }
      text = jsonEncode(error.toJson());
    case JsonResponse(:final body):
      text = jsonEncode(
          path.startsWith('/assistant/') ? body : scrubAssistantErrors(body));
    case RawJsonResponse(:final raw):
      text = raw;
    case BytesResponse() || SseResponse():
      return _error(415, 'response is not JSON');
  }
  if (utf8.encode(text).length > maxResponseBytes) {
    return _error(413, 'response too large: narrow the request');
  }
  return (status: resp.status, body: text);
}

/// Поля с текстом ошибки ядра/сборки, в которых может оказаться адрес
/// сервера (`dial tcp 1.2.3.4:443: …`).
const Set<String> _kErrorTextKeys = {'error', 'last_error', 'last_start_error'};

/// §750 — скрыть сетевые адреса в текстах ошибок ответа обработчика Debug API
/// (`GET /state`, пробы, `check-config`): адрес сервера ассистенту не
/// отдаётся. Ответы `/assistant/*` не трогаются — их форму задаёт натив, а
/// `check-exit` отдаёт внешний адрес выхода намеренно.
Object? scrubAssistantErrors(Object? v) {
  if (v is Map) {
    return {
      for (final e in v.entries)
        '${e.key}': e.value is String && _kErrorTextKeys.contains(e.key)
            ? maskNetworkAddresses(e.value as String)
            : scrubAssistantErrors(e.value),
    };
  }
  if (v is List) return [for (final x in v) scrubAssistantErrors(x)];
  return v;
}

/// `GET /assistant/help` — карта маршрутов из `/help?format=json`,
/// отфильтрованная политикой: только allow и changes; у changes пометка
/// `"requires": "change_permission"`. Запись `GET|PUT` раскладывается по
/// методам.
Future<({int status, String body})> _help(
  DebugRegistry registry,
  int maxResponseBytes,
) async {
  final ctx = DebugContext(registry: registry, appStartedAt: appStartedAt);
  final resp = await _router.handle(
    DebugRequest(
      method: 'GET',
      uri: Uri(path: '/help', queryParameters: const {'format': 'json'}),
      headers: const {},
      body: Uint8List(0),
      receivedAt: DateTime.now(),
    ),
    ctx,
  );
  final full = (resp as JsonResponse).body as Map;
  final endpoints = <Map<String, Object?>>[];
  for (final raw in (full['endpoints'] as List).cast<Map>()) {
    final path = '${raw['path']}';
    // `{id}` / `{tag}` / `{idx}` → образец сегмента для политики.
    final probe = path.replaceAll(RegExp(r'\{[^}]*\}'), 'x');
    for (final method in '${raw['method']}'.split('|')) {
      final access = assistantPolicy(method, probe, const {});
      if (access == AssistantAccess.deny) continue;
      endpoints.add({
        for (final e in raw.entries)
          if (e.key != 'auth') '${e.key}': e.value,
        'method': method,
        if (access == AssistantAccess.changes) 'requires': 'change_permission',
      });
    }
  }
  final body = {
    'server': 'lxbox-assistant-gateway',
    'usage': 'callApi(method, path, body): path with query string, body is a '
        'JSON string. Response: status (HTTP code) and body (JSON).',
    'limits': {
      'response_bytes': maxResponseBytes,
      'over_limit': '413 — narrow the request',
    },
    'change_permission': 'Routes marked "requires": "change_permission" run '
        'only when the user turned on App Settings → Automation → '
        'Let assistants change settings; otherwise 403.',
    'notes': [
      'Any route not listed here answers 403.',
      'Query parameters reveal and warnings are not available (403).',
      'PATCH /subs/{id} accepts only enabled and name.',
      'Network addresses in error texts are masked.',
      'Directions are addressed by tag (see GET /directions).',
    ],
    'endpoints': endpoints,
    'errors': full['errors'],
  };
  final text = jsonEncode(body);
  if (utf8.encode(text).length > maxResponseBytes) {
    return _error(413, 'response too large: narrow the request');
  }
  return (status: 200, body: text);
}
