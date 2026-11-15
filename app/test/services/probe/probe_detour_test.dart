import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/probe/probe_config.dart';
import 'package:lxbox/services/probe/probe_detour.dart';

import '../../parser/engine_test_setup.dart';

/// §730 — detour источника в «Тесте серверов»: классификация (нет / учтён /
/// не учтён) по каждому роду ссылки и сборка probe-конфига по плану.

NodeSpec _n(String tag, {String host = '', String scheme = 'vless'}) {
  final h = host.isEmpty ? 'h${tag.hashCode.abs()}.example' : host;
  if (scheme == 'naive') {
    return FolderMember(raw: 'naive+https://u:p@$h:443#$tag').node!;
  }
  return VlessSpec(
    id: tag,
    tag: tag,
    label: tag,
    server: h,
    port: 443,
    rawSource: '',
    uuid: '00000000-0000-0000-0000-000000000000',
  );
}

/// Узел с родной цепочкой (⚙-звено).
NodeSpec _chained(String tag, NodeSpec hop) => VlessSpec(
      id: tag,
      tag: tag,
      label: tag,
      server: 'h${tag.hashCode.abs()}.example',
      port: 443,
      rawSource: '',
      uuid: '00000000-0000-0000-0000-000000000000',
      chained: hop,
    );

UserServer _server(String id, NodeSpec node,
        {String prefix = '',
        bool enabled = true,
        DetourPolicy policy = DetourPolicy.defaults}) =>
    UserServer(
      id: id,
      name: id,
      enabled: enabled,
      tagPrefix: prefix,
      detourPolicy: policy,
      nodes: [node],
    );

SubscriptionServers _sub(String id, List<NodeSpec> nodes,
        {DetourPolicy policy = DetourPolicy.defaults,
        String prefix = '',
        bool enabled = true,
        Map<String, DateTime> disabled = const {}}) =>
    SubscriptionServers(
      id: id,
      name: id,
      enabled: enabled,
      tagPrefix: prefix,
      detourPolicy: policy,
      url: 'https://example.com/$id',
      nodes: nodes,
      disabledHashes: disabled,
    );

DetourPolicy _via(NodeLink link, {bool replace = false, bool use = true}) =>
    DetourPolicy(
        overrideDetour: link, replaceDetourChain: replace, useDetourServers: use);

