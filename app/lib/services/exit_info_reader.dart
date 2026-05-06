import 'package:flutter/services.dart';

/// §038 — `ActivityManager.getHistoricalProcessExitReasons`-обёртка.
///
/// Lazy, зовётся только из `DumpBuilder.build()` — `traceInputStream`
/// (mini-tombstone) может быть до сотен KB; не нужно тянуть на cold-start.
///
/// API 30+ only; на младших и на любую ошибку — пустой список.
class ExitInfoReader {
  static const _channel = MethodChannel('com.leadaxe.lxbox/methods');

  /// Список последних 5 exit'ов нашего пакета с метаданными системы.
  /// Поля каждой записи (как в `android.app.ApplicationExitInfo`):
  ///   - `timestamp`: Long, ms since epoch
  ///   - `reason`: String — `CRASH | CRASH_NATIVE | ANR | LOW_MEMORY |
  ///     SIGNALED | EXIT_SELF | USER_REQUESTED | …`
  ///   - `description`: String? (от системы, может быть null)
  ///   - `importance`: Int (foreground/perceptible/etc.)
  ///   - `pss`: Long (byte)
  ///   - `rss`: Long (byte)
  ///   - `status`: Int (signal-coded для SIGNALED, exit-coded для EXIT_SELF)
  ///   - `trace`: String? — для CRASH_NATIVE: mini-tombstone (стек,
  ///     регистры, имена SO, fault address). Для CRASH: stacktrace JVM.
  ///     Null если система не приложила.
  static Future<List<Map<String, Object?>>> read() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>(
        'getApplicationExitInfo',
      );
      if (raw == null) return const [];
      return raw
          .cast<Map<Object?, Object?>>()
          .map((m) => m.map((k, v) => MapEntry(k as String, v)))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
