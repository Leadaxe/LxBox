import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/settings_storage.dart';

/// §713 — `ping_options.concurrency`: дефолт, clamp, мусор, сброс ключа.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_ping_concurrency_');
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

  test('без ключа — дефолт', () async {
    expect(await SettingsStorage.getPingConcurrency(),
        SettingsStorage.pingConcurrencyDefault);
  });

  test('запись/чтение, соседние поля ping_options не трогаются', () async {
    await SettingsStorage.setGlobalPingTimeout(4321);
    await SettingsStorage.setPingConcurrency(4);
    expect(await SettingsStorage.getPingConcurrency(), 4);
    final opts = await SettingsStorage.getPingOptions();
    expect(opts['timeout_ms'], 4321);
    expect(opts['concurrency'], 4);
  });

  test('clamp сверху и снизу на записи и на чтении', () async {
    await SettingsStorage.setPingConcurrency(999);
    expect(await SettingsStorage.getPingConcurrency(),
        SettingsStorage.pingConcurrencyMax);
    await SettingsStorage.setPingConcurrency(0);
    expect(await SettingsStorage.getPingConcurrency(),
        SettingsStorage.pingConcurrencyMin);
    // Рука/Debug API положили число мимо диапазона — читатель приводит.
    final opts = await SettingsStorage.getPingOptions();
    opts['concurrency'] = -5;
    await SettingsStorage.savePingOptions(opts);
    expect(await SettingsStorage.getPingConcurrency(),
        SettingsStorage.pingConcurrencyMin);
  });

  test('мусор в ключе → дефолт; null снимает ключ', () async {
    final opts = await SettingsStorage.getPingOptions();
    opts['concurrency'] = 'ten';
    await SettingsStorage.savePingOptions(opts);
    expect(await SettingsStorage.getPingConcurrency(),
        SettingsStorage.pingConcurrencyDefault);
    await SettingsStorage.setPingConcurrency(7);
    await SettingsStorage.setPingConcurrency(null);
    expect((await SettingsStorage.getPingOptions()).containsKey('concurrency'),
        isFalse);
    expect(await SettingsStorage.getPingConcurrency(),
        SettingsStorage.pingConcurrencyDefault);
  });
}
