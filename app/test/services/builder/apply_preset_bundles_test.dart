import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';

void main() {
  group('applyPresetBundles (spec §033, sealed sig)', () {
    test('активный preset регистрирует rule_set + routing rule в registry, '
        'возвращает extra DNS данные (route+dns enabled)', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'Russian domains direct',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out', 'dns_server': 'yandex_doh'},
      );
      final reg = RuleSetRegistry();

      // §257: DNS-aspect гейтится var dns_enable; без var — всегда on.
      final result = applyPresetBundles(
        reg,
        [rule],
        [preset],
      );

      expect(result.warnings, isEmpty);
      expect(reg.getRuleSets().length, 1);
      expect(reg.getRuleSets().first['tag'], 'ru-direct:ru-domains');
      expect(reg.getRules().length, 1);
      expect(reg.getRules().first,
          {'rule_set': 'ru-direct:ru-domains', 'outbound': 'direct-out'});
      expect(result.extraDnsServers.length, 1);
      expect(result.extraDnsServers.first['tag'], 'ru-direct:yandex_doh');
      expect(result.extraDnsRules.length, 1);
      expect(result.extraDnsRules.first,
          {'rule_set': 'ru-direct:ru-domains', 'server': 'ru-direct:yandex_doh'});

      // §033: dnsRulesByPresetId — авторитативный источник для applyCustomDns
      // (по immutable presetId). labelByPresetId — для UI рендера.
      expect(result.dnsRulesByPresetId, hasLength(1));
      expect(result.dnsRulesByPresetId['ru-direct'], [
        {'rule_set': 'ru-direct:ru-domains', 'server': 'ru-direct:yandex_doh'}
      ]);
      expect(result.labelByPresetId['ru-direct'], 'Russian domains direct');
    });

    // §257: тумблер DNS-блока — магическая var dns_enable.
    test('§257 dns_enable=false: route emit, но без DNS fragments', () {
      final preset = _ruDirectWithDnsEnable();
      final rule = CustomRulePreset(
        name: 'Russian domains direct',
        presetId: 'ru-direct',
        varsValues: {
          'outbound': 'direct-out',
          'dns_server': 'yandex_doh',
          'dns_enable': 'false', // юзер выключил DNS-блок пресета
        },
      );
      final reg = RuleSetRegistry();

      final result = applyPresetBundles(reg, [rule], [preset]);

      // Route side активен — rule_set и routing rule зарегистрированы
      expect(reg.getRuleSets().length, 1);
      expect(reg.getRules().length, 1);

      // DNS side НЕ активен — dns_rule и dns_servers пропущены
      expect(result.dnsRulesByPresetId, isEmpty);
      expect(result.extraDnsServers, isEmpty);
    });

    test('§257 dns_enable объявлена, юзер не трогал → default true → DNS on',
        () {
      final preset = _ruDirectWithDnsEnable();
      final rule = CustomRulePreset(
        name: 'RU',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out', 'dns_server': 'yandex_doh'},
      );
      final reg = RuleSetRegistry();
      final result = applyPresetBundles(reg, [rule], [preset]);
      expect(result.dnsRulesByPresetId, hasLength(1));
      expect(result.extraDnsServers, hasLength(1));
    });

    test('§257 пресет БЕЗ var dns_enable → DNS всегда on (пока routing on)',
        () {
      final preset = _ruDirect(); // var не объявлена
      final rule = CustomRulePreset(
        name: 'RU',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out', 'dns_server': 'yandex_doh'},
      );
      final reg = RuleSetRegistry();
      final result = applyPresetBundles(reg, [rule], [preset]);
      expect(result.dnsRulesByPresetId, hasLength(1));
      expect(result.extraDnsServers, hasLength(1));
    });

    // §257 — DNS-only пресет (fakeip) с dns_enable=false → пресет ничего
    // не эмитит (у него нет routing, только DNS-блок под тумблером).
    test('§257 fakeip dns_enable=false → пусто (DNS-only пресет)', () {
      final preset = _fakeipWithDnsEnable();
      final rule = CustomRulePreset(
        name: 'FakeIP',
        presetId: 'fakeip',
        varsValues: {'dns_enable': 'false'},
      );
      final reg = RuleSetRegistry();
      final result = applyPresetBundles(reg, [rule], [preset]);
      expect(result.dnsRulesByPresetId, isEmpty);
      expect(result.extraDnsServers, isEmpty);
    });

    test('§257 fakeip dns_enable по умолчанию (default true) → DNS on', () {
      final preset = _fakeipWithDnsEnable();
      final rule = CustomRulePreset(name: 'FakeIP', presetId: 'fakeip');
      final reg = RuleSetRegistry();
      final result = applyPresetBundles(reg, [rule], [preset]);
      expect(result.dnsRulesByPresetId, hasLength(1));
      expect(result.extraDnsServers, hasLength(1));
    });

    test('§121 routing = король: route disabled подавляет DNS-аспект целиком '
        '(даже при dns enabled)', () {
      // §033 раньше разрешал DNS-only пресет (route off, dns on). §121 это
      // отменяет: routing-тоггл — король. cr.enabled=false → пресет мёртв
      // целиком: ни routing rule, ни rule_set, ни DNS-фрагменты, ни mirror.
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'ru-direct',
        enabled: false, // routing-тоггл выключен = король
        varsValues: {'outbound': 'direct-out', 'dns_server': 'yandex_doh'},
      );
      final reg = RuleSetRegistry();

      final result = applyPresetBundles(
        reg,
        [rule],
        [preset],
      );

      // Пресет мёртв целиком — ничего не эмитится.
      expect(reg.getRules(), isEmpty, reason: 'нет routing rule');
      expect(reg.getRuleSets(), isEmpty,
          reason: 'rule_set не регистрируется (на него никто не ссылается)');
      expect(result.dnsRulesByPresetId, isEmpty, reason: 'нет DNS-правила');
      expect(result.extraDnsServers, isEmpty, reason: 'нет DNS-серверов');
    });

    test('broken preset (presetId не найден) → warning + skip', () {
      final rule = CustomRulePreset(
        name: 'Ghost',
        presetId: 'missing',
      );
      final reg = RuleSetRegistry();

      final result = applyPresetBundles(reg, [rule], const []);

      expect(result.warnings.length, 1);
      expect(result.warnings.first, contains('missing'));
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), isEmpty);
      expect(result.extraDnsServers, isEmpty);
    });

    test('disabled preset-правило — пропускается полностью', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'ru-direct',
        enabled: false,
        varsValues: {'outbound': 'direct-out'},
      );
      final reg = RuleSetRegistry();

      final result = applyPresetBundles(reg, [rule], [preset]);

      expect(result.warnings, isEmpty);
      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), isEmpty);
    });

    test('inline правила пропускаются (обрабатывает applyCustomRules)', () {
      final preset = _ruDirect();
      final rule = CustomRuleInline(
        name: 'Firefox .ru',
        domainSuffixes: const ['ru'],
      );
      final reg = RuleSetRegistry();

      final result = applyPresetBundles(reg, [rule], [preset]);

      expect(reg.getRuleSets(), isEmpty);
      expect(reg.getRules(), isEmpty);
      expect(result.extraDnsServers, isEmpty);
    });

    test('два preset-правила с одним presetId и одинаковыми vars — '
        'identical-skip rule_set', () {
      final preset = _ruDirect();
      final ruleA = CustomRulePreset(
        name: 'A',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out'},
      );
      final ruleB = CustomRulePreset(
        name: 'B',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out'},
      );
      final reg = RuleSetRegistry();

      final result = applyPresetBundles(reg, [ruleA, ruleB], [preset]);

      expect(result.warnings, isEmpty,
          reason: 'identical content — silent skip');
      expect(reg.getRuleSets().length, 1,
          reason: 'один rule_set "ru-domains" на оба правила');
      expect(reg.getRules().length, 2);
    });

    test('rule_set tag сохраняется без auto-suffix (routing rule ссылается '
        'на литерал)', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out'},
      );
      final reg = RuleSetRegistry();

      applyPresetBundles(reg, [rule], [preset]);

      expect(reg.getRuleSets().first['tag'], 'ru-direct:ru-domains');
      expect(reg.getRules().first['rule_set'], 'ru-direct:ru-domains');
    });
  });
}

