import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart' show RuleDns, RuleResolve;
import 'package:lxbox/models/rule_tree.dart';
import 'package:lxbox/services/builder/rule_tree_emit.dart';
import 'package:lxbox/services/builder/rule_tree_tags.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/contract/rule_conditions.dart';

import '../contract_paths.dart';

// §757 — тело правила как дерево: разбор, запись, старая форма, теги §6.13,
// выпуск наборов / resolve / зеркала. Корпус — rule_tree_corpus_test.dart.

late RuleConditionTable table;

RuleTreeBody? parse(
  Map<String, dynamic> body, {
  List<String> refs = const [],
}) => parseRuleTreeBody(body, table, recordRefs: refs);

Map<String, dynamic> write(RuleTreeBody b) => ruleTreeBodyToJson(b);

void main() {
  setUpAll(() async {
    await loadTestRegistry();
    table = ContractRegistry.I.ruleConditions!;
  });

  group('таблица условий', () {
    test('ключи и признаки берутся из реестра', () {
      final setKeys = {
        for (final k in table.keys)
          if (k.set) k.key,
      };
      expect(setKeys, isNotEmpty);
      expect(table.refsKey, kRuleRefsKey);
      // Условия — по order.
      final orders = [for (final c in table.conditions) c.order];
      expect(orders, [...orders]..sort());
    });

    test('неизвестные поля ключа (label, placeholder — §184) пропускаются', () {
      final t = RuleConditionTable.fromJson({
        'conditions': [
          {
            'id': 'destination',
            'keys': [
              {
                'key': 'domain',
                'field': 'list',
                'set': true,
                'dns': true,
                'label': 'Domains',
                'placeholder': 'example.com',
                'future_field': {'x': 1},
              },
            ],
          },
        ],
      });
      expect(t.key('domain')?.set, isTrue);
      expect(t.key('domain')?.dns, isTrue);
    });
  });

  group('разбор тела', () {
    test('простое правило: скаляр читается списком, цель отделена', () {
      final b = parse({
        'domain_suffix': 'a.com',
        'port': 443,
        'outbound': 'proxy',
      })!;
      final leaf = b.root as RuleLeaf;
      expect(leaf.conditions['domain_suffix'], ['a.com']);
      expect(leaf.conditions['port'], [443]);
      expect(b.target, {'outbound': 'proxy'});
      expect(ruleTreeKind(b.root), 'inline');
    });

    test('пустые значения не хранятся', () {
      final leaf =
          parse({
                'domain': <String>[],
                'ip_is_private': false,
                'inbound': ['tun-in'],
              })!.root
              as RuleLeaf;
      expect(leaf.conditions.keys, ['inbound']);
    });

    test('не дерево: ключ вне таблицы', () {
      expect(parse({'clash_mode': 'direct', 'outbound': 'x'}), isNull);
    });

    test('не дерево: refs у logical', () {
      expect(
        parse({
          'type': 'logical',
          'mode': 'or',
          'refs': ['https://a/x.srs'],
          'rules': [
            {
              'domain': ['a.com'],
            },
          ],
        }),
        isNull,
      );
    });

    test('не дерево: цель не у корня, mode вне and|or, пустые rules', () {
      expect(
        parse({
          'type': 'logical',
          'mode': 'and',
          'rules': [
            {
              'domain': ['a.com'],
              'outbound': 'x',
            },
          ],
        }),
        isNull,
      );
      expect(
        parse({
          'type': 'logical',
          'mode': 'xor',
          'rules': [
            {
              'domain': ['a.com'],
            },
          ],
        }),
        isNull,
      );
      expect(parse({'type': 'logical', 'mode': 'or', 'rules': []}), isNull);
    });

    test('не дерево: значение не той формы', () {
      expect(
        parse({
          'port': ['443'],
        }),
        isNull,
      );
      expect(parse({'ip_is_private': 'yes'}), isNull);
    });

    test('рукописный rule_set читается типизированно', () {
      final leaf =
          parse({'rule_set': 'geosite-x', 'outbound': 'x'})!.root as RuleLeaf;
      expect(leaf.ruleSet, ['geosite-x']);
    });
  });

  group('старая форма (refs на записи)', () {
    test('корень простой — refs в него', () {
      final b = parse(
        {
          'domain': ['a.com'],
          'outbound': 'x',
        },
        refs: ['https://a/1.srs'],
      )!;
      final leaf = b.root as RuleLeaf;
      expect(leaf.refs, ['https://a/1.srs']);
      expect(ruleTreeKind(b.root), 'srs');
    });

    test('корень logical — обёртка and из {refs} и тела без цели', () {
      final b = parse(
        {
          'type': 'logical',
          'mode': 'or',
          'invert': true,
          'rules': [
            {
              'domain': ['a.com'],
            },
            {
              'port': [80],
            },
          ],
          'outbound': 'x',
        },
        refs: ['https://a/1.srs'],
      )!;
      expect(write(b), {
        'type': 'logical',
        'mode': 'and',
        'rules': [
          {
            'refs': ['https://a/1.srs'],
          },
          {
            'type': 'logical',
            'mode': 'or',
            'rules': [
              {
                'domain': ['a.com'],
              },
              {
                'port': [80],
              },
            ],
            'invert': true,
          },
        ],
        'outbound': 'x',
      });
    });

    test('refs и на записи, и в дереве — главнее дерево', () {
      final b = parse(
        {
          'refs': ['https://a/tree.srs'],
          'outbound': 'x',
        },
        refs: ['https://a/record.srs'],
      )!;
      expect(ruleTreeRefs(b.root), ['https://a/tree.srs']);
    });

    test('одиночный ref записи — refs[0]; у пресета ref не ссылка', () {
      expect(legacyRecordRefs({'kind': 'srs', 'ref': 'https://a/1.srs'}), [
        'https://a/1.srs',
      ]);
      expect(legacyRecordRefs({'kind': 'preset', 'ref': 'blk'}), isEmpty);
      expect(
        legacyRecordRefs({
          'kind': 'srs',
          'refs': ['https://a/1.srs', 'https://a/2.srs'],
          'ref': 'https://a/0.srs',
        }),
        ['https://a/1.srs', 'https://a/2.srs'],
      );
    });

    test('запись → новая форма → повторное чтение даёт то же', () {
      final first = parse({
        'type': 'logical',
        'mode': 'and',
        'rules': [
          {'port': 443, 'source_ip_cidr': '10.0.0.0/8'},
          {
            'type': 'logical',
            'mode': 'or',
            'rules': [
              {
                'refs': ['https://a/1.srs'],
                'domain': ['b.com'],
              },
              {
                'process_name': ['app.exe'],
                'invert': true,
              },
            ],
          },
        ],
        'action': 'reject',
        'method': 'default',
      })!;
      final json = write(first);
      expect(json['action'], 'reject');
      expect(json['method'], 'default');
      expect(write(parse(json)!), json);
    });
  });

  group('вычисляемое по дереву', () {
    test('ссылки pre-order без повторов; refs или доменный ключ', () {
      final b = parse({
        'type': 'logical',
        'mode': 'or',
        'rules': [
          {
            'refs': ['https://a/1.srs', 'https://a/2.srs'],
          },
          {
            'refs': [' https://a/1.srs '],
            'port': [1],
          },
        ],
      })!;
      expect(ruleTreeRefs(b.root), ['https://a/1.srs', 'https://a/2.srs']);
      expect(ruleTreeHasRefsOrDomain(b.root, table), isTrue);
      expect(
        ruleTreeHasRefsOrDomain(
          parse({
            'ip_cidr': ['1.1.1.0/24'],
            'port': [1],
          })!.root,
          table,
        ),
        isFalse,
      );
      expect(
        ruleTreeHasRefsOrDomain(
          parse({
            'type': 'logical',
            'mode': 'and',
            'rules': [
              {
                'port': [1],
              },
              {
                'domain_keyword': ['x'],
              },
            ],
          })!.root,
          table,
        ),
        isTrue,
      );
    });
  });

  group('теги §6.13', () {
    List<RuleTags> assign(
      List<RuleTagInput> rules, {
      Set<String> reserved = const {},
    }) => assignRuleTags(rules, reserved: reserved, table: table);

    test('h8 — 8 hex нижнего регистра от обрезанной ссылки', () {
      final h = ruleRefHash('  https://example.com/rules/trackers.srs ');
      expect(h, '3cdcfd9d');
    });

    test('базу берёт запись без дерева (verbatim); пустое имя — unnamed', () {
      final t = assign(
        [
          const RuleTagInput(name: 'A'),
          RuleTagInput(
            name: 'A',
            root: parse({
              'domain': ['a.com'],
            })!.root,
          ),
          RuleTagInput(
            name: '',
            root: parse({
              'domain': ['b.com'],
            })!.root,
          ),
        ],
        reserved: {'A (2)'},
      );
      expect(t[0].base, 'A');
      expect(t[1].base, 'A (3)');
      expect(t[1].inlineTags, {'': 'A (3)'});
      expect(t[2].base, 'unnamed');
    });

    test('база — имя с обрезанными краями у любого вызывающего (§183 п. 5)', () {
      final t = assign([
        const RuleTagInput(name: '  Ads \t'),
        const RuleTagInput(name: 'Ads'),
        const RuleTagInput(name: ' \n '),
      ], reserved: const {});
      expect(t[0].base, 'Ads');
      expect(t[1].base, 'Ads (2)');
      expect(t[2].base, 'unnamed');
    });

    test('одна ссылка в двух узлах — один тег; коллизия h8 — 16 hex', () {
      // §757 (контракт 1.1.182) — stem `pair` совпал у двух ссылок, их h8
      // совпали (пара из corpus/rule_tree/h8_collision) — 16 hex у группы.
      const a = 'https://mirror-19526.example.com/rules/pair.srs';
      const b = 'https://mirror-99213.example.com/rules/pair.srs';
      final t = assign([
        RuleTagInput(
          name: 'P',
          root: parse({
            'type': 'logical',
            'mode': 'or',
            'rules': [
              {
                'refs': [a, b, 'https://example.com/rules/set-57516.srs'],
              },
              {
                'refs': [a],
              },
            ],
          })!.root,
        ),
      ]).single;
      expect(t.refTags, {
        a: 'P:pair-e31a3654be43599e',
        b: 'P:pair-e31a3654aec37891',
        'https://example.com/rules/set-57516.srs': 'P:set-57516',
      });
    });

    test('производный тег, совпавший с базой, разводится на себе', () {
      final t = assign([
        RuleTagInput(
          name: 'X',
          root: parse({
            'refs': ['https://a/1.srs'],
            'domain': ['a.com'],
          })!.root,
        ),
        RuleTagInput(
          name: 'X:1',
          root: parse({
            'refs': ['https://a/2.srs'],
          })!.root,
        ),
      ]);
      // Inline-набор корня — чистый `B'` (контракт 1.1.182).
      expect(t[0].refTags.values, ['X:1 (2)']);
      expect(t[0].inlineTags, {'': 'X'});
      expect(t[1].refTags.values, ['X:1:2']);
    });

    test('stem: query, percent-encoding, только последнее .srs/.json', () {
      expect(ruleRefStem('https://e.com/r/ads.srs?token=1#x'), 'ads');
      expect(ruleRefStem('https://e.com/geo.tar.srs'), 'geo.tar');
      expect(ruleRefStem('https://e.com/list.txt'), 'list.txt');
      expect(ruleRefStem('https://e.com/LIST.SRS'), 'LIST');
      expect(ruleRefStem('file:///C:/Rules/a%2Fb.srs'), 'a/b');
      expect(ruleRefStem('file:///a/My%20Set.json'), 'My Set');
      expect(ruleRefStem('https://e.com/lists/'), '');
      expect(ruleRefStem('https://e.com'), '');
      expect(ruleRefStem('https://e.com/.srs'), '');
      // Не разбирается как URL — режется вручную по `#`, `?`, `/`.
      expect(ruleRefStem('http://[bad/x/y.srs?q#f'), 'y');
    });

    test('без выбора стороны у узла без refs inline-набора нет', () {
      final t = assignRuleTags(
        [
          RuleTagInput(
            name: 'A',
            root: parse({
              'domain': ['a.com'],
            })!.root,
          ),
        ],
        reserved: const {},
        table: table,
        sideInlineSets: false,
      );
      expect(t.single.inlineTags, isEmpty);
    });
  });

  group('выпуск', () {
    RuleTreeEmitResult emit(
      RuleTreeBody b, {
      String name = 'R',
      String? Function(String)? path,
      bool side = true,
    }) {
      final tags = assignRuleTags(
        [RuleTagInput(name: name, root: b.root)],
        reserved: const {},
        table: table,
        sideInlineSets: side,
      ).single;
      return emitRuleTree(
        ruleName: name,
        body: b,
        tags: tags,
        refPath: path ?? (r) => '/f/${ruleRefHash(r)}',
        table: table,
        sideInlineSets: side,
      );
    }

    test('нет файла хоть у одной ссылки — правило не выпускается', () {
      final res = emit(
        parse({
          'refs': ['https://a/1.srs', 'https://a/2.srs'],
          'outbound': 'x',
        })!,
        path: (r) => r.endsWith('2.srs') ? null : '/f/1',
      );
      expect(res.emitted, isFalse);
      expect(res.missingRefs, ['https://a/2.srs']);
      expect(res.warnings.single, contains('"R"'));
    });

    test('формат набора по расширению ссылки', () {
      expect(ruleSetFormatOf('https://a/list.JSON?x=1'), 'source');
      expect(ruleSetFormatOf('https://a/list.srs'), 'binary');
      final res = emit(
        parse({
          'refs': ['file:///sd/l.json'],
          'outbound': 'x',
        })!,
      );
      expect(res.ruleSets.single['format'], 'source');
      expect(res.ruleSets.single['type'], 'local');
    });

    test('без выбора стороны ключи узла без refs остаются на узле', () {
      final res = emit(
        parse({
          'domain': ['a.com'],
          'outbound': 'x',
        })!,
        side: false,
      );
      expect(res.ruleSets, isEmpty);
      expect(res.routeRule, {
        'domain': ['a.com'],
        'outbound': 'x',
      });
    });

    test('пустое корневое тело не выпускается', () {
      expect(emit(parse({'outbound': 'x'})!).emitted, isFalse);
    });

    test('resolve — то же дерево и теги, action resolve у корня', () {
      final res = emit(
        parse({
          'type': 'logical',
          'mode': 'or',
          'rules': [
            {
              'refs': ['https://a/1.srs'],
            },
            {
              'port': [443],
            },
          ],
          'outbound': 'x',
        })!,
      );
      final rule = ruleTreeResolveRule(
        res.match!,
        const RuleResolve(strategy: 'ipv4_only', rewriteTtl: 60),
      );
      expect(rule['type'], 'logical');
      expect(rule['action'], 'resolve');
      expect(rule['strategy'], 'ipv4_only');
      expect(rule['rewrite_ttl'], 60);
      expect(rule.containsKey('outbound'), isFalse);
      expect((rule['rules'] as List).first, {
        'rule_set': 'R:1',
      });
    });

    test('висячий рукописный rule_set', () {
      final b = parse({
        'rule_set': ['geo', 'mine'],
        'outbound': 'x',
      })!;
      expect(ruleTreeDanglingTags(b.root, {'geo'}), {'mine'});
    });

    test('Force IPv4 над простым M — ключи рядом; без сервера пусто', () {
      final b = parse({
        'domain': ['a.com'],
        'port': [443],
        'outbound': 'x',
      })!;
      final res = emit(b, side: false);
      final m = ruleTreeMirrorMatcher(res.match!, res.inlineSets, table);
      expect(m, {
        'domain': ['a.com'],
      });
      final mirrors = ruleTreeDnsMirrors(
        ruleId: 'id',
        ruleName: 'R',
        enabled: true,
        dns: const RuleDns(forceIpv4: true),
        mirror: m,
        hasRefsOrDomain: true,
      );
      expect(mirrors.entries.single.body, {
        'domain': ['a.com'],
        'ip_version': 6,
        'action': 'predefined',
        'rcode': 'NOERROR',
      });
      expect(mirrors.entries.single.serverless, isTrue);
    });

    test('Block HTTPS без доменов и refs не выпускается', () {
      final mirrors = ruleTreeDnsMirrors(
        ruleId: 'id',
        ruleName: 'R',
        enabled: true,
        dns: const RuleDns(blockHttps: true),
        mirror: const {
          'inbound': ['tun-in'],
        },
        hasRefsOrDomain: false,
      );
      expect(mirrors.entries, isEmpty);
      expect(mirrors.emptyWithDnsOption, isFalse);
    });

    test('пустое зеркало при включённой опции', () {
      final mirrors = ruleTreeDnsMirrors(
        ruleId: 'id',
        ruleName: 'R',
        enabled: true,
        dns: const RuleDns(fixedIps: ['192.0.2.1']),
        mirror: null,
        hasRefsOrDomain: false,
      );
      expect(mirrors.entries, isEmpty);
      expect(mirrors.emptyWithDnsOption, isTrue);
      expect(
        ruleTreeDnsMirrors(
          ruleId: 'id',
          ruleName: 'R',
          enabled: true,
          dns: const RuleDns(serverTag: 'cf'),
          mirror: null,
          hasRefsOrDomain: false,
        ).emptyWithDnsOption,
        isFalse,
      );
    });

    test('двойной invert при снятии обёртки гасится', () {
      final res = emit(
        parse({
          'type': 'logical',
          'mode': 'and',
          'invert': true,
          'rules': [
            {
              'port': [1],
            },
            {
              'inbound': ['tun-in'],
              'invert': true,
            },
          ],
        })!,
        side: false,
      );
      expect(ruleTreeMirrorMatcher(res.match!, res.inlineSets, table), {
        'inbound': ['tun-in'],
      });
    });
  });
}
