import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/services/backup_merge.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/lx_backup_import.dart';

import '../parser/engine_test_setup.dart';

// §640 (контракт 1.1.116, BACKUP.md §9 п. 7) — «ключа `rules` нет» и
// `rules: []` — разные файлы. Первый о правилах молчит: правила приёмника
// остаются как были, кода нет. Второй (и любой файл с ключом) замещает их
// целиком, и снятые называются одним `backup_rules_replaced {count}` — только
// при `count > 0`.
//
// Режим Merge у LxBox — слияние документа хранения (§633,
// [mergeStorageDoc]); импорт LX Backup режимов не имеет. Строки Merge таблицы
// проверяются на нём: ничего не снимается, кодов нет.

const _receiverRuleNames = ['mine-a', 'mine-b', 'mine-c'];

Map<String, dynamic> _rule(String name, int num) => {
      'kind': 'inline',
      'name': name,
      'enabled': true,
      'num': num,
      'outbound': 'direct-out',
      'match': {
        'domain_suffix': ['$name.example-1.com'],
      },
    };

/// Файл 1.0 с одним узлом; [rules] `null` — ключа нет вовсе.
String _file10({List<Map<String, dynamic>>? rules}) => jsonEncode({
      'lx_backup': 2,
      'exported_by': {'app': 'launcher', 'version': '2.3.6'},
      'exported_at': '2026-10-13T00:00:00Z',
      'sources': [
        {
          'kind': 'server',
          'id': '01SRV640000000000000000000',
          'tag': 'one-node',
          'enabled': true,
          'body': {
            'type': 'trojan',
            'server': 'example-2.com',
            'server_port': 443,
            'password': 'testpass640',
          },
        },
      ],
      'rules': ?rules,
    });

/// Файл 0.x с одним узлом; [rules] `null` — ключа нет вовсе.
String _file0x({List<Map<String, dynamic>>? rules}) => jsonEncode({
      'lx_backup': 1,
      'exported_by': {'app': 'launcher', 'version': '1.5.1'},
      'exported_at': '2026-10-13T00:00:00Z',
      'servers': [
        {
          'id': '01SRV6400X0000000000000000',
          'node_tag': 'one-node',
          'uri': 'trojan://testpass640@example-2.com:443#one-node',
        },
      ],
      'rules': ?rules,
    });

/// Правила приёмника — тем же разбором, каким их пишет импорт.
List<CustomRule> _receiverRules() => planLxBackupImport(
      _file10(rules: [
        for (var i = 0; i < _receiverRuleNames.length; i++)
          _rule(_receiverRuleNames[i], 1000 + i),
      ]),
      const LxImportReceiver(),
    ).rules;

LxImportPlan _plan(String raw, List<CustomRule> receiverRules) =>
    planLxBackupImport(raw, LxImportReceiver(rules: receiverRules));

Iterable<LxBackupWarning> _replaced(LxImportPlan plan) =>
    plan.file.warnings.where((w) => w.code == kWarnRulesReplaced);

void main() {
  setUpAll(loadEngineSections);

  late List<CustomRule> mine;
  setUp(() {
    mine = _receiverRules();
    expect(mine.map((r) => r.name), _receiverRuleNames);
  });

  group('Replace (импорт LX Backup)', () {
    test('ключа rules нет — правила приёмника как были, кода нет', () {
      final plan = _plan(_file10(), mine);
      expect(plan.file.rulesDeclared, isFalse);
      expect(identical(plan.rules, mine), isTrue,
          reason: 'файл о правилах молчит: тот же список, без оси и D-117');
      expect(_replaced(plan), isEmpty);
      expect(plan.lists, hasLength(1), reason: 'узел файла применён');
    });

    test('rules: [] — правила сняты, count = сколько было', () {
      final plan = _plan(_file10(rules: const []), mine);
      expect(plan.file.rulesDeclared, isTrue);
      expect(plan.rules, isEmpty);
      expect(_replaced(plan).map((w) => w.detail), ['rules: 3']);
    });

    test('rules: [...] — правила файла вместо своих, count = сколько было', () {
      final plan = _plan(
          _file10(rules: [_rule('theirs-a', 1000), _rule('theirs-b', 1001)]),
          mine);
      expect(plan.rules.map((r) => r.name), ['theirs-a', 'theirs-b']);
      expect(_replaced(plan).map((w) => w.detail), ['rules: 3']);
    });

    test('приёмник без правил — кода нет ни при [], ни при [...]', () {
      for (final rules in [
        const <Map<String, dynamic>>[],
        [_rule('theirs-a', 1000)],
      ]) {
        final plan = _plan(_file10(rules: rules), const []);
        expect(plan.rules, hasLength(rules.length));
        expect(_replaced(plan), isEmpty, reason: '$rules');
      }
    });

    test('0.x: ключа нет — как у 1.0; ключ есть — замена с count', () {
      final silent = _plan(_file0x(), mine);
      expect(silent.file.rulesDeclared, isFalse);
      expect(identical(silent.rules, mine), isTrue);
      expect(_replaced(silent), isEmpty);

      final wiped = _plan(_file0x(rules: const []), mine);
      expect(wiped.file.rulesDeclared, isTrue);
      expect(wiped.rules, isEmpty);
      expect(_replaced(wiped).map((w) => w.detail), ['rules: 3']);
    });
  });

  group('экспорт', () {
    test('ключ rules пишется всегда, пусть []', () async {
      final out = await buildLxBackup(
          lists: const [], rules: const [], vars: const {});
      final doc = jsonDecode(out.json) as Map<String, dynamic>;
      expect(doc.containsKey('rules'), isTrue);
      expect(doc['rules'], isEmpty);
      // Свой файл с пустыми правилами замещает правила приёмника.
      final plan = _plan(out.json, mine);
      expect(plan.rules, isEmpty);
      expect(_replaced(plan).map((w) => w.detail), ['rules: 3']);
    });
  });

  group('Merge (§633, документ хранения)', () {
    Map<String, dynamic> rec(String id) => {
          'id': id,
          'kind': 'inline',
          'name': id,
          'enabled': true,
          'num': 1000,
          'outbound': 'direct-out',
          'match': {
            'domain_suffix': ['$id.example-1.com'],
          },
        };
    Map<String, dynamic> doc() => {
          'rules': [rec('mine-a'), rec('mine-b')],
        };
    List<Object?> ids(Map<String, dynamic> d) =>
        [for (final r in d['rules'] as List) (r as Map)['id']];

    test('ключа rules нет — правила как были', () {
      final mineDoc = doc();
      final stats = mergeStorageDoc(mineDoc, const {'vars': {}});
      expect(ids(mineDoc), ['mine-a', 'mine-b']);
      expect(stats.rules.added, 0);
    });

    test('rules: [] и [...] — слияние, ничего не снимается', () {
      final empty = doc();
      mergeStorageDoc(empty, const {'rules': []});
      expect(ids(empty), ['mine-a', 'mine-b']);

      final some = doc();
      final stats = mergeStorageDoc(some, {
        'rules': [rec('theirs-a')],
      });
      expect(ids(some), ['mine-a', 'mine-b', 'theirs-a']);
      expect(stats.rules.added, 1);
    });
  });
}
