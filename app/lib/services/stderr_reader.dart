import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../vpn/box_vpn_client.dart';

/// §038 — read-only access к `filesDir/stderr.log`.
///
/// Libbox через `Libbox.redirectStderr` (`BoxApplication.initializeLibbox`)
/// перенаправляет Go stderr в этот файл. При panic'е без recover() Go
/// runtime пишет multi-goroutine stacktrace до SIGABRT'а — файл переживает
/// смерть процесса.
///
/// Только последняя сессия, без ротации/накопления. Цель — диагностировать
/// текущий инцидент, не вести историю.
class StderrReader {
  /// Содержимое `stderr.log` или `null` если файл отсутствует/пуст.
  static Future<String?> read() async {
    final file = await _file();
    if (file == null) return null;
    if (!await file.exists()) return null;
    if (await file.length() == 0) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// Путь к файлу для Share — `null` если отсутствует/пуст.
  static Future<String?> path() async {
    final file = await _file();
    if (file == null) return null;
    if (!await file.exists() || await file.length() == 0) return null;
    return file.path;
  }

  /// Internal app-scoped storage (`/data/data/<pkg>/files/`) — то же место,
  /// куда нативка кладёт stderr.log через `Libbox.redirectStderr`.
  ///
  /// §316 — путь берём у NATIVE (`getFilesDir`). Прежний комментарий
  /// утверждал, что `getApplicationDocumentsDirectory()` соответствует
  /// Android `filesDir`, — это неверно: у Flutter он указывает на
  /// `app_flutter`, у native/ядра это `files`. Из-за подмены §038-канал
  /// не находил файл НИКОГДА (device-verified §316). Фоллбэк на Dart-путь
  /// оставлен для юнит-тестов, где MethodChannel не поднят.
  static Future<File?> _file() async {
    try {
      final native = await BoxVpnClient().getFilesDir();
      final base = (native != null && native.isNotEmpty)
          ? native
          : (await getApplicationDocumentsDirectory()).path;
      final f = File('$base/stderr.log');
      if (await f.exists() && await f.length() > 0) return f;
      return null;
    } catch (_) {
      return null;
    }
  }
}
