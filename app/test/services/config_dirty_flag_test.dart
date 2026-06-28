import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/config_dirty_check.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §113 — config-dirty флаг владеется `SettingsStorage`, поднимается
/// config-значимыми сейверами; `_save` при снятом флаге выравнивает mtime
/// конфига (`touchConfig`), чтобы bootstrap mtime-compare не дал ложного
/// «config changed» после kill приложения.
///
/// Pattern: ротация `getApplicationDocumentsPath()` через mocked
/// MethodChannel + `resetCacheForTesting()` (как в settings_storage_staging).
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  String configPath() => '${tmp.path}/singbox_config.json';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_dirty_');
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
      /* ignore */
    }
  });

  group('§113 — авто-dirty на config-значимых сейверах', () {
    test('config-значимые сейверы поднимают configDirty', () async {
      expect(SettingsStorage.configDirty, isFalse);

      await SettingsStorage.saveRouteFinal('vpn-1');
      expect(SettingsStorage.configDirty, isTrue);

      SettingsStorage.configDirty = false;
      await SettingsStorage.saveEnabledGroups({'g1'});
      expect(SettingsStorage.configDirty, isTrue);

      SettingsStorage.configDirty = false;
      await SettingsStorage.saveDnsServers([
        {'tag': 'local', 'address': '1.1.1.1'}
      ]);
      expect(SettingsStorage.configDirty, isTrue);

      SettingsStorage.configDirty = false;
      await SettingsStorage.setTunApps(
        const TunAppsConfig(mode: 'allow', packages: ['com.x']),
      );
      expect(SettingsStorage.configDirty, isTrue);
    });

    test('не-config сейверы (sort/ping/timestamp) НЕ поднимают флаг',
        () async {
      await SettingsStorage.setNodeSort('latency', const ['a', 'b']);
      expect(SettingsStorage.configDirty, isFalse);

      await SettingsStorage.savePingOptions({'url': 'https://x'});
      expect(SettingsStorage.configDirty, isFalse);

      await SettingsStorage.setLastGlobalUpdate(
          DateTime.utc(2026, 1, 1));
      expect(SettingsStorage.configDirty, isFalse);
    });

    test('setVar: config-var → dirty, прочий var → нет', () async {
      await SettingsStorage.setVar('log_level', 'debug'); // config-var
      expect(SettingsStorage.configDirty, isTrue);

      SettingsStorage.configDirty = false;
      await SettingsStorage.setVar('sort_mode', 'latency'); // не config-var
      expect(SettingsStorage.configDirty, isFalse);

      // машинно-генерируемые clash_* — вне allowlist (выходы сборки).
      await SettingsStorage.setVar('clash_secret', 'abc');
      expect(SettingsStorage.configDirty, isFalse);
    });
  });

  group('§113 — touch конфига при записи настроек', () {
    test('!dirty при _save → config-файл выровнен (isDirty=false)', () async {
      // Симулируем «конфиг записан раньше настроек» (инверсия §107):
      // config-файл с прошлым mtime, затем не-config запись настроек.
      final cfg = File(configPath());
      await cfg.writeAsString('{}');
      await cfg.setLastModified(DateTime(2020));

      // Не-config запись (флаг не поднимается) → _save → touch конфига.
      await SettingsStorage.setNodeSort('latency', const []);

      expect(SettingsStorage.configDirty, isFalse);
      expect(await ConfigDirtyCheck.isDirty(), isFalse,
          reason: 'touch выровнял mtime конфига → ложного dirty нет');
    });

    test('dirty при _save → config НЕ тронут (честно грязно)', () async {
      final cfg = File(configPath());
      await cfg.writeAsString('{}');
      await cfg.setLastModified(DateTime(2020));
      final before = cfg.lastModifiedSync();

      // config-значимая запись (свёрнут посреди правки — пересборки не было):
      // флаг поднят → touch НЕ зовётся → конфиг остаётся старым → isDirty=true.
      await SettingsStorage.saveRouteFinal('vpn-1');

      expect(SettingsStorage.configDirty, isTrue);
      expect(cfg.lastModifiedSync(), before,
          reason: 'dirty=true → config не тронут');
      expect(await ConfigDirtyCheck.isDirty(), isTrue,
          reason: 'настройки новее конфига и флаг грязный → пересобрать');
    });

    test('репро-сценарий: правка → снятие флага пересборкой → flush → чисто',
        () async {
      final cfg = File(configPath());
      await cfg.writeAsString('{}');
      await cfg.setLastModified(DateTime(2020));

      // 1. Правка config-настройки (staged) — флаг поднят.
      await SettingsStorage.setTunApps(
        const TunAppsConfig(mode: 'allow', packages: ['com.x']),
        flush: false,
      );
      expect(SettingsStorage.configDirty, isTrue);

      // 2. Пересборка на возврате к home: пишет конфиг (свежий mtime) и
      //    снимает флаг.
      await cfg.writeAsString('{"rebuilt":true}');
      SettingsStorage.configDirty = false;

      // 3. dispose-flush настроек на диск: !dirty → touch конфига.
      await SettingsStorage.flushToDisk();

      // 4. Эмуляция холодного старта после kill: bootstrap mtime-compare.
      expect(await ConfigDirtyCheck.isDirty(), isFalse,
          reason: 'после чистой правки kill не должен дать ложный баннер');
    });
  });
}
