import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/screens/home/home_dialogs.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/vpn/box_vpn_client.dart';

/// Feature 126 — persist-контракт first-run-шагов визарда. Проверяется через
/// реальный SettingsStorage (mock path_provider) + mock MethodChannel'а
/// VpnPlugin. Рендер самих barrier-диалогов не нужен — здесь только логика
/// «показать один раз»: какие native-вызовы шаг делает и какой флаг ставит.
///
/// Harness идентичен migration-тестам: tmp-dir + resetCacheForTesting.
void main() {
  late Directory tmp;
  const ppChannel = MethodChannel('plugins.flutter.io/path_provider');
  const vpnChannel = MethodChannel('com.leadaxe.lxbox/methods');
  final calls = <MethodCall>[];

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_wizard_');
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ppChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(ppChannel, null);
    m.setMockMethodCallHandler(vpnChannel, null);
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  void mockVpn() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(vpnChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'requestAddTile':
          return 'added';
        case 'isIgnoringBatteryOptimizations':
          return true; // whitelisted — battery-шаг выйдет рано
        default:
          return null;
      }
    });
  }

  group('maybeShowAddTilePrompt', () {
    testWidgets('first run: calls requestAddTile and sets persist flag',
        (tester) async {
      mockVpn();
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));

      await maybeShowAddTilePrompt(ctx, BoxVpnClient());

      expect(calls.where((c) => c.method == 'requestAddTile'), hasLength(1));
      expect(await SettingsStorage.getVar('wizard_addtile_v1', '0'), '1');
    });

    testWidgets('second run: flag already set → no native call', (tester) async {
      mockVpn();
      await SettingsStorage.setVar('wizard_addtile_v1', '1');
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));

      await maybeShowAddTilePrompt(ctx, BoxVpnClient());

      expect(calls.where((c) => c.method == 'requestAddTile'), isEmpty);
    });
  });

  group('maybeShowBatteryOptimizationDialog', () {
    testWidgets('whitelisted → early return, no persist flag set',
        (tester) async {
      mockVpn(); // isIgnoringBatteryOptimizations → true
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));

      await maybeShowBatteryOptimizationDialog(ctx, BoxVpnClient());

      // Не в whitelist → флаг не ставится (повторно спросим когда понадобится).
      expect(await SettingsStorage.getVar('wizard_battery_v1', '0'), '0');
    });
  });
}
