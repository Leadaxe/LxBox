import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/debug_entry.dart';

/// Глобальный лог приложения. Кольцевой буфер последних ~500 записей,
/// наблюдаем через `ChangeNotifier` (UI: `DebugScreen`). Роутит и app-
/// и core-сообщения; нативные события VPN шлются `source: DebugSource.core`.
///
/// **Persistent slice (§038).** `warning` + `error` уровни также
/// пишутся в `filesDir/applog.txt` (ring-buffer ~200 строк / ~64KB) —
/// чтобы pre-crash JVM-events были доступны после рестарта процесса.
/// `debug`/`info` остаются in-memory (шум, не нужен post-mortem).
/// `initPersistent()` зовётся в `main()` до `runApp` и подгружает
/// сохранённые entries с маркером `fromPreviousSession=true`.
class AppLog extends ChangeNotifier {
  AppLog._();
  static final AppLog I = AppLog._();

  static const int _maxEntries = 500;
  static const int _persistMax = 200;
  static const int _persistMaxBytes = 64 * 1024;
  static const String _persistFileName = 'applog.txt';

  final List<DebugEntry> _entries = <DebugEntry>[];

  bool _persistInitialized = false;
  bool _persistDirty = false;
  bool _persistWriting = false;

  List<DebugEntry> get entries => List.unmodifiable(_entries);

  /// Подгружает persistent entries предыдущей сессии в `_entries` с флагом
  /// `fromPreviousSession=true`. Идемпотентен. Зовётся в `main()` до
  /// `runApp` чтобы Debug-экран при первом render'е сразу видел prev-session.
  Future<void> initPersistent() async {
    if (_persistInitialized) return;
    _persistInitialized = true;
    try {
      final f = await _persistFile();
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      final loaded = <DebugEntry>[];
      for (final line in const LineSplitter().convert(raw)) {
        if (line.isEmpty) continue;
        try {
          final j = jsonDecode(line) as Map<String, dynamic>;
          loaded.add(DebugEntry(
            time: DateTime.parse(j['time'] as String),
            source: DebugSource.values.byName(j['source'] as String),
            level: DebugLevel.values.byName(j['level'] as String),
            message: j['message'] as String,
            fromPreviousSession: true,
          ));
        } catch (_) {/* skip malformed line */}
      }
      // Файл хранится chronologically (старые сначала), а UI ожидает
      // newest-first. Reversed: prev-session newest сверху, потом постарше.
      _entries.addAll(loaded.reversed);
      if (_entries.length > _maxEntries) {
        _entries.removeRange(_maxEntries, _entries.length);
      }
      notifyListeners();
    } catch (_) {/* swallow — persistent log не критичен для работы app */}
  }

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
    if (level == DebugLevel.warning || level == DebugLevel.error) {
      _persistDirty = true;
      _schedulePersistWrite();
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
    _persistDirty = true;
    _schedulePersistWrite();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Persistent file management
  // ---------------------------------------------------------------------------

  Future<File> _persistFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_persistFileName');
  }

  void _schedulePersistWrite() {
    if (_persistWriting) return;
    _persistWriting = true;
    Future.microtask(() async {
      try {
        while (_persistDirty) {
          _persistDirty = false;
          await _writePersistent();
        }
      } finally {
        _persistWriting = false;
      }
    });
  }

  Future<void> _writePersistent() async {
    try {
      final f = await _persistFile();
      // _entries newest-first. Идём с верха (newest), накапливаем строки
      // пока не упрёмся в N entries / bytes-cap. Потом разворачиваем
      // один раз для chronological-file-order.
      final out = <String>[];
      var bytes = 0;
      for (final e in _entries) {
        if (e.fromPreviousSession) continue;
        if (e.level != DebugLevel.warning && e.level != DebugLevel.error) {
          continue;
        }
        final line = jsonEncode({
          'time': e.time.toIso8601String(),
          'source': e.source.name,
          'level': e.level.name,
          'message': e.message,
        });
        final lineBytes = utf8.encode(line).length + 1; // +\n
        if (bytes + lineBytes > _persistMaxBytes && out.isNotEmpty) break;
        out.add(line);
        bytes += lineBytes;
        if (out.length >= _persistMax) break;
      }
      final sb = StringBuffer();
      for (final line in out.reversed) {
        sb.writeln(line);
      }
      await f.writeAsString(sb.toString(), flush: true);
    } catch (_) {/* swallow */}
  }
}
