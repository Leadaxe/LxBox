import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import '../parser/engine_test_setup.dart';

/// §073 — detour APPEND (default) vs REPLACE (toggle) tests на уровне
/// `buildConfig`. Pure model→config rebuild без UI/storage.
///
/// Сценарии:
///   1. Empty chain (single VLESS) + override + append/replace → 1-hop
///   2. Empty chain + override + replace=true → 1-hop (same as #1)
///   3. Default detour-empty config + override → override at tail of main
void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

  final template = WizardTemplate(
    parserConfig: ParserConfigBlock(),
    // §267 — group_templates: vpn-1 Направление (direct+auto), auto-подгруппа.
    // ('jump-out' был в старом addOutbounds, но seed-логика его не читала —
    // мёртвый элемент; в новой схеме отсутствует.)
    groupTemplates: GroupTemplates(
      direction: DirectionTemplate(
        include: const ['direct', 'auto'],
        options: const {'interrupt_exist_connections': true},
      ),
      auto: AutoTemplate(
        options: const {'url': 'https://x', 'interval': '30s'},
      ),
      defaultDirections: [
        DefaultDirection(tag: 'vpn-1', label: 'vpn-1', defaultEnabled: true),
      ],
    ),
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
        detourPolicy: const DetourPolicy(overrideDetour: NodeLink(tag: 'jump-out')),
        origin: UserSource.paste,
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
          overrideDetour: NodeLink(tag: 'jump-out'),
          replaceDetourChain: true,
        ),
        origin: UserSource.paste,
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
          overrideDetour: NodeLink(tag: 'jump-out'),
        ),
        origin: UserSource.paste,
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
        detourPolicy: const DetourPolicy(overrideDetour: NodeLink(tag: 'Home WG')),
        origin: UserSource.paste,
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

    test('bare-form override (старый баг) → узел выпадает fail-closed, конфиг '
        'валиден (§439, NODE_LINK §5.1)', () async {
      final consumer = UserServer(
        id: 'consumer-bad',
        name: 'Consumer',
        enabled: true,
        tagPrefix: '',
        // Pre-§080 поведение: picker сохранял bare 'WG'. Целевой outbound
        // эмитится как 'Home WG' → 'WG' не существует → dangling reference.
        detourPolicy: const DetourPolicy(overrideDetour: NodeLink(tag: 'WG')),
        origin: UserSource.paste,
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
      final tags = outs.map((o) => o['tag']).toSet();
      // §439 — корневая ссылка 'WG' не разрешается (корневой узел эмитится
      // как 'Home WG'). Узел с неразрешённым detour не эмитится: напрямую
      // трафик не уходит (до §439 §172 снимал detour, и узел шёл напрямую).
      expect(tags.contains('Main'), false,
          reason: 'носитель висячей ссылки выпадает, а не идёт напрямую');
      expect(tags.contains('Home WG'), true, reason: 'цель на месте');
      expect(tags.contains('WG'), false,
          reason: 'bare "WG" не эмитится — это и есть §080 баг');
      expect(result.validation.hasFatal, false,
          reason: 'выпавший узел не делает конфиг невалидным');
      expect(
          result.emitWarnings,
          contains(allOf(
            contains('Node "Main" was skipped: its detour "WG" did not resolve'),
            contains('never goes direct'),
          )));
      expect(result.emitWarnings.any((w) => w.contains('Detour removed')),
          isFalse);
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
        nodes: [parseUri('vless://wg@hop.com:443?type=ws&security=tls#WG')!],
      );
      final consumer = UserServer(
        id: 'consumer2',
        name: 'Consumer',
        enabled: true,
        tagPrefix: '',
        detourPolicy: const DetourPolicy(overrideDetour: NodeLink(tag: 'WG')),
        origin: UserSource.paste,
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
        nodes: [parseUri('vless://wg@hop.com:443?type=ws&security=tls#WG')!],
      );
      final consumer = UserServer(
        id: 'consumer3',
        name: 'Consumer',
        enabled: true,
        tagPrefix: '',
        detourPolicy: const DetourPolicy(overrideDetour: NodeLink(tag: 'Home WG')),
        origin: UserSource.paste,
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

  // §574 (контракт 1.1.84, §81) — `tls.fragment` уступает `detour`,
  // назначенному сборкой: снимается с кодом `detour_with_tls_fragment`,
  // код виден в предупреждениях узла. `record_fragment` связи с detour не
  // имеет.
  group('§574 — tls.fragment под detour сборки', () {
    NodeSpec xrayFragmentNode() => parseXrayElement({
          'remarks': 'X',
          'outbounds': [
            {
              'tag': 'proxy',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': 'example-1.com',
                    'port': 443,
                    'users': [
                      {
                        'id': '11111111-1111-1111-1111-111111111111',
                        'encryption': 'none',
                      },
                    ],
                  },
                ],
              },
              'streamSettings': {
                'network': 'tcp',
                'security': 'tls',
                'tlsSettings': {'serverName': 'example-1.com'},
                'finalmask': {
                  'tcp': [
                    {
                      'type': 'fragment',
                      'settings': {'packets': 'tlshello'},
                    },
                  ],
                },
              },
            },
          ],
        }).single;

    NodeSpec singboxNode(Map<String, dynamic> tls) {
      final raw = jsonEncode({
        'type': 'vless',
        'tag': 'S',
        'server': 'example-1.com',
        'server_port': 443,
        'uuid': '11111111-1111-1111-1111-111111111111',
        'tls': tls,
      });
      return parseSingboxEntry(
        jsonDecode(raw) as Map<String, dynamic>,
        rawSource: raw,
      )!;
    }

    Future<(Map, BuildResult)> buildMain(NodeSpec spec,
        {required bool detour}) async {
      final list = UserServer(
        id: 'u1',
        name: 'Test',
        enabled: true,
        tagPrefix: '',
        detourPolicy: detour
            ? const DetourPolicy(overrideDetour: NodeLink(tag: 'jump-out'))
            : const DetourPolicy(),
        origin: UserSource.paste,
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
      final main =
          outs.firstWhere((o) => (o as Map)['tag'] == spec.tag) as Map;
      return (main, result);
    }

    List<String> codesOf(BuildResult r, String tag) => [
          for (final w in r.nodeBuildWarningsByEmittedTag[tag] ?? const [])
            if (w is RegistryWarning) w.code,
        ];

    test('Xray finalmask + override_detour → fragment снят, код у узла',
        () async {
      final (main, r) = await buildMain(xrayFragmentNode(), detour: true);
      expect(main['detour'], 'jump-out');
      final tls = main['tls'] as Map;
      expect(tls['enabled'], true);
      expect(tls.containsKey('fragment'), isFalse);
      expect(tls.containsKey('fragment_fallback_delay'), isFalse);
      expect(codesOf(r, main['tag'] as String),
          contains('detour_with_tls_fragment'));
      final w = r.nodeBuildWarningsByEmittedTag[main['tag']]!
          .whereType<RegistryWarning>()
          .firstWhere((w) => w.code == 'detour_with_tls_fragment');
      expect(w.params['tag'], main['tag']);
      expect(w.params['target'], 'jump-out');
    });

    test('тот же узел без detour — fragment на месте, кода нет', () async {
      final (main, r) = await buildMain(xrayFragmentNode(), detour: false);
      expect(main.containsKey('detour'), isFalse);
      expect((main['tls'] as Map)['fragment'], true);
      expect(codesOf(r, main['tag'] as String),
          isNot(contains('detour_with_tls_fragment')));
    });

    test('явный record_fragment под detour остаётся, fragment снят',
        () async {
      final (main, r) = await buildMain(
        singboxNode({
          'enabled': true,
          'server_name': 'example-1.com',
          'fragment': true,
          'record_fragment': true,
          'fragment_fallback_delay': '300ms',
        }),
        detour: true,
      );
      expect(main['detour'], 'jump-out');
      final tls = main['tls'] as Map;
      expect(tls.containsKey('fragment'), isFalse);
      expect(tls['record_fragment'], true);
      expect(tls['fragment_fallback_delay'], '300ms');
      expect(codesOf(r, 'S'), ['detour_with_tls_fragment']);
    });

    test('только record_fragment под detour — тело не трогается', () async {
      final (main, r) = await buildMain(
        singboxNode({
          'enabled': true,
          'server_name': 'example-1.com',
          'record_fragment': true,
        }),
        detour: true,
      );
      expect(main['detour'], 'jump-out');
      expect((main['tls'] as Map)['record_fragment'], true);
      expect(codesOf(r, 'S'), isEmpty);
    });
  });

  group('DetourPolicy в записи sources[] — replaceDetourChain', () {
    DetourPolicy readPolicy(Map<String, dynamic> record) =>
        sourceFromRecord(record).value!.detourPolicy;

    UserServer withPolicy(DetourPolicy p) => UserServer(
          id: 'u1',
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: p,
        );

    test('default false: missing key → false', () {
      final policy = readPolicy({
        'kind': 'server',
        'id': 'u1',
        'detour': {'tag': 'x'},
        'detour_policy': {
          'register_detour_servers': true,
          'register_detour_in_auto': false,
          'use_detour_servers': true,
          // no 'replace_detour_chain' key
        },
      });
      expect(policy.replaceDetourChain, false);
      expect(policy.registerDetourServers, true);
      expect(policy.overrideDetour, const NodeLink(tag: 'x'));
    });

    test('true: serialized round-trip', () {
      const original = DetourPolicy(
        overrideDetour: NodeLink(tag: 'x'),
        replaceDetourChain: true,
      );
      final record = sourceToRecord(withPolicy(original));
      expect(record['detour'], {'tag': 'x'});
      expect((record['detour_policy'] as Map).containsKey('override_detour'),
          isFalse);
      final restored = readPolicy(record);
      expect(restored, original);
      expect(restored.replaceDetourChain, true);
    });

    test('умолчания: detour_policy в запись не пишется', () {
      final record = sourceToRecord(withPolicy(DetourPolicy.defaults));
      expect(record.containsKey('detour_policy'), isFalse);
      expect(record.containsKey('detour'), isFalse);
      expect(readPolicy(record), DetourPolicy.defaults);
    });

    test('copyWith updates replaceDetourChain', () {
      const a = DetourPolicy();
      final b = a.copyWith(replaceDetourChain: true);
      expect(b.replaceDetourChain, true);
      expect(b.overrideDetour, NodeLink.none);
      // == check: разные → not equal
      expect(b == a, false);
    });
  });
}
