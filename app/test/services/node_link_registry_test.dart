import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/codec/chain_record.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/settings_storage/node_link_registry.dart';

import '../parser/engine_test_setup.dart';

// §439 §2.5, D-113/D-114, NODE_LINK §6 — реестр ссылок на узлы: операция,
// меняющая АДРЕС узла (переименование, перенос), переписывает ссылки во всех
// носителях — detour источника и члена, позиции цепочек, состав autogroup;
// удаление гасит их и называет задетых; смена `tag_policy` папки адрес не
// меняет и ссылки не трогает, новый финальный тег даёт сборка.

String _uri(String name, {String host = 'h.example'}) =>
    'vless://11111111-1111-1111-1111-111111111111@$host:443'
    '?type=ws&security=tls#$name';

const _f1 = 'f1';
const _f2 = 'f2';

FolderServers _folder(
  String id,
  List<FolderMember> members, {
  String prefix = '',
}) =>
    FolderServers(
      id: id,
      name: id.toUpperCase(),
      enabled: true,
      tagPrefix: prefix,
      detourPolicy: DetourPolicy.defaults,
      members: members,
    );

UserServer _root(String tag, {NodeLink detour = NodeLink.none}) => UserServer(
      id: 'u-$tag',
      name: '',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy(overrideDetour: detour),
      origin: UserSource.paste,
      rawBody: _uri(tag, host: '$tag.example'),
      nodes: [parseUri(_uri(tag, host: '$tag.example'))!],
    );

FolderMember _group(String tag, List<NodeLink> members) => FolderMember.auto(
    AutoSelectSpec(
        id: tag,
        tag: tag,
        label: tag,
        membership: ExplicitMembers(members)));

/// Состояние: папка f1 (A, B → A, группа G {A}), папка f2 (C), корневой R → A,
/// цепочка [A, R].
({List<ServerList> lists, List<SourceChain> chains}) _state() {
  const a = NodeLink(folderId: _f1, tag: 'A');
  return (
    lists: [
      _folder(_f1, [
        FolderMember(raw: _uri('A', host: 'a.example')),
        FolderMember(raw: _uri('B', host: 'b.example'), detour: a),
        _group('G', const [a]),
      ]),
      _folder(_f2, [FolderMember(raw: _uri('C', host: 'c.example'))]),
      _root('R', detour: a),
    ],
    chains: const [
      SourceChain(tag: 'route', hops: [a, NodeLink(tag: 'R')]),
    ],
  );
}

FolderServers _f(List<ServerList> lists, String id) =>
    lists.whereType<FolderServers>().singleWhere((f) => f.id == id);

NodeLinkRelink _relink(
  List<ServerList> before,
  List<ServerList> after,
  List<SourceChain> chains, {
  Map<NodeSpec, NodeSpec> renamed = const {},
  Set<String> goneContainers = const {},
}) {
  final diff = diffNodeAddresses(before, after, renamed: renamed);
  return relinkNodeLinks(after, chains,
      moves: diff.moves, gone: diff.gone, goneContainers: goneContainers);
}

