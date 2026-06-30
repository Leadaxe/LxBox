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

  // ВАЖНО: используем обычный `test()`, НЕ `testWidgets`. Проверяемые функции
  // при этих мок-ответах НЕ доходят до `showDialog(context)` — context живёт
  // только в ветках, которые здесь не достигаются (early-return по флагу /
  // whitelisted). Native-вызов идёт через `BoxVpnClient._invoke` с
  // `.timeout()`-таймером; в обычном `test()` MethodChannel-мок отвечает
  // синхронно → таймер отменяется мгновенно (как в box_vpn_client_test.dart).
  // testWidgets же гоняет это в fake-async зоне, где реальный Timer не
  // резолвится → pending timer → 10-минутный hang в CI. Фейковый context
  // нужен только чтобы удовлетворить сигнатуру — он не разыменовывается.
  group('maybeShowAddTilePrompt', () {
    test('first run: calls requestAddTile and sets persist flag', () async {
      mockVpn();
      await maybeShowAddTilePrompt(_FakeContext(), BoxVpnClient());
      expect(calls.where((c) => c.method == 'requestAddTile'), hasLength(1));
      expect(await SettingsStorage.getVar('wizard_addtile_v1', '0'), '1');
    });

    test('second run: flag already set → no native call', () async {
      mockVpn();
      await SettingsStorage.setVar('wizard_addtile_v1', '1');
      await maybeShowAddTilePrompt(_FakeContext(), BoxVpnClient());
      expect(calls.where((c) => c.method == 'requestAddTile'), isEmpty);
    });
  });

  group('maybeShowBatteryOptimizationDialog', () {
    test('whitelisted → early return, no persist flag set', () async {
      mockVpn(); // isIgnoringBatteryOptimizations → true
      await maybeShowBatteryOptimizationDialog(_FakeContext(), BoxVpnClient());
      // Не в whitelist → флаг не ставится (повторно спросим когда понадобится).
      expect(await SettingsStorage.getVar('wizard_battery_v1', '0'), '0');
    });
  });
}

/// Заглушка `BuildContext` — функции под тестом до него не доходят (early-
/// return), сигнатура удовлетворяется без разыменования. `mounted=false` —
/// защитный гард `if (!context.mounted) return` в диалог-функциях выйдет раньше
/// любого реального обращения к контексту, даже если поток дойдёт туда.
class _FakeContext implements BuildContext {
  @override
  bool get mounted => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
