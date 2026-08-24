import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/rule_transfer.dart';

/// §396 — экспорт/импорт правил файлом: конверт, парс, санация ссылок,
/// вставка (имя/num). Схема wire-формата — в спеке §396 §3.
void main() {
  // Шаблон получателя: один пресет с remote rule_set (block-ads, num 960)
  // и один чисто-inline (private-ip, num 950) — хватает для preset-веток.
  // dns_options — один шаблонный сервер google_udp (для DNS-санации §5.3a).
  final template = WizardTemplate.fromJson({
    'dns_options': {
      'servers': [
        {
          'enabled': true,
          'server': {'tag': 'google_udp', 'type': 'udp'},
        },
      ],
    },
    'selectable_rules': [
      {
        'preset_id': 'block-ads',
        'ui': {'label': 'Block Ads', 'num': 960},
        'rule': {'rule_set': 'geosite-ads', 'action': 'reject'},
        'rule_set': [
          {
            'type': 'remote',
            'tag': 'geosite-ads',
            'url': 'https://example.com/ads.srs',
          },
        ],
      },
      {
        'preset_id': 'private-ip',
        'ui': {'label': 'Private IP', 'num': 950},
        'rule': {'ip_is_private': true, 'outbound': 'direct-out'},
      },
    ],
  });

  const directionTags = {'vpn-1', 'vpn-2'};
  const dnsTags = {'dns-cf', 'dns-google'};

  SanitizedImportRule sanitize(dynamic entry) => sanitizeImportedRule(
        entry,
        directionTags: directionTags,
        dnsServerTags: dnsTags,
        template: template,
      );

  group('конверт', () {
    test('buildRulesExport пишет маркеры и все правила', () {
      final json = buildRulesExport(
        [
          CustomRuleInline(name: 'A', domains: ['a.com']),
          CustomRuleJson(name: 'B', json: '{"outbound":"direct-out"}'),
        ],
        appVersion: '9.9.9+999',
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['app'], 'lxbox');
      expect(decoded['kind'], 'rules');
      expect(decoded['format'], kRulesExportFormatVersion);
      expect(decoded['source_app_version'], '9.9.9+999');
      expect(decoded['created_at'], isNotNull);
      expect((decoded['rules'] as List).length, 2);
    });

    test('parse отвергает не-JSON, чужой app, пустые rules', () {
      expect(() => parseRulesImport('not json'),
          throwsA(isA<FormatException>()));
      expect(
          () => parseRulesImport('{"app":"other","kind":"rules","format":1}'),
          throwsA(isA<FormatException>()));
      expect(
          () => parseRulesImport(
              '{"app":"lxbox","kind":"rules","format":1,"rules":[]}'),
          throwsA(isA<FormatException>()));
    });

    test('parse отличает бэкап-файл понятной ошибкой', () {
      expect(
        () => parseRulesImport('{"app":"lxbox","kind":"backup","format":1}'),
        throwsA(predicate(
            (e) => e is FormatException && e.message.contains('backup'))),
      );
    });

    test('parse отвергает format из будущего', () {
      expect(
        () => parseRulesImport(
            '{"app":"lxbox","kind":"rules","format":2,"rules":[{}]}'),
        throwsA(predicate(
            (e) => e is FormatException && e.message.contains('newer'))),
      );
    });

    test('round-trip: export → parse сохраняет элементы', () {
      final rule = CustomRuleInline(
        name: 'Round',
        domains: ['x.com'],
        ports: ['443'],
        outbound: 'vpn-2',
      );
      final contents = parseRulesImport(buildRulesExport([rule]));
      expect(contents.rawRules.length, 1);
      final s = sanitize(contents.rawRules.single);
      expect(s.importable, isTrue);
      final imported = s.rule!;
      // Эквивалентность полей — id намеренно ДРУГОЙ (перегенерация).
      expect(imported.id, isNot(rule.id));
      final a = imported.toJson()..remove('id');
      final b = rule.toJson()..remove('id');
      expect(a, b);
    });
  });

  group('санация: неимпортируемое', () {
    test('элемент не-Map / без kind / с чужим kind → unsupportedEntry', () {
      for (final entry in [
        42,
        <String, dynamic>{'name': 'no kind'},
        <String, dynamic>{'kind': 'hologram', 'name': 'future'},
      ]) {
        final s = sanitize(entry);
        expect(s.importable, isFalse, reason: '$entry');
        expect(s.rejectReason, ImportRuleRejectReason.unsupportedEntry);
      }
    });

    test('битый элемент не topит остальные', () {
      final file = buildRulesExport([CustomRuleInline(name: 'OK')]);
      final decoded = jsonDecode(file) as Map<String, dynamic>;
      (decoded['rules'] as List).insert(0, {'kind': 'hologram'});
      final contents = parseRulesImport(jsonEncode(decoded));
      final items = contents.rawRules.map(sanitize).toList();
      expect(items[0].importable, isFalse);
      expect(items[1].importable, isTrue);
    });

    test('§398 — любой preset неимпортируем (и знакомый, и чужой)', () {
      for (final pid in ['block-ads', 'private-ip', 'from-the-future']) {
        final s = sanitize(
            CustomRulePreset(name: 'P', presetId: pid).toJson());
        expect(s.importable, isFalse, reason: pid);
        expect(s.rejectReason, ImportRuleRejectReason.presetNotTransferable,
            reason: pid);
      }
    });

    test('§398 — правило с занятым именем неимпортируемо', () {
      final s = sanitizeImportedRule(
        CustomRuleInline(name: 'My Rule', domains: ['a.com']).toJson(),
        directionTags: directionTags,
        dnsServerTags: dnsTags,
        template: template,
        existingNames: {'My Rule'},
      );
      expect(s.importable, isFalse);
      expect(s.rejectReason, ImportRuleRejectReason.nameExists);
    });
  });

  group('санация: outbound', () {
    test('висячий тег → vpn-1 + выключение + warning', () {
      final s = sanitize(CustomRuleInline(
        name: 'R',
        domains: ['a.com'],
        outbound: 'vpn-9',
      ).toJson());
      final rule = s.rule!;
      expect(rule.outbound, kImportOutboundFallback);
      expect(rule.enabled, isFalse);
      expect(s.warnings, hasLength(1));
      expect(s.warnings.single.kind, ImportRuleWarningKind.outboundMissing);
      expect(s.warnings.single.missingTag, 'vpn-9');
    });

    test('спец-теги и существующее Направление — без лечения', () {
      for (final ob in ['reject', 'block', 'direct-out', 'vpn-2']) {
        final s = sanitize(
            CustomRuleInline(name: 'R', outbound: ob, domains: ['a.com'])
                .toJson());
        expect(s.warnings, isEmpty, reason: ob);
        expect(s.rule!.outbound, ob);
        expect(s.rule!.enabled, isTrue, reason: ob);
      }
    });

    test('json-правило: пустой outbound не лечится', () {
      final s = sanitize(
          CustomRuleJson(name: 'J', json: '{"outbound":"direct-out"}')
              .toJson());
      expect(s.importable, isTrue);
      expect(s.warnings, isEmpty);
      expect(s.rule!.enabled, isTrue);
    });
  });

  group('санация: dns / resolve', () {
    test('висячий dns.serverTag → опция выключена, forceIpv4 выжил', () {
      final s = sanitize(CustomRuleInline(
        name: 'R',
        domains: ['a.com'],
        dns: const RuleDns(
            enabled: true, serverTag: 'my-doh', forceIpv4: true),
      ).toJson());
      final dns = s.rule!.dns!;
      expect(dns.enabled, isFalse);
      expect(dns.serverTag, '');
      expect(dns.forceIpv4, isTrue);
      expect(s.warnings.single.kind, ImportRuleWarningKind.dnsServerMissing);
      // DNS-лечение не выключает правило целиком.
      expect(s.rule!.enabled, isTrue);
    });

    test('известный dns.serverTag — без лечения', () {
      final s = sanitize(CustomRuleInline(
        name: 'R',
        domains: ['a.com'],
        dns: const RuleDns(enabled: true, serverTag: 'dns-cf'),
      ).toJson());
      expect(s.warnings, isEmpty);
      expect(s.rule!.dns!.serverTag, 'dns-cf');
      expect(s.rule!.dns!.enabled, isTrue);
    });

    test('висячий resolve.serverTag → auto', () {
      final s = sanitize(CustomRuleInline(
        name: 'R',
        domains: ['a.com'],
        resolve: const RuleResolve(serverTag: 'my-doh', strategy: 'ipv4_only'),
      ).toJson());
      final resolve = s.rule!.resolve!;
      expect(resolve.serverTag, '');
      expect(resolve.strategy, 'ipv4_only'); // остальное не тронуто
      expect(
          s.warnings.single.kind, ImportRuleWarningKind.resolveServerMissing);
    });
  });

  group('санация: srs', () {
    test('srs-правило приезжает выключенным даже если в файле включено', () {
      final s = sanitize(CustomRuleSrs(
        name: 'S',
        enabled: true,
        srsUrl: 'https://example.com/x.srs',
      ).toJson());
      expect(s.rule!.enabled, isFalse);
      expect(s.needsSrsDownload, isTrue);
      expect(s.warnings, isEmpty); // штатное поведение, не warning
    });

  });

  group('вставка: имя и num', () {
    test('чужой num из файла не переносится — правило садится в свою зону', () {
      final target = <CustomRule>[];
      final raw = CustomRuleInline(name: 'A', domains: ['a.com']).toJson()
        ..['num'] = 5; // чужая ось
      final s = sanitize(raw);
      final inserted = insertImportedRule(target, s.rule!, template: template);
      expect(inserted.orderNum, kUserRuleNumStart);
      expect(target, contains(inserted));
    });

    test('не-preset → nextUserRuleNum, последовательно при мульти-импорте',
        () {
      final target = <CustomRule>[];
      final a = insertImportedRule(
          target,
          sanitize(CustomRuleInline(name: 'A', domains: ['a.com']).toJson())
              .rule!,
          template: template);
      final b = insertImportedRule(
          target,
          sanitize(CustomRuleInline(name: 'B', domains: ['b.com']).toJson())
              .rule!,
          template: template);
      expect(a.orderNum, kUserRuleNumStart);
      expect(b.orderNum, kUserRuleNumStart + 1);
    });

    test('§398 — имя при вставке не мутируется (суффиксов больше нет)', () {
      final target = <CustomRule>[];
      final s =
          sanitize(CustomRuleInline(name: 'My Rule', domains: ['a.com']).toJson());
      final inserted = insertImportedRule(target, s.rule!, template: template);
      expect(inserted.name, 'My Rule');
    });
  });

  group('DNS-секции конверта (§5.3a)', () {
    test('buildRulesExport пишет dns_servers/dns_rules, parse их читает', () {
      final json = buildRulesExport(
        [CustomRuleInline(name: 'R', domains: ['a.com'])],
        dnsServers: [
          {'enabled': true, 'kind': 'inline', 'tag': 'my-doh', 'body': {'type': 'udp', 'server': '10.0.0.1'}},
        ],
        dnsRules: [
          {'kind': 'inline', 'name': 'ntc', 'rule': {'domain': 'ntc.party'}},
        ],
      );
      final contents = parseRulesImport(json);
      expect(contents.rawDnsServers, hasLength(1));
      expect(contents.rawDnsRules, hasLength(1));
      // Файл без секций → пустые списки, не ошибка.
      final bare = parseRulesImport(
          buildRulesExport([CustomRuleInline(name: 'R')]));
      expect(bare.rawDnsServers, isEmpty);
      expect(bare.rawDnsRules, isEmpty);
    });

    test('referencedDnsServerTags собирает dns/resolve-теги', () {
      final tags = referencedDnsServerTags([
        CustomRuleInline(
          name: 'A',
          dns: const RuleDns(enabled: true, serverTag: 'x-doh'),
        ),
        CustomRuleInline(
          name: 'B',
          resolve: const RuleResolve(serverTag: 'y-udp'),
        ),
        CustomRuleInline(name: 'C'),
      ]);
      expect(tags, {'x-doh', 'y-udp'});
    });

    group('sanitizeImportedDnsServer', () {
      SanitizedImportDnsItem srv(dynamic raw, {Set<String> existing = const {}}) =>
          sanitizeImportedDnsServer(
            raw,
            existingTags: existing,
            templateServerTags: {'google_udp'},
          );

      test('inline-сервер с новым tag → importable', () {
        final s = srv({
          'enabled': true,
          'kind': 'inline',
          'tag': 'my-doh',
          'body': {'type': 'udp', 'server': '10.0.0.1'},
          'description': 'Mine',
        });
        expect(s.importable, isTrue);
        expect(s.item!['tag'], 'my-doh');
        expect(s.label, 'Mine (my-doh)');
      });

      test('tag уже существует → alreadyExists, настройки не трогаются', () {
        final s = srv(
          {'enabled': true, 'kind': 'inline', 'tag': 'my-doh', 'body': {'type': 'udp', 'server': '1.2.3.4'}},
          existing: {'my-doh'},
        );
        expect(s.importable, isFalse);
        expect(s.skipReason, ImportDnsSkipReason.alreadyExists);
      });

      test('template-сервер: известный шаблону → importable, чужой → notAvailable', () {
        final known = srv({'enabled': true, 'kind': 'template', 'tag': 'google_udp'});
        expect(known.importable, isTrue);
        final unknown = srv({'enabled': true, 'kind': 'template', 'tag': 'quantum_dns'});
        expect(unknown.importable, isFalse);
        expect(unknown.skipReason, ImportDnsSkipReason.notAvailable);
      });

      test('preset-сервер → managedByPresets; мусор → unsupportedEntry', () {
        final preset = srv({'enabled': true, 'kind': 'preset', 'tag': 'fakeip'});
        expect(preset.skipReason, ImportDnsSkipReason.managedByPresets);
        expect(srv(42).skipReason, ImportDnsSkipReason.unsupportedEntry);
        expect(srv({'kind': 'hologram', 'tag': 'x'}).skipReason,
            ImportDnsSkipReason.unsupportedEntry);
      });
    });

    group('sanitizeImportedDnsRule', () {
      SanitizedImportDnsItem rule(dynamic raw,
              {List<Map<String, dynamic>> existing = const []}) =>
          sanitizeImportedDnsRule(raw,
              existingRules: existing, template: template);

      test('inline новое → importable, enabled автора переносится', () {
        final s = rule({
          'enabled': false,
          'kind': 'inline',
          'name': 'ntc',
          'rule': {'domain': 'ntc.party', 'action': 'predefined'},
        });
        expect(s.importable, isTrue);
        expect(s.item!['enabled'], isFalse);
        expect(s.item!['name'], 'ntc');
      });

      test('inline точный дубль → alreadyExists', () {
        final entry = {
          'kind': 'inline',
          'name': 'ntc',
          'rule': {'domain': 'ntc.party'},
        };
        final s = rule(Map<String, dynamic>.from(entry),
            existing: [Map<String, dynamic>.from(entry)]);
        expect(s.skipReason, ImportDnsSkipReason.alreadyExists);
      });

      test('preset: есть → alreadyExists; неизвестен → notAvailable; известен → importable', () {
        expect(
          rule({'kind': 'preset', 'presetId': 'block-ads'},
              existing: [{'kind': 'preset', 'presetId': 'block-ads'}]).skipReason,
          ImportDnsSkipReason.alreadyExists,
        );
        expect(
          rule({'kind': 'preset', 'presetId': 'from-the-future'}).skipReason,
          ImportDnsSkipReason.notAvailable,
        );
        expect(rule({'kind': 'preset', 'presetId': 'block-ads'}).importable,
            isTrue);
      });

      test('srs → id перегенерируется', () {
        final s = rule({
          'kind': 'srs',
          'name': 'geo',
          'id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'body': {'rule_set': 'x'},
        });
        expect(s.importable, isTrue);
        expect(s.item!['id'], isNot('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'));
        expect(s.item!['name'], 'geo');
      });
    });
  });
}
