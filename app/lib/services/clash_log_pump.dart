import 'dart:async';

import 'package:flutter/services.dart';

import '../models/debug_entry.dart';
import 'app_log.dart';

/// §043: Pump для sing-box logs из Kotlin'а в наш [AppLog].
///
/// Подписывается на EventChannel `lxbox/coreLog` (registered в `VpnPlugin.kt`
/// onAttachedToEngine). Каждое event — строка sing-box формата:
/// `+0300 2026-05-06 12:34:56 INFO  router: rule[0]: ...`
///
/// Для каждой строки:
/// 1. Парсим уровень substring search'ем (sing-box формат включает
///    ` INFO `/` WARN `/` ERROR ` между timestamp и tag — robust к
///    минор-изменениям в форматтере).
/// 2. Пушим в [AppLog] как `DebugSource.core` с парсенным уровнем.
///
/// **Volume reduction в Kotlin:** TRACE/DEBUG отфильтровываются ещё на
/// нативной стороне в `BoxVpnService.writeDebugMessage` — здесь они
/// никогда не приходят. Если когда-нибудь понадобятся для глубокой
/// диагностики — снять filter в Kotlin.
///
/// Singleton — один на весь lifetime app'а. `attach()` вызывается из
/// `main.dart` после `AppLog.I.initPersistent()`.
class ClashLogPump {
  ClashLogPump._();
  static final ClashLogPump I = ClashLogPump._();

  static const _channel = EventChannel('lxbox/coreLog');
  StreamSubscription? _sub;

  /// Подписывается на EventChannel. Идемпотентно: повторный вызов no-op.
  ///
  /// **F22 part 2 batching:** native side отдаёт `List<String>` за один
  /// JNI marshal (см. `BoxService.coreLogDrainer`). Backward-compat: на
  /// случай старого APK / плагина принимаем и одиночный `String`.
  void attach() {
    if (_sub != null) return;
    _sub = _channel.receiveBroadcastStream().listen(
      _onEvent,
      onError: (_) {
        // Channel error — не критично, sing-box логи continue working
        // когда channel восстановится. Не нужно крутить retry — Flutter
        // EventChannel сам пере-подписывается на reattach.
      },
      cancelOnError: false,
    );
  }

  void _onEvent(dynamic event) {
    if (event is String) {
      if (event.isEmpty) return;
      AppLog.I.log(parseLevel(event), event, source: DebugSource.core);
      return;
    }
    if (event is List) {
      // Batch mode (F22 part 2): native шлёт List<String> от 1 до 200 строк.
      // Один notifyListeners на весь batch вместо N (см. AppLog.logBatch).
      final lines = <String>[];
      for (final item in event) {
        if (item is String && item.isNotEmpty) lines.add(item);
      }
      if (lines.isEmpty) return;
      AppLog.I.logBatch(lines, parseLevel, source: DebugSource.core);
    }
  }

  /// Отписаться. Опционально на shutdown.
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Парсит sing-box log level из строки.
  ///
  /// Sing-box форматтер выдаёт уровень в одной из форм:
  ///   - С пробелами вокруг: `+0300 ... INFO  tag: message` (terminal mode)
  ///   - Слитно с timer: `INFO[0006] [...] tag: message` (default formatter
  ///     после strip'а ANSI escapes)
  ///
  /// Возможные LEVEL: TRACE, DEBUG, INFO, WARN, ERROR, FATAL, PANIC.
  /// Сводим к нашим 4 уровням ([DebugLevel]):
  ///   - TRACE/DEBUG → debug (но эти не доходят сюда — фильтр в Kotlin)
  ///   - INFO → info
  ///   - WARN → warning
  ///   - ERROR/FATAL/PANIC → error
  ///
  /// Используем regex с word-boundary `\b` чтобы не матчилось внутри слов
  /// типа `WARNING` (но WARN внутри WARNING всё равно match'нется — это
  /// acceptable для нашего use case'а).
  ///
  /// Если уровень не распознан — fallback DebugLevel.info.
  ///
  /// Visible for testing.
  static DebugLevel parseLevel(String line) {
    if (_errorRe.hasMatch(line)) return DebugLevel.error;
    if (_warnRe.hasMatch(line)) return DebugLevel.warning;
    if (_infoRe.hasMatch(line)) return DebugLevel.info;
    if (_debugRe.hasMatch(line)) return DebugLevel.debug;
    return DebugLevel.info; // unknown format — soft fallback
  }

  static final _errorRe = RegExp(r'\b(ERROR|FATAL|PANIC)\b');
  static final _warnRe = RegExp(r'\bWARN\b');
  static final _infoRe = RegExp(r'\bINFO\b');
  static final _debugRe = RegExp(r'\b(TRACE|DEBUG)\b');
}
