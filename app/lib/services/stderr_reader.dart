import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// §038 MVP1 — read-only access к `external/stderr.log`.
///
/// Сюда libbox перенаправляет Go stderr через `Libbox.redirectStderr` на
/// init процесса (см. `BoxApplication.initializeLibbox` в нативке).
/// При panic'е без recover() Go runtime пишет полный multi-goroutine
/// stacktrace в этот файл **до** того, как процесс получит SIGABRT —
/// поэтому файл переживает смерть процесса и доступен при следующем старте.
///
/// Намеренно показываем **только последнюю сессию**, без накопления:
/// никаких `.old`/rotation. Если файл уже непустой и юзер запустил
/// приложение снова — содержимое пере-открытия libbox'ом перетрёт старое;
/// нам это ок, потому что цель — диагностировать ровно текущий/последний
/// инцидент, а не вести историю.
///
/// Симметрично `lib/services/debug/handlers/files.dart` `_externalFile`
/// (§031 Debug API), который выдаёт этот же файл по HTTP — оба читателя
/// используют path_provider, не дублируя нативный код.
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

  static Future<File?> _file() async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return null;
      return File('${dir.path}/stderr.log');
    } catch (_) {
      return null;
    }
  }
}
