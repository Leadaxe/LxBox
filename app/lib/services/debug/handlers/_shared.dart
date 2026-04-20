import 'dart:convert';

import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';

/// `?rebuild=true` на любом CRUD-хендлере: после успешного write'а
/// триггерит `SubscriptionController.generateConfig()` +
/// `HomeController.saveParsedConfig(...)`. Возвращает extras для
/// body ответа:
///
/// - rebuild не запрошен → `{}` (не добавляет ключей).
/// - rebuild прошёл → `{'rebuilt': true, 'config_bytes': N}`.
/// - rebuild свалился → `{'rebuilt': false, 'rebuild_error': '...'}`.
///   Write уже успел — статус 200/201 остаётся, ошибка под своим ключом.
Future<Map<String, Object?>> maybeRebuild(DebugRequest req, DebugContext ctx) async {
  if (!req.qBool('rebuild')) return const {};
  final sub = ctx.requireSub();
  final home = ctx.requireHome();
  try {
    final json = await sub.generateConfig();
    if (json == null) {
      return {
        'rebuilt': false,
        'rebuild_error': 'generate failed: ${sub.lastError}',
      };
    }
    final saved = await home.saveParsedConfig(json);
    if (!saved) {
      return {
        'rebuilt': false,
        'rebuild_error': 'saveParsedConfig returned false',
      };
    }
    return {'rebuilt': true, 'config_bytes': json.length};
  } catch (e) {
    return {'rebuilt': false, 'rebuild_error': e.toString()};
  }
}

/// JSON-body как `List<dynamic>`. Пустой/не-массив → [BadRequest].
List<dynamic> jsonBodyAsList(DebugRequest req) {
  if (req.body.isEmpty) {
    throw const BadRequest('body required (JSON array)');
  }
  try {
    final text = utf8.decode(req.body, allowMalformed: false);
    final parsed = jsonDecode(text);
    if (parsed is! List) {
      throw const BadRequest('body must be JSON array');
    }
    return parsed;
  } on FormatException catch (e) {
    throw BadRequest('invalid JSON body: ${e.message}');
  }
}

/// Strict extractor: ключ из Map должен иметь нужный тип или отсутствовать.
/// Присутствие ключа с null или wrong-type → [BadRequest].
bool? fieldBool(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) return null;
  final v = m[key];
  if (v is bool) return v;
  throw BadRequest('field "$key" must be bool, got ${v.runtimeType}');
}

String? fieldString(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) return null;
  final v = m[key];
  if (v is String) return v;
  throw BadRequest('field "$key" must be string, got ${v.runtimeType}');
}

int? fieldInt(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) return null;
  final v = m[key];
  if (v is int) return v;
  throw BadRequest('field "$key" must be int, got ${v.runtimeType}');
}

List<String>? fieldStringList(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) return null;
  final v = m[key];
  if (v is List) {
    return v.map((e) {
      if (e is String) return e;
      throw BadRequest('field "$key" must be list of strings');
    }).toList();
  }
  throw BadRequest('field "$key" must be array, got ${v.runtimeType}');
}
