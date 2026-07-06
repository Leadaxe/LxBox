import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/builder/post_steps.dart';

/// §247 — healDanglingResolveServers: битая `server`-ссылка resolve-правила
/// деградирует (server снимается → DNS-роутинг), а не валит каждое
/// сматчившееся соединение лениво («DNS server not found» в ядре).
void main() {
  Map<String, dynamic> cfg({
    List<Map<String, dynamic>> servers = const [],
    List<Map<String, dynamic>> rules = const [],
  }) =>
      {
        'dns': {'servers': servers},
        'route': {'rules': rules},
      };

  test('resolve со ссылкой на живой сервер — не трогаем', () {
    final config = cfg(
      servers: [
        {'tag': 'yandex_udp', 'type': 'udp', 'server': '77.88.8.8'},
      ],
      rules: [
        {
          'rule_set': ['ru-domains'],
          'action': 'resolve',
          'server': 'yandex_udp',
          'strategy': 'ipv4_only',
        },
      ],
    );
    final removed = healDanglingResolveServers(config);
    expect(removed, isEmpty);
    expect(
        (config['route']['rules'] as List).first['server'], 'yandex_udp');
  });

  test('resolve со ссылкой на отсутствующий сервер → server снят + запись',
      () {
    // Сценарий ru-direct: DNS-аспект выключен → yandex_udp не в dns.servers,
    // а route-аспект всё равно эмитит resolve с server.
    final config = cfg(
      servers: [
        {'tag': 'google_udp', 'type': 'udp', 'server': '8.8.8.8'},
      ],
      rules: [
        {
          'rule_set': ['ru-domains', 'ru-services'],
          'action': 'resolve',
          'server': 'yandex_udp',
          'strategy': 'ipv4_only',
        },
        {
          'rule_set': ['ru-domains', 'ru-services'],
          'outbound': 'direct-out',
        },
      ],
    );
    final removed = healDanglingResolveServers(config);
    expect(removed, hasLength(1));
    expect(removed.single.target, 'yandex_udp');
    final healed = (config['route']['rules'] as List).first as Map;
    expect(healed.containsKey('server'), isFalse,
        reason: 'битая ссылка снята — резолв через DNS-роутинг');
    expect(healed['action'], 'resolve');
    expect(healed['strategy'], 'ipv4_only',
        reason: 'остальные resolve-опции не трогаем');
  });

  test('не-resolve правила и server-поля вне resolve не трогаются', () {
    final config = cfg(
      rules: [
        {'rule_set': ['x'], 'outbound': 'vpn-1'},
        {'protocol': 'dns', 'action': 'hijack-dns'},
      ],
    );
    expect(healDanglingResolveServers(config), isEmpty);
  });

  test('resolve без server / пустой server — не трогаем', () {
    final config = cfg(
      rules: [
        {'rule_set': ['x'], 'action': 'resolve', 'strategy': 'ipv4_only'},
        {'rule_set': ['y'], 'action': 'resolve', 'server': ''},
      ],
    );
    expect(healDanglingResolveServers(config), isEmpty);
  });

  test('пустой/отсутствующий dns.servers → все resolve-server сняты', () {
    final config = {
      'route': {
        'rules': [
          {'rule_set': ['x'], 'action': 'resolve', 'server': 'gone'},
        ],
      },
    };
    final removed = healDanglingResolveServers(config);
    expect(removed, hasLength(1));
    expect(removed.single.target, 'gone');
  });
}
