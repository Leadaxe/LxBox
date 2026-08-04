import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/rule_order.dart';

void main() {
  group('markRuleOrder (§370 разметка)', () {
    test('пресет из шаблона получает шаблонный num, остальное — подряд от 1000',
        () {
      final rules = [
        _preset('fcm-push'),
        _inline('Home wifi'),
        _preset('traffic-processing'),
        _inline('4pda'),
      ];

      final changed = markRuleOrder(rules, _catalog());

      expect(changed, isTrue);
      expect(rules[0].orderNum, 970); // fcm-push из шаблона
      expect(rules[1].orderNum, 1000); // первое пользовательское
      expect(rules[2].orderNum, 0); // traffic-processing из шаблона
      expect(rules[3].orderNum, 1001); // второе пользовательское
    });

    test('уже размеченные не трогаются', () {
      final rules = [_inline('a')..orderNum = 1042];

      final changed = markRuleOrder(rules, _catalog());

      expect(changed, isFalse);
      expect(rules.single.orderNum, 1042);
    });

    test('пресет, которого нет в шаблоне, нумеруется как пользовательский', () {
      final rules = [_preset('long-gone-preset')];

      markRuleOrder(rules, _catalog());

      expect(rules.single.orderNum, kUserRuleNumStart);
    });
  });

  group('sortRulesByNum (§370 сортировка)', () {
    test('сортирует по возрастанию num', () {
      final rules = [
        _inline('c')..orderNum = 1120,
        _inline('a')..orderNum = 0,
        _inline('b')..orderNum = 970,
      ];

      final out = sortRulesByNum(rules);

      expect(out.map((r) => r.name), ['a', 'b', 'c']);
    });

    test('при равных num сохраняет исходный порядок (стабильность)', () {
      final rules = [
        _inline('first')..orderNum = 1100,
        _inline('second')..orderNum = 1100,
        _inline('third')..orderNum = 1100,
      ];

      final out = sortRulesByNum(rules);

      expect(out.map((r) => r.name), ['first', 'second', 'third']);
    });
  });

  group('placeRuleAfter (§370 drag с ленивым сдвигом)', () {
    test('свободный want — соседи не двигаются', () {
      final a = _inline('a')..orderNum = 1000;
      final moved = _inline('moved')..orderNum = 1050;
      final c = _inline('c')..orderNum = 1020;
      final rules = [a, moved, c];

      // встать за `a` (1000) → want=1001, свободен
      placeRuleAfter(rules, moved, a, isSortable: (_) => true);

      expect(moved.orderNum, 1001);
      expect(a.orderNum, 1000, reason: 'цель не двигается');
      expect(c.orderNum, 1020, reason: 'want был свободен — сдвига нет');
    });

    test('занятый want — сдвигаются только те, кто >= want', () {
      final head = _inline('head')..orderNum = 950;
      final a = _inline('a')..orderNum = 1000;
      final b = _inline('b')..orderNum = 1001; // занимает want
      final c = _inline('c')..orderNum = 1002;
      final moved = _inline('moved')..orderNum = 1080;
      final rules = [head, a, b, c, moved];

      placeRuleAfter(rules, moved, a, isSortable: (_) => true);

      expect(moved.orderNum, 1001);
      expect(head.orderNum, 950, reason: 'ниже want — не трогаем');
      expect(a.orderNum, 1000, reason: 'цель — не трогаем');
      expect(b.orderNum, 1002, reason: 'был на want → +1');
      expect(c.orderNum, 1003);
    });

    test('шаблонные якоря не сдвигаются, если каскад до них не дошёл', () {
      final a = _inline('a')..orderNum = 1000;
      final anchor = _preset('ru-direct')..orderNum = 1120;
      final moved = _inline('moved')..orderNum = 1090;
      final rules = [a, anchor, moved];

      placeRuleAfter(rules, moved, a, isSortable: (_) => true);

      expect(moved.orderNum, 1001);
      expect(anchor.orderNum, 1120,
          reason: 'весь смысл ленивого сдвига — якорь на месте');
    });

    test('каскад останавливается на первой дырке — якорь за ней не двигается',
        () {
      final a = _inline('a')..orderNum = 1000;
      final b = _inline('b')..orderNum = 1001; // занимает want
      final c = _inline('c')..orderNum = 1002; // сплошной блок
      final gap = _preset('ru-direct')..orderNum = 1120; // за дыркой
      final moved = _inline('moved')..orderNum = 1090;
      final rules = [a, b, c, gap, moved];

      placeRuleAfter(rules, moved, a, isSortable: (_) => true);

      expect(moved.orderNum, 1001);
      expect(b.orderNum, 1002, reason: 'сплошной блок сдвигается');
      expect(c.orderNum, 1003);
      expect(gap.orderNum, 1120,
          reason: 'между блоком и якорем ДЫРКА — вытеснять некуда; '
              'сдвиг всех >= want уводил якорь на 1121 (баг на устройстве)');
    });

    test('несортируемое правило не двигается и не сдвигается', () {
      final head = _preset('traffic-processing')..orderNum = 0;
      final a = _inline('a')..orderNum = 1000;
      final moved = _inline('moved')..orderNum = 1010;
      final rules = [head, a, moved];
      bool sortable(CustomRule r) => r.presetId != 'traffic-processing';

      // попытка подвинуть саму шапку — no-op
      placeRuleAfter(rules, head, a, isSortable: sortable);
      expect(head.orderNum, 0);

      // сдвиг остальных шапку не задевает
      placeRuleAfter(rules, moved, a, isSortable: sortable);
      expect(head.orderNum, 0);
      expect(moved.orderNum, 1001);
    });

    test('target == null — правило уезжает в начало пользовательской зоны', () {
      final a = _inline('a')..orderNum = 1000;
      final moved = _inline('moved')..orderNum = 1050;
      final rules = [a, moved];

      placeRuleAfter(rules, moved, null, isSortable: (_) => true);

      expect(moved.orderNum, kUserRuleNumStart);
      expect(a.orderNum, 1001, reason: 'был на want → сдвинулся');
    });
  });

  group('nextUserRuleNum (§370 вставка пользовательского)', () {
    test('пустая зона → старт зоны', () {
      expect(nextUserRuleNum([_preset('fcm-push')..orderNum = 970]),
          kUserRuleNumStart);
    });

    test('конец занятой части зоны, шаблонные вне зоны игнорируются', () {
      final rules = [
        _preset('traffic-processing')..orderNum = 0,
        _inline('a')..orderNum = 1000,
        _inline('b')..orderNum = 1005,
        _preset('ru-direct')..orderNum = 1120, // вне зоны — не влияет
      ];

      expect(nextUserRuleNum(rules), 1006);
    });

    test('зона исчерпана → возвращает границу (равенство допустимо)', () {
      final rules = [_inline('last')..orderNum = kUserRuleNumEnd];

      expect(nextUserRuleNum(rules), kUserRuleNumEnd);
    });
  });

  group('normalizeRuleOrder (§370 полный проход)', () {
    test('seed обязательного пресета + разметка + сортировка', () {
      final rules = [_inline('user')..orderNum = 1000];

      final out = normalizeRuleOrder(rules, _catalog(), _template());

      expect(out.first.presetId, 'traffic-processing',
          reason: 'несортируемый пресет засеян и стоит первым');
      expect(out.first.orderNum, 0);
      expect(out.last.name, 'user');
    });

    test('идемпотентность: повторный вызов ничего не меняет', () {
      final once = normalizeRuleOrder(
          [_preset('fcm-push'), _inline('user')], _catalog(), _template());
      final snapshot = [for (final r in once) '${r.presetId}:${r.orderNum}'];

      final twice = normalizeRuleOrder(once, _catalog(), _template());

      expect([for (final r in twice) '${r.presetId}:${r.orderNum}'], snapshot);
    });

    test('varsValues существующего пресета не затирается seed-ом', () {
      final rules = [
        CustomRulePreset(
          name: 'Traffic Processing',
          presetId: 'traffic-processing',
          varsValues: const {'sniff_enabled': 'false'},
        ),
      ];

      final out = normalizeRuleOrder(rules, _catalog(), _template());

      final head = out.first as CustomRulePreset;
      expect(head.varsValues['sniff_enabled'], 'false');
    });

    test('регресс §369: пресет с direct-out не встаёт выше шапки', () {
      // fcm-push (970) добавлен в пустой список — шапка засевается на 0.
      final out =
          normalizeRuleOrder([_preset('fcm-push')], _catalog(), _template());

      expect(out.map((r) => r.presetId), ['traffic-processing', 'fcm-push']);
    });
  });

  group('§370 регресс: drag не двигает шаблонные якоря', () {
    test('перетаскивание в занятую точку не сдвигает якоря ниже', () {
      // Раскладка как на устройстве после разметки.
      final head = _preset('traffic-processing')..orderNum = 0;
      final priv = _preset('private-ip')..orderNum = 950;
      final ads = _preset('block-ads')..orderNum = 960;
      final fcm = _preset('fcm-push')..orderNum = 970;
      final bt = _preset('bittorrent')..orderNum = 980;
      final home = _inline('Home wifi')..orderNum = 1000;
      final ruDirect = _preset('ru-direct')..orderNum = 1120;
      final rules = [head, priv, ads, fcm, bt, home, ruDirect];
      bool sortable(CustomRule r) => r.presetId != 'traffic-processing';

      // fcm тащим за bt (980) → want=981, свободен → сдвига быть не должно
      placeRuleAfter(rules, fcm, bt, isSortable: sortable);

      expect(fcm.orderNum, 981);
      expect(home.orderNum, 1000, reason: 'want свободен — сосед не двигается');
      expect(ruDirect.orderNum, 1120, reason: 'ЯКОРЬ обязан стоять');
      expect(head.orderNum, 0);
    });
  });

  group('JSON round-trip (§370 num в storage)', () {
    test('orderNum переживает toJson/fromJson', () {
      final r = _inline('a')..orderNum = 1042;

      final back = CustomRule.fromJson(r.toJson());

      expect(back.orderNum, 1042);
      expect(r.toJson()['num'], 1042, reason: 'ключ в JSON — `num`');
    });

    test('неразмеченное правило не пишет ключ num', () {
      expect(_inline('a').toJson().containsKey('num'), isFalse);
    });

    test('copyWith сохраняет orderNum', () {
      final r = _inline('a')..orderNum = 1007;

      expect(r.copyWith(name: 'b').orderNum, 1007);
      expect(r.withEnabled(false).orderNum, 1007);
    });
  });
}

CustomRulePreset _preset(String id) =>
    CustomRulePreset(name: id, presetId: id, varsValues: const {});

CustomRuleInline _inline(String name) => CustomRuleInline(name: name);

/// Каталог по раскладке §370 §2 (подмножество, достаточное для тестов).
List<SelectableRule> _catalog() => [
      _spec('traffic-processing', 0, sortable: false),
      _spec('private-ip', 950),
      _spec('block-ads', 960),
      _spec('fcm-push', 970),
      _spec('ru-direct', 1120),
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
