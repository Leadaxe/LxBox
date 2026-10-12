import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/config_dirty_check.dart';
import 'package:lxbox/services/platform_channels.dart';

/// §076F / 003-CONFIG_BUILD · P12 — восстановление флага «конфиг устарел»
/// после убийства процесса: сравнение mtime `lxbox_settings.json`
/// (Documents) и `singbox_config.json` (native filesDir, §414) с секундной
/// точностью (§113). Края — по докстрингу `ConfigDirtyCheck.isDirty`.
void main() {
  late Directory docs;
  late Directory filesDir;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const vpnChannel = MethodChannel(PlatformChannels.methods);

  File settingsFile() => File('${docs.path}/lxbox_settings.json');
  File configFile() => File('${filesDir.path}/singbox_config.json');

  Future<void> write(File f, DateTime mtime) async {
    await f.writeAsString('{}');
    await f.setLastModified(mtime);
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    docs = await Directory.systemTemp.createTemp('lxbox_dcheck_docs_');
    filesDir = await Directory.systemTemp.createTemp('lxbox_dcheck_files_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return docs.path;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(vpnChannel, (call) async {
      if (call.method == 'getFilesDir') return filesDir.path;
      return null;
    });
    ConfigDirtyCheck.resetForTesting();
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(vpnChannel, null);
    for (final d in [docs, filesDir]) {
      try {
        if (d.existsSync()) await d.delete(recursive: true);
      } on FileSystemException {
        /* ignore */
      }
    }
  });

  final base = DateTime(2026, 1, 1, 12);

  test('свежая установка (нет ни настроек, ни конфига) → чисто', () async {
    expect(await ConfigDirtyCheck.isDirty(), isFalse);
  });

  test('конфиг есть, настроек нет → чисто', () async {
    await write(configFile(), base);
    expect(await ConfigDirtyCheck.isDirty(), isFalse);
  });

  test('настройки есть, конфига нет → грязно (надо собрать)', () async {
    await write(settingsFile(), base);
    expect(await ConfigDirtyCheck.isDirty(), isTrue);
  });

  test('настройки новее конфига → грязно', () async {
    await write(configFile(), base);
    await write(settingsFile(), base.add(const Duration(seconds: 5)));
    expect(await ConfigDirtyCheck.isDirty(), isTrue);
  });

  test('конфиг новее настроек → чисто', () async {
    await write(settingsFile(), base);
    await write(configFile(), base.add(const Duration(seconds: 5)));
    expect(await ConfigDirtyCheck.isDirty(), isFalse);
  });

  test('одна и та же секунда → чисто (сравнение с точностью до секунды)',
      () async {
    await write(configFile(), base);
    await write(settingsFile(), base);
    expect(await ConfigDirtyCheck.isDirty(), isFalse);
  });
}
