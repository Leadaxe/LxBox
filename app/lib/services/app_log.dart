import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/debug_entry.dart';

/// Глобальный лог приложения. Per-source ring buffer'ы (§043), наблюдаем
/// через `ChangeNotifier` (UI: `DebugScreen`).
///
/// **Per-source quotas (§043).** Раньше был общий `_entries` cap = 500.
/// Теперь каждый `DebugSource` имеет свой собственный ring buffer:
///   - `app` — 300 entries (наши собственные сообщения)
///   - `core` — 500 entries (sing-box логи, verbose на busy traffic)
///
/// Source A не вытесняет source B. Расширение на k источников — один
/// entry в `_maxEntriesPerSource` map'е, никаких изменений в insert-логике.
///
/// **Persistent slice (§038 + §043).** `warning` + `error` уровни также
/// пишутся в `filesDir/<source>log.txt`:
///   - `app` warn/error → `applog.txt` (200 строк / 64 KB)
///   - `core` warn/error → `corelog.txt` (200 строк / 64 KB, новый файл)
///
/// Каждый файл — независимый ring-buffer rotation. Total worst case 128 KB.
/// `debug`/`info` остаются in-memory (шум, не нужен post-mortem).
/// `initPersistent()` зовётся в `main()` до `runApp` и подгружает
/// сохранённые entries обоих файлов с маркером `fromPreviousSession=true`.
class AppLog extends ChangeNotifier {
  AppLog._();
  static final AppLog I = AppLog._();

  // ─── Per-source quotas (§043) ─────────────────────────────────

  /// In-memory caps. Map → easy to add new sources.
  static const Map<DebugSource, int> _maxEntriesPerSource = {
    DebugSource.app: 300,
    DebugSource.core: 500,
  };

  /// Persistent file names per source.
  static const Map<DebugSource, String> _persistFileNames = {
    DebugSource.app: 'applog.txt',
    DebugSource.core: 'corelog.txt',
  };

  /// Persistent caps per source — count of warn/error lines.
  static const Map<DebugSource, int> _persistMaxLinesPerSource = {
    DebugSource.app: 200,
    DebugSource.core: 200,
  };

  /// Per-file byte cap (одинаково для всех файлов).
  static const int _persistMaxBytesPerFile = 64 * 1024;

  // ─── State ────────────────────────────────────────────────────

  /// Ring buffer per source. Newest-first. F22 part 2: переехали с
  /// `List<DebugEntry>` на `ListQueue<DebugEntry>` — `addFirst` / `removeLast`
  /// обе O(1); раньше `List.insert(0, ...)` был O(n) shift всего буфера на
  /// каждом write'е (заметно на busy core-log traffic, cap=500).
  /// Read path (`entriesForSource`, `entries`) materialize'ит queue в
  /// immutable List — single O(n) копия, та же стоимость что была у
  /// `List.unmodifiable(list)` раньше.
  final Map<DebugSource, ListQueue<DebugEntry>> _entriesBySource = {
    for (final s in DebugSource.values) s: ListQueue<DebugEntry>(),
  };

  bool _persistInitialized = false;
  // Per-source dirty flags для persist write. Если только app-level warn —
  // не нужно перепаковывать corelog.txt и наоборот.
  final Set<DebugSource> _persistDirty = <DebugSource>{};
  bool _persistWriting = false;

  // ─── Public read API ──────────────────────────────────────────

  /// Все entries отсортированные по времени (newest first), merge всех
  /// source'ов. **Compute on read** — k-way merge небольших списков
  /// (k = число sources, n ≤ sum of caps). Пренебрежимо в нашем масштабе.
  List<DebugEntry> get entries {
    // ListQueue → fixed-size List один раз для k-way merge с index access.
    final lists = _entriesBySource.values
        .map((q) => q.toList(growable: false))
        .where((l) => l.isNotEmpty)
        .toList(growable: false);
    return _mergeByTime(lists);
  }

  /// Только entries указанного source'а — без merge'а, direct lookup.
  /// Используется в `/logs?source=...` фильтре.
  List<DebugEntry> entriesForSource(DebugSource source) =>
      List.unmodifiable(_entriesBySource[source] ?? const <DebugEntry>[]);

  // ─── Persistent init ──────────────────────────────────────────

  /// Подгружает persistent entries предыдущей сессии (из обоих файлов
  /// — `applog.txt` и `corelog.txt`) в соответствующие source-buckets с
  /// флагом `fromPreviousSession=true`. Идемпотентен. Зовётся в `main()`
  /// до `runApp` чтобы Debug-экран при первом render'е сразу видел
  /// prev-session.
  Future<void> initPersistent() async {
    if (_persistInitialized) return;
    _persistInitialized = true;
    for (final source in DebugSource.values) {
      try {
        await _loadPersistFile(source);
      } catch (_) {/* swallow — persistent log не критичен */}
    }
    notifyListeners();
  }

