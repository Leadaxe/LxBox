import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/channel.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/validation.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §248 — detour-каналы в билдере: block-гейт, direct-fallback пустого
/// detour-канала, autoTag-алиас, деградация route_final, AWG→WG advisory.
/// §254 — detour-циклы больше НЕ рвутся edge-strip'ом: детектор в
/// validateConfig возвращает fatal DetourCycle с минимальным набором
/// виновников (группа тестов «§254 — detour-циклы»). Harness — как в
/// channel_groups_test.dart (настоящий buildConfig, channels из settings).
void main() {
  WizardTemplate template() => WizardTemplate(
        parserConfig: ParserConfigBlock(),
        groupTemplates: GroupTemplates(),
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

  group('§254 — detour-циклы: fatal + минимальный набор виновников', () {
    // §254 сменил семантику §248: билдер цикл НЕ рвёт (никакого снятия
    // detour), детектор в validateConfig возвращает fatal DetourCycle с
    // минимальным набором culprits — конфиг не собирается, юзер устраняет
    // причину сам. Хелпер: билд без expect(isOk).
    Future<BuildResult> buildRaw(
            List<ServerList> lists, List<Channel> channels) =>
        buildConfig(
          lists: lists,
          template: template(),
          settings: BuildSettings(channels: channels),
        );

    List<DetourCycle> cyclesOf(BuildResult r) =>
        r.validation.fatal.whereType<DetourCycle>().toList();

    test('прямой цикл: member.detour=C → fatal, culprit = член, detour цел',
        () async {
      final r = await buildRaw([
        vlessServer(
            id: 'u',
            names: ['Relay Berlin'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(
            tag: 'vpn-2', label: 'Relay', isDetour: true, nodeFilter: 'Relay'),
      ]);
      final cycles = cyclesOf(r);
      expect(cycles, hasLength(1));
      expect(cycles.single.culprits,
          [(tag: 'Relay Berlin', detour: 'vpn-2')]);
      // §254 — конфиг НЕ правится: detour остаётся на месте.
      expect(byTag(r, 'Relay Berlin')['detour'], 'vpn-2');
      expect(r.emitWarnings, isNot(contains(contains('removed detour'))));
    });

    test('цикл через auto-двойник (detour=<tag>-auto) — тот же fatal',
        () async {
      final r = await buildRaw([
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
      final cycles = cyclesOf(r);
      expect(cycles, hasLength(1));
      expect(cycles.single.culprits.single.tag, 'Relay Berlin');
      expect(cycles.single.message, contains('Routing loop'));
    });

    test('транзитивный цикл через промежуточный узел — 1 culprit', () async {
      // Client ∈ vpn-2; Client→Mid→vpn-2. Оба ребра развязывают цикл
      // (равный score) — тай-брейк лексикографический даёт Client.
      // Показывается ОДИН виновник, цикл целиком — в issue.cycle.
      final r = await buildRaw([
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
      final cycles = cyclesOf(r);
      expect(cycles, hasLength(1));
      expect(cycles.single.culprits, hasLength(1));
      expect(cycles.single.culprits.single.tag, 'Client');
      expect(cycles.single.cycle,
          containsAll(<String>['Client', 'Mid', 'vpn-2']));
    });

    test('межканальный цикл: A∈C1→C2, B∈C2→C1 — один culprit, один issue',
        () async {
      final r = await buildRaw([
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
      // Кольцо одно (A→C2→B→C1→A): минимальный набор = 1 ребро (какое —
      // тай-брейк, оба симметричны).
      final cycles = cyclesOf(r);
      expect(cycles, hasLength(1));
      expect(cycles.single.culprits, hasLength(1));
    });

    test('ссылка на ОБЫЧНЫЙ канал (Debug API-сценарий) — тот же fatal',
        () async {
      final r = await buildRaw([
        vlessServer(
            id: 'u',
            names: ['Node X'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(tag: 'vpn-2', label: 'Plain', nodeFilter: 'Node X'),
      ]);
      expect(cyclesOf(r).single.culprits.single.tag, 'Node X');
    });

    test('флагман §248: relay в той же подписке под overrideDetour=C — '
        'fatal с culprit=relay, клиенты невиновны', () async {
      // §254 — осознанная смена поведения: раньше edge-strip выпутывал relay
      // автоматически, теперь юзер устраняет сам (см. spec 254, секция
      // «Осознанное изменение поведения»).
      final r = await buildRaw([
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
      final cycles = cyclesOf(r);
      expect(cycles, hasLength(1));
      // Минимальный набор: только relay (член канала), клиенты — транзит.
      expect(cycles.single.culprits,
          [(tag: 'Relay Berlin', detour: 'vpn-2')]);
    });

    test('реальный кейс §254: флот∈C1→C2, одна нода∈C2→C1 — culprit '
        'ровно она, не флот', () async {
      // Миниатюра device-кейса: 3 «BL»-ноды в vpn-2 детурят в vpn-3
      // (WARP IN); внутри vpn-3 одна AWG-нода по ошибке детурит обратно в
      // vpn-2, две MASQUE-ноды чисты. Виновник — ровно AWG (1, не 3).
      final r = await buildRaw([
        vlessServer(
            id: 'bl',
            names: ['BL Sofia', 'BL Zagreb', 'BL Helsinki'],
            policy: const DetourPolicy(overrideDetour: 'vpn-3')),
        vlessServer(id: 'in1', names: ['IN Masque A']),
        vlessServer(id: 'in2', names: ['IN Masque B']),
        vlessServer(
            id: 'awg',
            names: ['IN Awg'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(
            tag: 'vpn-2', label: 'BL', isDetour: true, nodeFilter: 'BL'),
        const Channel(
            tag: 'vpn-3', label: 'WARP IN', isDetour: true, nodeFilter: 'IN'),
      ]);
      final cycles = cyclesOf(r);
      expect(cycles, hasLength(1));
      expect(cycles.single.culprits, [(tag: 'IN Awg', detour: 'vpn-2')]);
      // Флот не тронут и не оговорён.
      expect(byTag(r, 'BL Sofia')['detour'], 'vpn-3');
      expect(cycles.single.message, isNot(contains('BL Sofia')));
    });

    test('линейная цепочка каналов C1→C2→C3 без замыкания → ok', () async {
      // Регрессия device-кейса ПОСЛЕ устранения виновника: [BL]→WARP IN→
      // наружу, WARP OUT→[BL] — ацикличная цепочка, fatal быть не должно.
      final r = await build([
        vlessServer(
            id: 'out',
            names: ['OUT Warp'],
            policy: const DetourPolicy(overrideDetour: 'vpn-3')),
        vlessServer(
            id: 'bl',
            names: ['BL Sofia', 'BL Zagreb'],
            policy: const DetourPolicy(overrideDetour: 'vpn-4')),
        vlessServer(id: 'in1', names: ['IN Masque'])
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(
            tag: 'vpn-2', label: 'OUT', isDetour: true, nodeFilter: 'OUT'),
        const Channel(
            tag: 'vpn-3', label: 'BL', isDetour: true, nodeFilter: 'BL'),
        const Channel(
            tag: 'vpn-4', label: 'WARP IN', isDetour: true, nodeFilter: 'IN'),
      ]);
      expect(byTag(r, 'BL Sofia')['detour'], 'vpn-4');
      expect(byTag(r, 'OUT Warp')['detour'], 'vpn-3');
    });

    test('два независимых кольца → два issue, по culprit на каждое',
        () async {
      final r = await buildRaw([
        vlessServer(
            id: 'x',
            names: ['Node X'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
        vlessServer(
            id: 'y',
            names: ['Node Y'],
            policy: const DetourPolicy(overrideDetour: 'vpn-3')),
      ], [
        const Channel(tag: 'vpn-1', label: 'Main'),
        const Channel(
            tag: 'vpn-2', label: 'C1', isDetour: true, nodeFilter: 'Node X'),
        const Channel(
            tag: 'vpn-3', label: 'C2', isDetour: true, nodeFilter: 'Node Y'),
      ]);
      final cycles = cyclesOf(r);
      expect(cycles, hasLength(2));
      expect(
          cycles.expand((c) => c.culprits.map((x) => x.tag)),
          containsAll(<String>['Node X', 'Node Y']));
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
