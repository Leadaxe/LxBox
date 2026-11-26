/// §761 — узлы, которые цепочка перехватывает на позиции ≥ 1.
///
/// С ядра v1.14.4-lx.37-rc.2 (SPEC 165 форка) цепочка сама ставит `detour`
/// каждому узлу, до которого доходит на позиции ≥ 1: узел позиции или любой
/// лист группы там, на любой глубине, выбранный и нет, кроме `direct` и
/// `block`. Такой узел с фиксированным локальным портом или с полями
/// привязки сокета, которые под `detour` не действуют, ядро отвергает при
/// загрузке — и с ним весь конфиг (ALGORITHM К5).
///
/// LxBox этим узлам `detour` не пишет, поэтому шаг `applyDetourYields`
/// (контракт 1.1.65) их не видит. Шаг ниже снимает поля по готовому
/// конфигу. Кода реестра под это нет — строки предупреждения без кода.
library;

/// Фиксированный локальный порт по типу узла (ALGORITHM К5).
const Map<String, List<String>> kChainHopLocalPortFields = {
  'wireguard': ['listen_port'],
  'tailscale': ['listen_port', 'relay_server_port'],
  'openconnect': ['dtls_local_port'],
};

/// Поля привязки сокета, которые апстрим под `detour` не применяет: сокет
/// узла открывает хоп цепочки (ALGORITHM К5). `domain_resolver`,
/// `fallback_delay`, `connect_timeout`, keepalive и `udp_fragment` сюда не
/// входят — их ядро применяет и под `detour`.
const List<String> kChainHopSocketFields = [
  'bind_interface',
  'inet4_bind_address',
  'inet6_bind_address',
  'bind_address_no_port',
  'protect_path',
  'routing_mark',
  'reuse_addr',
  'netns',
  'tcp_fast_open',
  'tcp_multi_path',
  'network_strategy',
  'network_type',
  'fallback_network_type',
];

const _kGroupTypes = {'selector', 'urltest'};
const _kNotTakenOver = {'direct', 'block', 'dns'};

/// Позиция цепочки, на которой узел достигнут.
typedef ChainReach = ({String chain, int position});

/// Где цепочки конфига достигают узлов: тег листа → позиции. Позиция 0
/// тоже входит — по ней судится конфликт перехвата.
Map<String, List<ChainReach>> chainReaches(Map<String, dynamic> config) {
  final byTag = <String, Map<String, dynamic>>{};
  for (final key in const ['outbounds', 'endpoints']) {
    final list = config[key];
    if (list is! List) continue;
    for (final e in list) {
      if (e is Map<String, dynamic> && e['tag'] is String) {
        byTag[e['tag'] as String] = e;
      }
    }
  }
  final out = <String, List<ChainReach>>{};
  for (final chain in byTag.values) {
    if (chain['type'] != 'chain') continue;
    final positions = chain['outbounds'];
    if (positions is! List) continue;
    final chainTag = chain['tag'] as String;
    for (var i = 0; i < positions.length; i++) {
      final leaves = <String>{};
      _leaves('${positions[i]}', byTag, leaves, <String>{});
      for (final leaf in leaves) {
        out.putIfAbsent(leaf, () => []).add((chain: chainTag, position: i));
      }
    }
  }
  return out;
}

void _leaves(String tag, Map<String, Map<String, dynamic>> byTag,
    Set<String> out, Set<String> seen) {
  if (!seen.add(tag)) return;
  final node = byTag[tag];
  if (node == null) return;
  final type = node['type'];
  if (_kGroupTypes.contains(type)) {
    final members = node['outbounds'];
    if (members is List) {
      for (final m in members) {
        _leaves('$m', byTag, out, seen);
      }
    }
    return;
  }
  // Вложенная цепочка выше позиции 0 — ошибка ядра, её ловит сборка цепочек
  // (`chain_nested_position`); на позиции 0 она идёт своим путём.
  if (type == 'chain' || _kNotTakenOver.contains(type)) return;
  out.add(tag);
}

/// Снять у узлов позиций ≥ 1 поля, с которыми ядро их не загрузит, и
/// сообщить о конфликте перехвата. Возвращает строки для `emitWarnings`.
///
/// Конфликт (узел на позиции ≥ 1 двух цепочек или двух позиций, или на ≥ 1
/// одной и на 0 другой) сборка не чинит: ядро не загрузит такой конфиг, а
/// молча выбрать одну цепочку значило бы подменить маршрут.
List<String> applyChainPositionYields(Map<String, dynamic> config) {
  final reaches = chainReaches(config);
  if (reaches.isEmpty) return const [];
  final warnings = <String>[];
  for (final key in const ['outbounds', 'endpoints']) {
    final list = config[key];
    if (list is! List) continue;
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      final tag = e['tag'];
      if (tag is! String) continue;
      final at = reaches[tag];
      if (at == null) continue;
      final takenOver = [for (final r in at) if (r.position >= 1) r];
      if (takenOver.isEmpty) continue;
      if (at.length > 1) {
        warnings.add('Node "$tag" is reached by more than one chain position '
            '(${at.map(_where).join(', ')}) and taken over past the first '
            'position: the core rejects such a config.');
      }
      final fields = [
        ...?kChainHopLocalPortFields[e['type']],
        ...kChainHopSocketFields,
      ];
      final removed = [
        for (final f in fields)
          if (e.containsKey(f)) f,
      ];
      if (removed.isEmpty) continue;
      for (final f in removed) {
        e.remove(f);
      }
      warnings.add('Node "$tag" (${_where(takenOver.first)}): removed '
          '${removed.join(', ')} — a node the chain dials through the position '
          'below cannot use them.');
    }
  }
  return warnings;
}

String _where(ChainReach r) => 'chain "${r.chain}" position ${r.position + 1}';
