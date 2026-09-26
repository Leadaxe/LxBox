import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import 'engine_test_setup.dart';

/// Контракт 1.1.80 (§77 п.1) — строка `vpn://` внутри списка ссылок даёт все
/// WG/AWG-контейнеры профиля; origin каждого — `.conf`; контейнер по
/// умолчанию сохраняет прежнее имя строки (имя профиля).
String _conf(String host) => '[Interface]\n'
    'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
    'Address = 10.0.0.2/32\n'
    '[Peer]\n'
    'PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\n'
    'AllowedIPs = 0.0.0.0/0\n'
    'Endpoint = $host:51820\n';

String _profile() {
  Map<String, dynamic> c(String name, String proto, String host) => {
        'container': name,
        proto: {
          'last_config': jsonEncode({'config': _conf(host)}),
        },
      };
  final json = jsonEncode({
    'description': 'Prof',
    'defaultContainer': 'amnezia-awg',
    'containers': [
      c('amnezia-wireguard', 'wireguard', 'wg.example.com'),
      c('amnezia-awg', 'awg', 'awg.example.com'),
    ],
  });
  return 'vpn://${base64Url.encode(utf8.encode(json)).replaceAll('=', '')}';
}

void main() {
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  test('строка vpn:// в списке — все контейнеры, origin .conf', () {
    final body = 'vless://11111111-1111-1111-1111-111111111111@a.example.com:443'
        '?security=tls&sni=a.example.com#a\n${_profile()}\n';
    final nodes = parseAll(decode(body));
    final wg = nodes.whereType<WireguardSpec>().toList();
    expect(wg.map((n) => n.server),
        ['wg.example.com', 'awg.example.com']);
    for (final n in wg) {
      expect(n.rawSource.trimLeft(), startsWith('[Interface]'));
    }
    // Контейнер по умолчанию — имя профиля (как прежний одиночный узел).
    expect(wg[1].label, 'Prof');
    expect(wg[0].label, 'Prof amnezia-wireguard');
  });
}
