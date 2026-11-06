import '../../../models/codec/node_link_record.dart';
import '../../../models/node_link.dart';
import '../../../models/tls_policy.dart';
import '../../core_duration.dart';
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
        'rebuild_error': 'generate failed: ${sub.lastError?.renderEn() ?? ''}',
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

/// §439 (D-112) — поле-ссылка на узел: объект `{folder_id?, tag}`. Терпимо:
/// строка — корневая ссылка `{tag}` (форма до 2.23.3), `null` и пустой тег —
/// ссылки нет ([NodeLink.none]). Ключа нет — `null` (не трогать).
NodeLink? fieldNodeLink(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) return null;
  final v = m[key];
  if (v == null) return NodeLink.none;
  final link = nodeLinkFromRecord(v);
  if (link == null) {
    throw BadRequest('field "$key" must be {"folder_id"?: string, "tag": '
        'string}, a string or null, got ${v.runtimeType}');
  }
  return link.tag.isEmpty ? NodeLink.none : link;
}

/// §439 — список ссылок на узлы (позиции цепочки): элементы как у
/// [fieldNodeLink], пустой тег остаётся позицией (её ловит проверка цепочки).
List<NodeLink>? fieldNodeLinkList(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) return null;
  final v = m[key];
  if (v is! List) {
    throw BadRequest('field "$key" must be array, got ${v.runtimeType}');
  }
  return [
    for (final e in v)
      nodeLinkFromRecord(e) ??
          (throw BadRequest('field "$key" must be a list of '
              '{"folder_id"?: string, "tag": string} or strings')),
  ];
}

List<int>? fieldIntList(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) return null;
  final v = m[key];
  if (v is List) {
    return v.map((e) {
      if (e is int) return e;
      throw BadRequest('field "$key" must be list of ints');
    }).toList();
  }
  throw BadRequest('field "$key" must be array, got ${v.runtimeType}');
}

/// Парсит JSON-object → `Map<String, String>`. Значения приводятся к string
/// via `toString()` (`null` → `""`). Используется для `vars_values`
/// в preset-rule'ах.
Map<String, String>? fieldStringMap(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) return null;
  final v = m[key];
  if (v is Map) {
    return {
      for (final e in v.entries)
        if (e.key is String) e.key as String: e.value?.toString() ?? '',
    };
  }
  throw BadRequest('field "$key" must be object, got ${v.runtimeType}');
}

/// §636 — частичная правка TLS-политики из ключа `tls` тела: ключа нет —
/// `null` (не трогать); поле, которого нет в объекте, не меняется; `null` —
/// сброс в «наследовать». Пауза проверяется той же функцией, что в UI и
/// сборке ([parseCoreDurationNanos]).
TlsPolicy? fieldTlsPatch(Map<String, dynamic> m, TlsPolicy current) {
  if (!m.containsKey('tls')) return null;
  final raw = m['tls'];
  if (raw is! Map) throw const BadRequest('field "tls" must be an object');
  final patch = raw.cast<String, dynamic>();
  for (final k in patch.keys) {
    if (!TlsPolicy.keys.contains(k)) {
      throw BadRequest('field "tls.$k" is unknown; expected one of '
          '${TlsPolicy.keys.join(', ')}');
    }
  }
  final TlsPolicy next;
  try {
    next = current.patched(patch);
  } on FormatException catch (e) {
    throw BadRequest('field ${e.message}');
  }
  final delay = next.fallbackDelay;
  if (patch.containsKey('fallback_delay') &&
      delay != null &&
      parseCoreDurationNanos(delay) == null) {
    throw BadRequest('field "tls.fallback_delay": "$delay" is not a duration '
        'like 500ms or 1s');
  }
  return next;
}
