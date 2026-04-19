import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Кэш последнего HTTP-ответа подписки (body + headers). Используется
/// `SubscriptionDetailScreen → Source` чтобы показать реальный запрос,
/// а не реконструкцию из `SubscriptionMeta`.
///
/// Файлы:
///   app_support/sub_cache/`<hash>`          — сырое тело (как пришло по HTTP)
///   app_support/sub_cache/`<hash>`.headers  — JSON `{header: value, ...}`
class HttpCache {
  HttpCache._();

  static String _hash(String url) => url.hashCode.toRadixString(16);

  static Future<Directory> _dir() async {
    final root = await getApplicationSupportDirectory();
    final d = Directory('${root.path}/sub_cache');
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }

  static Future<void> save(
    String url,
    String body,
    Map<String, String> headers,
  ) async {
    final dir = await _dir();
    final key = _hash(url);
    await File('${dir.path}/$key').writeAsString(body);
    await File('${dir.path}/$key.headers')
        .writeAsString(jsonEncode(headers));
  }

  static Future<String?> loadBody(String url) async {
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_hash(url)}');
      if (!f.existsSync()) return null;
      return f.readAsString();
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, String>?> loadHeaders(String url) async {
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_hash(url)}.headers');
      if (!f.existsSync()) return null;
      final raw = await f.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
