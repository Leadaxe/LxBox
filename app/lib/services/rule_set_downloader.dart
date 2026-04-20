import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Кэширует удалённые `.srs` rule-set'ы локально. Файл = `$docs/rule_sets/<id>.srs`,
/// где `id` — `CustomRule.id` (стабильный UUID). Переименование правила или
/// правка URL'а не ломает кэш (удаление делает caller при URL-change).
///
/// Контракт: sing-box в конфиге получает `{type: "local", path: <abs>}` и
/// сам ничего не скачивает. Обновление кэша — manual (кнопка Download в
/// списке правил).
class RuleSetDownloader {
  RuleSetDownloader._();

  static const _timeout = Duration(seconds: 30);
  static const _dirName = 'rule_sets';

  static Directory? _cacheDir;

  static Future<Directory> _dir() async {
    if (_cacheDir != null) return _cacheDir!;
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  static Future<File> _file(String id) async =>
      File('${(await _dir()).path}/$id.srs');

  /// Есть ли кэш для правила.
  static Future<bool> isCached(String id) async {
    try {
      return await (await _file(id)).exists();
    } catch (_) {
      return false;
    }
  }

  /// Абсолютный путь к cached-файлу или null если нет.
  static Future<String?> cachedPath(String id) async {
    final f = await _file(id);
    return await f.exists() ? f.path : null;
  }

  /// Время последней модификации (mtime). Null если нет.
  static Future<DateTime?> lastUpdated(String id) async {
    final f = await _file(id);
    if (!await f.exists()) return null;
    return (await f.stat()).modified;
  }

  /// Скачать и сохранить. Атомарно: пишем во временный файл и `rename` на
  /// финальный, чтобы при сетевом обрыве не остаться с частично записанным
  /// кэшем.
  /// Возвращает абсолютный путь при успехе, null при ошибке.
  static Future<String?> download(String id, String url) async {
    try {
      final f = await _file(id);
      final tmp = File('${f.path}.tmp');

      final resp = await http
          .get(Uri.parse(url), headers: {'User-Agent': 'LxBox'})
          .timeout(_timeout);

      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return null;
      await tmp.writeAsBytes(resp.bodyBytes, flush: true);
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// Удалить cached-файл (noop если нет). Вызывать при delete rule или
  /// change URL.
  static Future<void> delete(String id) async {
    try {
      final f = await _file(id);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
