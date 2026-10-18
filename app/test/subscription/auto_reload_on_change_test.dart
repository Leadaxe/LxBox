// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/tunnel_status.dart';
import 'package:lxbox/services/haptic_service.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/auto_updater.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tempRoot);
  final String tempRoot;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempRoot;
  @override
  Future<String?> getApplicationSupportPath() async => tempRoot;
}

/// §338 — галка «автоперезапуск VPN при смене настроек».
///
/// §667 — гейт переехал в `HomeController.applyIfAutoReload` и проверяется на
/// реальном контроллере с замоканным native-каналом (приём
/// `reload_schedules_autoping_test.dart`): четыре условия порознь, повтор
/// после cooldown.
SubscriptionServers _sub(SubscriptionOnUpdateAction action) =>
    SubscriptionServers(
      id: 'x',
      name: 'x',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      url: 'https://example.com/sub',
      onUpdateAction: action,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('§338 effectiveOnUpdateAction — перекрытие per-subscription выбора', () {
    test('галка вкл → reload при ЛЮБОМ сохранённом значении', () {
      for (final a in SubscriptionOnUpdateAction.values) {
        expect(
          AutoUpdater.effectiveOnUpdateAction(_sub(a), autoReload: true),
          SubscriptionOnUpdateAction.reload,
          reason: 'сохранённое $a должно быть перекрыто',
        );
      }
    });

    test('галка выкл → значение поля подписки', () {
      for (final a in SubscriptionOnUpdateAction.values) {
        expect(
          AutoUpdater.effectiveOnUpdateAction(_sub(a), autoReload: false),
          a,
        );
      }
    });

    test('перекрытие НЕ мутирует поле — выключение вернёт выбор юзера', () {
      final list = _sub(SubscriptionOnUpdateAction.none);
      AutoUpdater.effectiveOnUpdateAction(list, autoReload: true);
      expect(list.onUpdateAction, SubscriptionOnUpdateAction.none);
      expect(
        AutoUpdater.effectiveOnUpdateAction(list, autoReload: false),
        SubscriptionOnUpdateAction.none,
      );
    });
  });

  group('§338/§667 гейт автоперезапуска — HomeController.applyIfAutoReload',
      () {
    const methods = MethodChannel('com.leadaxe.lxbox/methods');
    const ccStatus = MethodChannel('lxbox/cc/status');
    const ccGroups = MethodChannel('lxbox/cc/groups');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    late Directory tempDir;
    late HomeController controller;
    late List<String> calls;

    int reloads() => calls.where((m) => m == 'reloadVPN').length;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('auto_reload_gate_');
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
      SettingsStorage.resetCacheForTesting();
      HapticService.I.enabled = false;
      calls = <String>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        if (call.method == 'reloadVPN') return true;
        return null;
      });
      for (final ch in [ccStatus, ccGroups]) {
        messenger.setMockMethodCallHandler(ch, (call) async => null);
      }
      controller = HomeController();
    });

    tearDown(() async {
      controller.cancelMassPing();
      controller.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (final ch in [methods, ccStatus, ccGroups]) {
        messenger.setMockMethodCallHandler(ch, null);
      }
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    /// Все четыре условия: галка, connected, конфиг разошёлся, cooldown чист.
    Future<void> arm({bool flag = true, bool tunnelUp = true}) async {
      await SettingsStorage.setAutoReloadOnChange(flag);
      controller.debugSeedNodeState(
          group: 'vpn-1', activeNode: 'n1', tunnelUp: tunnelUp);
      controller.markConfigChangedNeedRestart();
    }

    test('все условия выполнены → reload, окно autoApplying закрыто', () async {
      await arm();
      final applied = await controller.applyIfAutoReload();
      expect(applied, isTrue);
      expect(reloads(), 1);
      expect(controller.state.autoApplying, isFalse,
          reason: 'окно подавления плашки закрывается вместе с reload');
      expect(controller.state.configChangedNeedRestart, isFalse,
          reason: 'успешный reload гасит флаг (§323 fix)');
    });

    test('галка выкл → нет (дефолтное поведение сохранено)', () async {
      await arm(flag: false);
      expect(await controller.applyIfAutoReload(), isFalse);
      expect(reloads(), 0);
      expect(controller.state.configChangedNeedRestart, isTrue,
          reason: 'плашка остаётся честным fallback\'ом');
    });

    test('туннель лежит → нет: «перезапуск» ≠ «запуск»', () async {
      await SettingsStorage.setAutoReloadOnChange(true);
      controller.debugSeedNodeState(
          group: 'vpn-1', activeNode: 'n1', tunnelUp: false);
      expect(await controller.applyIfAutoReload(), isFalse);
      expect(reloads(), 0);
      expect(controller.autoApplyRetryPendingForTesting, isFalse,
          reason: 'не-connected повтора не планирует: конфиг подхватит Start');
    });

    test('§324 вердикт fresh (needRestart=false) → нет: ядро уже на этом конфиге',
        () async {
      await SettingsStorage.setAutoReloadOnChange(true);
      controller.debugSeedNodeState(group: 'vpn-1', activeNode: 'n1');
      expect(await controller.applyIfAutoReload(), isFalse);
      expect(reloads(), 0);
    });

    test('cooldown → не сразу, а ровно один повтор после его истечения',
        () async {
      await arm();
      // Занять cooldown: ручной reload (кнопка) только что был.
      await controller.reloadVpn();
      expect(reloads(), 1);
      controller.markConfigChangedNeedRestart(); // новая правка в пределах 3 с

      expect(await controller.applyIfAutoReload(), isFalse,
          reason: 'в cooldown reload не уходит');
      expect(reloads(), 1);
      expect(controller.autoApplyRetryPendingForTesting, isTrue,
          reason: 'Д4 — срыв по cooldown планирует повтор');

      // Второй вызов во время ожидания второго таймера не ставит.
      expect(await controller.applyIfAutoReload(), isFalse);
      expect(controller.autoApplyRetryPendingForTesting, isTrue);

      final sw = Stopwatch()..start();
      while (reloads() < 2 && sw.elapsed < const Duration(seconds: 6)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(reloads(), 2, reason: 'повтор ушёл после cooldown');
      expect(controller.autoApplyRetryPendingForTesting, isFalse);
      // Удержание: повторов больше нет.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(reloads(), 2, reason: 'ровно один повтор, не цикл');
    });

    test('повтор перепроверяет условия: конфиг применили руками → reload нет',
        () async {
      await arm();
      await controller.reloadVpn();
      controller.markConfigChangedNeedRestart();
      expect(await controller.applyIfAutoReload(), isFalse);
      expect(controller.autoApplyRetryPendingForTesting, isTrue);
      // За время ожидания туннель перезапустили вручную: новый `connected`
      // гасит флаг (§323 intent-based reset).
      controller.debugHandleStatusEvent(const TunnelStatusEvent(
          status: TunnelStatus.connected, raw: 'connected'));
      expect(controller.state.configChangedNeedRestart, isFalse);
      final sw = Stopwatch()..start();
      while (controller.autoApplyRetryPendingForTesting &&
          sw.elapsed < const Duration(seconds: 6)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(reloads(), 1, reason: 'повтору нечего применять');
    });
  });
}
