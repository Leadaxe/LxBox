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

  // §439 §4.2 — путь хранения: `fromRecord(toRecord(x)) == x` для правил всех
  // видов (с `unknownAsVerbatim`) и DNS-записей всех видов, через JSON-текст
  // файла; вторая запись совпадает с первой.
  group('§439 круг кодека правил хранения', () {
    CustomRule viaStorage(CustomRule r) => ruleFromRecord(
          (jsonDecode(jsonEncode(ruleToRecord(r))) as Map)
              .cast<String, dynamic>(),
          unknownAsVerbatim: true,
        ).value!;

    final rules = <CustomRule>[
      CustomRuleInline(
        id: 'i1',
        name: 'Home LAN',
        enabled: false,
        orderNum: 945,
        domainSuffixes: ['.lan'],
        ipCidrs: ['10.0.0.0/8'],
        ports: ['443'],
        portRanges: ['8000:9000'],
        packages: ['com.app'],
        network: ['tcp'],
        wifiSsids: ['home'],
        outbound: 'vpn-2',
        dns: const RuleDns(enabled: true, serverTag: 'my-doh', forceIpv4: true),
        resolve: const RuleResolve(only: true, strategy: 'ipv4_only'),
      ),
      CustomRuleInline(name: '  spaced name  ', domains: ['a'], outbound: kOutboundReject),
      CustomRuleSrs(
        id: 's1',
        name: 'Geo sets',
        orderNum: 1010,
        srsUrls: ['https://x/a.srs', 'https://x/b.srs'],
        updateIntervalHours: 720,
        protocols: ['quic'],
        outbound: 'vpn-1',
      ),
      CustomRuleSrs(id: 's2', name: 'Never', srsUrl: 'https://x/c.srs', updateIntervalHours: 0),
      CustomRulePreset(
        id: 'p1',
        name: 'Russia direct',
        orderNum: 1120,
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out', 'dns_ip': '77.88.8.8'},
      ),
      CustomRuleJson(
        id: 'j1',
        name: 'Json object',
        orderNum: 1020,
        json: '{"//":"note","domain_suffix":[".x"],"action":"route","outbound":"vpn-1"}',
      ),
      CustomRuleJson(id: 'j2', name: 'Json broken', json: '{not json'),
    ];

    for (final r in rules) {
      test('${r.kind.name} "${r.name}"', () {
        final back = viaStorage(r);
        if (r is CustomRuleJson && r.json.startsWith('{not')) {
          // Нечитаемый текст — маркер без тела: имя, id и ось на месте, тело
          // пустое (текст остаётся в .v0.bak миграции).
          expect(back, isA<CustomRuleJson>());
          expect((back as CustomRuleJson).json, '');
          expect(back.id, r.id);
          expect(ruleToRecord(back).containsKey('body'), isFalse);
          return;
        }
        expect(back, r);
        expect(jsonEncode(ruleToRecord(back)), jsonEncode(ruleToRecord(r)));
      });
    }

    test('json-массив: запись держит один объект — splitJsonRuleArrays до '
        'кодека, каждая часть проходит круг', () {
      final split = splitJsonRuleArrays([
        CustomRuleJson(
          id: 'arr',
          name: 'Json array',
          orderNum: 1021,
          json: '[{"action":"sniff"},{"domain_suffix":[".y"],"outbound":"direct-out"}]',
        ),
      ]);
      expect(split.map((x) => x.name), ['Json array', 'Json array #2']);
      for (final part in split) {
        expect(viaStorage(part), part);
      }
      // Без деления массив не пережил бы запись: тела у маркера нет.
      final unsplit = CustomRuleJson(name: 'raw', json: '[{"action":"sniff"}]');
      expect(ruleToRecord(unsplit).containsKey('body'), isFalse);
    });
  });

  group('§439 круг кодека DNS-записей хранения', () {
    Map<String, dynamic> viaFile(Map<String, dynamic> rec) =>
        (jsonDecode(jsonEncode(rec)) as Map).cast<String, dynamic>();

    const servers = <DnsServerRef>[
      DnsServerInline(
        enabled: false,
        tag: 'my-doh',
        body: {'type': 'https', 'server': 'dns.example', 'detour': 'vpn-1'},
        description: 'Mine',
      ),
      DnsServerPreset(enabled: true, tag: 'yandex_udp', presetId: 'ru-direct'),
      DnsServerPreset(enabled: true, tag: 'orphan'),
      DnsServerTemplate(
        enabled: true,
        tag: 'google_doh',
        varValues: {'outbound': 'vpn-1', 'dns_ip': '8.8.4.4'},
        description: '',
      ),
    ];
    for (final s in servers) {
      test('сервер ${s.kind} "${s.tag}"', () {
        final rec = dnsServerToRecord(s);
        final back = dnsServerFromRecord(viaFile(rec)).value!;
        expect(back, s);
        expect(dnsServerToRecord(back), rec);
      });
    }

    const dnsRules = <DnsRuleRef>[
      DnsRuleInline(
        name: 'corp',
        enabled: false,
        rule: {
          'domain_suffix': ['.corp'],
          'server': 'my-doh',
        },
      ),
      DnsRulePreset(presetId: 'ru-direct', enabled: true),
      DnsRuleSrs(
        name: 'geo',
        id: 'ds_geo',
        body: {'server': 'google_doh'},
      ),
      DnsRuleSrs(
        name: 'top-level',
        id: 'ds_top',
        srsUrl: 'https://x/geo.srs',
        server: 'my-doh',
        rule: {
          'query_type': ['A'],
        },
        enabled: false,
      ),
      DnsRuleTemplate(name: 'Default', enabled: true),
      DnsRuleTemplate(name: 'Off', enabled: false),
    ];
    for (final (i, r) in dnsRules.indexed) {
      test('правило #$i ${r.kind}', () {
        final rec = dnsRuleToRecord(r);
        final back = dnsRuleFromRecord(viaFile(rec)).value!;
        expect(back, r);
        expect(dnsRuleToRecord(back), rec);
      });
    }
  });
}
