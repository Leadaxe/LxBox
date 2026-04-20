import 'subs.dart';

/// Сериализатор `_cache` для `GET /state/storage` (§031).
///
/// Модель: **denylist с scrubber'ом**, не allow-list. Философия debug-tool'а —
/// по умолчанию всё видно разработчику, чтобы новые настройки автоматом
/// становились доступны без ручного whitelist'а. Известные чувствительные
/// поля маскируются здесь явно:
///
/// - `vars.debug_token` → `***`
/// - `server_lists[].url` → `scheme://host/***` (provider token в path)
/// - `server_lists[].nodes` → только количество (в узлах могут быть
///   UUID/password'ы VLESS/Trojan/SS)
/// - `server_lists[].rawBody` → только длина (inline URI могут содержать
///   credentials)
///
/// Всё остальное — pass-through. Новый ключ без правила попадает в ответ
/// как есть; если он чувствительный — добавить rule здесь и в тесте.
Map<String, Object?> serializeStorageCache(Map<String, dynamic> cache) {
  final out = <String, Object?>{};
  for (final e in cache.entries) {
    out[e.key] = _scrub(e.key, e.value);
  }
  return out;
}

Object? _scrub(String key, dynamic value) {
  switch (key) {
    case 'vars':
      return _scrubVars(value);
    case 'server_lists':
      return _scrubServerLists(value);
    default:
      return value;
  }
}

Object? _scrubVars(dynamic vars) {
  if (vars is! Map) return vars;
  final out = <String, Object?>{};
  for (final e in vars.entries) {
    final k = e.key.toString();
    if (k == 'debug_token') {
      final v = e.value?.toString() ?? '';
      out[k] = v.isEmpty ? '' : '***';
    } else {
      out[k] = e.value;
    }
  }
  return out;
}

Object? _scrubServerLists(dynamic lists) {
  if (lists is! List) return lists;
  return lists.whereType<Map>().map(_scrubServerListEntry).toList();
}

Map<String, Object?> _scrubServerListEntry(Map<dynamic, dynamic> m) {
  final out = <String, Object?>{};
  for (final e in m.entries) {
    final k = e.key.toString();
    switch (k) {
      case 'url':
        out[k] = e.value is String
            ? maskSubscriptionUrl(e.value as String)
            : e.value;
      case 'nodes':
        // Узлы могут содержать credentials в UUID/password → только count.
        out['nodes_count'] = e.value is List ? (e.value as List).length : 0;
      case 'rawBody':
        // UserServer inline URI — могут содержать token'ы. Отдаём длину.
        out['raw_body_bytes'] = e.value?.toString().length ?? 0;
      default:
        out[k] = e.value;
    }
  }
  return out;
}
