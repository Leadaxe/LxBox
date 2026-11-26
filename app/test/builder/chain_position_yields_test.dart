// §761 — ядро v1.14.4-lx.37-rc.2 ставит `detour` узлам позиций ≥ 1 цепочки
// само и отвергает у них фиксированный локальный порт и поля привязки
// сокета (ALGORITHM К5). Сборка снимает эти поля по готовому конфигу.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/builder/post_steps/chain_position_yields.dart';

Map<String, dynamic> _byTag(Map<String, dynamic> config, String tag) {
  for (final key in const ['outbounds', 'endpoints']) {
    for (final e in (config[key] as List? ?? const [])) {
      if ((e as Map)['tag'] == tag) return e.cast<String, dynamic>();
    }
  }
  throw StateError('no $tag');
}

void main() {
  test('лист группы на позиции ≥ 1: порты и поля К5 сняты, позиция 0 цела', () {
    final config = <String, dynamic>{
      'outbounds': [
        {
          'tag': 'entry',
          'type': 'vless',
          'bind_interface': 'wlan0',
          'tcp_fast_open': true,
        },
        {
          'tag': 'grp',
          'type': 'selector',
          'outbounds': ['inner', 'direct'],
        },
        {
          'tag': 'inner',
          'type': 'urltest',
          'outbounds': ['ts', 'vl'],
        },
        {
          'tag': 'vl',
          'type': 'vless',
          'routing_mark': 7,
          'domain_resolver': 'dns-local',
          'connect_timeout': '5s',
        },
        {'tag': 'direct', 'type': 'direct', 'bind_interface': 'eth0'},
        {
          'tag': 'c',
          'type': 'chain',
          'outbounds': ['entry', 'grp', 'wg'],
        },
      ],
      'endpoints': [
        {'tag': 'wg', 'type': 'wireguard', 'listen_port': 51820, 'mtu': 1408},
        {
          'tag': 'ts',
          'type': 'tailscale',
          'listen_port': 41641,
          'relay_server_port': 3478,
          'netns': 'x',
        },
      ],
    };
    final warnings = applyChainPositionYields(config);

    final entry = _byTag(config, 'entry');
    expect(entry['bind_interface'], 'wlan0');
    expect(entry['tcp_fast_open'], isTrue);

    expect(_byTag(config, 'wg').containsKey('listen_port'), isFalse);
    expect(_byTag(config, 'wg')['mtu'], 1408);

    final ts = _byTag(config, 'ts');
    expect(ts.containsKey('listen_port'), isFalse);
    expect(ts.containsKey('relay_server_port'), isFalse);
    expect(ts.containsKey('netns'), isFalse);

    final vl = _byTag(config, 'vl');
    expect(vl.containsKey('routing_mark'), isFalse);
    // Эти ядро применяет и под detour — не трогаются.
    expect(vl['domain_resolver'], 'dns-local');
    expect(vl['connect_timeout'], '5s');

    // `direct` цепочка не перехватывает.
    expect(_byTag(config, 'direct')['bind_interface'], 'eth0');

    expect(warnings, hasLength(3));
    expect(warnings.where((w) => w.contains('"wg"') && w.contains('listen_port')),
        hasLength(1));
  });

  test('OpenConnect dtls_local_port снят; у WireGuard на позиции 0 порт цел', () {
    final config = <String, dynamic>{
      'outbounds': [
        {
          'tag': 'c',
          'type': 'chain',
          'outbounds': ['wg', 'oc'],
        },
      ],
      'endpoints': [
        {'tag': 'wg', 'type': 'wireguard', 'listen_port': 51820},
        {'tag': 'oc', 'type': 'openconnect', 'dtls_local_port': 4443},
      ],
    };
    applyChainPositionYields(config);
    expect(_byTag(config, 'wg')['listen_port'], 51820);
    expect(_byTag(config, 'oc').containsKey('dtls_local_port'), isFalse);
  });

  test('конфликт перехвата: предупреждение, поля узла не трогаются без причины',
      () {
    final config = <String, dynamic>{
      'outbounds': [
        {'tag': 'a', 'type': 'vless'},
        {'tag': 'b', 'type': 'vless'},
        {'tag': 'n', 'type': 'vless'},
        {
          'tag': 'c1',
          'type': 'chain',
          'outbounds': ['a', 'n'],
        },
        {
          'tag': 'c2',
          'type': 'chain',
          'outbounds': ['n', 'b'],
        },
      ],
    };
    final warnings = applyChainPositionYields(config);
    expect(warnings, hasLength(1));
    expect(warnings.single, contains('"n"'));
    expect(warnings.single, contains('chain "c1" position 2'));
    expect(warnings.single, contains('chain "c2" position 1'));
  });

  test('без цепочек — ничего', () {
    final config = <String, dynamic>{
      'outbounds': [
        {'tag': 'a', 'type': 'vless', 'bind_interface': 'wlan0'},
      ],
    };
    expect(applyChainPositionYields(config), isEmpty);
    expect(_byTag(config, 'a')['bind_interface'], 'wlan0');
  });
}
