import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/rule_record.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/rule_tree.dart';
import 'package:lxbox/screens/custom_rule_edit/edit_controller.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/rule_transfer.dart';
import 'package:lxbox/services/storage_migration/legacy_form_v0.dart';
import 'package:lxbox/services/storage_migration/migrate_storage.dart';

// §757 — пути чтения правил мимо кодека новой формы (`ruleFromRecord` с
// `refs` в теле): старые формы хранения, бэкапы 0.x и `lx_backup: 2`, файл
// правил форматов 1 и 2, окно правила. Для каждого — ссылки наборов и
// условия доезжают до модели и переживают «прочитал → сохранил → прочитал»
// (у лаунчера на таком пути ссылки оставались на записи, и первое
// сохранение формы их теряло).

const _a = 'https://example.com/rules/a.srs';
const _b = 'https://example.com/rules/b.srs';

/// Запись хранения правила [r] через JSON (как на диске).
Map<String, dynamic> _stored(CustomRule r) =>
    jsonDecode(jsonEncode(ruleToRecord(r))) as Map<String, dynamic>;

/// Сохранить и прочитать путём хранения; запись — новой формы.
CustomRule _saveRead(CustomRule r) {
  final rec = _stored(r);
  expect(rec.containsKey('refs'), isFalse, reason: 'refs на записи');
  expect(rec.containsKey('ref'), isFalse, reason: 'ref на записи');
  final back = ruleFromRecord(rec, unknownAsVerbatim: true).value!;
  expect(back, r, reason: 'прочитал → сохранил → прочитал');
  return back;
}

