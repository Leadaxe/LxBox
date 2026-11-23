import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/rule_tree_tags.dart' show ruleRefHash;
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/storage_migration/rule_set_tag_refs.dart';

/// §757 (контракт 1.1.182, TASKS_LXBOX §185) — перезапись рукописных ссылок
/// `rule_set` на прежние теги наборов собственных правил: тела правил
/// маршрута и свои DNS-правила; идемпотентность; чужие теги не трогаются.
void main() {
  const a = 'https://example.com/rules/a.srs';
  const b = 'https://example.com/rules/b.srs';
  const c = 'https://example.com/rules/c.srs';
  const x = 'https://example.com/x.srs';
  const y = 'https://example.com/y.srs';

  // «Geo» — три ссылки, своего inline-набора корня нет; «Ai» — две ссылки и
  // inline-набор корня (`domain_suffix`).
  Map<String, dynamic> geo() => {
        'kind': 'srs',
        'id': 'g',
        'name': 'Geo',
        'body': {
          'refs': [a, b, c],
          'outbound': 'proxy',
        },
      };
  Map<String, dynamic> ai() => {
        'kind': 'srs',
        'id': 'ai',
        'name': 'Ai',
        'body': {
          'refs': [x, y],
          'domain_suffix': ['example-1.com'],
          'outbound': 'proxy',
        },
      };
  Map<String, dynamic> verbatim(String name, Object ruleSet) => {
        'kind': 'inline',
        'id': 'v-$name',
        'name': name,
        'verbatim': true,
        'body': {'rule_set': ruleSet, 'outbound': 'direct'},
      };

  Map<String, dynamic> doc(
    List<Map<String, dynamic>> rules, {
    List<Map<String, dynamic>> dns = const [],
  }) =>
      jsonDecode(jsonEncode({
        'storage_version': 1,
        'rules': rules,
        'dns': {'servers': [], 'rules': dns},
      })) as Map<String, dynamic>;

  int migrate(
    Map<String, dynamic> d, {
    Iterable<String> taken = const [],
    List<SelectableRule> presets = const [],
  }) =>
      migrateRuleSetTagRefs(d, takenTags: taken, presets: presets);

  Object? bodyRuleSet(Map<String, dynamic> d, int i) =>
      (d['rules'] as List)[i]['body']['rule_set'];

  test('схема до §757: `имя` и `имя-N` → `имя:<stem>`', () {
    final d = doc([
      geo(),
      verbatim('Mine', ['Geo', 'Geo-2', 'Geo-3', 'other']),
    ]);
    expect(migrate(d), 3);
    expect(bodyRuleSet(d, 1), ['Geo:a', 'Geo:b', 'Geo:c', 'other']);
  });

  test('промежуточная схема: `имя:<h8>` → `имя:<stem>`, `имя:inline` → `имя`',
      () {
    final d = doc([
      ai(),
      geo(),
      verbatim('Mine', [
        'Ai',
        'Ai:${ruleRefHash(y)}',
        'Ai:inline',
        'Geo',
        'Geo:${ruleRefHash(b)}',
        'Geo:${ruleRefHash(c, length: 16)}',
      ]),
    ]);
    expect(migrate(d), 5);
    // Голый `Ai` остаётся: у правила свой inline-набор корня, теперь это его
    // тег; голый `Geo` (без inline-набора) — на тег первой ссылки.
    expect(bodyRuleSet(d, 2), ['Ai', 'Ai:y', 'Ai', 'Geo:a', 'Geo:b', 'Geo:c']);
  });

  test('рукописные теги в узлах дерева правила — на любом уровне', () {
    final d = doc([
      geo(),
      {
        'kind': 'inline',
        'id': 't',
        'name': 'Tree',
        'body': {
          'type': 'logical',
          'mode': 'or',
          'rules': [
            {'rule_set': 'Geo-2'},
            {
              'rule_set': ['Geo', 'foreign'],
              'port': [443],
            },
          ],
          'outbound': 'direct',
        },
      },
    ]);
    expect(migrate(d), 2);
    final rules = (d['rules'] as List)[1]['body']['rules'] as List;
    expect(rules[0]['rule_set'], 'Geo:b');
    expect(rules[1]['rule_set'], ['Geo:a', 'foreign']);
  });

  test('свои DNS-правила: `user` (body) и `srs` (rule, body), logical', () {
    final d = doc([
      ai(),
      geo(),
    ], dns: [
      {
        'kind': 'user',
        'name': 'u',
        'enabled': true,
        'body': {
          'rule_set': ['Geo', 'Ai:inline'],
          'server': 'dns-a',
        },
      },
      {
        'kind': 'user',
        'name': 'l',
        'enabled': true,
        'body': {
          'type': 'logical',
          'mode': 'and',
          'rules': [
            {'rule_set': 'Geo-3'},
            {
              'query_type': ['A'],
            },
          ],
          'server': 'dns-a',
        },
      },
      {
        'kind': 'srs',
        'name': 's',
        'id': 'ds',
        'rule': {'rule_set': 'Geo-2'},
        'body': {'rule_set': 'Ai:${ruleRefHash(y)}'},
      },
      {
        'kind': 'template',
        'name': 'tpl',
        'enabled': true,
        'rule_set': 'Geo',
      },
    ]);
    expect(migrate(d), 5);
    final dns = d['dns']['rules'] as List;
    expect(dns[0]['body']['rule_set'], ['Geo:a', 'Ai']);
    expect((dns[1]['body']['rules'] as List)[0]['rule_set'], 'Geo:c');
    expect(dns[2]['rule']['rule_set'], 'Geo:b');
    expect(dns[2]['body']['rule_set'], 'Ai:y');
    // Не своё DNS-правило — не трогается.
    expect(dns[3]['rule_set'], 'Geo');
  });

  test('идемпотентна: повторный прогон ничего не меняет', () {
    final d = doc([
      ai(),
      geo(),
      verbatim('Mine', ['Geo', 'Geo-2', 'Ai:inline', 'Ai:x']),
    ]);
    expect(migrate(d), 3);
    final once = jsonEncode(d);
    expect(migrate(d), 0);
    expect(jsonEncode(d), once);
    expect(bodyRuleSet(d, 2), ['Geo:a', 'Geo:b', 'Ai', 'Ai:x']);
  });

  test('чужие теги и теги, совпавшие с нынешними, не трогаются', () {
    final preset = SelectableRule.fromJson({
      'label': 'RU',
      'preset_id': 'ru',
      'rule_set': [
        {'tag': 'ru:Geo-2', 'type': 'inline', 'rules': []},
      ],
      'rule': {'rule_set': 'ru:Geo-2', 'outbound': 'direct'},
    });
    final d = doc([
      geo(),
      // Правило «Geo-3» с inline-набором корня: `Geo-3` — его нынешний тег.
      {
        'kind': 'inline',
        'id': 'g3',
        'name': 'Geo-3',
        'body': {
          'domain': ['example-2.com'],
          'outbound': 'direct',
        },
      },
      {'kind': 'preset', 'id': 'p', 'ref': 'ru', 'enabled': false},
      verbatim('Mine', [
        'Geo-3',
        'Geo:a',
        'template-set',
        'ru:Geo-2',
        'Unknown',
        'Unknown-2',
      ]),
    ]);
    expect(
      migrate(d, taken: const ['template-set'], presets: [preset]),
      0,
    );
    expect(bodyRuleSet(d, 3), [
      'Geo-3',
      'Geo:a',
      'template-set',
      'ru:Geo-2',
      'Unknown',
      'Unknown-2',
    ]);
  });

  test('запись старой формы (ссылки на записи) — по тем же правилам', () {
    final d = doc([
      {
        'kind': 'srs',
        'id': 'old',
        'name': 'Old',
        'refs': [a, b],
        'body': {'outbound': 'proxy'},
      },
      verbatim('Mine', ['Old', 'Old-2']),
    ]);
    expect(migrate(d), 2);
    expect(bodyRuleSet(d, 1), ['Old:a', 'Old:b']);
  });

  group('маркер хранилища', () {
    late Directory tmp;
    const channel = MethodChannel('plugins.flutter.io/path_provider');

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tmp = await Directory.systemTemp.createTemp('lxbox_rule_set_tags_');
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
      } on FileSystemException {
        /* ignore */
      }
    });

    test('один раз: после маркера голый `имя` больше не переписывается',
        () async {
      final template =
          WizardTemplate.fromJson(<String, dynamic>{
        'config': <String, dynamic>{},
        'selectable_rules': <dynamic>[],
      });
      await SettingsStorage.replaceRaw(doc([
        geo(),
        verbatim('Mine', ['Geo', 'Geo-2']),
      ]));
      await SettingsStorage.migrateRuleSetTagRefsIfNeeded(template);
      var out = await SettingsStorage.dumpCache();
      expect(out['rule_set_tags_migrated'], isTrue);
      expect(out['rules'][1]['body']['rule_set'], ['Geo:a', 'Geo:b']);

      // Пользователь после обновления снова написал голый `Geo`.
      out['rules'][1]['body']['rule_set'] = ['Geo'];
      await SettingsStorage.replaceRaw(out);
      await SettingsStorage.migrateRuleSetTagRefsIfNeeded(template);
      out = await SettingsStorage.dumpCache();
      expect(out['rules'][1]['body']['rule_set'], ['Geo']);
    });
  });
}
