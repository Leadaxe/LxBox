import 'dart:convert';

/// Извлекает base URI и секрет Clash API из JSON конфига sing-box.
class ClashEndpoint {
  ClashEndpoint({required this.baseUri, required this.secret});

  final Uri baseUri;
  final String secret;

  static ClashEndpoint? fromConfigJson(String raw) {
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final exp = decoded['experimental'];
      if (exp is! Map<String, dynamic>) return null;
      final clash = exp['clash_api'];
      if (clash is! Map<String, dynamic>) return null;
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
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final route = decoded['route'];
      if (route is! Map<String, dynamic>) return null;
      final f = route['final'];
      return f?.toString();
    } catch (_) {
      return null;
    }
  }
}
