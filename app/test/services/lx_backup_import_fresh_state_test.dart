import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/services/lx_backup_import.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/template_loader.dart';
import 'package:lxbox/services/warp/warp_account.dart';
import 'package:lxbox/services/warp/warp_backup.dart';

import '../parser/engine_test_setup.dart';
import '../storage_migration/golden_harness.dart';

/// 017-BACKUP_AND_STORAGE · P25 — запись LX-импорта идёт по свежему
/// приёмнику: план пересчитывается при подтверждении, а не берётся из превью.
/// 017 · P13 (часть) — живая регистрация WARP импортом не перетирается.

WarpAccount _warp(String privKey) => WarpAccount(
      privKey: privKey,
      peerPub: 'cGVlcg==',
      clientV4: '172.16.0.2',
      clientV6: 'fd01::2',
      clientId: 'AQID',
      accountId: 'acc-$privKey',
      deviceId: 'dev-1',
      token: 'tok-1',
      endpoint: WarpAccount.defaultEndpoint,
      createdAt: '2026-01-01T00:00:00Z',
    );

String _file({
  List<Map<String, dynamic>> directions = const [],
  List<Map<String, dynamic>> warp = const [],
}) =>
    jsonEncode({
      'lx_backup': 2,
      'exported_by': {'app': 'launcher', 'version': '1.6.0'},
      'exported_at': '2026-09-15T00:00:00Z',
      'sources': [
        {
          'kind': 'server',
          'id': '01SRVF25000000000000000000',
          'tag': 'srv-a',
          'enabled': true,
          'body': {
            'type': 'trojan',
            'server': 'example-1.com',
            'server_port': 443,
            'password': 'testpass1',
          },
        },
      ],
      'directions': directions,
      if (warp.isNotEmpty) 'warp': warp,
    });

void main() {
  setUpAll(loadEngineSections);
  TestWidgetsFlutterBinding.ensureInitialized();

  late WizardTemplate template;
  setUpAll(() async {
    LocaleController.I.setting = 'en';
    template = await TemplateLoader.load();
  });
  tearDownAll(() {
    TemplateLoader.invalidate();
    LocaleController.I.setting = 'system';
  });

  Future<void> freshInstall() => SettingsStorage.migrateDirectionsIfNeeded(
        template.groupTemplates,
        varDefaults: {for (final v in template.vars) v.name: v.defaultValue},
      );

  group('P25 запись по свежему приёмнику', () {
    test('тег, занятый между превью и подтверждением, не перетирается',
        () async {
      final box = await StorageSandbox.create();
      addTearDown(box.dispose);
      await freshInstall();

      const importer = LxBackupImportService();
      final preview = await importer.prepare(_file(directions: [
        {'tag': 'ru-exit', 'filter': 'from-file'},
      ]));
      expect(preview.appliedDirections, 1,
          reason: 'на момент превью тег свободен');

      // Между превью и подтверждением приёмник завёл своё Направление
      // с тем же тегом (фоновая запись, другой экран).
      await SettingsStorage.setDirections([
        ...await SettingsStorage.getDirections(),
        const Direction(tag: 'ru-exit', label: 'Mine', nodeFilter: 'mine'),
      ]);

      final result = await importer.apply(preview);
      expect(result.appliedDirections, 0,
          reason: 'план пересчитан: тег уже занят');
      final mine = (await SettingsStorage.getDirections())
          .where((d) => d.tag == 'ru-exit')
          .toList();
      expect(mine, hasLength(1));
      expect(mine.single.nodeFilter, 'mine',
          reason: 'своё Направление приёмника осталось как было');
    });
  });

  group('P13 живая регистрация WARP', () {
    test('регистрация есть → запись файла не применяется', () async {
      final box = await StorageSandbox.create();
      addTearDown(box.dispose);
      await freshInstall();
      await SettingsStorage.setWarpAccount(_warp('bGl2ZQ=='));

      const importer = LxBackupImportService();
      await importer.apply(await importer.prepare(
          _file(warp: [warpAccountToBackup(_warp('ZmlsZQ=='))])));

      expect((await SettingsStorage.getWarpAccount())?.privKey, 'bGl2ZQ==');
    });

    test('регистрации нет → запись файла применяется', () async {
      final box = await StorageSandbox.create();
      addTearDown(box.dispose);
      await freshInstall();
      expect(await SettingsStorage.getWarpAccount(), isNull);

      const importer = LxBackupImportService();
      await importer.apply(await importer.prepare(
          _file(warp: [warpAccountToBackup(_warp('ZmlsZQ=='))])));

      expect((await SettingsStorage.getWarpAccount())?.privKey, 'ZmlsZQ==');
    });
  });
}
