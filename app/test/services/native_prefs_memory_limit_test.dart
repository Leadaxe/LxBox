import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/memory_limit_setting.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §271 — memory_limit в §189 native_prefs: default, write-through (JSON +
/// method direction), нормализация мусора, участие в backup-блоке vpn_settings.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const methodsChannel = MethodChannel('com.leadaxe.lxbox/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final nativeCalls = <MethodCall>[];
  // Эмуляция native prefs: setMemoryLimit пишет, getMemoryLimit читает.
  String nativeValue = MemoryLimitSetting.auto;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lxbox_native_prefs_test_');
    nativeCalls.clear();
    nativeValue = MemoryLimitSetting.auto;
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(methodsChannel, (call) async {
      nativeCalls.add(call);
      switch (call.method) {
        case 'getMemoryLimit':
          return nativeValue;
        case 'setMemoryLimit':
          nativeValue = call.arguments['value'] as String;
          return null;
        case 'getBackgroundMode':
          return 'never';
        case 'getAutoStart':
        case 'getKeepOnExit':
        case 'getCoreLogsEnabled':
        case 'getAllowBypass':
        case 'getAutoRedirect':
          return false;
        default:
          return null;
      }
    });
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(methodsChannel, null);
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<void> seedFile(Map<String, dynamic> data) async {
    final f = File('${tmp.path}/lxbox_settings.json');
    await f.writeAsString(jsonEncode(data));
    SettingsStorage.resetCacheForTesting();
  }

  Future<Map<String, dynamic>> readFile() async {
    final f = File('${tmp.path}/lxbox_settings.json');
    return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
  }

  test('default (пустой storage) → auto', () async {
    expect(await SettingsStorage.getNativeMemoryLimit(),
        MemoryLimitSetting.auto);
  });

  test('write-through: JSON-истина + зеркало в native', () async {
    await SettingsStorage.setNativeMemoryLimit('512');
    // JSON — источник истины.
    final data = await readFile();
    final section = data['native_prefs'] as Map<String, dynamic>;
    expect(section['memory_limit'], '512');
    // Native получил тот же wire.
    final set = nativeCalls.where((c) => c.method == 'setMemoryLimit');
    expect(set.single.arguments, {'value': '512'});
    // Чтение возвращает записанное.
    expect(await SettingsStorage.getNativeMemoryLimit(), '512');
  });

  test('мусор на диске нормализуется в auto при чтении', () async {
    await seedFile({
      'native_prefs': {'memory_limit': 'corrupted-junk'},
    });
    expect(await SettingsStorage.getNativeMemoryLimit(),
        MemoryLimitSetting.auto);
  });

  test('export backup-блока содержит memory_limit (default auto)', () async {
    final block = await SettingsStorage.exportNativePrefsBackup();
    expect(block['memory_limit'], MemoryLimitSetting.auto);
  });

  test('apply backup: валидное значение применяется, мусор → auto', () async {
    final n1 = await SettingsStorage.applyNativePrefsBackup(
        {'memory_limit': 'off'});
    expect(n1, 1);
    expect(await SettingsStorage.getNativeMemoryLimit(), 'off');

    final n2 = await SettingsStorage.applyNativePrefsBackup(
        {'memory_limit': 'garbage-9000'});
    expect(n2, 1);
    expect(await SettingsStorage.getNativeMemoryLimit(),
        MemoryLimitSetting.auto);
  });

  test('старый бэкап без memory_limit — ключ пропускается, не падает',
      () async {
    await SettingsStorage.setNativeMemoryLimit('384');
    final n = await SettingsStorage.applyNativePrefsBackup(
        {'auto_start': true}); // бэкап от версии до §271
    expect(n, 1);
    // Прежнее значение не затёрто.
    expect(await SettingsStorage.getNativeMemoryLimit(), '384');
  });
}
