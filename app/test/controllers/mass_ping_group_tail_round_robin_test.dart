// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/services/haptic_service.dart';
import 'package:lxbox/vpn/cc_channel.dart';
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

/// §677 — хвост mass-ping (§308) делает групповой force-URLTest только по
/// группам не-round_robin: у балансировщика ядро само тестирует пул, а force
/// тестировал бы всех членов и пересобирал пул (issue #171 п.16).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late HomeController controller;
  late List<String> groupUrltestCalls;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mass_ping_tail_rr_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    HapticService.I.enabled = false;
    groupUrltestCalls = <String>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'ccUrlTestGroup':
          groupUrltestCalls.add((call.arguments as Map)['tag'] as String);
          return true;
        case 'ccUrlTestOutbound':
          return <String, dynamic>{'delay': 100};
      }
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

  const members = ['n1', 'n2', 'n3'];

  Map<String, dynamic> urltest(String tag, Map<String, dynamic> extra) => {
        'type': 'urltest',
        'tag': tag,
        'outbounds': members,
        'url': 'https://cp.cloudflare.com/generate_204',
        ...extra,
      };

  final configJson = jsonEncode({
    'outbounds': [
      for (final n in members)
        {'type': 'socks', 'tag': n, 'server': '127.0.0.1', 'server_port': 1080},
      {
        'type': 'selector',
        'tag': 'vpn-1',
        'outbounds': ['fast', 'pool', 'hold', ...members],
      },
      urltest('fast', {'tolerance': 100}),
      urltest('pool', {
        'tolerance': 100,
        'mode': 'round_robin',
        'balancer': {'pool': 3, 'pool_tolerance': 0},
      }),
      urltest('hold', {'mode': 'failover'}),
    ],
  });

  CcGroup group(String tag, String type) => CcGroup(
        tag: tag,
        type: type,
        selectable: type == 'Selector',
        selected: '',
        isExpand: false,
        items: const [],
      );

  void seed() {
    controller.debugSeedNodeState(group: 'vpn-1', activeNode: 'n1');
    controller.debugSetCcGroups([
      group('vpn-1', 'Selector'),
      group('fast', 'URLTest'),
      group('pool', 'URLTest'),
      group('hold', 'URLTest'),
    ]);
  }

  Future<void> runMassPingAndTail() async {
    await controller.runMassUrltest(order: members);
    // Хвост — unawaited после прогона по узлам.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  test('round_robin пропущен, least_test и failover — групповой URLTest',
      () async {
    seed();
    controller.debugSetRunningConfigRaw(configJson);

    await runMassPingAndTail();

    expect(groupUrltestCalls, ['fast', 'hold']);
  });

  test('без снапшота ядра режим берётся из собранного конфига', () async {
    seed();
    controller.debugSetConfigRaw(configJson);

    await runMassPingAndTail();

    expect(groupUrltestCalls, ['fast', 'hold']);
  });
}
