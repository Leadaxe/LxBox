import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/backup_screen/restore_summary.dart';
import 'package:lxbox/services/backup_service.dart';

/// §607 — итог восстановления бэкапа, общий для экрана Backup и главного
/// экрана. Раньше путь с главного экрана не сообщал о числе ошибок.
void main() {
  test('ошибки восстановления попадают в итог с их числом', () {
    final text = restoreSummaryText(
      const BackupApplyResult(
        serverListsApplied: 2,
        errors: ['Storage: a', 'Chains: b'],
      ),
      fetchingSubscriptions: true,
    );
    expect(text, contains('2 errors'));
  });

  test('без ошибок число ошибок не выводится', () {
    final text = restoreSummaryText(
      const BackupApplyResult(appSettingsApplied: 3),
    );
    expect(text, isNot(contains('error')));
  });

  test('ничего не применено — рестарт не предлагается', () {
    expect(restoreAppliedAnything(const BackupApplyResult()), isFalse);
    expect(
      restoreAppliedAnything(const BackupApplyResult(debugConfigApplied: 1)),
      isTrue,
    );
  });
}
