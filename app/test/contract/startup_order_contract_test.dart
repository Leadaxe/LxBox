import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// §417 — порядок старта в `main()`. `WorkspaceStore.I.recover()` доводит
// загрузку слота, убитую посреди копирования, а `SettingsStorage._load` кладёт
// сцену в кэш и мигрирует её форму (§439). Чтение настроек раньше recover
// оставит в кэше старую сцену, и первое же сохранение ляжет поверх доведённого
// слота. `SubscriptionIdentity.init` читает настройки через `getVar`.
//
// `AppLog.I.initPersistent()` — ДО recover: warning доводки пишет applog.txt
// одной текущей сессией, записи убитой сессии пропали бы до чтения.
void main() {
  test('main() runs WorkspaceStore.recover before any settings read', () {
    final src = File('lib/main.dart').readAsLinesSync();
    final start = src.indexWhere((l) => l.startsWith('void main('));
    final end = src.indexWhere((l) => l.contains('runApp('), start);
    expect(start, isNot(-1), reason: 'void main() not found in lib/main.dart');
    expect(end, isNot(-1), reason: 'runApp( not found after main()');

    int firstLine(bool Function(String code) match) {
      for (var i = start; i <= end; i++) {
        final code = src[i].split('//').first;
        if (match(code)) return i;
      }
      return -1;
    }

    final recover = firstLine((c) => c.contains('WorkspaceStore.I.recover()'));
    expect(
      recover,
      isNot(-1),
      reason: 'WorkspaceStore.I.recover() not in main()',
    );

    final settingsRead = firstLine(
      (c) =>
          c.contains('SettingsStorage.') ||
          c.contains('SubscriptionIdentity.init('),
    );
    expect(
      settingsRead,
      greaterThan(recover),
      reason:
          'lib/main.dart:${settingsRead + 1} reads settings before '
          'WorkspaceStore.I.recover() (line ${recover + 1})',
    );

    final persistentLog = firstLine(
      (c) => c.contains('AppLog.I.initPersistent()'),
    );
    expect(persistentLog, isNot(-1));
    expect(
      persistentLog,
      lessThan(recover),
      reason:
          'AppLog.I.initPersistent() must load the previous session '
          'log before recover() logs its warning',
    );
  });
}
