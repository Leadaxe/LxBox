import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/emit_context.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';
import 'package:lxbox/services/builder/server_list_build.dart';

/// §322 — узел автовыбора внутри папки: хранится членом `kind: auto`
/// (§439 N2, `codec/auto_group_record.dart`), а на билде превращается в
/// `urltest` по членам ЭТОЙ же папки.
class _FakeCtx extends EmitContext {
  _FakeCtx({this.passiveCheck = false});

  /// §272/§322 — глобальная настройка приложения, доходит до групп через ctx.
  @override
  final bool passiveCheck;

  final entries = <SingboxEntry>[];
  final warnings = <String>[];
  final selectorTags = <String>[];
  final autoTags = <String>[];
  final _seen = <String>{};

  @override
  TemplateVars get vars => TemplateVars.empty;

  @override
  String allocateTag(String baseTag) {
    var t = baseTag;
    var i = 1;
    while (!_seen.add(t)) {
      t = '$baseTag-${i++}';
    }
    return t;
  }

  @override
  void addEntry(SingboxEntry entry) => entries.add(entry);

  @override
  void warn(String line) => warnings.add(line);

  @override
  void addToSelectorTagList(SingboxEntry entry) => selectorTags.add(entry.tag);

  @override
  void addToAutoList(SingboxEntry entry) => autoTags.add(entry.tag);

  @override
  final RuleSetRegistry ruleSets =
      RuleSetRegistry(initialRuleSets: const [], initialRules: const []);
}

