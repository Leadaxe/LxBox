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
  final template = WizardTemplate.fromJson({
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

  const channelTags = {'vpn-1', 'vpn-2'};
  const dnsTags = {'dns-cf', 'dns-google'};

  SanitizedImportRule sanitize(dynamic entry) => sanitizeImportedRule(
        entry,
        channelTags: channelTags,
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

    test('preset с неизвестным presetId → unknownPreset', () {
      final s = sanitize(
          CustomRulePreset(name: 'Ghost', presetId: 'from-the-future')
              .toJson());
      expect(s.importable, isFalse);
      expect(s.rejectReason, ImportRuleRejectReason.unknownPreset);
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

    test('спец-теги и существующий канал — без лечения', () {
      for (final ob in ['reject', 'block', 'direct-out', 'vpn-2']) {
        final s = sanitize(
            CustomRuleInline(name: 'R', outbound: ob, domains: ['a.com'])
                .toJson());
        expect(s.warnings, isEmpty, reason: ob);
        expect(s.rule!.outbound, ob);
        expect(s.rule!.enabled, isTrue, reason: ob);
      }
    });

    test('preset-override в varsValues лечится так же', () {
      final s = sanitize(CustomRulePreset(
        name: 'Private IP',
        presetId: 'private-ip',
        varsValues: {'outbound': 'vpn-9'},
      ).toJson());
      final rule = s.rule! as CustomRulePreset;
      expect(rule.varsValues['outbound'], kImportOutboundFallback);
      expect(rule.enabled, isFalse);
      expect(s.warnings.single.kind, ImportRuleWarningKind.outboundMissing);
    });

    test('preset без override («как в шаблоне») — чисто', () {
      final s = sanitize(
          CustomRulePreset(name: 'Private IP', presetId: 'private-ip')
              .toJson());
      expect(s.warnings, isEmpty);
      expect(s.rule!.enabled, isTrue);
      expect(s.needsSrsDownload, isFalse); // inline-пресет, без remote srs
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

    test('preset с remote rule_set → needsSrsDownload + выключен', () {
      final s = sanitize(
          CustomRulePreset(name: 'Block Ads', presetId: 'block-ads', enabled: true)
              .toJson());
      expect(s.rule!.enabled, isFalse);
      expect(s.needsSrsDownload, isTrue);
    });
  });

  group('вставка: имя и num', () {
    test('preset садится на шаблонный num, чужой num из файла не переносится',
        () {
      final target = <CustomRule>[];
      final raw =
          CustomRulePreset(name: 'Block Ads', presetId: 'block-ads')
              .toJson()
            ..['num'] = 5; // чужая ось
      final s = sanitize(raw);
      final inserted = insertImportedRule(target, s.rule!, template: template);
      expect(inserted.orderNum, 960);
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

    test('коллизия имени → суффикс копии; повторный импорт не коллизирует',
        () {
      final target = <CustomRule>[
        CustomRuleInline(name: 'My Rule', orderNum: 1000),
      ];
      final s =
          sanitize(CustomRuleInline(name: 'My Rule', domains: ['a.com']).toJson());
      final first = insertImportedRule(target, s.rule!, template: template);
      expect(first.name, 'My Rule (2)');

      final s2 =
          sanitize(CustomRuleInline(name: 'My Rule', domains: ['a.com']).toJson());
      final second = insertImportedRule(target, s2.rule!, template: template);
      expect(second.name, 'My Rule (3)');
      expect(second.id, isNot(first.id));
    });
  });
}
