import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §073 — detour APPEND (default) vs REPLACE (toggle) tests на уровне
/// `buildConfig`. Pure model→config rebuild без UI/storage.
///
/// Сценарии:
///   1. Empty chain (single VLESS) + override + append/replace → 1-hop
///   2. Empty chain + override + replace=true → 1-hop (same as #1)
///   3. Default detour-empty config + override → override at tail of main
void main() {
  final template = WizardTemplate(
    parserConfig: ParserConfigBlock(),
    presetGroups: [
      PresetGroup(
        tag: 'vpn-1',
        type: 'selector',
        options: {'default': kAutoOutboundTag},
        defaultEnabled: true,
        addOutbounds: ['direct-out', kAutoOutboundTag, 'jump-out'],
      ),
      PresetGroup(
        tag: kAutoOutboundTag,
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
        // 'jump-out' — обычный outbound, который юзер выбирает как
        // override detour target.
        {
          'tag': 'jump-out',
          'type': 'vless',
          'server': 'jump.example.com',
          'server_port': 443,
          'uuid': 'jump-uuid'
        },
      ],
      'route': {'rules': []},
    },
    selectableRules: const [],
    dnsOptions: const {},
    pingOptions: const {},
    speedTestOptions: const {},
  );

  group('§073 — empty native chain (single VLESS)', () {
    test('append (default): main.detour = override (1-hop)', () async {
      final spec =
          parseUri('vless://u1@h1.com:443?type=ws&security=tls#A')!;
      final list = UserServer(
        id: 'u1',
        name: 'Test',
        enabled: true,
        tagPrefix: '',
        detourPolicy: const DetourPolicy(overrideDetour: 'jump-out'),
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [spec],
      );

      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
          enabledGroups: {'vpn-1', kAutoOutboundTag},
        ),
      );

      expect(result.validation.isOk, true,
          reason: result.validation.issues.join('\n'));
      final outs = result.config['outbounds'] as List;
      final main = outs.firstWhere((o) => (o as Map)['tag'] == 'A') as Map;
      expect(main['detour'], 'jump-out',
          reason: 'append с пустой цепочкой — 1-hop как replace');
    });

    test('replace (explicit toggle): main.detour = override', () async {
      final spec =
          parseUri('vless://u1@h1.com:443?type=ws&security=tls#B')!;
      final list = UserServer(
        id: 'u2',
        name: 'Test',
        enabled: true,
        tagPrefix: '',
        detourPolicy: const DetourPolicy(
          overrideDetour: 'jump-out',
          replaceDetourChain: true,
        ),
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [spec],
      );

      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
          enabledGroups: {'vpn-1', kAutoOutboundTag},
        ),
      );

      expect(result.validation.isOk, true,
          reason: result.validation.issues.join('\n'));
      final outs = result.config['outbounds'] as List;
      final main = outs.firstWhere((o) => (o as Map)['tag'] == 'B') as Map;
      expect(main['detour'], 'jump-out');
    });

    test('append with overrideDetour empty: no detour set on main', () async {
      final spec =
          parseUri('vless://u1@h1.com:443?type=ws&security=tls#C')!;
      final list = UserServer(
        id: 'u3',
        name: 'Test',
        enabled: true,
        tagPrefix: '',
        // useDetourServers default true, overrideDetour empty → main без
        // detour (нет цепочки в config'е, нет override).
        detourPolicy: const DetourPolicy(),
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [spec],
      );

      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
          enabledGroups: {'vpn-1', kAutoOutboundTag},
        ),
      );

      expect(result.validation.isOk, true,
          reason: result.validation.issues.join('\n'));
      final outs = result.config['outbounds'] as List;
      final main = outs.firstWhere((o) => (o as Map)['tag'] == 'C') as Map;
      expect(main.containsKey('detour'), false,
          reason: 'нет цепочки + нет override → main без detour');
    });

    test('useDetourServers=false + override → no detour (use=false wins)',
        () async {
      final spec =
          parseUri('vless://u1@h1.com:443?type=ws&security=tls#D')!;
      final list = UserServer(
        id: 'u4',
        name: 'Test',
        enabled: true,
        tagPrefix: '',
        detourPolicy: const DetourPolicy(
          useDetourServers: false,
          overrideDetour: 'jump-out',
        ),
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [spec],
      );

      final result = await buildConfig(
        lists: [list],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
          enabledGroups: {'vpn-1', kAutoOutboundTag},
        ),
      );

      expect(result.validation.isOk, true,
          reason: result.validation.issues.join('\n'));
      final outs = result.config['outbounds'] as List;
      final main = outs.firstWhere((o) => (o as Map)['tag'] == 'D') as Map;
      expect(main.containsKey('detour'), false,
          reason: 'use=false побеждает override');
    });
  });

  group('DetourPolicy JSON round-trip — replaceDetourChain', () {
    test('default false: missing key → false', () {
      final policy = DetourPolicy.fromJson({
        'register_detour_servers': true,
        'register_detour_in_auto': false,
        'use_detour_servers': true,
        'override_detour': 'x',
        // no 'replace_detour_chain' key
      });
      expect(policy.replaceDetourChain, false);
    });

    test('true: serialized round-trip', () {
      const original = DetourPolicy(
        overrideDetour: 'x',
        replaceDetourChain: true,
      );
      final restored = DetourPolicy.fromJson(original.toJson());
      expect(restored, original);
      expect(restored.replaceDetourChain, true);
    });

    test('copyWith updates replaceDetourChain', () {
      const a = DetourPolicy();
      final b = a.copyWith(replaceDetourChain: true);
      expect(b.replaceDetourChain, true);
      expect(b.overrideDetour, '');
      // == check: разные → not equal
      expect(b == a, false);
    });
  });
}
