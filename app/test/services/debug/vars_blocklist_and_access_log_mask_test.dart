// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/debug_entry.dart';
import 'package:lxbox/services/app_log.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/settings.dart';
import 'package:lxbox/services/debug/transport/middleware/access_log.dart';
import 'package:lxbox/services/debug/transport/pipeline.dart';
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

/// 027-DEBUG_API P4 — `debug_token`/`debug_enabled`/`debug_port` не
/// перезаписываются через `/settings/vars` (409), иначе через API можно
/// заблокировать себе доступ. FEATURE.md отмечал "ban в /settings/vars —
/// no witness".
///
/// 027-DEBUG_API P7 (request log часть) — sensitive query-параметры
/// (`token`/`secret`/`auth`/`key`) замаскированы в строке access-лога, а не
/// просто в снимке хранилища. FEATURE.md отмечал "request log — no witness".
void main() {
  late Directory tmp;

  DebugContext ctx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 9, 30),
      );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('vars_blocklist_');
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

  group('PUT/DELETE /settings/vars/{key} — Debug API blocklist (P4)', () {
    for (final key in ['debug_token', 'debug_enabled', 'debug_port']) {
      test('PUT $key → 409, значение не меняется', () async {
        final before = await SettingsStorage.getVar(key, '');
        final req = DebugRequest.forTest(
          method: 'PUT',
          path: '/settings/vars/$key',
          body: utf8.encode(jsonEncode({'value': 'hacked'})),
        );
        await expectLater(
          settingsHandler(req, ctx()),
          throwsA(isA<Conflict>()
              .having((e) => e.message, 'message', contains(key))),
        );
        expect(await SettingsStorage.getVar(key, ''), before);
      });

      test('DELETE $key → 409, значение не удаляется', () async {
        await SettingsStorage.setVar(key, 'kept');
        final req = DebugRequest.forTest(
          method: 'DELETE',
          path: '/settings/vars/$key',
        );
        await expectLater(
          settingsHandler(req, ctx()),
          throwsA(isA<Conflict>()),
        );
        expect(await SettingsStorage.getVar(key, ''), 'kept');
      });
    }

    test('обычный var (не в blocklist) — PUT проходит', () async {
      final req = DebugRequest.forTest(
        method: 'PUT',
        path: '/settings/vars/some_custom_flag',
        body: utf8.encode(jsonEncode({'value': 'on'})),
      );
      final r = await settingsHandler(req, ctx());
      expect((r as JsonResponse).status, 200);
      expect(await SettingsStorage.getVar('some_custom_flag', ''), 'on');
    });
  });

  group('accessLog middleware — маскирование sensitive query (P7)', () {
    Future<DebugResponse> okHandler(DebugRequest r, DebugContext c) async =>
        const JsonResponse({'ok': true});

    test('token в query замаскирован в строке лога, не попадает открытым текстом', () async {
      final req = DebugRequest.forTest(
        method: 'GET',
        path: '/state',
        query: {'token': 'super-secret-abc123'},
      );
      await runPipeline(req, ctx(), [accessLog()], okHandler);

      final entries = AppLog.I.entriesForSource(DebugSource.app);
      expect(entries, isNotEmpty);
      final line = entries.first.message;
      expect(line, isNot(contains('super-secret-abc123')));
      expect(line, contains('token=***'));
    });

    test('secret/auth/key замаскированы, обычный параметр — нет', () async {
      final req = DebugRequest.forTest(
        method: 'GET',
        path: '/state',
        query: {
          'client_secret': 'shh',
          'auth': 'bearer-xyz',
          'key': 'abcdef',
          'reveal': 'true',
        },
      );
      await runPipeline(req, ctx(), [accessLog()], okHandler);

      final line = AppLog.I.entriesForSource(DebugSource.app).first.message;
      expect(line, isNot(contains('shh')));
      expect(line, isNot(contains('bearer-xyz')));
      expect(line, isNot(contains('=abcdef')));
      expect(line, contains('client_secret=***'));
      expect(line, contains('auth=***'));
      expect(line, contains('key=***'));
      // reveal — не sensitive, значение проходит как есть.
      expect(line, contains('reveal=true'));
    });
  });
}
