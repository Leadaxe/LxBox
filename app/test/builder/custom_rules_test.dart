import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/codec/rule_record.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';
import 'package:lxbox/services/storage_migration/legacy_form_v0.dart';

/// §757 — srsPaths ключуются id кэша набора по ссылке.
Map<String, String> _paths(String id, Map<String, String> byUrl) => {
      for (final e in byUrl.entries)
        CustomRuleTree.cacheIdFor(id, e.key): e.value,
    };

/// Правило через запись хранения и обратно — путь `SettingsStorage`.
CustomRule _storageRoundTrip(CustomRule r) =>
    ruleFromRecord(ruleToRecord(r), unknownAsVerbatim: true).value!;

void main() {
  group('applyCustomRules — inline', () {
    test('domain only → inline rule_set + outbound route', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          id: 'id-1',
          name: 'Pin Yandex',
          domains: ['ya.ru', 'yandex.ru'],
          outbound: 'direct-out',
        ),
      ]);
      final sets = reg.getRuleSets();
      expect(sets, hasLength(1));
      expect(sets.first['tag'], 'Pin Yandex');
      expect(sets.first['type'], 'inline');
      expect(sets.first['rules'], [
        {
          'domain': ['ya.ru', 'yandex.ru'],
        },
      ]);
      expect(reg.getRules(), [
        {'rule_set': 'Pin Yandex', 'outbound': 'direct-out'},
      ]);
    });

    test('domain_suffix-only rule emits domain_suffix field', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'RU',
          domainSuffixes: ['ru', 'xn--p1ai'],
          outbound: 'vpn-1',
        ),
      ]);
      expect(reg.getRuleSets().first['rules'].first,
          {'domain_suffix': ['ru', 'xn--p1ai']});
    });

    test('ip_cidr rule emits ip_cidr field', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Home LAN',
          ipCidrs: ['10.0.0.0/8', '192.168.0.0/16'],
          outbound: 'direct-out',
        ),
      ]);
      expect(reg.getRuleSets().first['rules'].first,
          {'ip_cidr': ['10.0.0.0/8', '192.168.0.0/16']});
    });

    test('domain + suffix + ip в одном правиле → все в одном headless rule', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Mixed',
          domains: ['foo.com'],
          domainSuffixes: ['bar.com'],
          ipCidrs: ['10.0.0.0/8'],
          outbound: 'direct-out',
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      expect(match, {
        'domain': ['foo.com'],
        'domain_suffix': ['bar.com'],
        'ip_cidr': ['10.0.0.0/8'],
      });
    });

    test('§755: ports → int list, port_range → string list, на маршрутном правиле', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'HTTPS+range',
          domainSuffixes: ['example.com'],
          ports: ['443', '8443'],
          portRanges: ['8000:9000', ':3000'],
          outbound: 'vpn-1',
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      expect(match.containsKey('port'), isFalse, reason: 'набор без портов');
      expect(match.containsKey('port_range'), isFalse);
      final route = reg.getRules().single;
      expect(route['rule_set'], 'HTTPS+range');
      expect(route['port'], [443, 8443]);
      expect(route['port_range'], ['8000:9000', ':3000']);
    });

    // §757 — приложения уходят из inline-набора на маршрутное правило.
    test('packages → package_name на маршрутном правиле, домены — в наборе', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Firefox RU',
          domainSuffixes: ['.ru'],
          packages: ['org.mozilla.firefox'],
          outbound: 'direct-out',
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      expect(match, {'domain_suffix': ['.ru']});
      final rule = reg.getRules().first;
      expect(rule['rule_set'], 'Firefox RU');
      expect(rule['package_name'], ['org.mozilla.firefox']);
    });

    test('packages-only rule → маршрутное правило с package_name (§757)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Block bad app',
          packages: ['com.evil.app'],
          outbound: kOutboundReject,
        ),
      ]);
      // §757 — без ключей `set: true` набора нет; приложение — на правиле.
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules().single,
          {'package_name': ['com.evil.app'], 'action': 'reject'});
    });

    test('protocols идут на routing-rule level (headless не поддерживает)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'TLS quic',
          domainSuffixes: ['example.com'],
          protocols: ['tls', 'quic'],
          outbound: 'vpn-1',
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      expect(match.containsKey('protocol'), isFalse);
      final rule = reg.getRules().first;
      expect(rule['protocol'], ['tls', 'quic']);
      expect(rule['rule_set'], 'TLS quic');
      expect(rule['outbound'], 'vpn-1');
    });

    test('§240 network идёт на routing-rule level, AND с protocol', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'UDP quic',
          domainSuffixes: ['example.com'],
          network: ['udp'],
          protocols: ['quic'],
          outbound: 'vpn-1',
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      // network/protocol — routing-rule level, не в headless match.
      expect(match.containsKey('network'), isFalse);
      final rule = reg.getRules().first;
      expect(rule['network'], ['udp']);
      expect(rule['protocol'], ['quic']);
      expect(rule['rule_set'], 'UDP quic');
    });

    test('§240 network-only (match пуст) → routing rule без rule_set', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'All ICMP',
          network: ['icmp'],
          outbound: 'direct-out',
        ),
      ]);
      expect(reg.getRuleSets(), isEmpty);
      final rule = reg.getRules().single;
      expect(rule['network'], ['icmp']);
      expect(rule.containsKey('rule_set'), isFalse);
      expect(rule['outbound'], 'direct-out');
    });

    test('§240 пустой network не эмитит ключ', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Plain',
          domainSuffixes: ['example.com'],
          outbound: 'vpn-1',
        ),
      ]);
      final rule = reg.getRules().first;
      expect(rule.containsKey('network'), isFalse);
    });

    test('reject + protocol → action:reject со сохранением protocol', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Block BT',
          domainSuffixes: ['.torrent'],
          protocols: ['bittorrent'],
          outbound: kOutboundReject,
        ),
      ]);
      final rule = reg.getRules().first;
      expect(rule['action'], 'reject');
      expect(rule.containsKey('outbound'), isFalse);
      expect(rule['protocol'], ['bittorrent']);
    });

    test('disabled → skipped', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Never',
          enabled: false,
          domains: ['example.com'],
          outbound: 'direct-out',
        ),
      ]);
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), isEmpty);
    });

    test('no match fields → skipped', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(name: 'Empty inline', outbound: 'vpn-1'),
      ]);
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), isEmpty);
    });

    test('invalid port strings → отбрасываются на intPorts getter', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Bad ports',
          ports: ['443', 'abc', '99999', '80'],
          outbound: 'vpn-1',
        ),
      ]);
      expect(reg.getRuleSets(), isEmpty, reason: '§755: только порты — без набора');
      expect(reg.getRules().single['port'], [443, 80]);
    });

    test('collision с существующим tag'
        ' → авто-суффикс через registry', () {
      final reg = RuleSetRegistry(
        initialRuleSets: [
          {'tag': 'Block', 'type': 'remote'},
        ],
      );
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Block',
          domainSuffixes: ['x.com'],
          outbound: kOutboundReject,
        ),
      ]);
      expect(reg.getRuleSets().map((s) => s['tag']).toList(),
          ['Block', 'Block (2)']);
      expect(reg.getRules().first['rule_set'], 'Block (2)');
    });
  });

  group('applyCustomRules — srs (local-file mode)', () {
    test('srs с cached path → local rule_set + routing rule', () {
      final reg = RuleSetRegistry();
      final rule = CustomRuleTree.flat(
        id: 'rule-1',
        name: 'GeoIP CN',
        srsUrl: 'https://example.com/geoip-cn.srs',
        outbound: 'direct-out',
      );
      // §757 — ключ srsPaths — id кэша набора по ссылке.
      final warn = applyCustomRules(reg, [rule], srsPaths: {
        CustomRuleTree.cacheIdFor('rule-1', rule.srsUrl):
            '/cache/rule_sets/rule-1.srs',
      });
      expect(warn, isEmpty);
      final set = reg.getRuleSets().single;
      expect(set['type'], 'local');
      expect(set['tag'], 'GeoIP CN:geoip-cn');
      expect(set['format'], 'binary');
      expect(set['path'], '/cache/rule_sets/rule-1.srs');
      expect(set.containsKey('url'), isFalse);
      expect(set.containsKey('update_interval'), isFalse);
      expect(reg.getRules().single,
          {'rule_set': 'GeoIP CN:geoip-cn', 'outbound': 'direct-out'});
    });

    test('srs без cached path → skip + warning', () {
      final reg = RuleSetRegistry();
      final rule = CustomRuleTree.flat(
        id: 'r2',
        name: 'Not yet downloaded',
        srsUrl: 'https://example.com/foo.srs',
        outbound: 'vpn-1',
      );
      final warn = applyCustomRules(reg, [rule]);
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), isEmpty);
      expect(warn, hasLength(1));
      expect(warn.first, contains('Not yet downloaded'));
    });

    test('srs + ports + packages + protocol → AND на routing rule level', () {
      final reg = RuleSetRegistry();
      final rule = CustomRuleTree.flat(
        id: 'r3',
        name: 'SRS filtered',
        srsUrl: 'https://example.com/rules.srs',
        ports: ['443'],
        portRanges: ['8000:9000'],
        packages: ['org.mozilla.firefox'],
        protocols: ['tls'],
        outbound: 'vpn-1',
      );
      applyCustomRules(reg, [rule], srsPaths: {
        CustomRuleTree.cacheIdFor('r3', rule.srsUrl): '/cache/rule_sets/r3.srs',
      });
      final r = reg.getRules().single;
      expect(r['rule_set'], 'SRS filtered:rules');
      expect(r['port'], [443]);
      expect(r['port_range'], ['8000:9000']);
      expect(r['package_name'], ['org.mozilla.firefox']);
      expect(r['protocol'], ['tls']);
      expect(r['outbound'], 'vpn-1');
    });
  });

  // §439 — хранение правил: запись `rules[]` кодеком (путь `SettingsStorage`
  // читает с `unknownAsVerbatim`).
  group('CustomRule: запись rules[] round-trip', () {
    test('inline со всеми полями', () {
      final src = CustomRuleTree.flat(
        id: 'id-x',
        name: 'Mixed',
        domains: ['a.com'],
        domainSuffixes: ['b.com'],
        ports: ['443'],
        portRanges: ['8000:9000'],
        protocols: ['tls'],
        network: ['tcp', 'udp'],
        outbound: kOutboundReject,
      );
      final back = _storageRoundTrip(src);
      expect(back, isA<CustomRuleTree>());
      final inline = back as CustomRuleTree;
      expect(inline.id, 'id-x');
      expect(inline.name, 'Mixed');
      expect(inline.domains, ['a.com']);
      expect(inline.domainSuffixes, ['b.com']);
      expect(inline.ports, ['443']);
      expect(inline.portRanges, ['8000:9000']);
      expect(inline.protocols, ['tls']);
      expect(inline.network, ['tcp', 'udp']);
      expect(inline.outbound, kOutboundReject);
    });

    test('srs kind preserved', () {
      final src = CustomRuleTree.flat(
        name: 'Remote',
        srsUrl: 'https://example.com/rules.srs',
        outbound: 'vpn-1',
      );
      final back = _storageRoundTrip(src);
      expect(back, isA<CustomRuleTree>());
      final srs = back as CustomRuleTree;
      expect(srs.srsUrl, 'https://example.com/rules.srs');
    });

    test('форма 2.23.2: legacy target field → outbound', () {
      final back = readLegacyCustomRule({
        'id': 'legacy-1',
        'name': 'Legacy',
        'enabled': true,
        'kind': 'inline',
        'domains': ['foo.com'],
        'target': 'vpn-1',
      });
      expect(back, isA<CustomRuleTree>());
      expect((back as CustomRuleTree).outbound, 'vpn-1');
    });
  });

  // §051 / §030 new_fields — wifi_ssid / wifi_bssid.
  //
  // ⚠ С sing-box 1.14 wifi_* эмитятся в **headless rule_set** (раньше под 1.12
  // были на routing-rule level). Эти тесты обновлены под 1.14-форму.
  group('§051 wifi conditions (1.14: headless)', () {
    test('inline wifi-only → wifi_ssid на маршрутном правиле (§757)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Home wifi → direct',
          wifiSsids: ['lexRouter'],
          outbound: 'direct-out',
        ),
      ]);
      // §757 — Wi-Fi не ключ набора: набора нет, условие на маршрутном
      // правиле.
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), [
        {
          'wifi_ssid': ['lexRouter'],
          'outbound': 'direct-out',
        },
      ]);
    });

    test('inline wifi_ssid + wifi_bssid вместе на правиле (§757)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Home',
          wifiSsids: ['lexRouter'],
          wifiBssids: ['38:2c:4a:cf:6d:5c'],
          outbound: 'direct-out',
        ),
      ]);
      // §757 — оба Wi-Fi-условия вместе на маршрутном правиле.
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), [
        {
          'wifi_ssid': ['lexRouter'],
          'wifi_bssid': ['38:2c:4a:cf:6d:5c'],
          'outbound': 'direct-out',
        },
      ]);
    });

    test('inline domain + wifi: домен в наборе, wifi на правиле, AND', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Banking on home wifi',
          domains: ['bank.com'],
          wifiSsids: ['lexRouter'],
          outbound: 'direct-out',
        ),
      ]);
      // §757 — домен в наборе, Wi-Fi на правиле: (набор) AND (wifi).
      expect(reg.getRuleSets(), hasLength(1));
      expect(reg.getRuleSets().first['rules'], [
        {
          'domain': ['bank.com'],
        },
      ]);
      expect(reg.getRules(), [
        {
          'rule_set': 'Banking on home wifi',
          'wifi_ssid': ['lexRouter'],
          'outbound': 'direct-out',
        },
      ]);
    });

    test('srs + wifi: rule_set + wifi_ssid в одном правиле', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'GeoSite RU on home',
          srsUrl: 'https://example.com/geo.srs',
          wifiSsids: ['lexRouter'],
          outbound: 'direct-out',
        ),
      ], srsPaths: {
        // CustomRuleTree needs cached path, иначе skipped с warning.
        // Pass id-key = generated id; используем factory-call id для этого
        // не получится (UUID каждый запуск разный). Создадим с id явно:
      });
    });

    test('srs + wifi с явным id и path', () {
      final reg = RuleSetRegistry();
      final srs = CustomRuleTree.flat(
        id: 'srs-1',
        name: 'GeoSite RU on home',
        srsUrl: 'https://example.com/geo.srs',
        wifiSsids: ['lexRouter'],
        outbound: 'direct-out',
      );
      applyCustomRules(reg, [srs],
          srsPaths: _paths('srs-1', {srs.srsUrl: '/cache/geo.srs'}));
      expect(reg.getRuleSets(), hasLength(1));
      expect(reg.getRules(), [
        {
          'rule_set': 'GeoSite RU on home:geo',
          'wifi_ssid': ['lexRouter'],
          'outbound': 'direct-out',
        },
      ]);
    });

    // ## 12 контракта (D-100) — несколько наборов в одном правиле.
    group('## 12 srs с несколькими наборами', () {
      final multi = CustomRuleTree.flat(
        id: 'm',
        name: 'Multi',
        srsUrls: const [
          'https://x/a.srs',
          'https://x/b.srs',
          'https://x/c.srs',
        ],
        outbound: 'proxy',
      );

      test('rule_set на каждый набор, одно правило со списком тегов', () {
        final reg = RuleSetRegistry();
        final warn = applyCustomRules(reg, [multi], srsPaths: _paths('m', {
          'https://x/a.srs': '/cache/m.srs',
          'https://x/b.srs': '/cache/m~1.srs',
          'https://x/c.srs': '/cache/m~2.srs',
        }));
        expect(warn, isEmpty);
        // §757 (§6.13, контракт 1.1.182) — каждая ссылка `имя:<stem>`.
        final tags = ['Multi:a', 'Multi:b', 'Multi:c'];
        expect(reg.getRuleSets().map((s) => s['tag']), tags);
        expect(reg.getRuleSets().map((s) => s['path']),
            ['/cache/m.srs', '/cache/m~1.srs', '/cache/m~2.srs']);
        expect(reg.getRules(), [
          {
            'rule_set': tags,
            'outbound': 'proxy',
          },
        ]);
      });

      test('один набор — rule_set строкой, конфиг как до ## 12', () {
        final reg = RuleSetRegistry();
        applyCustomRules(
            reg,
            [
              CustomRuleTree.flat(
                  id: 's', name: 'S', srsUrl: 'https://x/a.srs', outbound: 'proxy')
            ],
            srsPaths: _paths('s', {'https://x/a.srs': '/cache/s.srs'}));
        expect(reg.getRules().single['rule_set'], 'S:a');
      });

      test('нет файла хотя бы одного набора → правило пропущено с warning', () {
        final reg = RuleSetRegistry();
        final warn = applyCustomRules(reg, [multi], srsPaths: _paths('m', {
          'https://x/a.srs': '/cache/m.srs',
          'https://x/c.srs': '/cache/m~2.srs',
        }));
        expect(warn.single, contains('Multi'));
        expect(reg.getRuleSets(), isEmpty, reason: 'частичной регистрации нет');
        expect(reg.getRules(), isEmpty);
      });

      test('resolve-опция: то же множество тегов в resolve-правиле', () {
        final reg = RuleSetRegistry();
        final r = multi.copyWith(
            resolve: const RuleResolve(only: false, strategy: 'ipv4_only'));
        applyCustomRules(reg, [r], srsPaths: _paths('m', {
          'https://x/a.srs': '/cache/m.srs',
          'https://x/b.srs': '/cache/m~1.srs',
          'https://x/c.srs': '/cache/m~2.srs',
        }));
        final rules = reg.getRules();
        expect(rules, hasLength(2));
        expect(rules.first['action'], 'resolve');
        final tags = ['Multi:a', 'Multi:b', 'Multi:c'];
        expect(rules.first['rule_set'], tags);
        expect(rules.last['rule_set'], tags);
      });
    });

    test('disabled rule не эмитит wifi-условия', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Off',
          enabled: false,
          wifiSsids: ['lexRouter'],
          outbound: 'direct-out',
        ),
      ]);
      expect(reg.getRules(), isEmpty);
    });

    test('empty wifi-списки не появляются в JSON', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'No wifi',
          domains: ['ya.ru'],
          outbound: 'direct-out',
        ),
      ]);
      final rule = reg.getRules().first;
      expect(rule.containsKey('wifi_ssid'), isFalse);
      expect(rule.containsKey('wifi_bssid'), isFalse);
    });
  });

  // §030/new_fields — source_ip_cidr / source_ip_is_private / inbound.
  group('§030 new_fields source + inbound', () {
    test('inline source_ip_cidr → маршрутное правило (§757)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'LAN clients',
          sourceIpCidrs: ['192.168.1.0/24'],
          outbound: 'direct-out',
        ),
      ]);
      // §757 — источник не ключ набора: условие на маршрутном правиле.
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), [
        {'source_ip_cidr': ['192.168.1.0/24'], 'outbound': 'direct-out'},
      ]);
    });

    test('inline domain + source_ip_cidr — набор и правило (AND, §757)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'r',
          domains: ['bank.com'],
          sourceIpCidrs: ['10.0.0.0/8'],
          outbound: 'vpn-1',
        ),
      ]);
      // §757 — домен в наборе, источник на правиле (AND).
      expect(reg.getRuleSets().first['rules'], [
        {
          'domain': ['bank.com'],
        },
      ]);
      expect(reg.getRules().single, {
        'rule_set': 'r',
        'source_ip_cidr': ['10.0.0.0/8'],
        'outbound': 'vpn-1',
      });
    });

    test('inline source_ip_is_private → routing-rule level (не headless)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'priv-src',
          sourceIpIsPrivate: true,
          outbound: 'direct-out',
        ),
      ]);
      // headless его не принимает → пустой match → нет rule_set, route-rule.
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), [
        {'source_ip_is_private': true, 'outbound': 'direct-out'},
      ]);
    });

    test('inline inbound-only → routing-rule level без rule_set', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'proxy clients',
          inbounds: ['mixed-in'],
          outbound: 'direct-out',
        ),
      ]);
      // inbound в headless нет → route-rule без rule_set (НЕ skip — гейт).
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), [
        {'inbound': ['mixed-in'], 'outbound': 'direct-out'},
      ]);
    });

    test('inline domain + inbound: rule_set + inbound на route-level', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'r',
          domains: ['ya.ru'],
          inbounds: ['tun-in', 'mixed-in'],
          outbound: 'vpn-1',
        ),
      ]);
      expect(reg.getRuleSets().first['rules'], [
        {'domain': ['ya.ru']},
      ]);
      expect(reg.getRules(), [
        {
          'rule_set': 'r',
          'inbound': ['tun-in', 'mixed-in'],
          'outbound': 'vpn-1',
        },
      ]);
    });

    test('srs: source_ip_cidr/inbound → routing-rule level (нет headless)', () {
      final reg = RuleSetRegistry();
      final srs = CustomRuleTree.flat(
        id: 'srs-1',
        name: 'GeoSite',
        srsUrl: 'https://example.com/geo.srs',
        sourceIpCidrs: ['192.168.0.0/16'],
        sourceIpIsPrivate: true,
        inbounds: ['mixed-in'],
        outbound: 'direct-out',
      );
      applyCustomRules(reg, [srs],
          srsPaths: _paths('srs-1', {srs.srsUrl: '/cache/geo.srs'}));
      expect(reg.getRules(), [
        {
          'rule_set': 'GeoSite:geo',
          'source_ip_cidr': ['192.168.0.0/16'],
          'source_ip_is_private': true,
          'inbound': ['mixed-in'],
          'outbound': 'direct-out',
        },
      ]);
    });

    test('empty source/inbound — поля не появляются в JSON', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(name: 'r', domains: ['ya.ru'], outbound: 'direct-out'),
      ]);
      final rs = reg.getRuleSets().first['rules'] as List;
      expect((rs.first as Map).containsKey('source_ip_cidr'), isFalse);
      final rule = reg.getRules().first;
      expect(rule.containsKey('source_ip_is_private'), isFalse);
      expect(rule.containsKey('inbound'), isFalse);
    });

    test('запись rules[] round-trip + форма 2.23.2 без новых ключей', () {
      final r = CustomRuleTree.flat(
        id: 'id-1',
        name: 'r',
        sourceIpCidrs: ['10.0.0.0/8'],
        sourceIpIsPrivate: true,
        inbounds: ['mixed-in'],
      );
      final body = ruleToRecord(r)['body'] as Map<String, dynamic>;
      expect(body['source_ip_cidr'], ['10.0.0.0/8']);
      expect(body['source_ip_is_private'], true);
      expect(body['inbound'], ['mixed-in']);
      final restored = _storageRoundTrip(r) as CustomRuleTree;
      expect(restored.sourceIpCidrs, ['10.0.0.0/8']);
      expect(restored.sourceIpIsPrivate, isTrue);
      expect(restored.inbounds, ['mixed-in']);

      // Старый JSON без новых ключей → пустые/false.
      final legacy = readLegacyCustomRule({
        'kind': 'inline',
        'name': 'Legacy',
        'domains': ['ya.ru'],
      }) as CustomRuleTree;
      expect(legacy.sourceIpCidrs, isEmpty);
      expect(legacy.sourceIpIsPrivate, isFalse);
      expect(legacy.inbounds, isEmpty);

      // Запись не пишет пустые.
      final emptyBody = ruleToRecord(legacy)['body'] as Map<String, dynamic>;
      expect(emptyBody.containsKey('source_ip_cidr'), isFalse);
      expect(emptyBody.containsKey('source_ip_is_private'), isFalse);
      expect(emptyBody.containsKey('inbound'), isFalse);
    });
  });

  // §051 — round-trip записи rules[] для wifi-полей.
  group('§051 wifi: запись rules[] round-trip', () {
    test('inline: запись пишет wifi_ssid/wifi_bssid, чтение восстанавливает', () {
      final r = CustomRuleTree.flat(
        id: 'id-1',
        name: 'Home',
        wifiSsids: ['lexRouter'],
        wifiBssids: ['38:2c:4a:cf:6d:5c'],
      );
      final body = ruleToRecord(r)['body'] as Map<String, dynamic>;
      expect(body['wifi_ssid'], ['lexRouter']);
      expect(body['wifi_bssid'], ['38:2c:4a:cf:6d:5c']);

      final restored = _storageRoundTrip(r) as CustomRuleTree;
      expect(restored.wifiSsids, ['lexRouter']);
      expect(restored.wifiBssids, ['38:2c:4a:cf:6d:5c']);
    });

    test('inline: empty wifi-поля не пишутся в запись', () {
      final r = CustomRuleTree.flat(name: 'No wifi', domains: ['ya.ru']);
      final body = ruleToRecord(r)['body'] as Map<String, dynamic>;
      expect(body.containsKey('wifi_ssid'), isFalse);
      expect(body.containsKey('wifi_bssid'), isFalse);
    });

    test('inline: BSSID lower-case на read-side (model tolerant)', () {
      final r = ruleFromRecord({
        'kind': 'inline',
        'name': 'X',
        'body': {
          'wifi_bssid': ['38:2C:4A:CF:6D:5C', 'AA:BB:CC:DD:EE:FF'],
        },
      }, unknownAsVerbatim: true).value! as CustomRuleTree;
      expect(r.wifiBssids, ['38:2c:4a:cf:6d:5c', 'aa:bb:cc:dd:ee:ff']);
    });

    test('inline: backward-compat — форма 2.23.2 без wifi-полей', () {
      final r = readLegacyCustomRule({
        'kind': 'inline',
        'name': 'Legacy',
        'domains': ['ya.ru'],
        'outbound': 'direct-out',
      }) as CustomRuleTree;
      expect(r.wifiSsids, isEmpty);
      expect(r.wifiBssids, isEmpty);
    });

    test('srs: round-trip сохраняет wifi-поля', () {
      final r = CustomRuleTree.flat(
        id: 'srs-1',
        name: 'GeoSite',
        srsUrl: 'https://example.com/geo.srs',
        wifiSsids: ['Office'],
        wifiBssids: ['11:22:33:44:55:66'],
      );
      final restored = _storageRoundTrip(r) as CustomRuleTree;
      expect(restored.wifiSsids, ['Office']);
      expect(restored.wifiBssids, ['11:22:33:44:55:66']);
    });
  });

  // §225 (#17) — raw-JSON правило.
  group('applyCustomRules — json', () {
    test('объект → добавляется в route.rules как есть', () {
      final reg = RuleSetRegistry();
      final warnings = applyCustomRules(reg, [
        CustomRuleJson(
          name: 'Hijack DNS',
          json: '{ "protocol": "dns", "action": "hijack-dns" }',
        ),
      ]);
      expect(warnings, isEmpty);
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), [
        {'protocol': 'dns', 'action': 'hijack-dns'},
      ]);
    });

    test('массив объектов → несколько правил, порядок сохранён', () {
      final reg = RuleSetRegistry();
      final warnings = applyCustomRules(reg, [
        CustomRuleJson(
          name: 'Two',
          json: '[{"action":"sniff"},{"protocol":"dns","action":"hijack-dns"}]',
        ),
      ]);
      expect(warnings, isEmpty);
      expect(reg.getRules(), [
        {'action': 'sniff'},
        {'protocol': 'dns', 'action': 'hijack-dns'},
      ]);
    });

    test('битый JSON → skip + warning, конфиг не падает', () {
      final reg = RuleSetRegistry();
      final warnings = applyCustomRules(reg, [
        CustomRuleJson(name: 'Broken', json: '{not json'),
      ]);
      expect(reg.getRules(), isEmpty);
      expect(warnings, hasLength(1));
      expect(warnings.first, contains('invalid JSON'));
    });

    test('пустое тело → skip + warning', () {
      final reg = RuleSetRegistry();
      final warnings =
          applyCustomRules(reg, [CustomRuleJson(name: 'Empty', json: '  ')]);
      expect(reg.getRules(), isEmpty);
      expect(warnings.single, contains('empty body'));
    });

    test('скаляр (не объект/массив) → skip + warning', () {
      final reg = RuleSetRegistry();
      final warnings =
          applyCustomRules(reg, [CustomRuleJson(name: 'Scalar', json: '42')]);
      expect(reg.getRules(), isEmpty);
      expect(warnings.single, contains('object or array'));
    });

    test('массив без объектов → skip + warning', () {
      final reg = RuleSetRegistry();
      final warnings = applyCustomRules(
          reg, [CustomRuleJson(name: 'NoObjs', json: '[1, 2, 3]')]);
      expect(reg.getRules(), isEmpty);
      expect(warnings.single, contains('no rule objects'));
    });

    test('§350: //-ключи вычищаются рекурсивно + warning', () {
      final reg = RuleSetRegistry();
      final warnings = applyCustomRules(reg, [
        CustomRuleJson(
          name: 'Commented',
          json: '{"//": "матчер youtube", "domain_suffix": ["youtube.com"], '
              '"//note": "и логика", '
              '"rules": [{"//x": "вложенный", "protocol": "dns"}], '
              '"action": "route", "outbound": "direct-out"}',
        ),
      ]);
      expect(warnings.single, contains('comment key'));
      expect(reg.getRules(), [
        {
          'domain_suffix': ['youtube.com'],
          'rules': [
            {'protocol': 'dns'},
          ],
          'action': 'route',
          'outbound': 'direct-out',
        },
      ]);
    });

    test('§350: правило целиком из комментариев → skip, не пустой объект', () {
      final reg = RuleSetRegistry();
      final warnings = applyCustomRules(reg, [
        CustomRuleJson(name: 'OnlyComment', json: '{"//": "todo"}'),
      ]);
      expect(reg.getRules(), isEmpty);
      expect(warnings, hasLength(2),
          reason: 'warning про drop + warning про skip');
      expect(warnings.last, contains('empty after dropping'));
    });

    test('§350: в массиве комментарий-элемент выпадает, соседи живут', () {
      final reg = RuleSetRegistry();
      final warnings = applyCustomRules(reg, [
        CustomRuleJson(
          name: 'Mixed',
          json: '[{"//": "только коммент"},'
              '{"action":"sniff","//c":"tail"}]',
        ),
      ]);
      expect(reg.getRules(), [
        {'action': 'sniff'},
      ]);
      expect(warnings.single, contains('comment key'));
    });

    test('disabled json-правило пропускается (skipDisabled)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleJson(
          name: 'Off',
          enabled: false,
          json: '{"action":"sniff"}',
        ),
      ]);
      expect(reg.getRules(), isEmpty);
    });

    test('round-trip записи rules[] сохраняет тело (verbatim)', () {
      final r = CustomRuleJson(
        id: 'j-1',
        name: 'RT',
        json: '{"action":"hijack-dns"}',
      );
      final record = ruleToRecord(r);
      expect(record['kind'], 'inline');
      expect(record['verbatim'], isTrue);
      expect(record['body'], {'action': 'hijack-dns'});
      final restored = _storageRoundTrip(r);
      expect(restored, isA<CustomRuleJson>());
      // Текст переформатируется, тело то же.
      expect(jsonDecode((restored as CustomRuleJson).json),
          {'action': 'hijack-dns'});
      expect(restored.kind, CustomRuleKind.json);
    });
  });

  // §247 — resolve-опция правила: route + resolve (пара правил) /
  // resolve-only (одно нетерминальное) / гейт по доменному матчу.
  group('§247 resolve action', () {
    test('inline + resolve (route mode) → ДВА правила: resolve перед route, '
        'один tag', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'RU v4',
          domainSuffixes: ['ru'],
          outbound: 'direct-out',
          resolve: const RuleResolve(strategy: 'ipv4_only'),
        ),
      ]);
      expect(reg.getRules(), [
        {'rule_set': 'RU v4', 'action': 'resolve', 'strategy': 'ipv4_only'},
        {'rule_set': 'RU v4', 'outbound': 'direct-out'},
      ]);
    });

    test('inline + resolve only → ОДНО нетерминальное правило без outbound',
        () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'RU v4',
          domainSuffixes: ['ru'],
          outbound: 'direct-out', // в модели остаётся — билдер игнорирует
          resolve: const RuleResolve(only: true, strategy: 'ipv4_only'),
        ),
      ]);
      expect(reg.getRules(), [
        {'rule_set': 'RU v4', 'action': 'resolve', 'strategy': 'ipv4_only'},
      ]);
    });

    test('inline БЕЗ доменных полей + resolve в модели → resolve НЕ эмитится '
        '(гейт resolveEligible)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'LAN',
          ipCidrs: ['10.0.0.0/8'],
          outbound: 'direct-out',
          resolve: const RuleResolve(strategy: 'ipv4_only'),
        ),
      ]);
      expect(reg.getRules(), [
        {'rule_set': 'LAN', 'outbound': 'direct-out'},
      ], reason: 'чистый ip-матч резолвить нечего — только route');
    });

    test('srs + resolve → пара с srs-tag (srs всегда eligible)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(
        reg,
        [
          CustomRuleTree.flat(
            id: 'srs-1',
            name: 'RU srs',
            srsUrl: 'https://ex.com/ru.srs',
            outbound: 'vpn-1',
            resolve: const RuleResolve(
                strategy: 'ipv4_only', serverTag: 'yandex_udp'),
          ),
        ],
        srsPaths: _paths('srs-1', {'https://ex.com/ru.srs': '/cache/ru.srs'}),
      );
      expect(reg.getRules(), [
        {
          'rule_set': 'RU srs:ru',
          'action': 'resolve',
          'strategy': 'ipv4_only',
          'server': 'yandex_udp',
        },
        {'rule_set': 'RU srs:ru', 'outbound': 'vpn-1'},
      ]);
    });

    test('reject + resolve → resolve перед {action: reject}', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Block RU',
          domainSuffixes: ['ru'],
          outbound: kOutboundReject,
          resolve: const RuleResolve(strategy: 'ipv4_only'),
        ),
      ]);
      expect(reg.getRules(), [
        {'rule_set': 'Block RU', 'action': 'resolve', 'strategy': 'ipv4_only'},
        {'rule_set': 'Block RU', 'action': 'reject'},
      ]);
    });

    test('advanced-поля: заданные эмитятся, пустые нет; routing-level '
        'AND-поля дублируются на resolve-правило', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Adv',
          domainSuffixes: ['ru'],
          protocols: ['tls'],
          outbound: 'direct-out',
          resolve: const RuleResolve(
            strategy: 'ipv4_only',
            disableCache: true,
            rewriteTtl: 60,
            timeout: '5s',
            clientSubnet: '1.2.3.0/24',
          ),
        ),
      ]);
      expect(reg.getRules().first, {
        'rule_set': 'Adv',
        'protocol': ['tls'],
        'action': 'resolve',
        'strategy': 'ipv4_only',
        'disable_cache': true,
        'rewrite_ttl': 60,
        'timeout': '5s',
        'client_subnet': '1.2.3.0/24',
      });
      expect(reg.getRules()[1], {
        'rule_set': 'Adv',
        'protocol': ['tls'],
        'outbound': 'direct-out',
      });
    });

    test('resolve без опций → голое {action: resolve} (inherit всего)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Bare',
          domainSuffixes: ['ru'],
          outbound: 'direct-out',
          resolve: const RuleResolve(),
        ),
      ]);
      expect(reg.getRules().first, {'rule_set': 'Bare', 'action': 'resolve'});
    });

    test('JSON round-trip: RuleResolve сохраняется; старые записи без '
        'resolve → null', () {
      final r = CustomRuleTree.flat(
        id: 'rt-1',
        name: 'RT',
        domainSuffixes: ['ru'],
        outbound: 'direct-out',
        resolve: const RuleResolve(
          only: true,
          strategy: 'ipv4_only',
          serverTag: 'yandex_udp',
          disableOptimisticCache: true,
          rewriteTtl: 30,
          timeout: '2s',
          clientSubnet: '10.0.0.0/8',
        ),
      );
      final restored = _storageRoundTrip(r) as CustomRuleTree;
      final rr = restored.resolve!;
      expect(rr.only, isTrue);
      expect(rr.strategy, 'ipv4_only');
      expect(rr.serverTag, 'yandex_udp');
      expect(rr.disableCache, isFalse);
      expect(rr.disableOptimisticCache, isTrue);
      expect(rr.rewriteTtl, 30);
      expect(rr.timeout, '2s');
      expect(rr.clientSubnet, '10.0.0.0/8');

      // Старая запись без resolve.
      final legacy = readLegacyCustomRule({
        'name': 'Old',
        'kind': 'inline',
        'domainSuffixes': ['ru'],
        'outbound': 'direct-out',
      });
      expect(legacy.resolve, isNull);
      expect(legacy.resolveActive, isFalse);
    });

    test('resolveEligible: inline с доменами true, чистый ip false, '
        'srs всегда true', () {
      expect(
        CustomRuleTree.flat(name: 'A', domainSuffixes: ['ru']).resolveEligible,
        isTrue,
      );
      expect(
        CustomRuleTree.flat(name: 'B', ipCidrs: ['10.0.0.0/8']).resolveEligible,
        isFalse,
      );
      // §757 — srs = правило со ссылкой в дереве (ссылка — условие).
      expect(
        CustomRuleTree.flat(name: 'C', srsUrl: 'https://x/c.srs')
            .resolveEligible,
        isTrue,
      );
    });
  });

  group('§694 network_type / network_is_expensive', () {
    test('inline: на правиле рядом с набором домена (§757)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Video on cellular',
          domains: ['video.example'],
          networkTypes: ['cellular'],
          networkIsExpensive: true,
          outbound: kOutboundReject,
        ),
      ]);
      // §757 — тип/лимитность сети на правиле, домен в наборе.
      expect(reg.getRuleSets().first['rules'], [
        {
          'domain': ['video.example'],
        },
      ]);
      expect(reg.getRules(), [
        {
          'rule_set': 'Video on cellular',
          'network_type': ['cellular'],
          'network_is_expensive': true,
          'action': 'reject',
        },
      ]);
    });

    test('inline: только тип сети — правило не пустое', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'All on cellular',
          networkTypes: ['cellular'],
          outbound: 'vpn-1',
        ),
      ]);
      // §757 — набора нет, условие на маршрутном правиле.
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules().single,
          {'network_type': ['cellular'], 'outbound': 'vpn-1'});
    });

    test('srs: на routing-rule рядом с rule_set', () {
      final reg = RuleSetRegistry();
      final srs = CustomRuleTree.flat(
        name: 'geo',
        srsUrl: 'https://e/geo.srs',
        networkTypes: ['wifi'],
        networkIsExpensive: true,
        outbound: 'direct-out',
      );
      applyCustomRules(reg, [srs],
          srsPaths: _paths(srs.id, {srs.srsUrl: '/tmp/geo.srs'}));
      expect(reg.getRules(), [
        {
          'rule_set': 'geo:geo',
          'network_type': ['wifi'],
          'network_is_expensive': true,
          'outbound': 'direct-out',
        },
      ]);
    });
  });

  // §712 — package_name_regex / domain_regex.
  group('§712 package_name_regex / domain_regex', () {
    const dnsOn = RuleDns(enabled: true, serverTag: 'google_udp');

    test('inline: domain_regex в наборе, package_name_regex на правиле (§757)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleTree.flat(
          name: 'Oplus',
          packageRegexes: [r'^com\.oplus\.'],
          domainRegexes: [r'(^|\.)example\.com$'],
          outbound: 'vpn-1',
        ),
      ]);
      // §757 — регулярка домена в наборе, регулярка пакета на правиле.
      expect(reg.getRuleSets().first['rules'], [
        {
          'domain_regex': [r'(^|\.)example\.com$'],
        },
      ]);
      expect(reg.getRules().single, {
        'rule_set': 'Oplus',
        'package_name_regex': [r'^com\.oplus\.'],
        'outbound': 'vpn-1',
      });
    });

    test('inline: только регулярка пакета — DNS-способно, зеркало по ключу (§757)',
        () {
      final rule = CustomRuleTree.flat(
        name: 'Oplus',
        packageRegexes: [r'^com\.oplus\.'],
        outbound: 'vpn-1',
        dns: dnsOn,
      );
      expect(rule.dnsLayerEligible, true);
      expect(rule.dnsMirrorActive, true);
      expect(rule.summary(), isNotEmpty);
      final reg = RuleSetRegistry();
      final result = applyAllCustomRules(reg, [rule], const []);
      // §757 — набора нет; зеркало несёт ключ приложения.
      expect(reg.getRuleSets(), isEmpty);
      expect(result.dnsMirrors.single.body,
          {'package_name_regex': [r'^com\.oplus\.']});
    });

    test('inline: domain regex делает правило resolve-способным', () {
      expect(
        CustomRuleTree.flat(name: 'r', domainRegexes: ['^a']).resolveEligible,
        true,
      );
    });

    test('srs: package_name_regex на routing-rule и в DNS-зеркале', () {
      final reg = RuleSetRegistry();
      final srs = CustomRuleTree.flat(
        name: 'geo',
        srsUrl: 'https://e/geo.srs',
        packageRegexes: [r'^com\.oplus\.'],
        outbound: 'vpn-1',
        dns: dnsOn,
      );
      final result = applyAllCustomRules(reg, [srs], const [],
          srsPaths: _paths(srs.id, {srs.srsUrl: '/tmp/geo.srs'}));
      expect(reg.getRules().single, {
        'rule_set': 'geo:geo',
        'package_name_regex': [r'^com\.oplus\.'],
        'outbound': 'vpn-1',
      });
      expect(result.dnsMirrors.single.body['package_name_regex'],
          [r'^com\.oplus\.']);
    });

    test('кодек: round-trip обоих ключей, ключи sing-box в теле записи', () {
      final src = CustomRuleTree.flat(
        id: 'id-re',
        name: 'Re',
        packageRegexes: [r'^com\.oplus\.', r'^com\.coloros\.'],
        domainRegexes: [r'\.example\.com$'],
        outbound: 'direct-out',
      );
      final rec = ruleToRecord(src);
      final body = rec['body'] as Map;
      expect(body['package_name_regex'],
          [r'^com\.oplus\.', r'^com\.coloros\.']);
      expect(body['domain_regex'], [r'\.example\.com$']);
      final back = _storageRoundTrip(src);
      expect(back, src);
      final srs = CustomRuleTree.flat(
        id: 'id-srs',
        name: 'S',
        srsUrl: 'https://e/x.srs',
        packageRegexes: ['^a'],
        outbound: 'vpn-1',
      );
      expect(_storageRoundTrip(srs), srs);
    });
  });
}
