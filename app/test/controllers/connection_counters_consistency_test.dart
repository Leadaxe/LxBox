// ignore_for_file: depend_on_referenced_packages

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

/// P4 (012-LIVE_STATE / FEATURE.md) — «Connection counters are consistent»:
/// on the home screen "app connections" and "connections to servers" are
/// shown separately; the first (`connectionsIn`) equals the number shown on
/// the Statistics "Connections" card (`overview_tab`/`memory_detail_sheet`
/// both read `CcStatus.connectionsIn` verbatim — see `stats_screen.dart`
/// `_onStatus`: `_connsIn = s.connectionsIn`). `no witness` in FEATURE.md.
///
/// `_onCcStatus` (home_controller.dart) is the single place that turns a raw
/// `CcStatus` tick into `HomeState.traffic` — the same field
/// (`s.connectionsIn`) that both screens ultimately source from. This test
/// pins that mapping: home's `connectionsIn` must equal the raw
/// `CcStatus.connectionsIn` (what Stats shows), `connectionsOut` likewise,
/// and `activeConnections` must be their sum (task 194 §3.1 — NOT
/// independently computed, so the two screens cannot drift apart).
///
/// Mutation this test must catch: `_onCcStatus` stops copying
/// `s.connectionsIn`/`s.connectionsOut` 1:1 (e.g. swaps them, or derives
/// `activeConnections` from something other than their sum) — home's badge
/// would then disagree with Stats/Conns for the same core tick.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late HomeController controller;

  TunnelStatusEvent event(TunnelStatus status, {String? reason}) {
    final raw = switch (status) {
      TunnelStatus.connected => 'Started',
      TunnelStatus.connecting => 'Starting',
      TunnelStatus.disconnected || TunnelStatus.revoked => 'Stopped',
      _ => status.name,
    };
    return TunnelStatusEvent(status: status, raw: raw, errorReason: reason);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('conn_counters_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    HapticService.I.enabled = false;
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    controller = HomeController();
  });

  tearDown(() async {
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
      'CcStatus тик → HomeState.traffic: connectionsIn/Out 1:1, '
      'activeConnections = их сумма', () async {
    controller.debugHandleStatusEvent(event(TunnelStatus.connecting));
    controller.debugHandleStatusEvent(event(TunnelStatus.connected));
    // `_startCcStreams()` — unawaited внутри `_handleStatusEvent`; дать ему
    // долистать до `_cc.status.listen`, иначе первый тик уйдёт в никуда.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final codec = const StandardMethodCodec();
    final tick = <String, Object?>{
      'uplink': 0,
      'downlink': 0,
      'uplinkTotal': 1000,
      'downlinkTotal': 2000,
      'memory': 0,
      'goroutines': 0,
      'connectionsIn': 7,
      'connectionsOut': 3,
    };
    await messenger.handlePlatformMessage(
      'lxbox/cc/status',
      codec.encodeSuccessEnvelope(tick),
      (ByteData? reply) {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(controller.state.traffic.connectionsIn, 7,
        reason: 'home-бейдж "app connections" должен = CcStatus.connectionsIn '
            '(то же поле читает Stats "Connections in")');
    expect(controller.state.traffic.connectionsOut, 3,
        reason:
            'home-бейдж "connections to servers" должен = CcStatus.connectionsOut');
    expect(controller.state.traffic.activeConnections, 10,
        reason: 'activeConnections — сумма In+Out (task 194 §3.1), не '
            'отдельно посчитанное значение');
  });
}
