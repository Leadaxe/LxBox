import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/record_codec.dart';

/// §435 — кодек записей ONE_NAMESPACE §1–§2: метаданные + `body` sing-box.
void main() {
  group('§435 ruleToRecord / ruleFromRecord — inline', () {
    test('inline: тело в именах и типах sing-box, действие — outbound', () {
      final r = CustomRuleInline(
        id: 'r1',
        name: 'Home LAN',
        enabled: true,
        orderNum: 945,
        domains: ['a.com'],
        domainSuffixes: ['.lan'],
        domainKeywords: ['nas'],
        ipCidrs: ['100.64.0.0/10'],
        ports: ['80', '443', 'x'],
        portRanges: ['8000:9000'],
        packages: ['com.app'],
        protocols: ['tls'],
        network: ['tcp'],
        ipIsPrivate: true,
        sourceIpCidrs: ['10.0.0.0/8'],
        sourceIpIsPrivate: true,
        inbounds: ['tun-in'],
        wifiSsids: ['home'],
        wifiBssids: ['AA:BB:CC:DD:EE:FF'],
        outbound: '@self',
      );
      final rec = ruleToRecord(r);
      expect(rec['kind'], 'inline');
      expect(rec['id'], 'r1');
      expect(rec['name'], 'Home LAN');
      expect(rec['enabled'], true);
      expect(rec['num'], 945);
      expect(rec['body'], {
        'domain': ['a.com'],
        'domain_suffix': ['.lan'],
        'domain_keyword': ['nas'],
        'ip_cidr': ['100.64.0.0/10'],
        'port': [80, 443], // `x` отброшен: sing-box ждёт числа
        'port_range': ['8000:9000'],
        'package_name': ['com.app'],
        'protocol': ['tls'],
        'network': ['tcp'],
        'ip_is_private': true,
        'source_ip_cidr': ['10.0.0.0/8'],
        'source_ip_is_private': true,
        'inbound': ['tun-in'],
        'wifi_ssid': ['home'],
        'wifi_bssid': ['aa:bb:cc:dd:ee:ff'],
        'outbound': '@self',
      });
      expect(rec.containsKey('refs'), isFalse);

      final back = ruleFromRecord(rec).value! as CustomRuleInline;
      expect(back.id, 'r1');
      expect(back.orderNum, 945);
      expect(back.ipCidrs, ['100.64.0.0/10']);
      expect(back.ports, ['80', '443']);
      expect(back.wifiBssids, ['aa:bb:cc:dd:ee:ff']);
      expect(back.outbound, '@self');
      expect(ruleToRecord(back), rec, reason: 'round-trip байт-в-байт');
    });

    test('reject → action: reject, обратно kOutboundReject', () {
      final r = CustomRuleInline(name: 'Block', domains: ['ads.com'], outbound: kOutboundReject);
      final rec = ruleToRecord(r);
      expect(rec['body'], {'domain': ['ads.com'], 'action': 'reject'});
      expect(ruleFromRecord(rec).value!.outbound, kOutboundReject);
    });

    test('без outbound и action → direct-out; скаляр в списке принимается', () {
      final read = ruleFromRecord({
        'kind': 'inline',
        'name': 'x',
        'body': {'domain_suffix': '.ts.net'},
      });
      final r = read.value! as CustomRuleInline;
      expect(r.outbound, kDirectOutboundTag);
      expect(r.domainSuffixes, ['.ts.net']);
      expect(r.enabled, isTrue);
      expect(r.orderNum, isNull);
    });

    test('незнакомые ключи body → unknownKeys, запись живёт', () {
      final read = ruleFromRecord({
        'kind': 'inline',
        'name': 'x',
        'body': {'ip_cidr': ['1.1.1.1/32'], 'process_name': ['a'], 'user': ['u'], 'outbound': 'p'},
      });
      expect(read.value, isNotNull);
      expect(read.unknownKeys, ['process_name', 'user']);
    });

    test('dns/resolve — поля записи вне body, переживают round-trip', () {
      final r = CustomRuleInline(
        name: 'x',
        domains: ['a'],
        dns: const RuleDns(enabled: true, serverTag: 'doh'),
      );
      final rec = ruleToRecord(r);
      expect(rec['dns'], isA<Map>());
      expect((rec['body'] as Map).containsKey('dns'), isFalse);
      final back = ruleFromRecord(rec).value!;
      expect(back.dns?.serverTag, 'doh');
    });

    test('чужой kind / нет kind / body не объект → drop с причиной', () {
      expect(ruleFromRecord({'name': 'x'}).dropped, contains('without kind'));
      expect(ruleFromRecord({'kind': 'magic', 'name': 'x'}).dropped, contains('magic'));
      expect(ruleFromRecord({'kind': 'inline', 'name': 'x', 'body': 'str'}).dropped,
          contains('not an object'));
    });
  });

  group('§435 ruleToRecord / ruleFromRecord — srs / preset / json', () {
    test('srs: refs снаружи body, rule_set в body не пишется; при чтении — незнакомый ключ', () {
      final r = CustomRuleSrs(
        id: 's1',
        name: 'Geo',
        srsUrls: ['https://x/a.srs', 'https://x/b.srs'],
        ports: ['443'],
        outbound: 'vpn-1',
      );
      final rec = ruleToRecord(r);
      expect(rec['kind'], 'srs');
      expect(rec['refs'], ['https://x/a.srs', 'https://x/b.srs']);
      expect(rec['body'], {'port': [443], 'outbound': 'vpn-1'});

      final back = ruleFromRecord({
        ...rec,
        'body': {...rec['body'] as Map, 'rule_set': ['Geo', 'Geo-2']},
      });
      // Норма B3 (14.09.2026): `rule_set` в теле записи сторона не переносит —
      // ключ незнакомый, решение об отбросе принимает контекст (секции —
      // запись целиком).
      expect(back.unknownKeys, ['rule_set']);
      expect((back.value! as CustomRuleSrs).srsUrls, r.srsUrls);
      expect(back.value!.ports, ['443']);
    });

    test('srs без refs читает одиночный ref', () {
      final back = ruleFromRecord({'kind': 'srs', 'name': 'g', 'ref': 'https://x/a.srs'});
      expect((back.value! as CustomRuleSrs).srsUrls, ['https://x/a.srs']);
    });

    test('preset: ref + vars', () {
      final r = CustomRulePreset(name: 'Ads', presetId: 'block-ads', varsValues: {'outbound': 'vpn-1'});
      final rec = ruleToRecord(r);
      expect(rec['ref'], 'block-ads');
      expect(rec['vars'], {'outbound': 'vpn-1'});
      final back = ruleFromRecord(rec).value! as CustomRulePreset;
      expect(back.presetId, 'block-ads');
      expect(back.varsValues, {'outbound': 'vpn-1'});
    });

    test('json: inline + verbatim, объект — в body, тело то же после круга',
        () {
      final r = CustomRuleJson(name: 'raw', json: '{"outbound":"x"}');
      final rec = ruleToRecord(r);
      expect(rec['kind'], 'inline');
      expect(rec['verbatim'], isTrue);
      expect(rec['body'], {'outbound': 'x'});
      final back = ruleFromRecord(rec).value! as CustomRuleJson;
      expect(jsonDecode(back.json), {'outbound': 'x'});
      expect(ruleToRecord(back), rec);
    });
  });

  group('§435 DNS-серверы', () {
    test('user ↔ DnsServerInline, тег в метаданных, не в body', () {
      const s = DnsServerInline(
        enabled: true,
        tag: '@{self}-dns',
        body: {'type': 'tailscale', 'endpoint': '@self', 'tag': 'stale'},
      );
      final rec = dnsServerToRecord(s);
      expect(rec, {
        'kind': 'user',
        'tag': '@{self}-dns',
        'enabled': true,
        'body': {'type': 'tailscale', 'endpoint': '@self'},
      });
      final back = dnsServerFromRecord(rec).value! as DnsServerInline;
      expect(back.tag, '@{self}-dns');
      expect(back.body, {'type': 'tailscale', 'endpoint': '@self'});
    });

    test('preset/template — корневые виды; чужой kind → drop', () {
      expect(dnsServerFromRecord({'kind': 'preset', 'tag': 'p'}).value, isA<DnsServerPreset>());
      final t = dnsServerFromRecord({'kind': 'template', 'tag': 't', 'vars': {'a': 'b'}}).value!
          as DnsServerTemplate;
      expect(t.varValues, {'a': 'b'});
      expect(dnsServerFromRecord({'kind': 'user', 'tag': 'x'}).dropped, contains('body'));
      expect(dnsServerFromRecord({'kind': 'user', 'body': {}}).dropped, contains('tag'));
      expect(dnsServerFromRecord({'kind': 'alien', 'tag': 'x'}).dropped, contains('alien'));
    });
  });

  group('§435 DNS-правила', () {
    test('user ↔ DnsRuleInline с enabled', () {
      const r = DnsRuleInline(
        name: '',
        rule: {'domain_suffix': ['.ts.net'], 'server': '@{self}-dns'},
        enabled: false,
      );
      final rec = dnsRuleToRecord(r);
      expect(rec, {
        'kind': 'user',
        'name': '',
        'enabled': false,
        'body': {'domain_suffix': ['.ts.net'], 'server': '@{self}-dns'},
      });
      final back = dnsRuleFromRecord(rec).value! as DnsRuleInline;
      expect(back.enabled, isFalse);
      expect(back.rule['server'], '@{self}-dns');
    });

    test('корневые виды и drop', () {
      expect(dnsRuleFromRecord({'kind': 'srs', 'name': 'n', 'id': 'i'}).value, isA<DnsRuleSrs>());
      expect(dnsRuleFromRecord({'kind': 'preset', 'ref': 'p'}).value, isA<DnsRulePreset>());
      expect(dnsRuleFromRecord({'kind': 'template', 'name': 't'}).value, isA<DnsRuleTemplate>());
      expect(dnsRuleFromRecord({'kind': 'user', 'name': 'x'}).dropped, contains('body'));
      expect(dnsRuleFromRecord({'kind': 'zzz'}).dropped, contains('zzz'));
    });
  });
}
