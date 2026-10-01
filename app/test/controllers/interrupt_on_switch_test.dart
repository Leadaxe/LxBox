// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/services/haptic_service.dart';
import 'package:lxbox/services/settings_storage.dart';
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

/// P22 (012-LIVE_STATE / FEATURE.md) — «Breaking on node switch — only the
/// switched group»: с включённым «Interrupt connections on switch» после
/// успешного switchNode рвутся ТОЛЬКО живые соединения, чья `chains`
/// содержит переключаемую группу; соединения других групп не трогаются.
/// Свидетель отсутствовал (`no witness`, task 591 §012, строка 200).
///
/// Мутация, под которую тест обязан падать: если `_connectionIdsInGroup`
/// перестанет фильтровать по `chains.contains(group)` (например, станет
/// закрывать все живые соединения без разбора группы) — тест на "чужую"
/// группу поймает лишний `ccCloseConnection`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('com.leadaxe.lxbox/methods');
  const ccStatus = MethodChannel('lxbox/cc/status');
  const ccGroups = MethodChannel('lxbox/cc/groups');
  const ccConnections = MethodChannel('lxbox/cc/connections');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late HomeController controller;
  late List<String> closedIds;

  /// Снапшот соединений, отдаваемый EventChannel-стриму `_cc.connections`
  /// как ответ на 'listen' — `_connectionIdsInGroup` читает `.first`.
  List<Map<String, Object?>> snapshot = const [];

  Map<String, Object?> conn({
    required String id,
    required List<String> chains,
    bool closed = false,
  }) => {
    'id': id,
    'network': 'tcp',
    'domain': 'example.com',
    'destination': 'example.com:443',
    'rule': '',
    'uplink': 0,
    'downlink': 0,
    'chains': chains,
    'createdAt': 1000,
    'closedAt': closed ? 2000 : 0,
  };

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('interrupt_switch_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    HapticService.I.enabled = false;
    closedIds = [];
    snapshot = const [];

    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'ccSelectOutbound':
          return true;
        case 'ccGetGroups':
          return <dynamic>[];
        case 'ccCloseConnection':
          closedIds.add((call.arguments as Map)['id'] as String);
          return true;
      }
      return null;
    });
    for (final ch in [ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    // EventChannel `connections`: сам канал получает 'listen'/'cancel' через
    // тот же MethodChannel-механизм мока; отдаём текущий снапшот на listen,
    // дальше `_cc.connections.first` резолвится этим значением (см. паттерн
    // `_sharedStream` — постоянный upstream `receiveBroadcastStream`).
    messenger.setMockMethodCallHandler(ccConnections, (call) async {
      if (call.method == 'listen') {
        final codec = const StandardMethodCodec();
        final data = codec.encodeSuccessEnvelope(snapshot);
        await messenger.handlePlatformMessage(
          'lxbox/cc/connections',
          data,
          (ByteData? reply) {},
        );
      }
      return null;
    });

    await SettingsStorage.setInterruptOnSwitch(true);
    controller = HomeController();
  });

  tearDown(() async {
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final ch in [methods, ccStatus, ccGroups, ccConnections]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
      'switchNode с Interrupt=on закрывает только живые соединения '
      'переключаемой группы, не трогая другую', () async {
    controller.debugSeedNodeState(group: 'vpn-1', activeNode: '🇫🇮node');

    snapshot = [
      conn(id: 'c1', chains: ['vpn-1', 'selector']), // своя группа, живое
      conn(id: 'c2', chains: ['vpn-1'], closed: true), // своя группа, закрыто
      conn(id: 'c3', chains: ['vpn-2']), // чужая группа
      conn(id: 'c4', chains: const []), // без chains — прямой outbound
    ];
    // Подать свежий снапшот в уже-живой upstream (listen уже был на старте
    // контроллера) — пере-эмитим через тот же канал.
    final codec = const StandardMethodCodec();
    await messenger.handlePlatformMessage(
      'lxbox/cc/connections',
      codec.encodeSuccessEnvelope(snapshot),
      (ByteData? reply) {},
    );

    await controller.switchNode('🇩🇪other');

    expect(closedIds, ['c1'],
        reason: 'только живое соединение своей группы (vpn-1) должно рваться');
  });

  test(
      'switchNode с Interrupt=off не закрывает ничего, даже если есть '
      'живые соединения переключаемой группы', () async {
    await SettingsStorage.setInterruptOnSwitch(false);
    controller.debugSeedNodeState(group: 'vpn-1', activeNode: '🇫🇮node');

    snapshot = [conn(id: 'c1', chains: ['vpn-1'])];
    final codec = const StandardMethodCodec();
    await messenger.handlePlatformMessage(
      'lxbox/cc/connections',
      codec.encodeSuccessEnvelope(snapshot),
      (ByteData? reply) {},
    );

    await controller.switchNode('🇩🇪other');

    expect(closedIds, isEmpty,
        reason: 'выключенный тугл не должен рвать соединения');
  });
}
