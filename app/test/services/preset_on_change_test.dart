import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/preset_on_change.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §266 — on_change пресета FakeIP: `@rule_enable AND @dns_enable` → глушит
/// глобальную `resolve_enabled`. Тест на РЕАЛЬНОМ wizard_template.json.
void main() {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tmp;
  late SelectableRule fakeip;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_on_change_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
    final raw = File('assets/wizard_template.json').readAsStringSync();
    final tpl = WizardTemplate.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    fakeip = tpl.selectableRules.firstWhere((r) => r.presetId == 'fakeip');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('FakeIP enabled + dns_enable(default true) → resolve_enabled=false', () async {
    final cr = CustomRulePreset(name: 'FakeIP', presetId: 'fakeip', enabled: true);
    await applyPresetOnChange(fakeip, cr);
    expect(await SettingsStorage.getVar('resolve_enabled', 'true'), 'false');
  });

  test('FakeIP disabled → resolve_enabled=true (вернулась)', () async {
    // сначала выключаем
    await SettingsStorage.setVar('resolve_enabled', 'false');
    final cr = CustomRulePreset(name: 'FakeIP', presetId: 'fakeip', enabled: false);
    await applyPresetOnChange(fakeip, cr);
    expect(await SettingsStorage.getVar('resolve_enabled', 'x'), 'true');
  });

  test('FakeIP enabled но dns_enable=false → resolve_enabled=true', () async {
    final cr = CustomRulePreset(
      name: 'FakeIP',
      presetId: 'fakeip',
      enabled: true,
      varsValues: {'dns_enable': 'false'},
    );
    await applyPresetOnChange(fakeip, cr);
    expect(await SettingsStorage.getVar('resolve_enabled', 'x'), 'true',
        reason: 'DNS-аспект выключен → FakeIP не рулит DNS → resolve не глушим');
  });

  test('идемпотентность: повторный вызов даёт то же', () async {
    final cr = CustomRulePreset(name: 'FakeIP', presetId: 'fakeip', enabled: true);
    await applyPresetOnChange(fakeip, cr);
    await applyPresetOnChange(fakeip, cr);
    expect(await SettingsStorage.getVar('resolve_enabled', 'true'), 'false');
  });

  test('пресет без on_change (ru-direct) → resolve_enabled не трогается', () async {
    final raw = File('assets/wizard_template.json').readAsStringSync();
    final tpl = WizardTemplate.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    final ruDirect = tpl.selectableRules.firstWhere((r) => r.presetId == 'ru-direct');
    await SettingsStorage.setVar('resolve_enabled', 'true');
    final cr = CustomRulePreset(name: 'RU', presetId: 'ru-direct', enabled: true);
    await applyPresetOnChange(ruDirect, cr);
    expect(await SettingsStorage.getVar('resolve_enabled', 'x'), 'true',
        reason: 'ru-direct не несёт on_change — цель не меняется');
  });
}