/// §257 — реплика DNS-only пресета `fakeip` с var `dns_enable` (default true).
SelectableRule _fakeipWithDnsEnable() => SelectableRule(
      label: 'FakeIP',
      presetId: 'fakeip',
      vars: [
        WizardVar(
          name: 'dns_enable',
          type: 'bool',
          defaultValue: 'true',
          title: 'DNS',
        ),
        WizardVar(
          name: 'dns_server',
          type: 'dns_servers',
          defaultValue: 'fakeip',
          wizardUI: 'hidden',
        ),
      ],
      dnsServers: [
        {'type': 'fakeip', 'tag': 'fakeip', 'inet4_range': '198.18.0.0/15'},
      ],
      dnsRule: const {
        'query_type': ['A', 'AAAA'],
        'server': '@dns_server',
      },
    );

/// §257 — реплика [_ruDirect] с магической var `dns_enable` (default true).
SelectableRule _ruDirectWithDnsEnable() {
  final base = _ruDirect();
  return SelectableRule(
    label: base.label,
    defaultEnabled: base.defaultEnabled,
    presetId: base.presetId,
    vars: [
      ...base.vars,
      WizardVar(
        name: 'dns_enable',
        type: 'bool',
        defaultValue: 'true',
        title: 'DNS',
      ),
    ],
    ruleSets: base.ruleSets,
    rule: base.rules,
    dnsRule: base.dnsRules,
    dnsServers: base.dnsServers,
  );
}

SelectableRule _ruDirect() => SelectableRule(
      label: 'Russian domains direct',
      defaultEnabled: true,
      presetId: 'ru-direct',
      vars: [
        WizardVar(
          name: 'outbound',
          type: 'outbound',
          defaultValue: 'direct-out',
        ),
        WizardVar(
          name: 'dns_server',
          type: 'dns_servers',
          defaultValue: 'yandex_doh',
          required: false,
        ),
      ],
      ruleSets: [
        {
          'tag': 'ru-domains',
          'type': 'inline',
          'format': 'domain_suffix',
          'rules': [
            {
              'domain_suffix': ['ru']
            }
          ]
        }
      ],
      dnsRule: const {'rule_set': 'ru-domains', 'server': '@dns_server'},
      rule: const {'rule_set': 'ru-domains', 'outbound': '@outbound'},
      dnsServers: [
        {
          'type': 'https',
          'tag': 'yandex_doh',
          'server': '77.88.8.88',
          'detour': '@outbound',
          'description': 'Yandex DoH',
        },
      ],
    );
