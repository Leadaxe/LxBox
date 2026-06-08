import 'dart:convert';

/// §085 R2 — on-demand структурные запросы к собранному sing-box config'у.
///
/// До §085 каждый сайт (home view/copy/count, stats detour-chain)
/// независимо делал `jsonDecode(configRaw)` + unpack `outbounds`/`endpoints`
/// + traversal по `detour`. Detour-chain логика была продублирована 3×
/// (home_screen, stats_screen, builder). Этот класс — единый owner.
///
/// **Отличие от `ConfigCache`** (`models/home_state.dart`): `ConfigCache` —
/// derived render-state (detourTags/protoByTag), парсится один раз per
/// `HomeState` для hot-path itemBuilder'а. `ConfigIntrospection` — on-demand
/// query-объект для редких операций (tap «View JSON» / «Copy», stats init),
/// даёт by-tag lookup + chain traversal + count. Парсит при создании.
class ConfigIntrospection {
  ConfigIntrospection._(this._byTag, this._kindByTag);

  final Map<String, Map<String, dynamic>> _byTag;
  final Map<String, String> _kindByTag; // tag → 'outbound' | 'endpoint'

  /// Control-outbound типы — не считаются payload-нодами.
  static const _controlTypes = <String>{
    'selector', 'urltest', 'direct', 'block', 'dns',
  };

  /// Парсит configRaw. На malformed JSON → пустой introspection (queries
  /// возвращают null/0/empty — caller'ы деградируют к placeholder'ам).
  factory ConfigIntrospection.parse(String configRaw) {
    final byTag = <String, Map<String, dynamic>>{};
    final kindByTag = <String, String>{};
    if (configRaw.isNotEmpty) {
      try {
        final cfg = jsonDecode(configRaw) as Map<String, dynamic>;
        void index(String key, String kind) {
          for (final o in (cfg[key] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()) {
            final t = o['tag'];
            if (t is String) {
              byTag[t] = o;
              kindByTag[t] = kind;
            }
          }
        }

        index('outbounds', 'outbound');
        index('endpoints', 'endpoint');
      } catch (_) {
        // malformed — empty maps.
      }
    }
    return ConfigIntrospection._(byTag, kindByTag);
  }

  /// Raw outbound/endpoint map по tag'у, либо null.
  Map<String, dynamic>? outboundByTag(String tag) => _byTag[tag];

  /// `'outbound'` / `'endpoint'` (default `'outbound'` если неизвестен).
  String kindOf(String tag) => _kindByTag[tag] ?? 'outbound';

  /// Tag detour-цели данного outbound'а, либо null.
  String? detourOf(String tag) {
    final d = _byTag[tag]?['detour'];
    return (d is String && d.isNotEmpty) ? d : null;
  }

  /// Цепочка outbound-map'ов начиная с `tag`: `[self, detour1, detour2, …]`.
  /// Cycle-safe. Пустой список если tag не найден.
  List<Map<String, dynamic>> outboundChain(String tag) {
    final self = _byTag[tag];
    if (self == null) return const [];
    final chain = <Map<String, dynamic>>[self];
    final seen = <String>{tag};
    var cur = self['detour'];
    while (cur is String && cur.isNotEmpty && seen.add(cur)) {
      final next = _byTag[cur];
      if (next == null) break;
      chain.add(next);
      cur = next['detour'];
    }
    return chain;
  }

  /// Цепочка detour-**тегов** (без self): `[detour1, detour2, …]`. Cycle-safe.
  List<String> detourChain(String tag) {
    final chain = <String>[];
    final seen = <String>{tag};
    var cur = detourOf(tag);
    while (cur != null && seen.add(cur)) {
      chain.add(cur);
      cur = detourOf(cur);
    }
    return chain;
  }

  /// Количество payload-нод (non-control outbounds + все endpoints).
  int get nodeCount {
    var n = 0;
    _byTag.forEach((tag, o) {
      if (_kindByTag[tag] == 'endpoint') {
        n++;
      } else {
        final type = o['type']?.toString() ?? '';
        if (!_controlTypes.contains(type)) n++;
      }
    });
    return n;
  }
}
