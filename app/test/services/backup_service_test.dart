import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/backup_service.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §040 backup-restore — round-trip и edge cases для нового single-format
/// (`storage` + `vpn_settings` блоки).
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_backup_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// Полный snapshot который имитирует «реальное» состояние юзера: vars +
  /// custom_rules + tun_apps + server_lists + dns_options.
  Map<String, dynamic> sampleSnapshot() => {
        'vars': {
          'log_level': 'info',
          'auto_update_subs': 'true',
          'auto_record_wifi_history': 'true',
          'wifi_history':
              '[{"ssid":"Home","bssid":"aa:bb:cc:dd:ee:ff","last_seen":"2026-05-10T12:00:00Z"}]',
          'debug_enabled': 'true',
          'debug_token': 'secret-token-xyz',
          'debug_port': '9269',
        },
        'custom_rules': [
          {
            'id': 'rule-1',
            'name': 'Ru Apps',
            'enabled': true,
            'kind': 'inline',
            'packages': ['ru.tinkoff.investing', 'com.vkontakte.android'],
            'outbound': 'vpn-2',
          },
        ],
        'tun_apps': {
          'mode': 'allow',
          'packages': ['com.example.app'],
        },
        'server_lists': [
          {
            'id': 'src-1',
            'type': 'subscription',
            'name': 'My subs',
            'url': 'https://example.com/sub',
          },
        ],
        'route_final': 'vpn-1',
        // §221 — directions (живая модель роутинга §125) + guard миграции.
        'channels': [
          {'tag': 'vpn-1', 'label': 'Main', 'enabled': true},
          {'tag': 'vpn-2', 'label': 'Backup', 'enabled': true},
        ],
        'channels_migrated': true,
        'enabled_groups': ['group-a'],
        'dns_options': {
          'servers': [
            {'tag': 'cloudflare', 'type': 'udp', 'server': '1.1.1.1'}
          ],
        },
      };

  Future<void> seedStorage(Map<String, dynamic> snapshot) async {
    await SettingsStorage.replaceRaw(snapshot);
  }

  test('exportRaw returns deep copy of full storage', () async {
    final snap = sampleSnapshot();
    await seedStorage(snap);
    final raw = await SettingsStorage.exportRaw();
    expect(raw['vars'], isA<Map<String, dynamic>>());
    expect((raw['custom_rules'] as List).length, 1);
    // Mutating returned map должно не аффектить storage (deep clone).
    raw['vars']['log_level'] = 'debug';
    final fresh = await SettingsStorage.exportRaw();
    expect(fresh['vars']['log_level'], 'info');
  });

  test('replaceRaw with merge=false overwrites everything', () async {
    await seedStorage(sampleSnapshot());
    await SettingsStorage.replaceRaw({
      'vars': {'log_level': 'warn'},
    });
    expect(await SettingsStorage.getVar('log_level', ''), 'warn');
    final cr = await SettingsStorage.getCustomRules();
    expect(cr, isEmpty);
  });

  test('replaceRaw with merge=true preserves untouched keys', () async {
    await seedStorage(sampleSnapshot());
    await SettingsStorage.replaceRaw(
      {
        'vars': {'log_level': 'warn'},
      },
      merge: true,
    );
    expect(await SettingsStorage.getVar('log_level', ''), 'warn');
    expect(await SettingsStorage.getVar('auto_update_subs', ''), 'true');
    final cr = await SettingsStorage.getCustomRules();
    expect(cr.length, 1, reason: 'custom_rules must be preserved on merge');
  });

  group('BackupService.buildExport', () {
    test('full export contains storage + metadata, no vpn_settings without toggle',
        () async {
      await seedStorage(sampleSnapshot());
      final svc = const BackupService();
      final json = await svc.buildExport(include: {
        BackupCategory.serverLists,
        BackupCategory.routing,
        BackupCategory.appSettings,
        BackupCategory.debugConfig,
      });
      final parsed = jsonDecode(json) as Map<String, dynamic>;
      expect(parsed['app'], 'lxbox');
      expect(parsed['kind'], 'backup');
      expect(parsed['created_at'], isA<String>());
      expect(parsed.containsKey('version'), isFalse,
          reason: 'new format does not use schema version');
      expect(parsed['storage'], isA<Map>());
      expect(parsed.containsKey('vpn_settings'), isFalse);
      final st = parsed['storage'] as Map<String, dynamic>;
      expect(st['custom_rules'], isA<List>());
      expect(st['tun_apps'], isA<Map>());
      expect(st['vars']['debug_token'], 'secret-token-xyz');
    });

    test('without debugConfig — debug-keys are stripped from vars', () async {
      await seedStorage(sampleSnapshot());
      final svc = const BackupService();
      final json = await svc.buildExport(include: {
        BackupCategory.serverLists,
        BackupCategory.routing,
        BackupCategory.appSettings,
      });
      final parsed = jsonDecode(json) as Map<String, dynamic>;
      final vars = (parsed['storage'] as Map<String, dynamic>)['vars']
          as Map<String, dynamic>;
      expect(vars.containsKey('debug_token'), isFalse);
      expect(vars.containsKey('debug_port'), isFalse);
      expect(vars.containsKey('debug_enabled'), isFalse);
      expect(vars['log_level'], 'info');
    });

    test('only debugConfig — keeps only debug-keys', () async {
      await seedStorage(sampleSnapshot());
      final svc = const BackupService();
      final json =
          await svc.buildExport(include: {BackupCategory.debugConfig});
      final parsed = jsonDecode(json) as Map<String, dynamic>;
      final vars = (parsed['storage'] as Map<String, dynamic>)['vars']
          as Map<String, dynamic>;
      expect(vars.keys.toSet(),
          {'debug_enabled', 'debug_token', 'debug_port'});
      expect((parsed['storage'] as Map).containsKey('custom_rules'), isFalse);
      expect((parsed['storage'] as Map).containsKey('server_lists'), isFalse);
    });

    test('only routing — top-level routing keys + no vars', () async {
      await seedStorage(sampleSnapshot());
      final svc = const BackupService();
      final json =
          await svc.buildExport(include: {BackupCategory.routing});
      final parsed = jsonDecode(json) as Map<String, dynamic>;
      final st = parsed['storage'] as Map<String, dynamic>;
      expect(st.containsKey('custom_rules'), isTrue);
      expect(st.containsKey('tun_apps'), isTrue);
      expect(st.containsKey('route_final'), isTrue);
      expect(st.containsKey('enabled_groups'), isTrue);
      expect(st.containsKey('dns_options'), isTrue);
      expect(st.containsKey('server_lists'), isFalse);
      expect(st.containsKey('vars'), isFalse);
    });

    test('§221 — ключи channels + channels_migrated экспортируются в routing', () async {
      await seedStorage(sampleSnapshot());
      final svc = const BackupService();
      final json = await svc.buildExport(include: {BackupCategory.routing});
      final st = (jsonDecode(json) as Map<String, dynamic>)['storage']
          as Map<String, dynamic>;
      // Регрессия: directions был в allowlist restore, но НЕ в export →
      // вся модель роутинг-Направлений §125 терялась при backup на новом устройстве.
      expect(st.containsKey('channels'), isTrue,
          reason: 'directions обязаны попадать в backup (§125 модель роутинга)');
      expect((st['channels'] as List), hasLength(2));
      expect(st.containsKey('channels_migrated'), isTrue,
          reason: 'guard миграции — иначе миграция пере-сработает поверх restore');
    });

    // §221 — инвариант против будущих забытых ключей: КАЖДЫЙ top-level ключ из
    // allowedTopLevelKeys (restore принимает) должен экспортироваться при
    // include={all} (иначе data-loss при backup, как было с directions).
    test('§221 — allowlist ⊆ export (все категории)', () async {
      // Снапшот с непустым значением для каждого allowlist-ключа.
      final snap = <String, dynamic>{};
      for (final k in SettingsStorage.allowedTopLevelKeys) {
        snap[k] = switch (k) {
          'vars' => {'log_level': 'info'},
          'server_lists' => [
              {'id': 's', 'type': 'subscription', 'name': 'n', 'url': 'http://x'}
            ],
          'dns_options' || 'tun_apps' || 'vpn_mode' || 'ping_options' ||
          'warp_account' || 'masque_account' =>
            {'_probe': 1},
          'channels' || 'custom_rules' || 'node_manual_order' ||
          'enabled_groups' || 'excluded_nodes' =>
            ['_probe'],
          'channels_migrated' || 'presets_migrated' ||
          'preset_ids_remapped' || 'interrupt_connections_on_switch' =>
            true,
          _ => '_probe', // строковые: route_final, node_sort_mode, ...
        };
      }
      await seedStorage(snap);
      final svc = const BackupService();
      final json = await svc.buildExport(include: {
        BackupCategory.serverLists,
        BackupCategory.routing,
        BackupCategory.appSettings,
        BackupCategory.debugConfig,
        BackupCategory.vpnSettings,
      });
      final st = (jsonDecode(json) as Map<String, dynamic>)['storage']
          as Map<String, dynamic>;
      final missing = SettingsStorage.allowedTopLevelKeys
          .where((k) => !st.containsKey(k))
          .toList();
      expect(missing, isEmpty,
          reason: 'ключи в allowlist restore, но НЕ в export → потеря при '
              'backup. Добавь в _topLevelRoutingKeys/_topLevelAppKeys '
              '(backup_service.dart): $missing');
    });

    // §349 — auto_ping_on_start был единственным var-сиротой: писался через
    // setVar, но не входил ни в allowlist, ни в template → export клал,
    // default-deny импорта дропал («1 unknown keys skipped» на свой же бэкап).
    test('§349 — auto_ping_on_start ∈ appFeatureFlagVars allowlist', () {
      expect(
          SettingsStorage.allowedVarKeys(const [])
              .contains('auto_ping_on_start'),
          isTrue,
          reason: 'настройка обязана переживать restore (§221-симметрия)');
    });

    // §279 — app_language: var-allowlist membership (иначе import дропает
    // неизвестный var → настройка не переживает restore).
    test('§279 — app_language ∈ appFeatureFlagVars allowlist', () {
      expect(SettingsStorage.allowedVarKeys(const []).contains('app_language'),
          isTrue,
          reason: 'app_language обязан переживать restore (§221-симметрия: '
              'export vars нефильтрован, import — по allowlist)');
    });

    // §279/§189 — guard: app_language НЕ член NativePrefsKeys. Членство
    // автоматически экспортировало бы его вторым представлением в
    // vpn_settings-блок бэкапа (неопределённый precedence на import);
    // boxvpn_boot-копия — derived cache, единственный дом бэкапа — vars.
    test('§279 — app_language ∉ NativePrefsKeys.all (derived cache)', () {
      expect(NativePrefsKeys.all.contains('app_language'), isFalse);
    });

    // §279 — полный export→import round-trip сохраняет app_language.
    test('§279 — app_language переживает export→import round-trip', () async {
      await seedStorage({
        'vars': {'app_language': 'ru'},
      });
      final exported = await SettingsStorage.exportRaw();
      SettingsStorage.resetCacheForTesting();
      await SettingsStorage.replaceRaw(exported);
      expect(await SettingsStorage.getAppLanguage(), 'ru');
    });
  });

  group('BackupService.parseImport', () {
    test('rejects non-JSON', () async {
      final svc = const BackupService();
      await expectLater(svc.parseImport('not json'),
          throwsA(isA<FormatException>()));
    });

    test('rejects file without app/kind markers', () async {
      final svc = const BackupService();
      await expectLater(
          svc.parseImport(jsonEncode({'storage': {}})),
          throwsA(isA<FormatException>()));
    });

    test('rejects legacy format (no storage key)', () async {
      final svc = const BackupService();
      final legacy = {
        'app': 'lxbox',
        'kind': 'backup',
        'version': 1,
        'vars': {'log_level': 'info'},
      };
      await expectLater(
          svc.parseImport(jsonEncode(legacy)),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('Unsupported'))));
    });

    test('parses minimal valid backup', () async {
      final svc = const BackupService();
      final raw = jsonEncode({
        'app': 'lxbox',
        'kind': 'backup',
        'created_at': '2026-05-10T12:00:00Z',
        'storage': {
          'vars': {'log_level': 'debug'},
        },
      });
      final c = await svc.parseImport(raw);
      expect(c.storage, isNotNull);
      expect(c.vpnSettings, isNull);
      expect(c.createdAt?.year, 2026);
    });
  });

  test('round-trip: export → reset → import → bytewise equal', () async {
    final original = sampleSnapshot();
    await seedStorage(original);
    final svc = const BackupService();
    final exported = await svc.buildExport(include: {
      BackupCategory.serverLists,
      BackupCategory.routing,
      BackupCategory.appSettings,
      BackupCategory.debugConfig,
    });

    // Wipe storage by replacing with empty.
    await SettingsStorage.replaceRaw({});
    expect(await SettingsStorage.getCustomRules(), isEmpty);

    // Restore.
    final contents = await svc.parseImport(exported);
    final apply = await svc.applyImport(
      contents,
      merge: false,
      include: {
        BackupCategory.serverLists,
        BackupCategory.routing,
        BackupCategory.appSettings,
        BackupCategory.debugConfig,
      },
    );
    expect(apply.errors, isEmpty);
    expect(apply.serverListsApplied, 1);

    // Compare key fields.
    final restored = await SettingsStorage.exportRaw();
    expect(restored['custom_rules'], original['custom_rules']);
    expect(restored['tun_apps'], original['tun_apps']);
    expect(restored['route_final'], original['route_final']);
    expect(restored['enabled_groups'], original['enabled_groups']);
    expect(restored['dns_options'], original['dns_options']);
    expect((restored['vars'] as Map)['log_level'], 'info');
    expect((restored['vars'] as Map)['debug_token'], 'secret-token-xyz');
    expect((restored['vars'] as Map)['wifi_history'],
        original['vars']['wifi_history']);
    expect((restored['server_lists'] as List).length, 1);
  });

  test('§248 — detour-роль Направления переживает backup round-trip', () async {
    // Restore пишет raw JSON мимо UI/storage-мутаторов — поле `detour`
    // обязано пережить export→restore и прочитаться в Direction.isDetour
    // (parse-гейт fromJson валидную роль не срезает).
    await seedStorage({
      'channels': [
        {'tag': 'vpn-1', 'label': 'Main', 'enabled': true},
        {'tag': 'vpn-2', 'label': 'Relay', 'enabled': true, 'detour': true},
      ],
      'channels_migrated': true,
    });
    final svc = const BackupService();
    final exported = await svc.buildExport(include: {BackupCategory.routing});
    // Сырое поле в самом бэкапе (формат переживает и ручную правку файла).
    final st = (jsonDecode(exported) as Map<String, dynamic>)['storage']
        as Map<String, dynamic>;
    expect(((st['channels'] as List)[1] as Map)['detour'], isTrue);

    // Wipe → restore.
    await SettingsStorage.replaceRaw({});
    final contents = await svc.parseImport(exported);
    final apply = await svc.applyImport(contents,
        merge: false, include: {BackupCategory.routing});
    expect(apply.errors, isEmpty);

    final restored = await SettingsStorage.getDirections();
    final vpn2 = restored.firstWhere((c) => c.tag == 'vpn-2');
    expect(vpn2.isDetour, isTrue,
        reason: 'detour-роль не должна теряться при restore');
    expect(restored.firstWhere((c) => c.tag == 'vpn-1').isDetour, isFalse);
  });

  test('§274 — detour+include_block переживают round-trip оба', () async {
    // §274 снял взаимоисключение ролей §248: detour-Направление — валидная цель
    // правил, парс-гейт fromJson больше не коэрсит include_block у detour.
    // Оба поля обязаны пережить export→restore как есть.
    await seedStorage({
      'channels': [
        {'tag': 'vpn-1', 'label': 'Main', 'enabled': true},
        {
          'tag': 'vpn-2',
          'label': 'Relay',
          'enabled': true,
          'detour': true,
          'include_block': true,
        },
      ],
      'channels_migrated': true,
    });
    final svc = const BackupService();
    final exported = await svc.buildExport(include: {BackupCategory.routing});

    await SettingsStorage.replaceRaw({});
    final contents = await svc.parseImport(exported);
    final apply = await svc.applyImport(contents,
        merge: false, include: {BackupCategory.routing});
    expect(apply.errors, isEmpty);

    final restored = await SettingsStorage.getDirections();
    final vpn2 = restored.firstWhere((c) => c.tag == 'vpn-2');
    expect(vpn2.isDetour, isTrue);
    expect(vpn2.includeBlock, isTrue,
        reason: 'include_block у detour-Направления не должен коэрситься (§274)');
  });

  group('§159 — allowlist (default-deny) на импорте', () {
    test('replaceRaw отбрасывает чужеродный top-level ключ', () async {
      final dropped = await SettingsStorage.replaceRaw({
        'vars': {'log_level': 'info'},
        'custom_rules': [],
        'totally_random_field_12345': {'nested': 'garbage'},
        'another_alien_key': 'x',
      });
      expect(dropped, containsAll(['totally_random_field_12345', 'another_alien_key']));
      final raw = await SettingsStorage.exportRaw();
      expect(raw.containsKey('totally_random_field_12345'), isFalse,
          reason: 'чужеродный top-level ключ не должен попасть в storage');
      expect(raw.containsKey('another_alien_key'), isFalse);
      // Валидные ключи остаются.
      expect((raw['vars'] as Map)['log_level'], 'info');
    });

    test('replaceRaw отбрасывает чужой vars-подключ, оставляет известные',
        () async {
      final dropped = await SettingsStorage.replaceRaw({
        'vars': {
          'log_level': 'debug', // template-var → ok
          'auto_update_subs': 'false', // app-флаг → ok
          'haptic_enabled': 'false', // app-флаг (был не в STORAGE.md) → ok
          'alien_var_xyz': 'should_be_dropped', // чужой → drop
        },
      });
      expect(dropped, contains('vars.alien_var_xyz'));
      final raw = await SettingsStorage.exportRaw();
      final vars = raw['vars'] as Map;
      expect(vars['log_level'], 'debug');
      expect(vars['auto_update_subs'], 'false');
      expect(vars['haptic_enabled'], 'false');
      expect(vars.containsKey('alien_var_xyz'), isFalse,
          reason: 'неизвестный var отбрасывается allowlist\'ом');
    });

    test('§219 — warp_account/masque_account переживают restore', () async {
      final dropped = await SettingsStorage.replaceRaw({
        'warp_account': {'private_key': 'wp'},
        'masque_account': {'priv_key_der': 'mp', 'endpoint': 'e'},
      });
      // Ни один не должен попасть в dropped (оба в allowlist).
      expect(dropped, isNot(contains('warp_account')));
      expect(dropped, isNot(contains('masque_account')));
      final raw = await SettingsStorage.exportRaw();
      expect(raw.containsKey('warp_account'), isTrue);
      expect(raw.containsKey('masque_account'), isTrue,
          reason: 'masque_account не должен теряться при restore (§130)');
    });

    test('merge=true тоже фильтрует чужие ключи', () async {
      await seedStorage({
        'vars': {'log_level': 'warn'},
      });
      final dropped = await SettingsStorage.replaceRaw(
        {
          'vars': {'alien_var': 'x', 'auto_check_updates': 'false'},
          'bogus_top': 1,
        },
        merge: true,
      );
      expect(dropped, containsAll(['vars.alien_var', 'bogus_top']));
      final raw = await SettingsStorage.exportRaw();
      expect((raw['vars'] as Map)['log_level'], 'warn',
          reason: 'merge сохраняет существующее');
      expect((raw['vars'] as Map)['auto_check_updates'], 'false');
      expect((raw['vars'] as Map).containsKey('alien_var'), isFalse);
      expect(raw.containsKey('bogus_top'), isFalse);
    });

    test('чистый бэкап (наш) ничего не отбрасывает', () async {
      final dropped = await SettingsStorage.replaceRaw(sampleSnapshot());
      expect(dropped, isEmpty,
          reason: 'все ключи sampleSnapshot валидны → drop пуст');
    });

    test('legacy top-level ключи отбрасываются (миграции удалены §159)',
        () async {
      final dropped = await SettingsStorage.replaceRaw({
        'vars': {'log_level': 'info'},
        'proxy_sources': [{'url': 'x'}],
        'app_rules': [{'packages': ['a']}],
        'enabled_rules': ['r1'],
        'rule_outbounds': {'r1': 'vpn-1'},
        'node_overrides': {'x': 1},
      });
      expect(
          dropped,
          containsAll([
            'proxy_sources',
            'app_rules',
            'enabled_rules',
            'rule_outbounds',
            'node_overrides',
          ]));
      final raw = await SettingsStorage.exportRaw();
      for (final k in [
        'proxy_sources',
        'app_rules',
        'enabled_rules',
        'rule_outbounds',
        'node_overrides'
      ]) {
        expect(raw.containsKey(k), isFalse, reason: '$k должен быть отброшен');
      }
    });
  });

  test(
      'partial restore: routing-only keeps existing app vars + adds custom_rules',
      () async {
    // Seed pre-existing state.
    await seedStorage({
      'vars': {'log_level': 'warn'},
    });

    final backup = jsonEncode({
      'app': 'lxbox',
      'kind': 'backup',
      'storage': {
        'custom_rules': [
          {
            'id': 'rule-x',
            'name': 'X',
            'enabled': true,
            'kind': 'preset',
            'presetId': 'ru-direct',
          },
        ],
      },
    });
    final svc = const BackupService();
    final c = await svc.parseImport(backup);
    final apply = await svc.applyImport(c,
        merge: true, include: {BackupCategory.routing});
    expect(apply.errors, isEmpty);

    // Existing vars preserved.
    expect(await SettingsStorage.getVar('log_level', ''), 'warn');
    // New custom_rules added.
    final cr = await SettingsStorage.getCustomRules();
    expect(cr.length, 1);
    expect(cr.first.name, 'X');
  });
}