void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

  group('реестр ссылок (чистые функции)', () {
    test('переименование члена папки переписывает все носители', () {
      final s = _state();
      final f1 = _f(s.lists, _f1);
      final renamedMember =
          FolderMember(raw: _uri('A2', host: 'a.example'));
      final after = [
        f1.copyWith(members: [renamedMember, ...f1.members.skip(1)]),
        ...s.lists.skip(1),
      ];
      final r = _relink(s.lists, after, s.chains,
          renamed: {f1.members[0].node!: renamedMember.node!});

      const a2 = NodeLink(folderId: _f1, tag: 'A2');
      final nf1 = _f(r.lists, _f1);
      expect(nf1.members[1].detour, a2, reason: 'detour члена');
      expect(
          ((nf1.members[2].node as AutoSelectSpec).membership as ExplicitMembers)
              .members,
          [a2],
          reason: 'состав autogroup');
      expect(r.lists.whereType<UserServer>().single.detourPolicy.overrideDetour,
          a2,
          reason: 'detour корневого узла');
      expect(r.chains.single.hops, [a2, const NodeLink(tag: 'R')],
          reason: 'позиция цепочки');
      expect(r.cleared.isEmpty, isTrue, reason: 'перепись ничего не гасит');
      expect(r.rewritten.detourCarriers, ['B', 'R']);
      expect(r.rewritten.touchedGroups, ['G']);
      expect(r.rewritten.groupMembers, 1);
      expect(r.rewritten.positions, 1);
    });

    test('переименование корневого узла переписывает корневые ссылки', () {
      final s = _state();
      final root = s.lists.whereType<UserServer>().single;
      final f2 = _f(s.lists, _f2);
      final before = [
        _f(s.lists, _f1),
        f2.copyWith(members: [
          f2.members.single.copyWith(detour: const NodeLink(tag: 'R')),
        ]),
        root,
      ];
      final renamed = root.copyWith(
          rawBody: _uri('R2', host: 'R.example'),
          nodes: [parseUri(_uri('R2', host: 'R.example'))!]);
      final after = [before[0], before[1], renamed];
      final r = _relink(before, after, s.chains,
          renamed: {root.nodes.single: renamed.nodes.single});
      expect(_f(r.lists, _f2).members.single.detour, const NodeLink(tag: 'R2'));
      expect(r.chains.single.hops.last, const NodeLink(tag: 'R2'));
    });

    test('перенос члена между папками переписывает folder_id', () {
      final s = _state();
      final f1 = _f(s.lists, _f1);
      final f2 = _f(s.lists, _f2);
      final moved = f1.members[0];
      final after = [
        f1.copyWith(members: f1.members.skip(1).toList()),
        f2.copyWith(members: [...f2.members, moved]),
        ...s.lists.skip(2),
      ];
      final r = _relink(s.lists, after, s.chains);
      const moved2 = NodeLink(folderId: _f2, tag: 'A');
      expect(r.lists.whereType<UserServer>().single.detourPolicy.overrideDetour,
          moved2);
      expect(_f(r.lists, _f1).members.first.detour, moved2);
      expect(r.chains.single.hops.first, moved2);
    });

    test('удаление гасит ссылки и называет задетых порознь: detour, члены '
        'групп, позиции цепочек', () {
      final s = _state();
      final f1 = _f(s.lists, _f1);
      final after = [
        f1.copyWith(members: f1.members.skip(1).toList()),
        ...s.lists.skip(1),
      ];
      final r = _relink(s.lists, after, s.chains);
      expect(r.lists.whereType<UserServer>().single.detourPolicy.overrideDetour,
          NodeLink.none);
      final nf1 = _f(r.lists, _f1);
      expect(nf1.members.first.detour, NodeLink.none);
      expect(
          ((nf1.members[1].node as AutoSelectSpec).membership as ExplicitMembers)
              .members,
          isEmpty);
      expect(r.chains.single.hops, const [NodeLink(tag: 'R')],
          reason: 'позиция уходит, цепочка остаётся');

      // Член autogroup — не detour (находка AVD: «detour removed from 2
      // source(s)» при одном detour-носителе и группе).
      expect(r.cleared.detourCarriers, ['B', 'R']);
      expect(r.cleared.touchedGroups, ['G']);
      expect(r.cleared.groupMembers, 1);
      expect(r.cleared.positions, 1);
      expect(r.cleared.touchedChains, ['route']);
    });

    test('смена tag_policy папки ссылок не трогает, финальный тег на сборке '
        'новый', () async {
      final s = _state();
      final f1 = _f(s.lists, _f1);
      final after = [f1.copyWith(tagPrefix: 'EU'), ...s.lists.skip(1)];
      final diff = diffNodeAddresses(s.lists, after);
      expect(diff.moves, isEmpty);
      expect(diff.gone, isEmpty);

      Future<Map<String, dynamic>> chainOf(List<ServerList> lists) async {
        final r = await buildConfig(
          lists: lists,
          template: _template(),
          settings: BuildSettings(
            directions: const [Direction(tag: 'vpn-1', label: 'V')],
            chains: s.chains,
            coreVersion: '1.14.0-lx.39',
          ),
        );
        return (r.config['outbounds'] as List)
            .cast<Map<String, dynamic>>()
            .singleWhere((o) => o['tag'] == 'route');
      }

      expect((await chainOf(s.lists))['outbounds'], ['A', 'R']);
      expect((await chainOf(after))['outbounds'], ['EU A', 'R']);
      final rootDetour = (await buildConfig(
        lists: after,
        template: _template(),
        settings: const BuildSettings(
            directions: [Direction(tag: 'vpn-1', label: 'V')]),
      ))
          .config['outbounds'] as List;
      expect(
          rootDetour.cast<Map>().singleWhere((o) => o['tag'] == 'R')['detour'],
          'EU A');
    });
  });

  group('реестр ссылок (контроллер)', () {
    late Directory tmp;
    const channel = MethodChannel('plugins.flutter.io/path_provider');

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tmp = await Directory.systemTemp.createTemp('lxbox_node_link_registry_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory' ||
            call.method == 'getApplicationDocumentsPath') {
          return tmp.path;
        }
        return null;
      });
      SettingsStorage.resetCacheForTesting();
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      try {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      } catch (_) {}
    });

    Future<SubscriptionController> boot() async {
      final s = _state();
      await File('${tmp.path}/lxbox_settings.json').writeAsString(jsonEncode({
        'storage_version': 1,
        'directions_migrated': true,
        'directions': [const Direction(tag: 'vpn-1', label: 'V').toJson()],
        'sources': [
          for (final l in s.lists) sourceToRecord(l),
          for (final c in s.chains) chainToRecord(c),
        ],
      }));
      SettingsStorage.resetCacheForTesting();
      final c = SubscriptionController();
      await c.init();
      await c.rehydrationDone;
      return c;
    }

    test('правка тела члена (переименование) переписывает хранение', () async {
      final c = await boot();
      expect(await c.updateMemberAt(0, 0, _uri('A2', host: 'a.example')),
          isNull);
      SettingsStorage.resetCacheForTesting();
      const a2 = NodeLink(folderId: _f1, tag: 'A2');
      final lists = await SettingsStorage.getServerLists();
      expect(_f(lists, _f1).members[1].detour, a2);
      expect(lists.whereType<UserServer>().single.detourPolicy.overrideDetour,
          a2);
      expect((await SettingsStorage.getChains()).single.hops.first, a2);
      expect(c.takeLinkNotices(), isEmpty, reason: 'перепись не уведомляет');
    });

    test('удаление члена: уведомление считает detour, члены групп и позиции '
        'порознь', () async {
      final c = await boot();
      await c.removeMemberAt(0, 0);
      final notice = c.takeLinkNotices().single;
      expect(notice.subject.name, 'A');
      expect(notice.change.detourCarriers, hasLength(2),
          reason: 'R и член B — detour; группа G — не detour');
      expect(notice.change.touchedGroups, ['G']);
      expect(notice.change.groupMembers, 1);
      expect(notice.change.positions, 1);
      expect((await SettingsStorage.getChains()).single.hops,
          const [NodeLink(tag: 'R')]);
    });

    test('перенос члена в другую папку переписывает folder_id в хранении',
        () async {
      final c = await boot();
      expect(await c.moveMemberToFolder(0, 0, 1), isNull);
      SettingsStorage.resetCacheForTesting();
      const moved = NodeLink(folderId: _f2, tag: 'A');
      final lists = await SettingsStorage.getServerLists();
      expect(lists.whereType<UserServer>().single.detourPolicy.overrideDetour,
          moved);
      expect((await SettingsStorage.getChains()).single.hops.first, moved);
    });
  });
}

WizardTemplate _template() => WizardTemplate(
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
    );
