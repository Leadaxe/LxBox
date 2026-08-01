import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/emit_context.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';
import 'package:lxbox/services/builder/server_list_build.dart';

/// §322 — узел автовыбора внутри папки: хранится обычным членом
/// (`autogroup://` в `raw`), а на билде превращается в `urltest` по членам
/// ЭТОЙ же папки.
class _FakeCtx implements EmitContext {
  _FakeCtx({this.passiveCheck = false});

  /// §272/§322 — глобальная настройка приложения, доходит до групп через ctx.
  @override
  final bool passiveCheck;

  final entries = <SingboxEntry>[];
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

  FolderServers folder(List<String> raws, {bool enabled = true}) =>
      FolderServers(
        id: 'f1',
        name: 'F',
        enabled: enabled,
        tagPrefix: 'F:',
        detourPolicy: const DetourPolicy(),
        members: [for (final r in raws) FolderMember(raw: r)],
      );

  List<Map<String, dynamic>> urltests(_FakeCtx c) => [
        for (final e in c.entries)
          if (e.map['type'] == 'urltest') e.map,
      ];

  group('эмиссия из папки', () {
    test('правило отбирает членов той же папки', () {
      final auto = AutoSelectSpec(
        id: 'a',
        tag: 'auto',
        label: 'Мой авто',
        membership: const RuleMembers(include: 'DE|NL'),
      );
      final f = folder([
        vless('u1', '1.1.1.1', 'DE-1'),
        vless('u2', '2.2.2.2', 'NL-1'),
        vless('u3', '3.3.3.3', 'US-1'),
        auto.toUri(),
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
        tag: 'auto',
        label: 'A',
        membership: const RuleMembers(include: 'EU', exclude: 'slow'),
      );
      final ctx = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'EU-fast'),
        vless('u2', '2.2.2.2', 'EU-slow'),
        auto.toUri(),
      ]).build(ctx);
      expect(urltests(ctx).single['outbounds'], ['F: EU-fast']);
    });

    test('пустое правило = все члены папки', () {
      final ctx = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'A'),
        vless('u2', '2.2.2.2', 'B'),
        AutoSelectSpec(id: 'a', tag: 'auto', label: 'All').toUri(),
      ]).build(ctx);
      expect(urltests(ctx).single['outbounds'], ['F: A', 'F: B']);
    });

    test('явный список берёт по идентичности, а не по имени', () {
      final auto = AutoSelectSpec(
        id: 'a',
        tag: 'auto',
        label: 'A',
        membership: const ExplicitMembers(['vless|2.2.2.2|443|u2']),
      );
      final ctx = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'A'),
        vless('u2', '2.2.2.2', 'B'),
        auto.toUri(),
      ]).build(ctx);
      expect(urltests(ctx).single['outbounds'], ['F: B']);
    });

    test('пустой пул → группа НЕ эмитится (пустой urltest роняет ядро)', () {
      final auto = AutoSelectSpec(
        id: 'a',
        tag: 'auto',
        label: 'A',
        membership: const RuleMembers(include: 'НЕТ-ТАКИХ'),
      );
      final ctx = _FakeCtx();
      folder([vless('u1', '1.1.1.1', 'A'), auto.toUri()]).build(ctx);
      expect(urltests(ctx), isEmpty);
      // Сами серверы при этом на месте.
      expect(ctx.entries, hasLength(1));
    });

    test('группа попадает в selector, но не в ✨auto', () {
      final ctx = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'A'),
        AutoSelectSpec(id: 'a', tag: 'auto', label: 'G').toUri(),
      ]).build(ctx);
      expect(ctx.selectorTags, contains('F: G'));
      // urltest внутри urltest — вложенность без пользы.
      expect(ctx.autoTags, isNot(contains('F: G')));
    });

    test('группа не берёт в пул другую группу', () {
      final ctx = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'A'),
        AutoSelectSpec(id: 'g1', tag: 'auto', label: 'G1').toUri(),
        AutoSelectSpec(id: 'g2', tag: 'auto2', label: 'G2').toUri(),
      ]).build(ctx);
      for (final u in urltests(ctx)) {
        expect(u['outbounds'], ['F: A']);
      }
    });

    test('§272 — passive_check из глобальных настроек', () {
      final on = _FakeCtx(passiveCheck: true);
      folder([
        vless('u1', '1.1.1.1', 'A'),
        AutoSelectSpec(id: 'a', tag: 'auto', label: 'G').toUri(),
      ]).build(on);
      expect(urltests(on).single['passive_check'], isTrue);

      // Выключено → ключа нет вовсе (omitempty = апстрим-поведение).
      final off = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'A'),
        AutoSelectSpec(id: 'a', tag: 'auto', label: 'G').toUri(),
      ]).build(off);
      expect(urltests(off).single.containsKey('passive_check'), isFalse);
    });

    test('выключенная папка не эмитит ничего', () {
      final ctx = _FakeCtx();
      folder([
        vless('u1', '1.1.1.1', 'A'),
        AutoSelectSpec(id: 'a', tag: 'auto', label: 'G').toUri(),
      ], enabled: false)
          .build(ctx);
      expect(ctx.entries, isEmpty);
    });
  });

  group('хранение', () {
    test('переживает persist round-trip папки', () {
      final auto = AutoSelectSpec(
        id: 'a',
        tag: 'auto',
        label: 'Мой авто',
        membership: const RuleMembers(include: '🇩🇪|🇳🇱'),
      );
      final m = FolderMember(raw: auto.toUri());
      expect(m.node, isA<AutoSelectSpec>());

      final back = FolderMember.fromJson(m.toJson());
      final n = back.node;
      expect(n, isA<AutoSelectSpec>());
      expect(n!.label, 'Мой авто');
      expect((n as AutoSelectSpec).membership,
          isA<RuleMembers>().having((r) => r.include, 'include', '🇩🇪|🇳🇱'));
    });
  });
}
