import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
    final servers = [
      {'enabled': true, 'kind': 'inline', 'tag': 't', 'body': {'type': 'udp'}},
    ];
    final rules = [
      {'kind': 'inline', 'name': 'r', 'rule': {'server': 'x'}},
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
    final savedServers = await SettingsStorage.getDnsServers();
    expect(savedServers.length, 1);
    expect(savedServers.first['tag'], 't');
    final savedRules = await SettingsStorage.getDnsRulesList();
    expect(savedRules.length, 1);
    expect(savedRules.first['name'], 'r');
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
}
