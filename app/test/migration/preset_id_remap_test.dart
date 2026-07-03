import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §228 — one-shot ремап переименованных preset_id в custom_rules:
///   bittorrent-direct → bittorrent
///   private-ip-direct → private-ip
///   block_unknown     → unknown-traffic
///
/// Инвариант: переписывается ТОЛЬКО presetId; varsValues (выбранный юзером
/// outbound) сохраняется. Harness как в channels_migration_test.dart.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  String mainPath() => '${tmp.path}/lxbox_settings.json';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_preset_remap_');
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
    } catch (_) {}
  });

  Future<void> seedFile(Map<String, dynamic> data) async {
    await File(mainPath()).writeAsString(jsonEncode(data));
    SettingsStorage.resetCacheForTesting();
  }

  Map<String, dynamic> presetRule(String presetId,
          {Map<String, String>? vars}) =>
      {
        'id': 'rule-$presetId',
        'name': presetId,
        'enabled': true,
        'kind': 'preset',
        'presetId': presetId,
        'varsValues': vars ?? <String, String>{},
      };

  test('переименовывает id, varsValues[outbound] сохраняется', () async {
    await seedFile({
      'custom_rules': [
        presetRule('bittorrent-direct', vars: {'outbound': 'vpn-2'}),
        presetRule('private-ip-direct'),
        presetRule('block_unknown', vars: {'outbound': 'reject'}),
      ],
    });

    await SettingsStorage.migrateRenamedPresetIds();

    final rules = await SettingsStorage.getCustomRules();
    final byOldName = {for (final r in rules) r.name: r};

    // presetId переписан на новые.
    expect((byOldName['bittorrent-direct'] as CustomRulePreset).presetId,
        'bittorrent');
    expect((byOldName['private-ip-direct'] as CustomRulePreset).presetId,
        'private-ip');
    expect((byOldName['block_unknown'] as CustomRulePreset).presetId,
        'unknown-traffic');

    // Выбранный outbound (varsValues) пережил ремап.
    expect(byOldName['bittorrent-direct']!.outbound, 'vpn-2');
    expect(byOldName['block_unknown']!.outbound, 'reject');
  });

  test('не трогает пресеты вне маппинга и user-rule', () async {
    await seedFile({
      'custom_rules': [
        presetRule('ru-direct', vars: {'outbound': 'vpn-1'}),
        presetRule('fakeip'),
        {
          'id': 'u1',
          'name': 'my rule',
          'enabled': true,
          'kind': 'domain',
          'domainSuffixes': ['example.com'],
          'outbound': 'vpn-3',
        },
      ],
    });

    await SettingsStorage.migrateRenamedPresetIds();

    final rules = await SettingsStorage.getCustomRules();
    final ru = rules.firstWhere((r) => r.name == 'ru-direct');
    expect((ru as CustomRulePreset).presetId, 'ru-direct'); // не тронут
    final fk = rules.firstWhere((r) => r.name == 'fakeip');
    expect((fk as CustomRulePreset).presetId, 'fakeip');
  });

  test('идемпотентна: повторный вызов не ломает уже переименованные', () async {
    await seedFile({
      'custom_rules': [
        presetRule('bittorrent-direct', vars: {'outbound': 'vpn-2'}),
      ],
    });

    await SettingsStorage.migrateRenamedPresetIds();
    // второй вызов — guard уже поднят, no-op
    await SettingsStorage.migrateRenamedPresetIds();

    final rules = await SettingsStorage.getCustomRules();
    expect((rules.single as CustomRulePreset).presetId, 'bittorrent');
    expect(rules.single.outbound, 'vpn-2');
  });

  test('пустой storage — no-op, не падает', () async {
    await seedFile({});
    await SettingsStorage.migrateRenamedPresetIds();
    expect(await SettingsStorage.getCustomRules(), isEmpty);
  });
}
