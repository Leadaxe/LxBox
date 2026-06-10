import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §107 — staging: `setX(..., flush: false)` обновляет только in-memory
/// `_cache`; диск догоняет одним атомарным `flushToDisk()`. Главный
/// регрессионный сценарий: читатель (generateConfig на возврате к home)
/// видит staged-данные ДО дисковой записи — гонка «rebuild читает
/// несфлашенный storage» закрыта классом.
///
/// Pattern: ротация `getApplicationDocumentsPath()` через mocked
/// MethodChannel + `resetCacheForTesting()` (как в settings_storage_test).
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  String mainPath() => '${tmp.path}/lxbox_settings.json';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_staging_');
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
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } on FileSystemException {
      /* ignore — AppLog может дописывать async */
    }
  });

  Future<Map<String, dynamic>> readDisk() async =>
      jsonDecode(await File(mainPath()).readAsString()) as Map<String, dynamic>;

  group('§107 — staged writes (flush: false)', () {
    test('setVar(flush:false): кэш обновлён, диска нет', () async {
      await SettingsStorage.setVar('alpha', '1', flush: false);
      expect(await SettingsStorage.getVar('alpha', 'def'), '1');
      expect(File(mainPath()).existsSync(), isFalse,
          reason: 'диск не тронут до flushToDisk');
    });

    test('staged-серия + flushToDisk → файл содержит всё', () async {
      await SettingsStorage.setVar('alpha', '1', flush: false);
      await SettingsStorage.saveRouteFinal('vpn-1', flush: false);
      await SettingsStorage.saveEnabledGroups({'g1'}, flush: false);
      expect(File(mainPath()).existsSync(), isFalse);

      await SettingsStorage.flushToDisk();

      final disk = await readDisk();
      expect((disk['vars'] as Map)['alpha'], '1');
      expect(disk['route_final'], 'vpn-1');
      expect(disk['enabled_groups'], ['g1']);
    });

    test('default (flush:true) пишет сразу — поведение не изменилось',
        () async {
      await SettingsStorage.setVar('alpha', '1');
      expect(File(mainPath()).existsSync(), isTrue);
    });

    test('flushToDisk без загруженного кэша — no-op', () async {
      await SettingsStorage.flushToDisk();
      expect(File(mainPath()).existsSync(), isFalse);
    });
  });

  group('§107 — регрессия (rebuild читал несфлашенный storage)', () {
    test('staged custom rules видны читателю ДО дисковой записи', () async {
      // Имитация бага: правка правил staged (markDirty экрана), rebuild на
      // didPop читает storage — dispose-flush ещё не случился.
      final rule = CustomRuleInline(
        name: 'r1',
        domainSuffixes: ['example.com'],
        outbound: 'vpn-1',
      );
      await SettingsStorage.saveCustomRules([rule], flush: false);

      final read = await SettingsStorage.getCustomRules();
      expect(read, hasLength(1));
      expect(read.single.name, 'r1');
      expect(File(mainPath()).existsSync(), isFalse,
          reason: 'чтение шло из _cache — свежие правила без ожидания диска');
    });

    test('staged tun_apps + flushToDisk → round-trip с диска', () async {
      await SettingsStorage.setTunApps(
        const TunAppsConfig(mode: 'allow', packages: ['com.a']),
        flush: false,
      );
      await SettingsStorage.flushToDisk();
      SettingsStorage.resetCacheForTesting();

      final cfg = await SettingsStorage.getTunApps();
      expect(cfg.mode, 'allow');
      expect(cfg.packages, ['com.a']);
    });
  });

  group('§107 — cleanup удалённого ключа auto_rebuild', () {
    test('vars.auto_rebuild выбрасывается на первом save', () async {
      await File(mainPath()).writeAsString(jsonEncode({
        'vars': {'auto_rebuild': 'false', 'alpha': '1'},
      }));
      // Прогружаем кэш с диска, затем любой save.
      expect(await SettingsStorage.getVar('alpha', 'def'), '1');
      await SettingsStorage.setVar('beta', '2');

      final disk = await readDisk();
      expect((disk['vars'] as Map).containsKey('auto_rebuild'), isFalse,
          reason: 'stale-ключ чистится в _save() по образцу node_overrides');
      expect((disk['vars'] as Map)['alpha'], '1');
      expect((disk['vars'] as Map)['beta'], '2');
    });
  });
}
