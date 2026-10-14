import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/settings_storage_keys.dart';

/// §578 — разовый шаг: поздний дефолтный пресет `tailscale` у пользователя
/// с уже сохранённым состоянием.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_late_presets_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => tmp.path);
    SettingsStorage.resetCacheForTesting();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  final shipped = jsonDecode(
      File('assets/wizard_template.json').readAsStringSync()) as Map<String, dynamic>;
  final template = WizardTemplate.fromJson(shipped);

  void writeDoc(Map<String, dynamic> doc) {
    File('${tmp.path}/lxbox_settings.json').writeAsStringSync(jsonEncode({
      kStorageVersionKey: kStorageVersion,
      ...doc,
    }));
  }

  Future<List<String>> presetIds() async => [
        for (final r in await SettingsStorage.getCustomRules())
          if (r is CustomRulePreset) r.presetId,
      ];

  test('дефолты засеяны раньше: пресет добавляется один раз', () async {
    writeDoc({'presets_migrated': true});
    expect(await SettingsStorage.seedLateDefaultPresets(template), isTrue);
    final rules = await SettingsStorage.getCustomRules();
    final ts = rules.whereType<CustomRulePreset>().single;
    expect(ts.presetId, 'tailscale');
    expect(ts.enabled, isTrue);
    expect(ts.orderNum, 945);

    // Удалённый пользователем пресет не возвращается.
    await SettingsStorage.saveCustomRules(const []);
    expect(await SettingsStorage.seedLateDefaultPresets(template), isFalse);
    expect(await presetIds(), isEmpty);
  });

  test('пресет уже есть — дубля нет', () async {
    writeDoc({'presets_migrated': true});
    await SettingsStorage.saveCustomRules([
      CustomRulePreset(name: 'x', presetId: 'tailscale', enabled: false),
    ]);
    expect(await SettingsStorage.seedLateDefaultPresets(template), isFalse);
    expect(await presetIds(), ['tailscale']);
  });

  test('свежая установка не трогается; первый seed закрывает шаг', () async {
    expect(await SettingsStorage.seedLateDefaultPresets(template), isFalse);
    expect(await presetIds(), isEmpty);
    await SettingsStorage.markDefaultsSeeded();
    expect(await SettingsStorage.seedLateDefaultPresets(template), isFalse);
    expect(await presetIds(), isEmpty);
  });

  // §644 — первый seed дефолтов идёт в хранилище (старт / сборка / Routing),
  // а не только на экране маршрутов.
  group('§644 первый seed дефолтов', () {
    final defaults = [
      for (final r in template.selectableRules)
        if (r.defaultEnabled) r.presetId,
    ];

    test('свежая установка: все default-пресеты, поздние закрыты', () async {
      expect(defaults, containsAll(['bittorrent', 'tailscale']));
      expect(await SettingsStorage.seedDefaultPresets(template), isTrue);
      expect(await presetIds(), defaults);
      expect(await SettingsStorage.hasDefaultsSeeded(), isTrue);
      // Поздний шаг после первого seed ничего не добавляет.
      expect(await SettingsStorage.seedLateDefaultPresets(template), isFalse);
      expect(await presetIds(), defaults);
    });

    test('разовый: удалённый пресет не возвращается', () async {
      await SettingsStorage.seedDefaultPresets(template);
      await SettingsStorage.saveCustomRules(const []);
      expect(await SettingsStorage.seedDefaultPresets(template), isFalse);
      expect(await presetIds(), isEmpty);
    });

    test('дефолты уже засеяны — не трогается', () async {
      writeDoc({'presets_migrated': true});
      expect(await SettingsStorage.seedDefaultPresets(template), isFalse);
      expect(await presetIds(), isEmpty);
    });

    test('пресет уже в правилах — дубля нет, выбор пользователя цел', () async {
      await SettingsStorage.saveCustomRules([
        CustomRulePreset(name: 'x', presetId: 'bittorrent', enabled: false),
      ]);
      expect(await SettingsStorage.seedDefaultPresets(template), isTrue);
      final rules = await SettingsStorage.getCustomRules();
      final bt = rules
          .whereType<CustomRulePreset>()
          .where((r) => r.presetId == 'bittorrent')
          .toList();
      expect(bt, hasLength(1));
      expect(bt.single.enabled, isFalse);
      expect(rules, hasLength(defaults.length));
    });
  });
}
