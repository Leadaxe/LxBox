/// §370 — разметка и упорядочивание правил по разреженной оси `num`.
///
/// Ось — сквозная нумерация всех правил (см. `docs/spec/tasks/370-…` §2):
/// `0` голова (traffic-processing), `950..990` специфичные пресеты,
/// `1000..1100` зона пользовательских правил, `1110..1150` широкие
/// перехватчики. Шаг 10 между шаблонными оставлен намеренно — в зазор можно
/// вписать новый пресет, не переделывая раскладку.
///
/// `num` — СТАРТОВАЯ позиция, а не забитая навсегда сортировка: юзер двигает
/// правило drag'ом, номер пересчитывается (`reorderByNum`). Но живёт он в
/// storage и является авторитетным источником порядка — именно поэтому
/// зазоры должны сохраняться, а не схлопываться при каждом перетаскивании.
///
/// Заменяет §264 `pinned` (фиксированная позиция «всегда первый»): тот умел
/// только прибить к началу и ничего не говорил про остальные правила.
library;

import '../../models/custom_rule.dart';
import '../../models/parser_config.dart';
import '../selectable_to_custom.dart';

/// §370 — проставить `num` правилам, у которых его ещё нет.
///
/// Отдельного версионированного шага миграции НЕТ (решение владельца): storage,
/// записанный до §370, приезжает с `orderNum == null`, и разметка случается при
/// первой же загрузке.
///
/// - правило-пресет, чей `presetId` есть в шаблоне → `num` из шаблона;
/// - всё остальное (пользовательские inline/srs/json + пресеты, которых в
///   шаблоне уже нет) → подряд от [kUserRuleNumStart] в текущем порядке списка.
///
/// Принятое следствие: правила из старого storage садятся в начало
/// пользовательской зоны и оказываются приоритетнее добавленных после
/// обновления. Мутирует элементы на месте (поле `orderNum` не final);
/// возвращает true, если что-то размечено — вызывающий персистит.
bool markRuleOrder(
  List<CustomRule> customRules,
  List<SelectableRule> selectableRules,
) {
  final numByPresetId = {
    for (final sr in selectableRules) sr.presetId: sr.num,
  };

  var changed = false;
  var nextUserNum = kUserRuleNumStart;
  for (final cr in customRules) {
    if (cr.orderNum != null) continue;
    final fromTemplate =
        cr.kind == CustomRuleKind.preset ? numByPresetId[cr.presetId] : null;
    cr.orderNum = fromTemplate ?? nextUserNum++;
    changed = true;
  }
  return changed;
}

