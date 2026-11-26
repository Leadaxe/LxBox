// §761 — кольца и конфликты цепочек под перезапись `detour` ядра
// v1.14.4-lx.37-rc.2: одному узлу или группе нужен один путь. Решение
// владельца 26.11: клиент копий не делает — цепочка выпадает с подсказкой.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/chains/chain_takeover.dart';

Map<String, dynamic> _cfg(List<Map<String, dynamic>> outbounds,
        [List<Map<String, dynamic>> endpoints = const []]) =>
    {'outbounds': outbounds, 'endpoints': endpoints};

Map<String, dynamic>? _byTag(Map<String, dynamic> c, String tag) {
  for (final key in const ['outbounds', 'endpoints']) {
    for (final e in (c[key] as List)) {
      if ((e as Map)['tag'] == tag) return e.cast<String, dynamic>();
    }
  }
  return null;
}

Map<String, dynamic> _n(String tag, [String type = 'vless']) =>
    {'tag': tag, 'type': type};
Map<String, dynamic> _g(String tag, List<String> m) =>
    {'tag': tag, 'type': 'selector', 'outbounds': m};
Map<String, dynamic> _c(String tag, List<String> p) =>
    {'tag': tag, 'type': 'chain', 'outbounds': p};

void main() {
  test('[A, Направление{A, X}] → выпала, подсказка: копия без A для позиции 2',
      () {
    final c = _cfg([
      _n('A'),
      _n('X'),
      _n('direct', 'direct'),
      _g('vpn-1', ['A', 'X', 'direct']),
      _c('ch', ['A', 'vpn-1']),
    ]);
    final w = applyChainTakeover(c);
    expect(_byTag(c, 'ch'), isNull);
    expect(_byTag(c, 'vpn-1')!['outbounds'], ['A', 'X', 'direct'],
        reason: 'копий нет, группа не тронута');
    expect(c['outbounds'] as List, hasLength(4));
    expect(w.single, contains('"A" is the entry'));
    expect(w.single,
        contains('make a copy of "vpn-1" without "A" for this position'));
  });

  test('[Dir{A, B}, A] → выпала, подсказка: копия Dir без A для входа', () {
    final c = _cfg([
      _n('A'),
      _n('B'),
      _g('d', ['A', 'B']),
      _c('ch', ['d', 'A']),
    ]);
    final w = applyChainTakeover(c);
    expect(_byTag(c, 'ch'), isNull);
    expect(w.single, contains('make a copy of "d" without "A" for the entry'));
  });

  test('общий вход двух цепочек — не конфликт', () {
    final c = _cfg([
      _n('X'),
      _n('Y'),
      _c('c1', ['wg', 'X']),
      _c('c2', ['wg', 'Y']),
    ], [
      _n('wg', 'wireguard'),
    ]);
    expect(applyChainTakeover(c), isEmpty);
    expect(_byTag(c, 'c1'), isNotNull);
    expect(_byTag(c, 'c2'), isNotNull);
  });

  test('группа на позиции ≥ 1 в двух цепочках → нижняя выпала', () {
    final c = _cfg([
      _n('E1'),
      _n('E2'),
      _n('X'),
      _g('grp', ['X']),
      _c('c1', ['E1', 'grp']),
      _c('c2', ['E2', 'grp']),
    ]);
    final w = applyChainTakeover(c);
    expect(_byTag(c, 'c1'), isNotNull);
    expect(_byTag(c, 'c2'), isNull);
    expect(w.single, contains('"grp" is used in chains "c1" (position 2)'));
    expect(w.single, contains('WireGuard copies need other keys'));
  });

  test('узел на позиции ≥ 1 одной цепочки и на входе другой → конфликт', () {
    final c = _cfg([
      _n('E'),
      _n('N'),
      _n('Y'),
      _c('c1', ['E', 'N']),
      _c('c2', ['N', 'Y']),
    ]);
    applyChainTakeover(c);
    expect(_byTag(c, 'c2'), isNull);
  });

  test('две позиции ≥ 1 одной цепочки через группы → выпала', () {
    final c = _cfg([
      _n('E'),
      _n('A'),
      _n('B'),
      _g('g1', ['A']),
      _g('g2', ['A', 'B']),
      _c('ch', ['E', 'g1', 'g2']),
    ]);
    final w = applyChainTakeover(c);
    expect(_byTag(c, 'ch'), isNull);
    expect(w.single, contains('"A" is at positions 2 and 3'));
    expect(w.single, contains('copy of "g2" without "A" for position 3'));
  });

  test('вложенная chain на позиции 2 → выпала', () {
    final c = _cfg([
      _n('A'),
      _n('B'),
      _c('inner', ['A', 'B']),
      _n('E'),
      _c('outer', ['E', 'inner']),
    ]);
    final w = applyChainTakeover(c);
    expect(_byTag(c, 'outer'), isNull);
    expect(w.single, contains('nested chain'));
  });

  test('кольцо через detour: detour узла входа ведёт в позицию выше → выпала',
      () {
    final c = _cfg([
      {'tag': 'A', 'type': 'vless', 'detour': 'N'},
      _n('N'),
      _c('ch', ['A', 'N']),
    ]);
    final w = applyChainTakeover(c);
    expect(_byTag(c, 'ch'), isNull);
    expect(w.single, contains('remove that detour'));
  });

  test('тег хопа занят узлом → выпала', () {
    final c = _cfg([
      _n('A'),
      _n('B'),
      _n('ch#1'),
      _c('ch', ['A', 'B']),
    ]);
    applyChainTakeover(c);
    expect(_byTag(c, 'ch'), isNull);
  });

  test('цепочка без пересечений не меняется', () {
    final c = _cfg([
      _n('A'),
      _n('B'),
      _c('ch', ['A', 'B']),
    ]);
    expect(applyChainTakeover(c), isEmpty);
    expect((c['outbounds'] as List), hasLength(3));
  });
}
