import 'package:flutter/foundation.dart';

import '../../services/traffic_profiler.dart';

/// §044/new-profiler — единая фильтр-модель профайлера. Раньше фильтр-state
/// был размазан полями прямо в `TraceExplorer` (`_search`/`_kindFilter`/
/// `_onlyUnattributed`). Теперь — один `ChangeNotifier`, который слушают и
/// `TraceExplorer` (применяет к списку), и `ProfilerFilterSheet` (редактирует).
///
/// Две независимые оси:
/// - **Protocol** — фильтр «по типу события» (DNS/TCP/UDP, по СЕМЕЙСТВУ §177).
/// - **App** — фильтр «по процессу»: выбранные пакеты + «потеряшки»
///   (unattributed/no-owner) как ещё один пункт. App-ось работает в OR:
///   событие проходит, если его process ∈ apps ЛИБО (это потеряшка И выбраны
///   потеряшки).
/// Плюс кросс-осевой `search` (domain/ip/process).
class ProfilerFilter extends ChangeNotifier {
  String _search = '';
  final Set<TrafficEventKind> _kinds = <TrafficEventKind>{};
  final Set<String> _apps = <String>{};
  // «Потеряшки» — события без owner'а (unattributed). Галка в App-табе.
  bool _includeUnattributed = false;

  String get search => _search;
  Set<TrafficEventKind> get kinds => _kinds;
  Set<String> get apps => _apps;
  bool get includeUnattributed => _includeUnattributed;

  /// Активна ли app-ось (выбран хоть один app или потеряшки).
  bool get appAxisActive => _apps.isNotEmpty || _includeUnattributed;

  /// Сколько «фильтров» активно — для бейджа `(N)` на кнопке фильтра.
  int get activeCount {
    var n = 0;
    if (_search.isNotEmpty) n++;
    n += _kinds.length;
    n += _apps.length;
    if (_includeUnattributed) n++;
    return n;
  }

  /// Активность без app-оси (для App-вкладки, где app-ось не применяется).
  int get activeCountNoApps {
    var n = 0;
    if (_search.isNotEmpty) n++;
    n += _kinds.length;
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

  // ── потеряшки (unattributed как пункт app-оси) ──
  set includeUnattributed(bool v) {
    if (_includeUnattributed == v) return;
    _includeUnattributed = v;
    notifyListeners();
  }

  void clearAll() {
    _search = '';
    _kinds.clear();
    _apps.clear();
    _includeUnattributed = false;
    notifyListeners();
  }

  /// §177 — представитель семейства: dnsFail→dnsResolve, tcpClose→tcpOpen,
  /// чтобы один чип ловил обе фазы. udpOpen — сам себе семейство.
  static TrafficEventKind kindFamily(TrafficEventKind k) => switch (k) {
        TrafficEventKind.dnsFail => TrafficEventKind.dnsResolve,
        TrafficEventKind.tcpClose => TrafficEventKind.tcpOpen,
        _ => k,
      };

  static bool _isUnattributed(TrafficEvent e) =>
      e.confidence == ConfidenceLevel.unattributed;

  /// Применяет фильтр к потоку событий. [includeApps] — учитывать ли app-ось
  /// (в App-вкладке она не нужна: target зафиксирован сессией).
  Iterable<TrafficEvent> apply(Iterable<TrafficEvent> src,
      {bool includeApps = true}) {
    var list = src;
    if (_kinds.isNotEmpty) {
      list = list.where((e) => _kinds.contains(kindFamily(e.kind)));
    }
    if (includeApps && appAxisActive) {
      list = list.where((e) {
        // OR: process в выбранных ИЛИ (потеряшка и потеряшки включены).
        final byApp = e.process != null && _apps.contains(e.process);
        final byUnattr = _includeUnattributed && _isUnattributed(e);
        return byApp || byUnattr;
      });
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
