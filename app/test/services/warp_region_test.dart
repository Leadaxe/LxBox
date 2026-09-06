import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/warp/warp_region.dart';

/// §425 — регион пулов WARP: настройка + автодетект.
void main() {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tmp;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_warp_region_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
    WarpRegion.resetForTest();
    WarpRegion.detectorOverride = null;
  });

  tearDown(() async {
    WarpRegion.detectorOverride = null;
    await tmp.delete(recursive: true);
  });

  test('normalizeWarpRegion: auto/default/cc; мусор → auto', () {
    expect(SettingsStorage.normalizeWarpRegion('auto'), 'auto');
    expect(SettingsStorage.normalizeWarpRegion('Default'), 'default');
    expect(SettingsStorage.normalizeWarpRegion(' RU '), 'ru');
    expect(SettingsStorage.normalizeWarpRegion('rus'), 'auto');
    expect(SettingsStorage.normalizeWarpRegion(''), 'auto');
  });

  test('дефолт настройки — auto; set/get нормализуют', () async {
    expect(await SettingsStorage.getWarpRegion(), 'auto');
    await SettingsStorage.setWarpRegion('IL');
    expect(await SettingsStorage.getWarpRegion(), 'il');
    expect(SettingsStorage.allowedVarKeys(const []), contains('warp_region'));
  });

  test('effective: auto → детект; default → корень; явный → как есть',
      () async {
    WarpRegion.detectorOverride = () async => 'RU';
    expect(await WarpRegion.effective(), 'ru');

    await SettingsStorage.setWarpRegion('default');
    expect(await WarpRegion.effective(), '');

    await SettingsStorage.setWarpRegion('il');
    expect(await WarpRegion.effective(), 'il');
  });

  test('detected: мусор от нативки → локаль/пусто, кэш на процесс', () async {
    WarpRegion.detectorOverride = () async => 'xyz';
    final d = await WarpRegion.detected();
    // Фолбэк на Platform.localeName: либо 2-буквенный код, либо пусто.
    expect(d.isEmpty || RegExp(r'^[a-z]{2}$').hasMatch(d), isTrue);
    WarpRegion.detectorOverride = () async => 'ru';
    expect(await WarpRegion.detected(), d, reason: 'кэш не сброшен');
    WarpRegion.resetForTest();
    expect(await WarpRegion.detected(), 'ru');
  });
}
