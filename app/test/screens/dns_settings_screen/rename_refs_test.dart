import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/screens/dns_settings_screen/dns_server_resolver.dart';

/// §117 задача 4b — rename тега DNS-сервера: каскад по всем ссылкам
/// (`renameDnsServerTagRefs` + `renameRuleDnsServerTag`), чтобы
/// переименование не орфанило рефы.
void main() {
  group('renameDnsServerTagRefs', () {
    test('каскад: domain_resolver, dns_servers-vars, §061-правила, resolvers',
        () {
      final servers = <Map<String, dynamic>>[
        {
          'enabled': true,
          'kind': 'inline',
          'tag': 'my-doh',
          'body': {
            'type': 'https',
            'server': 'dns.example.com',
            'domain_resolver': 'my-dns',
          },
        },
        {
          'enabled': true,
          'kind': 'template',
          'tag': 'safe_dns_dot',
          'varValues': {
            'dom_resolver': 'my-dns',
            'safe_profile': 'my-dns', // enum — совпадение текста, не трогаем
          },
        },
      ];
      final rules = <Map<String, dynamic>>[
        {
          'enabled': true,
          'kind': 'inline',
          'name': 'r1',
          'rule': {'domain': ['x.com'], 'server': 'my-dns'},
        },
        {
          'enabled': true,
          'kind': 'srs',
          'id': 'ds_1',
          'name': 'cn',
          'server': 'my-dns',
        },
        {'enabled': true, 'kind': 'preset', 'presetId': 'p'},
      ];
      final templateByTag = <String, Map<String, dynamic>>{
        'safe_dns_dot': {
          'vars': [
            {'name': 'dom_resolver', 'type': 'dns_servers'},
            {'name': 'safe_profile', 'type': 'enum'},
          ],
          'server': {'tag': 'safe_dns_dot'},
        },
      };

      final updated = renameDnsServerTagRefs(
        servers: servers,
        rules: rules,
        templateByTag: templateByTag,
        oldTag: 'my-dns',
        newTag: 'home-router',
        dnsFinal: 'my-dns',
        defaultResolver: 'google_udp',
      );

      expect(servers[0]['body']['domain_resolver'], 'home-router');
      expect(servers[1]['varValues']['dom_resolver'], 'home-router');
      expect(servers[1]['varValues']['safe_profile'], 'my-dns',
          reason: 'enum-var с совпавшим текстом не трогается');
      expect(rules[0]['rule']['server'], 'home-router');
      expect(rules[1]['server'], 'home-router');
      expect(updated.dnsFinal, 'home-router');
      expect(updated.defaultResolver, 'google_udp');
    });

    test('нет ссылок → ничего не меняется', () {
      final servers = <Map<String, dynamic>>[
        {
          'enabled': true,
          'kind': 'inline',
          'tag': 'other',
          'body': {'type': 'udp', 'server': '192.168.1.1'},
        },
      ];
      final rules = <Map<String, dynamic>>[];
      final updated = renameDnsServerTagRefs(
        servers: servers,
        rules: rules,
        templateByTag: const {},
        oldTag: 'my-dns',
        newTag: 'x',
        dnsFinal: 'google_udp',
        defaultResolver: 'cloudflare_udp',
      );
      expect(servers[0]['body'], {'type': 'udp', 'server': '192.168.1.1'});
      expect(updated.dnsFinal, 'google_udp');
      expect(updated.defaultResolver, 'cloudflare_udp');
    });
  });

  group('renameRuleDnsServerTag', () {
    test('dns.serverTag правил обновляется; без ссылок — identical', () {
      final rules = <CustomRule>[
        CustomRuleInline(
          name: 'tg',
          domains: ['t.me'],
          outbound: 'vpn-1',
          dns: const RuleDns(enabled: true, serverTag: 'my-dns'),
        ),
        CustomRuleSrs(
          name: 'cn',
          srsUrl: 'https://e/x.srs',
          dns: const RuleDns(enabled: false, serverTag: 'my-dns'),
        ),
        CustomRuleInline(name: 'plain', domains: ['a.com']),
      ];

      final renamed = renameRuleDnsServerTag(rules, 'my-dns', 'home-router');
      expect(identical(renamed, rules), false);
      expect(renamed[0].dns!.serverTag, 'home-router');
      expect(renamed[1].dns!.serverTag, 'home-router',
          reason: 'выключенная галка тоже несёт выбор — каскадим');
      expect(renamed[2].dns, null);

      final noop = renameRuleDnsServerTag(renamed, 'ghost', 'x');
      expect(identical(noop, renamed), true,
          reason: 'без ссылок caller может не персистить');
    });
  });
}
