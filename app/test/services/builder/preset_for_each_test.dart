import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/if_engine.dart';
import 'package:lxbox/services/builder/preset_expand.dart';
import 'package:lxbox/services/builder/preset_node_loop.dart';
import 'package:lxbox/services/template_loader.dart';

import '../../contract_paths.dart' show loadTestRegistry;

/// §578/§643 — язык шаблона: обход узлов пресета (`for_each_node` /
/// `for_each_node_do`), доступ `@node`, `#tpl`.
///
/// JSON-литерал в форму разобранного JSON: движок правит дерево на месте.
dynamic j(Object v) => jsonDecode(jsonEncode(v));

void main() {
  Map<String, dynamic> shippedTemplate() =>
      jsonDecode(File('assets/wizard_template.json').readAsStringSync())
          as Map<String, dynamic>;

  SelectableRule tailscalePreset() => SelectableRule.fromJson(
      (shippedTemplate()['selectable_rules'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((r) => r['preset_id'] == 'tailscale'));

  CustomRulePreset rule({Map<String, String> vars = const {}}) =>
      CustomRulePreset(
          name: 'Tailscale networks', presetId: 'tailscale', varsValues: vars);

  PresetNode ts(String tag, {bool skip = false, Map<String, dynamic>? extra}) =>
      PresetNode(
        tag: tag,
        body: {'type': 'tailscale', 'tag': tag, ...?extra},
        skipPresets: skip,
      );

  PresetNode vless(String tag) =>
      PresetNode(tag: tag, body: {'type': 'vless', 'tag': tag});

  group('for_each_node', () {
    test('ноль узлов — пресет пуст', () {
      final f = expandPreset(rule(), tailscalePreset(), nodes: [vless('a')]);
      expect(f.isEmpty, isTrue);
      expect(expandPreset(rule(), tailscalePreset()).isEmpty, isTrue);
    });

    test('один узел — записи из таблицы спеки', () {
      final f = expandPreset(rule(), tailscalePreset(), nodes: [ts('home-ts')]);
      expect(f.routingRules, [
        {
          'preferred_by': ['home-ts'],
          'action': 'resolve',
          'server': 'home-ts-dns',
        },
        {
          'preferred_by': ['home-ts'],
          'outbound': 'home-ts',
        },
      ]);
      expect(f.dnsServers, [
        {
          'type': 'tailscale',
          'tag': 'home-ts-dns',
          'endpoint': 'home-ts',
          'description': 'MagicDNS of the tailnet',
        },
      ]);
      expect(f.dnsRules, [
        {
          'preferred_by': ['home-ts-dns'],
          'server': 'home-ts-dns',
        },
      ]);
    });

    test('два узла — повторы подряд в порядке узлов, теги без неймспейса', () {
      final f = expandPreset(rule(), tailscalePreset(),
          nodes: [ts('home-ts'), vless('x'), ts('work-ts')]);
      expect([for (final r in f.routingRules) r['preferred_by']], [
        ['home-ts'],
        ['home-ts'],
        ['work-ts'],
        ['work-ts'],
      ]);
      expect([for (final s in f.dnsServers) s['tag']],
          ['home-ts-dns', 'work-ts-dns']);
      expect([for (final r in f.dnsRules) r['server']],
          ['home-ts-dns', 'work-ts-dns']);
      // В DNS-правиле preferred_by называет DNS-сервер, не узел.
      expect([for (final r in f.dnsRules) r['preferred_by']], [
        ['home-ts-dns'],
        ['work-ts-dns'],
      ]);
    });

    test('filter ложен (skip_presets) — узел не обслуживается', () {
      final f = expandPreset(rule(), tailscalePreset(),
          nodes: [ts('home-ts', skip: true), ts('work-ts')]);
      expect([for (final s in f.dnsServers) s['tag']], ['work-ts-dns']);
      expect(f.routingRules.every((r) => r['preferred_by'].first == 'work-ts'),
          isTrue);
    });

    test('dns_enable выключен — только правило маршрута', () {
      final f = expandPreset(rule(vars: {'dns_enable': 'false'}),
          tailscalePreset(),
          nodes: [ts('home-ts')]);
      expect(f.routingRules, [
        {
          'preferred_by': ['home-ts'],
          'outbound': 'home-ts',
        },
      ]);
      expect(f.dnsServers, isEmpty);
      expect(f.dnsRules, isEmpty);
    });

    test('#filter по полю тела; отсутствующее поле в условии — ложь', () {
      final preset = SelectableRule.fromJson({
        'preset_id': 'p',
        'for_each_node': {
          '#filter': {'@node.body.hostname': 'box'},
        },
        'rules': [
          {'preferred_by': ['@node'], 'outbound': '@node'},
        ],
      });
      final f = expandPreset(
          CustomRulePreset(name: 'p', presetId: 'p'), preset,
          nodes: [
            ts('a', extra: {'hostname': 'box'}),
            ts('b'),
            ts('c', extra: {'hostname': 'other'}),
            vless('d'),
          ]);
      expect(f.routingRules.map((r) => r['outbound']), ['a']);
    });

    test('без #filter — все узлы любого типа', () {
      final preset = SelectableRule.fromJson({
        'preset_id': 'p',
        'for_each_node': <String, dynamic>{},
        'rules': [
          {'preferred_by': ['@node'], 'outbound': '@node'},
        ],
      });
      final f = expandPreset(
          CustomRulePreset(name: 'p', presetId: 'p'), preset,
          nodes: [ts('a'), vless('b')]);
      expect(f.routingRules.map((r) => r['outbound']), ['a', 'b']);
    });
  });

  group('for_each_node_do', () {
    // §588 — гейт «правило без условий» читает списки полей-условий реестра.
    setUpAll(loadTestRegistry);

    SelectableRule collectPreset({
      Map<String, dynamic> extraVar = const {},
      Map<String, dynamic>? finals,
    }) =>
        SelectableRule.fromJson(j({
          'preset_id': 'hosts',
          'for_each_node_do': {
            '#filter': {'@node.body.server': '#notEmpty'},
            '#do': {
              '@domains': {'#append': '@node.body.server'},
            },
            '#final': ?finals,
          },
          'vars': [
            {'name': 'domains', 'type': 'text_list', ...extraVar},
          ],
          'dns_servers': [
            {'type': 'udp', 'tag': 'res', 'server': '1.1.1.1'},
          ],
          'dns_rules': [
            {'domain': '@domains', 'server': 'res'},
          ],
        }) as Map<String, dynamic>);

    PresetNode srv(String tag, String server) => PresetNode(
        tag: tag,
        body: {'type': 'vless', 'tag': tag, 'server': server});

    test('тело один раз, теги в неймспейсе пресета, запись не меняется', () {
      final cr = CustomRulePreset(
          name: 'h', presetId: 'hosts', varsValues: {'domains': 'own.example'});
      final f = expandPreset(cr, collectPreset(),
          nodes: [srv('a', 'a.example'), ts('ts'), srv('b', 'b.example')]);
      expect(f.dnsRules, [
        {
          'domain': ['own.example', 'a.example', 'b.example'],
          'server': 'hosts:res',
        },
      ]);
      expect(f.dnsServers.single['tag'], 'hosts:res');
      // Собранное не персистится: значение записи — только ввод пользователя.
      expect(cr.varsValues, {'domains': 'own.example'});
    });

    test('#final: unique → sort → limit независимо от порядка ключей', () {
      final f = expandPreset(
          CustomRulePreset(name: 'h', presetId: 'hosts'),
          collectPreset(finals: {
            '@domains': {'#limit': 2, '#sort': true, '#unique': true},
          }),
          nodes: [
            srv('z', 'z.example'),
            srv('a1', 'a.example'),
            srv('a2', 'a.example'),
            srv('m', 'm.example'),
          ]);
      expect(f.dnsRules.single['domain'], ['a.example', 'm.example']);
    });

    test('internal: значение записи игнорируется, база — default_value', () {
      final f = expandPreset(
          CustomRulePreset(
              name: 'h', presetId: 'hosts', varsValues: {'domains': 'user.x'}),
          collectPreset(extraVar: {
            'wizard_ui': 'internal',
            'default_value': 'base.example',
          }),
          nodes: [srv('a', 'a.example')]);
      expect(f.dnsRules.single['domain'], ['base.example', 'a.example']);
    });

    test('unique объявления снимает дубли ввода и собранного', () {
      final f = expandPreset(
          CustomRulePreset(
              name: 'h',
              presetId: 'hosts',
              varsValues: {'domains': 'a.example\nx.example\nx.example'}),
          collectPreset(extraVar: {'unique': true}),
          nodes: [srv('a', 'a.example'), srv('b', 'b.example')]);
      expect(f.dnsRules.single['domain'],
          ['a.example', 'x.example', 'b.example']);
    });

    test('пустой итог: правило без условий снимается с кодом', () {
      final warns = TemplateWarnings();
      final f = collectTemplateWarnings(
          warns,
          () => expandPreset(CustomRulePreset(name: 'h', presetId: 'hosts'),
              collectPreset(),
              nodes: [ts('ts')]));
      expect(f.dnsRules, isEmpty);
      expect(warns.codes, contains(templateWarnFragmentDropped));
    });

    test('подписи «обслуживаемые узлы» у _do нет', () {
      expect(
          presetForEachNodes(CustomRulePreset(name: 'h', presetId: 'hosts'),
              collectPreset(), [srv('a', 'a.example')]),
          isEmpty);
    });
  });

  group('nodeLoopTypeHint', () {
    test('равенство, #in, член #and; иначе — без сужения', () {
      expect(nodeLoopTypeHint({'@node.body.type': 'tailscale'}),
          {'tailscale'});
      expect(
          nodeLoopTypeHint({
            '#and': [
              {'@node.body.type': 'tailscale'},
              {'#not': '@node.skip_presets'},
            ],
          }),
          {'tailscale'});
      expect(
          nodeLoopTypeHint({
            '@node.body.type': {
              '#in': ['vless', 'trojan'],
            },
          }),
          {'vless', 'trojan'});
      expect(nodeLoopTypeHint(null), isNull);
      expect(nodeLoopTypeHint({'@node.body.server': '#notEmpty'}), isNull);
      expect(
          nodeLoopTypeHint({
            '#or': [
              {'@node.body.type': 'tailscale'},
              {'@node.body.type': 'vless'},
            ],
          }),
          isNull);
    });
  });

  group('for_each_node: прочее', () {

    test('пресет без обхода работает как раньше, узлы не влияют', () {
      final preset = SelectableRule.fromJson({
        'preset_id': 'plain',
        'rule': {'ip_is_private': true, 'outbound': 'direct-out'},
      });
      final cr = CustomRulePreset(name: 'plain', presetId: 'plain');
      final a = expandPreset(cr, preset);
      final b = expandPreset(cr, preset, nodes: [ts('home-ts')]);
      expect(a.routingRules, [
        {'ip_is_private': true, 'outbound': 'direct-out'},
      ]);
      expect(b.routingRules, a.routingRules);
    });
  });

  group('@node', () {
    final node = ts('home-ts', extra: {
      'hostname': 'box',
      'nested': {'deep': 7},
      'empty': '',
    });
    final r = presetNodeResolver(node);

    test('тег, поле записи, поле тела', () {
      expect(r('node'), 'home-ts');
      expect(r('node.skip_presets'), false);
      expect(r('node.body.hostname'), 'box');
      expect(r('node.body.nested.deep'), 7);
    });

    test('отсутствующее или пустое поле — Dropped; чужое имя — null', () {
      expect(r('node.body.missing'), same(Dropped.instance));
      expect(r('node.body.nested.missing'), same(Dropped.instance));
      expect(r('node.body.empty'), same(Dropped.instance));
      expect(r('node.unknown_field'), same(Dropped.instance));
      expect(r('other'), isNull);
    });

    test('в теле: отсутствующее поле снимает ключ и элемент', () {
      final out = substituteVars(j({
        'a': '@node.body.hostname',
        'b': '@node.body.missing',
        'list': ['@node', '@node.body.missing'],
      }), const {}, extra: r);
      expect(out, {
        'a': 'box',
        'list': ['home-ts'],
      });
    });
  });

  group('#tpl', () {
    dynamic resolve(String name) => switch (name) {
          'a' => 'one',
          'b' => 2,
          'node.body.hostname' => 'box',
          'blank' => '',
          'gone' => Dropped.instance,
          _ => null,
        };

    test('одна и две вставки, путь, @имя без скобок — литерал', () {
      expect(walk(j({'#tpl': '@{a}-dns'}), resolve), 'one-dns');
      expect(walk(j({'#tpl': '@{a}/@{b}'}), resolve), 'one/2');
      expect(walk(j({'#tpl': 'h-@{node.body.hostname}'}), resolve), 'h-box');
      expect(walk(j({'#tpl': '@a-@{a}'}), resolve), '@a-one');
    });

    test('пустое или неизвестное значение снимает ключ и элемент', () {
      expect(
          walk(j({
            'x': {'#tpl': '@{blank}-dns'},
            'y': {'#tpl': '@{gone}'},
            'z': {'#tpl': '@{unknown}'},
            'keep': 1,
          }), resolve),
          {'keep': 1});
      expect(
          walk(j([
            {'#tpl': '@{a}'},
            {'#tpl': '@{blank}'},
          ]), resolve),
          ['one']);
    });

    test('внутри #value', () {
      expect(
          walk(j({
            '#if': {
              '#and': ['@flag'],
              '#value': {
                's': {'#tpl': '@{a}-x'},
              },
            },
          }), (n) => n == 'flag' ? true : resolve(n)),
          {'s': 'one-x'});
    });

    test('лишний ключ — ошибка шаблона: загрузка бросает, рантайм снимает', () {
      final sink = TemplateWarnings();
      final out = collectTemplateWarnings(
          sink,
          () => walk(j({
                'x': {'#tpl': '@{a}', 'extra': 1},
                'keep': 1,
              }), resolve));
      expect(out, {'keep': 1});
      expect(sink.items.map((w) => w.code), [templateWarnUnknownDirective]);
      expect(
          () => validateIfConstructs({
                'x': {'#tpl': '@{a}', 'extra': 1},
              }, const {}),
          throwsA(isA<TemplateIfError>()));
    });

    test('обычная строка вне #tpl не меняется', () {
      expect(walk(j({'s': 'a-@{a}'}), resolve), {'s': 'a-@{a}'});
    });
  });

  group('загрузка шаблона', () {
    test('for_each — ошибка загрузки всего шаблона (D-130, §83 отменён)', () {
      final json = shippedTemplate();
      (json['selectable_rules'] as List).add({
        'preset_id': 'bad',
        'for_each': {'node_type': 'tailscale', 'as': 'node'},
        'ui': {'label': 'bad'},
      });
      expect(() => WizardTemplate.fromJson(json),
          throwsA(isA<FormatException>()));
      expect(
          () => parsePresetNodeLoop(
              (json['selectable_rules'] as List).last as Map<String, dynamic>,
              const {}),
          throwsA(isA<TemplateIfError>()));
    });

    test('#filter с необъявленным полем записи — ошибка шаблона', () {
      final json = shippedTemplate();
      (json['selectable_rules'] as List).add({
        'preset_id': 'bad',
        'for_each_node': {'#filter': '@node.nope'},
        'ui': {'label': 'bad'},
      });
      expect(
          () => validateTemplateConstructs(json, WizardTemplate.fromJson(json)),
          throwsA(isA<TemplateIfError>()));
    });

    test('глобальная переменная node.* или unique не у text_list — ошибка',
        () {
      for (final decl in [
        {'name': 'node.x', 'type': 'text'},
        {'name': 'flag', 'type': 'bool', 'unique': true},
      ]) {
        final json = shippedTemplate();
        ((json['sections'] as List).first['vars'] as List).add(decl);
        expect(
            () => validateTemplateConstructs(
                json, WizardTemplate.fromJson(json)),
            throwsA(isA<TemplateIfError>()),
            reason: '$decl');
      }
    });

    test('у `for_each_node_do` тело без @node: имя узла в #if — ошибка', () {
      final json = shippedTemplate();
      (json['selectable_rules'] as List).add({
        'preset_id': 'bad',
        'for_each_node_do': {
          '#do': {
            '@hosts': {'#append': '@node.body.server'},
          },
        },
        'vars': [
          {'name': 'hosts', 'type': 'text_list'},
        ],
        'rules': [
          {
            '#if': {
              '#and': ['@node.skip_presets'],
              '#value': {'domain': '@hosts', 'outbound': 'direct-out'},
            },
          },
        ],
        'ui': {'label': 'bad'},
      });
      expect(
          () => validateTemplateConstructs(json, WizardTemplate.fromJson(json)),
          throwsA(isA<TemplateIfError>()));
    });

    test('боевой пресет tailscale проходит валидацию', () {
      final json = shippedTemplate();
      expect(() => validateTemplateConstructs(json, WizardTemplate.fromJson(json)),
          returnsNormally);
      expect(tailscalePreset().nodeLoop?.isNode, isTrue);
    });
  });
}
