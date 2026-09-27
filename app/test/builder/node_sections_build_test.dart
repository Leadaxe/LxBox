import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/builder/core_chain_capability.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/tailscale_state/state_keys.dart';

import '../parser/engine_test_setup.dart';

/// §575 — секции узла упразднены (контракт 1.1.85): запись хранения с ключом
/// `sections` читается, но её правила и DNS-записи в конфиг не попадают.
/// Tailscale: `state_directory`, гейт ядра, пул Направлений.
void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

  final template = WizardTemplate(
    parserConfig: ParserConfigBlock(),
    groupTemplates: GroupTemplates(
      direction: DirectionTemplate(
        include: const ['direct', 'auto'],
        options: const {'interrupt_exist_connections': true},
      ),
      auto: AutoTemplate(options: const {'url': 'https://x', 'interval': '30s'}),
      defaultDirections: [
        DefaultDirection(tag: 'vpn-1', label: 'vpn-1', defaultEnabled: true),
      ],
    ),
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

  const settings = BuildSettings(enabledGroups: {'vpn-1', kAutoOutboundTag});

  // Секции в форме хранения (прежняя каноническая связка Tailscale плюс
  // DNS-сервер `udp` через узел): после §575 кодек и сборка их не видят.
  const sectionsJson = <String, dynamic>{
    'rules': [
      {
        'kind': 'inline',
        'name': '@{self} network',
        'enabled': true,
        'body': {
          'ip_cidr': ['100.64.0.0/10'],
          'outbound': '@self',
        },
      },
    ],
    'dns': {
      'servers': [
        {
          'kind': 'user',
          'tag': '@{self}-dns',
          'enabled': true,
          'body': {'type': 'tailscale', 'endpoint': '@self'},
        },
        {
          'kind': 'user',
          'tag': '@{self}-udp',
          'enabled': true,
          'body': {'type': 'udp', 'server': '9.9.9.9', 'detour': '@self'},
        },
      ],
      'rules': [
        {
          'kind': 'user',
          'enabled': true,
          'body': {
            'domain_suffix': ['.ts.net'],
            'server': '@{self}-dns',
          },
        },
      ],
    },
  };

  TailscaleSpec ts({String tag = 'home-ts', String? exitNode}) => TailscaleSpec(
        id: 'ts-$tag',
        tag: tag,
        label: tag,
        body: {'auth_key': 'tskey', 'exit_node': ?exitNode},
      );

  UserServer user(NodeSpec node, {bool enabled = true, String prefix = ''}) =>
      UserServer(
        id: 'u-${node.tag}',
        name: '',
        enabled: enabled,
        tagPrefix: prefix,
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.manual,
        rawBody: node.toUri(),
        nodes: [node],
      );

  /// Запись хранения [list], прочитанная обратно кодеком; при [sections] —
  /// с ключом `sections` у сервера или у каждого члена папки, как её оставила
  /// прошлая версия.
  ServerList viaStore(ServerList list, {bool sections = true}) {
    final rec = sourceToRecord(list);
    if (sections && list is UserServer) rec['sections'] = sectionsJson;
    if (sections && list is FolderServers) {
      rec['nodes'] = [
        for (final n in rec['nodes'] as List)
          {...(n as Map).cast<String, dynamic>(), 'sections': sectionsJson},
      ];
    }
    return sourceFromRecord(rec).value!;
  }

  List<Map<String, dynamic>> rules(BuildResult r) =>
      ((r.config['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> endpoints(BuildResult r) =>
      ((r.config['endpoints'] as List?) ?? const []).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> dnsServers(BuildResult r) =>
      (((r.config['dns'] as Map?)?['servers'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  group('§575 секции в записи хранения на сборку не влияют', () {
    test('свой сервер: ни правил, ни DNS-записей узла, конфиг прежний',
        () async {
      final vless = parseUri('vless://u1@h1.com:443?type=ws&security=tls#A')!;
      final plain = await buildConfig(
          lists: [
            viaStore(user(ts()), sections: false),
            viaStore(user(vless), sections: false),
          ],
          template: template,
          settings: settings);
      final stored = await buildConfig(
        lists: [viaStore(user(ts())), viaStore(user(vless))],
        template: template,
        settings: settings,
      );
      expect(stored.configJson, plain.configJson);
      expect(stored.configJson, isNot(contains('@self')));
      expect(stored.configJson, isNot(contains('100.64.0.0/10')));
      expect(stored.configJson, isNot(contains('9.9.9.9')));
      expect(dnsServers(stored).map((x) => x['tag']),
          isNot(anyOf(contains('home-ts-dns'), contains('A-udp'))));
      expect(rules(stored).where((x) => x['outbound'] == 'home-ts'), isEmpty);
      expect(
          stored.emitWarnings.where((w) => w.contains('Node DNS')), isEmpty);
    });

    test('член папки: то же', () async {
      final vless = parseUri('vless://u1@h1.com:443?type=ws&security=tls#A')!;
      final folder = FolderServers(
        id: 'f',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(raw: ts().toUri()),
          FolderMember(raw: vless.toUri()),
        ],
      );
      final plain = await buildConfig(
          lists: [viaStore(folder, sections: false)],
          template: template,
          settings: settings);
      final stored = await buildConfig(
          lists: [viaStore(folder)],
          template: template,
          settings: settings);
      expect(stored.configJson, plain.configJson);
      expect(stored.configJson, isNot(contains('@self')));
      expect(stored.configJson, isNot(contains('100.64.0.0/10')));
      expect(stored.configJson, isNot(contains('9.9.9.9')));
    });
  });

  group('§435 Tailscale — state_directory, гейт ядра, Направления', () {
    test('state_directory подставляется при известном корне, тело не трогается', () async {
      final node = ts(tag: '🇩🇪 home ts/1');
      final r = await buildConfig(
        lists: [user(node)],
        template: template,
        settings: const BuildSettings(
          enabledGroups: {'vpn-1', kAutoOutboundTag},
          tailscaleStateRoot: '/data/user/0/app/files',
        ),
      );
      expect(endpoints(r).single['state_directory'],
          '/data/user/0/app/files/tailscale/${tailscaleStateDirName('🇩🇪 home ts/1')}');
      // Флаг — два code point'а (regional indicators) → два `_`, как у Go по рунам.
      expect(tailscaleStateDirName('🇩🇪 home ts/1'), '___home_ts_1');
      expect(tailscaleStateDirName('///'), '___');
      expect(tailscaleStateDirName(''), 'tailscale');
      expect(node.body.containsKey('state_directory'), isFalse);
    });

    test('state_directory: без корня не пишется; своё значение не трогается', () async {
      final r1 = await buildConfig(lists: [user(ts())], template: template, settings: settings);
      expect(endpoints(r1).single.containsKey('state_directory'), isFalse);
      final own = TailscaleSpec(id: 'x', tag: 'x', label: 'x', body: {'state_directory': '/own'});
      final r2 = await buildConfig(
        lists: [user(own)],
        template: template,
        settings: const BuildSettings(enabledGroups: {'vpn-1'}, tailscaleStateRoot: '/root'),
      );
      expect(endpoints(r2).single['state_directory'], '/own');
    });

    test('гейт ядра по тегу сборки (§56): без with_tailscale узел снят с кодом; '
        'с тегом — эмиссия', () async {
      final noTs = kCoreBuildTags.difference({'with_tailscale'});
      final old = await buildConfig(
        lists: [user(ts())],
        template: template,
        settings: BuildSettings(enabledGroups: const {'vpn-1'}, coreBuildTags: noTs),
      );
      expect(endpoints(old), isEmpty);
      expect(rules(old).where((x) => x['outbound'] == 'home-ts'), isEmpty);
      expect(dnsServers(old), isEmpty);
      expect(old.emitWarnings.single, startsWith('home-ts: '));
      expect(old.emitWarnings.single, contains('Tailscale'));
      final codes = [
        for (final w in old.nodeBuildWarningsByEmittedTag['home-ts'] ?? const [])
          (w as RegistryWarning).code,
      ];
      expect(codes, ['tailscale_core_unsupported']);
      expect(old.validation.isOk, isTrue, reason: old.validation.issues.join('\n'));

      // Встроенное ядро (дефолт BuildSettings) несёт тег — узел на месте.
      expect(kCoreBuildTags, contains('with_tailscale'));
      final fresh = await buildConfig(
        lists: [user(ts())],
        template: template,
        settings: const BuildSettings(enabledGroups: {'vpn-1'}),
      );
      expect(endpoints(fresh).single['tag'], 'home-ts');
      expect(fresh.emitWarnings, isEmpty);

      // Теги неизвестны — гейт по тегу не применяется.
      final unknown = await buildConfig(
        lists: [user(ts())],
        template: template,
        settings: const BuildSettings(enabledGroups: {'vpn-1'}, coreBuildTags: null),
      );
      expect(endpoints(unknown).single['tag'], 'home-ts');
    });

    test('без exit_node — не в пуле Направлений; с exit_node — кандидат', () async {
      final vless = parseUri('vless://u1@h1.com:443?type=ws&security=tls#A')!;
      final r = await buildConfig(
        lists: [user(ts()), user(vless), user(ts(tag: 'exit', exitNode: 'srv'))],
        template: template,
        settings: settings,
      );
      final outs = (r.config['outbounds'] as List).cast<Map<String, dynamic>>();
      final vpn1 = outs.firstWhere((o) => o['tag'] == 'vpn-1');
      final members = (vpn1['outbounds'] as List).cast<String>();
      expect(members, isNot(contains('home-ts')));
      expect(members, contains('A'));
      expect(members, contains('exit'));
      final auto = outs.firstWhere((o) => o['tag'] == 'vpn-1-auto');
      expect((auto['outbounds'] as List), isNot(contains('home-ts')));
      // Узел при этом эмитирован — законная цель detour.
      expect(endpoints(r).map((e) => e['tag']), containsAll(['home-ts', 'exit']));
    });
  });
}
