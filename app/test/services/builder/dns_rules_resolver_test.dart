// §061 + §033: DNS rules resolver + applyCustomDns с unified kind set.
//
// Покрывает:
// - resolveDnsRulesList: orphan cleanup, auto-discovery, persist на изменении,
//   legacy-shape (старые kind=user/rule + поле title) — наверх не отдаётся,
//   в хранении остаётся (§439 A1)
// - applyCustomDns: kind=inline / kind=template / kind=preset / kind=srs
//   rendering, wizard-fields strip, enabled-skip, linear order

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/dns_ref.dart';
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

  // Сырые записи `dns.rules` в файл хранения формы 1.0 — для форм, которые
  // кодек не читает (репозиторий их не пишет).
  void seedRawRules(List<Map<String, dynamic>> rules) {
    File('${tmp.path}/lxbox_settings.json').writeAsStringSync(jsonEncode({
      'storage_version': 1,
      'dns': {'rules': rules},
    }));
  }

  // Файл хранения формы 2.23.2 (`dns_options.rules`): его разбирает миграция
  // в `_load` (§439).
  void seedLegacyRules(List<Map<String, dynamic>> rules) {
    File('${tmp.path}/lxbox_settings.json').writeAsStringSync(jsonEncode({
      'dns_options': {'rules': rules},
    }));
  }

  Future<List<dynamic>> rawRules() async {
    final raw = await SettingsStorage.exportRaw();
    return (raw['dns'] as Map)['rules'] as List;
  }

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
      expect(resolved[0], const DnsRulePreset(presetId: 'ru-direct', enabled: true));
      expect(resolved[1],
          const DnsRuleTemplate(name: 'Default → Google DoH', enabled: true));

      final stored = await SettingsStorage.getDnsRulesList();
      expect(stored, hasLength(2));
    });

    test('новый preset post-install: вставляется ПЕРЕД первой template-записью', () async {
      // Stored: один template и один inline (user)
      await SettingsStorage.saveDnsRulesList([
        const DnsRuleInline(name: 'My U', rule: {'server': 'u'}),
        const DnsRuleTemplate(name: 'T1', enabled: true),
      ]);

      final resolved = await resolveDnsRulesList(
        templateRules: [
          {'name': 'T1', 'enabled_default': true, 'server': 't1'},
        ],
        activePresetIdsWithDnsRule: {'new-preset-id'},
      );

      // Ожидаем: [inline, NEW_PRESET, T1] — preset вставлен ПЕРЕД template.
      expect(resolved, hasLength(3));
      expect(resolved[0], isA<DnsRuleInline>());
      expect((resolved[1] as DnsRulePreset).presetId, 'new-preset-id');
      expect((resolved[2] as DnsRuleTemplate).name, 'T1');
    });

    test('orphan cleanup: kind=template/preset с unknown identifier выбрасываются', () async {
      await SettingsStorage.saveDnsRulesList([
        const DnsRuleTemplate(name: 'Orphan template', enabled: true),
        const DnsRulePreset(presetId: 'orphan-preset', enabled: true),
        const DnsRuleInline(name: 'My user', rule: {'server': 'cf'}),
      ]);

      final resolved = await resolveDnsRulesList(
        templateRules: const [],
        activePresetIdsWithDnsRule: const {},
      );

      expect(resolved, hasLength(1));
      expect((resolved.single as DnsRuleInline).name, 'My user');
    });

    test('inline и srs всегда сохраняются, даже без template/preset', () async {
      await SettingsStorage.saveDnsRulesList([
        const DnsRuleInline(
          name: 'Disabled inline',
          rule: {'rule_set': 'foo', 'server': 'bar'},
          enabled: false,
        ),
        const DnsRuleSrs(
          id: 'ds_123',
          name: 'CN sites',
          srsUrl: 'https://example.com/cn.srs',
          server: 'cf_doh',
        ),
      ]);

      final resolved = await resolveDnsRulesList(
        templateRules: const [],
        activePresetIdsWithDnsRule: const {},
      );

      expect(resolved, hasLength(2));
      expect(resolved[0], isA<DnsRuleInline>());
      expect(resolved[1], isA<DnsRuleSrs>());
    });

    test('reorder сохраняется: stored entries в storage-order, новые в правильных местах', () async {
      // Юзер уже видел template, перетащил выше preset
      await SettingsStorage.saveDnsRulesList([
        const DnsRuleTemplate(name: 'A', enabled: true),
        const DnsRulePreset(presetId: 'p-id', enabled: true),
      ]);

      final resolved = await resolveDnsRulesList(
        templateRules: [
          {'name': 'A', 'enabled_default': true, 'server': 'x'},
          {'name': 'NEW', 'enabled_default': true, 'server': 'y'},
        ],
        activePresetIdsWithDnsRule: {'p-id', 'new-p-id'},
      );

      expect(resolved, hasLength(4));
      // Новый preset new-p-id вставляется ПЕРЕД первой template-записью (A).
      // §117 (решение №6): kind:preset записи — атомарная mirror-группа,
      // компактятся к позиции первой → p-id подтягивается к new-p-id,
      // standalone A не может стоять внутри группы. NEW — в конец.
      expect((resolved[0] as DnsRulePreset).presetId, 'new-p-id');
      expect((resolved[1] as DnsRulePreset).presetId, 'p-id');
      expect((resolved[2] as DnsRuleTemplate).name, 'A');
      expect((resolved[3] as DnsRuleTemplate).name, 'NEW');
    });

    test('enabled_default: false → новый template-default добавляется выключенным', () async {
      final resolved = await resolveDnsRulesList(
        templateRules: [
          {'name': 'OptIn', 'enabled_default': false, 'server': 'x'},
        ],
        activePresetIdsWithDnsRule: const {},
      );

      expect(resolved, hasLength(1));
      expect(resolved.single.enabled, false);
    });
  });

  group('§033 запись, которую кодек не читает: наверх не отдаётся, в хранении остаётся', () {
    test('legacy kind=user', () async {
      final legacy = {
        'enabled': true,
        'kind': 'user',
        'title': 'Legacy user',
        'rule': {'server': 'cf'},
      };
      seedRawRules([legacy]);

      final resolved = await resolveDnsRulesList(
        templateRules: const [],
        activePresetIdsWithDnsRule: const {},
      );

      expect(resolved, isEmpty, reason: 'kind=user не распознан');
      expect(await rawRules(), [legacy]);
    });

    test('legacy kind=rule (даже с валидным presetId)', () async {
      final legacy = {'enabled': true, 'kind': 'rule', 'presetId': 'ru-direct'};
      seedRawRules([legacy]);

      final resolved = await resolveDnsRulesList(
        templateRules: const [],
        activePresetIdsWithDnsRule: const {'ru-direct'},
      );

      // kind=rule не распознан → наверх не отдаётся. Auto-discovery видит,
      // что для presetId 'ru-direct' нет записи, и создаёт fresh kind=preset.
      expect(resolved,
          [const DnsRulePreset(presetId: 'ru-direct', enabled: true)]);
      expect(await rawRules(), [
        legacy,
        {'kind': 'preset', 'ref': 'ru-direct', 'enabled': true},
      ]);
    });

    test('legacy template с title (не name) → auto-discovery добавляет fresh', () async {
      final legacy = {'enabled': false, 'kind': 'template', 'title': 'Old default'};
      seedRawRules([legacy]);

      final resolved = await resolveDnsRulesList(
        templateRules: [
          {'name': 'Old default', 'enabled_default': true, 'server': 'x'},
        ],
        activePresetIdsWithDnsRule: const {},
      );

      // Legacy запись имеет title не name → не распознана.
      // Auto-discovery создаёт fresh с enabled_default=true (юзер потерял
      // свой OFF-toggle, ожидаемо при no-migration policy).
      expect(resolved,
          [const DnsRuleTemplate(name: 'Old default', enabled: true)]);
      expect(await rawRules(), [
        legacy,
        {'kind': 'template', 'name': 'Old default', 'enabled': true},
      ]);
    });
  });

  group('applyCustomDns (§033)', () {
    test('kind=template: copy without name/enabled_default wizard fields', () async {
      await SettingsStorage.saveDnsRulesList([
        const DnsRuleTemplate(name: 'Default → Google', enabled: true),
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
        const DnsRuleInline(
          name: 'My CF',
          rule: {'domain_suffix': ['example.com'], 'server': 'cloudflare_doh'},
        ),
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
        const DnsRulePreset(presetId: 'ru-direct', enabled: true),
      ]);

      final config = <String, dynamic>{};
      await applyCustomDns(
        config,
        {'servers': [], 'rules': []},
        extraDnsRulesByPresetId: const {
          // §253: пресет может нести несколько правил — legacy-ветка
          // (без dnsMirrors) эмитит ВСЕ, в порядке шаблона.
          'ru-direct': [
            {'rule_set': 'ru-domains', 'action': 'predefined', 'rcode': 'NOERROR'},
            {'rule_set': 'ru-domains', 'server': 'yandex_doh'},
          ],
        },
        activePresetIdsWithDnsRule: const {'ru-direct'},
      );

      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['rules'], [
        {'rule_set': 'ru-domains', 'action': 'predefined', 'rcode': 'NOERROR'},
        {'rule_set': 'ru-domains', 'server': 'yandex_doh'},
      ]);
    });

    test('kind=srs: cached path резолвится → rule_set добавляется в route + DNS rule эмитится', () async {
      await SettingsStorage.saveDnsRulesList([
        const DnsRuleSrs(
          id: 'ds_test',
          name: 'CN sites',
          srsUrl: 'https://example.com/cn.srs',
          server: 'cloudflare_doh',
        ),
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

    test(
        '§439 A1: inline без ключа enabled и srs формы §294 (server и условия '
        'в body) из файла 2.23.2 эмитятся', () async {
      seedLegacyRules([
        {
          'kind': 'inline',
          'name': 'Local',
          'rule': {'domain_suffix': ['lan'], 'server': 'local'},
        },
        {
          'kind': 'srs',
          'id': 'ds_body',
          'name': 'Body form',
          'body': {'server': 'cloudflare_doh', 'query_type': ['A']},
        },
      ]);

      final config = <String, dynamic>{};
      await applyCustomDns(
        config,
        {'servers': [], 'rules': []},
        dnsSrsCachedPaths: const {'ds_body': '/tmp/body.srs'},
      );

      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['rules'], [
        {'domain_suffix': ['lan'], 'server': 'local'},
        {
          'rule_set': 'Body form',
          'server': 'cloudflare_doh',
          'query_type': ['A'],
        },
      ]);
    });

    test('kind=srs без cached path: silently skip', () async {
      await SettingsStorage.saveDnsRulesList([
        const DnsRuleSrs(
          id: 'ds_test',
          name: 'CN sites',
          srsUrl: 'https://example.com/cn.srs',
          server: 'cloudflare_doh',
        ),
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
        const DnsRuleInline(name: 'Off', rule: {'server': 'x'}, enabled: false),
        const DnsRuleInline(name: 'On', rule: {'server': 'y'}),
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
        const DnsRulePreset(presetId: 'p-id', enabled: true),
        const DnsRuleInline(name: 'U', rule: {'server': 'u'}),
        const DnsRuleTemplate(name: 'T', enabled: true),
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
          'p-id': [
            {'server': 'p'},
          ],
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
