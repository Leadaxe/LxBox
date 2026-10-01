// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/settings.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$root/docs';
}

/// §606 — `PUT /settings/tun_apps`: `count` в ответе — число УНИКАЛЬНЫХ
/// имён, ровно столько, сколько легло в хранилище.
void main() {
  late Directory tmp;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('tun_apps_put_');
    await Directory('${tmp.path}/docs').create();
    await Directory('${tmp.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    SettingsStorage.resetCacheForTesting();
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  test('дубли в запросе: count = уникальных = сохранённых', () async {
    final r = await settingsHandler(
      DebugRequest.forTest(
        method: 'PUT',
        path: '/settings/tun_apps',
        body: utf8.encode(jsonEncode({
          'mode': 'allow',
          'packages': ['org.a', 'org.b', 'org.a', ' org.b ', ''],
        })),
      ),
      DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 9, 30),
      ),
    );
    final body = (r as JsonResponse).body as Map;
    expect(body['count'], 2);
    final saved = await SettingsStorage.getTunApps();
    expect(saved.packages.length, body['count']);
  });
}