  Future<void> _loadPersistFile(DebugSource source) async {
    final f = await _persistFile(source);
    if (!await f.exists()) return;
    final raw = await f.readAsString();
    final loaded = <DebugEntry>[];
    for (final line in const LineSplitter().convert(raw)) {
      if (line.isEmpty) continue;
      try {
        final j = jsonDecode(line) as Map<String, dynamic>;
        // §043 forward-compat: source field может уже не совпадать с
        // именем файла (если когда-то писали mixed entries) — доверяем тому
        // что в JSON. Для legacy `applog.txt` это всегда DebugSource.app.
        loaded.add(DebugEntry(
          time: DateTime.parse(j['time'] as String),
          source: DebugSource.values.byName(j['source'] as String),
          level: DebugLevel.values.byName(j['level'] as String),
          message: j['message'] as String,
          fromPreviousSession: true,
        ));
      } catch (_) {/* skip malformed line */}
    }
    // File chronologically (oldest first), in-memory newest-first.
    final queue = _entriesBySource[source]!;
    queue.addAll(loaded.reversed);
    final cap = _maxEntriesPerSource[source]!;
    while (queue.length > cap) {
      queue.removeLast();
    }
  }

  // ─── Public write API ─────────────────────────────────────────

  void log(
    DebugLevel level,
    String message, {
    DebugSource source = DebugSource.app,
  }) {
    final line = message.trim();
    if (line.isEmpty) return;
    final queue = _entriesBySource[source];
    if (queue == null) return; // unknown source — silently ignore
    _appendOne(queue, source, level, line);
    _scheduleNotify();
  }

