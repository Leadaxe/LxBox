// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/automation/event_emitter.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/sources.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

/// 014-AUTOMATION P13 — «Events carry no secrets». Свидетель отсутствовал
/// (591, §014). Сама эмиссия (event_emitter.dart) отправляет наружу ровно
/// то, что ей передал caller — маскирование делает
/// `subscription_controller` ДО вызова emit (`shortUrl =
/// maskSubscriptionUrl(list.url)`, используется и для лога, и для
/// `sub_id`). Проверяем именно этот шов: токен подписки, попавший в URL, не
/// должен долетать до `sub_id` в SUB_REFRESHED/SUB_REFRESH_FAILED — ни на
/// успехе, ни на провале.
void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;
  late List<(String, Map<String, Object?>)> sent;

  const secretToken = 'super-secret-token-abc123';
  const bodyA = 'vless://uuid-1@h1.example:443?type=ws&security=tls#A1\n';

  SubscriptionServers sub(String url) => SubscriptionServers(
        id: 's1',
        name: 's1',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: url,
      );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('automation_mask_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    fetchBackoffsForTesting = const [Duration.zero, Duration.zero];
    sent = [];
    AutomationEventEmitter.I.debugConfigureForTest(
      subs: true,
      onSend: (action, extras) => sent.add((action, extras)),
    );
  });

  tearDown(() async {
    fetchBackoffsForTesting = null;
    AutomationEventEmitter.I.debugConfigureForTest();
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  Future<SubscriptionController> boot(String url) async {
    await SettingsStorage.saveServerLists([sub(url)]);
    final c = SubscriptionController();
    await c.init();
    await c.rehydrationDone;
    return c;
  }

  group('P13 — sub_id не несёт токен подписки', () {
    test('успешный fetch: SUB_REFRESHED.sub_id замаскирован', () async {
      final url = 'https://provider.example/sub/$secretToken';
      final c = await boot(url);
      c.httpClientForTesting =
          MockClient((req) async => http.Response(bodyA, 200));

      await c.refreshEntry(c.entries.single);

      expect(sent, isNotEmpty);
      final event = sent.singleWhere((e) => e.$1 == 'SUB_REFRESHED');
      final subId = event.$2['sub_id'] as String;
      expect(subId, isNot(contains(secretToken)));
      expect(subId, 'https://provider.example/***');
    });

    test('провал fetch: SUB_REFRESH_FAILED.sub_id замаскирован', () async {
      final url = 'https://provider.example/sub/$secretToken';
      final c = await boot(url);
      c.httpClientForTesting =
          MockClient((req) async => throw const SocketException('offline'));

      await c.refreshEntry(c.entries.single);

      expect(sent, isNotEmpty);
      final event = sent.singleWhere((e) => e.$1 == 'SUB_REFRESH_FAILED');
      final subId = event.$2['sub_id'] as String;
      expect(subId, isNot(contains(secretToken)));
      expect(subId, 'https://provider.example/***');
    });
  });
}
