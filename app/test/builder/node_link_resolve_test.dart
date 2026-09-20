import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import '../parser/engine_test_setup.dart';

// §439 (D-112), NODE_LINK §5 — резолв ссылок на узлы вторым проходом
// настоящего `buildConfig`: пара члена папки и узла подписки — финальный тег
// с префиксом контейнера, корневая ссылка — корневой узел или корневое имя,
// группа подписки — по сырому тегу группы. Не разрешилось — fail-closed:
// носитель detour не эмитится (каскадом и кольцом тоже), цепочка — целиком.

NodeSpec _node(String tag, int i) => parseUri(
    'vless://u$i@h$i.example:443?type=ws&security=tls#${Uri.encodeComponent(tag)}')!;

FolderServers _folder({
  NodeLink aDetour = NodeLink.none,
  NodeLink bDetour = NodeLink.none,
  bool bEnabled = true,
}) =>
    FolderServers(
      id: 'f1',
      name: 'F',
      enabled: true,
      tagPrefix: 'F',
      detourPolicy: DetourPolicy.defaults,
      members: [
        FolderMember(raw: _node('A', 1).rawSource, detour: aDetour),
        FolderMember(raw: _node('B', 2).rawSource, detour: bDetour, enabled: bEnabled),
      ],
    );

SubscriptionServers _sub({DetourPolicy policy = DetourPolicy.defaults}) =>
    SubscriptionServers(
      id: 's1',
      name: 'Sub',
      enabled: true,
      tagPrefix: 'S',
      detourPolicy: policy,
      url: 'https://example.com/sub',
      nodes: [
        _node('N1', 3),
        _node('N2', 4),
        AutoSelectSpec(
          id: 'g',
          tag: 'G',
          label: 'G',
          membership: const ExplicitMembers([NodeLink(tag: 'N1')]),
        ),
      ],
    );

UserServer _root(String tag, {NodeLink detour = NodeLink.none}) => UserServer(
      id: 'u-$tag',
      name: '',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy(overrideDetour: detour),
      origin: UserSource.paste,
      nodes: [_node(tag, 10)],
    );

Future<BuildResult> _build(
  List<ServerList> lists, {
  List<SourceChain> chains = const [],
}) =>
    buildConfig(
      lists: lists,
      template: WizardTemplate(
        parserConfig: ParserConfigBlock(),
        groupTemplates: GroupTemplates(),
        vars: const [],
        varSections: const [],
        config: {
          'outbounds': [
            {'tag': kDirectOutboundTag, 'type': 'direct'},
            {'tag': kBlockOutboundTag, 'type': 'block'},
          ],
          'route': {'rules': <dynamic>[]},
        },
        selectableRules: const [],
        dnsOptions: const {},
        pingOptions: const {},
        speedTestOptions: const {},
      ),
      settings: BuildSettings(
        directions: const [
          Direction(tag: 'vpn-1', label: 'V'),
          Direction(tag: 'relay', label: 'Relay', isDetour: true, nodeFilter: 'N2'),
        ],
        chains: chains,
        coreVersion: '1.14.0-lx.39',
      ),
    );

Map<String, dynamic>? _out(BuildResult r, String tag) {
  for (final o in r.config['outbounds'] as List) {
    if ((o as Map)['tag'] == tag) return o.cast<String, dynamic>();
  }
  return null;
}

