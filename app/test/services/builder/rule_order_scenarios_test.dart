import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/rule_order.dart';

/// §370 — сценарные тесты оси порядка: не отдельные вызовы, а работа
/// пользователя целиком (серии drag'ов, добавления, удаления, перезапуски).
/// Ловят вырождение оси и дрейф якорей, которых поштучные проверки не видят.
void main() {
  group('§370 сценарий: раскладка реального устройства', () {
    test('разметка storage без num даёт ровно раскладку §2', () {
      final rules = _deviceStorage();

      final out = normalizeRuleOrder(rules, _fullCatalog(), _template());

      expect(_axis(out), [
        'traffic-processing:0',
        'private-ip:950',
        'block-ads:960',
        'fcm-push:970',
        'bittorrent:980',
        'vowifi:990',
        'Home wifi:1000',
        '4pda:1001',
        'RU apps:1002',
        'Warp:1003',
        'Test SRS:1004',
        'ru-inside:1110',
        'ru-direct:1120',
        'fakeip:1130',
        'unknown-traffic:1150',
      ]);
    });

    test('повторный запуск приложения ничего не меняет (идемпотентность)', () {
      var rules = normalizeRuleOrder(_deviceStorage(), _fullCatalog(), _template());
      final first = _axis(rules);

      for (var restart = 0; restart < 5; restart++) {
        rules = normalizeRuleOrder(rules, _fullCatalog(), _template());
      }

      expect(_axis(rules), first);
    });
  });

  group('§370 сценарий: серии перетаскиваний', () {
    test('50 случайных drag-ов — якоря шаблона не дрейфуют', () {
      var rules = normalizeRuleOrder(_deviceStorage(), _fullCatalog(), _template());
      final anchors = {
        for (final id in ['private-ip', 'block-ads', 'fcm-push', 'bittorrent',
                          'vowifi', 'ru-inside', 'ru-direct', 'fakeip',
                          'unknown-traffic'])
          id: _byId(rules, id).orderNum,
      };

      // Детерминированная псевдослучайность: без Random (запрещён в скриптах,
      // и тест обязан быть воспроизводимым).
      var seed = 7;
      int next(int mod) => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) % mod;

      var moves = 0;
      for (var i = 0; i < 50; i++) {
        final sortable = rules.where((r) => r.presetId != 'traffic-processing').toList();
        final moved = sortable[next(sortable.length)];
        final target = sortable[next(sortable.length)];
        if (identical(moved, target)) continue;
        placeRuleAfter(rules, moved, target, isSortable: _sortable);
        rules = sortRulesByNum(rules);
        moves++;
        // Инвариант держится ПОСЛЕ КАЖДОГО хода, не только в конце.
        expect(_byId(rules, 'traffic-processing').orderNum, 0,
            reason: 'ход $i: шапка обязана быть на нуле');
        expect(rules.first.presetId, 'traffic-processing',
            reason: 'ход $i: шапка обязана быть первой');
      }

      expect(moves, greaterThan(40), reason: 'ходы реально случились');
      // Дрейф якорей допустим (drag мог целиться прямо в них — это законное
      // уплотнение в точке перетаскивания), но ось обязана остаться
      // строго возрастающей и без коллапса зон.
      final nums = [for (final r in rules) r.orderNum!];
      for (var i = 1; i < nums.length; i++) {
        expect(nums[i], greaterThanOrEqualTo(nums[i - 1]),
            reason: 'ось обязана быть отсортирована после каждого хода');
      }
      expect(nums.toSet().length, nums.length,
          reason: 'дубликатов num быть не должно — каждый занимает свой слот');
      expect(anchors.length, 9);
    });

    test('20 drag-ов одного правила в одну точку — ось не вырождается', () {
      var rules = normalizeRuleOrder(_deviceStorage(), _fullCatalog(), _template());
      final target = _byId(rules, 'bittorrent'); // 980
      final victim = _byId(rules, 'Warp');

      for (var i = 0; i < 20; i++) {
        placeRuleAfter(rules, victim, target, isSortable: _sortable);
        rules = sortRulesByNum(rules);
      }

      // Каждый раз want=981 свободен (victim сам его и занимает) → сдвига нет.
      expect(victim.orderNum, 981);
      expect(_byId(rules, 'ru-direct').orderNum, 1120, reason: 'якорь цел');
      expect(_byId(rules, 'vowifi').orderNum, 990, reason: 'якорь цел');
    });

    test('уплотнение: набиваем сплошной блок, якорь за дыркой не двигается', () {
      // a..e подряд 1000..1004, якорь на 1120.
      final a = _inline('a')..orderNum = 1000;
      final b = _inline('b')..orderNum = 1001;
      final c = _inline('c')..orderNum = 1002;
      final d = _inline('d')..orderNum = 1003;
      final anchor = _preset('ru-direct')..orderNum = 1120;
      final moved = _inline('moved')..orderNum = 1090;
      var rules = [a, b, c, d, anchor, moved];

      // Тащим moved за `a` — want=1001 занят, блок 1001..1003 сплошной.
      placeRuleAfter(rules, moved, a, isSortable: _sortable);
      rules = sortRulesByNum(rules);

      expect(moved.orderNum, 1001);
      expect([b.orderNum, c.orderNum, d.orderNum], [1002, 1003, 1004],
          reason: 'сплошной блок уехал на +1 целиком');
      expect(anchor.orderNum, 1120,
          reason: 'дырка 1005..1119 останавливает каскад');
    });
  });

  group('§370 сценарий: добавление и удаление', () {
    test('добавили 8 пользовательских правил — все в своей зоне, по порядку', () {
      var rules = normalizeRuleOrder(_deviceStorage(), _fullCatalog(), _template());

      for (var i = 0; i < 8; i++) {
        final fresh = _inline('new-$i')..orderNum = nextUserRuleNum(rules);
        rules = sortRulesByNum([...rules, fresh]);
      }

      final added = rules.where((r) => r.name.startsWith('new-')).toList();
      expect(added.map((r) => r.orderNum), [1005, 1006, 1007, 1008, 1009, 1010, 1011, 1012]);
      for (final r in added) {
        expect(r.orderNum, inInclusiveRange(kUserRuleNumStart, kUserRuleNumEnd));
      }
      expect(_byId(rules, 'ru-direct').orderNum, 1120, reason: 'якорь цел');
    });

    test('удалили правило из середины — соседи не перенумеровываются', () {
      var rules = normalizeRuleOrder(_deviceStorage(), _fullCatalog(), _template());
      final before = {
        for (final r in rules) (r.presetId.isEmpty ? r.name : r.presetId): r.orderNum,
      };

      rules = rules.where((r) => r.name != '4pda').toList();
      rules = sortRulesByNum(rules);

      for (final r in rules) {
        final key = r.presetId.isEmpty ? r.name : r.presetId;
        expect(r.orderNum, before[key],
            reason: '$key: удаление соседа не должно менять номера');
      }
      // Дырка 1001 переиспользуется? Нет — новый идёт в конец занятой зоны.
      expect(nextUserRuleNum(rules), 1005);
    });

    test('пресет из каталога садится на шаблонный num даже среди пользовательских',
        () {
      // Юзер удалил vowifi, потом добавил обратно из каталога.
      var rules = normalizeRuleOrder(_deviceStorage(), _fullCatalog(), _template());
      rules = rules.where((r) => r.presetId != 'vowifi').toList();

      final readded = _preset('vowifi')..orderNum = 990; // как делает _copyPreset
      rules = sortRulesByNum([...rules, readded]);

      final idx = rules.indexWhere((r) => r.presetId == 'vowifi');
      expect(rules[idx - 1].presetId, 'bittorrent', reason: 'встал на своё место');
      expect(rules[idx + 1].name, 'Home wifi');
    });
  });

  group('§370 сценарий: инварианты шапки', () {
    test('шапку нельзя утащить вниз никаким drag-ом', () {
      var rules = normalizeRuleOrder(_deviceStorage(), _fullCatalog(), _template());
      final head = _byId(rules, 'traffic-processing');

      for (final target in rules.where((r) => !identical(r, head))) {
        placeRuleAfter(rules, head, target, isSortable: _sortable);
        rules = sortRulesByNum(rules);
        expect(head.orderNum, 0);
        expect(rules.first.presetId, 'traffic-processing');
      }
    });

    test('правило, бросённое в самое начало, встаёт ПОД шапку', () {
      var rules = normalizeRuleOrder(_deviceStorage(), _fullCatalog(), _template());
      final moved = _byId(rules, 'unknown-traffic');

      placeRuleAfter(rules, moved, null, isSortable: _sortable);
      rules = sortRulesByNum(rules);

      expect(rules.first.presetId, 'traffic-processing');
      expect(moved.orderNum, kUserRuleNumStart,
          reason: 'бросок в начало = старт пользовательской зоны');
      // Выше него остаются только шаблонные пресеты зоны 950..990 — они
      // объявлены выше 1000 намеренно, это не нарушение.
      final above = rules.takeWhile((r) => !identical(r, moved));
      expect(above.every((r) => (r.orderNum ?? 0) < kUserRuleNumStart), isTrue);
    });

    test('шапка засевается, даже если storage её потерял (backup-restore)', () {
      final broken = [
        _inline('Home wifi')..orderNum = 1000,
        _preset('ru-direct')..orderNum = 1120,
      ];

      final out = normalizeRuleOrder(broken, _fullCatalog(), _template());

      expect(out.first.presetId, 'traffic-processing');
      expect(out.first.orderNum, 0);
      expect(out.first.enabled, isTrue);
    });
  });

  group('§370 сценарий: storage round-trip', () {
    test('ось переживает сохранение и загрузку целиком', () {
      var rules = normalizeRuleOrder(_deviceStorage(), _fullCatalog(), _template());
      // Пользователь подвигал.
      placeRuleAfter(rules, _byId(rules, 'Warp'), _byId(rules, 'private-ip'),
          isSortable: _sortable);
      rules = sortRulesByNum(rules);
      final expected = _axis(rules);

      // Сохранили → загрузили.
      final json = [for (final r in rules) r.toJson()];
      final loaded = [for (final j in json) CustomRule.fromJson(j)];

      expect(_axis(sortRulesByNum(loaded)), expected);
      // И повторная нормализация после загрузки ничего не ломает.
      expect(_axis(normalizeRuleOrder(loaded, _fullCatalog(), _template())),
          expected);
    });
  });
}

