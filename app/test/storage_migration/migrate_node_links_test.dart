import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/codec/chain_record.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/storage_migration/migrate_storage.dart';

// §439 §2.3 п. 8 — миграция ссылок 2.23.2 → NodeLink: финальный тег строкой
// переводится по состоянию до миграции (словарь финальных тегов той же
// сборкой, `sub_cache` для узлов подписок); не нашлось или неоднозначно —
// корень с предупреждением; Направление и служебный тег — корень молча.
// Отдельно — члены папок `autogroup://` (N2): составные ключи → пары.

String _uri(String name, String host) =>
    'vless://11111111-1111-1111-1111-111111111111@$host:443'
    '?type=ws&security=tls#${Uri.encodeComponent(name)}';

Map<String, dynamic> _folderV0(
  String id,
  String prefix,
  List<Map<String, dynamic>> members, {
  bool enabled = true,
  String overrideDetour = '',
}) =>
    {
      'type': 'folder',
      'id': id,
      'name': id,
      'enabled': enabled,
      'tag_prefix': prefix,
      'detour_policy': {'override_detour': overrideDetour},
      'created_at': '2026-09-01T00:00:00.000',
      'members': members,
    };

Map<String, dynamic> _serverV0(String id, String raw, {String detour = ''}) => {
      'type': 'user',
      'id': id,
      'name': '',
      'enabled': true,
      'origin': 'paste',
      'created_at': '2026-09-01T00:00:00.000',
      'raw_body': raw,
      'detour_policy': {'override_detour': detour},
    };

StorageMigrationResult _migrate(
  Map<String, dynamic> doc, {
  Map<String, String> bodies = const {},
}) =>
    migrateStorageDoc(doc, subscriptionBodies: bodies);

List<Map<String, dynamic>> _sources(StorageMigrationResult r) =>
    [for (final s in r.doc['sources'] as List) (s as Map).cast<String, dynamic>()];

ServerList _list(StorageMigrationResult r, String id) => sourceFromRecord(
        _sources(r).firstWhere((s) => s['id'] == id))
    .value!;

List<NodeLink> _hops(StorageMigrationResult r, String tag) => chainFromRecord(
        _sources(r).firstWhere((s) => s['kind'] == 'chain' && s['tag'] == tag))
    .value!
    .hops;

