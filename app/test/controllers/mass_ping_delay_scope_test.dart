// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/services/haptic_service.dart';
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

/// §325 — замеры пинга разложены по Направлениям: изоляция записи + фоллбэк чтения.
///
/// Регресс жалоб 4PDA #1289/#1290/#1376/#1381/#1382 («нажатие тест-пинга
/// сбрасывает данные глобально, а тест идёт только для текущего Направления»).
/// Раньше `lastDelay` был одной плоской картой: mass-ping чистил её целиком, а
/// заполнял лишь нодами выбранного Направления.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late HomeController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mass_ping_scope_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    HapticService.I.enabled = false;
    for (final ch in [methods, ccStatus, ccGroups]) {
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

  // Два Направления с замерами; выбран A.
  void seedTwoDirections() => controller.debugSeedNodeState(
        group: 'ch-a',
        activeNode: 'a1',
        groups: const ['ch-a', 'ch-b'],
        delayByDirection: const {
          'ch-a': {'a1': 120, 'shared': 200},
          'ch-b': {'b1': 90, 'shared': 310},
        },
      );

  group('изоляция записи', () {
    test('mass-ping не трогает карту другого Направления', () async {
      seedTwoDirections();

      unawaited(controller.runMassUrltest(order: const ['a1', 'shared']));
      expect(controller.massPingRunning, isTrue, reason: 'прогон должен идти');

      // Направление B нетронут целиком.
      expect(controller.state.delayByDirection['ch-b'],
          const {'b1': 90, 'shared': 310});
      // В Направлении A замеры пингуемых нод убраны — их место занял индикатор.
      expect(controller.state.delayByDirection['ch-a'], isEmpty);
      expect(controller.state.pingBusy['a1'], '…');
      expect(controller.state.pingBusy['shared'], '…');
    });

    test('переключение Направления само по себе замеры не трогает', () {
      seedTwoDirections();
      final before = controller.state.delayByDirection;

      controller.setSelectedGroup('ch-b');

      expect(controller.state.delayByDirection, before);
    });
  });

  group('фоллбэк чтения', () {
    test('свой замер Направления имеет приоритет и не помечается', () {
      seedTwoDirections();
      final s = controller.state;

      // 'shared' есть в обоих — берём значение выбранного Направления A.
      expect(s.delayOf('shared'), 200);
      expect(s.delayIsForeign('shared'), isFalse);
      expect(s.delayOf('a1'), 120);
      expect(s.delayIsForeign('a1'), isFalse);
    });

    test('нода без замера в своём Направлении берёт чужой и помечается', () {
      seedTwoDirections();
      final s = controller.state;

      // 'b1' мерили только в Направлении B — показываем как ориентир, но помечаем.
      expect(s.delayOf('b1'), 90);
      expect(s.delayIsForeign('b1'), isTrue);
    });

    test('ноду не мерили нигде → null, пометки нет', () {
      seedTwoDirections();
      final s = controller.state;

      expect(s.delayOf('never-tested'), isNull);
      expect(s.delayIsForeign('never-tested'), isFalse);
    });

    test('после смены Направления прежние замеры видны как чужие', () {
      seedTwoDirections();

      controller.setSelectedGroup('ch-b');
      final s = controller.state;

      // Своё в B.
      expect(s.delayOf('b1'), 90);
      expect(s.delayIsForeign('b1'), isFalse);
      expect(s.delayOf('shared'), 310);
      expect(s.delayIsForeign('shared'), isFalse);
      // Чужое из A — показано, но помечено (список не пустеет: жалоба #1290).
      expect(s.delayOf('a1'), 120);
      expect(s.delayIsForeign('a1'), isTrue);
    });
  });

  test('замеры вне Направления живут в scratch-ключе', () async {
    // selectedGroup == null — Направления нет (папки, проба подписок).
    controller.debugHandleStatusEvent(
      TunnelStatusEvent(status: TunnelStatus.connected, raw: 'Started'),
    );

    unawaited(controller.runMassUrltest(order: const ['x']));

    expect(controller.state.delayByDirection.keys, [HomeState.scratchDirection]);
  });
}
