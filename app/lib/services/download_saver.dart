import 'dart:io';

/// Сохраняет текст в `/sdcard/Download/lxbox-dump/<fileName>`. Папка
/// создаётся при первом вызове; файлы перезаписываются без диалога, чтобы
/// пользователь всегда пересылал из одного места.
///
/// Возвращает путь или null при ошибке.
class DownloadSaver {
  DownloadSaver._();

  static const _dumpDir = '/storage/emulated/0/Download/lxbox-dump';
  static const _dumpDirAlt = '/sdcard/Download/lxbox-dump';

  static Future<String?> save({
    required String fileName,
    required String content,
  }) async {
    try {
      final dir = await _ensureDir();
      if (dir == null) return null;
      final path = '${dir.path}/$fileName';
      await File(path).writeAsString(content);
      return path;
    } catch (_) {
      return null;
    }
  }

  static Future<Directory?> _ensureDir() async {
    for (final candidate in [_dumpDir, _dumpDirAlt]) {
      try {
        final parent = Directory(candidate.substring(0, candidate.lastIndexOf('/')));
        if (!parent.existsSync()) continue;
        final d = Directory(candidate);
        if (!d.existsSync()) await d.create(recursive: true);
        return d;
      } catch (_) {}
    }
    return null;
  }
}
