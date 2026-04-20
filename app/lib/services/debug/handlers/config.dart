import 'dart:convert';

import 'package:path_provider/path_provider.dart';

import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `/config[/pretty|/path]` — GET возвращает сохранённый sing-box конфиг.
/// `PUT /config` — прямой override (body = raw sing-box JSON). Минует
/// `buildConfig(...)`, подписки, custom rules — пишет bytes как есть
/// через `HomeController.saveParsedConfig`.
///
/// Raw ответ на GET — ровно то что лежит в памяти HomeController (`configRaw`),
/// без round-trip'а через jsonDecode. Pretty — валидный JSON parse + indent 2.
Future<DebugResponse> configHandler(DebugRequest req, DebugContext ctx) async {
  if (req.path == '/config' && req.method == 'PUT') {
    return _put(req, ctx);
  }
  if (req.method != 'GET') {
    throw BadRequest('method ${req.method} not allowed on ${req.path}');
  }
  return switch (req.path) {
    '/config' => _body(ctx, pretty: false),
    '/config/pretty' => _body(ctx, pretty: true),
    '/config/path' => _path(),
    _ => throw NotFound('config path: ${req.path}'),
  };
}

/// `PUT /config` — body это сырой sing-box JSON (объект). Валидируется
/// только парсингом (`jsonDecode` не бросил → принимаем). sing-box при
/// reload сам скажет о семантических проблемах; endpoint сугубо transport.
///
/// **Важно:** этот override — временный. Любой последующий
/// `POST /action/rebuild-config` (включая `?rebuild=true` в других
/// CRUD endpoint'ах) сотрёт его, сгенерив конфиг заново из settings.
Future<DebugResponse> _put(DebugRequest req, DebugContext ctx) async {
  if (req.body.isEmpty) {
    throw const BadRequest('body required (raw sing-box JSON)');
  }
  final String text;
  try {
    text = utf8.decode(req.body, allowMalformed: false);
  } on FormatException catch (e) {
    throw BadRequest('body is not valid UTF-8: ${e.message}');
  }
  // Валидация — парсим и убеждаемся, что это объект.
  try {
    final parsed = jsonDecode(text);
    if (parsed is! Map) {
      throw const BadRequest('config body must be JSON object');
    }
  } on FormatException catch (e) {
    throw BadRequest('invalid JSON config: ${e.message}');
  }
  final home = ctx.requireHome();
  final saved = await home.saveParsedConfig(text);
  if (!saved) {
    throw const UpstreamError('saveParsedConfig returned false');
  }
  return JsonResponse({
    'ok': true,
    'action': 'config-put',
    'bytes': text.length,
    'tunnel_up_when_saved': home.state.tunnelUp,
    'note': 'override is temporary — POST /action/rebuild-config '
        'will overwrite it with generated config from current settings.',
  });
}

Future<DebugResponse> _body(DebugContext ctx, {required bool pretty}) async {
  final home = ctx.requireHome();
  final raw = home.state.configRaw;
  if (raw.isEmpty) throw const NotFound('no saved config');
  if (!pretty) return RawJsonResponse(raw);
  try {
    final parsed = jsonDecode(raw);
    return JsonResponse(parsed, pretty: true);
  } on FormatException {
    // Config в памяти не валидный JSON (необычно, но возможно) — отдаём как есть.
    return RawJsonResponse(raw);
  }
}

Future<DebugResponse> _path() async {
  final dir = await getApplicationDocumentsDirectory();
  return JsonResponse({
    'app_documents_dir': dir.path,
    'note':
        'sing-box core сохраняет конфиг в internal files dir '
        '(/data/data/<pkg>/files/) через native side; путь выше — для справки.',
  });
}
