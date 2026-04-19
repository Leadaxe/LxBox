import 'package:flutter/foundation.dart';

import '../models/debug_entry.dart';

/// Глобальный лог приложения. Кольцевой буфер последних ~500 записей,
/// наблюдаем через `ChangeNotifier` (UI: `DebugScreen`). Роутит и app-
/// и core-сообщения; нативные события VPN шлются `source: DebugSource.core`.
///
/// В v1 логи жили внутри `HomeController._state.debugEvents` и добавлять
/// строки можно было только из контроллера. v2 — `AppLog.I.info/debug/
/// warning/error(...)` доступен из любого места пайплайна.
class AppLog extends ChangeNotifier {
  AppLog._();
  static final AppLog I = AppLog._();

  static const int _maxEntries = 500;
  final List<DebugEntry> _entries = <DebugEntry>[];

  List<DebugEntry> get entries => List.unmodifiable(_entries);

  void log(
    DebugLevel level,
    String message, {
    DebugSource source = DebugSource.app,
  }) {
    final line = message.trim();
    if (line.isEmpty) return;
    _entries.insert(0, DebugEntry(
      time: DateTime.now(),
      source: source,
      level: level,
      message: line,
    ));
    if (_entries.length > _maxEntries) {
      _entries.removeRange(_maxEntries, _entries.length);
    }
    if (kDebugMode) {
      // ignore: avoid_print
      print('[${level.name}] $line');
    }
    notifyListeners();
  }

  void debug(String message, {DebugSource source = DebugSource.app}) =>
      log(DebugLevel.debug, message, source: source);
  void info(String message, {DebugSource source = DebugSource.app}) =>
      log(DebugLevel.info, message, source: source);
  void warning(String message, {DebugSource source = DebugSource.app}) =>
      log(DebugLevel.warning, message, source: source);
  void error(String message, {DebugSource source = DebugSource.app}) =>
      log(DebugLevel.error, message, source: source);

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}
