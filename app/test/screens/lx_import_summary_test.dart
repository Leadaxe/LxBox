import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/screens/backup_screen/lx_import_summary.dart';
import 'package:lxbox/services/lx_backup.dart';

/// §641 — превью и снек импорта LX Backup после §640: файл без ключа `rules`
/// правил не трогает, замена правил приёмника — не отказ.
LxBackupFile _file({
  int rules = 0,
  bool rulesDeclared = true,
  int replaced = 0,
  List<LxBackupWarning> other = const [],
}) => LxBackupFile(
  version: 1,
  exportedByApp: 'L×Box',
  exportedByVersion: '2.25.12',
  exportedAt: '',
  directions: const [],
  rules: [for (var i = 0; i < rules; i++) CustomRuleInline(name: 'r$i')],
  subscriptions: const [],
  vars: const {},
  routeFinal: null,
  warnings: [
    ...other,
    if (replaced > 0) LxBackupWarning(kWarnRulesReplaced, 'rules: $replaced'),
  ],
  rulesDeclared: rulesDeclared,
);

const _refused = LxBackupWarning(kWarnVarSkipped, 'preset:x.vars.y');

void main() {
  group('превью: последняя строка', () {
    test('ключа rules нет — правила остаются', () {
      final lines = lxImportPreviewLines(_file(rulesDeclared: false));
      expect(lines.last, 'This file has no rules. The current rules stay.');
    });

    test('ключ есть, у приёмника правил нет — добавляет', () {
      final lines = lxImportPreviewLines(_file(rules: 2));
      expect(lines.last, "Importing adds the file's rules.");
    });

    test('ключ есть, у приёмника 5 правил — заменяет 5', () {
      final lines = lxImportPreviewLines(_file(rules: 2, replaced: 5));
      expect(lines.last, 'Importing replaces the current 5 rule(s).');
    });
  });

  group('превью: «Not applied as-is:»', () {
    test('одна замена — заголовка нет', () {
      final lines = lxImportPreviewLines(_file(rules: 2, replaced: 5));
      expect(lines, isNot(contains('Not applied as-is:')));
      expect(lines.where((l) => l.contains('rules: 5')), isEmpty);
    });

    test('замена и отказ — в списке только отказ', () {
      final lines = lxImportPreviewLines(
        _file(rules: 2, replaced: 5, other: const [_refused]),
      );
      expect(lines, contains('Not applied as-is:'));
      expect(lines, contains('• preset:x.vars.y'));
      expect(lines.where((l) => l.contains('rules: 5')), isEmpty);
    });
  });

  group('снек', () {
    String snack(
      LxBackupFile f, {
      int directions = 0,
      int settings = 0,
      int chains = 0,
    }) => lxImportSnackText(
      f,
      appliedDirections: directions,
      appliedSettings: settings,
      appliedChains: chains,
    );

    test('замена — не «not applied», а хвост replaced N', () {
      final text = snack(
        _file(rules: 3, replaced: 5),
        directions: 2,
        settings: 1,
      );
      expect(text, isNot(contains('not applied')));
      expect(
        text,
        'Imported 3 rules, 2 directions and 1 settings, replaced 5 rule(s)',
      );
    });

    test('замена и отказ — отказ считается без замены', () {
      final text = snack(_file(rules: 3, replaced: 5, other: const [_refused]));
      expect(
        text,
        'Imported 3 rule(s), 1 items not applied, '
        'replaced 5 rule(s)',
      );
    });

    test('хвост replaced стоит до клаузы цепочек', () {
      final text = snack(_file(rules: 1, replaced: 2), chains: 1);
      expect(text, endsWith(', replaced 2 rule(s); chains: 1'));
    });

    test('ключа rules нет и счётчики нулевые — импортировать нечего', () {
      final text = snack(_file(rulesDeclared: false));
      expect(
        text,
        'Nothing to import: the file has no rules, directions or settings.',
      );
    });

    test('ключа rules нет, настройки применены — прежняя ветка', () {
      final text = snack(_file(rulesDeclared: false), settings: 2);
      expect(text, 'Imported 0 rules and 2 settings');
    });
  });
}