void main() {
  final directions = [const Direction(tag: 'vpn-1', label: 'V').toJson()];

  group('финальная строка → NodeLink', () {
    test('член папки с префиксом — пара {id папки, сырой тег}', () {
      final r = _migrate({
        'directions': directions,
        'server_lists': [
          _folderV0('fold-eu', 'EU', [
            {'raw': _uri('de-1', 'a.example'), 'enabled': true},
            {'raw': _uri('nl-1', 'b.example'), 'enabled': true},
          ]),
          _serverV0('srv', _uri('Root', 'c.example'), detour: 'EU de-1'),
        ],
        'chains': [
          {'tag': 'c', 'hops': ['EU nl-1', 'vpn-1', 'direct-out'], 'order': 1},
        ],
      });
      expect(r.warnings, isEmpty);
      expect(_list(r, 'srv').detourPolicy.overrideDetour,
          const NodeLink(folderId: 'fold-eu', tag: 'de-1'));
      expect(_hops(r, 'c'), const [
        NodeLink(folderId: 'fold-eu', tag: 'nl-1'),
        NodeLink(tag: 'vpn-1'),
        NodeLink(tag: 'direct-out'),
      ], reason: 'Направление и служебный тег — корнем, без предупреждения');
    });

    test('голый тег соседа по папке — пара (интра-ссылка 2.23.2)', () {
      final r = _migrate({
        'server_lists': [
          _folderV0('f', 'P', [
            {'raw': _uri('a', 'a.example'), 'enabled': true},
            {'raw': _uri('b', 'b.example'), 'enabled': true, 'detour': 'a'},
          ]),
        ],
      });
      final folder = _list(r, 'f') as FolderServers;
      expect(folder.members[1].detour, const NodeLink(folderId: 'f', tag: 'a'));
    });

    test('узел подписки из sub_cache — пара {id подписки, сырой тег}', () {
      const url = 'https://example.com/sub/1';
      final r = _migrate({
        'server_lists': [
          {
            'type': 'subscription',
            'id': 'sub-1',
            'name': 'Provider',
            'enabled': true,
            'tag_prefix': 'PR',
            'url': url,
          },
          _serverV0('srv', _uri('Root', 'c.example'), detour: 'PR DE-1'),
        ],
      }, bodies: {
        url: '${_uri('DE-1', 'd.example')}\n${_uri('NL-1', 'n.example')}',
      });
      expect(r.warnings, isEmpty);
      expect(_list(r, 'srv').detourPolicy.overrideDetour,
          const NodeLink(folderId: 'sub-1', tag: 'DE-1'));
    });

    test('неоднозначная строка — корень с предупреждением', () {
      // Обе папки выключены: в словаре сборки их нет, запасной путь по
      // финальной форме даёт двух кандидатов.
      final r = _migrate({
        'server_lists': [
          _folderV0('x1', 'X', [
            {'raw': _uri('a', 'a1.example'), 'enabled': true},
          ], enabled: false),
          _folderV0('x2', 'X', [
            {'raw': _uri('a', 'a2.example'), 'enabled': true},
          ], enabled: false),
          _serverV0('srv', _uri('Root', 'c.example'), detour: 'X a'),
        ],
      });
      expect(_list(r, 'srv').detourPolicy.overrideDetour,
          const NodeLink(tag: 'X a'));
      expect(r.warnings, [
        allOf(contains('detour "X a" matches 2 nodes'),
            contains('kept as a root link')),
      ]);
    });

    test('строка без узла — корень с предупреждением', () {
      final r = _migrate({
        'directions': directions,
        'chains': [
          {'tag': 'c', 'hops': ['ghost', 'vpn-1'], 'order': 1},
        ],
      });
      expect(_hops(r, 'c'), const [NodeLink(tag: 'ghost'), NodeLink(tag: 'vpn-1')]);
      expect(r.warnings, [
        allOf(contains('position 1 "ghost" matches no node'),
            contains('kept as a root link')),
      ]);
    });
  });

  group('члены папок autogroup:// → kind: auto', () {
    const alpha = 'vless://c3c3c3c3-0000-4000-8000-000000000070@198.51.100.70:443'
        '?type=tcp&security=tls#Alpha';
    const jump = 'trojan://pass-71@198.51.100.71:443?security=tls#Jump';
    const auto = 'autogroup://?members='
        'vless%7C198.51.100.70%7C443%7Cc3c3c3c3-0000-4000-8000-000000000070'
        '%2Ctrojan%7C198.51.100.71%7C443%7Cpass-71'
        '&interval=3m#EF%20Auto';

    AutoSelectSpec groupOf(StorageMigrationResult r) =>
        (_list(r, 'f') as FolderServers)
            .members
            .map((m) => m.node)
            .whereType<AutoSelectSpec>()
            .single;

    test('составные ключи → пары по узлам той же папки', () {
      final r = _migrate({
        'server_lists': [
          _folderV0('f', '', [
            {'raw': alpha, 'enabled': true},
            {'raw': jump, 'enabled': true},
            {'raw': auto, 'enabled': true},
          ]),
        ],
      });
      expect(r.warnings, isEmpty);
      final g = groupOf(r);
      expect(g.tag, 'EF Auto');
      expect(g.params.interval, '3m');
      expect((g.membership as ExplicitMembers).members, const [
        NodeLink(folderId: 'f', tag: 'Alpha'),
        NodeLink(folderId: 'f', tag: 'Jump'),
      ]);
      final record = ((_sources(r).single['nodes'] as List).last as Map);
      expect(record['kind'], 'auto');
      expect((record['group'] as Map)['members'], [
        {'folder_id': 'f', 'tag': 'Alpha'},
        {'folder_id': 'f', 'tag': 'Jump'},
      ]);
    });

    test('неоднозначный ключ — член снят с предупреждением; режим правила — '
        'как есть в group.members_rule', () {
      final r = _migrate({
        'server_lists': [
          _folderV0('f', '', [
            {'raw': alpha, 'enabled': true},
            {'raw': alpha.replaceAll('#Alpha', '#Alpha copy'), 'enabled': true},
            {'raw': auto, 'enabled': true},
            {'raw': 'autogroup://?include=DE&exclude=slow#Rule', 'enabled': true},
          ]),
        ],
      });
      final folder = _list(r, 'f') as FolderServers;
      final groups = [
        for (final m in folder.members)
          if (m.node case final AutoSelectSpec g) g,
      ];
      expect((groups[0].membership as ExplicitMembers).members, isEmpty);
      expect(r.warnings, [
        contains('member key "vless|198.51.100.70|443|'
            'c3c3c3c3-0000-4000-8000-000000000070" matches 2 nodes, dropped'),
        contains('member key "trojan|198.51.100.71|443|pass-71" matches no '
            'node, dropped'),
      ]);
      expect(
          groups[1].membership,
          isA<RuleMembers>()
              .having((m) => m.include, 'include', 'DE')
              .having((m) => m.exclude, 'exclude', 'slow'));
      final ruleRecord = ((_sources(r).single['nodes'] as List).last as Map);
      expect((ruleRecord['group'] as Map)['members_rule'],
          {'include': 'DE', 'exclude': 'slow'});
      expect(ruleRecord.containsKey('members_rule'), isFalse,
          reason: 'поле стороны LxBox лежит в group (контракт 1.0.1)');
    });

    test('документ формы 1.0 ранней сборки с autogroup:// мигрирует на месте',
        () {
      final r = migrateStorageDoc({
        'storage_version': 1,
        'sources': [
          {
            'kind': 'folder',
            'id': 'f',
            'name': 'F',
            'enabled': true,
            'nodes': [
              {'kind': 'server', 'enabled': true, 'origin': {'kind': 'uri', 'raw': alpha}},
              {'kind': 'unsupported', 'enabled': true, 'origin': {'kind': 'uri', 'raw': auto}},
            ],
          },
        ],
      });
      expect(r.migrated, isTrue);
      final g = groupOf(r);
      expect((g.membership as ExplicitMembers).members,
          const [NodeLink(folderId: 'f', tag: 'Alpha')]);
      expect(r.warnings.single, contains('matches no node, dropped'));
    });
  });
}