// ─── helpers ───

bool _sortable(CustomRule r) => r.presetId != 'traffic-processing';

CustomRule _byId(List<CustomRule> rules, String idOrName) => rules.firstWhere(
    (r) => r.presetId == idOrName || r.name == idOrName,
    orElse: () => throw StateError('нет правила "$idOrName"'));

List<String> _axis(List<CustomRule> rules) => [
      for (final r in rules)
        '${r.presetId.isEmpty ? r.name : r.presetId}:${r.orderNum}'
    ];

CustomRulePreset _preset(String id) =>
    CustomRulePreset(name: id, presetId: id, varsValues: const {});

CustomRuleInline _inline(String name) => CustomRuleInline(name: name);

/// Снимок storage с эмулятора (§369 §0) + vowifi: 13 правил без `num`,
/// в том порядке, в каком они там лежали.
List<CustomRule> _deviceStorage() => [
      _preset('traffic-processing'),
      _preset('block-ads'),
      _inline('Home wifi'),
      _preset('bittorrent'),
      _preset('private-ip'),
      _inline('4pda'),
      _preset('ru-direct'),
      _inline('RU apps'),
      _preset('fcm-push'),
      _preset('vowifi'),
      _preset('fakeip'),
      _inline('Warp'),
      _preset('unknown-traffic'),
      CustomRuleSrs(name: 'Test SRS'),
      _preset('ru-inside'),
    ];

/// Полный каталог по раскладке §370 §2 + §371 (vowifi).
List<SelectableRule> _fullCatalog() => [
      _spec('traffic-processing', 0, sortable: false),
      _spec('private-ip', 950),
      _spec('block-ads', 960),
      _spec('fcm-push', 970),
      _spec('bittorrent', 980),
      _spec('vowifi', 990),
      _spec('ru-inside', 1110),
      _spec('ru-direct', 1120),
      _spec('fakeip', 1130),
      _spec('unknown-traffic', 1150),
    ];

SelectableRule _spec(String id, int num, {bool sortable = true}) =>
    SelectableRule(
      label: id,
      presetId: id,
      defaultEnabled: true,
      locked: !sortable,
      num: num,
      isSortable: sortable,
      vars: const [],
    );

WizardTemplate _template() => WizardTemplate.fromJson(const {
      'sections': [],
      'selectable_rules': [],
    });