void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

  group('разрешается в финальный тег', () {
    test('пара члена папки, пара узла подписки, корневой узел', () async {
      final r = await _build(
        [
          _folder(aDetour: const NodeLink(folderId: 's1', tag: 'N2')),
          _sub(),
          _root('R', detour: const NodeLink(folderId: 'f1', tag: 'B')),
        ],
        chains: const [
          SourceChain(tag: 'route', hops: [
            NodeLink(folderId: 'f1', tag: 'A'),
            NodeLink(folderId: 's1', tag: 'N1'),
            NodeLink(tag: 'R'),
          ]),
        ],
      );
      expect(r.emitWarnings.where((w) => w.contains('resolve')), isEmpty);
      // Префикс контейнера — в финальном теге, ссылка его не несёт.
      expect(_out(r, 'route')!['outbounds'], ['F A', 'S N1', 'R']);
      expect(_out(r, 'F A')!['detour'], 'S N2');
      expect(_out(r, 'R')!['detour'], 'F B');
    });

    test('группа подписки — пара с сырым тегом группы; Направление — корнем',
        () async {
      final r = await _build(
        [_sub(), _root('R', detour: const NodeLink(tag: 'relay'))],
        chains: const [
          SourceChain(tag: 'via-group', hops: [
            NodeLink(tag: 'R'),
            NodeLink(folderId: 's1', tag: 'G'),
          ]),
        ],
      );
      expect(_out(r, 'S G')!['type'], 'urltest');
      expect(_out(r, 'S G')!['outbounds'], ['S N1']);
      expect(_out(r, 'via-group')!['outbounds'], ['R', 'S G']);
      expect(_out(r, 'R')!['detour'], 'relay');
    });

    test('цель ниже ссылающегося в списке источников разрешается', () async {
      final r = await _build([
        _root('R', detour: const NodeLink(folderId: 'f1', tag: 'A')),
        _folder(),
      ]);
      expect(_out(r, 'R')!['detour'], 'F A');
    });
  });

  test('узел и группа-тёзка в подписке: узел N1, группа N1-2; отметка узла '
      'гасит узел, а не группу', () async {
    final sub = SubscriptionServers(
      id: 's1',
      name: 'Sub',
      enabled: true,
      tagPrefix: 'S',
      detourPolicy: DetourPolicy.defaults,
      url: 'https://example.com/sub',
      // Группа выше узла-тёзки: её сырой тег всё равно N1-2.
      nodes: [
        AutoSelectSpec(
          id: 'g',
          tag: 'N1',
          label: 'N1',
          membership: const ExplicitMembers([NodeLink(tag: 'N2')]),
        ),
        _node('N1', 3),
        _node('N2', 4),
      ],
      disabledHashes: {'N1': DateTime.utc(2026, 9, 1)},
    );
    final r = await _build(
      [sub, _root('R')],
      chains: const [
        SourceChain(tag: 'via-group', hops: [
          NodeLink(tag: 'R'),
          NodeLink(folderId: 's1', tag: 'N1-2'),
        ]),
      ],
    );
    expect(_out(r, 'S N1'), isNotNull, reason: 'финальный тег у группы');
    expect(_out(r, 'S N1')!['type'], 'urltest', reason: 'узел N1 выключен');
    expect(_out(r, 'S N1')!['outbounds'], ['S N2']);
    expect(_out(r, 'via-group')!['outbounds'], ['R', 'S N1']);
  });

  group('fail-closed', () {
    test('узла нет в контейнере — носитель detour не эмитится', () async {
      final r = await _build([
        _folder(),
        _root('R', detour: const NodeLink(folderId: 'f1', tag: 'ghost')),
      ]);
      expect(_out(r, 'R'), isNull, reason: 'напрямую не уходит');
      expect(r.emitWarnings, contains(allOf(
        contains('Node "R" was skipped'),
        contains('"ghost" in "F"'),
        contains('it has no node "ghost"'),
      )));
    });

    test('выключенный член — тот же исход, что отсутствующий', () async {
      final r = await _build([
        _folder(bEnabled: false),
        _root('R', detour: const NodeLink(folderId: 'f1', tag: 'B')),
      ]);
      expect(_out(r, 'R'), isNull);
      expect(r.emitWarnings.join('\n'), contains('it has no node "B"'));
    });

    test('корневая ссылка на члена папки не разрешается (NODE_LINK §5.1 № 6)',
        () async {
      final r = await _build([
        _folder(),
        _root('R', detour: const NodeLink(tag: 'F A')),
      ]);
      expect(_out(r, 'R'), isNull);
      expect(r.emitWarnings.join('\n'),
          contains('target "F A" is not among nodes'));
    });

    test('контейнер удалён — цепочка выпадает целиком', () async {
      final r = await _build(
        [_root('R')],
        chains: const [
          SourceChain(tag: 'route', hops: [
            NodeLink(tag: 'R'),
            NodeLink(folderId: 'gone', tag: 'X'),
          ]),
        ],
      );
      expect(_out(r, 'route'), isNull);
      expect(r.emitWarnings.join('\n'),
          contains('the referenced source is gone'));
    });

    test('каскад: цель выпала — выпадает и тот, кто ходил через неё', () async {
      final r = await _build([
        _folder(
          aDetour: const NodeLink(tag: 'ghost'),
          bDetour: const NodeLink(folderId: 'f1', tag: 'A'),
        ),
      ]);
      expect(_out(r, 'F A'), isNull);
      expect(_out(r, 'F B'), isNull);
      expect(r.emitWarnings.join('\n'),
          contains('node "F A" it goes through was skipped'));
    });

    test('кольцо через контейнеры — выпадают все участники, каскадом и '
        'остальные узлы подписки', () async {
      // R → N1 (пара), подписка S целиком → R (общий detour): N1 → R → N1.
      final r = await _build([
        _sub(policy: const DetourPolicy(overrideDetour: NodeLink(tag: 'R'))),
        _root('R', detour: const NodeLink(folderId: 's1', tag: 'N1')),
      ]);
      expect(_out(r, 'R'), isNull);
      expect(_out(r, 'S N1'), isNull);
      expect(_out(r, 'S N2'), isNull, reason: 'N2 ходил через выпавший R');
      expect(r.emitWarnings.join('\n'), contains('loops back'));
    });

    test('detour на себя — носитель выпадает', () async {
      final r = await _build([
        _root('R', detour: const NodeLink(tag: 'R')),
      ]);
      expect(_out(r, 'R'), isNull);
      expect(r.emitWarnings.join('\n'),
          contains('the detour points at the node itself'));
    });
  });
}
