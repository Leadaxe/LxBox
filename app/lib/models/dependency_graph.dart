import 'dart:convert';

import 'config_node.dart';

/// §355 — один пострадавший от мёртвой ноды-корня: DNS-сервер или нода,
/// зависящие от неё напрямую (detour) или через канал/цепочку.
class DependentRef {
  const DependentRef({
    required this.kind,
    required this.tag,
    this.via,
  });

  /// `'dns'` — DNS-сервер конфига; `'node'` — outbound/endpoint.
  final String kind;

  /// Тег зависимого (dns-tag или tag ноды).
  final String tag;

  /// Тег узла, на который зависимый ссылается СВОИМ detour'ом, когда это не
  /// сам корень (обычно канал: `yandex_udp → via vpn-2`). `null` — прямой
  /// detour на корень.
  final String? via;

  bool get isDns => kind == 'dns';

  @override
  bool operator ==(Object other) =>
      other is DependentRef &&
      other.kind == kind &&
      other.tag == tag &&
      other.via == via;

  @override
  int get hashCode => Object.hash(kind, tag, via);

  @override
  String toString() => 'DependentRef($kind $tag via=$via)';
}

/// §355 — граф detour-зависимостей собранного конфига (статика) + запрос
/// «кто пострадал от мёртвой ноды» (динамика подаётся аргументами).
///
/// Статика строится из configRaw одним проходом (аналог [ParsedConfig.parse],
/// но со стороны рёбер): ноды/endpoints с `detour`, DNS-серверы с `detour`,
/// состав selector/urltest-групп. Пересоздаётся на смену configRaw — держит
/// HomeController (та же parse-once дисциплина §091).
///
/// Динамика — два уже существующих потока (§355: никакой новой диагностики):
/// выбор selector-групп (groups-стрим CC) и замеры пинга (`delayByChannel`).
class DependencyGraph {
  const DependencyGraph._({
    required Map<String, List<DependentRef>> dependentsOf,
    required Map<String, List<String>> selectorMembers,
    required Map<String, List<String>> urltestMembers,
    required Set<String> payloadTags,
  })  : _dependentsOf = dependentsOf,
        _selectorMembers = selectorMembers,
        _urltestMembers = urltestMembers,
        _payloadTags = payloadTags;

  const DependencyGraph.empty()
      : _dependentsOf = const {},
        _selectorMembers = const {},
        _urltestMembers = const {},
        _payloadTags = const {};

  /// Обратные рёбра: цель (нода или канал) → кто на неё ссылается detour'ом.
  final Map<String, List<DependentRef>> _dependentsOf;

  /// selector-группы → члены (болеют по текущему ВЫБОРУ — см. [computeSick]).
  final Map<String, List<String>> _selectorMembers;

  /// urltest-группы → члены (самолечатся §308: больны только когда мертвы ВСЕ).
  final Map<String, List<String>> _urltestMembers;

  /// Теги payload-нод (не control) — кандидаты в dead-корни.
  final Set<String> _payloadTags;

  bool get isEmpty =>
      _dependentsOf.isEmpty && _selectorMembers.isEmpty && _payloadTags.isEmpty;

  /// Прямые зависимые узла (без транзитивности) — для секции «кто через меня»
  /// на живой ноде.
  List<DependentRef> directDependents(String tag) =>
      _dependentsOf[tag] ?? const [];

