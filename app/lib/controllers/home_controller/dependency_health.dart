part of '../home_controller.dart';

/// §355 — граф detour-зависимостей активного конфига и пересчёт «корней беды».
/// Вынесено `part`'ом из `home_controller.dart` (задача 740) — та же
/// библиотека и тот же `HomeController`, тела методов не менялись. Общие с
/// контроллером поля/хелперы объявлены абстрактно; реализацию даёт
/// `HomeController`. Стоит в `with` после `_PingMixin`: его абстрактный
/// `_recomputeDependencyHealth` реализуется здесь.
mixin _DependencyHealthMixin on ChangeNotifier {
  // --- surface, предоставляемая HomeController ---
  HomeState get _state;
  void _emit(HomeState next);
  void _addDebug(DebugSource source, String message);

  // §355 — граф detour-зависимостей активного конфига (parse-once дисциплина
  // §091: пересоздаётся только на смену raw). Динамика (выбор групп, замеры)
  // подаётся в computeSick аргументами из state.
  DependencyGraph _depGraph = const DependencyGraph.empty();
  String _depGraphRaw = '';

  /// §355 — актуализировать граф под текущий activeConfigRaw (ленивая
  /// parse-once инвалидация, общая для computeSick и UI-запросов).
  DependencyGraph _ensureDepGraph() {
    final raw = _state.activeConfigRaw;
    if (raw != _depGraphRaw) {
      _depGraphRaw = raw;
      _depGraph = DependencyGraph.fromConfig(raw);
    }
    return _depGraph;
  }

  /// §355 — прямые зависимые ноды/Направления (кто ссылается detour'ом): вкладка
  /// «Dependents» в OutboundViewScreen. Статический срез графа, без health.
  List<DependentRef> directDependentsOf(String tag) =>
      _ensureDepGraph().directDependents(tag);

  /// §355 — пересчёт «корней беды» (мёртвая нода → зависимые DNS/ноды).
  /// Дёргается на двух событиях (новой диагностики нет by design): замер
  /// пинга (см. ping_orchestration) и смена выбора групп (_applyGroups).
  /// Эмитит только при фактическом изменении результата; баннер lastError —
  /// только для DNS-ветки (решение юзера, spec §4.3) и только на НОВУЮ
  /// dns-жертву; исчезновение всех dns-жертв снимает наш баннер (чужие
  /// lastError не трогаем).
  void _recomputeDependencyHealth() {
    _ensureDepGraph();
    final selections = <String, String>{
      for (final g in _state.ccGroups)
        if (g.selectable && g.selected.isNotEmpty) g.tag: g.selected,
    };
    final sick = _depGraph.computeSick(
      selections: selections,
      delays: _state.delayByDirection,
    );
    if (_sickRootsEqual(sick, _state.sickRoots)) return;

    final prevDnsVictims = <String>{
      for (final list in _state.sickRoots.values)
        for (final d in list)
          if (d.isDns) d.tag,
    };
    DnsViaDeadNodeMsg? banner;
    for (final e in sick.entries) {
      for (final d in e.value) {
        if (d.isDns && !prevDnsVictims.contains(d.tag)) {
          banner = DnsViaDeadNodeMsg(d.tag, e.key, d.via ?? '');
          break;
        }
      }
      if (banner != null) break;
    }
    final hasDnsVictims =
        sick.values.any((list) => list.any((d) => d.isDns));
    if (banner != null) {
      _addDebug(DebugSource.app, banner.renderEn());
      _emit(_state.copyWith(sickRoots: sick, lastError: banner));
    } else if (!hasDnsVictims && _state.lastError is DnsViaDeadNodeMsg) {
      _emit(_state.copyWith(sickRoots: sick, lastError: null));
    } else {
      _emit(_state.copyWith(sickRoots: sick));
    }
  }

  static bool _sickRootsEqual(
    Map<String, List<DependentRef>> a,
    Map<String, List<DependentRef>> b,
  ) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      final other = b[e.key];
      if (other == null || !listEquals(e.value, other)) return false;
    }
    return true;
  }
}
