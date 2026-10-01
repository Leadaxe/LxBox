import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/if_engine.dart';
import 'package:lxbox/services/builder/preset_expand.dart';
import 'package:lxbox/services/template_loader.dart';

/// §578 — язык шаблона: `for_each` пресета, доступ `@node`, `#tpl`.
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

  group('for_each', () {
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

    test('filter по полю тела; отсутствующее поле в условии — ложь', () {
      final preset = SelectableRule.fromJson({
        'preset_id': 'p',
        'for_each': {
          'node_type': 'tailscale',
          'as': 'n',
          'filter': {'@n.body.hostname': 'box'},
        },
        'rules': [
          {'preferred_by': ['@n'], 'outbound': '@n'},
        ],
      });
      final f = expandPreset(
          CustomRulePreset(name: 'p', presetId: 'p'), preset,
          nodes: [
            ts('a', extra: {'hostname': 'box'}),
            ts('b'),
            ts('c', extra: {'hostname': 'other'}),
          ]);
      expect(f.routingRules.map((r) => r['outbound']), ['a']);
    });

    test('пресет без for_each работает как раньше, узлы не влияют', () {
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
    final r = presetNodeResolver('node', node);

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
    test('for_each без as — снимается только этот пресет (§83)', () {
      final json = shippedTemplate();
      final rules = json['selectable_rules'] as List;
      final before = rules.length;
      rules.add({
        'preset_id': 'bad',
        'for_each': {'node_type': 'tailscale'},
        'ui': {'label': 'bad'},
      });
      final dropped =
          validateTemplateConstructs(json, WizardTemplate.fromJson(json));
      expect(dropped, ['bad']);
      // Запись вырезана из raw — перечень пресетов вернулся к исходному
      // размеру, остальной шаблон (в т.ч. боевой tailscale) не пострадал.
      expect(rules.length, before);
      expect(rules.any((r) => r['preset_id'] == 'bad'), isFalse);
      expect(WizardTemplate.fromJson(json).selectableRules
          .any((r) => r.presetId == 'tailscale'), isTrue);
    });

    test('filter с необъявленным полем записи — ошибка шаблона', () {
      final json = shippedTemplate();
      (json['selectable_rules'] as List).add({
        'preset_id': 'bad',
        'for_each': {
          'node_type': 'tailscale',
          'as': 'node',
          'filter': '@node.nope',
        },
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
      expect(tailscalePreset().forEach?.as, 'node');
    });
  });
}
