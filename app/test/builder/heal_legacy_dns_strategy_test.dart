import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/builder/post_steps.dart';

/// §246 hotfix — healLegacyDnsStrategy: легаси `strategy` в dns.rules
/// несовместим с query_type/ip_version (ядро 1.14 отклоняет старт). Снимаем
/// strategy, если несовместимая пара есть.
void main() {
  Map<String, dynamic> cfg(List<Map<String, dynamic>> dnsRules) => {
        'dns': {'rules': dnsRules},
      };

  test('strategy + query_type в конфиге (FakeIP) → strategy снят', () {
    final config = cfg([
      {
        'rule_set': ['ru-domains'],
        'server': 'yandex_udp',
        'strategy': 'ipv4_only',
      },
      {
        'query_type': ['A', 'AAAA'],
        'server': 'fakeip',
      },
    ]);
    final healed = healLegacyDnsStrategy(config);
    expect(healed, [0]);
    final rules = config['dns']['rules'] as List;
    expect((rules[0] as Map).containsKey('strategy'), isFalse);
    expect((rules[0] as Map)['server'], 'yandex_udp',
        reason: 'остальные поля не трогаем');
  });

  test('strategy + ip_version → strategy снят', () {
    final config = cfg([
      {'rule_set': ['x'], 'strategy': 'ipv4_only'},
      {'ip_version': 4, 'server': 's'},
    ]);
    expect(healLegacyDnsStrategy(config), [0]);
  });

  test('strategy БЕЗ query_type/ip_version → не трогаем (легаси-режим ок)', () {
    final config = cfg([
      {
        'rule_set': ['ru-domains'],
        'server': 'yandex_udp',
        'strategy': 'ipv4_only',
      },
    ]);
    expect(healLegacyDnsStrategy(config), isEmpty);
    expect((config['dns']['rules'][0] as Map)['strategy'], 'ipv4_only');
  });

  test('query_type без strategy нигде → ничего не снимаем', () {
    final config = cfg([
      {
        'query_type': ['A'],
        'server': 'fakeip',
      },
    ]);
    expect(healLegacyDnsStrategy(config), isEmpty);
  });

  test('несколько strategy при query_type → снимаем со всех', () {
    final config = cfg([
      {'rule_set': ['a'], 'strategy': 'ipv4_only'},
      {'rule_set': ['b'], 'strategy': 'prefer_ipv4'},
      {'query_type': ['AAAA'], 'server': 'fakeip'},
    ]);
    expect(healLegacyDnsStrategy(config), [0, 1]);
  });

  test('нет dns / нет rules → пусто, без падения', () {
    expect(healLegacyDnsStrategy({}), isEmpty);
    expect(healLegacyDnsStrategy({'dns': {}}), isEmpty);
    expect(healLegacyDnsStrategy({'dns': {'rules': []}}), isEmpty);
  });
}
