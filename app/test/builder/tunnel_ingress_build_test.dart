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

/// §656 (контракт 1.1.126/1.1.127, TASKS_LXBOX §123/§124) — пресет
/// `tunnel-ingress` поздним дефолтом у существующего пользователя и его место
/// в собранном конфиге: route-правило reject сразу за головой
/// `traffic-processing` (раньше `tailscale` и `private-ip`), DNS-reject — после
/// правила пользователя и раньше `query_type: [A, AAAA]` пресета `fakeip`.
/// DNS-часть пресета var `dns_enable` не имеет и выходит без неё (§257).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tmp;
  late WizardTemplate template;

  setUpAll(() async {
    await loadEngineSections();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lxbox_tunnel_ingress_');
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

  const wgIni =
      '[Interface]\n'
      'PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=\n'
      'Address = 10.8.0.2/32\n\n'
      '[Peer]\n'
      'PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=\n'
      'Endpoint = 203.0.113.1:51820\n'
      'AllowedIPs = 0.0.0.0/0\n';

  CustomRulePreset preset(String id) => selectableRuleToCustom(
    template.selectableRules.singleWhere((p) => p.presetId == id),
    template,
  );

  const userDns = DnsRuleInline(
    name: 'mine',
    rule: {
      'domain_suffix': ['example.org'],
      'server': 'cloudflare_udp',
    },
  );

  /// Состояние §124: дефолты засеяны, `tailscale` уже прошёл поздний шаг,
  /// включён `fakeip`, своё DNS-правило первым.
  Future<void> seedState() async {
    File('${tmp.path}/lxbox_settings.json').writeAsStringSync(
      jsonEncode({
        kStorageVersionKey: kStorageVersion,
        'presets_migrated': true,
        'late_presets_seeded': ['tailscale'],
      }),
    );
    SettingsStorage.resetCacheForTesting();
    await SettingsStorage.saveCustomRules([
      preset('traffic-processing'),
      preset('tailscale'),
      preset('private-ip'),
      preset('fakeip')..enabled = true,
    ]);
    await SettingsStorage.saveDnsRulesList([
      userDns,
      const DnsRulePreset(presetId: 'tailscale'),
      const DnsRulePreset(presetId: 'fakeip'),
    ]);
  }

  Future<(BuildResult, String)> build({bool allowGateway = false}) async {
    final parsed = await parseFromSource(const InlineSource(wgIni));
    final wg = parsed.nodes.single;
    final server = UserServer(
      id: 'u-wg',
      name: '',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.paste,
      rawBody: wgIni,
      allowGateway: allowGateway,
      nodes: parsed.nodes,
    );
    final result = await buildConfig(
      lists: [server],
      template: template,
      settings: BuildSettings(
        enabledGroups: const {'vpn-1', kAutoOutboundTag},
        customRules: await SettingsStorage.getCustomRules(),
      ),
    );
    return (result, wg.tag);
  }

  List<Map<String, dynamic>> listOf(Map<String, dynamic> config, String sec) =>
      (((config[sec] as Map?)?['rules'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  test(
    'поздний дефолт: reject туннеля за головой, DNS-reject раньше fakeip',
    () async {
      await seedState();
      expect(await SettingsStorage.seedLateDefaultPresets(template), isTrue);
      final ti = (await SettingsStorage.getCustomRules())
          .whereType<CustomRulePreset>()
          .singleWhere((r) => r.presetId == 'tunnel-ingress');
      expect(ti.orderNum, 940);

      final (result, wgTag) = await build();
      final reject = {
        'inbound': [wgTag],
        'action': 'reject',
      };

      // route.rules: правило reject — первое после правил головы.
      final route = listOf(result.config, 'route');
      final at = route.indexWhere((r) => _eq(r, reject));
      expect(at, greaterThanOrEqualTo(0), reason: jsonEncode(route));
      final head = (template.selectableRules.singleWhere(
        (p) => p.presetId == 'traffic-processing',
      )).rules.length;
      expect(at, greaterThanOrEqualTo(head));
      printOnFailure(const JsonEncoder.withIndent(' ').convert(route));
      for (final r in route.take(at)) {
        expect(
          r.containsKey('outbound'),
          isFalse,
          reason:
              'до reject туннеля — только нетерминальные правила головы: $r',
        );
      }
      final privateAt = route.indexWhere((r) => r['ip_is_private'] == true);
      expect(privateAt, greaterThan(at));
      expect(
        route.where(
          (r) => r['inbound'] is List && (r['inbound'] as List).contains(wgTag),
        ),
        [reject],
        reason: 'без allow_* у узла — только reject',
      );

      // dns.rules: правило пользователя первым, reject раньше fakeip A/AAAA.
      final dns = listOf(result.config, 'dns');
      expect(dns.first['domain_suffix'], [
        'example.org',
      ], reason: jsonEncode(dns));
      final dnsReject = dns.indexWhere((r) => _eq(r, reject));
      final fake = dns.indexWhere(
        (r) =>
            r['query_type'] is List &&
            (r['query_type'] as List).contains('A') &&
            (r['query_type'] as List).contains('AAAA'),
      );
      expect(dnsReject, greaterThan(0), reason: jsonEncode(dns));
      expect(fake, greaterThan(dnsReject), reason: jsonEncode(dns));
    },
  );

  // `gateway_out` по умолчанию — `route.final` (у лаунчера `proxy-out`, у
  // LxBox — главное Направление `vpn-1`).
  test('allow_gateway: правило шлюза в route.final, DNS не режется', () async {
    await seedState();
    await SettingsStorage.seedLateDefaultPresets(template);
    final (result, wgTag) = await build(allowGateway: true);
    final route = listOf(result.config, 'route');
    final mine = [
      for (final r in route)
        if (r['inbound'] is List && (r['inbound'] as List).contains(wgTag)) r,
    ];
    expect(mine, [
      {
        'inbound': [wgTag],
        'outbound': 'vpn-1',
      },
      {
        'inbound': [wgTag],
        'action': 'reject',
      },
    ]);
    final dns = listOf(result.config, 'dns');
    expect(
      dns.where((r) => r.containsKey('inbound')),
      isEmpty,
      reason: 'пир шлюза резолвит имена',
    );
  });
}

bool _eq(Map<String, dynamic> a, Map<String, dynamic> b) =>
    jsonEncode(a) == jsonEncode(b);
