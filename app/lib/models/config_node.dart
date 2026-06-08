import 'dart:convert';

import '../services/tag_resolver.dart';

/// §091 — структурные метаданные одной ноды собранного sing-box config'а.
///
/// `config-tag == нода в Clash` — одна идентичность. Протокол и `detour`-поле
/// лежат в конфиге по точному тегу, поэтому достаются **без reverse-map**
/// (в отличие от subscription id — его в конфиг не пишут, см. §091 spec).
///
/// Один `ConfigNode` на каждый outbound/endpoint (payload + служебные —
/// различаем через [type]/[isControl]). Заменяет три раздельные ре-деривации
/// из `configRaw`: `ConfigCache.protoByTag`/`detourTags`, `ConfigIntrospection`
/// и reverse-map `subscriptionsOfTag` (последний → prefix-фильтр на UI).
class ConfigNode {
  const ConfigNode({
    required this.tag,
    required this.type,
    required this.kind,
    required this.detour,
    required this.isMarkedDetour,
    required this.detourRefCount,
    required this.raw,
  });

  /// Тег как в конфиге = нода в Clash (`proxies[...].all` элемент).
  final String tag;

  /// `type` из конфига: `vless`|`trojan`|…|`selector`|`urltest`|`direct`|
  /// `block`|`dns`. Заменяет `protoByTag` + `isControl` одним полем.
  final String type;

  /// `'outbound'` или `'endpoint'` (из какой секции конфига). Только
  /// WireGuard эмитится как endpoint. Для «View JSON» заголовка.
  final String kind;

  /// Свой hop-таргет (через кого ходит) — поле `detour` конфига, либо null.
  /// Используется контекстным меню (Copy detour) и бэйджем «есть detour».
  final String? detour;

  /// `⚙`-маркер в теге (ручная пометка ноды как detour в node_settings).
  /// Переходное поле — см. план миграции `⚙` в §091 spec.
  final bool isMarkedDetour;

  /// Сколько нод ссылаются на меня как на detour-таргет (релей-роль).
  final int detourRefCount;

  /// Сырой outbound/endpoint JSON — источник для «View JSON» / «Copy».
  final Map<String, dynamic> raw;

  /// Структурно: «я — релей/hop-таргет» (на меня кто-то ссылается).
  bool get isDetour => detourRefCount > 0;

  /// Служебный outbound (не payload-нода) — UI не показывает его как ноду.
  bool get isControl => kControlTypes.contains(type);

  /// Control-типы outbound'ов sing-box (не payload-ноды).
  static const kControlTypes = <String>{
    'selector', 'urltest', 'direct', 'block', 'dns',
  };
}

/// §091 — распарсенный конфиг: `Map<tag, ConfigNode>` + структурные запросы.
///
/// **Статик-слой**: строится один раз на смену `configRaw` (см. `HomeState`),
/// держит только то, что выводимо из конфига. Динамика (пинги/active/urltest)
/// живёт отдельными map'ами и джойнится на рендере (`NodeViewItem`).
///
/// Схлопывает `ConfigCache` (`protoByTag`/`detourTags`) и `ConfigIntrospection`
/// (`outboundByTag`/`detourChain`/`outboundChain`/`nodeCount`) в один объект.
class ParsedConfig {
  const ParsedConfig._(this.byTag);

  const ParsedConfig.empty() : byTag = const <String, ConfigNode>{};

  final Map<String, ConfigNode> byTag;

  /// Парсит `configRaw` одним проходом. Malformed JSON → пустой ParsedConfig
  /// (запросы возвращают null/0/empty — caller'ы деградируют к placeholder'ам).
  factory ParsedConfig.parse(String configRaw) {
    if (configRaw.isEmpty) return const ParsedConfig.empty();
    final byTag = <String, ConfigNode>{};
    final detourTargets = <String, int>{};
    try {
      final cfg = jsonDecode(configRaw) as Map<String, dynamic>;
      final raws = <(Map<String, dynamic>, String)>[
        for (final o in (cfg['outbounds'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>())
          (o, 'outbound'),
        for (final o in (cfg['endpoints'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>())
          (o, 'endpoint'),
      ];
      // Проход 1 — посчитать detour-ссылки.
      for (final (o, _) in raws) {
        final d = o['detour'];
        if (d is String && d.isNotEmpty) {
          detourTargets[d] = (detourTargets[d] ?? 0) + 1;
        }
      }
      // Проход 2 — построить ConfigNode'ы (detourRefCount уже известен).
      for (final (o, kind) in raws) {
        final t = o['tag'];
        if (t is! String) continue;
        final d = o['detour'];
        byTag[t] = ConfigNode(
          tag: t,
          type: (o['type'] as String?) ?? '',
          kind: kind,
          detour: (d is String && d.isNotEmpty) ? d : null,
          isMarkedDetour: TagResolver.isDetourMarker(t),
          detourRefCount: detourTargets[t] ?? 0,
          raw: o,
        );
      }
    } catch (_) {
      // malformed — пустой результат.
    }
    return ParsedConfig._(byTag);
  }

  ConfigNode? operator [](String tag) => byTag[tag];

  Iterable<ConfigNode> get nodes => byTag.values;

  bool get isEmpty => byTag.isEmpty;

  /// `'outbound'` / `'endpoint'` (default `'outbound'` для неизвестного тега).
  String kindOf(String tag) => byTag[tag]?.kind ?? 'outbound';

  /// Raw outbound/endpoint map по tag'у, либо null.
  Map<String, dynamic>? rawOf(String tag) => byTag[tag]?.raw;

  /// Tag detour-цели данной ноды, либо null.
  String? detourOf(String tag) => byTag[tag]?.detour;

  /// Протокол payload-ноды (`null` для control-узла / missing). Прямая
  /// замена `ConfigCache.protoByTag[tag]` (тот тоже скипал control-типы).
  String? protocolOf(String tag) {
    final n = byTag[tag];
    return (n != null && !n.isControl) ? n.type : null;
  }

  /// Цепочка raw-map'ов начиная с `tag`: `[self, detour1, detour2, …]`.
  /// Cycle-safe. Пустой список если tag не найден.
  List<Map<String, dynamic>> outboundChain(String tag) {
    final self = byTag[tag];
    if (self == null) return const [];
    final chain = <Map<String, dynamic>>[self.raw];
    final seen = <String>{tag};
    var cur = self.detour;
    while (cur != null && seen.add(cur)) {
      final next = byTag[cur];
      if (next == null) break;
      chain.add(next.raw);
      cur = next.detour;
    }
    return chain;
  }

  /// Цепочка detour-**тегов** (без self): `[detour1, detour2, …]`. Cycle-safe.
  List<String> detourChain(String tag) {
    final chain = <String>[];
    final seen = <String>{tag};
    var cur = byTag[tag]?.detour;
    while (cur != null && seen.add(cur)) {
      chain.add(cur);
      cur = byTag[cur]?.detour;
    }
    return chain;
  }

  /// Количество payload-нод (non-control). Endpoints (wireguard) — non-control.
  int get nodeCount => byTag.values.where((n) => !n.isControl).length;
}
