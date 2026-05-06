import 'package:flutter/services.dart';

/// §038 — обёртка над `logcat -d -t N *:<level>` через native
/// `ProcessBuilder`. Lazy, только из `DumpBuilder.build()`.
///
/// Logd UID-фильтрует автоматически — `READ_LOGS` не нужен (отдаются
/// только события нашего UID + связанные system messages типа
/// `libc`/`DEBUG`/`tombstoned` под нашим pid).
///
/// Независимый канал от ApplicationExitInfo: logd — kernel-buffer,
/// AEI — ActivityManager. Полезен когда AEI не приложил trace (Samsung
/// One UI quirk на REASON_CRASH) и на API <30 где AEI отсутствует.
class LogcatReader {
  static const _channel = MethodChannel('com.leadaxe.lxbox/methods');

  /// Последние [count] строк logcat (clamp 50..5000) с уровнем
  /// [level] и выше: `V`/`D`/`I`/`W`/`E`/`F`. Default — `E` (Error+Fatal).
  /// Без фильтрации шум других уровней игнорируется.
  static Future<String?> tail({int count = 1000, String level = 'E'}) async {
    try {
      final raw = await _channel.invokeMethod<String>(
        'getLogcatTail',
        {'count': count, 'level': level},
      );
      if (raw == null || raw.isEmpty) return null;
      return raw;
    } catch (_) {
      return null;
    }
  }
}
