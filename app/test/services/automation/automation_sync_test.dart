import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/automation/automation_sync.dart';
import 'package:lxbox/services/automation/event_emitter.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §605 — receiver'ы автоматизации выставляются по сохранённому тумблеру, а не
/// только по нажатию в UI (бэкап и набор пишут переменную напрямую).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lxbox_automation_sync_');
    messenger.setMockMethodCallHandler(pathChannel, (call) async => tmp.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
    AutomationEventEmitter.I.debugConfigureForTest();
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } on FileSystemException {
      /* AppLog может писать в каталог параллельно */
    }
  });

  for (final stored in [true, false]) {
    test('в хранилище приём=$stored → receiver выставлен в $stored', () async {
      await SettingsStorage.setAutomationReceiveEnabled(stored);
      final seen = <bool>[];
      await syncAutomationFromStorage(setReceiver: (v) async => seen.add(v));
      expect(seen, [stored]);
    });
  }

  test('гейты эмиттера перечитываются из хранилища', () async {
    await SettingsStorage.setAutomationEmitLifecycle(true);
    final sent = <String>[];
    // Гейты выключены, отправка перехвачена.
    AutomationEventEmitter.I.debugConfigureForTest(onSend: (a, _) => sent.add(a));
    await syncAutomationFromStorage(setReceiver: (_) async {});
    AutomationEventEmitter.I.emitVpnRevoked();
    expect(sent, ['VPN_REVOKED']);
  });
}