/// `refs` всех простых узлов записанного тела.
List<String> _bodyRefs(Map<String, dynamic> rec) {
  final out = <String>[];
  void walk(Object? n) {
    if (n is! Map) return;
    final refs = n['refs'];
    if (refs is List) out.addAll(refs.cast<String>());
    final rules = n['rules'];
    if (rules is List) rules.forEach(walk);
  }

  walk(rec['body']);
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('хранение: форма 2.23.2 (srsUrl / srsUrls)', () {
    test('srsUrls главнее srsUrl, условия на месте', () {
      final r = readLegacyCustomRule({
        'kind': 'srs',
        'id': 'r1',
        'name': 'S',
        'srsUrl': _a,
        'srsUrls': [_a, _b],
        'ports': ['443'],
        'packages': ['com.x'],
        'outbound': 'vpn-1',
      });
      expect(r.allRefs, [_a, _b]);
      expect(r.ports, ['443']);
      expect(r.packages, ['com.x']);
      final back = _saveRead(r);
      expect(_bodyRefs(_stored(back)), [_a, _b]);
    });

    test('одиночный srsUrl', () {
      final r = readLegacyCustomRule(
          {'kind': 'srs', 'id': 'r1', 'name': 'S', 'srsUrl': _a});
      expect(r.allRefs, [_a]);
      _saveRead(r);
    });

    test('миграция документа: refs в теле записи', () {
      final res = migrateStorageDoc({
        'custom_rules': [
          {
            'kind': 'srs',
            'id': 'r1',
            'name': 'S',
            'srsUrls': [_a, _b],
            'ports': ['443'],
            'outbound': 'vpn-1',
          },
        ],
      });
      final rec = (res.doc['rules'] as List).single as Map<String, dynamic>;
      expect(rec.containsKey('refs'), isFalse);
      expect(_bodyRefs(rec), [_a, _b]);
      final r = ruleFromRecord(rec, unknownAsVerbatim: true).value!;
      expect(r.allRefs, [_a, _b]);
      expect(r.ports, ['443']);
      _saveRead(r);
    });
  });

  group('хранение: форма 1.0 до §757 (refs / ref на записи)', () {
    test('refs на записи + условия тела → корень дерева', () {
      final r = ruleFromRecord({
        'kind': 'srs',
        'id': 'r1',
        'name': 'S',
        'refs': [_a, _b],
        'update_interval_hours': 12,
        'body': {
          'port': [443],
          'package_name': ['com.x'],
          'outbound': 'vpn-1',
        },
        'dns': {'enabled': true, 'serverTag': 'cf'},
      }, unknownAsVerbatim: true).value! as CustomRuleTree;
      expect(r.allRefs, [_a, _b]);
      expect(r.ports, ['443']);
      expect(r.packages, ['com.x']);
      expect(r.updateIntervalHours, 12);
      expect(r.dns?.serverTag, 'cf');
      expect(_bodyRefs(_stored(_saveRead(r))), [_a, _b]);
    });

    test('одиночный ref на записи', () {
      final r = ruleFromRecord({
        'kind': 'srs',
        'id': 'r1',
        'name': 'S',
        'ref': _a,
        'body': {'outbound': 'vpn-1'},
      }, unknownAsVerbatim: true).value!;
      expect(r.allRefs, [_a]);
      _saveRead(r);
    });

    test('refs на записи при корне logical — обёртка and', () {
      final r = ruleFromRecord({
        'kind': 'srs',
        'id': 'r1',
        'name': 'S',
        'refs': [_a],
        'body': {
          'type': 'logical',
          'mode': 'or',
          'rules': [
            {'port': [443]},
            {'network': ['udp']},
          ],
          'outbound': 'vpn-1',
        },
      }, unknownAsVerbatim: true).value! as CustomRuleTree;
      expect(r.allRefs, [_a]);
      expect(r.hasGroups, isTrue);
      final root = r.root as RuleGroup;
      expect(root.mode, RuleGroup.kAnd);
      expect((root.children.first as RuleLeaf).refs, [_a]);
      expect(r.outbound, 'vpn-1');
      _saveRead(r);
    });
  });

  group('бэкап', () {
    test('0.x: одиночный ref srs-правила', () {
      final file = parseLxBackup(jsonEncode({
        'lx_backup': 1,
        'exported_by': {'app': 'launcher', 'version': '1.5.1'},
        'exported_at': '2026-08-22T00:00:00Z',
        'rules': [
          {
            'kind': 'srs',
            'name': 'Geo',
            'num': 1100,
            'ref': _a,
            'outbound': 'direct',
          },
        ],
      }), knownOutbounds: {'direct'});
      final r = file.rules.single;
      expect(r.allRefs, [_a]);
      _saveRead(r);
    });

    test('lx_backup 2: refs на записи + домены и порт в теле', () {
      final file = parseLxBackup(jsonEncode({
        'lx_backup': 2,
        'exported_by': {'app': 'launcher', 'version': 'test'},
        'exported_at': '2026-09-14T00:00:00Z',
        'rules': [
          {
            'kind': 'srs',
            'name': 'Mixed',
            'enabled': true,
            'num': 1000,
            'refs': [_a, _b],
            'body': {
              'domain_suffix': ['example-1.com'],
              'port': [443],
              'outbound': 'direct',
            },
          },
        ],
      }), knownOutbounds: {'direct'});
      final r = file.rules.single;
      expect(r.allRefs, [_a, _b]);
      expect(r.domainSuffixes, ['example-1.com']);
      expect(r.ports, ['443']);
      _saveRead(r);
    });

    test('экспорт 3 → импорт: дерево с группами и ссылками листа', () async {
      final r = ruleFromRecord({
        'kind': 'srs',
        'name': 'T',
        'enabled': true,
        'num': 1000,
        'body': {
          'type': 'logical',
          'mode': 'and',
          'rules': [
            {'port': [443]},
            {
              'type': 'logical',
              'mode': 'or',
              'rules': [
                {'refs': [_a]},
                {'domain': ['example-2.com']},
              ],
            },
          ],
          'outbound': 'direct',
        },
      }, unknownAsVerbatim: true).value!;
      final out = await buildLxBackup(lists: const [], rules: [r], vars: const {});
      final back =
          parseLxBackup(out.json, knownOutbounds: {'direct'}).rules.single;
      expect(back.allRefs, [_a]);
      expect(back.conditionValues('domain'), ['example-2.com']);
      expect(ruleTreeBodyToJson((back as CustomRuleTree).body),
          ruleTreeBodyToJson((r as CustomRuleTree).body));
      _saveRead(back);
    });
  });

  group('файл правил', () {
    final template = WizardTemplate.fromJson({'selectable_rules': []});

    CustomRule import(Map<String, dynamic> entry, int format) =>
        sanitizeImportedRule(
          entry,
          directionTags: const {'vpn-1'},
          dnsServerTags: const {'cf'},
          template: template,
          format: format,
        ).rule!;

    test('формат 1 (2.23.2): srsUrls', () {
      final r = import({
        'kind': 'srs',
        'name': 'S',
        'srsUrls': [_a, _b],
        'ports': ['443'],
        'outbound': 'vpn-1',
      }, kRulesFormatLegacy);
      expect(r.allRefs, [_a, _b]);
      expect(r.ports, ['443']);
      _saveRead(r);
    });

    test('формат 2: refs на записи (до §757)', () {
      final r = import({
        'kind': 'srs',
        'name': 'S',
        'refs': [_a],
        'body': {'port': [443], 'outbound': 'vpn-1'},
      }, kRulesExportFormatVersion);
      expect(r.allRefs, [_a]);
      expect(r.ports, ['443']);
      _saveRead(r);
    });

    test('экспорт → импорт: refs и домены в теле', () {
      final r = CustomRuleTree.flat(
        name: 'S',
        srsUrls: const [_a, _b],
        domains: const ['example-3.com'],
        outbound: 'vpn-1',
      );
      final contents = parseRulesImport(buildRulesExport([r]));
      final entry = contents.rawRules.single as Map<String, dynamic>;
      expect(entry.containsKey('refs'), isFalse);
      final back = import(entry, contents.format);
      expect(back.allRefs, [_a, _b]);
      expect(back.domains, ['example-3.com']);
      _saveRead(back);
    });
  });

  group('окно правила (существующая форма)', () {
    CustomRuleEditController open(CustomRule r) => CustomRuleEditController(
          initial: r,
          preset: null,
          existingNames: const {},
        );

    test('srs-правило без правок сохраняется с теми же ссылками', () {
      final r = ruleFromRecord({
        'kind': 'srs',
        'id': 'r1',
        'name': 'S',
        'refs': [_a, _b],
        'body': {'port': [443], 'outbound': 'vpn-1'},
      }, unknownAsVerbatim: true).value!;
      final ctrl = open(r);
      addTearDown(ctrl.dispose);
      expect(ctrl.kind, CustomRuleKind.srs);
      final saved = ctrl.snapshot();
      expect(saved.allRefs, [_a, _b]);
      expect(saved.ports, ['443']);
      expect(ctrl.isDirty(), isFalse);
    });

    test('ссылки и домены в одном узле — форма без потерь', () {
      final r = CustomRuleTree.flat(
        id: 'r1',
        name: 'S',
        srsUrls: const [_a],
        domains: const ['example-4.com'],
        outbound: 'vpn-1',
      );
      final ctrl = open(r);
      addTearDown(ctrl.dispose);
      expect(ctrl.jsonMode, isFalse);
      expect(ctrl.snapshot(), r);
      expect(ctrl.isDirty(), isFalse);
    });

    test('srs без единой ссылки: сохраняется как inline, данные целы, '
        'повторное открытие — inline', () {
      final r = CustomRuleTree.flat(
        id: 'r1',
        name: 'S',
        srsUrl: _a,
        ports: const ['443'],
        packages: const ['com.x'],
        outbound: 'vpn-1',
      );
      final ctrl = open(r);
      addTearDown(ctrl.dispose);
      ctrl.setFieldRaw(ctrl.stack.frame('destination')!, 'refs', '');
      final saved = _saveRead(ctrl.snapshot());
      expect(saved.kind, CustomRuleKind.inline);
      expect(saved.allRefs, isEmpty);
      expect(saved.ports, ['443']);
      expect(saved.packages, ['com.x']);
      expect(saved.outbound, 'vpn-1');

      final again = open(saved);
      addTearDown(again.dispose);
      expect(again.kind, CustomRuleKind.inline);
      expect(again.snapshot(), saved);
      expect(again.isDirty(), isFalse);
    });

    test('⚠ пустого DNS-зеркала: опция включена, условий для DNS нет', () {
      const dns = RuleDns(forceIpv4: true);
      final r = CustomRuleTree.flat(
        id: 'r1',
        name: 'S',
        srsUrl: _a,
        ports: const ['443'],
        outbound: 'vpn-1',
        dns: dns,
      );
      final ctrl = open(r);
      addTearDown(ctrl.dispose);
      expect(r.dnsOptionsWithoutEffect, isFalse);
      expect(ctrl.dnsOptionsWithoutEffect, isFalse);
      // Без ссылок остался только порт — DNS его не видит.
      ctrl.setFieldRaw(ctrl.stack.frame('destination')!, 'refs', '');
      expect(ctrl.dnsOptionsWithoutEffect, isTrue);
      final saved = _saveRead(ctrl.snapshot());
      expect(saved.dnsOptionsWithoutEffect, isTrue);
      expect(saved.dns, dns, reason: 'опция сохраняется');
    });
  });
}
