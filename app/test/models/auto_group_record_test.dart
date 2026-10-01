import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/codec/auto_group_record.dart';
import 'package:lxbox/models/direction.dart' show StickyHashKey, UrltestMode;
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';

// §439 N2 — кодек члена папки `kind: auto` (`codec/auto_group_record.dart`):
// круг записи, поля стороны LxBox внутри `group` (контракт 1.0.1) и терпимое
// чтение (S1 член `{tag}`, `default` строкой, `selector`, форма dev-сборок
// с полями на уровне узла).

AutoSelectSpec _spec(AutoSelectMembership membership,
        {AutoSelectParams params = const AutoSelectParams(),
        String badge = kDefaultPoolBadge}) =>
    AutoSelectSpec(
      id: 'x',
      tag: 'Best',
      label: 'Best',
      membership: membership,
      params: params,
      poolBadge: badge,
    );

Map<String, dynamic> _write(AutoSelectSpec g, {bool enabled = true}) =>
    jsonDecode(jsonEncode(autoGroupMemberToRecord(
            FolderMember.auto(g, enabled: enabled), g, 'f1')))
        as Map<String, dynamic>;

({AutoSelectSpec group, bool enabled, List<String> notes,
    List<String> unknown}) _read(Map<String, dynamic> j) {
  final notes = <String>[];
  final unknown = <String>[];
  final r = autoGroupMemberFromRecord(j,
      folderId: 'f1', where: 'F: Best', notes: notes, unknown: unknown);
  return (
    group: r.member.node! as AutoSelectSpec,
    enabled: r.member.enabled,
    notes: notes,
    unknown: unknown,
  );
}

