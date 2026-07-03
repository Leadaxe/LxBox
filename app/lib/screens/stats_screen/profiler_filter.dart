import 'package:flutter/foundation.dart';

import '../../services/traffic_profiler.dart';

/// §044/new-profiler — единая фильтр-модель профайлера. Раньше фильтр-state
/// был размазан полями прямо в `TraceExplorer` (`_search`/`_kindFilter`/
/// `_onlyUnattributed`). Теперь — один `ChangeNotifier`, который слушают и
/// `TraceExplorer` (применяет к списку), и `ProfilerFilterSheet` (редактирует).
///
/// Независимые оси (между собой AND, внутри оси OR):
/// - **Protocol** — фильтр «по типу события» (DNS/TCP/UDP, по СЕМЕЙСТВУ §177).
/// - **App** — фильтр «по процессу»: выбранные пакеты + «потеряшки»
///   (unattributed/no-owner) как ещё один пункт. App-ось работает в OR:
///   событие проходит, если его process ∈ apps ЛИБО (это потеряшка И выбраны
///   потеряшки).
/// - **Rule** (§230) — по сматчившему route-правилу (`event.rule`; '' = «final»).
/// - **Outbound** (§230) — по любому звену `outboundChain ∪ detourChain`
///   (селектор / канал / detour-транспорт).
/// Плюс кросс-осевой `search` (domain/ip/process, substring, не regex).
class ProfilerFilter extends ChangeNotifier {
  String _search = '';
  final Set<TrafficEventKind> _kinds = <TrafficEventKind>{};
  final Set<String> _apps = <String>{};
  // §230 — ось Rule (сматчившее route-правило; '' = «final», без правила) и
  // ось Outbound (любое звено outboundChain ∪ detourChain: селектор/канал/detour).
  final Set<String> _rules = <String>{};
  final Set<String> _outbounds = <String>{};
  // «Потеряшки» — события без owner'а (unattributed). Галка в App-табе.
  bool _includeUnattributed = false;

  String get search => _search;
  Set<TrafficEventKind> get kinds => _kinds;
  Set<String> get apps => _apps;
  Set<String> get rules => _rules;
  Set<String> get outbounds => _outbounds;
  bool get includeUnattributed => _includeUnattributed;

  /// Активна ли app-ось (выбран хоть один app или потеряшки).
  bool get appAxisActive => _apps.isNotEmpty || _includeUnattributed;

  /// Сколько «фильтров» активно — для бейджа `(N)` на кнопке фильтра.
  int get activeCount {
    var n = 0;
    if (_search.isNotEmpty) n++;
    n += _kinds.length;
    n += _apps.length;
    n += _rules.length;
    n += _outbounds.length;
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

  // ── rules (§230 — сматчившее правило; '' = «final») ──
  bool hasRule(String r) => _rules.contains(r);
  void toggleRule(String r, bool on) {
    if (on) {
      _rules.add(r);
    } else {
      _rules.remove(r);
    }
    notifyListeners();
  }

  // ── outbounds (§230 — любое звено outboundChain ∪ detourChain) ──
  bool hasOutbound(String o) => _outbounds.contains(o);
  void toggleOutbound(String o, bool on) {
    if (on) {
      _outbounds.add(o);
    } else {
      _outbounds.remove(o);
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
    _rules.clear();
    _outbounds.clear();
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
    if (_rules.isNotEmpty) {
      // '' в наборе = «final» (событие без явного правила).
      list = list.where((e) => _rules.contains(e.rule ?? ''));
    }
    if (_outbounds.isNotEmpty) {
      // Любое звено роутинг- или detour-цепочки.
      list = list.where((e) =>
          e.outboundChain.any(_outbounds.contains) ||
          e.detourChain.any(_outbounds.contains));
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
