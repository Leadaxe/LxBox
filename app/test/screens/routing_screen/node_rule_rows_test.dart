import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/node_sections.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/routing_screen/node_rule_rows.dart';

/// §435 — строки правил узлов на общей оси экрана Routing (чистая логика:
/// сбор из источников, объединённый порядок, drag через `placeRuleAfter`,
/// разнесение изменений по владельцам).
void main() {
  TailscaleSpec ts(String tag) => TailscaleSpec(
        id: 'ts-$tag',
        tag: tag,
        label: tag,
        body: const {'auth_key': 'tskey'},
      );

  CustomRuleInline rule(String name,
          {String id = '', int? num, bool enabled = true, String outbound = '@self'}) =>
      CustomRuleInline(
        id: id.isEmpty ? null : id,
        name: name,
        enabled: enabled,
        orderNum: num,
        ipCidrs: const ['100.64.0.0/10'],
        outbound: outbound,
      );

  UserServer user(
    NodeSpec node, {
    NodeSections? sections,
    bool enabled = true,
    String prefix = '',
    String id = '',
  }) =>
      UserServer(
        id: id.isEmpty ? 'u-${node.tag}' : id,
        name: '',
        enabled: enabled,
        tagPrefix: prefix,
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.manual,
        createdAt: DateTime.utc(2026, 9, 14),
        rawBody: node.toUri(),
        sections: sections,
        nodes: [node],
      );

  FolderMember member(NodeSpec node,
          {NodeSections? sections, bool enabled = true}) =>
      FolderMember(
        raw: node.toUri(),
        node: node,
        enabled: enabled,
        sections: sections,
      );

  FolderServers folder(List<FolderMember> members,
          {bool enabled = true, String prefix = '', String id = 'f-1'}) =>
      FolderServers(
        id: id,
        name: 'folder',
        enabled: enabled,
        tagPrefix: prefix,
        detourPolicy: DetourPolicy.defaults,
        members: members,
        createdAt: DateTime.utc(2026, 9, 14),
      );

  group('collectNodeRules', () {
    test('UserServer и член папки дают строки; подписка и узел без ноды — нет',
        () {
      final sub = SubscriptionServers(
        id: 's-1',
        name: 'sub',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
      );
      final noNode = UserServer(
        id: 'u-broken',
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.manual,
        createdAt: DateTime.utc(2026, 9, 14),
        rawBody: '',
        sections: NodeSections(rules: [rule('@{self} net')]),
      );
      final lists = <ServerList>[
        sub,
        user(ts('home'), sections: NodeSections(rules: [rule('@{self} net')])),
        noNode,
        folder([
          member(ts('work'), sections: NodeSections(rules: [rule('@{self} lan')])),
          FolderMember(raw: 'garbage', sections: NodeSections(rules: [rule('x')])),
        ], prefix: '🇩🇪'),
      ];

      final refs = collectNodeRules(lists);

      expect(refs.map((r) => r.finalTag), ['home', '🇩🇪 work']);
      expect(refs[0].entryIndex, 1);
      expect(refs[0].memberIndex, isNull);
      expect(refs[0].sourceId, 'u-home');
      expect(refs[1].entryIndex, 3);
      expect(refs[1].memberIndex, 0);
      expect(refs[1].sourceId, 'f-1');
      expect(refs[1].ruleIndex, 0);
    });

    test('подстановка @self только в displayRule; хранимая запись с плейсхолдером',
        () {
      final r = rule('@{self} net');
      final refs = collectNodeRules([
        user(ts('home'), sections: NodeSections(rules: [r]), prefix: '🏠'),
      ]);

      final ref = refs.single;
      expect(identical(ref.rule, r), isTrue);
      expect(ref.rule.name, '@{self} net');
      expect(ref.rule.outbound, '@self');
      expect(ref.displayRule.name, '🏠 home net');
      expect(ref.displayRule.outbound, '🏠 home');
      expect(ref.displayRule.id, r.id);
      expect(ref.rowKey, 'node:u-home:null:${r.id}');
    });

    test('без num — ось 945; секции без правил (только DNS) строк не дают', () {
      final refs = collectNodeRules([
        user(ts('a'), sections: NodeSections(rules: [rule('x'), rule('y', num: 1005)])),
        user(ts('b'), sections: NodeSections.fromJson({
          'dns': {
            'servers': [
              {
                'kind': 'user',
                'tag': '@{self}-dns',
                'body': {'type': 'tailscale', 'endpoint': '@self'},
              }
            ],
          },
        })),
      ]);

      expect(refs.length, 2);
      expect(refs[0].axisNum, kNodeRuleDefaultNum);
      expect(refs[1].axisNum, 1005);
      expect(refs.every((r) => r.finalTag == 'a'), isTrue);
    });

    test('выключенный узел, выключенный член и выключенная папка — dimmed', () {
      final refs = collectNodeRules([
        user(ts('off'), sections: NodeSections(rules: [rule('x')]), enabled: false),
        folder([
          member(ts('m-off'), sections: NodeSections(rules: [rule('x')]), enabled: false),
          member(ts('m-on'), sections: NodeSections(rules: [rule('x')])),
        ]),
        folder([
          member(ts('in-off-folder'), sections: NodeSections(rules: [rule('x')])),
        ], enabled: false, id: 'f-2'),
      ]);

      expect(
        {for (final r in refs) r.finalTag: r.nodeDisabled},
        {'off': true, 'm-off': true, 'm-on': false, 'in-off-folder': true},
      );
    });
  });

  group('buildRuleRows', () {
    test('общая ось: узловое без num встаёт между 0 и 950, при равенстве корневое раньше',
        () {
      final head = CustomRulePreset(name: 'tp', presetId: 'traffic-processing', orderNum: 0);
      final private = CustomRulePreset(name: 'priv', presetId: 'private-ips', orderNum: 950);
      final userRule = rule('user', num: 1000, outbound: 'vpn-1');
      final tie = rule('tie', num: 945, outbound: 'vpn-1');
      final refs = collectNodeRules([
        user(ts('n'), sections: NodeSections(rules: [rule('n-default'), rule('n-late', num: 1001)])),
      ]);

      final rows = buildRuleRows([head, private, userRule, tie], refs);

      expect(rows.map((r) => r.rule.name), [
        'tp', // 0
        'tie', // 945 корневое — раньше узлового при равенстве
        'n-default', // 945 узловое
        'priv', // 950
        'user', // 1000
        'n-late', // 1001
      ]);
      expect(rows[0], isA<RootRuleRow>().having((r) => r.index, 'index', 0));
      expect(rows[1], isA<RootRuleRow>().having((r) => r.index, 'index', 3));
      expect(rows[2], isA<NodeRuleRow>());
      expect(rows[2].rowKey, refs[0].rowKey);
      expect(rows[4].rowKey, userRule.id);
    });

    test('без узловых — порядок корневых как sortRulesByNum (стабильно)', () {
      final a = rule('a', num: 1000);
      final b = rule('b', num: 1000);
      final c = rule('c'); // null → kDefaultRuleNum = 1000
      final rows = buildRuleRows([c, a, b], const []);
      expect(rows.map((r) => r.rule.name), ['c', 'a', 'b']);
      expect(kDefaultRuleNum, 1000);
    });
  });

  group('applyRuleDrag', () {
    bool sortableRoot(CustomRule r) => r.presetId != 'traffic-processing';

    test('узловое правило под корневое: num узла меняется, корневые не тронуты',
        () {
      final head = CustomRulePreset(name: 'tp', presetId: 'traffic-processing', orderNum: 0);
      final a = rule('a', num: 1000, outbound: 'vpn-1');
      final b = rule('b', num: 1010, outbound: 'vpn-1');
      final nodeRule = rule('n'); // 945
      final refs = collectNodeRules([
        user(ts('n'), sections: NodeSections(rules: [nodeRule])),
      ]);
      final rows = buildRuleRows([head, a, b], refs);
      expect(rows.map((r) => r.rule.name), ['tp', 'n', 'a', 'b']);

      // Бросаем «n» (строка 1) на место после «a»: newIndex в списке без
      // moved — [tp, a, b] → индекс 2 = «за a».
      final result = applyRuleDrag(rows, 1, 2, isRootSortable: sortableRoot);

      expect(result.rootChanged, isFalse);
      expect(result.nodeUpdates.single.ref.rule, same(nodeRule));
      expect(result.nodeUpdates.single.orderNum, 1001);
      expect(nodeRule.orderNum, 1001); // мутация на месте, как у §370
      expect(a.orderNum, 1000);
      expect(b.orderNum, 1010);
      // Пересобранный порядок отражает ось.
      expect(buildRuleRows([head, a, b], refs).map((r) => r.rule.name),
          ['tp', 'a', 'n', 'b']);
    });

    test('корневое под узловое: rootChanged, узловые не тронуты', () {
      final a = rule('a', num: 1000, outbound: 'vpn-1');
      final nodeRule = rule('n', num: 1010);
      final refs = collectNodeRules([
        user(ts('n'), sections: NodeSections(rules: [nodeRule])),
      ]);
      final rows = buildRuleRows([a], refs); // [a, n]

      final result = applyRuleDrag(rows, 0, 1, isRootSortable: sortableRoot);

      expect(result.rootChanged, isTrue);
      expect(result.nodeUpdates, isEmpty);
      expect(a.orderNum, 1011);
      expect(nodeRule.orderNum, 1010);
    });

    test('ленивый сдвиг задевает соседей обоих видов — обе стороны в результате',
        () {
      final a = rule('a', num: 1000, outbound: 'vpn-1');
      final b = rule('b', num: 1001, outbound: 'vpn-1'); // сплошной блок 1001..1002
      final nodeRule = rule('n', num: 1002);
      final moved = rule('m', num: 1050, outbound: 'vpn-1');
      final refs = collectNodeRules([
        user(ts('n'), sections: NodeSections(rules: [nodeRule])),
      ]);
      final rows = buildRuleRows([a, b, moved], refs); // [a, b, n, m]

      // «m» (строка 3) за «a»: список без m — [a, b, n] → newIndex 1.
      final result = applyRuleDrag(rows, 3, 1, isRootSortable: sortableRoot);

      expect(moved.orderNum, 1001);
      expect(b.orderNum, 1002, reason: 'сдвинут блоком');
      expect(nodeRule.orderNum, 1003, reason: 'сдвинут блоком');
      expect(a.orderNum, 1000);
      expect(result.rootChanged, isTrue);
      expect(result.nodeUpdates.single.orderNum, 1003);
    });

    test('несортируемое корневое не двигается; за границы — пусто', () {
      final head = CustomRulePreset(name: 'tp', presetId: 'traffic-processing', orderNum: 0);
      final nodeRule = rule('n');
      final refs = collectNodeRules([
        user(ts('n'), sections: NodeSections(rules: [nodeRule])),
      ]);
      final rows = buildRuleRows([head], refs);

      expect(applyRuleDrag(rows, 0, 1, isRootSortable: sortableRoot).isEmpty, isTrue);
      expect(head.orderNum, 0);
      expect(applyRuleDrag(rows, 5, 0, isRootSortable: sortableRoot).isEmpty, isTrue);
      expect(applyRuleDrag(rows, 1, 7, isRootSortable: sortableRoot).isEmpty, isTrue);
    });

    test('узловое в начало — старт пользовательской зоны (как у корневых)', () {
      final a = rule('a', num: 1000, outbound: 'vpn-1');
      final nodeRule = rule('n', num: 1020);
      final refs = collectNodeRules([
        user(ts('n'), sections: NodeSections(rules: [nodeRule])),
      ]);
      final rows = buildRuleRows([a], refs); // [a, n]

      final result = applyRuleDrag(rows, 1, 0, isRootSortable: sortableRoot);

      expect(nodeRule.orderNum, kUserRuleNumStart);
      expect(a.orderNum, 1001, reason: '1000 занят — сдвиг');
      expect(result.rootChanged, isTrue);
      expect(result.nodeUpdates.single.orderNum, kUserRuleNumStart);
    });
  });

  group('applyNodeRuleUpdates / groupNodeRuleUpdates / sectionsOfOwner', () {
    test('enabled — через withEnabled (новый объект, id/num сохранены); num — на месте',
        () {
      final r0 = rule('r0', num: 945);
      final r1 = rule('r1', num: 1005);
      final sections = NodeSections.fromJson({
        'rules': [
          for (final r in [r0, r1])
            {
              'kind': 'inline',
              'id': r.id,
              'name': r.name,
              'enabled': true,
              'num': r.orderNum,
              'body': {'ip_cidr': ['100.64.0.0/10'], 'outbound': '@self'},
            },
        ],
        'dns': {
          'servers': [
            {
              'kind': 'user',
              'tag': '@{self}-dns',
              'body': {'type': 'tailscale', 'endpoint': '@self'},
            }
          ],
        },
      })!;
      final refs = collectNodeRules([user(ts('n'), sections: sections)]);

      final next = applyNodeRuleUpdates(sections, [
        NodeRuleUpdate(ref: refs[0], enabled: false),
        NodeRuleUpdate(ref: refs[1], orderNum: 1042),
      ]);

      expect(next.rules[0].enabled, isFalse);
      expect(next.rules[0].id, r0.id);
      expect(next.rules[0].orderNum, 945);
      expect(identical(next.rules[0], sections.rules[0]), isFalse);
      expect(next.rules[1].orderNum, 1042);
      expect(identical(next.rules[1], sections.rules[1]), isTrue);
      expect(next.dnsServers.single.tag, '@{self}-dns');
      // Исходный объект секций не пересобран — правило 0 в нём как было.
      expect(sections.rules[0].enabled, isTrue);
    });

    test('устаревшая ссылка (другой id по индексу) пропускается молча', () {
      final sections = NodeSections(rules: [rule('a', num: 945)]);
      final stale = collectNodeRules([
        user(ts('n'), sections: NodeSections(rules: [rule('other', num: 945)])),
      ]).single;

      final next = applyNodeRuleUpdates(sections, [
        NodeRuleUpdate(ref: stale, enabled: false, orderNum: 1),
      ]);

      expect(next.rules.single.enabled, isTrue);
      expect(next.rules.single.orderNum, 945);
    });

    test('группировка по владельцу: одиночный узел и член папки — раздельно',
        () {
      final refs = collectNodeRules([
        user(ts('u'), sections: NodeSections(rules: [rule('a'), rule('b')])),
        folder([
          member(ts('m0'), sections: NodeSections(rules: [rule('c')])),
          member(ts('m1'), sections: NodeSections(rules: [rule('d')])),
        ]),
      ]);

      final grouped = groupNodeRuleUpdates([
        for (final r in refs) NodeRuleUpdate(ref: r, orderNum: 1000),
      ]);

      expect(grouped.keys.toList(), [
        (entryIndex: 0, memberIndex: null),
        (entryIndex: 1, memberIndex: 0),
        (entryIndex: 1, memberIndex: 1),
      ]);
      expect(grouped[(entryIndex: 0, memberIndex: null)]!.length, 2);
    });

    test('sectionsOfOwner: по индексу и id; уехавший владелец → null', () {
      final s = NodeSections(rules: [rule('a')]);
      final lists = <ServerList>[
        user(ts('u'), sections: s),
        folder([member(ts('m'), sections: s)]),
      ];

      expect(
        sectionsOfOwner(lists, (entryIndex: 0, memberIndex: null), sourceId: 'u-u'),
        same(s),
      );
      expect(
        sectionsOfOwner(lists, (entryIndex: 1, memberIndex: 0), sourceId: 'f-1'),
        same(s),
      );
      expect(
        sectionsOfOwner(lists, (entryIndex: 0, memberIndex: null), sourceId: 'gone'),
        isNull,
      );
      expect(
        sectionsOfOwner(lists, (entryIndex: 1, memberIndex: 5), sourceId: 'f-1'),
        isNull,
      );
      expect(
        sectionsOfOwner(lists, (entryIndex: 1, memberIndex: null), sourceId: 'f-1'),
        isNull,
        reason: 'папка без memberIndex — не владелец',
      );
      expect(
        sectionsOfOwner(lists, (entryIndex: 9, memberIndex: null), sourceId: 'u-u'),
        isNull,
      );
    });
  });

  group('nodeRulesSignature', () {
    test('меняется на enabled/num/тег/приглушение, стабилен иначе', () {
      final r = rule('a', num: 945);
      List<NodeRuleRef> refsOf({bool enabled = true, String prefix = ''}) =>
          collectNodeRules([
            user(ts('n'), sections: NodeSections(rules: [r]), enabled: enabled, prefix: prefix),
          ]);

      final base = nodeRulesSignature(refsOf());
      expect(nodeRulesSignature(refsOf()), base);
      expect(nodeRulesSignature(refsOf(enabled: false)), isNot(base));
      expect(nodeRulesSignature(refsOf(prefix: '🏠')), isNot(base));
      r.orderNum = 1000;
      expect(nodeRulesSignature(refsOf()), isNot(base));
      expect(nodeRulesSignature(const []), '');
    });
  });
}
