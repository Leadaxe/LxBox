// §761 — сохранённые цепочки, которые сборка выбрасывает на ядре
// v1.14.4-lx.37-rc.2: обнаружение той же проверкой, что у редактора, и
// отметка «скрыто» до следующего изменения конфига.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/chains/chain_takeover.dart';
import 'package:lxbox/services/chains/chain_trouble_state.dart';

({String section, Map<String, dynamic> body}) _ob(Map<String, dynamic> b) =>
    (section: 'outbounds', body: b);

ChainBodies _bodies(List<Map<String, dynamic>> list) =>
    {for (final b in list) b['tag'] as String: _ob(b)};

Map<String, dynamic> _n(String tag) => {'tag': tag, 'type': 'vless'};
Map<String, dynamic> _g(String tag, List<String> m) =>
    {'tag': tag, 'type': 'selector', 'outbounds': m};

SourceChain _c(String tag, List<String> hops) =>
    SourceChain(tag: tag, hops: [for (final h in hops) NodeLink(tag: h)]);

void main() {
  // Собранный конфиг: выпавших цепочек в нём нет.
  final built = _bodies([
    _n('A'),
    _n('X'),
    _n('E1'),
    _n('E2'),
    _g('vpn-1', ['A', 'X']),
    _g('vpn-2', ['X']),
    _n('Z'),
    _g('vpn-1 copy', ['Z']),
    {'tag': 'c1', 'type': 'chain', 'outbounds': ['E1', 'vpn-2']},
  ]);

  test('старая [A, Направление{A, X}] → подсказка с копией Направления', () {
    final t = findChainTroubles(
        chains: [_c('old', ['A', 'vpn-1'])], bodies: built);
    expect(t, hasLength(1));
    expect(t.single.chain.tag, 'old');
    expect(t.single.failure.fault, ChainTakeoverFault.ring);
    expect(t.single.message,
        contains('make a copy of "vpn-1" without "A" for this position'));
  });

  test('Направление на позиции ≥ 1 двух цепочек → подсказка у второй', () {
    final t = findChainTroubles(chains: [
      _c('c1', ['E1', 'vpn-2']),
      _c('c2', ['E2', 'vpn-2']),
    ], bodies: built);
    expect(t.map((e) => e.chain.tag), ['c2']);
    expect(t.single.message, contains('"c1"'));
    expect(t.single.message, contains('WireGuard copies need other keys'));
    // На главном экране «здесь» нет: обе цепочки по имени.
    expect(t.single.message, contains('and in chain "c2" (position 2)'));
    expect(t.single.message, isNot(contains('here')));
  });

  test('узел с фиксированным портом на позиции 2 → подсказка про порт', () {
    final withPort = {
      ...built,
      'wg': _ob({'tag': 'wg', 'type': 'wireguard', 'listen_port': 51820}),
    };
    final t = findChainTroubles(
        chains: [_c('p', ['E1', 'wg'])], bodies: withPort);
    expect(t.single.failure.fault, ChainTakeoverFault.localPort);
    expect(t.single.message,
        contains('"wg" at position 2 of chain "p" has a fixed local port'));
  });

  test('общий вход двух цепочек — без подсказки', () {
    final t = findChainTroubles(chains: [
      _c('c1', ['E1', 'vpn-2']),
      _c('c3', ['E1', 'A']),
    ], bodies: built);
    expect(t, isEmpty);
  });

  test('исправленная цепочка — подсказки нет; выключенная — не судится', () {
    expect(
        findChainTroubles(
            chains: [_c('old', ['A', 'vpn-1 copy'])], bodies: built),
        isEmpty);
    expect(
        findChainTroubles(
            chains: [_c('old', ['A', 'vpn-1']).copyWith(enabled: false)],
            bodies: built),
        isEmpty);
  });

  test('«скрыть» держится до изменения конфига', () {
    final t = findChainTroubles(
        chains: [_c('old', ['A', 'vpn-1'])], bodies: built);
    final stamp = chainTroubleStamp(t, built);
    expect(chainTroubleStamp(t, built), stamp, reason: 'стабильна');

    final st = ChainTroubleState.I;
    st.setForTest(t, stamp: stamp, dismissed: stamp);
    expect(st.visible, isEmpty, reason: 'скрыта при этом же конфиге');

    final changed = {
      ...built,
      'Y': _ob(_n('Y')),
    };
    final next = chainTroubleStamp(t, changed);
    expect(next, isNot(stamp));
    st.setForTest(t, stamp: next, dismissed: stamp);
    expect(st.visible, hasLength(1), reason: 'конфиг изменился — снова видна');
    st.setForTest(const []);
  });
}
