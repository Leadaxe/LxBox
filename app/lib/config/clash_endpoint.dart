import 'package:json5/json5.dart';

/// Извлекает base URI и секрет Clash API из JSON / JSON5 / JSONC конфига sing-box.
///
/// Должен разбирать тот же синтаксис, что и загрузка конфига в ядро ([json5Decode]),
/// иначе при комментариях в конфиге [fromConfigJson] давал бы null и UI не видел Clash API.
class ClashEndpoint {
  ClashEndpoint({required this.baseUri, required this.secret});

  final Uri baseUri;
  final String secret;

  static ClashEndpoint? fromConfigJson(String raw) {
    try {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      final dynamic decoded = json5Decode(trimmed);
      if (decoded is! Map) return null;
      final exp = decoded['experimental'];
      if (exp is! Map) return null;
      final clash = exp['clash_api'];
      if (clash is! Map) return null;
      final controller = clash['external_controller'];
      final secret = clash['secret']?.toString() ?? '';
      final s = controller?.toString() ?? '127.0.0.1:9090';
      final Uri base = s.startsWith('http://') || s.startsWith('https://')
          ? Uri.parse(s)
          : Uri.parse('http://$s');
      return ClashEndpoint(baseUri: base, secret: secret);
    } catch (_) {
      return null;
    }
  }

  /// Значение [route.final], если есть (имя outbound).
  static String? routeFinalTag(String raw) {
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
