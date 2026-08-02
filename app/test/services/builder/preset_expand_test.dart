import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/post_steps.dart'
    show resolveDnsServersBodies;
import 'package:lxbox/services/builder/preset_expand.dart';

void main() {
  group('expandPreset (spec §033)', () {
    test('все vars заданы → полные fragments', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'Russian domains direct',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'vpn-1', 'dns_server': 'yandex_doh'},
      );

      final f = expandPreset(rule, preset);

      expect(f.warnings, isEmpty);
      expect(f.ruleSets.length, 1);
      expect(f.ruleSets.first['tag'], 'ru-domains');
      expect(f.dnsRules.single,
          {'rule_set': 'ru-domains', 'server': 'yandex_doh'});
      expect(f.routingRules.single,
          {'rule_set': 'ru-domains', 'outbound': 'vpn-1'});
      expect(f.dnsServers.length, 1);
      expect(f.dnsServers.first['tag'], 'yandex_doh');
      expect(f.dnsServers.first['detour'], 'vpn-1');
    });

    test('optional var: default_value применяется когда varsValues не содержит '
        'ключ (юзер не трогал)', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'Russian domains direct',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out'}, // dns_server не трогал
      );

      final f = expandPreset(rule, preset);

      expect(f.warnings, isEmpty);
      expect(f.dnsRules.single,
          {'rule_set': 'ru-domains', 'server': 'yandex_doh'},
          reason: 'default_value из шаблона применяется');
      expect(f.dnsServers.length, 1);
      expect(f.dnsServers.first['tag'], 'yandex_doh');
    });

    test('optional var: явная пустая строка → фрагменты с @var dropped', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'ru-direct',
        // '' = explicit "— (default DNS)" из UI dropdown'а
        varsValues: {'outbound': 'direct-out', 'dns_server': ''},
      );

      final f = expandPreset(rule, preset);

      expect(f.warnings, isEmpty);
      expect(f.routingRules.single['outbound'], 'direct-out');
      expect(f.dnsRules, isEmpty);
      expect(f.dnsServers, isEmpty);
    });

    test('@outbound == direct-out → detour удаляется из dns_servers', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'Russian domains direct',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out', 'dns_server': 'yandex_doh'},
      );

      final f = expandPreset(rule, preset);

      expect(f.dnsServers.length, 1);
      expect(f.dnsServers.first.containsKey('detour'), isFalse);
      expect(f.routingRules.single['outbound'], 'direct-out');
    });

    test('required var без explicit + defaultValue → substituted by default', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'Russian domains direct',
        presetId: 'ru-direct',
        varsValues: {}, // out required, default_value='direct-out' → direct
      );

      final f = expandPreset(rule, preset);

      expect(f.warnings, isEmpty);
      expect(f.routingRules.single['outbound'], 'direct-out');
    });

    test('required var + no value + empty default → empty fragments + warn', () {
      final preset = SelectableRule(
        label: 'Broken',
        presetId: 'broken',
        vars: [
          WizardVar(
            name: 'outbound',
            type: 'outbound',
            defaultValue: '', // no default, but required
          ),
        ],
        ruleSets: const [],
        rule: const {'outbound': '@outbound'},
      );
      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'broken',
      );

      final f = expandPreset(rule, preset);

      expect(f.isEmpty, isTrue);
      expect(f.warnings.length, 1);
      expect(f.warnings.first, contains('required var "outbound"'));
    });

    test('фильтр dns_servers — только выбранный tag', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'direct-out', 'dns_server': 'yandex_safe'},
      );

      final f = expandPreset(rule, preset);

      expect(f.dnsServers.length, 1);
      expect(f.dnsServers.first['tag'], 'yandex_safe');
    });

    // §354 — ru-direct БЕЗ var'а `dns_server`: группа зашита литералом в
    // правилах, выбора нет. Эмитим все объявленные серверы — недоэмиссия
    // оставила бы правило со ссылкой в пустоту, а пустая группа = EmptyDnsGroup
    // (fatal до старта ядра).
    group('§354 пресет без var dns_server → эмитим все', () {
      test('группа + три члена, порядок шаблона', () {
        final f = expandPreset(
          CustomRulePreset(
            name: 'X',
            presetId: 'ru-direct',
            varsValues: {'outbound': 'vpn-2'},
          ),
          _ruDirectWithDnsGroup(),
        );

        expect(f.dnsServers.map((s) => s['tag']),
            ['dns_ru', 'yandex_udp', 'yandex_dot', 'yandex_doh']);
        final grp = f.dnsServers.first;
        expect(grp['type'], 'group');
        expect(grp['servers'], ['yandex_udp', 'yandex_dot', 'yandex_doh']);
        expect(grp['mode'], 'fastest');
        // §319: у группы не бывает detour'а.
        expect(grp.containsKey('detour'), isFalse);
      });

      test('три независимых пути: канал / vpn-1 / напрямую', () {
        final f = expandPreset(
          CustomRulePreset(
            name: 'X',
            presetId: 'ru-direct',
            varsValues: {'outbound': 'vpn-2'},
          ),
          _ruDirectWithDnsGroup(),
        );
        Map<String, dynamic> byTag(String t) =>
            f.dnsServers.firstWhere((s) => s['tag'] == t);

        // UDP — по каналу пресета (ровно тот путь, что висел на мёртвой ноде).
        expect(byTag('yandex_udp')['detour'], 'vpn-2');
        // DoT — через vpn-1, НЕ @outbound: шифрован, утечки нет.
        expect(byTag('yandex_dot')['detour'], 'vpn-1');
        // DoH — напрямую: detour снят как direct-out (§117).
        expect(byTag('yandex_doh').containsKey('detour'), isFalse);
      });

      test('правило ссылается на группу литералом, без @-плейсхолдера', () {
        final f = expandPreset(
          CustomRulePreset(
            name: 'X',
            presetId: 'ru-direct',
            varsValues: {'outbound': 'vpn-2'},
          ),
          _ruDirectWithDnsGroup(),
        );

        expect(f.dnsRules.single['server'], 'dns_ru');
      });
    });

    // Контракт §033 для пресетов, у которых var остался (fakeip и пр.):
    // эмитится только выбранный + члены, если выбрана группа.
    group('§354 пресет С var dns_server → только выбранный', () {
      test('одиночный сервер едет один', () {
        final f = expandPreset(
          CustomRulePreset(
            name: 'X',
            presetId: 'ru-direct',
            varsValues: {'outbound': 'vpn-2', 'dns_server': 'yandex_udp'},
          ),
          _ruDirectWithDnsServerVar(),
        );

        expect(f.dnsServers.length, 1);
        expect(f.dnsServers.single['tag'], 'yandex_udp');
      });

      test('выбрана группа → тянет своих членов', () {
        final f = expandPreset(
          CustomRulePreset(
            name: 'X',
            presetId: 'ru-direct',
            varsValues: {'outbound': 'vpn-2', 'dns_server': 'dns_ru'},
          ),
          _ruDirectWithDnsServerVar(),
        );

        expect(f.dnsServers.map((s) => s['tag']),
            ['dns_ru', 'yandex_udp', 'yandex_dot', 'yandex_doh']);
      });

      test('dns_server не выбран → пресет не вносит DNS-серверов', () {
        final preset = _ruDirectWithDnsServerVar();
        final f = expandPreset(
          CustomRulePreset(
            name: 'X',
            presetId: 'ru-direct',
            varsValues: {'outbound': 'vpn-2', 'dns_server': ''},
          ),
          preset,
        );

        expect(f.dnsServers, isEmpty);
      });
    });

    test('remote rule_set + cached path → заменяется на type: local, path',
        () {
      final preset = SelectableRule(
        label: 'Block Ads',
        presetId: 'block-ads',
        ruleSets: [
          {
            'tag': 'ads-all',
            'type': 'remote',
            'format': 'binary',
            'url': 'https://ex.com/ads.srs',
          }
        ],
        rule: const {'rule_set': 'ads-all', 'action': 'reject'},
      );
      final rule = CustomRulePreset(name: 'Block Ads', presetId: 'block-ads');

      final f = expandPreset(rule, preset,
          srsPaths: {'ads-all': '/cache/preset__block-ads__ads-all.srs'});

      expect(f.warnings, isEmpty);
      expect(f.ruleSets.length, 1);
      final rs = f.ruleSets.first;
      expect(rs['type'], 'local', reason: 'remote → local (spec §011)');
      expect(rs['path'], '/cache/preset__block-ads__ads-all.srs');
      expect(rs.containsKey('url'), isFalse);
      expect(rs['tag'], 'ads-all');
    });

    test('remote rule_set + НЕТ cached path → rule_set skipped + warning + '
        'routing_rule тоже dropped (dangling-ref защита)', () {
      final preset = SelectableRule(
        label: 'Block Ads',
        presetId: 'block-ads',
        ruleSets: [
          {'tag': 'ads-all', 'type': 'remote', 'url': 'https://ex.com/ads.srs'}
        ],
        rule: const {'rule_set': 'ads-all', 'action': 'reject'},
      );
      final rule = CustomRulePreset(name: 'Block Ads', presetId: 'block-ads');

      final f = expandPreset(rule, preset); // srsPaths: {}

      expect(f.ruleSets, isEmpty,
          reason: 'без кэша remote rule_set не попадает в конфиг');
      expect(f.routingRules, isEmpty,
          reason: 'rule без своего rule_set → drop, иначе sing-box падает '
              'с "rule-set not found"');
      expect(f.warnings.length, 2,
          reason: 'один warning про rule_set skip, второй про routing_rule skip');
      expect(f.warnings.any((w) => w.contains('no cached file')), isTrue);
      expect(f.warnings.any((w) => w.contains('missing rule_set')), isTrue);
    });

    // ─── §045: GeoIP fallback layer ────────────────────────────────────
    //
    // `rule_set: ["a", "b"]` (массивная форма) + `enabled: "@var"` гейтинг
    // на rule_set entry. 4 матрицы — geoip on/off × .srs cached/missing.
    //
    // Преsett-фабрика — `_ruDirectWithGeoip()` ниже, реплицирует
    // расширенный `ru-direct` из template'а v1.6.2.

    test('§045: geoip on + .srs cached → оба rule_set + array routing rule', () {
      final preset = _ruDirectWithGeoip();
      final rule = CustomRulePreset(
        name: 'Russian',
        presetId: 'ru-direct',
        varsValues: {
          'outbound': 'direct-out',
          'dns_server': 'yandex_udp',
          'geoip_enabled': 'true',
        },
      );

      final f = expandPreset(rule, preset,
          srsPaths: {'geoip-ru': '/cache/preset__ru-direct__geoip-ru.srs'});

      expect(f.warnings, isEmpty);
      expect(f.ruleSets.length, 2);
      expect(f.ruleSets.map((rs) => rs['tag']).toSet(),
          {'ru-domains', 'geoip-ru'});
      // geoip-ru: type конвертирован в local (spec §011)
      final geoip = f.ruleSets.firstWhere((rs) => rs['tag'] == 'geoip-ru');
      expect(geoip['type'], 'local');
      expect(geoip['path'], '/cache/preset__ru-direct__geoip-ru.srs');
      expect(geoip.containsKey('enabled'), isFalse,
          reason: 'enabled — наша мета-конвенция, sing-box не знает');
      // routing rule: массив остался (оба tag'а expanded)
      expect(f.routingRules.single['rule_set'], ['ru-domains', 'geoip-ru']);
      expect(f.routingRules.single['outbound'], 'direct-out');
    });

    test('§045: geoip on + .srs НЕ cached → даунгрейд до single ru-domains '
        '+ warning про missing geoip-ru', () {
      final preset = _ruDirectWithGeoip();
      final rule = CustomRulePreset(
        name: 'Russian',
        presetId: 'ru-direct',
        varsValues: {
          'outbound': 'direct-out',
          'dns_server': 'yandex_udp',
          'geoip_enabled': 'true',
        },
      );

      final f = expandPreset(rule, preset); // srsPaths: {}

      expect(f.ruleSets.length, 1, reason: 'только ru-domains expanded');
      expect(f.ruleSets.first['tag'], 'ru-domains');
      // routing rule даунгрейдился до single string
      expect(f.routingRules.single['rule_set'], 'ru-domains');
      expect(f.routingRules.single['outbound'], 'direct-out');
      // warning про missing geoip-ru
      expect(f.warnings.any((w) => w.contains('geoip-ru') && w.contains('no cached')),
          isTrue);
    });

    test('§045: geoip off (var=false) + .srs cached → geoip-ru фрагмент '
        'пропускается, routing rule даунгрейдится', () {
      final preset = _ruDirectWithGeoip();
      final rule = CustomRulePreset(
        name: 'Russian',
        presetId: 'ru-direct',
        varsValues: {
          'outbound': 'direct-out',
          'dns_server': 'yandex_udp',
          'geoip_enabled': 'false',
        },
      );

      final f = expandPreset(rule, preset,
          srsPaths: {'geoip-ru': '/cache/preset__ru-direct__geoip-ru.srs'});

      expect(f.warnings, isEmpty,
          reason: 'enabled=false — это намеренная конфигурация, не warning');
      expect(f.ruleSets.length, 1, reason: 'geoip-ru gated за enabled var');
      expect(f.ruleSets.first['tag'], 'ru-domains');
      // routing rule даунгрейдился до single string (geoip-ru не в expandedTags)
      expect(f.routingRules.single['rule_set'], 'ru-domains');
    });

    test('§045: geoip off + .srs НЕ cached → geoip-ru пропускается без '
        'warning (gated раньше чем cache check)', () {
      final preset = _ruDirectWithGeoip();
      final rule = CustomRulePreset(
        name: 'Russian',
        presetId: 'ru-direct',
        varsValues: {
          'outbound': 'direct-out',
          'dns_server': 'yandex_udp',
          'geoip_enabled': 'false',
        },
      );

      final f = expandPreset(rule, preset); // srsPaths: {}

      expect(f.warnings, isEmpty,
          reason: 'gated rule_set не доходит до cache-check warning');
      expect(f.ruleSets.length, 1);
      expect(f.routingRules.single['rule_set'], 'ru-domains');
    });

    test('§045: enabled bool literal true → фрагмент включается', () {
      final preset = SelectableRule(
        label: 'X',
        presetId: 'x',
        ruleSets: [
          {'tag': 'a', 'type': 'inline', 'rules': [], 'enabled': true}
        ],
        rule: const {'rule_set': 'a', 'outbound': 'direct-out'},
      );
      final f = expandPreset(CustomRulePreset(name: 'X', presetId: 'x'), preset);
      expect(f.ruleSets.length, 1);
      expect(f.ruleSets.first.containsKey('enabled'), isFalse,
          reason: 'мета-поле strip перед попаданием в config');
    });

    test('§045: enabled bool literal false → фрагмент пропускается', () {
      final preset = SelectableRule(
        label: 'X',
        presetId: 'x',
        ruleSets: [
          {'tag': 'a', 'type': 'inline', 'rules': [], 'enabled': false}
        ],
        rule: const {'rule_set': 'a', 'outbound': 'direct-out'},
      );
      final f = expandPreset(CustomRulePreset(name: 'X', presetId: 'x'), preset);
      expect(f.ruleSets, isEmpty);
      expect(f.routingRules, isEmpty,
          reason: 'rule_set не expanded → dangling guard дропнул rule');
    });

    test('§045: rule.rule_set массив, оба tag\'а missing → rule dropped + warning', () {
      final preset = SelectableRule(
        label: 'X',
        presetId: 'x',
        ruleSets: [
          {'tag': 'a', 'type': 'remote', 'url': 'https://ex.com/a.srs'},
          {'tag': 'b', 'type': 'remote', 'url': 'https://ex.com/b.srs'},
        ],
        rule: const {'rule_set': ['a', 'b'], 'outbound': 'direct-out'},
      );
      final f = expandPreset(CustomRulePreset(name: 'X', presetId: 'x'), preset);
      expect(f.ruleSets, isEmpty);
      expect(f.routingRules, isEmpty);
      expect(f.warnings.any((w) => w.contains('none of') && w.contains('a') && w.contains('b')),
          isTrue);
    });

    // Universal outbound override (spec §033 §5 / task 011) — `varsValues['outbound']`
    // всегда побеждает template-решение. Ветки: empty → as-is, "reject" → action,
    // иначе → outbound. Ниже три теста на эти ветки + кейс «template hardcoded
    // action: reject, юзер override'нул в vpn-tag».

    test('outbound override == "reject" → action:reject, outbound удаляется', () {
      final preset = _ruDirect();
      final rule = CustomRulePreset(
        name: 'Block Russian',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'reject', 'dns_server': 'yandex_doh'},
      );

      final f = expandPreset(rule, preset);
      expect(f.routingRules.single, {'rule_set': 'ru-domains', 'action': 'reject'});
      expect(f.routingRules.single.containsKey('outbound'), isFalse);
    });

    test('outbound override == vpn-tag → outbound set, action удаляется '
        '(даже если template был action:reject)', () {
      // Block Ads-like preset: `rule: {rule_set, action: reject}` без `@outbound`.
      final preset = SelectableRule(
        label: 'Block ads',
        presetId: 'block-ads',
        vars: [],
        ruleSets: [
          {'tag': 'ads', 'type': 'inline', 'format': 'domain', 'rules': []},
        ],
        rule: const {'rule_set': 'ads', 'action': 'reject'},
      );
      final rule = CustomRulePreset(
        name: 'Ads via vpn',
        presetId: 'block-ads',
        varsValues: {'outbound': 'vpn-1'}, // override — pipe ads через vpn
      );

      final f = expandPreset(rule, preset);
      expect(f.routingRules.single, {'rule_set': 'ads', 'outbound': 'vpn-1'});
      expect(f.routingRules.single.containsKey('action'), isFalse);
    });

    test('outbound override пустой → template-решение остаётся', () {
      // Block Ads без override — template'ный action:reject должен дойти.
      final preset = SelectableRule(
        label: 'Block ads',
        presetId: 'block-ads',
        vars: [],
        ruleSets: [
          {'tag': 'ads', 'type': 'inline', 'format': 'domain', 'rules': []},
        ],
        rule: const {'rule_set': 'ads', 'action': 'reject'},
      );
      final rule = CustomRulePreset(
        name: 'Block ads',
        presetId: 'block-ads',
        varsValues: {}, // outbound не задан вообще
      );

      final f = expandPreset(rule, preset);
      expect(f.routingRules.single, {'rule_set': 'ads', 'action': 'reject'});
    });

    // §162 регресс — `@outbound`-форма + var.default_value: "reject".
    // unknown-traffic (§033) задаёт `rule.outbound: "@outbound"` и дефолт
    // "reject". Если юзер ВКЛЮЧИЛ пресет, но не открывал OutboundPicker,
    // ключа в varsValues нет → override-ветка пропускается, а substitute уже
    // подставил @outbound → "reject" в поле `outbound`. До фикса литерал
    // `outbound: "reject"` уезжал в route.rules → fatal (DanglingOutboundRef).
    // Backstop в expandPreset нормализует reject→action независимо от того,
    // пришло оно override'ом или дефолтом.
    test('§162 default_value=="reject" в @outbound (пикер не трогали) → '
        'action:reject, НЕ outbound:reject', () {
      final preset = SelectableRule(
        label: 'Unknown traffic',
        presetId: 'unknown-traffic',
        vars: [
          WizardVar(
            name: 'outbound',
            type: 'outbound',
            defaultValue: 'reject', // дефолт = drop
          ),
        ],
        ruleSets: [
          {
            'tag': 'unknown-apps',
            'type': 'inline',
            'rules': [
              {'invert': true, 'package_name_regex': '^'},
            ],
          },
        ],
        rule: const {'rule_set': 'unknown-apps', 'outbound': '@outbound'},
      );
      final rule = CustomRulePreset(
        name: 'Unknown traffic',
        presetId: 'unknown-traffic',
        varsValues: {}, // ВКЛючён, но пикер не открывали → ключа outbound нет
      );

      final f = expandPreset(rule, preset);
      expect(f.routingRules.single, {'rule_set': 'unknown-apps', 'action': 'reject'});
      expect(f.routingRules.single.containsKey('outbound'), isFalse,
          reason: 'sing-box не принимает outbound:"reject" — это action');
    });

    test('unknown @name (не объявлен в vars) → остаётся как литерал', () {
      // Legacy / typo: шаблон ссылается на @foo, в `vars` такого нет.
      // _substitute должен вернуть строку как есть (не крашить).
      final preset = SelectableRule(
        label: 'Legacy',
        presetId: 'legacy',
        vars: [],
        ruleSets: [
          {'tag': 'x', 'type': 'inline', 'format': 'domain', 'rules': []},
        ],
        rule: const {'rule_set': 'x', 'outbound': '@foo'},
      );
      final rule = CustomRulePreset(
        name: 'Legacy',
        presetId: 'legacy',
        varsValues: {},
      );

      final f = expandPreset(rule, preset);
      // Правило проходит валидацию (outbound is String), значение не
      // разрезолвлено — это осознанный pass-through (см. _substitute docstring).
      expect(f.routingRules.single, {'rule_set': 'x', 'outbound': '@foo'});
    });

    test('deep-copy isolation: source preset не мутируется после expansion', () {
      final preset = _ruDirect();
      final originalRuleSet = Map<String, dynamic>.from(preset.ruleSets.first);
      final originalRules = preset.rules
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
      final originalDnsServers = preset.dnsServers
          .map((s) => Map<String, dynamic>.from(s))
          .toList();

      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'ru-direct',
        varsValues: {'outbound': 'vpn-1', 'dns_server': 'yandex_doh'},
      );
      expandPreset(rule, preset);

      expect(preset.ruleSets.first, originalRuleSet,
          reason: 'rule_set в шаблоне не должен мутироваться');
      expect(preset.rules, originalRules,
          reason: 'rule в шаблоне не должен мутироваться');
      expect(preset.dnsServers, originalDnsServers,
          reason: 'dns_servers в шаблоне не должны мутироваться');
    });

    test('routing rule без outbound/action после substitute → dropped', () {
      final preset = SelectableRule(
        label: 'Weird',
        presetId: 'weird',
        vars: [
          WizardVar(
            name: 'target',
            type: 'outbound',
            defaultValue: '',
            required: false,
          ),
        ],
        rule: const {'rule_set': 'x', 'outbound': '@target'},
      );
      final rule = CustomRulePreset(
        name: 'X',
        presetId: 'weird',
      );

      final f = expandPreset(rule, preset);

      expect(f.routingRules, isEmpty);
    });
  });

  group('mergeFragments (spec §033)', () {
    test('identical skip по tag', () {
      final f1 = PresetFragments(
        dnsServers: [
          {'tag': 'yandex_doh', 'type': 'https', 'server': 'a'}
        ],
        ruleSets: [
          {
            'tag': 'ru-domains',
            'type': 'inline',
            'rules': [
              {
                'domain_suffix': ['ru']
              }
            ]
          }
        ],
      );
      final f2 = PresetFragments(
        dnsServers: [
          {'tag': 'yandex_doh', 'type': 'https', 'server': 'a'}
        ],
        ruleSets: [
          {
            'tag': 'ru-domains',
            'type': 'inline',
            'rules': [
              {
                'domain_suffix': ['ru']
              }
            ]
          }
        ],
      );

      final m = mergeFragments([f1, f2]);
      expect(m.dnsServers.length, 1);
      expect(m.ruleSets.length, 1);
      expect(m.warnings, isEmpty);
    });

    test('real conflict — first-wins + warning', () {
      final f1 = PresetFragments(dnsServers: [
        {'tag': 'yandex_doh', 'type': 'https', 'server': 'a'}
      ]);
      final f2 = PresetFragments(dnsServers: [
        {'tag': 'yandex_doh', 'type': 'https', 'server': 'b'}
      ]);

      final m = mergeFragments([f1, f2]);
      expect(m.dnsServers.length, 1);
      expect(m.dnsServers.first['server'], 'a');
      expect(m.warnings.length, 1);
      expect(m.warnings.first, contains('yandex_doh'));
    });

    test('dns_rules и routing_rules append без dedup', () {
      final f1 = PresetFragments(
        dnsRules: [
          {'rule_set': 'ru-domains', 'server': 'a'}
        ],
        routingRules: [
          {'rule_set': 'ru-domains', 'outbound': 'direct-out'}
        ],
      );
      final f2 = PresetFragments(
        dnsRules: [
          {'rule_set': 'x', 'server': 'b'}
        ],
        routingRules: [
          {'rule_set': 'x', 'outbound': 'vpn-1'}
        ],
      );

      final m = mergeFragments([f1, f2]);
      expect(m.dnsRules.length, 2);
      expect(m.routingRules.length, 2);
    });

    test('порядок детерминирован — bundle A затем B', () {
      final a = PresetFragments(dnsServers: [
        {'tag': 'a', 'type': 'udp'}
      ]);
      final b = PresetFragments(dnsServers: [
        {'tag': 'b', 'type': 'udp'}
      ]);

      final ab = mergeFragments([a, b]);
      expect(ab.dnsServers.map((s) => s['tag']).toList(), ['a', 'b']);

      final ba = mergeFragments([b, a]);
      expect(ba.dnsServers.map((s) => s['tag']).toList(), ['b', 'a']);
    });
  });

  // §228 — FakeIP: DNS-only пресет. Сервер вливается через hidden-var
  // `dns_server` (магическая переменная), правило ссылается на него через
  // @dns_server. Регрессия: без var сервер не эмитился, правило висло в
  // пустоту и молча дропалось.
  group('expandPreset — FakeIP (§228)', () {
    test('сервер fakeip эмитится через hidden-var default; правило ссылается '
        'на него (юзер var не трогает)', () {
      final preset = _fakeip();
      final rule = CustomRulePreset(
        name: 'FakeIP',
        presetId: 'fakeip',
        varsValues: const {}, // hidden-var → значение из default_value
      );

      final f = expandPreset(rule, preset);

      expect(f.warnings, isEmpty);
      // Сервер вливается — не пустой список (регрессия #228).
      expect(f.dnsServers.length, 1);
      expect(f.dnsServers.first['tag'], 'fakeip');
      expect(f.dnsServers.first['type'], 'fakeip');
      // Правило ссылается на реально эмитнутый сервер (не dangling).
      expect(f.dnsRules.single, {
        'query_type': ['A', 'AAAA'],
        'server': 'fakeip',
      });
      // DNS-only: routing rule нет.
      expect(f.routingRules, isEmpty);
    });

    test('hasOutboundAffordance == false (нечего роутить → нет picker)', () {
      expect(_fakeip().hasOutboundAffordance, isFalse);
    });

    // §266 — РЕАЛЬНЫЙ шаблон (не реплика): регрессия «rule_enable без
    // default_value = required-var unset → expandPreset прерывал весь пресет,
    // fakeip-DNS не эмитился». Синтетический _fakeip() это не ловил (нет
    // rule_enable). Гоняем настоящий wizard_template.json.
    test('РЕАЛЬНЫЙ fakeip: dns_servers + dns_rules эмитятся (rule_enable не '
        'ломает развёртку)', () {
      final raw = File('assets/wizard_template.json').readAsStringSync();
      final tpl =
          WizardTemplate.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      final fakeip =
          tpl.selectableRules.firstWhere((r) => r.presetId == 'fakeip');
      final cr = CustomRulePreset(
          name: 'FakeIP', presetId: 'fakeip', enabled: true);
      final f = expandPreset(cr, fakeip, globalVars: {'vpn_mode': 'vpn'});
      expect(f.warnings, isEmpty, reason: 'rule_enable не должна ронять пресет');
      expect(f.dnsServers.any((s) => s['type'] == 'fakeip'), isTrue);
      expect(f.dnsRules.isNotEmpty, isTrue);
    });

    test('ru-direct.hasOutboundAffordance == true (есть var:outbound и rule)',
        () {
      expect(_ruDirect().hasOutboundAffordance, isTrue);
    });

    // §231 — touchesDns: чип «DNS» в списке правил.
    test('touchesDns: fakeip (dns_rule+dns_server) и ru-direct → true', () {
      expect(_fakeip().touchesDns, isTrue);
      expect(_ruDirect().touchesDns, isTrue);
    });

    test('touchesDns: пресет без dns_rule/dns_servers → false', () {
      final noDns = SelectableRule(
        label: 'X',
        presetId: 'x',
        rule: const {'protocol': 'bittorrent', 'outbound': 'direct-out'},
      );
      expect(noDns.touchesDns, isFalse);
    });
  });

  // §246 — `rule` как массив route-правил: пресет эмитит несколько правил
  // в порядке шаблона. Мотивация: ru-direct эмитит пару
  // `[resolve ipv4_only (#if @outbound==direct-out), route]` — IPv4-only
  // резолв только для direct-ветки (устройства без глобального IPv6),
  // туннельный IPv6 не режется.
  group('expandPreset — rule массив (§246)', () {
    test('дефолт (direct-out) → resolve+route, порядок сохранён', () {
      final f = expandPreset(
        CustomRulePreset(name: 'X', presetId: 'ru-direct'),
        _ruDirectArray(),
      );

      expect(f.warnings, isEmpty);
      expect(f.routingRules.length, 2);
      expect(f.routingRules[0], {
        'rule_set': 'ru-domains',
        'action': 'resolve',
        'strategy': 'ipv4_only',
      });
      expect(f.routingRules[1],
          {'rule_set': 'ru-domains', 'outbound': 'direct-out'});
    });

    test('override vpn-1 → #if-гейт роняет resolve; route получает override',
        () {
      final f = expandPreset(
        CustomRulePreset(
          name: 'X',
          presetId: 'ru-direct',
          varsValues: {'outbound': 'vpn-1'},
        ),
        _ruDirectArray(),
      );

      expect(f.warnings, isEmpty);
      expect(f.routingRules.single,
          {'rule_set': 'ru-domains', 'outbound': 'vpn-1'},
          reason: 'resolve ipv4_only вреден в туннеле (IPv6 там живёт) — '
              '#if-гейт эмитит его только при direct-out');
    });

    test('override reject → терминальный action:reject, промежуточный '
        'resolve не тронут override\'ом', () {
      // Без #if-гейта: resolve эмитится всегда — override его не подменяет
      // (иначе `action: resolve` стал бы outbound'ом юзера и убил семантику).
      final preset = SelectableRule(
        label: 'X',
        presetId: 'x',
        ruleSets: [
          {'tag': 'a', 'type': 'inline', 'rules': []},
        ],
        rule: const [
          {'rule_set': 'a', 'action': 'resolve', 'strategy': 'ipv4_only'},
          {'rule_set': 'a', 'outbound': 'direct-out'},
        ],
      );
      final f = expandPreset(
        CustomRulePreset(
            name: 'X', presetId: 'x', varsValues: {'outbound': 'reject'}),
        preset,
      );

      expect(f.routingRules.length, 2);
      expect(f.routingRules[0],
          {'rule_set': 'a', 'action': 'resolve', 'strategy': 'ipv4_only'});
      expect(f.routingRules[1], {'rule_set': 'a', 'action': 'reject'});
    });

    test('dangling rule_set в одном элементе → дропается только он + warning',
        () {
      final preset = SelectableRule(
        label: 'X',
        presetId: 'x',
        ruleSets: [
          {'tag': 'a', 'type': 'inline', 'rules': []},
        ],
        rule: const [
          {'rule_set': 'missing', 'action': 'resolve', 'strategy': 'ipv4_only'},
          {'rule_set': 'a', 'outbound': 'direct-out'},
        ],
      );
      final f = expandPreset(
        CustomRulePreset(name: 'X', presetId: 'x'),
        preset,
      );

      expect(f.routingRules.single,
          {'rule_set': 'a', 'outbound': 'direct-out'});
      expect(
        f.warnings.any((w) => w.contains('missing rule_set "missing"')),
        isTrue,
      );
    });

    test('force_ipv4=false → resolve-элемент выпадает, остаётся только route',
        () {
      final f = expandPreset(
        CustomRulePreset(
          name: 'X',
          presetId: 'ru-direct',
          varsValues: {'force_ipv4': 'false'},
        ),
        _ruDirectForceIpv4(),
      );

      expect(f.warnings, isEmpty);
      expect(f.routingRules.single,
          {'rule_set': 'ru-domains', 'outbound': 'direct-out'},
          reason: 'галка off → ipv4-резолв не эмитится (юзер сам решил)');
    });

    test('force_ipv4=true (дефолт) → resolve ipv4_only + route', () {
      final f = expandPreset(
        CustomRulePreset(name: 'X', presetId: 'ru-direct'),
        _ruDirectForceIpv4(),
      );

      expect(f.routingRules.length, 2);
      expect(f.routingRules[0]['action'], 'resolve');
      expect(f.routingRules[0]['strategy'], 'ipv4_only');
    });

    test('terminalRule: у массива — терминальный элемент (не resolve)', () {
      expect(_ruDirectArray().terminalRule,
          {'rule_set': 'ru-domains', 'outbound': '@outbound'});
    });

    test('SelectableRule.fromJson: rule-массив нормализуется в rules', () {
      final sr = SelectableRule.fromJson({
        'preset_id': 'x',
        'ui': {'label': 'X'},
        'rule': [
          {'rule_set': 'a', 'action': 'resolve', 'strategy': 'ipv4_only'},
          {'rule_set': 'a', 'outbound': 'direct-out'},
        ],
      });
      expect(sr.rules.length, 2);
      expect(sr.terminalRule, {'rule_set': 'a', 'outbound': 'direct-out'});
    });

    test('SelectableRule.fromJson: канонический ключ "rules" (массив) — '
        'как в шаблоне ru-direct', () {
      final sr = SelectableRule.fromJson({
        'preset_id': 'x',
        'ui': {'label': 'X'},
        'rules': [
          {'rule_set': 'a', 'action': 'resolve', 'strategy': 'ipv4_only'},
          {'rule_set': 'a', 'outbound': 'direct-out'},
        ],
      });
      expect(sr.rules.length, 2,
          reason: 'ключ "rules" должен читаться (регрессия: пресет молча '
              'терял все правила, ни warning, ни route.rules)');
      expect(sr.terminalRule, {'rule_set': 'a', 'outbound': 'direct-out'});
    });

    test('SelectableRule.fromJson: legacy Map → один элемент rules', () {
      final sr = SelectableRule.fromJson({
        'preset_id': 'x',
        'ui': {'label': 'X'},
        'rule': {'rule_set': 'a', 'outbound': 'direct-out'},
      });
      expect(sr.rules.single, {'rule_set': 'a', 'outbound': 'direct-out'});
      expect(sr.terminalRule, {'rule_set': 'a', 'outbound': 'direct-out'});
    });

    test('SelectableRule.fromJson: rule отсутствует → rules пуст, '
        'terminalRule пустой Map', () {
      final sr = SelectableRule.fromJson({'preset_id': 'x', 'ui': {'label': 'X'}});
      expect(sr.rules, isEmpty);
      expect(sr.terminalRule, isEmpty);
    });
  });

  // §246 e2e — НАСТОЯЩИЙ wizard_template.json (не синтетическая реплика).
  // Регрессия первого прогона: движок читал ключ `rule`, шаблон использовал
  // `rules` → пресет молча терял все правила (ни warning, ни route.rules),
  // синтетические тесты этого не ловили.
  group('§246 e2e — реальный wizard_template.json', () {
    SelectableRule realPreset(String presetId) {
      final raw = File('assets/wizard_template.json').readAsStringSync();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final rules = (json['selectable_rules'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .toList();
      final found =
          rules.firstWhere((r) => r['preset_id'] == presetId, orElse: () => {});
      expect(found, isNotEmpty, reason: 'preset "$presetId" есть в шаблоне');
      return SelectableRule.fromJson(found);
    }

    test('ru-direct (дефолты: force_ipv4=true) → пара resolve+route; '
        'dns_rule БЕЗ strategy', () {
      final preset = realPreset('ru-direct');
      final f = expandPreset(
        CustomRulePreset(name: 'RU', presetId: 'ru-direct'),
        preset,
      );

      // geoip-ru — remote без кэша: терминальное правило даунгрейдится до
      // inline-набора, warning про geoip-ru ожидаем; правил всё равно ДВА.
      expect(f.routingRules.length, 2,
          reason: 'resolve + route; 0 или 1 = движок потерял правило '
              '(регрессия rule/rules-ключа)');
      final resolve = f.routingRules[0];
      expect(resolve['action'], 'resolve');
      expect(resolve['strategy'], 'ipv4_only');
      expect(resolve['server'], 'dns_ru',
          reason: 'server из default dns_server — §354 группа (битую ссылку '
              'при выключенном DNS-аспекте снимает '
              'healDanglingResolveServers)');
      expect(resolve['rule_set'], ['ru-domains', 'ru-services']);
      final route = f.routingRules[1];
      expect(route['outbound'], 'direct-out');
      expect(route.containsKey('action'), isFalse);

      // ⚠ Легаси-опция strategy в dns rule deprecated (ядро 1.14,
      // resolveLegacyDNSMode fatal при query_type/ip_version в конфиге) —
      // её нет нигде. §253: DNS-слой Force IPv4 = пара правил:
      // [AAAA-гейт predefined NOERROR (ip_version: 6), маршрут].
      expect(f.dnsRules.length, 2,
          reason: 'AAAA-гейт + маршрут; 1 = #if-гейт потерян '
              '(регрессия dns_rule/dns_rules-ключа)');
      final gate = f.dnsRules[0];
      expect(gate['ip_version'], 6);
      expect(gate['action'], 'predefined');
      expect(gate['rcode'], 'NOERROR');
      expect(gate['rule_set'], ['ru-domains', 'ru-services']);
      expect(gate.containsKey('server'), isFalse,
          reason: 'serverless-действие — predefined отвечает сам');
      expect(gate.containsKey('strategy'), isFalse);
      final dnsRoute = f.dnsRules[1];
      expect(dnsRoute['server'], 'dns_ru');
      expect(dnsRoute.containsKey('ip_version'), isFalse,
          reason: 'маршрут безусловный — не-A/AAAA-запросы (HTTPS type 65) '
              'тоже должны идти в @dns_server');
      expect(dnsRoute.containsKey('strategy'), isFalse,
          reason: 'strategy в dns rule = fatal при включённом FakeIP');
    });

    // §354 — на РЕАЛЬНОМ шаблоне: дефолтная группа приезжает с членами.
    // Пустая группа = EmptyDnsGroup (fatal), поэтому проверяем на живом JSON,
    // а не только на фикстуре.
    test('ru-direct (дефолты) → dns_ru + три члена по разным путям', () {
      final f = expandPreset(
        CustomRulePreset(
          name: 'RU',
          presetId: 'ru-direct',
          varsValues: {'outbound': 'vpn-2'},
        ),
        realPreset('ru-direct'),
      );

      expect(f.dnsServers.map((s) => s['tag']),
          ['dns_ru', 'yandex_udp', 'yandex_dot', 'yandex_doh']);
      Map<String, dynamic> byTag(String t) =>
          f.dnsServers.firstWhere((s) => s['tag'] == t);

      final grp = byTag('dns_ru');
      expect(grp['servers'], ['yandex_udp', 'yandex_dot', 'yandex_doh']);
      expect(grp['mode'], 'fastest');
      expect(grp.containsKey('detour'), isFalse, reason: '§319');

      // Три НЕзависимых пути отказа — иначе одна мёртвая нода вешает ru-DNS.
      // UDP — по каналу пресета (открытый, но идёт туда же, куда трафик);
      // DoT — через vpn-1; DoH — напрямую. Оба шифрованных пути не зависят
      // от @outbound, поэтому мёртвая нода в нём их не трогает.
      expect(byTag('yandex_udp')['detour'], 'vpn-2');
      expect(byTag('yandex_dot')['detour'], 'vpn-1');
      expect(byTag('yandex_doh').containsKey('detour'), isFalse,
          reason: 'direct-out → detour снят (§117)');
    });

    // §354 — сквозь ОБА слоя: expandPreset → эмиссионный фильтр §312. Именно
    // здесь группа могла приехать пустой (члены выброшены как unknown →
    // EmptyDnsGroup, fatal до старта ядра), а expandPreset в одиночку это не
    // ловит.
    test('ru-direct → эмиссия: группа доезжает с членами, без дропов', () {
      final f = expandPreset(
        CustomRulePreset(
          name: 'RU',
          presetId: 'ru-direct',
          varsValues: {'outbound': 'vpn-2'},
        ),
        realPreset('ru-direct'),
      );

      final presetServersByTag = {
        for (final s in f.dnsServers) s['tag'] as String: s,
      };
      final warnings = <String>[];
      final emitted = resolveDnsServersBodies(
        resolved: [
          for (final s in f.dnsServers)
            {'kind': 'preset', 'tag': s['tag'], 'enabled': true},
        ],
        templateByTag: const {},
        presetServersByTag: presetServersByTag,
        knownOutboundTags: {'vpn-1', 'vpn-2', 'direct-out'},
        warningsOut: warnings,
      );

      final grp = emitted.firstWhere((s) => s['tag'] == 'dns_ru');
      expect(grp['servers'], ['yandex_udp', 'yandex_dot', 'yandex_doh'],
          reason: 'ни один член не выброшен фильтром §312');
      expect(warnings, isEmpty, reason: 'дропов быть не должно');
    });

    test('ru-direct: force_ipv4=false → route без resolve, DNS без AAAA-гейта',
        () {
      final preset = realPreset('ru-direct');
      final f = expandPreset(
        CustomRulePreset(
          name: 'RU',
          presetId: 'ru-direct',
          varsValues: {'force_ipv4': 'false'},
        ),
        preset,
      );
      // Галка off → resolve-элемент выпал, остался только терминальный route.
      expect(f.routingRules.length, 1);
      expect(f.routingRules.single['outbound'], 'direct-out');
      // §253: AAAA-гейт выпал целиком (array-element #if), маршрут остался.
      expect(f.dnsRules.length, 1);
      expect(f.dnsRules.single['server'], 'dns_ru');
      expect(f.dnsRules.single.containsKey('ip_version'), isFalse);
      expect(f.dnsRules.single.containsKey('strategy'), isFalse);
    });

    test('ru-direct: force_ipv4=false → только route', () {
      final preset = realPreset('ru-direct');
      final f = expandPreset(
        CustomRulePreset(
          name: 'RU',
          presetId: 'ru-direct',
          varsValues: {'force_ipv4': 'false'},
        ),
        preset,
      );
      expect(f.routingRules.length, 1);
      expect(f.routingRules.single['outbound'], 'direct-out');
    });

    test('ru-inside (srs закэширован) → пара resolve+route', () {
      final preset = realPreset('ru-inside');
      final f = expandPreset(
        CustomRulePreset(name: 'RU inside', presetId: 'ru-inside'),
        preset,
        srsPaths: {'ru-inside': '/cache/ru-inside.srs'},
      );
      expect(f.routingRules.length, 2);
      expect(f.routingRules[0]['action'], 'resolve');
      expect(f.routingRules[0]['strategy'], 'ipv4_only');
      expect(f.routingRules[0].containsKey('server'), isFalse,
          reason: 'ru-inside resolve без server — резолв через DNS-роутинг');
      expect(f.routingRules[1]['outbound'], 'direct-out');
    });
  });

  // §253 — механика dns_rules-массива: валидность элементов + guards.
  group('expandPreset — dns_rules array (§253)', () {
    test('элемент без server, но с serverless-action (predefined) выживает; '
        'без server и без action — дропается', () {
      final preset = SelectableRule(
        label: 'X',
        presetId: 'x',
        ruleSets: [
          {
            'tag': 'rs',
            'type': 'inline',
            'rules': [
              {
                'domain_suffix': ['ru']
              }
            ],
          },
        ],
        dnsRule: const [
          {'rule_set': 'rs', 'action': 'predefined', 'rcode': 'NOERROR'},
          {'rule_set': 'rs'}, // ни server, ни action → drop
          // action вне закрытого serverless-списка (у ядра evaluate без
          // server = fatal, опечатка = decode error) → drop.
          {'rule_set': 'rs', 'action': 'evaluate'},
        ],
      );
      final f = expandPreset(
        CustomRulePreset(name: 'X', presetId: 'x'),
        preset,
      );
      expect(f.dnsRules.length, 1);
      expect(f.dnsRules.single['action'], 'predefined');
    });

    test('невалидная форма rule_set (int) → ссылка снимается, правило живёт '
        '(паритет §219 с route-правилами)', () {
      final preset = SelectableRule(
        label: 'X',
        presetId: 'x',
        dnsRule: const [
          {'rule_set': 42, 'action': 'predefined', 'rcode': 'NOERROR'},
        ],
      );
      final f = expandPreset(
        CustomRulePreset(name: 'X', presetId: 'x'),
        preset,
      );
      expect(f.dnsRules.single.containsKey('rule_set'), isFalse);
      expect(f.dnsRules.single['action'], 'predefined');
      expect(f.warnings.any((w) => w.contains('invalid')), isTrue);
    });

    test('dangling rule_set в DNS-правиле → правило дропается с warning', () {
      final preset = SelectableRule(
        label: 'X',
        presetId: 'x',
        ruleSets: [
          {
            'tag': 'cached',
            'type': 'inline',
            'rules': [
              {
                'domain_suffix': ['ru']
              }
            ],
          },
        ],
        dnsRule: const [
          {'rule_set': 'missing-srs', 'action': 'predefined'},
          // массив-форма: выживший один tag даунгрейдится до String
          {
            'rule_set': ['cached', 'missing-srs'],
            'action': 'predefined',
          },
        ],
      );
      final f = expandPreset(
        CustomRulePreset(name: 'X', presetId: 'x'),
        preset,
      );
      expect(f.dnsRules.length, 1);
      expect(f.dnsRules.single['rule_set'], 'cached');
      expect(f.warnings.any((w) => w.contains('missing-srs')), isTrue);
    });

    test('SelectableRule: dns_rules (List) из JSON нормализуется; '
        'legacy dns_rule (Map) — тоже', () {
      final fromList = SelectableRule.fromJson({
        'preset_id': 'x',
        'ui': {'label': 'X'},
        'dns_rules': [
          {'rule_set': 'a', 'server': 's'},
          {'rule_set': 'a', 'action': 'predefined'},
        ],
      });
      expect(fromList.dnsRules.length, 2);
      expect(fromList.touchesDns, isTrue);

      final fromMap = SelectableRule.fromJson({
        'preset_id': 'x',
        'ui': {'label': 'X'},
        'dns_rule': {'rule_set': 'a', 'server': 's'},
      });
      expect(fromMap.dnsRules.length, 1);
      expect(fromMap.touchesDns, isTrue);
    });

    test('оба ключа сразу → dns_rules побеждает dns_rule (контракт TEMPLATE.md)',
        () {
      final r = SelectableRule.fromJson({
        'preset_id': 'x',
        'ui': {'label': 'X'},
        'dns_rule': {'rule_set': 'legacy', 'server': 's'},
        'dns_rules': [
          {'rule_set': 'a', 'server': 's'},
          {'rule_set': 'a', 'action': 'predefined'},
        ],
      });
      expect(r.dnsRules.length, 2);
      expect(r.dnsRules.first['rule_set'], 'a');
    });
  });
}

/// §246: реплика `ru-direct` с гейтом resolve по bool-var `force_ipv4`
/// (default true). Галка off → resolve-элемент выпадает.
SelectableRule _ruDirectForceIpv4() => SelectableRule(
      label: 'Russian domains & IPs',
      presetId: 'ru-direct',
      vars: [
        WizardVar(
          name: 'outbound',
          type: 'outbound',
          defaultValue: 'direct-out',
          title: 'Outbound',
        ),
        WizardVar(
          name: 'force_ipv4',
          type: 'bool',
          defaultValue: 'true',
          title: 'Force IPv4',
        ),
      ],
      ruleSets: [
        {
          'tag': 'ru-domains',
          'type': 'inline',
          'rules': [
            {
              'domain_suffix': ['ru']
            }
          ],
        },
      ],
      rule: const [
        {
          '#if': {
            'and': ['@force_ipv4'],
            'value': {
              'rule_set': 'ru-domains',
              'action': 'resolve',
              'strategy': 'ipv4_only',
            },
          },
        },
        {'rule_set': 'ru-domains', 'outbound': '@outbound'},
      ],
    );

/// §246: реплика `ru-direct` из шаблона с rule-массивом —
/// `[resolve ipv4_only под #if-гейтом, терминальный route]`.
SelectableRule _ruDirectArray() => SelectableRule(
      label: 'Russian domains & IPs',
      presetId: 'ru-direct',
      vars: [
        WizardVar(
          name: 'outbound',
          type: 'outbound',
          defaultValue: 'direct-out',
          title: 'Outbound',
        ),
      ],
      ruleSets: [
        {
          'tag': 'ru-domains',
          'type': 'inline',
          'rules': [
            {
              'domain_suffix': ['ru']
            }
          ],
        },
      ],
      rule: const [
        {
          '#if': {
            'and': [
              {'@outbound': 'direct-out'}
            ],
            'value': {
              'rule_set': 'ru-domains',
              'action': 'resolve',
              'strategy': 'ipv4_only',
            },
          },
        },
        {'rule_set': 'ru-domains', 'outbound': '@outbound'},
      ],
    );

/// Фабрика — реплика `FakeIP` пресета из шаблона (§228).
SelectableRule _fakeip() => SelectableRule(
      label: 'FakeIP',
      description: 'Instant DNS via placeholder IPs.',
      presetId: 'fakeip',
      vars: [
        WizardVar(
          name: 'dns_server',
          type: 'dns_servers',
          defaultValue: 'fakeip',
          wizardUI: 'hidden',
          title: 'FakeIP server',
        ),
      ],
      dnsRule: const {
        'query_type': ['A', 'AAAA'],
        'server': '@dns_server',
      },
      dnsServers: [
        {
          'type': 'fakeip',
          'tag': 'fakeip',
          'inet4_range': '198.18.0.0/15',
          'inet6_range': 'fc00::/18',
          'description': 'FakeIP allocator',
        },
      ],
    );

/// Фабрика — сокращённая реплика `Russian domains direct` из шаблона.
SelectableRule _ruDirect() => SelectableRule(
      label: 'Russian domains direct',
      description: 'Route Russian & Cyrillic TLDs directly.',
      defaultEnabled: true,
      presetId: 'ru-direct',
      vars: [
        WizardVar(
          name: 'outbound',
          type: 'outbound',
          defaultValue: 'direct-out',
          title: 'Outbound',
        ),
        WizardVar(
          name: 'dns_server',
          type: 'dns_servers',
          defaultValue: 'yandex_doh',
          required: false,
          title: 'DNS server',
        ),
      ],
      ruleSets: [
        {
          'tag': 'ru-domains',
          'type': 'inline',
          'format': 'domain_suffix',
          'rules': [
            {
              'domain_suffix': ['ru', 'xn--p1ai']
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
        {
          'type': 'udp',
          'tag': 'yandex_safe',
          'server': '77.88.8.88',
          'detour': '@outbound',
          'description': 'Yandex Safe',
        },
      ],
    );

/// §354: реплика `ru-direct` из шаблона — DNS-группа `dns_ru` зашита
/// ЛИТЕРАЛОМ в правиле (var'а `dns_server` нет: выбор одиночного сервера
/// вернул бы единственную точку отказа). Три члена по независимым путям:
/// UDP через канал пресета, DoT через vpn-1, DoH напрямую.
SelectableRule _ruDirectWithDnsGroup() => SelectableRule(
      label: 'Russian domains & IPs',
      presetId: 'ru-direct',
      vars: [
        WizardVar(
          name: 'outbound',
          type: 'outbound',
          defaultValue: 'direct-out',
          title: 'Outbound',
        ),
        WizardVar(
          name: 'dns_ip',
          type: 'enum',
          defaultValue: '77.88.8.8',
          title: 'UDP server IP',
        ),
      ],
      ruleSets: [
        {
          'tag': 'ru-domains',
          'type': 'inline',
          'rules': [
            {
              'domain_suffix': ['ru']
            }
          ],
        },
      ],
      dnsRule: const {'rule_set': 'ru-domains', 'server': 'dns_ru'},
      rule: const {'rule_set': 'ru-domains', 'outbound': '@outbound'},
      dnsServers: _ruDnsServers(),
    );

/// §354: та же реплика, но с var'ом `dns_server` — контракт §033 для
/// пресетов, где выбор сервера остался (fakeip и пр.).
SelectableRule _ruDirectWithDnsServerVar() => SelectableRule(
      label: 'Russian domains & IPs',
      presetId: 'ru-direct',
      vars: [
        WizardVar(
          name: 'outbound',
          type: 'outbound',
          defaultValue: 'direct-out',
          title: 'Outbound',
        ),
        WizardVar(
          name: 'dns_server',
          type: 'dns_servers',
          defaultValue: 'dns_ru',
          required: false,
          title: 'DNS server',
        ),
        WizardVar(
          name: 'dns_ip',
          type: 'enum',
          defaultValue: '77.88.8.8',
          title: 'UDP server IP',
        ),
      ],
      ruleSets: [
        {
          'tag': 'ru-domains',
          'type': 'inline',
          'rules': [
            {
              'domain_suffix': ['ru']
            }
          ],
        },
      ],
      dnsRule: const {'rule_set': 'ru-domains', 'server': '@dns_server'},
      rule: const {'rule_set': 'ru-domains', 'outbound': '@outbound'},
      dnsServers: _ruDnsServers(),
    );

/// §354: `dns_servers` пресета ru-direct — группа объявлена перед членами.
List<Map<String, dynamic>> _ruDnsServers() => [
      {
        'type': 'group',
        'tag': 'dns_ru',
        'servers': ['yandex_udp', 'yandex_dot', 'yandex_doh'],
        'mode': 'fastest',
        'error_ttl': '5m',
        'win_ttl': '5m',
        'description': 'RU DNS group',
      },
      {
        'type': 'udp',
        'tag': 'yandex_udp',
        'server': '@dns_ip',
        'server_port': 53,
        'detour': '@outbound',
        'description': 'Yandex UDP',
      },
      {
        'type': 'tls',
        'tag': 'yandex_dot',
        'server': '77.88.8.88',
        'server_port': 853,
        'detour': 'vpn-1',
        'description': 'Yandex Safe DoT (via vpn-1)',
      },
      // §354: у прямого сервера ключа `detour` нет вовсе — конвенция шаблона
      // (ср. opendns_udp / local_dns_resolver). `direct-out` дал бы тот же
      // результат (normalizeDnsDetour его снимает), но лишний ключ в шаблоне
      // не пишем.
      {
        'type': 'https',
        'tag': 'yandex_doh',
        'server': '77.88.8.88',
        'server_port': 443,
        'path': '/dns-query',
        'description': 'Yandex Safe DoH (direct)',
      },
    ];

/// §045: фабрика — расширенный `ru-direct` с GeoIP fallback layer.
/// Реплицирует template'ный shape v1.6.2: `geoip_enabled` bool var,
/// второй rule_set entry с `enabled: "@geoip_enabled"`, и
/// `rule.rule_set` как List.
SelectableRule _ruDirectWithGeoip() => SelectableRule(
      label: 'Russian domains & IPs direct',
      description: 'Route Russian TLDs and Russian IP ranges directly.',
      defaultEnabled: true,
      presetId: 'ru-direct',
      vars: [
        WizardVar(
          name: 'outbound',
          type: 'outbound',
          defaultValue: 'direct-out',
          title: 'Outbound',
        ),
        WizardVar(
          name: 'dns_server',
          type: 'dns_servers',
          defaultValue: 'yandex_udp',
          required: false,
          title: 'DNS server',
        ),
        WizardVar(
          name: 'geoip_enabled',
          type: 'bool',
          defaultValue: 'true',
          title: 'GeoIP IP-range fallback',
        ),
      ],
      ruleSets: [
        {
          'tag': 'ru-domains',
          'type': 'inline',
          'rules': [
            {
              'domain_suffix': ['ru', 'su']
            }
          ],
        },
        {
          'tag': 'geoip-ru',
          'enabled': '@geoip_enabled',
          'type': 'remote',
          'format': 'binary',
          'url': 'https://example.com/geoip-ru.srs',
          'update_interval': '168h',
        },
      ],
      dnsRule: const {'rule_set': 'ru-domains', 'server': '@dns_server'},
      rule: const {
        'rule_set': ['ru-domains', 'geoip-ru'],
        'outbound': '@outbound'
      },
      dnsServers: [
        {
          'type': 'udp',
          'tag': 'yandex_udp',
          'server': '77.88.8.8',
          'detour': '@outbound',
          'description': 'Yandex UDP',
        },
      ],
    );
