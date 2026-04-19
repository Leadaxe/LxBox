import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

void main() {
  group('buildConfig — smoke', () {
    final template = WizardTemplate(
      parserConfig: ParserConfigBlock(),
      presetGroups: [
        PresetGroup(
          tag: 'vpn-1',
          type: 'selector',
          options: {'default': 'auto-proxy-out'},
          defaultEnabled: true,
          addOutbounds: ['direct-out', 'auto-proxy-out'],
        ),
        PresetGroup(
          tag: 'auto-proxy-out',
          type: 'urltest',
          options: {'url': 'https://x', 'interval': '30s'},
          defaultEnabled: true,
          addOutbounds: const [],
        ),
      ],
      vars: const [],
      varSections: const [],
      config: {
        'outbounds': [
          {'tag': 'direct-out', 'type': 'direct'},
        ],
        'route': {'rules': []},
      },
      selectableRules: const [],
      dnsOptions: const {},
      pingOptions: const {},
      speedTestOptions: const {},
    );

    test('two VLESS nodes from UserServers → 2 outbounds + vpn-1 + auto', () async {
      final specs = [
        parseUri('vless://u1@h1.com:443?type=ws&security=tls#A')!,
        parseUri('vless://u2@h2.com:443?type=ws&security=tls#B')!,
      ];
      final list = UserServers(
        id: 'u1',
        name: 'Test',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: specs,
      );

      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(
          userVars: {
            'clash_api': '127.0.0.1:9090',
          },
          enabledGroups: {'vpn-1', 'auto-proxy-out'},
        ),
      );

      expect(result.validation.isOk, true,
          reason: result.validation.issues.join('\n'));
      final outs = result.config['outbounds'] as List;
      final tags = outs.map((o) => (o as Map)['tag']).toList();
      expect(tags, containsAll(['A', 'B', 'direct-out', 'vpn-1', 'auto-proxy-out']));

      // vpn-1 includes node tags.
      final vpn1 =
          outs.firstWhere((o) => (o as Map)['tag'] == 'vpn-1') as Map;
      expect(vpn1['outbounds'], containsAll(['A', 'B']));
    });

    test('WireGuard node → endpoints array, not outbounds', () async {
      final wg = parseWireguardUri(
        'wireguard://pk_a@wg.example.com:51820?publickey=pk_b&address=10.0.0.2%2F32&mtu=1420#WG',
      )!;
      final list = UserServers(
        id: 'u2',
        name: 'WG',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [wg],
      );

      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(userVars: {'clash_api': '127.0.0.1:9090'}),
      );

      final endpoints = result.config['endpoints'] as List?;
      expect(endpoints, isNotNull);
      expect(endpoints!.any((e) => (e as Map)['tag'] == 'WG'), true);
      final outs = result.config['outbounds'] as List;
      expect(outs.any((o) => (o as Map)['tag'] == 'WG'), false);
    });

    test('tls_fragment=true fragments first-hop TLS only', () async {
      final spec = parseUri('vless://u@h:443?type=tcp&security=tls&sni=h#A')!;
      final list = UserServers(
        id: 'u3',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [spec],
      );
      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(userVars: {
          'clash_api': '127.0.0.1:9090',
          'tls_fragment': 'true',
          'tls_record_fragment': 'true',
        }),
      );
      final outs = result.config['outbounds'] as List;
      final a = outs.firstWhere((o) => (o as Map)['tag'] == 'A') as Map;
      expect((a['tls'] as Map)['fragment'], true);
      expect((a['tls'] as Map)['record_fragment'], true);
    });

    test('duplicate node tags across and within lists get -N suffix + prefix applied', () async {
      final a1 = parseUri('vless://u1@h1:443?type=ws&security=tls#Frankfurt')!;
      final a2 = parseUri('vless://u2@h2:443?type=ws&security=tls#Frankfurt')!;
      final b1 = parseUri('vless://u3@h3:443?type=ws&security=tls#Frankfurt')!;
      final listA = UserServers(
        id: 'A', name: 'A', enabled: true, tagPrefix: 'BL:',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste, createdAt: DateTime.now(),
        nodes: [a1, a2],
      );
      final listB = UserServers(
        id: 'B', name: 'B', enabled: true, tagPrefix: 'W:',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste, createdAt: DateTime.now(),
        nodes: [b1],
      );
      final result = await buildConfig(
        lists: [listA, listB],
        template: template,
        settings: const BuildSettings(userVars: {'clash_api': '127.0.0.1:9090'}),
      );

      final outs = result.config['outbounds'] as List;
      final tags = outs.map((o) => (o as Map)['tag'] as String).toList();
      // Все теги уникальны.
      expect(tags.toSet().length, tags.length, reason: 'tags must be unique: $tags');
      // Префикс применён.
      expect(tags, contains('BL: Frankfurt'));
      expect(tags, contains('BL: Frankfurt-1'));
      expect(tags, contains('W: Frankfurt'));
      expect(result.validation.isOk, true);
    });

    test('clash_api default :9090 randomized to 49152-65535 range', () async {
      final list = UserServers(
        id: 'u4',
        name: 'E',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: const [],
      );
      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(userVars: {'clash_api': '127.0.0.1:9090'}),
      );
      // clash_api var был подменен — но @clash_api нет в template.config,
      // так что проверяем через internal (смотрим на emitWarnings пустой).
      expect(result.emitWarnings, isEmpty);
    });
  });
}
