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
}
