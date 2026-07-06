import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/channel.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §248 — detour-каналы в билдере: block-гейт, direct-fallback пустого
/// detour-канала, edge-strip detour-циклов (exempt-семантика: узел остаётся
/// в канале, снимается его цикл-образующий detour), autoTag-алиас,
/// деградация route_final, AWG→WG advisory. Harness — как в
/// channel_groups_test.dart (настоящий buildConfig, channels из settings).
void main() {
  WizardTemplate template() => WizardTemplate(
        parserConfig: ParserConfigBlock(),
        presetGroups: const [],
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

  // Одиночный UserServer с VLESS-нодами [names] и общей detour-политикой.
  UserServer vlessServer({
    required String id,
    required List<String> names,
    DetourPolicy policy = DetourPolicy.defaults,
  }) =>
      UserServer(
        id: id,
        name: id,
        enabled: true,
        tagPrefix: '',
        detourPolicy: policy,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [
          for (final n in names)
            parseUri('vless://u-$id@h-$id.com:443?type=ws&security=tls#$n')!,
        ],
      );

  Future<BuildResult> build(List<ServerList> lists, List<Channel> channels,
      {String routeFinal = ''}) async {
    final r = await buildConfig(
      lists: lists,
      template: template(),
      settings: BuildSettings(channels: channels, routeFinal: routeFinal),
    );
    expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
    return r;
  }

  List<Map<String, dynamic>> outs(BuildResult r) =>
      (r.config['outbounds'] as List).cast<Map<String, dynamic>>();

  Map<String, dynamic> byTag(BuildResult r, String tag) =>
      outs(r).firstWhere((o) => o['tag'] == tag);

  group('§248 — block-гейт и пустой fallback', () {
    test('block не эмитится у detour-канала даже при includeBlock=true',
        () async {
      // includeBlock=true при isDetour — несогласованное состояние (parse-гейт
      // fromJson такое не пропустит), билдер-гейт = defense-in-depth.
      final r = await build([
        vlessServer(id: 'u', names: ['A']),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(
            tag: 'vpn-2', label: 'Relay', isDetour: true, includeBlock: true),
      ]);
      expect(byTag(r, 'vpn-2')['outbounds'], isNot(contains('block')));
    });

    test('пустой detour-канал → [direct-out] c default=direct-out + warning',
        () async {
      final r = await build([
        vlessServer(id: 'u', names: ['A']),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(
            tag: 'vpn-2',
            label: 'Relay',
            isDetour: true,
            nodeFilter: 'no-such-node'),
      ]);
      final vpn2 = byTag(r, 'vpn-2');
      expect(vpn2['outbounds'], ['direct-out']);
      expect(vpn2['default'], 'direct-out');
      expect(
          r.emitWarnings,
          contains(contains(
              'Detour channel "Relay" (vpn-2): no nodes matched')));
    });

    test('пустой ОБЫЧНЫЙ канал — прежний §201 [block, direct-out]', () async {
      final r = await build([
        vlessServer(id: 'u', names: ['A']),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(tag: 'vpn-2', label: 'X', nodeFilter: 'no-such-node'),
      ]);
      final vpn2 = byTag(r, 'vpn-2');
      expect(vpn2['outbounds'], ['block', 'direct-out']);
      expect(vpn2['default'], 'block');
    });
  });

  group('§248 — edge-strip detour-циклов', () {
    test('прямой цикл: member.detour=C → detour снят, узел ОСТАЁТСЯ в канале',
        () async {
      final r = await build([
        vlessServer(
            id: 'u',
            names: ['Relay Berlin'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(
            tag: 'vpn-2', label: 'Relay', isDetour: true, nodeFilter: 'Relay'),
      ]);
      expect(byTag(r, 'Relay Berlin').containsKey('detour'), false);
      expect(byTag(r, 'vpn-2')['outbounds'], contains('Relay Berlin'));
      expect(r.emitWarnings,
          contains(contains('removed detour from 1 node(s)')));
    });

    test('цикл через auto-двойник (detour=<tag>-auto) рвётся так же',
        () async {
      final r = await build([
        vlessServer(
            id: 'u',
            names: ['Relay Berlin'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2-auto')),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(
            tag: 'vpn-2',
            label: 'Relay',
            isDetour: true,
            nodeFilter: 'Relay',
            auto: ChannelAuto()),
      ]);
      expect(byTag(r, 'Relay Berlin').containsKey('detour'), false);
      expect(r.emitWarnings, contains(contains('routing loop')));
    });

    test('транзитивный цикл через промежуточный узел', () async {
      // Client ∈ vpn-2; Client→Mid→vpn-2. Рвётся ребро ЧЛЕНА (Client),
      // Mid (не член) сохраняет свой detour на канал — это валидная цепочка.
      final r = await build([
        vlessServer(
            id: 'c',
            names: ['Client'],
            policy: const DetourPolicy(overrideDetour: 'Mid')),
        vlessServer(
            id: 'm',
            names: ['Mid'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(
            tag: 'vpn-2',
            label: 'Relay',
            isDetour: true,
            nodeFilter: 'Client'),
      ]);
      expect(byTag(r, 'Client').containsKey('detour'), false);
      expect(byTag(r, 'Mid')['detour'], 'vpn-2');
    });

    test('межканальный цикл: A∈C1→C2, B∈C2→C1 — рвётся один раз', () async {
      final r = await build([
        vlessServer(
            id: 'a',
            names: ['Node A'],
            policy: const DetourPolicy(overrideDetour: 'vpn-3')),
        vlessServer(
            id: 'b',
            names: ['Node B'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(
            tag: 'vpn-2', label: 'C1', isDetour: true, nodeFilter: 'Node A'),
        const Channel(
            tag: 'vpn-3', label: 'C2', isDetour: true, nodeFilter: 'Node B'),
      ]);
      // vpn-2 обрабатывается первым: ребро A→vpn-3 снято; после этого цикл
      // для vpn-3 исчез — B сохраняет свой detour (минимальность разрыва).
      expect(byTag(r, 'Node A').containsKey('detour'), false);
      expect(byTag(r, 'Node B')['detour'], 'vpn-2');
    });

    test('ссылка на ОБЫЧНЫЙ канал (Debug API-сценарий) рвётся так же',
        () async {
      final r = await build([
        vlessServer(
            id: 'u',
            names: ['Node X'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(tag: 'vpn-2', label: 'Plain', nodeFilter: 'Node X'),
      ]);
      expect(byTag(r, 'Node X').containsKey('detour'), false);
    });

    test('флагман: relay в той же подписке под overrideDetour=C', () async {
      // Политика применяется ко ВСЕМ нодам, включая сами relay'и: без
      // edge-strip канал опустел бы (исключение), с ним — relay едет
      // напрямую, остальной флот через канал → relay.
      final r = await build([
        vlessServer(
            id: 'u',
            names: ['Relay Berlin', 'Client A', 'Client B'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(
            tag: 'vpn-2',
            label: 'Relay',
            isDetour: true,
            nodeFilter: 'Relay',
            auto: ChannelAuto()),
      ]);
      expect(byTag(r, 'Relay Berlin').containsKey('detour'), false);
      expect(byTag(r, 'Client A')['detour'], 'vpn-2');
      expect(byTag(r, 'Client B')['detour'], 'vpn-2');
      // Селектор и auto-двойник согласованы: один member-set.
      expect(byTag(r, 'vpn-2')['outbounds'], contains('Relay Berlin'));
      expect(byTag(r, 'vpn-2-auto')['outbounds'], ['Relay Berlin']);
    });
  });

  group('§248 — restore-деградация и омонимия', () {
    test('custom-rule на detour-канал → конфиг валиден (принятая деградация)',
        () async {
      // Restore из бэкапа пишет мимо storage-heal: правило может ссылаться
      // на канал, ставший detour. Селектор vpn-2 в конфиге существует —
      // валидатор не падает; storage-heal чинит ссылку при следующей
      // мутации канала, билдер здесь только не должен ронять старт.
      final r = await buildConfig(
        lists: [vlessServer(id: 'u', names: ['A'])],
        template: template(),
        settings: BuildSettings(
          channels: const [
            Channel(tag: 'vpn-1', label: 'Main'),
            Channel(tag: 'vpn-2', label: 'Relay', isDetour: true),
          ],
          customRules: [
            CustomRuleInline(
                name: 'Pin', domains: const ['x.com'], outbound: 'vpn-2'),
          ],
        ),
      );
      expect(r.validation.isOk, true,
          reason: r.validation.issues.join('\n'));
    });

    test('омоним: member.detour=тёзка канала → интра-ребро на члена', () async {
      // Член папки носит bare-тег 'vpn-2' — тёзка detour-канала. Ссылка
      // member B detour='vpn-2' внутри ТОЙ ЖЕ папки означает ЧЛЕНА
      // (приоритет bareIndex FolderDetourPlan): резолв в display-form
      // 'hm- vpn-2', канал ни при чём — edge-strip рёбер не трогает.
      final folder = FolderServers(
        id: 'f1',
        name: 'Homonym',
        enabled: true,
        tagPrefix: 'hm-',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(raw: 'vless://u@h.com:443?type=ws&security=tls#vpn-2'),
          FolderMember(
              raw: 'vless://u2@h2.com:443?type=ws&security=tls#node-b',
              detour: 'vpn-2'),
        ],
      );
      final r = await build([
        folder,
        vlessServer(id: 'x', names: ['Exit Node']),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(
            tag: 'vpn-2', label: 'Relay', isDetour: true, nodeFilter: 'Exit'),
      ]);
      expect(byTag(r, 'hm- node-b')['detour'], 'hm- vpn-2');
      expect(r.emitWarnings, isNot(contains(contains('removed detour'))));
      expect(r.emitWarnings, isNot(contains(contains('routing loop'))));
    });
  });

  group('§248 — route_final не бывает detour-каналом', () {
    test('route_final=detour-канал → vpn-1 + отдельный warning', () async {
      final r = await build(
        [vlessServer(id: 'u', names: ['A'])],
        [
          const Channel(tag: 'vpn-1', label: 'Main'),
          const Channel(tag: 'vpn-2', label: 'Relay', isDetour: true),
        ],
        routeFinal: 'vpn-2',
      );
      expect((r.config['route'] as Map)['final'], 'vpn-1');
      expect(
          r.emitWarnings,
          contains(contains(
              'Route final "vpn-2" is a detour channel and cannot be a rule '
              'target')));
    });

    test('route_final=auto-двойник detour-канала → vpn-1', () async {
      final r = await build(
        [vlessServer(id: 'u', names: ['A'])],
        [
          const Channel(tag: 'vpn-1', label: 'Main'),
          const Channel(
              tag: 'vpn-2',
              label: 'Relay',
              isDetour: true,
              auto: ChannelAuto()),
        ],
        routeFinal: 'vpn-2-auto',
      );
      expect((r.config['route'] as Map)['final'], 'vpn-1');
      expect(r.emitWarnings, contains(contains('is a detour channel')));
    });

    test('route_final=обычный канал остаётся как есть', () async {
      final r = await build(
        [vlessServer(id: 'u', names: ['A'])],
        [
          const Channel(tag: 'vpn-1', label: 'Main'),
          const Channel(tag: 'vpn-2', label: 'Plain'),
        ],
        routeFinal: 'vpn-2',
      );
      expect((r.config['route'] as Map)['final'], 'vpn-2');
    });
  });

  group('§248 — AWG→WG advisory', () {
    WireguardSpec wgSpec({
      required String tag,
      Awg? awg,
    }) =>
        WireguardSpec(
          id: tag,
          tag: tag,
          label: tag,
          server: '10.0.0.1',
          port: 51820,
          rawUri: '',
          privateKey: 'cHJpdmF0ZS1rZXktdGVzdA==',
          localAddresses: const ['10.0.0.2/32'],
          peers: const [
            WireguardPeer(
              publicKey: 'cHVibGljLWtleS10ZXN0AAAA',
              endpointHost: '10.0.0.1',
              endpointPort: 51820,
            ),
          ],
          awg: awg,
        );

    UserServer wgServer({
      required String id,
      required WireguardSpec spec,
      DetourPolicy policy = DetourPolicy.defaults,
    }) =>
        UserServer(
          id: id,
          name: id,
          enabled: true,
          tagPrefix: '',
          detourPolicy: policy,
          origin: UserSource.paste,
          createdAt: DateTime.now(),
          nodes: [spec],
        );

    test('AWG-узел детурится через канал с WG-нодой → advisory', () async {
      final r = await build([
        wgServer(id: 'exit', spec: wgSpec(tag: 'WG Exit')),
        wgServer(
            id: 'awg',
            spec: wgSpec(
                tag: 'AWG Client', awg: const Awg({'jc': 4, 'jmin': 10})),
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(
            tag: 'vpn-2',
            label: 'Relay',
            isDetour: true,
            nodeFilter: 'WG Exit'),
      ]);
      expect(
          r.emitWarnings,
          contains(contains(
              'Node "AWG Client" (AmneziaWG) detours via channel "Relay"')));
    });

    test('обычный (не-AWG) WG-узел через канал с WG — без advisory',
        () async {
      final r = await build([
        wgServer(id: 'exit', spec: wgSpec(tag: 'WG Exit')),
        wgServer(
            id: 'wg',
            spec: wgSpec(tag: 'WG Client'),
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(
            tag: 'vpn-2',
            label: 'Relay',
            isDetour: true,
            nodeFilter: 'WG Exit'),
      ]);
      expect(r.emitWarnings, isNot(contains(contains('AmneziaWG'))));
    });
  });
}
