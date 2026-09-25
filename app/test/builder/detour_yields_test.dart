import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/builder/post_steps.dart';

import '../contract_paths.dart';

/// Контракт 1.1.65 — `detour` дописывает сборка после санитайзера, и связи
/// `conflicts {with: detour}` реестра судятся по готовому телу: уступающее
/// поле снимается с кодом связи, хоп остаётся.
void main() {
  setUpAll(loadTestRegistry);

  Map<String, dynamic> wg({String? detour}) => {
        'type': 'wireguard',
        'tag': 'wg',
        'listen_port': 51820,
        'detour': ?detour,
      };

  test('listen_port уступает detour — код связи, хоп сохранён', () {
    final ep = wg(detour: 'relay');
    final ws = applyDetourYields({
      'endpoints': [ep],
    });
    expect(ep.containsKey('listen_port'), isFalse);
    expect(ep['detour'], 'relay');
    expect(ws.map((w) => w.code), ['detour_with_listen_port']);
    expect(ws.single.params['tag'], 'wg');
    expect(ws.single.params['target'], 'relay');
  });

  test('без detour тело не трогается', () {
    final ep = wg();
    expect(applyDetourYields({'endpoints': [ep]}), isEmpty);
    expect(ep['listen_port'], 51820);
  });
}
