import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/codec/auto_group_record.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/node_settings/auto_group_source.dart';

// §686 — Source auto-узла папки: запись `kind: auto` → текст → разбор → та
// же запись; Save отказывает без записи на битом тексте, чужом `kind` и
// незнакомых ключах; JSON-превью группы-правила — строка вместо `[]`.

const _f = 'f1';
const _a = NodeLink(folderId: _f, tag: 'A');
const _b = NodeLink(folderId: _f, tag: 'B');

const _warn = [StoredWarning(code: 'group_member_missing')];

AutoSelectSpec _group(AutoSelectMembership m, {String badge = kDefaultPoolBadge}) =>
    AutoSelectSpec(
      id: 'g1',
      tag: 'Fast',
      label: 'Fast',
      membership: m,
      poolBadge: badge,
      params: const AutoSelectParams(mode: UrltestMode.roundRobin, pool: 3),
    );

void main() {
  final cases = <String, AutoSelectSpec>{
    'All': _group(const RuleMembers()),
    'Rule': _group(const RuleMembers(include: '^D', exclude: 'Xcu'),
        badge: r'[A-Z]{2}'),
    'Pick': _group(const ExplicitMembers([_a, _b]), badge: ''),
  };

  for (final MapEntry(key: name, value: group) in cases.entries) {
    test('$name: запись → Source → разбор → та же запись', () {
      final member =
          FolderMember.auto(group, enabled: false, warnings: _warn);
      final record = autoGroupMemberToRecord(member, group, _f);
      final text = autoGroupSourceText(member, group, _f);
      expect(text, contains('\n'), reason: 'отформатированный JSON');

      final back = autoGroupMemberFromRecord(
          jsonDecode(text) as Map<String, dynamic>,
          folderId: _f,
          where: 'Source');
      final g = back.member.node as AutoSelectSpec;
      expect(autoGroupMemberToRecord(back.member, g, _f), record);

      final parsed = parseAutoGroupSource(text, _f, group);
      expect(parsed, isA<AutoGroupSourceReady>());
      final ready = parsed as AutoGroupSourceReady;
      expect(ready.group.sameGroupAs(group), isTrue);
      expect(ready.group.id, group.id, reason: 'id записи не несёт');
      expect(ready.enabled, isFalse);
    });
  }

  group('Save: отказ без записи', () {
    final group = cases['All']!;

    test('не JSON', () {
      expect(parseAutoGroupSource('{"kind": "auto",', _f, group),
          isA<AutoGroupSourceRejected>());
    });

    test('не объект', () {
      expect(parseAutoGroupSource('[1, 2]', _f, group),
          isA<AutoGroupSourceRejected>());
    });

    test('kind не auto', () {
      final r = parseAutoGroupSource(
          '{"kind": "json", "tag": "Fast", "group": {}}', _f, group);
      expect(r, isA<AutoGroupSourceRejected>());
      expect((r as AutoGroupSourceRejected).message, contains('kind'));
    });

    test('незнакомые ключи — путями', () {
      final r = parseAutoGroupSource(
          '{"kind": "auto", "tag": "Fast", "fold": 1, '
          '"group": {"group_type": "urltest", "extra": true}}',
          _f,
          group);
      expect(r, isA<AutoGroupSourceRejected>());
      final msg = (r as AutoGroupSourceRejected).message;
      expect(msg, contains('fold'));
      expect(msg, contains('group.extra'));
    });
  });

  test('правка формы меняет tag и group, прочие ключи текста остаются', () {
    final group = cases['All']!;
    final member = FolderMember.auto(group);
    const source = '{"kind": "auto", "tag": "Fast", "enabled": false, '
        '"group": {"group_type": "urltest"}}';
    final next = autoGroupSourceWith(source, member,
        group.copyWith(tag: 'Slow', label: 'Slow'), _f);
    final j = jsonDecode(next) as Map<String, dynamic>;
    expect(j['tag'], 'Slow');
    expect(j['enabled'], isFalse, reason: 'enabled текста, не члена');
    expect((j['group'] as Map)['members_rule'], isNotNull);
  });

  test('форма из Source: битый текст — null, id прежний', () {
    final group = cases['Pick']!;
    expect(autoGroupFromSourceText('{oops', _f, group), isNull);
    final text = autoGroupSourceText(FolderMember.auto(group), group, _f);
    final g = autoGroupFromSourceText(text, _f, group)!;
    expect(g.id, group.id);
    expect(g.sameGroupAs(group), isTrue);
  });

  test('JSON: у группы-правила строка вместо состава, у Pick — теги', () {
    expect(autoGroupJsonPreview(cases['Rule']!)['outbounds'], isA<String>());
    expect(autoGroupJsonPreview(cases['Pick']!)['outbounds'], ['A', 'B']);
  });
}