void main() {
  setUpAll(loadEngineSections);

  group('§730 классификация', () {
    // late — лениво: разбор узла требует секций реестра (setUpAll).
    late final proxy = _server('srv', _n('Proxy'));

    test('override не задан — план пуст', () {
      final s = _sub('s', [_n('A')]);
      expect(probeDetourPlanOf(s, [s, proxy]).isEmpty, isTrue);
    });

    test('useDetourServers=false в режиме append — план пуст (как в сборке)', () {
      final s = _sub('s', [_n('A')],
          policy: _via(const NodeLink(tag: 'Proxy'), use: false));
      expect(probeDetourPlanOf(s, [s, proxy]).isEmpty, isTrue);
    });

    test('useDetourServers=false + replace — ссылка всё равно применяется', () {
      final s = _sub('s', [_n('A')],
          policy: _via(const NodeLink(tag: 'Proxy'), use: false, replace: true));
      final r = probeDetourPlanOf(s, [s, proxy]).at(0);
      expect(r.kind, ProbeDetourKind.applied);
      expect(r.replace, isTrue);
    });

    test('корневая ссылка на узел одиночного сервера — учтён', () {
      final p = _server('srv', _n('Proxy'), prefix: '🔌');
      final s = _sub('s', [_n('A'), _n('B')],
          policy: _via(const NodeLink(tag: '🔌 Proxy')));
      final plan = probeDetourPlanOf(s, [s, p]);
      expect(plan.appliedCount, 2);
      final r = plan.at(1);
      expect(r.kind, ProbeDetourKind.applied);
      expect(identical(r.target, p.nodes.single), isTrue);
      expect(r.replace, isFalse);
      expect(r.targetLabel, '🔌 Proxy');
      expect(plan.appliedLabels, ['🔌 Proxy']);
    });

    test('корневое имя без узла (Направление, -auto, служебный) — не учтён', () {
      for (final tag in ['vpn-1', 'vpn-1-auto', 'direct-out', 'my-chain']) {
        final s = _sub('s', [_n('A')], policy: _via(NodeLink(tag: tag)));
        expect(probeDetourPlanOf(s, [s, proxy]).at(0).kind,
            ProbeDetourKind.unapplied,
            reason: tag);
      }
    });

    test('неоднозначная корневая ссылка (два тёзки) — не учтён', () {
      final s = _sub('s', [_n('A')], policy: _via(const NodeLink(tag: 'Proxy')));
      final twin = _server('srv2', _n('Proxy', host: 'other.example'));
      expect(probeDetourPlanOf(s, [s, proxy, twin]).at(0).kind,
          ProbeDetourKind.unapplied);
    });

    test('ссылка на узел подписки (folderId + сырой тег) — учтён', () {
      final hub = _sub('hub', [_n('X'), _n('Y')], prefix: 'H');
      final s = _sub('s', [_n('A')],
          policy: _via(const NodeLink(folderId: 'hub', tag: 'Y'),
              replace: true));
      final r = probeDetourPlanOf(s, [s, hub]).at(0);
      expect(r.kind, ProbeDetourKind.applied);
      expect(identical(r.target, hub.nodes[1]), isTrue);
      expect(r.replace, isTrue);
      expect(r.targetLabel, 'H Y');
    });

    test('источник цели удалён / нет узла — не учтён', () {
      final hub = _sub('hub', [_n('X')]);
      for (final link in const [
        NodeLink(folderId: 'gone', tag: 'X'),
        NodeLink(folderId: 'hub', tag: 'Nope'),
      ]) {
        final s = _sub('s', [_n('A')], policy: _via(link));
        expect(probeDetourPlanOf(s, [s, hub]).at(0).kind,
            ProbeDetourKind.unapplied);
      }
    });

    test('выключенная цель (узел, подписка, сервер) — не учтён', () {
      final nodes = [_n('X')];
      final id = sourceNodeIdentities(nodes)[nodes.first]!;
      final hubOff = _sub('hub', nodes, disabled: {id: DateTime(2026)});
      final s = _sub('s', [_n('A')],
          policy: _via(const NodeLink(folderId: 'hub', tag: 'X')));
      expect(probeDetourPlanOf(s, [s, hubOff]).at(0).kind,
          ProbeDetourKind.unapplied);

      final hubDisabled = _sub('hub', [_n('X')], enabled: false);
      expect(probeDetourPlanOf(s, [s, hubDisabled]).at(0).kind,
          ProbeDetourKind.unapplied);

      final s2 =
          _sub('s', [_n('A')], policy: _via(const NodeLink(tag: 'Proxy')));
      final srvOff = _server('srv', _n('Proxy'), enabled: false);
      expect(probeDetourPlanOf(s2, [s2, srvOff]).at(0).kind,
          ProbeDetourKind.unapplied);
    });

    test('цель — группа — не учтён', () {
      final f = FolderServers(
        id: 'f',
        name: 'f',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember.auto(AutoSelectSpec(
              id: 'G',
              tag: 'G',
              label: 'G',
              membership: const RuleMembers())),
        ],
      );
      final s = _sub('s', [_n('A')],
          policy: _via(const NodeLink(folderId: 'f', tag: 'G')));
      expect(probeDetourPlanOf(s, [s, f]).at(0).kind,
          ProbeDetourKind.unapplied);
    });

    test('у цели свой override (прокси за прокси) — не учтён, без рекурсии', () {
      final hub = _sub('hub', [_n('X')],
          policy: _via(const NodeLink(tag: 'Proxy')));
      final s = _sub('s', [_n('A')],
          policy: _via(const NodeLink(folderId: 'hub', tag: 'X')));
      expect(probeDetourPlanOf(s, [s, hub, proxy]).at(0).kind,
          ProbeDetourKind.unapplied);
    });

    test('override в узел своего же источника — не учтён', () {
      final s = _sub('s', [_n('A'), _n('B')],
          policy: _via(const NodeLink(folderId: 's', tag: 'B')));
      final plan = probeDetourPlanOf(s, [s]);
      expect(plan.at(0).kind, ProbeDetourKind.unapplied);
      expect(plan.at(1).kind, ProbeDetourKind.unapplied);
    });

    group('папка', () {
      FolderServers folder(List<FolderMember> members,
              {DetourPolicy policy = DetourPolicy.defaults}) =>
          FolderServers(
            id: 'fold',
            name: 'fold',
            enabled: true,
            tagPrefix: '',
            detourPolicy: policy,
            members: members,
          );
      const a = 'vless://ua@a.example:443?type=ws&security=tls#A';
      const b = 'vless://ub@b.example:443?type=ws&security=tls#B';
      const c = 'vless://uc@c.example:443?type=ws&security=tls#C';

      test('личный detour члена учитывается, у остальных — нет', () {
        final f = folder([
          FolderMember(raw: a, detour: const NodeLink(tag: 'Proxy')),
          FolderMember(raw: b),
        ]);
        final plan = probeDetourPlanOf(f, [f, proxy]);
        expect(plan.at(0).kind, ProbeDetourKind.applied);
        expect(plan.at(1).kind, ProbeDetourKind.none);
      });

      test('личный detour сильнее папочного append; папочный replace сильнее личного',
          () {
        final other = _server('srv2', _n('Other'));
        final append = folder([
          FolderMember(raw: a, detour: const NodeLink(tag: 'Proxy')),
          FolderMember(raw: b),
        ], policy: _via(const NodeLink(tag: 'Other')));
        final p1 = probeDetourPlanOf(append, [append, proxy, other]);
        expect(p1.at(0).targetLabel, 'Proxy');
        expect(p1.at(1).targetLabel, 'Other');
        expect(p1.appliedLabels, ['Proxy', 'Other']);

        final replace = folder([
          FolderMember(raw: a, detour: const NodeLink(tag: 'Proxy')),
        ], policy: _via(const NodeLink(tag: 'Other'), replace: true));
        final p2 = probeDetourPlanOf(replace, [replace, proxy, other]);
        expect(p2.at(0).targetLabel, 'Other');
        expect(p2.at(0).replace, isTrue);
      });

      test('интра-detour: цель — член этой же папки без своего detour', () {
        final f = folder([
          FolderMember(raw: a, detour: const NodeLink(folderId: 'fold', tag: 'B')),
          FolderMember(raw: b),
        ]);
        final plan = probeDetourPlanOf(f, [f]);
        expect(plan.at(0).kind, ProbeDetourKind.applied);
        expect(identical(plan.at(0).target, f.members[1].node), isTrue);
      });

      test('интра-цель со своим личным detour — не учтён (один уровень)', () {
        final f = folder([
          FolderMember(raw: a, detour: const NodeLink(folderId: 'fold', tag: 'B')),
          FolderMember(raw: b, detour: const NodeLink(tag: 'Proxy')),
        ]);
        final plan = probeDetourPlanOf(f, [f, proxy]);
        expect(plan.at(0).kind, ProbeDetourKind.unapplied);
        expect(plan.at(1).kind, ProbeDetourKind.applied);
        expect(plan.appliedCount, 1);
        expect(plan.unappliedCount, 1);
      });

      test('папочный override в своего члена: цель — exempt, остальные идут через неё',
          () {
        final f = folder([FolderMember(raw: a), FolderMember(raw: b)],
            policy: _via(const NodeLink(folderId: 'fold', tag: 'B')));
        final plan = probeDetourPlanOf(f, [f]);
        expect(plan.at(0).kind, ProbeDetourKind.applied);
        expect(plan.at(1).kind, ProbeDetourKind.none, reason: 'exempt');
      });

      test('выключенный член тестируется и получает свой маршрут по индексу',
          () {
        final f = folder([
          FolderMember(raw: a),
          FolderMember(
              raw: b, enabled: false, detour: const NodeLink(tag: 'Proxy')),
          FolderMember(raw: c, detour: const NodeLink(tag: 'vpn-1')),
        ]);
        final plan = probeDetourPlanOf(f, [f, proxy]);
        expect(plan.at(0).kind, ProbeDetourKind.none);
        expect(plan.at(1).kind, ProbeDetourKind.applied);
        expect(plan.at(2).kind, ProbeDetourKind.unapplied);
      });

      test('цель — выключенный член папки — не учтён', () {
        final f = folder([
          FolderMember(raw: a, detour: const NodeLink(folderId: 'fold', tag: 'B')),
          FolderMember(raw: b, enabled: false),
        ]);
        expect(probeDetourPlanOf(f, [f]).at(0).kind, ProbeDetourKind.unapplied);
      });
    });
  });

  group('§730 probe-конфиг', () {
    Map<String, dynamic> cfg(ProbeConfig c) =>
        jsonDecode(c.configJson!) as Map<String, dynamic>;
    Map<String, dynamic> byTag(Map<String, dynamic> c, String tag) => [
          ...(c['outbounds'] as List),
          ...((c['endpoints'] as List?) ?? const []),
        ].cast<Map<String, dynamic>>().firstWhere((e) => e['tag'] == tag);

    ProbeDetourPlan planOf(Map<int, NodeSpec> targets,
            {bool replace = false}) =>
        ProbeDetourPlan({
          for (final e in targets.entries)
            e.key: ProbeDetourRoute.applied(
                target: e.value, replace: replace, targetLabel: e.value.tag),
        });

    test('без плана и с пустым планом — конфиг байт в байт прежний', () {
      final nodes = <NodeSpec?>[_chained('A', _n('⚙ Hop')), _n('B'), null];
      final base = buildProbeConfig(nodes);
      expect(buildProbeConfig(nodes, detourPlan: ProbeDetourPlan.empty).configJson,
          base.configJson);
      // План «не учтён» тоже конфиг не меняет.
      expect(
          buildProbeConfig(nodes,
                  detourPlan: const ProbeDetourPlan(
                      {0: ProbeDetourRoute.unapplied()}))
              .configJson,
          base.configJson);
    });

    test('append без родной цепочки: узел → цель', () {
      final c = buildProbeConfig([_n('A')],
          detourPlan: planOf({0: _n('Proxy')}));
      final j = cfg(c);
      expect(byTag(j, 'A')['detour'], 'Proxy');
      expect(byTag(j, 'Proxy').containsKey('detour'), isFalse);
      expect(c.tagByIndex, {0: 'A'});
      expect(c.ownerByTag['Proxy'], 0);
    });

    test('append с родной цепочкой: узел → звено → цель', () {
      final c = buildProbeConfig([_chained('A', _n('⚙ Hop'))],
          detourPlan: planOf({0: _n('Proxy')}));
      final j = cfg(c);
      expect(byTag(j, 'A')['detour'], '⚙ Hop');
      expect(byTag(j, '⚙ Hop')['detour'], 'Proxy');
    });

    test('replace: родная цепочка снята, узел сразу на цель', () {
      final c = buildProbeConfig([_chained('A', _n('⚙ Hop'))],
          detourPlan: planOf({0: _n('Proxy')}, replace: true));
      final j = cfg(c);
      expect(byTag(j, 'A')['detour'], 'Proxy');
      final tags = [for (final o in j['outbounds'] as List) o['tag']];
      expect(tags.contains('⚙ Hop'), isFalse);
    });

    test('общая цель у двух узлов — своя копия на узел, ссылки не путаются', () {
      final proxy = _chained('Proxy', _n('⚙ PHop'));
      final c = buildProbeConfig([_n('A'), _n('B')],
          detourPlan: planOf({0: proxy, 1: proxy}));
      final j = cfg(c);
      expect(byTag(j, 'A')['detour'], 'Proxy');
      expect(byTag(j, 'Proxy')['detour'], '⚙ PHop');
      expect(byTag(j, 'B')['detour'], 'Proxy-2');
      expect(byTag(j, 'Proxy-2')['detour'], '⚙ PHop-2');
      expect(c.ownerByTag['Proxy-2'], 1);
      expect(c.ownerByTag['⚙ PHop-2'], 1);
    });

    test('личный detour члена папки — только у этого члена', () {
      final proxy = _server('srv', _n('Proxy'));
      final f = FolderServers(
        id: 'fold',
        name: 'fold',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(
              raw: 'vless://ua@a.example:443?type=ws&security=tls#A',
              detour: const NodeLink(tag: 'Proxy')),
          FolderMember(raw: 'vless://ub@b.example:443?type=ws&security=tls#B'),
        ],
      );
      final c = buildProbeConfig([for (final m in f.members) m.node],
          detourPlan: probeDetourPlanOf(f, [f, proxy]));
      final j = cfg(c);
      expect(byTag(j, 'A')['detour'], 'Proxy');
      expect(byTag(j, 'B').containsKey('detour'), isFalse);
    });

    test('naive-цель считается в лимите батча', () {
      final naive = _n('NProxy', scheme: 'naive');
      final batches = buildProbeBatches([_n('A'), _n('B')],
          detourPlan: planOf({0: naive, 1: naive}));
      // kProbeMaxNaivePerConfig = 1: каждый узел со своей копией naive-цели
      // уезжает в свой батч.
      expect(batches.length, 2);
      expect(batches[0].tagByIndex.keys, [0]);
      expect(batches[1].tagByIndex.keys, [1]);
    });
  });
}
