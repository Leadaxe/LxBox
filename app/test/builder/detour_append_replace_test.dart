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

  group('§080 — overrideDetour ссылается на prefixed-form целевого outbound', () {
    // Target UserServer с непустым tagPrefix='Home' и нодой 'WG' →
    // эмитится в config как outbound с tag '🏠'-prefixed = 'Home WG'.
    // Consumer UserServer выбирает её как detour. Picker (§080) сохраняет
    // **display-form** 'Home WG' — это совпадает с эмитированным tag'ом.

    UserServer targetWG() => UserServer(
          id: 'wg-target',
          name: 'WG Target',
          enabled: true,
          tagPrefix: 'Home',
          detourPolicy: const DetourPolicy(),
          origin: UserSource.paste,
          createdAt: DateTime.now(),
          nodes: [parseUri('vless://wg@hop.com:443?type=ws&security=tls#WG')!],
        );

    test('display-form override → detour ссылается на существующий outbound',
        () async {
      final consumer = UserServer(
        id: 'consumer',
        name: 'Consumer',
        enabled: true,
        tagPrefix: '',
        // §080: picker сохраняет display-form 'Home WG' (= _withPrefix).
        detourPolicy: const DetourPolicy(overrideDetour: 'Home WG'),
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [parseUri('vless://u1@h1.com:443?type=ws&security=tls#Main')!],
      );

      final result = await buildConfig(
        lists: [targetWG(), consumer],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
          enabledGroups: {'vpn-1', kAutoOutboundTag},
        ),
      );

      expect(result.validation.isOk, true,
          reason: result.validation.issues.join('\n'));
      final outs = (result.config['outbounds'] as List).cast<Map>();
      final main = outs.firstWhere((o) => o['tag'] == 'Main');
      // detour указывает на 'Home WG' …
      expect(main['detour'], 'Home WG');
      // … и такой outbound реально существует в конфиге (no dangling ref).
      final tags = outs.map((o) => o['tag']).toSet();
      expect(tags.contains('Home WG'), true,
          reason: 'целевой outbound эмитится как prefixed-form "Home WG"');
    });

    test('bare-form override (старый баг) → detour деградирует, конфиг валиден '
        '(§172)', () async {
      final consumer = UserServer(
        id: 'consumer-bad',
        name: 'Consumer',
        enabled: true,
        tagPrefix: '',
        // Pre-§080 поведение: picker сохранял bare 'WG'. Целевой outbound
        // эмитится как 'Home WG' → 'WG' не существует → dangling reference.
        detourPolicy: const DetourPolicy(overrideDetour: 'WG'),
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [parseUri('vless://u1@h1.com:443?type=ws&security=tls#Main')!],
      );

      final result = await buildConfig(
        lists: [targetWG(), consumer],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
          enabledGroups: {'vpn-1', kAutoOutboundTag},
        ),
      );

      final outs = (result.config['outbounds'] as List).cast<Map>();
      final main = outs.firstWhere((o) => o['tag'] == 'Main');
      final tags = outs.map((o) => o['tag']).toSet();
      // §172 — detour 'WG' указывал на несуществующий outbound (есть только
      // 'Home WG') → healDanglingDetours СНЯЛ его. Нода 'Main' осталась,
      // работает напрямую. Конфиг валиден (раньше был fatal DanglingDetourRef).
      expect(main.containsKey('detour'), false,
          reason: '§172 снял битый detour "WG"');
      expect(tags.contains('Main'), true, reason: 'нода не выброшена');
      expect(tags.contains('WG'), false,
          reason: 'bare "WG" не эмитится — это и есть §080 баг');
      expect(result.validation.hasFatal, false,
          reason: '§172 — битый detour деградировал, не fatal');
      // warning о снятом detour присутствует.
      expect(result.emitWarnings.any((w) => w.contains('Detour убран')), true);
    });

    test('empty tagPrefix target: display-form == bare (regression-free)',
        () async {
      final target = UserServer(
        id: 'wg-noprefix',
        name: 'WG',
        enabled: true,
        tagPrefix: '',
        detourPolicy: const DetourPolicy(),
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [parseUri('vless://wg@hop.com:443?type=ws&security=tls#WG')!],
      );
      final consumer = UserServer(
        id: 'consumer2',
        name: 'Consumer',
        enabled: true,
        tagPrefix: '',
        detourPolicy: const DetourPolicy(overrideDetour: 'WG'),
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [parseUri('vless://u1@h1.com:443?type=ws&security=tls#Main')!],
      );

      final result = await buildConfig(
        lists: [target, consumer],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
          enabledGroups: {'vpn-1', kAutoOutboundTag},
        ),
      );

      expect(result.validation.isOk, true,
          reason: result.validation.issues.join('\n'));
      final outs = (result.config['outbounds'] as List).cast<Map>();
      final main = outs.firstWhere((o) => o['tag'] == 'Main');
      expect(main['detour'], 'WG');
      expect(outs.map((o) => o['tag']).toSet().contains('WG'), true);
    });

    test('disabled target UserServer не эмитит outbound (picker должен '
        'был его skip\'нуть)', () async {
      // Подтверждает review finding #7: disabled UserServer → no outbounds.
      // Picker фильтрует disabled (см. _showOverrideDetourPicker / _load),
      // здесь — builder-side инвариант: disabled list не в config.
      final disabledTarget = UserServer(
        id: 'wg-disabled',
        name: 'WG',
        enabled: false,
        tagPrefix: 'Home',
        detourPolicy: const DetourPolicy(),
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [parseUri('vless://wg@hop.com:443?type=ws&security=tls#WG')!],
      );
      final consumer = UserServer(
        id: 'consumer3',
        name: 'Consumer',
        enabled: true,
        tagPrefix: '',
        detourPolicy: const DetourPolicy(overrideDetour: 'Home WG'),
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [parseUri('vless://u1@h1.com:443?type=ws&security=tls#Main')!],
      );

      final result = await buildConfig(
        lists: [disabledTarget, consumer],
        template: template,
        settings: const BuildSettings(
          userVars: {'clash_api': '127.0.0.1:9090'},
          enabledGroups: {'vpn-1', kAutoOutboundTag},
        ),
      );

      final outs = (result.config['outbounds'] as List).cast<Map>();
      // disabled target НЕ в config → 'Home WG' отсутствует → если бы picker
      // его предложил, был бы dangling. Picker теперь его skip'ает.
      expect(outs.map((o) => o['tag']).toSet().contains('Home WG'), false,
          reason: 'disabled UserServer не эмитит outbound');
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