  /// Malformed JSON → пустой граф (запросы отдают пусто, UI молчит — та же
  /// деградация, что у [ParsedConfig.parse]).
  factory DependencyGraph.fromConfig(String configRaw) {
    if (configRaw.isEmpty) return const DependencyGraph.empty();
    final dependents = <String, List<DependentRef>>{};
    final selectorMembers = <String, List<String>>{};
    final urltestMembers = <String, List<String>>{};
    final payload = <String>{};
    try {
      final cfg = jsonDecode(configRaw) as Map<String, dynamic>;
      final raws = [
        ...(cfg['outbounds'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>(),
        ...(cfg['endpoints'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>(),
      ];
      for (final o in raws) {
        final tag = o['tag'];
        if (tag is! String || tag.isEmpty) continue;
        final type = o['type'] as String? ?? '';
        if (!ConfigNode.kControlTypes.contains(type)) payload.add(tag);
        final detour = o['detour'];
        if (detour is String && detour.isNotEmpty) {
          (dependents[detour] ??= [])
              .add(DependentRef(kind: 'node', tag: tag));
        }
        if (type == 'selector' || type == 'urltest') {
          final members = (o['outbounds'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList();
          (type == 'selector' ? selectorMembers : urltestMembers)[tag] =
              members;
        }
      }
      final servers = (cfg['dns']?['servers'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>();
      for (final s in servers) {
        final tag = s['tag'];
        final detour = s['detour'];
        if (tag is! String || tag.isEmpty) continue;
        if (detour is String && detour.isNotEmpty) {
          (dependents[detour] ??= [])
              .add(DependentRef(kind: 'dns', tag: tag));
        }
      }
    } catch (_) {
      return const DependencyGraph.empty();
    }
    return DependencyGraph._(
      dependentsOf: dependents,
      selectorMembers: selectorMembers,
      urltestMembers: urltestMembers,
      payloadTags: payload,
    );
  }

  /// Health ноды по замерам всех каналов (§355 §3.3): у замеров нет
  /// таймстампов, поэтому правило консервативное — «жива, если хоть в одном
  /// канале >0»; dead — только когда замеры есть и ВСЕ отрицательные;
  /// без замеров — unknown (false, не тревожим).
  static bool _isDead(String tag, Map<String, Map<String, int>> delays) {
    var seen = false;
    for (final channel in delays.values) {
      final v = channel[tag];
      if (v == null) continue;
      if (v >= 0) return false;
      seen = true;
    }
    return seen;
  }

  /// «Корни беды» → их транзитивные пострадавшие (§355 §3.4).
  ///
  /// [selections] — текущий выбор selector-групп (тег группы → выбранный член;
  /// только selector'ы: urltest-выбор сюда не подавать — те самолечатся §308).
  /// [delays] — `HomeState.delayByChannel` как есть.
  ///
  /// Возвращает только корни с непустым списком пострадавших (dead-нода, от
  /// которой никто не зависит, — не тревога, просто мёртвая нода).
  Map<String, List<DependentRef>> computeSick({
    required Map<String, String> selections,
    required Map<String, Map<String, int>> delays,
  }) {
    if (isEmpty) return const {};
    // dead-кандидаты: только payload-ноды с подтверждённой смертью.
    final dead = <String>{
      for (final tag in _payloadTags)
        if (_isDead(tag, delays)) tag,
    };
    if (dead.isEmpty) return const {};

    // Каналы, где выбран данный узел (обратный индекс выбора).
    final selectedIn = <String, List<String>>{};
    selections.forEach((group, selected) {
      if (_selectorMembers.containsKey(group)) {
        (selectedIn[selected] ??= []).add(group);
      }
    });

    final result = <String, List<DependentRef>>{};
    for (final root in dead) {
      final visited = <String>{root};
      final queue = <String>[root];
      final affected = <DependentRef>[];
      while (queue.isNotEmpty) {
        final cur = queue.removeLast();
        // 1. Прямые зависимые (detour на cur). DNS — лист; нода заражается
        //    и распространяет дальше.
        for (final dep in _dependentsOf[cur] ?? const <DependentRef>[]) {
          if (!visited.add(dep.tag)) continue;
          affected.add(DependentRef(
            kind: dep.kind,
            tag: dep.tag,
            via: cur == root ? null : cur,
          ));
          if (!dep.isDns) queue.add(dep.tag);
        }
        // 2. Selector-каналы, где cur сейчас выбран, — заражаются как
        //    транзитные узлы (в affected не попадают: они контекст, не жертва).
        for (final group in selectedIn[cur] ?? const <String>[]) {
          if (visited.add(group)) queue.add(group);
        }
        // 3. Urltest-группы больны только при ПОЛНОСТЬЮ мёртвом составе.
        _urltestMembers.forEach((group, members) {
          if (visited.contains(group) || !members.contains(cur)) return;
          if (members.every(dead.contains)) {
            visited.add(group);
            queue.add(group);
          }
        });
      }
      if (affected.isNotEmpty) result[root] = affected;
    }
    return result;
  }
}
