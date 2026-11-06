import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/validation.dart';
import 'package:lxbox/services/builder/post_steps.dart'
    show healDanglingDnsResolvers;
import 'package:lxbox/services/builder/validator.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/lx_backup_import.dart';
import 'package:lxbox/services/record_vars.dart';

// §643 (контракт 1.1.119, TEMPLATE_LANG §2.1, §6.9, D-132) — поля объявления
// `wizard_ui: internal` и `unique` вокруг движка (хранение, экспорт, импорт
// LX Backup) и объектная форма `route.default_domain_resolver` у читателей.

/// Объявления приёмника: пресет `hosts` с переменной только для сборки
/// `collected` и пользовательской `extra` (`unique`), глобальная `internal`.
final _decls = RecordVarDecls(
  presets: {
    'hosts': [
      const RecordVarDecl(
          name: 'collected', type: 'text_list', isInternal: true),
      const RecordVarDecl(name: 'extra', type: 'text_list', unique: true),
    ],
  },
  internalGlobals: const {'build_only'},
);

String _file(Map<String, dynamic> body) => jsonEncode({
      'lx_backup': 2,
      'exported_by': {'app': 'launcher', 'version': '1.6.0'},
      'exported_at': '2026-10-13T00:00:00Z',
      ...body,
    });

void main() {
  group('internal: хранение и редактор', () {
    test('писатель записи снимает internal молча, onInternal называет', () {
      final named = <String>[];
      final rules = normalizePresetRulesVars(
        [
          CustomRulePreset(
              name: 'h',
              presetId: 'hosts',
              varsValues: {'collected': 'a.example', 'extra': 'x.example'}),
        ],
        _decls,
        onInternal: (preset, name) => named.add('$preset.$name'),
      );
      expect((rules.single as CustomRulePreset).varsValues,
          {'extra': 'x.example'});
      expect(named, ['hosts.collected']);
      // Без колбэка — молча (хранение).
      expect(
          (normalizePresetRulesVars(rules, _decls).single as CustomRulePreset)
              .varsValues,
          {'extra': 'x.example'});
    });

    test('редактор: internal не пишется; unique снимает дубли', () {
      final decls = _decls.presets['hosts']!;
      expect(recordVarValueToStore('a.example', decls[0]), isNull);
      expect(recordVarValueToStore('b\na\nb\n\na', decls[1]), 'b\na');
    });

    test('dedupTextListValue: порядок первого появления, пустые выброшены',
        () {
      expect(dedupTextListValue(' a \n\nb\na\n b'), 'a\nb');
      final v = WizardVar(
          name: 'x', type: 'text_list', defaultValue: '', unique: true);
      expect(applyVarUnique(v, 'a\na'), 'a');
      expect(applyVarUnique(null, 'a\na'), 'a\na');
    });
  });

  group('internal: LX Backup', () {
    test('импорт: значение internal снято с reason internal', () {
      final plan = planLxBackupImport(
        _file({
          'vars': {'build_only': 'x', 'log_level': 'info'},
          'rules': [
            {
              'kind': 'preset',
              'ref': 'hosts',
              'enabled': true,
              'num': 960,
              'vars': {'collected': 'a.example', 'extra': 'x.example'},
            },
          ],
        }),
        LxImportReceiver(recordVars: _decls),
      );
      final reasons = [
        for (final w in plan.file.warnings)
          if (w.code == kWarnVarSkipped) '${w.reason}:${w.detail}',
      ]..sort();
      expect(reasons, [
        'internal:build_only',
        'internal:preset:hosts.vars.collected',
      ]);
      final hosts = plan.rules.whereType<CustomRulePreset>().single;
      expect(hosts.varsValues, {'extra': 'x.example'});
      expect(plan.file.vars.containsKey('build_only'), isFalse);
    });

    test('экспорт: internal не пишется ни у пресета, ни у глобали', () async {
      final raw = (await buildLxBackup(
        lists: const [],
        rules: [
          CustomRulePreset(
              name: 'h',
              presetId: 'hosts',
              varsValues: {'collected': 'a.example', 'extra': 'x.example'}),
        ],
        vars: const {'build_only': 'x', 'dns_resolver_no_stale': 'false'},
        recordVars: _decls,
      ))
          .json;
      final doc = jsonDecode(raw) as Map<String, dynamic>;
      final rule = (doc['rules'] as List).single as Map<String, dynamic>;
      expect(rule['vars'], {'extra': 'x.example'});
      // Переносимая переменная §6.9 едет в `vars`, internal — нет.
      expect(doc['vars'], {'dns_resolver_no_stale': 'false'});
    });
  });

  group('route.default_domain_resolver — объектная форма', () {
    Map<String, dynamic> config(Object resolver) => {
          'dns': {
            'servers': [
              {'type': 'udp', 'tag': 'dns_shield', 'server': '1.1.1.1'},
              {'type': 'fakeip', 'tag': 'fake'},
            ],
          },
          'route': {'default_domain_resolver': resolver},
        };

    test('валидатор берёт server из объекта; dangling и fakeip ловятся', () {
      expect(
          validateConfig(config({
            'server': 'dns_shield',
            'disable_optimistic_cache': true,
          })).issues.whereType<DanglingDnsServerRef>(),
          isEmpty);
      expect(
          validateConfig(config({'server': 'gone'}))
              .issues
              .whereType<DanglingDnsServerRef>()
              .single
              .field,
          'route.default_domain_resolver');
      expect(
          validateConfig(config({'server': 'fake'}))
              .issues
              .whereType<BadResolverServerType>(),
          hasLength(1));
    });

    test('замена битого резолвера меняет только server', () {
      final c = config({'server': 'gone', 'disable_optimistic_cache': true});
      final healed = healDanglingDnsResolvers(c,
          defaults: const {'dns_default_domain_resolver': 'dns_shield'});
      expect(healed.single.to, 'dns_shield');
      expect(c['route']['default_domain_resolver'],
          {'server': 'dns_shield', 'disable_optimistic_cache': true});
    });
  });
}
