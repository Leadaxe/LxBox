// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/automation/handlers.dart' as automation;
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/settings.dart';
import 'package:lxbox/services/debug/handlers/state.dart';
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

/// 019-CONFIG_EDITOR P6 — пока конфиг закреплён (§037), явный rebuild
/// через Debug API отвечает 409, а не молча перезаписывает pinned config.
/// Проверка на уровне `automation.actionRebuildConfig` (общий путь для
/// `/action/rebuild-config` и `/settings/rebuild-config`): лок проверяется
/// раньше, чем `ctx.requireSub()`/`requireHome()`, поэтому тест не требует
/// зарегистрированных контроллеров — незарегистрированный `DebugRegistry.I`
/// сам по себе доказывает порядок проверок (иначе тест упал бы на
/// requireSub(), а не на Conflict).
///
/// P7 (снятие пина при выключении Debug API из настроек) — UI-логика в
/// `app_settings_screen.dart:_toggleDebugApi`, виджет-состояние без чистого
/// Dart-слоя; FEATURE.md прямо отмечает «manual check (no autotest)» —
/// только на устройстве.
void main() {
  late Directory tmp;

  DebugContext ctx() => DebugContext(
    registry: DebugRegistry.I,
    appStartedAt: DateTime.utc(2026, 9, 30),
  );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('config_locked_');
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

  group('config_locked (§037) — rebuild gate (P6)', () {
    test(
      'locked=true → actionRebuildConfig бросает Conflict до requireSub/Home',
      () async {
        await SettingsStorage.setConfigLockedForDebug(true);
        await expectLater(
          automation.actionRebuildConfig(ctx()),
          throwsA(
            isA<Conflict>().having(
              (e) => e.message,
              'message',
              contains('config_locked'),
            ),
          ),
        );
      },
    );

    test(
      'locked=false → gate пропускает, падает дальше на requireSub (не на lock)',
      () async {
        await SettingsStorage.setConfigLockedForDebug(false);
        // Контроллеры в этом тесте не зарегистрированы — requireSub() тоже
        // кидает Conflict, но с другим сообщением ("subscription controller
        // not ready", не "config_locked"). Различие сообщений доказывает,
        // что при locked=false выполнение прошло lock-гейт и упало дальше.
        await expectLater(
          automation.actionRebuildConfig(ctx()),
          throwsA(
            isA<Conflict>().having(
              (e) => e.message,
              'message',
              isNot(contains('config_locked')),
            ),
          ),
        );
      },
    );

    test(
      'PUT /settings/config_locked {"locked":true} → GET /state/config_locked отдаёт true',
      () async {
        final put = DebugRequest.forTest(
          method: 'PUT',
          path: '/settings/config_locked',
          body: utf8.encode(jsonEncode({'locked': true})),
        );
        final putResp = await settingsHandler(put, ctx());
        expect((putResp as JsonResponse).status, 200);

        final get = DebugRequest.forTest(
          method: 'GET',
          path: '/state/config_locked',
        );
        final getResp = await stateHandler(get, ctx()) as JsonResponse;
        final body = getResp.body as Map<String, dynamic>;
        expect(body['locked'], true);
      },
    );

    test('PUT /settings/config_locked {"locked":false} снимает лок', () async {
      await SettingsStorage.setConfigLockedForDebug(true);
      final put = DebugRequest.forTest(
        method: 'PUT',
        path: '/settings/config_locked',
        body: utf8.encode(jsonEncode({'locked': false})),
      );
      await settingsHandler(put, ctx());
      expect(await SettingsStorage.getConfigLockedForDebug(), false);
    });
  });
}
