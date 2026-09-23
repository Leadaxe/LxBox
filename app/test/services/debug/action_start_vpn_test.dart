// ignore_for_file: depend_on_referenced_packages

// Ревью после v2.25.1, L2: `POST /action/start-vpn` без флага — прежний путь
// §494 «байт в байт», и контроллер подписок ему не нужен. После §494 хелпер
// требовал его ДО ветки guard и отвечал 409 там, где раньше стартовал.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/action.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
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

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('action_start_vpn_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    HapticService.I.enabled = false;
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, (call) async => null);
    }
    controller = HomeController();
    DebugRegistry.I.home = controller;
  });

  tearDown(() async {
    DebugRegistry.I.home = null;
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final ch in [methods, ccStatus, ccGroups]) {
      messenger.setMockMethodCallHandler(ch, null);
    }
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('без контроллера подписок → 200 и startVPN, а не 409', () async {
    expect(DebugRegistry.I.sub, isNull);
    final started = Completer<void>();
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'startVPN' && !started.isCompleted) {
        started.complete();
        return true;
      }
      return null;
    });

    final resp = await actionHandler(
      DebugRequest(
        method: 'POST',
        uri: Uri.parse('http://127.0.0.1:9269/action/start-vpn'),
        headers: const {},
        body: Uint8List(0),
        receivedAt: DateTime.utc(2026),
      ),
      DebugContext(registry: DebugRegistry.I, appStartedAt: DateTime.utc(2026)),
    );

    expect(resp, isA<JsonResponse>());
    await started.future;
  });
}
