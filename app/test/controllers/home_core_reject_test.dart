// ignore_for_file: depend_on_referenced_packages

// Фича 478 — ревью guard_builder_api: ожидание вердикта и stale-terminal.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/services/automation/automation_dispatcher.dart';
import 'package:lxbox/services/core_reject/core_reject_guard.dart';
import 'package:lxbox/services/core_reject/core_reject_state.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late HomeController controller;

  TunnelStatusEvent event(
    TunnelStatus status, {
    String? reason,
    String? coreError,
  }) {
    final raw = switch (status) {
      TunnelStatus.connected => 'Started',
      TunnelStatus.connecting => 'Starting',
      TunnelStatus.disconnected || TunnelStatus.revoked => 'Stopped',
      _ => status.name,
    };
    return TunnelStatusEvent(
      status: status,
      raw: raw,
      errorReason: reason,
      coreError: coreError,
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('home_core_reject_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    HapticService.I.enabled = false;
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    controller = HomeController();
  });

  tearDown(() async {
    controller.dispose();
    CoreRejectState.I.resetForTest();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('повторный startAndAwaitVerdict делит один completer', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'startVPN') return true;
      return null;
    });

    final first = controller.startAndAwaitVerdict(
      timeout: const Duration(seconds: 2),
    );
    final second = controller.startAndAwaitVerdict(
      timeout: const Duration(seconds: 2),
    );

    controller.debugHandleStatusEvent(event(TunnelStatus.connecting));
    controller.debugHandleStatusEvent(event(
      TunnelStatus.disconnected,
      coreError:
          'initialize outbound[0] vless[Frankfurt]: parse encryption: bad',
    ));

    final r1 = await first;
    final r2 = await second;
    expect(r1, contains('parse encryption'));
    expect(r2, r1);
  });

  test('startVPN=false завершает ожидание без 45 с', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'startVPN') return false;
      return null;
    });

    final sw = Stopwatch()..start();
    final err = await controller.startAndAwaitVerdict(
      timeout: const Duration(seconds: 45),
    );
    sw.stop();

    expect(err, isNotEmpty);
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('§498 — Disconnected скрывает плашку страховки', () {
    CoreRejectState.I.finish(const CoreRejectRun(
      outcome: CoreRejectOutcome.startedWithDisabled,
      disabled: [DisabledNode(tag: 'n1', reason: 'bad')],
    ));
    expect(CoreRejectState.I.bannerVisible, isTrue);

    controller.debugHandleStatusEvent(event(TunnelStatus.connected));
    controller.debugHandleStatusEvent(event(TunnelStatus.disconnected));

    expect(CoreRejectState.I.bannerVisible, isFalse);
    expect(CoreRejectState.I.disabled, isNotEmpty,
        reason: 'вердикт прогона на месте');
  });

  test('Stopped+core_error из stale-terminal резолвит completer', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'startVPN') return true;
      return null;
    });

    final fut = controller.startAndAwaitVerdict(
      timeout: const Duration(seconds: 2),
    );

    controller.debugHandleStatusEvent(event(
      TunnelStatus.disconnected,
      coreError: 'initialize outbound[1] vless[X]: bad key',
    ));

    final err = await fut;
    expect(err, contains('bad key'));
  });

  test('startVpnHeadless без старта сразу unavailable, без stale lastError',
      () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'startVPN') return false;
      if (call.method == 'startVpnHeadless') {
        return {'started': false, 'needs_consent': false};
      }
      return null;
    });
    await controller.start();

    final sw = Stopwatch()..start();
    final err = await controller.startAndAwaitVerdictHeadless(
      timeout: const Duration(seconds: 45),
    );
    sw.stop();

    expect(err, '');
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('startVpnHeadless=true ждёт core_error, не startVPN', () async {
    var startVpn = 0;
    var headless = 0;
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'startVPN') {
        startVpn++;
        return true;
      }
      if (call.method == 'startVpnHeadless') {
        headless++;
        return {'started': true, 'needs_consent': false};
      }
      return null;
    });

    final fut = controller.startAndAwaitVerdictHeadless(
      timeout: const Duration(seconds: 2),
    );
    controller.debugHandleStatusEvent(event(
      TunnelStatus.disconnected,
      coreError: 'initialize outbound[0] vless[X]: bad key',
    ));

    final err = await fut;
    expect(headless, 1);
    expect(startVpn, 0);
    expect(err, contains('bad key'));
  });

  // Ревью после v2.25.1, M2: Stop мимо кнопки фазы цикла тоже гасит прогон.
  group('M2 — любой Stop гасит идущий прогон страховки', () {
    Future<CoreRejectRun> startRun(_GatedCheckCore core) {
      final guard = CoreRejectGuard(core);
      CoreRejectState.I.beginRun();
      CoreRejectState.I.bindCancel(guard.cancel);
      return guard.run().then((r) {
        CoreRejectState.I.finish(r);
        return r;
      });
    }

    test('HomeController.stop() в фазе checking → финального старта нет',
        () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        if (call.method == 'stopVPN') return true;
        return null;
      });
      final core = _GatedCheckCore();
      final fut = startRun(core);
      await core.checkEntered.future;
      expect(CoreRejectState.I.phase, CoreRejectPhase.checking);

      // `POST /action/stop-vpn` и кнопка Stop сходятся сюда.
      await controller.stop();
      core.release.complete();
      final run = await fut;

      expect(run.outcome, CoreRejectOutcome.stoppedByUser);
      expect(core.realStarts, 1, reason: 'только сигнальный старт');
      expect(CoreRejectState.I.guardActive, isFalse);
      expect(CoreRejectState.I.phase, CoreRejectPhase.done);
    });

    test('нативный Stop (vpn-stop-requested) в фазе checking → старта нет',
        () async {
      registerAutomationBridge();
      final core = _GatedCheckCore();
      final fut = startRun(core);
      await core.checkEntered.future;

      // Плитка QS / Intent API / Locale: BoxVpnService.stop → VpnPlugin.
      // notifyStopRequested → automationAction на канале методов.
      final done = Completer<void>();
      await messenger.handlePlatformMessage(
        'com.leadaxe.lxbox/methods',
        const StandardMethodCodec().encodeMethodCall(const MethodCall(
          'automationAction',
          {'name': kVpnStopRequestedAction, 'args': <String, dynamic>{}},
        )),
        (_) => done.complete(),
      );
      await done.future;
      core.release.complete();
      final run = await fut;

      expect(run.outcome, CoreRejectOutcome.stoppedByUser);
      expect(core.realStarts, 1);
      expect(CoreRejectState.I.guardActive, isFalse);
    });
  });
}

