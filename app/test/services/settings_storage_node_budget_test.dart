import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/settings_storage_keys.dart';

/// Бюджет узлов — верхнеуровневый `node_budget`: дефолт, нижняя граница,
/// сброс ключа, значение для подписчиков.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_node_budget_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } on FileSystemException {
      /* ignore */
    }
  });

  test('без ключа — дефолт 1000', () async {
    expect(SettingsStorage.nodeBudgetDefault, 1000);
    expect(await SettingsStorage.getNodeBudget(), 1000);
  });

  test('запись/чтение, верхнего потолка нет', () async {
    await SettingsStorage.setNodeBudget(25000);
    expect(await SettingsStorage.getNodeBudget(), 25000);
    expect(SettingsStorage.nodeBudget.value, 25000);
    expect((await SettingsStorage.exportRaw())[kNodeBudgetKey], 25000);
  });

  test('clamp снизу 1 на записи и на чтении', () async {
    await SettingsStorage.setNodeBudget(0);
    expect(await SettingsStorage.getNodeBudget(), 1);
    expect(SettingsStorage.nodeBudget.value, 1);
  });

  test('set(null) снимает ключ', () async {
    await SettingsStorage.setNodeBudget(300);
    await SettingsStorage.setNodeBudget(null);
    expect((await SettingsStorage.exportRaw()).containsKey(kNodeBudgetKey),
        isFalse);
    expect(await SettingsStorage.getNodeBudget(), 1000);
    expect(SettingsStorage.nodeBudget.value, 1000);
  });

  test('ключ в allowlist импорта', () {
    expect(SettingsStorage.allowedTopLevelKeys, contains(kNodeBudgetKey));
  });
}