/// §370 — отсортировать правила по оси `num` (возрастание).
///
/// При равных `num` сохраняется взаимный порядок (стабильная сортировка):
/// равенство возможно после исчерпания пользовательской зоны, см.
/// [nextUserRuleNum]. Неразмеченные (`orderNum == null`) считаются
/// [kDefaultRuleNum] — но в норме [markRuleOrder] отрабатывает раньше.
List<CustomRule> sortRulesByNum(List<CustomRule> customRules) {
  final indexed = [
    for (var i = 0; i < customRules.length; i++) (i, customRules[i]),
  ];
  indexed.sort((a, b) {
    final byNum = (a.$2.orderNum ?? kDefaultRuleNum)
        .compareTo(b.$2.orderNum ?? kDefaultRuleNum);
    return byNum != 0 ? byNum : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// §370 — seed недостающих пресетов, объявленных в шаблоне как `default: true`
/// И несортируемых (`isSortable: false`).
///
/// Продуктовый инвариант §264: `traffic-processing` ДОЛЖЕН присутствовать
/// независимо от того, что в storage (fresh install, backup-restore, ручная
/// правка Debug API, апгрейд со старого storage, где пресета ещё не было).
/// Он несёт `sniff`/`hijack-dns`/`resolve`, а `sniff` обязан быть первым
/// правилом `route.rules` — иначе домен не извлечётся до матчинга роутинга.
///
/// Сортируемые пресеты здесь НЕ сидятся: их состав — выбор юзера.
List<CustomRule> seedRequiredPresets(
  List<CustomRule> customRules,
  List<SelectableRule> selectableRules,
  WizardTemplate template,
) {
  final required = selectableRules.where((r) => !r.isSortable).toList();
  if (required.isEmpty) return customRules;

  final present = {
    for (final cr in customRules)
      if (cr.kind == CustomRuleKind.preset) cr.presetId,
  };
  final missing = required.where((r) => !present.contains(r.presetId));
  if (missing.isEmpty) return customRules;

  final out = [...customRules];
  for (final spec in missing) {
    final seeded = selectableRuleToCustom(spec, template);
    out.add(CustomRulePreset(
      name: seeded.name,
      presetId: seeded.presetId,
      enabled: spec.defaultEnabled,
      varsValues: seeded.varsValues,
      orderNum: spec.num,
    ));
  }
  return out;
}

/// §370 — полный проход: seed обязательных → разметка → сортировка.
///
/// Идемпотентен: повторный вызов на нормализованном списке ничего не меняет.
/// Значения vars существующих пресетов сохраняются (seed только если пресета
/// нет вовсе).
List<CustomRule> normalizeRuleOrder(
  List<CustomRule> customRules,
  List<SelectableRule> selectableRules,
  WizardTemplate template,
) {
  final seeded = seedRequiredPresets(customRules, selectableRules, template);
  markRuleOrder(seeded, selectableRules);
  return sortRulesByNum(seeded);
}

/// §370 — номер для нового пользовательского правила: конец занятой части
/// зоны [kUserRuleNumStart]..[kUserRuleNumEnd].
///
/// Зона исчерпана (максимум уже на границе) → возвращаем ту же границу:
/// равенство `num` допустимо, порядок доопределяется позицией в списке.
/// Раздвигать зону не нужно — сто слотов на пользовательские правила.
int nextUserRuleNum(List<CustomRule> customRules) {
  var maxInZone = kUserRuleNumStart - 1;
  for (final cr in customRules) {
    final n = cr.orderNum;
    if (n == null || n < kUserRuleNumStart || n > kUserRuleNumEnd) continue;
    if (n > maxInZone) maxInZone = n;
  }
  final next = maxInZone + 1;
  return next > kUserRuleNumEnd ? kUserRuleNumEnd : next;
}

/// §370 — поставить правило [moved] сразу за правилом [target] («ленивый сдвиг»).
///
/// ```
/// want = target.num + 1
/// want свободен → moved.num = want            (соседи не трогаются)
/// want занят    → сдвигаем СПЛОШНОЙ занятый блок от want вверх на +1,
///                 останавливаясь на первой дырке; moved.num = want
/// ```
///
/// **Почему сдвиг ленивый, а не безусловный (не переизобретать):** каскад +1 на
/// каждом drag'е съедал бы зазоры и двигал шаблонные якоря — тогда `num` из
/// шаблона перестал бы что-либо гарантировать, и вписать новый пресет между
/// `ru-inside` (1110) и `ru-direct` (1120) стало бы невозможно. При ленивом
/// сдвиге уплотнение локально (только в точке перетаскивания), вся ось ниже
/// стоит на месте. Перенумерация зон намеренно НЕ делается — она ломала бы
/// ровно эти якоря.
///
/// **Каскад обязан останавливаться на первой дырке.** Сдвигать всех с
/// `num >= want` недостаточно лениво: правило на 1001 вытесняется законно
/// (номер занят), но якорь на 1120 за сотней свободных номеров вытеснять
/// некуда — а он всё равно уезжал на 1121 (наблюдалось на устройстве при
/// drag'е в занятую точку). Двигаем только сплошной занятый блок.
///
/// Несортируемые (`isSortable: false`) не двигаются и не сдвигаются: их номера
/// — часть инварианта (`traffic-processing` = 0).
void placeRuleAfter(
  List<CustomRule> customRules,
  CustomRule moved,
  CustomRule? target, {
  required bool Function(CustomRule) isSortable,
}) {
  if (!isSortable(moved)) return;
  // target == null → правило уезжает в самое начало сортируемой части.
  final want = target == null
      ? kUserRuleNumStart
      : (target.orderNum ?? kDefaultRuleNum) + 1;

  // Занятые номера от `want` вверх — без самого moved и без несортируемых
  // (их номера часть инварианта, вытеснять их нельзя).
  final occupied = <int, List<CustomRule>>{};
  for (final cr in customRules) {
    if (identical(cr, moved) || !isSortable(cr)) continue;
    final n = cr.orderNum;
    if (n != null && n >= want) (occupied[n] ??= []).add(cr);
  }

  // Сплошной занятый блок от `want`: 1001,1002,1003 — сдвигаем; на первой
  // дырке останавливаемся, всё что ниже неё (включая якоря) не трогаем.
  final block = <CustomRule>[];
  for (var n = want; occupied.containsKey(n); n++) {
    block.addAll(occupied[n]!);
  }
  // Сдвигаем сверху вниз — иначе +1 наложился бы на ещё не сдвинутого соседа.
  for (final cr in block.reversed) {
    cr.orderNum = cr.orderNum! + 1;
  }
  moved.orderNum = want;
}

/// §265/§266 — вычистить ref-var значения из `varsValues` пресетов.
///
/// Ref-var (`{"ref": name}`) хранит значение в ГЛОБАЛЬНОМ userVars, НЕ в
/// varsValues. Но при переезде обычной preset-var в ref (напр. `resolve_enabled`
/// стала ref в §265) старое значение остаётся в varsValues осиротевшим — и
/// subtitle/Debug API/любой varsValues-читатель показывает застрявшее неверное
/// значение (resolve_enabled: true, когда глобаль уже false).
///
/// Проходим по каждому preset-правилу: если в его varsValues есть ключ, который
/// в шаблоне объявлен как ref-var, — удаляем. Возвращает новый список (или тот
/// же, если чистить нечего — вызывающий сравнивает и персистит только при
/// изменении). Идемпотентна.
List<CustomRule> stripRefVarsFromVarsValues(
  List<CustomRule> customRules,
  List<SelectableRule> selectableRules,
) {
  // presetId → множество имён ref-vars этого пресета.
  final refNamesByPreset = <String, Set<String>>{};
  for (final sr in selectableRules) {
    final refs = {for (final v in sr.vars) if (v.isRef) v.ref};
    if (refs.isNotEmpty) refNamesByPreset[sr.presetId] = refs;
  }
  if (refNamesByPreset.isEmpty) return customRules;

  var changed = false;
  final out = <CustomRule>[];
  for (final cr in customRules) {
    if (cr is CustomRulePreset) {
      final refs = refNamesByPreset[cr.presetId];
      if (refs != null && cr.varsValues.keys.any(refs.contains)) {
        final cleaned = {
          for (final e in cr.varsValues.entries)
            if (!refs.contains(e.key)) e.key: e.value,
        };
        out.add(cr.copyWith(varsValues: cleaned));
        changed = true;
        continue;
      }
    }
    out.add(cr);
  }
  return changed ? out : customRules;
}