/// Один негодный узел; `check` ждёт [release] — окно, в котором человек жмёт
/// Stop. Фазы уходят в [CoreRejectState], как у живого хоста.
class _GatedCheckCore implements CoreRejectHost {
  final checkEntered = Completer<void>();
  final release = Completer<void>();
  final disabled = <String>[];
  var realStarts = 0;

  @override
  Future<CoreAttempt> realStart() async {
    realStarts++;
    if (disabled.contains('Bad')) return const CoreAttempt.accepted();
    return const CoreAttempt.rejected(
        'initialize outbound[0] vless[Bad]: bad node');
  }

  @override
  Future<RebuiltConfig?> rebuild() async => RebuiltConfig(
      configJson: '{}',
      tags: disabled.contains('Bad') ? {'Good'} : {'Bad', 'Good'});

  @override
  Future<CoreAttempt> check(String configJson) async {
    if (!checkEntered.isCompleted) checkEntered.complete();
    await release.future;
    return const CoreAttempt.accepted();
  }

  @override
  Future<CoreRejectNodeRef?> disableNode(String tag, String reason) async {
    disabled.add(tag);
    return CoreRejectNodeRef(sourceId: 's', nodeKey: tag);
  }

  @override
  Future<CoreRejectPrompt> askKeepChecking(int n) async =>
      CoreRejectPrompt.stop;

  @override
  void onProgress(
    CoreRejectPhase phase,
    int round, {
    List<DisabledNode> disabledNodes = const [],
  }) =>
      CoreRejectState.I
          .onProgress(phase, round, disabledNodes: disabledNodes);
}