void main() {
  String vless(String uuid, String ip, String name) =>
      'vless://$uuid@$ip:443?type=tcp&security=none#$name';

  /// Члены папки: строка — текст узла, [AutoSelectSpec] — член `kind: auto`.
  FolderServers folder(List<Object> members, {bool enabled = true}) =>
      FolderServers(
        id: 'f1',
        name: 'F',
        enabled: enabled,
        tagPrefix: 'F:',
        detourPolicy: const DetourPolicy(),
        members: [
          for (final m in members)
            m is AutoSelectSpec
                ? FolderMember.auto(m)
                : FolderMember(raw: m as String),
        ],
      );

  List<Map<String, dynamic>> urltests(_FakeCtx c) => [
        for (final e in c.entries)
          if (e.map['type'] == 'urltest') e.map,
      ];

  group('эмиссия из папки', () {
    test('правило отбирает членов той же папки', () {
      final auto = AutoSelectSpec(
        id: 'a',
        tag: 'Мой авто',
        label: 'Мой авто',
        membership: const RuleMembers(include: 'DE|NL'),
      );
      final f = folder([
        vless('u1', '1.1.1.1', 'DE-1'),
        vless('u2', '2.2.2.2', 'NL-1'),
        vless('u3', '3.3.3.3', 'US-1'),
        auto,
      ]);
      final ctx = _FakeCtx();
      f.build(ctx);

      final ut = urltests(ctx);
      expect(ut, hasLength(1));
      // Теги — ИТОГОВЫЕ, с префиксом папки.
      expect(ut.single['outbounds'], ['F: DE-1', 'F: NL-1']);
      expect(ut.single['tag'], 'F: Мой авто');
    });

    test('exclude вычитает из include', () {
      final auto = AutoSelectSpec(
        id: 'a',
        tag: 'Grp',
        label: 'Grp',
        membership: const RuleMembers(include: 'EU', exclude: 'slow'),
      );
      final ctx = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'EU-fast'),
        vless('u2', '2.2.2.2', 'EU-slow'),
        auto,
      ]).build(ctx);
      expect(urltests(ctx).single['outbounds'], ['F: EU-fast']);
    });

    test('пустое правило = все члены папки', () {
      final ctx = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'A'),
        vless('u2', '2.2.2.2', 'B'),
        AutoSelectSpec(id: 'a', tag: 'All', label: 'All'),
      ]).build(ctx);
      expect(urltests(ctx).single['outbounds'], ['F: A', 'F: B']);
    });

    test('явный список — пары на сырые теги членов, итог — финальные теги',
        () {
      final auto = AutoSelectSpec(
        id: 'a',
        tag: 'Grp',
        label: 'Grp',
        membership: const ExplicitMembers([
          NodeLink(folderId: 'f1', tag: 'B'),
          // член без folder_id внутри папки — свой контейнер (NODE_LINK §5.1 № 8)
          NodeLink(tag: 'A'),
        ]),
      );
      final ctx = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'A'),
        vless('u2', '2.2.2.2', 'B'),
        auto,
      ]).build(ctx);
      // Порядок — списка, а не папки.
      expect(urltests(ctx).single['outbounds'], ['F: B', 'F: A']);
      expect(ctx.warnings, isEmpty);
    });

    test('отсутствующий член отсекается с warning, группа живёт', () {
      final auto = AutoSelectSpec(
        id: 'a',
        tag: 'Grp',
        label: 'Grp',
        membership: const ExplicitMembers([
          NodeLink(folderId: 'f1', tag: 'gone'),
          NodeLink(folderId: 'f1', tag: 'B'),
          NodeLink(folderId: 'other-folder', tag: 'A'),
        ]),
      );
      final ctx = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'A'),
        vless('u2', '2.2.2.2', 'B'),
        auto,
      ]).build(ctx);
      expect(urltests(ctx).single['outbounds'], ['F: B']);
      expect(ctx.warnings, [
        contains('member "gone" was dropped: it has no node "gone"'),
        contains('member "A" was dropped: it is not a node of this container'),
      ]);
      expect(ctx.warnings.first, startsWith('Auto node "F: Grp"'));
    });

    test('явный состав без единого члена — группа не эмитится, с warning', () {
      final auto = AutoSelectSpec(
        id: 'a',
        tag: 'Grp',
        label: 'Grp',
        membership: const ExplicitMembers([NodeLink(folderId: 'f1', tag: 'gone')]),
      );
      final ctx = _FakeCtx();
      folder([vless('u1', '1.1.1.1', 'A'), auto]).build(ctx);
      expect(urltests(ctx), isEmpty);
      expect(ctx.entries, hasLength(1));
      expect(ctx.warnings.last,
          contains('was skipped: none of its members resolved'));
    });

    test('выключенный член отсекается, как отсутствующий', () {
      final auto = AutoSelectSpec(
        id: 'a',
        tag: 'Grp',
        label: 'Grp',
        membership: const ExplicitMembers([
          NodeLink(folderId: 'f1', tag: 'A'),
          NodeLink(folderId: 'f1', tag: 'B'),
        ]),
      );
      final f = folder([
        vless('u1', '1.1.1.1', 'A'),
        vless('u2', '2.2.2.2', 'B'),
        auto,
      ]);
      final off = f.copyWith(members: [
        f.members[0].copyWith(enabled: false),
        f.members[1],
        f.members[2],
      ]);
      final ctx = _FakeCtx();
      off.build(ctx);
      expect(urltests(ctx).single['outbounds'], ['F: B']);
      expect(ctx.warnings.single, contains('member "A" was dropped'));
    });

    test('пустой пул → группа НЕ эмитится (пустой urltest роняет ядро)', () {
      final auto = AutoSelectSpec(
        id: 'a',
        tag: 'Grp',
        label: 'Grp',
        membership: const RuleMembers(include: 'НЕТ-ТАКИХ'),
      );
      final ctx = _FakeCtx();
      folder([vless('u1', '1.1.1.1', 'A'), auto]).build(ctx);
      expect(urltests(ctx), isEmpty);
      // Сами серверы при этом на месте.
      expect(ctx.entries, hasLength(1));
    });

    test('группа попадает в selector, но не в ✨auto', () {
      final ctx = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'A'),
        AutoSelectSpec(id: 'a', tag: 'G', label: 'G'),
      ]).build(ctx);
      expect(ctx.selectorTags, contains('F: G'));
      // urltest внутри urltest — вложенность без пользы.
      expect(ctx.autoTags, isNot(contains('F: G')));
    });

    test('группа не берёт в пул другую группу', () {
      final ctx = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'A'),
        AutoSelectSpec(id: 'g1', tag: 'G1', label: 'G1'),
        AutoSelectSpec(id: 'g2', tag: 'G2', label: 'G2'),
      ]).build(ctx);
      for (final u in urltests(ctx)) {
        expect(u['outbounds'], ['F: A']);
      }
    });

    test('§272 — passive_check из глобальных настроек', () {
      final on = _FakeCtx(passiveCheck: true);
      folder([
        vless('u1', '1.1.1.1', 'A'),
        AutoSelectSpec(id: 'a', tag: 'G', label: 'G'),
      ]).build(on);
      expect(urltests(on).single['passive_check'], isTrue);

      // Выключено → ключа нет вовсе (omitempty = апстрим-поведение).
      final off = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'A'),
        AutoSelectSpec(id: 'a', tag: 'G', label: 'G'),
      ]).build(off);
      expect(urltests(off).single.containsKey('passive_check'), isFalse);
    });

    test('выключенная папка не эмитит ничего', () {
      final ctx = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'A'),
        AutoSelectSpec(id: 'a', tag: 'G', label: 'G'),
      ], enabled: false)
          .build(ctx);
      expect(ctx.entries, isEmpty);
    });
  });

  group('хранение', () {
    test('переживает запись kind: auto в sources[] (правило)', () {
      final auto = AutoSelectSpec(
        id: 'a',
        tag: 'Мой авто',
        label: 'Мой авто',
        membership: const RuleMembers(include: '🇩🇪|🇳🇱'),
      );
      final folder = FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [FolderMember.auto(auto)],
      );
      final back =
          (sourceFromRecord(sourceToRecord(folder)).value! as FolderServers)
              .members
              .single;
      final n = back.node;
      expect(n, isA<AutoSelectSpec>());
      // Подпись группы — её тег: запись kind: auto отдельной подписи не несёт.
      expect(n!.tag, 'Мой авто');
      expect(n.label, 'Мой авто');
      expect((n as AutoSelectSpec).membership,
          isA<RuleMembers>().having((r) => r.include, 'include', '🇩🇪|🇳🇱'));
    });

    test('явный состав переживает запись парами, корневой член — парой папки',
        () {
      final auto = AutoSelectSpec(
        id: 'a',
        tag: 'auto',
        label: 'auto',
        membership: const ExplicitMembers([
          NodeLink(folderId: 'f1', tag: 'pa,ss%word'),
          NodeLink(tag: 'Б'),
        ]),
      );
      final folder = FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [FolderMember.auto(auto)],
      );
      final record = sourceToRecord(folder);
      expect(((record['nodes'] as List).single as Map)['group']['members'], [
        {'folder_id': 'f1', 'tag': 'pa,ss%word'},
        {'folder_id': 'f1', 'tag': 'Б'},
      ]);
      final back = (sourceFromRecord(record).value! as FolderServers)
          .members
          .single
          .node as AutoSelectSpec;
      expect((back.membership as ExplicitMembers).members, const [
        NodeLink(folderId: 'f1', tag: 'pa,ss%word'),
        NodeLink(folderId: 'f1', tag: 'Б'),
      ]);
    });
  });
}
