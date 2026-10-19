// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
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

/// §647 — первое имя подписки из `profile-title` даёт `tagPrefix` из эмодзи
/// имени; дальше префикс автоматически не меняется.
void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;

  const body =
      'vless://uuid-1@h1.example:443?type=ws&security=tls#A1\n'
      'vless://uuid-2@h2.example:443?type=ws&security=tls#A2\n';
  // `Liberty VPN 🗽`
  const title = 'base64:TGliZXJ0eSBWUE4g8J+XvQ==';

  SubscriptionServers sub(
    String id, {
    String name = '',
    String tagPrefix = '',
  }) => SubscriptionServers(
    id: id,
    name: name,
    enabled: true,
    tagPrefix: tagPrefix,
    detourPolicy: DetourPolicy.defaults,
    url: 'http://x/$id',
  );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('emoji_prefix_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    fetchBackoffsForTesting = const [Duration.zero, Duration.zero];
  });

  tearDown(() async {
    fetchBackoffsForTesting = null;
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  Future<SubscriptionController> boot(List<ServerList> lists) async {
    await SettingsStorage.saveServerLists(lists);
    final c = SubscriptionController();
    await c.init();
    await c.rehydrationDone;
    c.httpClientForTesting = MockClient(
      (req) async =>
          http.Response(body, 200, headers: {'profile-title': title}),
    );
    return c;
  }

  SubscriptionServers listOf(SubscriptionController c, String id) => c.entries
      .map((e) => e.list)
      .whereType<SubscriptionServers>()
      .firstWhere((l) => l.id == id);

  test(
    'подписка без имени и префикса → имя и префикс 🗽; повторно не трогает',
    () async {
      final c = await boot([sub('s1')]);

      await c.refreshEntry(c.entries.single);
      var l = listOf(c, 's1');
      expect(l.name, 'Liberty VPN 🗽');
      expect(l.tagPrefix, '🗽');

      await c.refreshEntry(c.entries.single);
      l = listOf(c, 's1');
      expect(l.tagPrefix, '🗽');
    },
  );

  test('у подписки уже есть имя → префикс не появляется', () async {
    final c = await boot([sub('s1', name: 'Mine')]);

    await c.refreshEntry(c.entries.single);
    final l = listOf(c, 's1');
    expect(l.name, 'Mine');
    expect(l.tagPrefix, '');
  });

  test('префикс уже задан → не меняется', () async {
    final c = await boot([sub('s1', tagPrefix: 'LB')]);

    await c.refreshEntry(c.entries.single);
    final l = listOf(c, 's1');
    expect(l.name, 'Liberty VPN 🗽');
    expect(l.tagPrefix, 'LB');
  });

  test('импорт файла: имя из имени файла → префикс из его эмодзи', () async {
    final c = await boot([sub('s0', name: 'Other', tagPrefix: '🚀')]);

    expect(await c.addFileSubscription(body, '🚀 Fast.txt'), isTrue);
    final l = c.entries.last.list as SubscriptionServers;
    expect(l.name, '🚀 Fast');
    expect(l.tagPrefix, '🚀2');
  });

  test('🗽 занят другим источником → 🗽2', () async {
    final c = await boot([
      sub('s0', name: 'Other', tagPrefix: '🗽'),
      sub('s1'),
    ]);

    await c.refreshEntry(c.entries.firstWhere((e) => e.list.id == 's1'));
    expect(listOf(c, 's1').tagPrefix, '🗽2');
  });
}