  /// F22 part 2 — batch ingest для core logs из native EventChannel.
  /// Один проход: добавили N записей, persist mark, notify ОДИН раз.
  ///
  /// `levelOf` парсит уровень из строки (re-use `ClashLogPump.parseLevel`),
  /// чтобы не переоткрывать regex'ы в caller'е.
  void logBatch(
    List<String> messages,
    DebugLevel Function(String) levelOf, {
    DebugSource source = DebugSource.app,
  }) {
    if (messages.isEmpty) return;
    final queue = _entriesBySource[source];
    if (queue == null) return;
    for (final raw in messages) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      _appendOne(queue, source, levelOf(line), line);
    }
    _scheduleNotify();
  }

  /// Append + cap enforcement. ListQueue addFirst/removeLast обе O(1).
  /// Не вызывает notifyListeners — caller сам решает (single vs batch).
  void _appendOne(
    ListQueue<DebugEntry> queue,
    DebugSource source,
    DebugLevel level,
    String line,
  ) {
    queue.addFirst(DebugEntry(
      time: DateTime.now(),
      source: source,
      level: level,
      message: line,
    ));
    final cap = _maxEntriesPerSource[source]!;
    while (queue.length > cap) {
      queue.removeLast();
    }
    if (kDebugMode) {
      // ignore: avoid_print
      print('[${source.name}/${level.name}] $line');
    }
    if (level == DebugLevel.warning || level == DebugLevel.error) {
      _persistDirty.add(source);
      _schedulePersistWrite();
    }
  }

  // ─── Notify throttle (F22 part 2 — ≤60Hz) ─────────────────────

  /// 16ms = ~60Hz. UI всё равно ребилдится не чаще одного frame'а.
  static const _notifyWindow = Duration(milliseconds: 16);

  Timer? _notifyThrottleTimer;
  bool _notifyPending = false;

  /// Leading-edge throttle: первый вызов сразу `notifyListeners()`,
  /// последующие в окне 16ms объединяются и emit'ятся одним notify в
  /// конце окна. На устойчивом core-log потоке (100+ строк/сек) UI
  /// rebuild ≤ 60Hz вместо `freq(write)`.
  void _scheduleNotify() {
    if (_notifyThrottleTimer != null) {
      _notifyPending = true;
      return;
    }
    notifyListeners();
    _notifyThrottleTimer = Timer(_notifyWindow, () {
      _notifyThrottleTimer = null;
      if (_notifyPending) {
        _notifyPending = false;
        _scheduleNotify();
      }
    });
  }

  void debug(String message, {DebugSource source = DebugSource.app}) =>
      log(DebugLevel.debug, message, source: source);
  void info(String message, {DebugSource source = DebugSource.app}) =>
      log(DebugLevel.info, message, source: source);
  void warning(String message, {DebugSource source = DebugSource.app}) =>
      log(DebugLevel.warning, message, source: source);
  void error(String message, {DebugSource source = DebugSource.app}) =>
      log(DebugLevel.error, message, source: source);

  /// Очищает все source-buckets + помечает все persist files dirty
  /// (чтобы при ближайшем write они опустошились).
  void clear() {
    for (final list in _entriesBySource.values) {
      list.clear();
    }
    _persistDirty.addAll(DebugSource.values);
    _schedulePersistWrite();
    notifyListeners();
  }

  /// Очищает только entries конкретного source'а. Используется
  /// `/logs/clear?source=core`.
  void clearSource(DebugSource source) {
    final list = _entriesBySource[source];
    if (list == null) return;
    list.clear();
    _persistDirty.add(source);
    _schedulePersistWrite();
    notifyListeners();
  }

  // ─── Persistent file management ───────────────────────────────

  Future<File> _persistFile(DebugSource source) async {
    final dir = await getApplicationDocumentsDirectory();
    final name = _persistFileNames[source]!;
    return File('${dir.path}/$name');
  }

  void _schedulePersistWrite() {
    if (_persistWriting) return;
    _persistWriting = true;
    Future.microtask(() async {
      try {
        while (_persistDirty.isNotEmpty) {
          // Snapshot pending sources, обнуляем set, обрабатываем каждое.
          final pending = _persistDirty.toList(growable: false);
          _persistDirty.clear();
          for (final source in pending) {
            await _writePersistent(source);
          }
        }
      } finally {
        _persistWriting = false;
      }
    });
  }

  Future<void> _writePersistent(DebugSource source) async {
    try {
      final f = await _persistFile(source);
      final list = _entriesBySource[source]!;
      // list newest-first. Идём с верха, накапливаем warn/error до cap'а.
      // Потом reverse для chronological-file-order.
      final out = <String>[];
      var bytes = 0;
      final lineCap = _persistMaxLinesPerSource[source]!;
      for (final e in list) {
        if (e.fromPreviousSession) continue;
        if (e.level != DebugLevel.warning && e.level != DebugLevel.error) {
          continue;
        }
        final encoded = jsonEncode({
          'time': e.time.toIso8601String(),
          'source': e.source.name,
          'level': e.level.name,
          'message': e.message,
        });
        final lineBytes = utf8.encode(encoded).length + 1; // +\n
        if (bytes + lineBytes > _persistMaxBytesPerFile && out.isNotEmpty) {
          break;
        }
        out.add(encoded);
        bytes += lineBytes;
        if (out.length >= lineCap) break;
      }
      final sb = StringBuffer();
      for (final line in out.reversed) {
        sb.writeln(line);
      }
      await f.writeAsString(sb.toString(), flush: true);
    } catch (_) {/* swallow */}
  }

  // ─── k-way merge ──────────────────────────────────────────────

  /// Merge нескольких **уже отсортированных** newest-first lists в один
  /// глобально отсортированный newest-first list. O(n × k) где k = число
  /// sources, n = total entries. Для k=2-3 sources × ≤800 entries —
  /// пренебрежимо.
  static List<DebugEntry> _mergeByTime(Iterable<List<DebugEntry>> lists) {
    // Position cursors.
    final cursors = <_Cursor>[];
    for (final l in lists) {
      if (l.isNotEmpty) cursors.add(_Cursor(l));
    }
    if (cursors.isEmpty) return const <DebugEntry>[];
    if (cursors.length == 1) {
      // Fast path — один source, просто unmodifiable view.
      return List.unmodifiable(cursors.first.list);
    }
    final out = <DebugEntry>[];
    while (cursors.isNotEmpty) {
      // Find cursor with newest current entry.
      var newestIdx = 0;
      for (var i = 1; i < cursors.length; i++) {
        if (cursors[i].current.time.isAfter(cursors[newestIdx].current.time)) {
          newestIdx = i;
        }
      }
      out.add(cursors[newestIdx].current);
      cursors[newestIdx].advance();
      if (cursors[newestIdx].done) cursors.removeAt(newestIdx);
    }
    return out;
  }

  // ─── @visibleForTesting helpers ───────────────────────────────

  /// Test-only: clear all in-memory state without touching persist.
  /// Used by unit tests setUp.
  @visibleForTesting
  void resetForTesting() {
    for (final list in _entriesBySource.values) {
      list.clear();
    }
    _persistDirty.clear();
    _persistInitialized = false;
  }
}

/// Iterator-like cursor для k-way merge.
class _Cursor {
  _Cursor(this.list);
  final List<DebugEntry> list;
  int _idx = 0;

  bool get done => _idx >= list.length;
  DebugEntry get current => list[_idx];
  void advance() => _idx++;
}
