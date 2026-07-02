import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';

void main() {
  group('applyCustomRules — inline', () {
    test('domain only → inline rule_set + outbound route', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleInline(
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
        CustomRuleInline(
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
        CustomRuleInline(
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
        CustomRuleInline(
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

    test('ports → int list, port_range → string list, в одном headless rule', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleInline(
          name: 'HTTPS+range',
          domainSuffixes: ['example.com'],
          ports: ['443', '8443'],
          portRanges: ['8000:9000', ':3000'],
          outbound: 'vpn-1',
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      expect(match['port'], [443, 8443]);
      expect(match['port_range'], ['8000:9000', ':3000']);
    });

    test('packages → package_name в inline headless rule', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleInline(
          name: 'Firefox RU',
          domainSuffixes: ['.ru'],
          packages: ['org.mozilla.firefox'],
          outbound: 'direct-out',
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      expect(match['package_name'], ['org.mozilla.firefox']);
      expect(match['domain_suffix'], ['.ru']);
      final rule = reg.getRules().first;
      expect(rule.containsKey('package_name'), isFalse);
    });

    test('packages-only rule → inline с одним package_name', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleInline(
          name: 'Block bad app',
          packages: ['com.evil.app'],
          outbound: kOutboundReject,
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      expect(match, {'package_name': ['com.evil.app']});
      final rule = reg.getRules().first;
      expect(rule['action'], 'reject');
    });

    test('protocols идут на routing-rule level (headless не поддерживает)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleInline(
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

    test('reject + protocol → action:reject со сохранением protocol', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleInline(
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
        CustomRuleInline(
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
        CustomRuleInline(name: 'Empty inline', outbound: 'vpn-1'),
      ]);
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), isEmpty);
    });

    test('invalid port strings → отбрасываются на intPorts getter', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleInline(
          name: 'Bad ports',
          ports: ['443', 'abc', '99999', '80'],
          outbound: 'vpn-1',
        ),
      ]);
      final match = reg.getRuleSets().first['rules'].first as Map;
      expect(match['port'], [443, 80]);
    });

    test('collision с существующим tag'
        ' → авто-суффикс через registry', () {
      final reg = RuleSetRegistry(
        initialRuleSets: [
          {'tag': 'Block', 'type': 'remote'},
        ],
      );
      applyCustomRules(reg, [
        CustomRuleInline(
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
      final rule = CustomRuleSrs(
        id: 'rule-1',
        name: 'GeoIP CN',
        srsUrl: 'https://example.com/geoip-cn.srs',
        outbound: 'direct-out',
      );
      final warn = applyCustomRules(reg, [rule], srsPaths: {
        'rule-1': '/cache/rule_sets/rule-1.srs',
      });
      expect(warn, isEmpty);
      final set = reg.getRuleSets().single;
      expect(set['type'], 'local');
      expect(set['tag'], 'GeoIP CN');
      expect(set['format'], 'binary');
      expect(set['path'], '/cache/rule_sets/rule-1.srs');
      expect(set.containsKey('url'), isFalse);
      expect(set.containsKey('update_interval'), isFalse);
      expect(reg.getRules().single,
          {'rule_set': 'GeoIP CN', 'outbound': 'direct-out'});
    });

    test('srs без cached path → skip + warning', () {
      final reg = RuleSetRegistry();
      final rule = CustomRuleSrs(
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
      final rule = CustomRuleSrs(
        id: 'r3',
        name: 'SRS filtered',
        srsUrl: 'https://example.com/rules.srs',
        ports: ['443'],
        portRanges: ['8000:9000'],
        packages: ['org.mozilla.firefox'],
        protocols: ['tls'],
        outbound: 'vpn-1',
      );
      applyCustomRules(reg, [rule],
          srsPaths: {'r3': '/cache/rule_sets/r3.srs'});
      final r = reg.getRules().single;
      expect(r['rule_set'], 'SRS filtered');
      expect(r['port'], [443]);
      expect(r['port_range'], ['8000:9000']);
      expect(r['package_name'], ['org.mozilla.firefox']);
      expect(r['protocol'], ['tls']);
      expect(r['outbound'], 'vpn-1');
    });
  });

  group('CustomRule JSON round-trip', () {
    test('inline со всеми полями', () {
      final src = CustomRuleInline(
        id: 'id-x',
        name: 'Mixed',
        domains: ['a.com'],
        domainSuffixes: ['b.com'],
        ports: ['443'],
        portRanges: ['8000:9000'],
        protocols: ['tls'],
        outbound: kOutboundReject,
      );
      final back = CustomRule.fromJson(src.toJson());
      expect(back, isA<CustomRuleInline>());
      final inline = back as CustomRuleInline;
      expect(inline.id, 'id-x');
      expect(inline.name, 'Mixed');
      expect(inline.domains, ['a.com']);
      expect(inline.domainSuffixes, ['b.com']);
      expect(inline.ports, ['443']);
      expect(inline.portRanges, ['8000:9000']);
      expect(inline.protocols, ['tls']);
      expect(inline.outbound, kOutboundReject);
    });

    test('srs kind preserved', () {
      final src = CustomRuleSrs(
        name: 'Remote',
        srsUrl: 'https://example.com/rules.srs',
        outbound: 'vpn-1',
      );
      final back = CustomRule.fromJson(src.toJson());
      expect(back, isA<CustomRuleSrs>());
      final srs = back as CustomRuleSrs;
      expect(srs.srsUrl, 'https://example.com/rules.srs');
    });

    test('legacy target field → outbound', () {
      final back = CustomRule.fromJson({
        'id': 'legacy-1',
        'name': 'Legacy',
        'enabled': true,
        'kind': 'inline',
        'domains': ['foo.com'],
        'target': 'vpn-1',
      });
      expect(back, isA<CustomRuleInline>());
      expect((back as CustomRuleInline).outbound, 'vpn-1');
    });
  });

  group('CustomRule.summary', () {
    test('пустой inline → empty', () {
      expect(CustomRuleInline(name: 'x').summary, '');
    });

    test('inline с полями → разделённый dot', () {
      final s = CustomRuleInline(
        name: 'x',
        domainSuffixes: ['a', 'b'],
        ports: ['443'],
        protocols: ['tls'],
      ).summary;
      expect(s, contains('2 suffix'));
      expect(s, contains('1 port'));
      expect(s, contains('1 proto'));
    });

    test('srs → хост из URL', () {
      final s = CustomRuleSrs(
        name: 'x',
        srsUrl: 'https://rules.example.com/geo.srs',
      ).summary;
      expect(s, 'SRS: rules.example.com');
    });
  });

  // §051 / §030 new_fields — wifi_ssid / wifi_bssid.
  //
  // ⚠ С sing-box 1.14 wifi_* эмитятся в **headless rule_set** (раньше под 1.12
  // были на routing-rule level). Эти тесты обновлены под 1.14-форму.
  group('§051 wifi conditions (1.14: headless)', () {
    test('inline wifi-only → headless rule_set с wifi_ssid', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleInline(
          name: 'Home wifi → direct',
          wifiSsids: ['lexRouter'],
          outbound: 'direct-out',
        ),
      ]);
      // §030/new_fields: wifi теперь внутри headless rule_set (1.14).
      expect(reg.getRuleSets(), hasLength(1));
      expect(reg.getRuleSets().first['rules'], [
        {'wifi_ssid': ['lexRouter']},
      ]);
      expect(reg.getRules(), [
        {
          'rule_set': 'Home wifi → direct',
          'outbound': 'direct-out',
        },
      ]);
    });

    test('inline wifi_ssid + wifi_bssid в headless rule_set вместе', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleInline(
          name: 'Home',
          wifiSsids: ['lexRouter'],
          wifiBssids: ['38:2c:4a:cf:6d:5c'],
          outbound: 'direct-out',
        ),
      ]);
      expect(reg.getRuleSets().first['rules'], [
        {
          'wifi_ssid': ['lexRouter'],
          'wifi_bssid': ['38:2c:4a:cf:6d:5c'],
        },
      ]);
      expect(reg.getRules(), [
        {
          'rule_set': 'Home',
          'outbound': 'direct-out',
        },
      ]);
    });

    test('inline domain + wifi: оба в headless rule_set, AND-семантика', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleInline(
          name: 'Banking on home wifi',
          domains: ['bank.com'],
          wifiSsids: ['lexRouter'],
          outbound: 'direct-out',
        ),
      ]);
      // §030/new_fields: domain И wifi заходят в headless rule_set (AND).
      expect(reg.getRuleSets(), hasLength(1));
      expect(reg.getRuleSets().first['rules'], [
        {
          'domain': ['bank.com'],
          'wifi_ssid': ['lexRouter'],
        },
      ]);
      expect(reg.getRules(), [
        {
          'rule_set': 'Banking on home wifi',
          'outbound': 'direct-out',
        },
      ]);
    });

    test('srs + wifi: rule_set + wifi_ssid в одном правиле', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleSrs(
          name: 'GeoSite RU on home',
          srsUrl: 'https://example.com/geo.srs',
          wifiSsids: ['lexRouter'],
          outbound: 'direct-out',
        ),
      ], srsPaths: {
        // CustomRuleSrs needs cached path, иначе skipped с warning.
        // Pass id-key = generated id; используем factory-call id для этого
        // не получится (UUID каждый запуск разный). Создадим с id явно:
      });
    });

    test('srs + wifi с явным id и path', () {
      final reg = RuleSetRegistry();
      final srs = CustomRuleSrs(
        id: 'srs-1',
        name: 'GeoSite RU on home',
        srsUrl: 'https://example.com/geo.srs',
        wifiSsids: ['lexRouter'],
        outbound: 'direct-out',
      );
      applyCustomRules(reg, [srs], srsPaths: {'srs-1': '/cache/geo.srs'});
      expect(reg.getRuleSets(), hasLength(1));
      expect(reg.getRules(), [
        {
          'rule_set': 'GeoSite RU on home',
          'wifi_ssid': ['lexRouter'],
          'outbound': 'direct-out',
        },
      ]);
    });

    test('disabled rule не эмитит wifi-условия', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleInline(
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
        CustomRuleInline(
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
    test('inline source_ip_cidr → headless rule_set', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleInline(
          name: 'LAN clients',
          sourceIpCidrs: ['192.168.1.0/24'],
          outbound: 'direct-out',
        ),
      ]);
      // source_ip_cidr принимается headless rule_set (sing-box 1.14).
      expect(reg.getRuleSets(), hasLength(1));
      expect(reg.getRuleSets().first['rules'], [
        {'source_ip_cidr': ['192.168.1.0/24']},
      ]);
      expect(reg.getRules(), [
        {'rule_set': 'LAN clients', 'outbound': 'direct-out'},
      ]);
    });

    test('inline domain + source_ip_cidr — оба в headless (AND)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleInline(
          name: 'r',
          domains: ['bank.com'],
          sourceIpCidrs: ['10.0.0.0/8'],
          outbound: 'vpn-1',
        ),
      ]);
      expect(reg.getRuleSets().first['rules'], [
        {
          'domain': ['bank.com'],
          'source_ip_cidr': ['10.0.0.0/8'],
        },
      ]);
    });

    test('inline source_ip_is_private → routing-rule level (не headless)', () {
      final reg = RuleSetRegistry();
      applyCustomRules(reg, [
        CustomRuleInline(
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
        CustomRuleInline(
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
        CustomRuleInline(
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
      final srs = CustomRuleSrs(
        id: 'srs-1',
        name: 'GeoSite',
        srsUrl: 'https://example.com/geo.srs',
        sourceIpCidrs: ['192.168.0.0/16'],
        sourceIpIsPrivate: true,
        inbounds: ['mixed-in'],
        outbound: 'direct-out',
      );
      applyCustomRules(reg, [srs], srsPaths: {'srs-1': '/cache/geo.srs'});
      expect(reg.getRules(), [
        {
          'rule_set': 'GeoSite',
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
        CustomRuleInline(name: 'r', domains: ['ya.ru'], outbound: 'direct-out'),
      ]);
      final rs = reg.getRuleSets().first['rules'] as List;
      expect((rs.first as Map).containsKey('source_ip_cidr'), isFalse);
      final rule = reg.getRules().first;
      expect(rule.containsKey('source_ip_is_private'), isFalse);
      expect(rule.containsKey('inbound'), isFalse);
    });

    test('JSON round-trip + backward-compat', () {
      final r = CustomRuleInline(
        id: 'id-1',
        name: 'r',
        sourceIpCidrs: ['10.0.0.0/8'],
        sourceIpIsPrivate: true,
        inbounds: ['mixed-in'],
      );
      final json = r.toJson();
      expect(json['sourceIpCidrs'], ['10.0.0.0/8']);
      expect(json['sourceIpIsPrivate'], true);
      expect(json['inbounds'], ['mixed-in']);
      final restored = CustomRule.fromJson(json) as CustomRuleInline;
      expect(restored.sourceIpCidrs, ['10.0.0.0/8']);
      expect(restored.sourceIpIsPrivate, isTrue);
      expect(restored.inbounds, ['mixed-in']);

      // Старый JSON без новых ключей → пустые/false.
      final legacy = CustomRule.fromJson({
        'kind': 'inline',
        'name': 'Legacy',
        'domains': ['ya.ru'],
      }) as CustomRuleInline;
      expect(legacy.sourceIpCidrs, isEmpty);
      expect(legacy.sourceIpIsPrivate, isFalse);
      expect(legacy.inbounds, isEmpty);

      // toJson не пишет пустые.
      final emptyJson = legacy.toJson();
      expect(emptyJson.containsKey('sourceIpCidrs'), isFalse);
      expect(emptyJson.containsKey('sourceIpIsPrivate'), isFalse);
      expect(emptyJson.containsKey('inbounds'), isFalse);
    });
  });

  // §051 — JSON round-trip для wifi-полей.
  group('§051 wifi JSON round-trip', () {
    test('inline: toJson skip empty, fromJson restores', () {
      final r = CustomRuleInline(
        id: 'id-1',
        name: 'Home',
        wifiSsids: ['lexRouter'],
        wifiBssids: ['38:2c:4a:cf:6d:5c'],
      );
      final json = r.toJson();
      expect(json['wifiSsids'], ['lexRouter']);
      expect(json['wifiBssids'], ['38:2c:4a:cf:6d:5c']);

      final restored =
          CustomRule.fromJson(json) as CustomRuleInline;
      expect(restored.wifiSsids, ['lexRouter']);
      expect(restored.wifiBssids, ['38:2c:4a:cf:6d:5c']);
    });

    test('inline: empty wifi-поля не пишутся в JSON', () {
      final r = CustomRuleInline(name: 'No wifi', domains: ['ya.ru']);
      final json = r.toJson();
      expect(json.containsKey('wifiSsids'), isFalse);
      expect(json.containsKey('wifiBssids'), isFalse);
    });

    test('inline: BSSID lower-case на read-side (model tolerant)', () {
      final r = CustomRule.fromJson({
        'kind': 'inline',
        'name': 'X',
        'wifiBssids': ['38:2C:4A:CF:6D:5C', 'AA:BB:CC:DD:EE:FF'],
      }) as CustomRuleInline;
      expect(r.wifiBssids, ['38:2c:4a:cf:6d:5c', 'aa:bb:cc:dd:ee:ff']);
    });

    test('inline: backward-compat — старый JSON без wifi-полей', () {
      final r = CustomRule.fromJson({
        'kind': 'inline',
        'name': 'Legacy',
        'domains': ['ya.ru'],
        'outbound': 'direct-out',
      }) as CustomRuleInline;
      expect(r.wifiSsids, isEmpty);
      expect(r.wifiBssids, isEmpty);
    });

    test('srs: round-trip сохраняет wifi-поля', () {
      final r = CustomRuleSrs(
        id: 'srs-1',
        name: 'GeoSite',
        srsUrl: 'https://example.com/geo.srs',
        wifiSsids: ['Office'],
        wifiBssids: ['11:22:33:44:55:66'],
      );
      final restored =
          CustomRule.fromJson(r.toJson()) as CustomRuleSrs;
      expect(restored.wifiSsids, ['Office']);
      expect(restored.wifiBssids, ['11:22:33:44:55:66']);
    });

    test('inline: copyWith с wifi-полями', () {
      final r = CustomRuleInline(name: 'X');
      final updated = r.copyWith(wifiSsids: ['Home']);
      expect(updated.wifiSsids, ['Home']);
      expect(updated.wifiBssids, isEmpty);
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

    test('round-trip toJson/fromJson сохраняет тело', () {
      final r = CustomRuleJson(
        id: 'j-1',
        name: 'RT',
        json: '{"action":"hijack-dns"}',
      );
      final restored = CustomRule.fromJson(r.toJson());
      expect(restored, isA<CustomRuleJson>());
      expect((restored as CustomRuleJson).json, '{"action":"hijack-dns"}');
      expect(restored.kind, CustomRuleKind.json);
    });
  });
}
