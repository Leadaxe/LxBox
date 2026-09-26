import 'dart:convert';

import '../services/contract/protocol_level.dart';
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
    required this.transportLabel,
    required this.securityLabel,
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

  /// §102 — транспорт-слот subtitle: `transport.type` из конфига
  /// (`ws`/`grpc`/`xhttp`/`httpupgrade`/`quic`; sing-box `http` ≙ H2 → `h2`),
  /// либо `tcp` для v2ray-протоколов без transport-блока (default stream).
  /// `null` = слот не показываем (wg/hy2/tuic — транспорт зашит в протокол).
  /// §103 — вычисляется один раз в [ParsedConfig.parse] (eager, не getter).
  final String? transportLabel;

  /// §102 — security-слот subtitle. Схема с `levels` в реестре — подпись
  /// уровня протокола (§56/§60, контракт 1.1.60): старший `level` заданных
  /// полей и их форм-диапазонов плюс суффиксы `level_mark` (AmneziaWG:
  /// `awg`, `awg1.5+`, `awg2`, `awg3.1`…); ни одного поля уровня — `null`.
  /// Остальные протоколы — `Reality`/`TLS` (+`+Vision` при
  /// `flow=xtls-rprx-vision`) по конфигу.
  /// §103 — вычисляется один раз в [ParsedConfig.parse] (eager, не getter).
  final String? securityLabel;

  static String? _deriveTransport(String type, Map<String, dynamic> raw) {
    // §130/§393 — MASQUE ходит поверх QUIC(h3)/h2. Версия HTTP лежит в СВОЁМ
    // ключе `vhttp`, а не в `transport` (там у остальных типов объект
    // `{type: …}` — ws/grpc/…). Legacy-имя `network` НЕ читается (контракт
    // 0.8.0, D-078). Пусто → дефолт h3.
    if (type == 'masque') {
      final net = raw['vhttp'];
      return (net is String && net.isNotEmpty) ? net : 'h3';
    }
    final tr = raw['transport'];
    if (tr is Map) {
      final t = tr['type'];
      if (t is String && t.isNotEmpty) return t == 'http' ? 'h2' : t;
    }
    // §269 — anytls: TCP-over-TLS без transport-обёртки (как trojan).
    if (const {'vless', 'vmess', 'trojan', 'anytls'}.contains(type)) {
      return 'tcp';
    }
    return null;
  }

  /// Слот `securityLabel` — второй чип подзаголовка узла после транспорта.
  /// Схема с `levels` в реестре (§56/§60, сейчас AmneziaWG) — подпись уровня
  /// ([protocolLevelByRegistry]); иначе TLS / Reality (+Vision) по
  /// `tls`/`reality`/`flow`.
  static String? _deriveSecurity(String type, Map<String, dynamic> raw) {
    final level = protocolLevelByRegistry(type, raw);
    if (level != null) return level;
    final tls = raw['tls'];
    if (tls is Map && tls['enabled'] == true) {
      final reality = tls['reality'];
      final base =
          (reality is Map && reality['enabled'] == true) ? 'Reality' : 'TLS';
      // Vision (xtls-rprx-vision) — поверх TLS/Reality, только на голом TCP
      // (с v2ray-транспортами несовместим по протоколу).
      final flow = raw['flow'];
      return flow is String && flow.startsWith('xtls-rprx-vision')
          ? '$base+Vision'
          : base;
    }
    return null;
  }

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
      // §103 — transport/security лейблы деривятся здесь же, один раз.
      for (final (o, kind) in raws) {
        final t = o['tag'];
        if (t is! String) continue;
        final d = o['detour'];
        final type = (o['type'] as String?) ?? '';
        byTag[t] = ConfigNode(
          tag: t,
          type: type,
          kind: kind,
          detour: (d is String && d.isNotEmpty) ? d : null,
          isMarkedDetour: TagResolver.isDetourMarker(t),
          detourRefCount: detourTargets[t] ?? 0,
          raw: o,
          transportLabel: ConfigNode._deriveTransport(type, o),
          securityLabel: ConfigNode._deriveSecurity(type, o),
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

  /// Протокол payload-ноды (`null` для control-узла / пустого type / missing).
  /// Прямая замена `ConfigCache.protoByTag[tag]` (тот скипал и control-типы,
  /// и `type.isEmpty` — поэтому здесь тоже guard на непустой type).
  String? protocolOf(String tag) {
    final n = byTag[tag];
    return (n != null && !n.isControl && n.type.isNotEmpty) ? n.type : null;
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
