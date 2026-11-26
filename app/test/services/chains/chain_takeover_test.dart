// §761 — кольца и конфликты цепочек под перезапись `detour` ядра
// v1.14.4-lx.37-rc.2: одному узлу или группе нужен один путь.
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
Map<String, dynamic> _g(String tag, List<String> m, {String? def}) =>
    {'tag': tag, 'type': 'selector', 'outbounds': m, 'default': ?def};
Map<String, dynamic> _c(String tag, List<String> p) =>
    {'tag': tag, 'type': 'chain', 'outbounds': p};

void main() {
  test('[A, Направление{A, X}] → верхняя позиция — копия группы без A', () {
    final c = _cfg([
      _n('A'),
      _n('X'),
      _g('vpn-1', ['A', 'X', 'direct'], def: 'A'),
      _n('direct', 'direct'),
      _c('ch', ['A', 'vpn-1']),
    ]);
    final w = applyChainTakeover(c);
    expect(w, isEmpty, reason: 'это не ошибка для пользователя');
    final pos = (_byTag(c, 'ch')!['outbounds'] as List).cast<String>();
    expect(pos.first, 'A');
    expect(pos[1], isNot('vpn-1'));
    final copy = _byTag(c, pos[1])!;
    expect(copy['outbounds'], ['X', 'direct']);
    expect(copy.containsKey('default'), isFalse);
    // Оригинал Направления не тронут.
    expect(_byTag(c, 'vpn-1')!['outbounds'], ['A', 'X', 'direct']);
  });

  test('группа в двух цепочках → вторая берёт копии группы и узлов', () {
    final c = _cfg([
      _n('E1'),
      _n('E2'),
      _n('X'),
      _n('Y'),
      _g('grp', ['X', 'Y']),
      _c('c1', ['E1', 'grp']),
      _c('c2', ['E2', 'grp']),
    ]);
    expect(applyChainTakeover(c), isEmpty);
    expect(_byTag(c, 'c1')!['outbounds'], ['E1', 'grp']);
    final p2 = (_byTag(c, 'c2')!['outbounds'] as List).cast<String>();
    expect(p2.first, 'E2');
    final copy = _byTag(c, p2[1])!;
    final members = (copy['outbounds'] as List).cast<String>();
    expect(members, hasLength(2));
    expect(members.any((m) => m == 'X' || m == 'Y'), isFalse);
    for (final m in members) {
      expect(_byTag(c, m)!['type'], 'vless');
    }
  });

  test('WireGuard-узел в двух цепочках → вторая цепочка выпала', () {
    final c = _cfg([
      _n('E1'),
      _n('E2'),
      _c('c1', ['E1', 'wg']),
      _c('c2', ['E2', 'wg']),
    ], [
      _n('wg', 'wireguard'),
    ]);
    final w = applyChainTakeover(c);
    expect(_byTag(c, 'c1'), isNotNull);
    expect(_byTag(c, 'c2'), isNull);
    expect(w.single, contains('"c2"'));
    expect(w.single, contains('"wg"'));
    expect(w.single, contains('"c1"'));
  });

  test('WireGuard на позиции 0 обеих цепочек — тоже конфликт', () {
    final c = _cfg([
      _n('X'),
      _n('Y'),
      _c('c1', ['wg', 'X']),
      _c('c2', ['wg', 'Y']),
    ], [
      _n('wg', 'wireguard'),
    ]);
    applyChainTakeover(c);
    expect(_byTag(c, 'c2'), isNull);
  });

  test('вложенная chain на позиции 1 → цепочка выпала', () {
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

  test('кольцо через detour: detour узла позиции 0 ведёт в позицию выше → выпала',
      () {
    final c = _cfg([
      {'tag': 'A', 'type': 'vless', 'detour': 'N'},
      _n('N'),
      _c('ch', ['A', 'N']),
    ]);
    final w = applyChainTakeover(c);
    expect(_byTag(c, 'ch'), isNull);
    expect(w.single, contains('ring'));
  });

  test('[Dir{A, B}, A] → внизу копия группы без A, выход A', () {
    final c = _cfg([
      _n('A'),
      _n('B'),
      _g('d', ['A', 'B']),
      _c('ch', ['d', 'A']),
    ]);
    expect(applyChainTakeover(c), isEmpty);
    final pos = (_byTag(c, 'ch')!['outbounds'] as List).cast<String>();
    expect(pos[1], 'A');
    expect(_byTag(c, pos[0])!['outbounds'], ['B']);
  });

  test('группа опустела после снятия нижних узлов → выпала', () {
    final c = _cfg([
      _n('A'),
      _g('d', ['A']),
      _c('ch', ['A', 'd']),
    ]);
    final w = applyChainTakeover(c);
    expect(_byTag(c, 'ch'), isNull);
    expect(w.single, contains('no nodes left'));
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