void main() {
  group('круг записи', () {
    test('явный состав — пары, параметры и значки переживают запись', () {
      final g = _spec(
        const ExplicitMembers([
          NodeLink(folderId: 'f1', tag: 'de-1'),
          NodeLink(tag: 'de-2'),
        ]),
        params: const AutoSelectParams(
          mode: UrltestMode.roundRobin,
          url: 'https://example-1.com/204',
          interval: '2m',
          tolerance: 80,
          pool: 7,
          poolTolerance: 1500,
          stickyHash: [],
          interruptExistConnections: true,
        ),
        badge: '',
      );
      final record = _write(g, enabled: false);
      expect(record['kind'], 'auto');
      expect(record['enabled'], false);
      final group = record['group'] as Map;
      expect(group['group_type'], 'urltest');
      expect(group['members'], [
        {'folder_id': 'f1', 'tag': 'de-1'},
        {'folder_id': 'f1', 'tag': 'de-2'},
      ], reason: 'член без folder_id пишется парой своей папки');
      expect(group['pool_badge'], '', reason: 'поле стороны LxBox — в group');
      expect(record.containsKey('pool_badge'), isFalse);
      expect((group['strategy'] as Map)['sticky_hash'], ['none']);

      final back = _read(record);
      expect(back.notes, isEmpty);
      expect(back.unknown, isEmpty);
      expect(back.enabled, isFalse);
      expect(
          back.group.sameGroupAs(g.copyWith(
              membership: const ExplicitMembers([
            NodeLink(folderId: 'f1', tag: 'de-1'),
            NodeLink(folderId: 'f1', tag: 'de-2'),
          ]))),
          isTrue);
      expect(back.group.params.stickyHash, isEmpty);
    });

    test('группа по правилу — group.members_rule без members', () {
      final g = _spec(const RuleMembers(include: '^DE', exclude: 'slow'));
      final record = _write(g);
      final group = record['group'] as Map;
      expect(group.containsKey('members'), isFalse);
      expect(group['members_rule'], {'include': '^DE', 'exclude': 'slow'});
      expect(group.containsKey('pool_badge'), isFalse,
          reason: 'значок по умолчанию не пишется');
      final back = _read(record);
      expect(back.group.sameGroupAs(g), isTrue);
    });

    test('липкость по умолчанию у least_test в strategy не пишется', () {
      final strategy =
          (_write(_spec(const RuleMembers()))['group'] as Map)['strategy'] as Map;
      expect(strategy.containsKey('pool'), isFalse);
      expect(strategy.containsKey('sticky_hash'), isFalse);
      expect(
          autoSelectParamsFromStrategy({
            'mode': 'round_robin',
            'sticky_hash': ['process', 'bogus'],
          }).stickyHash,
          [StickyHashKey.fromWire('process')]);
    });
  });

  group('терпимое чтение', () {
    test('S1: член {tag} — пара своей папки', () {
      final back = _read({
        'kind': 'auto',
        'tag': 'Best',
        'group': {
          'group_type': 'urltest',
          'members': [
            {'tag': 'de-1'},
            {'folder_id': 'other', 'tag': 'x'},
            42,
          ],
        },
      });
      expect((back.group.membership as ExplicitMembers).members, const [
        NodeLink(folderId: 'f1', tag: 'de-1'),
        NodeLink(folderId: 'other', tag: 'x'),
      ]);
      expect(back.notes.single, contains('group.members[2] is not a link'));
    });

    test('§565 selector с default строкой — род selector, default — член', () {
      // Род исполняется: ни ноты о приведении, ни потери поля.
      final back = _read({
        'kind': 'auto',
        'tag': 'Pick',
        'group': {
          'group_type': 'selector',
          'default': 'de-2',
          'members': [
            {'folder_id': 'f1', 'tag': 'de-1'},
            {'folder_id': 'f1', 'tag': 'de-2'},
          ],
        },
      });
      expect(back.group.genus, 'selector');
      expect(back.notes, isEmpty, reason: 'род прочитан как записан');
      expect(back.group.manualDefault, 'de-2');
      expect((back.group.membership as ExplicitMembers).members, hasLength(2));
    });

    test('круг бэкапа: `default` уезжает и возвращается тем же именем', () {
      // Сохранение сквозным стоит ничего и возвращает полю обратимость — это и
      // есть предмет нормы `genus.round_trip.preserve_unexecuted`.
      final back = _read({
        'kind': 'auto',
        'tag': 'Pick',
        'group': {
          'group_type': 'selector',
          'default': 'de-2',
          'members': [
            {'folder_id': 'f1', 'tag': 'de-1'},
            {'folder_id': 'f1', 'tag': 'de-2'},
          ],
        },
      });
      final rec = autoGroupMemberToRecord(
        FolderMember.auto(back.group, enabled: true),
        back.group,
        'f1',
      );
      final group = rec['group'] as Map<String, dynamic>;
      // §565 — писатель пишет род как есть и `default` объектом NodeLink,
      // параметров замера у ручного рода нет.
      expect(group['group_type'], 'selector');
      expect(group['default'], {'folder_id': 'f1', 'tag': 'de-2'});
      expect(group.containsKey('strategy'), isFalse);
      final again = _read(jsonDecode(jsonEncode(rec)) as Map<String, dynamic>);
      expect(again.group.manualDefault, 'de-2');
      expect(again.group.genus, 'selector');
      expect(again.group.sameGroupAs(back.group), isTrue);
    });

    test('§565 запись без рода и urltest с default — автовыбор, поле сквозное',
        () {
      final old = _read({
        'kind': 'auto',
        'tag': 'Old',
        'group': {
          'group_type': 'urltest',
          'default': 'de-1',
          'members': [
            {'folder_id': 'f1', 'tag': 'de-1'},
          ],
        },
      });
      expect(old.group.genus, 'urltest');
      expect(old.group.manualDefault, 'de-1');
      final rec = _write(old.group);
      expect((rec['group'] as Map)['default'], 'de-1',
          reason: 'preserve_unexecuted: строкой как пришло');
      final noGenus = _read({
        'kind': 'auto',
        'tag': 'NoGenus',
        'group': <String, dynamic>{},
      });
      expect(noGenus.group.genus, 'urltest');
      expect(noGenus.notes, isEmpty);
    });

    test('поля стороны LxBox на уровне узла (dev-форма до 1.0.1) читаются '
        'молча, group сильнее', () {
      final dev = _read({
        'kind': 'auto',
        'tag': 'Rule',
        'group': {'group_type': 'urltest'},
        'members_rule': {'include': 'DE'},
        'pool_badge': 'NL',
      });
      expect(dev.unknown, isEmpty);
      expect(dev.notes, isEmpty);
      expect(dev.group.membership,
          isA<RuleMembers>().having((m) => m.include, 'include', 'DE'));
      expect(dev.group.poolBadge, 'NL');

      final both = _read({
        'kind': 'auto',
        'tag': 'Rule',
        'group': {
          'group_type': 'urltest',
          'members_rule': {'include': 'FI'},
          'pool_badge': '',
        },
        'members_rule': {'include': 'DE'},
        'pool_badge': 'NL',
      });
      expect(both.group.membership,
          isA<RuleMembers>().having((m) => m.include, 'include', 'FI'));
      expect(both.group.poolBadge, '');
    });

    test('непустой members сильнее members_rule (по схеме у группы-правила '
        'явного состава нет)', () {
      final back = _read({
        'kind': 'auto',
        'tag': 'Best',
        'group': {
          'group_type': 'urltest',
          'members': [
            {'folder_id': 'f1', 'tag': 'de-1'},
          ],
          'members_rule': {'include': 'de-'},
        },
      });
      expect((back.group.membership as ExplicitMembers).members,
          const [NodeLink(folderId: 'f1', tag: 'de-1')]);
      expect(back.notes.single, contains('group.members wins'));
    });

    test('незнакомые ключи — путями; без тега — Auto', () {
      final back = _read({
        'kind': 'auto',
        'fold': true,
        'group': {
          'group_type': 'urltest',
          'extra': 1,
          'members_rule': {'include': '', 'regex_flags': 'i'},
          'strategy': {'mode': 'least_test', 'weight': 2},
        },
      });
      expect(back.group.tag, 'Auto');
      expect(back.unknown, [
        'fold',
        'group.extra',
        'group.members_rule.regex_flags',
        'group.strategy.weight',
      ]);
    });
  });
}
