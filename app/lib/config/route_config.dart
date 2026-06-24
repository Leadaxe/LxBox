import 'package:json5/json5.dart';

/// §122 — мелкие чистые запросы к route-секции конфига sing-box (JSON/JSON5/
/// JSONC). Разбирает тот же синтаксис, что и загрузка конфига в ядро
/// ([json5Decode]), чтобы комментарии в конфиге не ломали парс.
///
/// Заменил `clash_endpoint.dart` (ClashEndpoint.fromConfigJson выпилен вместе
/// с Clash API; остался только route.final-парсинг).
class RouteConfig {
  const RouteConfig._();

  /// Значение `route.final`, если есть (имя дефолтного outbound).
  static String? finalTag(String raw) {
    try {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      final dynamic decoded = json5Decode(trimmed);
      if (decoded is! Map) return null;
      final route = decoded['route'];
      if (route is! Map) return null;
      final f = route['final'];
      return f?.toString();
    } catch (_) {
      return null;
    }
  }
}
