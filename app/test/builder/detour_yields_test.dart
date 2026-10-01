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

  // Контракт 1.1.84 (§81) — `tls.fragment` уступает detour; вслед уходит
  // осиротевший `fragment_fallback_delay`, если `record_fragment` не задан.
  Map<String, dynamic> vless(Map<String, dynamic> tls) => {
        'type': 'vless',
        'tag': 'v',
        'server': 'example.com',
        'server_port': 443,
        'uuid': '11111111-1111-1111-1111-111111111111',
        'detour': 'hop',
        'tls': tls,
      };

  test('tls.fragment уступает detour вместе с осиротевшей паузой', () {
    final ob = vless({
      'enabled': true,
      'fragment': true,
      'fragment_fallback_delay': '500ms',
    });
    final ws = applyDetourYields({
      'outbounds': [ob],
    });
    expect(ws.map((w) => w.code), ['detour_with_tls_fragment']);
    expect(ws.single.params['target'], 'hop');
    expect(ob['tls'], {'enabled': true});
    expect(ob['detour'], 'hop');
  });

  test('при record_fragment пауза остаётся', () {
    final ob = vless({
      'enabled': true,
      'fragment': true,
      'record_fragment': true,
      'fragment_fallback_delay': '500ms',
    });
    applyDetourYields({
      'outbounds': [ob],
    });
    expect(ob['tls'], {
      'enabled': true,
      'record_fragment': true,
      'fragment_fallback_delay': '500ms',
    });
  });

  // §577 — авторское тело: уступка идёт через точку правки.
  group('авторское тело', () {
    test('tls.fragment остаётся, код с applied: false', () {
      final ob = vless({
        'enabled': true,
        'fragment': true,
        'fragment_fallback_delay': '500ms',
      });
      final ws = applyDetourYields({
        'outbounds': [ob],
      }, authored: Set.identity()..add(ob));
      expect(ob['tls'], {
        'enabled': true,
        'fragment': true,
        'fragment_fallback_delay': '500ms',
      });
      expect(ws.map((w) => (w.code, w.applied)),
          [('detour_with_tls_fragment', false)]);
    });

    test('listen_port WireGuard при detour — жёсткое, снимается', () {
      final ep = wg(detour: 'relay');
      final ws = applyDetourYields({
        'endpoints': [ep],
      }, authored: Set.identity()..add(ep));
      expect(ep.containsKey('listen_port'), isFalse);
      expect(ws.map((w) => (w.code, w.applied)),
          [('detour_with_listen_port', true)]);
    });
  });
}
