import 'dart:convert';

import 'package:path_provider/path_provider.dart';

import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `/config[/pretty|/path]` — отдаём сохранённый sing-box конфиг.
///
/// Raw ответ — ровно то что лежит в памяти HomeController (`configRaw`),
/// без round-trip'а через jsonDecode. Pretty — валидный JSON parse + indent 2.
Future<DebugResponse> configHandler(DebugRequest req, DebugContext ctx) async {
  return switch (req.path) {
    '/config' => _body(ctx, pretty: false),
    '/config/pretty' => _body(ctx, pretty: true),
    '/config/path' => _path(),
    _ => throw NotFound('config path: ${req.path}'),
  };
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
