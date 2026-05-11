// §061 + §033: DNS rules resolver + applyCustomDns с unified kind set.
//
// Покрывает:
// - resolveDnsRulesList: orphan cleanup, auto-discovery, persist на изменении,
//   legacy-shape ignore (старые kind=user/rule + поле title silently dropped)
// - applyCustomDns: kind=inline / kind=template / kind=preset / kind=srs
//   rendering, wizard-fields strip, enabled-skip, linear order

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/settings_storage.dart';

void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_dns_test_');
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

  group('resolveDnsRulesList (§061 + §033)', () {
    test('первый запуск: storage пуст → preset перед template (default order)', () async {
      final templateRules = [
        {'name': 'Default → Google DoH', 'enabled_default': true, 'server': 'google_doh'},
      ];

      final resolved = await resolveDnsRulesList(
        templateRules: templateRules,
        activePresetIdsWithDnsRule: {'ru-direct'},
      );

      expect(resolved, hasLength(2));
      // Order: preset first (auto-discovery вставляет ПЕРЕД template-блоком),
      // потом template.
      expect(resolved[0]['kind'], 'preset');
      expect(resolved[0]['presetId'], 'ru-direct');
      expect(resolved[0]['enabled'], true);
      expect(resolved[1]['kind'], 'template');
      expect(resolved[1]['name'], 'Default → Google DoH');
      expect(resolved[1]['enabled'], true);

      final stored = await SettingsStorage.getDnsRulesList();
      expect(stored, hasLength(2));
    });

    test('новый preset post-install: вставляется ПЕРЕД первой template-записью', () async {
      // Stored: один template и один inline (user)
      await SettingsStorage.saveDnsRulesList([
        {'enabled': true, 'kind': 'inline', 'name': 'My U', 'rule': {'server': 'u'}},
        {'enabled': true, 'kind': 'template', 'name': 'T1'},
      ]);

      final resolved = await resolveDnsRulesList(
        templateRules: [
          {'name': 'T1', 'enabled_default': true, 'server': 't1'},
        ],
        activePresetIdsWithDnsRule: {'new-preset-id'},
      );

      // Ожидаем: [inline, NEW_PRESET, T1] — preset вставлен ПЕРЕД template.
      expect(resolved, hasLength(3));
      expect(resolved[0]['kind'], 'inline');
      expect(resolved[1]['kind'], 'preset');
      expect(resolved[1]['presetId'], 'new-preset-id');
      expect(resolved[2]['kind'], 'template');
      expect(resolved[2]['name'], 'T1');
    });

    test('orphan cleanup: kind=template/preset с unknown identifier выбрасываются', () async {
      await SettingsStorage.saveDnsRulesList([
        {'enabled': true, 'kind': 'template', 'name': 'Orphan template'},
        {'enabled': true, 'kind': 'preset', 'presetId': 'orphan-preset'},
        {'enabled': true, 'kind': 'inline', 'name': 'My user', 'rule': {'server': 'cf'}},
      ]);

      final resolved = await resolveDnsRulesList(
        templateRules: const [],
        activePresetIdsWithDnsRule: const {},
      );

      expect(resolved, hasLength(1));
      expect(resolved.single['kind'], 'inline');
      expect(resolved.single['name'], 'My user');
    });

    test('inline и srs всегда сохраняются, даже без template/preset', () async {
      await SettingsStorage.saveDnsRulesList([
        {
          'enabled': false,
          'kind': 'inline',
          'name': 'Disabled inline',
          'rule': {'rule_set': 'foo', 'server': 'bar'},
        },
        {
          'enabled': true,
          'kind': 'srs',
          'id': 'ds_123',
          'name': 'CN sites',
          'srsUrl': 'https://example.com/cn.srs',
          'server': 'cf_doh',
        },
      ]);

      final resolved = await resolveDnsRulesList(
        templateRules: const [],
        activePresetIdsWithDnsRule: const {},
      );

      expect(resolved, hasLength(2));
      expect(resolved[0]['kind'], 'inline');
      expect(resolved[1]['kind'], 'srs');
    });

    test('reorder сохраняется: stored entries в storage-order, новые в правильных местах', () async {
      // Юзер уже видел template, перетащил выше preset
      await SettingsStorage.saveDnsRulesList([
        {'enabled': true, 'kind': 'template', 'name': 'A'},
        {'enabled': true, 'kind': 'preset', 'presetId': 'p-id'},
      ]);

      final resolved = await resolveDnsRulesList(
        templateRules: [
          {'name': 'A', 'enabled_default': true, 'server': 'x'},
          {'name': 'NEW', 'enabled_default': true, 'server': 'y'},
        ],
        activePresetIdsWithDnsRule: {'p-id', 'new-p-id'},
      );

      expect(resolved, hasLength(4));
      // Stored entries сохраняют свой порядок: A (template), p-id (preset)
      // Новый preset new-p-id вставляется ПЕРЕД первой template-записью (A).
      // Новый template NEW добавляется в конец.
      expect(resolved[0]['kind'], 'preset');
      expect(resolved[0]['presetId'], 'new-p-id');
      expect(resolved[1]['kind'], 'template');
      expect(resolved[1]['name'], 'A');
      expect(resolved[2]['kind'], 'preset');
      expect(resolved[2]['presetId'], 'p-id');
      expect(resolved[3]['kind'], 'template');
      expect(resolved[3]['name'], 'NEW');
    });

    test('enabled_default: false → новый template-default добавляется выключенным', () async {
      final resolved = await resolveDnsRulesList(
        templateRules: [
          {'name': 'OptIn', 'enabled_default': false, 'server': 'x'},
        ],
        activePresetIdsWithDnsRule: const {},
      );

      expect(resolved, hasLength(1));
      expect(resolved.single['enabled'], false);
    });
  });

  group('§033 legacy ignore (no migration)', () {
    test('legacy kind=user silently dropped', () async {
      await SettingsStorage.saveDnsRulesList([
        {'enabled': true, 'kind': 'user', 'title': 'Legacy user', 'rule': {'server': 'cf'}},
      ]);

      final resolved = await resolveDnsRulesList(
        templateRules: const [],
        activePresetIdsWithDnsRule: const {},
      );

      expect(resolved, isEmpty,
          reason: 'kind=user не распознан → silently dropped');
    });

    test('legacy kind=rule silently dropped (orphan even with valid presetId)', () async {
      await SettingsStorage.saveDnsRulesList([
        {'enabled': true, 'kind': 'rule', 'presetId': 'ru-direct'},
      ]);

      final resolved = await resolveDnsRulesList(
        templateRules: const [],
        activePresetIdsWithDnsRule: const {'ru-direct'},
      );

      // kind=rule не распознан → запись отсеивается. Но auto-discovery видит
      // что для presetId 'ru-direct' нет записи и создаёт fresh kind=preset.
      expect(resolved, hasLength(1));
      expect(resolved.single['kind'], 'preset');
      expect(resolved.single['presetId'], 'ru-direct');
    });

    test('legacy template с title (не name) → orphan, но auto-discovery восстанавливает', () async {
      await SettingsStorage.saveDnsRulesList([
        {'enabled': false, 'kind': 'template', 'title': 'Old default'},
      ]);

      final resolved = await resolveDnsRulesList(
        templateRules: [
          {'name': 'Old default', 'enabled_default': true, 'server': 'x'},
        ],
        activePresetIdsWithDnsRule: const {},
      );

      // Legacy запись имеет title не name → не распознан → дропнут.
      // Auto-discovery создаёт fresh с enabled_default=true (юзер потерял
      // свой OFF-toggle, ожидаемо при no-migration policy).
      expect(resolved, hasLength(1));
      expect(resolved.single['kind'], 'template');
      expect(resolved.single['name'], 'Old default');
      expect(resolved.single['enabled'], true);
    });
  });

  group('applyCustomDns (§033)', () {
    test('kind=template: copy without name/enabled_default wizard fields', () async {
      await SettingsStorage.saveDnsRulesList([
        {'enabled': true, 'kind': 'template', 'name': 'Default → Google'},
      ]);

      final config = <String, dynamic>{};
      await applyCustomDns(
        config,
        {
          'servers': [{'tag': 'google_doh', 'type': 'https', 'server': 'dns.google'}],
          'rules': [
            {'name': 'Default → Google', 'enabled_default': true, 'server': 'google_doh'},
          ],
        },
      );

      expect(config['dns'], isA<Map>());
      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['rules'], [
        {'server': 'google_doh'},
      ]);
    });

    test('kind=inline: rule body берётся из самой записи', () async {
      await SettingsStorage.saveDnsRulesList([
        {
          'enabled': true,
          'kind': 'inline',
          'name': 'My CF',
          'rule': {'domain_suffix': ['example.com'], 'server': 'cloudflare_doh'},
        },
      ]);

      final config = <String, dynamic>{};
      await applyCustomDns(config, {'servers': [], 'rules': []});

      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['rules'], [
        {'domain_suffix': ['example.com'], 'server': 'cloudflare_doh'},
      ]);
    });

    test('kind=preset: body из extraDnsRulesByPresetId', () async {
      await SettingsStorage.saveDnsRulesList([
        {'enabled': true, 'kind': 'preset', 'presetId': 'ru-direct'},
      ]);

      final config = <String, dynamic>{};
      await applyCustomDns(
        config,
        {'servers': [], 'rules': []},
        extraDnsRulesByPresetId: const {
          'ru-direct': {'rule_set': 'ru-domains', 'server': 'yandex_doh'},
        },
        activePresetIdsWithDnsRule: const {'ru-direct'},
      );

      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['rules'], [
        {'rule_set': 'ru-domains', 'server': 'yandex_doh'},
      ]);
    });

    test('kind=srs: cached path резолвится → rule_set добавляется в route + DNS rule эмитится', () async {
      await SettingsStorage.saveDnsRulesList([
        {
          'enabled': true,
          'kind': 'srs',
          'id': 'ds_test',
          'name': 'CN sites',
          'srsUrl': 'https://example.com/cn.srs',
          'server': 'cloudflare_doh',
        },
      ]);

      final config = <String, dynamic>{};
      await applyCustomDns(
        config,
        {'servers': [], 'rules': []},
        dnsSrsCachedPaths: const {'ds_test': '/tmp/cn.srs'},
      );

      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['rules'], [
        {'rule_set': 'CN sites', 'server': 'cloudflare_doh'},
      ]);
      // rule_set зарегистрирован как local в route
      expect(config['route'], isA<Map>());
      final route = config['route'] as Map<String, dynamic>;
      expect(route['rule_set'], [
        {'type': 'local', 'tag': 'CN sites', 'format': 'binary', 'path': '/tmp/cn.srs'},
      ]);
    });

    test('kind=srs без cached path: silently skip', () async {
      await SettingsStorage.saveDnsRulesList([
        {
          'enabled': true,
          'kind': 'srs',
          'id': 'ds_test',
          'name': 'CN sites',
          'srsUrl': 'https://example.com/cn.srs',
          'server': 'cloudflare_doh',
        },
      ]);

      final config = <String, dynamic>{};
      await applyCustomDns(
        config,
        {'servers': [], 'rules': []},
        // dnsSrsCachedPaths empty → skip
      );

      final dns = config['dns'] as Map<String, dynamic>?;
      // dns.rules должен либо отсутствовать, либо быть пустым
      expect(dns?['rules'], anyOf(isNull, isEmpty));
    });

    test('enabled=false: правило пропускается', () async {
      await SettingsStorage.saveDnsRulesList([
        {
          'enabled': false,
          'kind': 'inline',
          'name': 'Off',
          'rule': {'server': 'x'},
        },
        {
          'enabled': true,
          'kind': 'inline',
          'name': 'On',
          'rule': {'server': 'y'},
        },
      ]);

      final config = <String, dynamic>{};
      await applyCustomDns(config, {'servers': [], 'rules': []});

      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['rules'], [
        {'server': 'y'},
      ]);
    });

    test('linear order: storage порядок == финальный dns.rules порядок', () async {
      await SettingsStorage.saveDnsRulesList([
        {'enabled': true, 'kind': 'preset', 'presetId': 'p-id'},
        {'enabled': true, 'kind': 'inline', 'name': 'U', 'rule': {'server': 'u'}},
        {'enabled': true, 'kind': 'template', 'name': 'T'},
      ]);

      final config = <String, dynamic>{};
      await applyCustomDns(
        config,
        {
          'servers': [],
          'rules': [
            {'name': 'T', 'server': 't'},
          ],
        },
        extraDnsRulesByPresetId: const {
          'p-id': {'server': 'p'},
        },
        activePresetIdsWithDnsRule: const {'p-id'},
      );

      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['rules'], [
        {'server': 'p'},
        {'server': 'u'},
        {'server': 't'},
      ]);
    });
  });
}
