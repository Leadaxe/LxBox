import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/services/builder/preset_expand.dart';
import 'package:lxbox/services/record_vars.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/storage_migration/migrate_storage.dart';
import 'package:lxbox/services/template_loader.dart';

import '../storage_migration/golden_harness.dart';

// §441 (SPEC 128 контракта) — значения переменных записи: нормы Н2/Н3/Н4 для
// двух носителей (`dns.servers[kind=template].vars`, `rules[kind=preset].vars`)
// и писатели, которые их применяют (репозиторий, миграция).

/// Объявления в форме шаблона: сервер с двумя переменными, сервер без
/// переменных, пресет с `outbound` и bool, пресет без переменных, пресет со
/// ссылкой на глобальную переменную.
final _decls = RecordVarDecls.fromJson({
  'dns_options': {
    'servers': [
      {
        'vars': [
          {'name': 'outbound', 'type': 'outbound', 'default_value': 'direct-out'},
          {'name': 'dns_ip', 'type': 'enum', 'default_value': '8.8.8.8'},
        ],
        'server': {'type': 'udp', 'tag': 'google_udp', 'detour': '@outbound'},
      },
      {
        'server': {'type': 'https', 'tag': 'quad9_doh'},
      },
    ],
  },
  'selectable_rules': [
    {
      'preset_id': 'ru-direct',
      'vars': [
        {'name': 'outbound', 'type': 'outbound', 'default_value': 'direct-out'},
        {'name': 'force_ipv4', 'type': 'bool', 'default_value': 'true'},
      ],
    },
    {'preset_id': 'block-ads'},
    {
      'id': 'traffic-processing',
      'vars': [
        {'ref': 'resolve_strategy'},
        {'name': 'sniff_timeout', 'type': 'enum', 'default': '300ms'},
      ],
    },
  ],
});

