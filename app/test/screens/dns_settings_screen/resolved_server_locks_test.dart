import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/screens/dns_settings_screen/dns_server_delete.dart';
import 'package:lxbox/screens/dns_settings_screen/dns_server_resolver.dart';
import 'package:lxbox/screens/dns_settings_screen/resolved_server.dart';

/// §680 — локи «used by» по ссылкам из самого списка: член группы,
/// DNS Final, Default Domain Resolver, `domain_resolver` другого сервера.
void main() {
  Map<String, dynamic> wrap(String desc, Map<String, dynamic> server,
          {bool enabled = true, List<Map<String, dynamic>>? vars}) =>
      {
        'description': desc,
        'enabled': enabled,
        'vars': ?vars,
        'server': server,
      };

  final templateByTag = <String, Map<String, dynamic>>{
    'google_udp': wrap('Google DNS (direct)',
        {'type': 'udp', 'tag': 'google_udp', 'server': '8.8.8.8'}),
    'google_doh': wrap('Google DoH',
        {'type': 'https', 'tag': 'google_doh', 'server': '8.8.8.8'}),
    'opendns_udp': wrap('OpenDNS UDP (direct)',
        {'type': 'udp', 'tag': 'opendns_udp', 'server': '208.67.222.222'}),
    'safe_dns_dot': wrap(
      'Safe DNS (DoT)',
      {
        'type': 'tls',
        'tag': 'safe_dns_dot',
        'server': '9.9.9.9',
        'domain_resolver': '@dom_resolver',
      },
      enabled: false,
      vars: [
        {
          'name': 'dom_resolver',
          'type': 'dns_servers',
          'default_value': 'google_udp',
        },
      ],
    ),
    'dns_shield': wrap('Shield DNS', {
      'type': 'group',
      'tag': 'dns_shield',
      'mode': 'fastest',
      'servers': ['google_doh', 'opendns_udp'],
    }),
  };

  DnsServerTemplate t(String tag, {bool enabled = true}) =>
      DnsServerTemplate(enabled: enabled, tag: tag);

  ResolvedServer find(List<ResolvedServer> list, String tag) =>
      list.firstWhere((s) => s.tag == tag);

  List<ResolvedServer> resolve(
    List<DnsServerRef> servers, {
    String dnsFinal = '',
    String defaultResolver = '',
    Map<String, String> ruleRefsByTag = const {},
  }) =>
      resolveDisplayedServers(servers, templateByTag, const {},
          ruleRefsByTag: ruleRefsByTag,
          dnsFinal: dnsFinal,
          defaultResolver: defaultResolver);

  test('член группы залочен описанием группы; вне группы — свободен', () {
    final list = resolve([
      t('google_udp'),
      t('google_doh'),
      t('opendns_udp'),
      t('dns_shield'),
    ]);
    final doh = find(list, 'google_doh');
    expect(doh.locked, isTrue);
    expect(doh.forceIncluded, isFalse);
    expect(doh.lockedByLabel, 'Shield DNS');
    expect(canDeleteDnsServer(doh), isFalse);
    final udp = find(list, 'google_udp');
    expect(udp.locked, isFalse);
    expect(canDeleteDnsServer(udp), isTrue);
  });

  test('группы нет в списке — члены свободны', () {
    final list = resolve([t('google_doh'), t('opendns_udp')]);
    expect(find(list, 'google_doh').locked, isFalse);
    expect(find(list, 'opendns_udp').locked, isFalse);
  });

  test('DNS Final и Default Domain Resolver — две метки через запятую', () {
    final list = resolve([t('google_doh'), t('dns_shield')],
        dnsFinal: 'dns_shield', defaultResolver: 'dns_shield');
    final shield = find(list, 'dns_shield');
    expect(shield.locked, isTrue);
    expect(shield.lockedByLabel, 'DNS Final, Default Domain Resolver');
  });

  test('domain_resolver шаблонного сервера (var dom_resolver) держит цель',
      () {
    final list = resolve([t('google_udp'), t('safe_dns_dot')]);
    final udp = find(list, 'google_udp');
    expect(udp.locked, isTrue);
    expect(udp.lockedByLabel, 'Safe DNS (DoT)');
    // safe_dns_dot удалён → google_udp свободен.
    expect(find(resolve([t('google_udp')]), 'google_udp').locked, isFalse);
  });

  // §695 — выключенная запись никого не держит.
  test('выключенный safe_dns_dot не держит google_udp', () {
    final list = resolve([t('google_udp'), t('safe_dns_dot', enabled: false)]);
    final udp = find(list, 'google_udp');
    expect(udp.locked, isFalse);
    expect(canDeleteDnsServer(udp), isTrue);
  });

  test('выключенная группа без пикеров не держит членов', () {
    final list = resolve([
      t('google_doh'),
      t('opendns_udp'),
      t('dns_shield', enabled: false),
    ]);
    for (final tag in ['google_doh', 'opendns_udp']) {
      expect(find(list, tag).locked, isFalse, reason: tag);
      expect(canDeleteDnsServer(find(list, tag)), isTrue, reason: tag);
    }
  });

  // §696 — группа под пикером forced: сборка эмитит её и членов всегда.
  test('выключенная группа под пикерами: forced, держит всех членов, члены '
      'тоже forced', () {
    final list = resolve(
      [
        t('google_doh', enabled: false),
        t('opendns_udp'),
        t('google_udp'),
        t('dns_shield', enabled: false),
      ],
      dnsFinal: 'dns_shield',
      defaultResolver: 'dns_shield',
    );
    final shield = find(list, 'dns_shield');
    expect(shield.forceIncluded, isTrue);
    expect(shield.usedByResolver, isTrue);
    expect(shield.lockedByLabel, 'DNS Final, Default Domain Resolver');
    for (final tag in ['google_doh', 'opendns_udp']) {
      final m = find(list, tag);
      expect(m.forceIncluded, isTrue, reason: tag);
      expect(m.locked, isTrue, reason: tag);
      expect(m.lockedByLabel, 'Shield DNS', reason: tag);
      expect(canDeleteDnsServer(m), isFalse, reason: tag);
    }
    // Вне группы — не forced и свободен.
    expect(find(list, 'google_udp').forceIncluded, isFalse);
    expect(find(list, 'google_udp').locked, isFalse);
    expect(shield.groupLiveMembers, 2);
  });

  test('пикеры переставлены — выключенная группа и члены свободны', () {
    final list = resolve(
      [
        t('google_doh', enabled: false),
        t('opendns_udp'),
        t('google_udp'),
        t('dns_shield', enabled: false),
      ],
      dnsFinal: 'google_udp',
      defaultResolver: 'google_udp',
    );
    expect(find(list, 'dns_shield').locked, isFalse);
    expect(find(list, 'google_doh').locked, isFalse);
    expect(find(list, 'opendns_udp').locked, isFalse);
    expect(find(list, 'google_udp').usedByResolver, isTrue);
  });

  test('выключенный член с DNS-опцией правила считается живым', () {
    final list = resolve(
      [
        t('google_doh'),
        t('opendns_udp', enabled: false),
        t('dns_shield', enabled: false),
      ],
      ruleRefsByTag: const {'opendns_udp': 'My rule'},
    );
    expect(find(list, 'google_doh').locked, isFalse);
    expect(find(list, 'dns_shield').groupLiveMembers, 2);
  });

  test('включённая группа держит членов, в т.ч. выключенных', () {
    final list = resolve([
      t('google_doh', enabled: false),
      t('opendns_udp'),
      t('dns_shield'),
    ]);
    expect(find(list, 'google_doh').lockedByLabel, 'Shield DNS');
    expect(find(list, 'opendns_udp').lockedByLabel, 'Shield DNS');
  });

  test('счётчики членов группы — по списку', () {
    final list = resolve([
      t('google_doh', enabled: false),
      t('dns_shield', enabled: false),
    ]);
    final shield = find(list, 'dns_shield');
    expect(shield.groupMembersInList, 1);
    expect(shield.groupLiveMembers, 0);
    expect(shield.enableBlockedEmptyGroup, isTrue);
    // Член включён — группу включить можно.
    final ok = find(
        resolve([t('google_doh'), t('dns_shield', enabled: false)]),
        'dns_shield');
    expect(ok.groupLiveMembers, 1);
    expect(ok.enableBlockedEmptyGroup, isFalse);
    // Включённую пустую группу выключить можно.
    expect(find(resolve([t('dns_shield')]), 'dns_shield')
        .enableBlockedEmptyGroup, isFalse);
  });

  test('висячий domain_resolver: цели нет в списке', () {
    final list = resolve([t('google_doh'), t('safe_dns_dot')]);
    expect(find(list, 'safe_dns_dot').danglingResolver, 'google_udp');
    expect(find(list, 'google_doh').danglingResolver, isEmpty);
    final ok = resolve([t('google_udp'), t('safe_dns_dot')]);
    expect(find(ok, 'safe_dns_dot').danglingResolver, isEmpty);
    // inline `{server}` — так же.
    final inline = resolve([
      const DnsServerInline(
        enabled: true,
        tag: 'my-dot',
        body: {
          'type': 'tls',
          'server': 'dot.example',
          'domain_resolver': {'server': 'gone'},
        },
      ),
    ]);
    expect(inline.single.danglingResolver, 'gone');
  });

  test('inline domain_resolver (строка и {server}) держит цель', () {
    final list = resolve([
      t('google_udp'),
      t('opendns_udp'),
      const DnsServerInline(
        enabled: true,
        tag: 'my-doh',
        body: {
          'type': 'https',
          'server': 'dns.example',
          'domain_resolver': 'google_udp',
        },
      ),
      const DnsServerInline(
        enabled: true,
        tag: 'my-dot',
        description: 'My DoT',
        body: {
          'type': 'tls',
          'server': 'dot.example',
          'domain_resolver': {'server': 'opendns_udp'},
        },
      ),
    ]);
    expect(find(list, 'google_udp').lockedByLabel, 'my-doh');
    expect(find(list, 'opendns_udp').lockedByLabel, 'My DoT');
  });

  test('больше двух источников — первые два и «+N»', () {
    final list = resolve(
      [t('google_doh'), t('opendns_udp'), t('dns_shield')],
      dnsFinal: 'google_doh',
      defaultResolver: 'google_doh',
      ruleRefsByTag: const {'google_doh': 'My rule'},
    );
    final doh = find(list, 'google_doh');
    expect(doh.lockedBySources,
        ['My rule', 'Shield DNS', 'DNS Final', 'Default Domain Resolver']);
    expect(doh.lockedByLabel, 'My rule, Shield DNS +2');
    // Правило — force-include сборки; лок списка — нет.
    expect(doh.forceIncluded, isTrue);
  });

  test('удаление: template без ссылок — да, preset — нет', () {
    final list = resolve([t('opendns_udp')]);
    expect(canDeleteDnsServer(find(list, 'opendns_udp')), isTrue);
    final preset = resolveDisplayedServers(
      const [DnsServerPreset(enabled: true, tag: 'ru:yandex')],
      templateByTag,
      const {
        'ru:yandex': {'type': 'udp', 'tag': 'ru:yandex', 'server': '77.88.8.8'},
      },
    );
    expect(canDeleteDnsServer(preset.single), isFalse);
  });

  test('enabledServerTags: выключенный, залоченный только списком, — вне '
      'пикеров (сборка его не форсирует)', () {
    final list = resolve([
      t('google_doh', enabled: false),
      t('opendns_udp'),
      t('dns_shield'),
    ]);
    expect(find(list, 'google_doh').locked, isTrue);
    expect(enabledServerTags(list), ['opendns_udp', 'dns_shield']);
  });
}
