import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/services/builder/preset_expand.dart' show PresetNode;
import 'package:lxbox/services/dns/dns_controller.dart';
import 'package:lxbox/services/settings_storage.dart';

/// §300 — DnsController.stage(): byte-identical staged-запись DNS-секции
/// (замена stageChanges). Пишет dns_servers/dns_rules/dns-vars c flush:false;
/// custom_rules НЕ трогает (это §295).
void main() {
  late Directory tmp;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_dnsctl_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method.startsWith('getApplicationDocuments')) return tmp.path;
      return null;
    });
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
  });

  test('stage() пишет servers/rules/dns-vars в storage', () async {
    final servers = <DnsServerRef>[
      const DnsServerInline(enabled: true, tag: 't', body: {'type': 'udp'}),
    ];
    final rules = <DnsRuleRef>[
      const DnsRuleInline(name: 'r', rule: {'server': 'x'}),
    ];
    await DnsController.stage(
      servers: servers,
      rules: rules,
      templateRulesByName: const {},
      presetRulesByPresetId: const {},
      strategy: 'ipv4_only',
      dnsFinal: 'cloudflare_udp',
      defaultResolver: 'local',
    );

    expect(await SettingsStorage.getVar('dns_strategy', ''), 'ipv4_only');
    expect(await SettingsStorage.getVar('dns_final', ''), 'cloudflare_udp');
    expect(await SettingsStorage.getVar('dns_default_domain_resolver', ''),
        'local');
    expect(await SettingsStorage.getDnsServers(), servers);
    expect(await SettingsStorage.getDnsRulesList(), rules);
  });

  test('stage() НЕ трогает custom_rules (§295 device-scope)', () async {
    // Заранее положим custom_rules; stage() не должен их стереть/тронуть.
    await SettingsStorage.saveCustomRules(const []);
    final before = await SettingsStorage.getCustomRules();
    await DnsController.stage(
      servers: const [],
      rules: const [],
      templateRulesByName: const {},
      presetRulesByPresetId: const {},
      strategy: 's',
      dnsFinal: 'f',
      defaultResolver: 'r',
    );
    final after = await SettingsStorage.getCustomRules();
    expect(after.length, before.length); // не тронуты
  });

  // §327 — дефолты резолверов приходят из `default_value` шаблона, а не из
  // литералов в коде. Регрессия на «после чистой установки оба поля пусты».
  group('§327 дефолты из шаблона', () {
    Future<Map<String, String>> templateDefaults() async {
      final raw = await rootBundle.loadString('assets/wizard_template.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, String>{};
      void walk(dynamic o) {
        if (o is Map) {
          final name = o['name'];
          if (name is String && o.containsKey('default_value')) {
            out[name] = '${o['default_value']}';
          }
          o.values.forEach(walk);
        } else if (o is List) {
          o.forEach(walk);
        }
      }

      walk(json);
      return out;
    }

    test('чистая установка — Final/Resolver/Strategy = default_value шаблона',
        () async {
      // Storage пуст: ни одного dns-var юзер не сохранял.
      final snap = await DnsController.load();
      final defaults = await templateDefaults();

      expect(snap.dnsFinal, defaults['dns_final']);
      expect(snap.defaultResolver, defaults['dns_default_domain_resolver']);
      expect(snap.strategy, defaults['dns_strategy']);
      // Не «выберите» — главный симптом §327.
      expect(snap.dnsFinal, isNotEmpty);
      expect(snap.defaultResolver, isNotEmpty);
    });

    test('пустая строка в storage трактуется как «не задано»', () async {
      // Тот самый осадок от stage(): '' — не отсутствие ключа, но и не выбор.
      await SettingsStorage.setVar('dns_final', '');
      await SettingsStorage.setVar('dns_default_domain_resolver', '');

      final snap = await DnsController.load();
      final defaults = await templateDefaults();

      expect(snap.dnsFinal, defaults['dns_final']);
      expect(snap.defaultResolver, defaults['dns_default_domain_resolver']);
    });

    test('сохранённый выбор юзера побеждает дефолт', () async {
      await SettingsStorage.setVar('dns_final', 'google_doh');
      await SettingsStorage.setVar(
          'dns_default_domain_resolver', 'cloudflare_udp');

      final snap = await DnsController.load();

      expect(snap.dnsFinal, 'google_doh');
      expect(snap.defaultResolver, 'cloudflare_udp');
    });

    test('исчезнувший тег сбрасывается на шаблонный дефолт, не на литерал',
        () async {
      await SettingsStorage.setVar('dns_final', 'no_such_server_tag');
      await SettingsStorage.setVar(
          'dns_default_domain_resolver', 'also_gone');

      final snap = await DnsController.load();
      final defaults = await templateDefaults();

      expect(snap.resolverReset, isTrue);
      expect(snap.dnsFinal, defaults['dns_final']);
      expect(snap.defaultResolver, defaults['dns_default_domain_resolver']);
    });
  });

  // §578 — серверы пресета с `for_each` видны на экране DNS как серверы
  // остальных пресетов; запись хранения без `preset_id` (тег `<узел>-dns`
  // без пространства), владелец — из пометки `_preset_id` тела.
  group('§578 пресет с for_each', () {
    Future<void> seedTailscalePreset() async {
      await SettingsStorage.saveCustomRules([
        CustomRulePreset(
            name: 'Tailscale networks', presetId: 'tailscale', orderNum: 945),
      ]);
    }

    test('серверы по узлам, хранение без preset_id, владелец из тела',
        () async {
      await seedTailscalePreset();
      final snap = await DnsController.load(presetNodes: const [
        PresetNode(tag: 'home-ts', body: {'type': 'tailscale'}),
        PresetNode(tag: 'vless-a', body: {'type': 'vless'}),
        PresetNode(tag: 'work-ts', body: {'type': 'tailscale'}),
      ]);

      expect(snap.presetServedTagsByPresetId['tailscale'],
          ['home-ts', 'work-ts']);
      expect(snap.presetServersByTag.keys,
          containsAll(['home-ts-dns', 'work-ts-dns']));
      expect(snap.presetServersByTag['home-ts-dns']!['_preset_id'],
          'tailscale');
      final stored = (await SettingsStorage.getDnsServers())
          .whereType<DnsServerPreset>()
          .where((s) => s.tag.endsWith('-ts-dns'))
          .toList();
      expect([for (final s in stored) s.tag], ['home-ts-dns', 'work-ts-dns']);
      // Тег не достроен до `tailscale:<тег>`.
      expect(stored.every((s) => !s.tag.startsWith('tailscale:')), isTrue);
    });

    test('узел с skip_presets не обслуживается, узлов нет — пусто', () async {
      await seedTailscalePreset();
      final snap = await DnsController.load(presetNodes: const [
        PresetNode(
            tag: 'home-ts', body: {'type': 'tailscale'}, skipPresets: true),
      ]);
      expect(snap.presetServedTagsByPresetId['tailscale'], isEmpty);
      expect(snap.presetServersByTag.keys.where((t) => t.endsWith('-dns')),
          isNot(contains('home-ts-dns')));
    });
  });

  // §580 — кэш DNS: три переменные новые, у сохранённого состояния их нет.
  group('§580 кэш DNS', () {
    test('сохранённое состояние без переменных — значения по умолчанию',
        () async {
      await SettingsStorage.setVar('dns_strategy', 'prefer_ipv4');
      await SettingsStorage.setVar('dns_final', 'cloudflare_udp');
      final snap = await DnsController.load();
      expect(snap.cacheCapacity, '4000');
      expect(snap.optimistic, isTrue);
      expect(snap.storeCache, isTrue);
    });

    test('сохранённое вне границ — значение по умолчанию', () async {
      await SettingsStorage.setVar('dns_cache_capacity', '100');
      final snap = await DnsController.load();
      expect(snap.cacheCapacity, '4000');
    });

    Future<void> stageCache(String capacity, bool opt, bool store) =>
        DnsController.stage(
          servers: const [],
          rules: const [],
          templateRulesByName: const {},
          presetRulesByPresetId: const {},
          strategy: 'ipv4_only',
          dnsFinal: 'dns_shield',
          defaultResolver: 'dns_shield',
          cacheCapacity: capacity,
          optimistic: opt,
          storeCache: store,
        );

    test('stage() пишет три переменные и помечает конфиг', () async {
      SettingsStorage.configDirty = false;
      await stageCache('8192', false, false);
      expect(await SettingsStorage.getVar('dns_cache_capacity', ''), '8192');
      expect(await SettingsStorage.getVar('dns_optimistic', ''), 'false');
      expect(await SettingsStorage.getVar('dns_store_cache', ''), 'false');
      expect(SettingsStorage.configDirty, isTrue);
      final snap = await DnsController.load();
      expect(snap.cacheCapacity, '8192');
      expect(snap.optimistic, isFalse);
      expect(snap.storeCache, isFalse);
    });

    test('stage() не сохраняет размер вне границ', () async {
      await stageCache('70000', true, true);
      expect(await SettingsStorage.getVar('dns_cache_capacity', ''), '');
    });
  });
}
