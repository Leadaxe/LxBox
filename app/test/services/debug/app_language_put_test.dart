// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/app_log.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/settings.dart';
import 'package:lxbox/services/debug/transport/request.dart';
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

/// §607 — `PUT /settings/vars/app_language`: текст 400 перечисляет ровно
/// принимаемые значения ([SettingsStorage.appLanguageValues]); раньше в нём
/// не было `zh`, хотя `zh` принимается.
void main() {
  late Directory tmp;

  DebugContext ctx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 9, 30),
      );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('app_language_put_');
    await Directory('${tmp.path}/docs').create();
    await Directory('${tmp.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    SettingsStorage.resetCacheForTesting();
    AppLog.I.resetForTesting();
  });

  tearDown(() async {
    SettingsStorage.resetCacheForTesting();
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  test('invalid app_language → 400 listing every accepted value', () async {
    final req = DebugRequest.forTest(
      method: 'PUT',
      path: '/settings/vars/app_language',
      body: utf8.encode(jsonEncode({'value': 'xx'})),
    );
    final error = await settingsHandler(req, ctx())
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(error, isA<BadRequest>());
    final message = (error! as BadRequest).message;
    for (final v in SettingsStorage.appLanguageValues) {
      expect(message, contains('"$v"'));
    }
    expect(await SettingsStorage.getVar('app_language', 'system'), 'system');
  });
}
