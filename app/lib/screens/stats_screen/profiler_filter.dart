import 'package:flutter/foundation.dart';

import '../../services/traffic_profiler.dart';

/// §044/new-profiler — единая фильтр-модель профайлера. Раньше фильтр-state
/// был размазан полями прямо в `TraceExplorer` (`_search`/`_kindFilter`/
/// `_onlyUnattributed`). Теперь — один `ChangeNotifier`, который слушают и
/// `TraceExplorer` (применяет к списку), и `ProfilerFilterSheet` (редактирует).
///
/// Две независимые оси (см. спеку):
/// - **app** — фильтр «по процессу» (мульти-выбор пакетов).
/// - **kind** — фильтр «по типу события» (DNS/TCP/UDP, по СЕМЕЙСТВУ §177).
/// Плюс кросс-осевой `search` (domain/ip/process) и `onlyUnattributed`.
class ProfilerFilter extends ChangeNotifier {
  String _search = '';
  final Set<TrafficEventKind> _kinds = <TrafficEventKind>{};
  final Set<String> _apps = <String>{};
  bool _onlyUnattributed = false;

  String get search => _search;
  Set<TrafficEventKind> get kinds => _kinds;
  Set<String> get apps => _apps;
  bool get onlyUnattributed => _onlyUnattributed;

  /// Сколько «фильтров» активно — для бейджа `(N)` на кнопке фильтра.
  /// Считаем оси: непустой search (1) + каждый kind + каждый app + unattr (1).
  int get activeCount {
    var n = 0;
    if (_search.isNotEmpty) n++;
    n += _kinds.length;
    n += _apps.length;
    if (_onlyUnattributed) n++;
    return n;
  }

  bool get isActive => activeCount > 0;

  // ── search ──
  set search(String v) {
    if (_search == v) return;
    _search = v;
    notifyListeners();
  }

  // ── kinds (по семейству §177) ──
  bool hasKind(TrafficEventKind k) => _kinds.contains(k);
  void toggleKind(TrafficEventKind k, bool on) {
    if (on) {
      _kinds.add(k);
    } else {
      _kinds.remove(k);
    }
    notifyListeners();
  }

  // ── apps ──
  bool hasApp(String pkg) => _apps.contains(pkg);
  void toggleApp(String pkg, bool on) {
    if (on) {
      _apps.add(pkg);
    } else {
      _apps.remove(pkg);
    }
    notifyListeners();
  }

  // ── unattributed ──
  set onlyUnattributed(bool v) {
    if (_onlyUnattributed == v) return;
    _onlyUnattributed = v;
    notifyListeners();
  }

  void clearAll() {
    _search = '';
    _kinds.clear();
    _apps.clear();
    _onlyUnattributed = false;
    notifyListeners();
  }

  /// §177 — представитель семейства: dnsFail→dnsResolve, tcpClose→tcpOpen,
  /// чтобы один чип ловил обе фазы. udpOpen — сам себе семейство.
  static TrafficEventKind kindFamily(TrafficEventKind k) => switch (k) {
        TrafficEventKind.dnsFail => TrafficEventKind.dnsResolve,
        TrafficEventKind.tcpClose => TrafficEventKind.tcpOpen,
        _ => k,
      };

  /// Применяет фильтр к потоку событий (та же логика, что была в
  /// `TraceExplorer._applyFilter`). [includeApps] — учитывать ли app-ось
  /// (в App-вкладке она не нужна: target зафиксирован сессией).
  Iterable<TrafficEvent> apply(Iterable<TrafficEvent> src,
      {bool includeApps = true}) {
    var list = src;
    if (_kinds.isNotEmpty) {
      list = list.where((e) => _kinds.contains(kindFamily(e.kind)));
    }
    if (includeApps && _apps.isNotEmpty) {
      list = list.where((e) => e.process != null && _apps.contains(e.process));
    }
    if (_onlyUnattributed) {
      list = list.where((e) => e.confidence == ConfidenceLevel.unattributed);
    }
    if (_search.isNotEmpty) {
      final lq = _search.toLowerCase();
      list = list.where((e) =>
          (e.domain?.toLowerCase().contains(lq) ?? false) ||
          (e.ip?.contains(_search) ?? false) ||
          (e.process?.toLowerCase().contains(lq) ?? false));
    }
    return list;
  }
}
