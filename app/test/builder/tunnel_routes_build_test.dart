import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/selectable_to_custom.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/settings_storage_keys.dart';
import 'package:lxbox/services/subscription/sources.dart';
import 'package:lxbox/services/template_loader.dart';

import '../parser/engine_test_setup.dart';

/// Задача 718 (контракт 1.1.161, TEMPLATE_LANG §6.10, TASKS_LXBOX §158 п.4(б))
/// — пресет `tunnel-routes` в собранном из боевого шаблона конфиге: DNS-правило
/// `preferred_by: [<тег>-dns]` стоит раньше `query_type: [A, AAAA]` пресета
/// `fakeip`, иначе домены туннеля уйдут в FakeIP. Два пути: правила сохранены
/// с пресетом сразу и существующая установка, куда пресет пришёл поздним
/// дефолтом при уже сохранённом порядке DNS-правил.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tmp;
  late WizardTemplate template;

  setUpAll(() async {
    await loadEngineSections();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lxbox_tunnel_routes_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => tmp.path);
    SettingsStorage.resetCacheForTesting();
    TemplateLoader.invalidate();
    template = await TemplateLoader.load();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  // Учётка и адрес — заглушки.
  const ovpnBody = '''
{
  "type": "openvpn-client",
  "tag": "office",
  "mode": "tls",
  "network": "udp",
  "servers": [{"server": "vpn.example.com", "server_port": 1194}],
  "username": "user",
  "password": "pass",
  "tls": {"enabled": true, "server_name": "vpn.example.com"}
}''';
  const vlessUri = 'vless://u1@h1.com:443?type=ws&security=tls&sni=h1.com#A';

  CustomRulePreset preset(String id) => selectableRuleToCustom(
    template.selectableRules.singleWhere((p) => p.presetId == id),
    template,
  );

  Future<void> writeState(List<String> lateSeeded) async {
    File('${tmp.path}/lxbox_settings.json').writeAsStringSync(
      jsonEncode({
        kStorageVersionKey: kStorageVersion,
        'presets_migrated': true,
        'late_presets_seeded': lateSeeded,
      }),
    );
    SettingsStorage.resetCacheForTesting();
  }

  Future<(BuildResult, String)> build() async {
    final ovpn = await parseFromSource(const InlineSource(ovpnBody));
    final vless = await parseFromSource(const InlineSource(vlessUri));
    final result = await buildConfig(
      lists: [
        UserServer(
          id: 'u-vless',
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: UserSource.paste,
          rawBody: vlessUri,
          nodes: vless.nodes,
        ),
        UserServer(
          id: 'u-ovpn',
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          origin: UserSource.paste,
          rawBody: ovpnBody,
          ownRoutes: true,
          nodes: ovpn.nodes,
        ),
      ],
      template: template,
      settings: BuildSettings(
        enabledGroups: const {'vpn-1', kAutoOutboundTag},
        customRules: await SettingsStorage.getCustomRules(),
      ),
    );
    final eps = (result.config['endpoints'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final tag = eps.singleWhere((e) => e['type'] == 'openvpn-client')['tag']
        as String;
    return (result, tag);
  }

  List<Map<String, dynamic>> listOf(Map<String, dynamic> config, String sec) =>
      (((config[sec] as Map?)?['rules'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  void expectOrder(BuildResult result, String tag) {
    final config = result.config;
    final dnsTag = '$tag-dns';
    printOnFailure(const JsonEncoder.withIndent(' ').convert(config['dns']));

    final servers = ((config['dns'] as Map)['servers'] as List)
        .cast<Map<String, dynamic>>();
    expect(
      servers.where((s) => s['type'] == 'openvpn' && s['tag'] == dnsTag),
      hasLength(1),
    );
    expect(
      servers.singleWhere((s) => s['tag'] == dnsTag)['endpoint'],
      tag,
    );

    final route = listOf(config, 'route');
    expect(
      route.any((r) => _eq(r, {
            'preferred_by': [tag],
            'outbound': tag,
          })),
      isTrue,
      reason: jsonEncode(route),
    );

    final dns = listOf(config, 'dns');
    final own = dns.indexWhere((r) => _eq(r, {
          'preferred_by': [dnsTag],
          'server': dnsTag,
        }));
    final fake = dns.indexWhere(
      (r) =>
          r['query_type'] is List &&
          (r['query_type'] as List).contains('A') &&
          (r['query_type'] as List).contains('AAAA'),
    );
    expect(own, greaterThanOrEqualTo(0), reason: jsonEncode(dns));
    expect(fake, greaterThanOrEqualTo(0), reason: jsonEncode(dns));
    expect(own, lessThan(fake), reason: jsonEncode(dns));
  }

  test('правила с пресетом: DNS-правило туннеля раньше fakeip', () async {
    await writeState(const ['tailscale', 'tunnel-ingress', 'tunnel-routes']);
    await SettingsStorage.saveCustomRules([
      preset('traffic-processing'),
      preset('private-ip'),
      preset('fakeip')..enabled = true,
      preset('tunnel-routes')..enabled = true,
    ]);
    final (result, tag) = await build();
    expectOrder(result, tag);
  });

  test(
    'поздний дефолт при сохранённом порядке DNS-правил: тот же порядок',
    () async {
      await writeState(const ['tailscale', 'tunnel-ingress']);
      await SettingsStorage.saveCustomRules([
        preset('traffic-processing'),
        preset('tailscale'),
        preset('tunnel-ingress'),
        preset('private-ip'),
        preset('fakeip')..enabled = true,
      ]);
      await SettingsStorage.saveDnsRulesList([
        const DnsRulePreset(presetId: 'tunnel-ingress'),
        const DnsRulePreset(presetId: 'tailscale'),
        const DnsRulePreset(presetId: 'fakeip'),
      ]);
      expect(await SettingsStorage.seedLateDefaultPresets(template), isTrue);
      final tr = (await SettingsStorage.getCustomRules())
          .whereType<CustomRulePreset>()
          .singleWhere((r) => r.presetId == 'tunnel-routes');
      expect(tr.orderNum, 943);

      final (result, tag) = await build();
      expectOrder(result, tag);
    },
  );
}

bool _eq(Map<String, dynamic> a, Map<String, dynamic> b) =>
    jsonEncode(a) == jsonEncode(b);