void main() {
  group('Н2/Н3/Н4: DNS-сервер kind: template', () {
    test('умолчание, пустое и необъявленное снимаются, значение подрезано', () {
      final undeclared = <String>[];
      final got = normalizeDnsServerVars(
        const DnsServerTemplate(enabled: true, tag: 'google_udp', varValues: {
          'outbound': 'direct-out',
          'dns_ip': ' 8.8.4.4 ',
          'legacy_x': '1',
        }),
        _decls,
        onUndeclared: undeclared.add,
      ) as DnsServerTemplate;
      expect(got.varValues, {'dns_ip': '8.8.4.4'});
      expect(undeclared, ['legacy_x']);

      final blank = normalizeDnsServerVars(
        const DnsServerTemplate(
            enabled: true, tag: 'google_udp', varValues: {'dns_ip': '   '}),
        _decls,
      ) as DnsServerTemplate;
      expect(blank.varValues, isEmpty, reason: 'пустое после подрезки — нет ключа');
    });

    test('сервер без объявленных переменных: все имена необъявлены', () {
      final got = normalizeDnsServerVars(
        const DnsServerTemplate(
            enabled: true, tag: 'quad9_doh', varValues: {'outbound': 'vpn-1'}),
        _decls,
      ) as DnsServerTemplate;
      expect(got.varValues, isEmpty);
    });

    test('сервер, которого шаблон не объявил, и другие виды — как есть', () {
      const orphan = DnsServerTemplate(
          enabled: true, tag: 'gone', varValues: {'outbound': 'direct-out'});
      expect(identical(normalizeDnsServerVars(orphan, _decls), orphan), isTrue);
      const inline = DnsServerInline(
          enabled: true, tag: 'my', body: {'type': 'udp', 'detour': 'x'});
      expect(identical(normalizeDnsServerVars(inline, _decls), inline), isTrue);
      const noTemplate = DnsServerTemplate(
          enabled: true, tag: 'google_udp', varValues: {'outbound': 'direct-out'});
      expect(
          identical(
              normalizeDnsServerVars(noTemplate, RecordVarDecls.none), noTemplate),
          isTrue,
          reason: 'шаблона нет — нормализации нет');
    });
  });

  group('Н2/Н3/Н4: правило kind: preset', () {
    test('умолчание и необъявленное снимаются, неизвестный пресет не трогается',
        () {
      final undeclared = <String>[];
      final rules = normalizePresetRulesVars(
        [
          CustomRulePreset(
            name: 'RU',
            presetId: 'ru-direct',
            varsValues: {
              'outbound': 'direct-out',
              'force_ipv4': 'true',
              'bogus': 'x',
            },
          ),
          CustomRulePreset(
            name: 'Ghost',
            presetId: 'no-such',
            varsValues: {'anything': 'kept'},
          ),
        ],
        _decls,
        onUndeclared: (id, name) => undeclared.add('$id.$name'),
      );
      expect(rules[0].varsValues, isEmpty);
      expect(rules[1].varsValues, {'anything': 'kept'});
      expect(undeclared, ['ru-direct.bogus']);
    });

    test('outbound законен у пресета без объявления (универсальная замена цели)',
        () {
      final got = normalizePresetRuleVars(
        CustomRulePreset(
          name: 'Ads',
          presetId: 'block-ads',
          varsValues: {'outbound': ' vpn-1 ', 'list': 'x'},
        ),
        _decls,
      );
      expect(got.varsValues, {'outbound': 'vpn-1'});
    });

    test('ref-переменная не нормализуется, алиас default читается', () {
      final got = normalizePresetRuleVars(
        CustomRulePreset(
          name: 'TP',
          presetId: 'traffic-processing',
          varsValues: {'resolve_strategy': ' ipv4_only', 'sniff_timeout': '300ms'},
        ),
        _decls,
      );
      expect(got.varsValues, {'resolve_strategy': ' ipv4_only'});
    });

    test('редактор: выбор умолчания снимает ключ', () {
      const decl = RecordVarDecl(name: 'outbound', defaultValue: 'direct-out');
      expect(recordVarValueToStore('direct-out', decl), isNull);
      expect(recordVarValueToStore(' vpn-1 ', decl), 'vpn-1');
      expect(recordVarValueToStore('  ', decl), isNull);
      expect(recordVarValueToStore('reject', null), 'reject');
    });
  });

  group('Н8: корневое имя → пара (tag, var)', () {
    final decls = RecordVarDecls.fromJson({
      'dns_options': {
        'servers': [
          {
            'vars': [
              {'name': 'vpn_outbound'},
            ],
            'server': {'tag': 'google_doh'},
          },
          {
            'vars': [
              {'name': 'outbound'},
            ],
            'server': {'tag': 'google_doh_vpn'},
          },
        ],
      },
    });

    test('неоднозначная склейка — выигрывает самый длинный тег', () {
      expect(rootDnsVarTarget('dns_google_doh_vpn_outbound', decls),
          (tag: 'google_doh_vpn', varName: 'outbound'));
    });

    test('кандидата нет', () {
      expect(rootDnsVarTarget('dns_final', decls), isNull);
      expect(rootDnsVarTarget('dns_google_doh_dns_ip', decls), isNull);
    });
  });

  group('SPEC 128 §6: цели по имени в переменных типа outbound', () {
    // google_dot — умолчание `vpn-1`; пресет `russian` объявляет цель под
    // именем `out`; `dns_ip`/`mode` — не цели, даже если значение совпало.
    final decls = RecordVarDecls.fromJson({
      'dns_options': {
        'servers': [
          {
            'vars': [
              {'name': 'outbound', 'type': 'outbound', 'default_value': 'vpn-1'},
              {'name': 'dns_ip', 'type': 'enum', 'default_value': '8.8.8.8'},
            ],
            'server': {'type': 'tls', 'tag': 'google_dot'},
          },
          {
            'vars': [
              {'name': 'outbound', 'type': 'outbound', 'default_value': 'direct-out'},
            ],
            'server': {'type': 'udp', 'tag': 'google_udp'},
          },
        ],
      },
      'selectable_rules': [
        {
          'preset_id': 'russian',
          'vars': [
            {'name': 'out', 'type': 'outbound', 'default_value': 'direct-out'},
            {'name': 'mode', 'type': 'enum', 'default_value': 'a'},
          ],
        },
      ],
    });

    test('переименование vpn-3 → vpn-9 переписывает vars сервера и пресета', () {
      final retarget = directionRefRetarget('vpn-3', 'vpn-9', rename: true);
      expect(retarget, {'vpn-3': 'vpn-9', 'vpn-3-auto': 'vpn-9-auto'});

      const dot = DnsServerTemplate(enabled: true, tag: 'google_dot', varValues: {
        'outbound': 'vpn-3',
        'dns_ip': 'vpn-3',
      });
      expect(
        (retargetDnsServerOutboundVars(dot, decls, retarget)
                as DnsServerTemplate)
            .varValues,
        {'outbound': 'vpn-9', 'dns_ip': 'vpn-3'},
        reason: 'enum-переменная — не цель',
      );

      final preset = CustomRulePreset(name: 'RU', presetId: 'russian', varsValues: const {
        'out': 'vpn-3-auto',
        'outbound': 'vpn-3',
        'mode': 'vpn-3',
      });
      expect(
        retargetPresetOutboundVars(preset, decls, retarget).varsValues,
        {'out': 'vpn-9-auto', 'outbound': 'vpn-9', 'mode': 'vpn-3'},
      );
    });

    test('удаление: vpn-1, равное умолчанию, снимает ключ (Н4); иначе остаётся',
        () {
      final retarget = directionRefRetarget('vpn-3', 'vpn-1');
      expect(retarget, {'vpn-3': 'vpn-1', 'vpn-3-auto': 'vpn-1'});
      const dot = DnsServerTemplate(
          enabled: true, tag: 'google_dot', varValues: {'outbound': 'vpn-3-auto'});
      const udp = DnsServerTemplate(
          enabled: true, tag: 'google_udp', varValues: {'outbound': 'vpn-3'});
      expect(
          (retargetDnsServerOutboundVars(dot, decls, retarget)
                  as DnsServerTemplate)
              .varValues,
          isEmpty);
      expect(
          (retargetDnsServerOutboundVars(udp, decls, retarget)
                  as DnsServerTemplate)
              .varValues,
          {'outbound': 'vpn-1'});
    });

    test('объявления нет — ключ outbound по имени; не совпало — тот же экземпляр',
        () {
      final retarget = directionRefRetarget('vpn-3', 'vpn-9', rename: true);
      const foreign = DnsServerTemplate(
          enabled: true, tag: 'my_tpl', varValues: {'outbound': 'vpn-3', 'x': 'vpn-3'});
      expect(
          (retargetDnsServerOutboundVars(foreign, RecordVarDecls.none, retarget)
                  as DnsServerTemplate)
              .varValues,
          {'outbound': 'vpn-9', 'x': 'vpn-3'});
      final unknownPreset = CustomRulePreset(name: 'Ghost',
          presetId: 'ghost', varsValues: const {'outbound': 'vpn-3', 'out': 'vpn-3'});
      expect(
          retargetPresetOutboundVars(unknownPreset, decls, retarget).varsValues,
          {'outbound': 'vpn-9', 'out': 'vpn-3'});

      const other = DnsServerTemplate(
          enabled: true, tag: 'google_dot', varValues: {'outbound': 'vpn-2'});
      expect(identical(retargetDnsServerOutboundVars(other, decls, retarget), other),
          isTrue);
      final inline = CustomRuleInline(name: 'r', outbound: 'vpn-3');
      expect(identical(retargetPresetOutboundVars(inline, decls, retarget), inline),
          isTrue);
    });
  });

  group('условие приёмки L8: конфиг не меняется', () {
    // Каждый пресет шаблона приложения: правило со ВСЕМИ объявленными
    // переменными, выставленными в умолчание (и универсальной целью, равной
    // умолчанию `outbound`), разворачивается в те же фрагменты, что и
    // нормализованное (без ключей).
    test('все пресеты шаблона: умолчания в vars ≡ пустые vars', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final template = await TemplateLoader.load();
      final decls = RecordVarDecls.fromTemplate(template);
      const globals = {
        'vpn_mode': 'vpn',
        'resolve_enabled': 'true',
        'resolve_strategy': 'prefer_ipv4',
      };
      var checked = 0;
      for (final preset in template.selectableRules) {
        final withDefaults = CustomRulePreset(
          name: preset.presetId,
          presetId: preset.presetId,
          varsValues: {
            for (final v in preset.vars)
              if (!v.isRef && v.defaultValue.isNotEmpty) v.name: v.defaultValue,
          },
        );
        final normalized =
            normalizePresetRuleVars(withDefaults, decls) as CustomRulePreset;
        expect(normalized.varsValues, isEmpty, reason: preset.presetId);
        final a = expandPreset(withDefaults, preset, globalVars: globals);
        final b = expandPreset(normalized, preset, globalVars: globals);
        String dump(PresetFragments f) => jsonEncode({
              'dns_servers': f.dnsServers,
              'dns_rules': f.dnsRules,
              'rule_sets': f.ruleSets,
              'rules': f.routingRules,
              'warnings': f.warnings,
            });
        expect(dump(b), dump(a), reason: preset.presetId);
        checked++;
      }
      expect(checked, template.selectableRules.length);
    });
  });

  group('писатели', () {
    late StorageSandbox box;
    setUp(() async {
      box = await StorageSandbox.create();
    });
    tearDown(() => box.dispose());

    test('репозиторий: запись DNS-серверов и правил снимает умолчания и сирот',
        () async {
      await SettingsStorage.saveDnsServers(const [
        DnsServerTemplate(enabled: true, tag: 'google_udp', varValues: {
          'outbound': 'direct-out',
          'dns_ip': '8.8.4.4',
          'legacy_x': '1',
        }),
        DnsServerTemplate(
            enabled: true, tag: 'google_dot', varValues: {'outbound': 'vpn-1'}),
      ]);
      await SettingsStorage.saveCustomRules([
        CustomRulePreset(
          name: 'RU',
          presetId: 'ru-direct',
          varsValues: {'outbound': 'direct-out', 'dns_ip': '77.88.8.1'},
        ),
      ]);
      final raw = await SettingsStorage.exportRaw();
      final servers = ((raw['dns'] as Map)['servers'] as List).cast<Map>();
      expect(servers[0]['vars'], {'dns_ip': '8.8.4.4'});
      expect(servers[1].containsKey('vars'), isFalse,
          reason: 'google_dot: outbound vpn-1 — умолчание шаблона LxBox');
      final rules = (raw['rules'] as List).cast<Map>();
      expect(rules.single['vars'], {'dns_ip': '77.88.8.1'});
    });

    test('миграция 2.23.2: vars пишутся без умолчаний', () async {
      final template = await TemplateLoader.load();
      final r = migrateStorageDoc({
        'dns_options': {
          'servers': [
            {
              'kind': 'template',
              'tag': 'google_udp',
              'enabled': true,
              'varValues': {'outbound': 'direct-out', 'dns_ip': '8.8.4.4'},
            },
          ],
        },
        'custom_rules': [
          {
            'kind': 'preset',
            'name': 'RU',
            'presetId': 'ru-direct',
            'varsValues': {'force_ipv4': 'true', 'dns_ip': '77.88.8.1'},
          },
        ],
      }, recordVars: RecordVarDecls.fromTemplate(template));
      final servers = ((r.doc['dns'] as Map)['servers'] as List).cast<Map>();
      expect(servers.single['vars'], {'dns_ip': '8.8.4.4'});
      final rules = (r.doc['rules'] as List).cast<Map>();
      expect(rules.single['vars'], {'dns_ip': '77.88.8.1'});
    });
  });
}
