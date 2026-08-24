import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/if_engine.dart';

// SPEC 393 фаза D (D5) — рубеж LOAD-валидации на общем корпусе шаблонов.
//
// Разрыв, который тут закрывается: раннер `template_contract_test.dart` гоняет
// корпус ТОЛЬКО через `walk()` — боевой обходчик рантайма. `validateIfConstructs`
// он не зовёт ни разу. Корпус зелёный, а валидатор при этом мог бы принимать
// или отвергать что угодно, и никто бы не заметил: ровно тот класс разрыва, на
// котором Go обжёгся в 6d43114 («контракт зелёный, продакшен идёт другим
// кодом»). У Go раннер корпуса в той же ситуации до сих пор.
//
// Почему отдельный файл, а не расширение раннера: фикстуры в `contract/**` —
// read-only копия общего контракта, а формата «ожидаемый вердикт загрузки» у
// корпуса СЕГОДНЯ НЕТ. Поэтому здесь — сторона LxBox, с явными списками
// кейсов; предложение общего формата описано в конце файла и уходит в контракт
// отдельной задачей.
//
// Ожидания сформулированы условиями («этот кейс обязан быть отвергнут»), а не
// снимком сообщения об ошибке: текст сообщения не нормирован контрактом.

const _contractRoot = 'contract';

/// Кейсы, чей `_comment` прямо объявляет конструкцию НЕВАЛИДНОЙ. Толерантный
/// рантайм даёт по ним fail-closed FALSE + warning (это и проверяет раннер
/// корпуса), но load-валидация обязана их отвергнуть — иначе опечатка в
/// боевом шаблоне доезжает до пользователя молча.
///
/// Рядом с каждым — цитата из `_comment` фикстуры, чтобы список не разъезжался
/// с корпусом незаметно.
const _mustRejectOnLoad = <String, String>{
  // "#if без and/or невалиден. Load-валидация обязана его отвергнуть"
  'grammar/if_without_and_or_is_false': 'нет ни and, ни or',
  // "оба ключа and и or одновременно — невалидно"
  'grammar/if_with_both_and_or_is_false': 'оба ключа and+or сразу',
  // "FAIL-CLOSED: cond-obj с обоими ключами and и or — невалиден"
  'enable/both_and_or_is_false': '#enable: оба ключа and+or сразу',
  // "FAIL-CLOSED (D-058): неразобранное условие. Число вместо cond"
  'enable/invalid_cond_is_false': '#enable: скаляр вместо условия',
};

/// Кейсы, где толерантность рантайма — И ЕСТЬ контракт: форма законна, и
/// загрузка обязана её ПРИНЯТЬ. Обратная половина рубежа: без неё валидатор
/// можно «починить» до состояния «отвергает всё подряд», и тесты промолчат.
const _mustLoadFine = <String>[
  // Сахар и вырожденные формы — §4.1.
  'grammar/hashed_keywords_canonical',
  'grammar/legacy_keywords_still_read',
  'grammar/mixed_hashed_and_legacy',
  'grammar/hashed_keywords_in_enable',
  'grammar/tolerant_unknown_var_field',
  // #enable во всех законных формах — то, что D4 обязан пропускать.
  'enable/single_string_form',
  'enable/sugar_list_is_and',
  'enable/cond_obj_or',
  'enable/recursive_cond',
  'enable/true_keeps_node_and_strips_key',
  'enable/true_then_if_applies',
  'enable/false_removes_key',
  'enable/false_drops_array_element',
  'enable/inside_if_branch',
  // Предикаты P1–P6 и вложенность.
  'predicates/nested_and_with_or',
  'predicates/nested_or_with_and',
  'predicates/nested_depth_three',
  'predicates/not_over_and',
  'predicates/p6_not_wraps_equality',
  'map_spread/named_if_two_on_one_object',
  'map_spread/nested_if_in_branch',
];

/// НЕНОРМИРОВАННЫЕ ВЕРДИКТЫ, измеренные 24.08.2026 прогоном ОБОИХ валидаторов
/// (Dart `validateIfConstructs`, Go `ValidateWizardTemplate`) по всему корпусу.
/// Два подкласса, оба — зафиксированный долг, а не «ожидаемое поведение»:
///   • Dart и Go дают РАЗНЫЙ вердикт (стороны разошлись молча);
///   • оба валидатора отвергают форму, которую корпус нормирует для рантайма
///     (валидатор строже собственного движка).
///
/// Значение — вердикт СЕГОДНЯШНЕГО Dart: `true` = отвергает. Список держит
/// правку валидатора видимой в диффе, а не проехавшей мимо. Каждая строка —
/// кандидат на решение в общем контракте (см. хвост файла).
const _knownDivergence = <String, bool>{
  // ЗАКРЫТО в D4: строковая форма `{"#in": "@list"}` (SPEC 103 C6). Рантайм
  // Dart её исполняет (`_inList`, ветка `arg is String`), Go принимает — а
  // валидатор Dart требовал список и отвергал законный шаблон. Оставлено в
  // списке как guard: возврат к отказу = регрессия.
  'predicates/p4_in_text_list_string_form': false,
  // ОБА отвергают — и это НОРМА, а не расхождение: TEMPLATE_LANG §4.1 прямо
  // определяет двухслойность (D-058): load такие конструкции отвергает, а
  // рантайм-ожидания фикстуры описывают ТОЛЕРАНТНЫЙ слой (если невалидный
  // узел всё же дошёл до рантайма — fail-closed + warning). Кандидат на
  // `"load": "reject"` с семантикой «валидатор отверг И рантайм-ожидания
  // выполняются при толерантном прогоне».
  'predicates/nested_empty_or_is_false': true,
  // То же самое на верхнем уровне (`{"and": []}` / `{"or": []}` в теле #if).
  'grammar/if_empty_and_is_true': true,
  // Условие истинно, ветки `value` нет: корпус нормирует рантайм как
  // «конструкция пропускается + warning», оба валидатора отвергают на load.
  'grammar/if_missing_value_is_skipped': true,
  // Согласованный accept. Разрыв «Dart принимает, Go отвергает» существовал
  // и был починен на стороне Go (55a54ec, 24.08.2026): TEMPLATE_LANG §4.2 P4
  // определяет предикат как принадлежность TrimSpace(scalar) множеству без
  // ограничения по типу var — валидатор Go был строже спеки и собственного
  // рантайма. Возврат к отказу на любой стороне = регрессия контракта.
  'predicates/p4_in_literal_list': false,
  'predicates/p4_notin_literal_list': false,
  // Dart принимает, Go отвергает: необъявленное имя вне предиката. Go ловит
  // его отдельным проходом `collectPlaceholderNamesFromJSON`, которого в Dart
  // нет вовсе (плейсхолдер остаётся видимым в конфиге — §5.2).
  'unresolved/undeclared_name_stays_placeholder': false,
};

/// Кейсы, которые Dart-валидатор отвергает по правилу «предикат ссылается на
/// необъявленную var». Корпус ожидает от РАНТАЙМА false+warning (§5.2 N9), и
/// раннер `template_contract_test.dart` это проверяет. Загрузка при этом
/// отвергает — оба приложения согласны (Go тоже), но фикстуры писались как
/// runtime-кейсы с пустой секцией `vars`, поэтому они здесь отдельным списком,
/// а не в `_mustRejectOnLoad`.
const _rejectedByUndeclaredName = <String>[
  'enable/unknown_var_is_false',
  'enable/false_skips_inner_evaluation',
  'unresolved/undeclared_in_predicate_is_false',
];

/// Вердикт load-валидации по фикстуре: null — принята, иначе текст ошибки.
String? _loadVerdict(String base) {
  final tpl = jsonDecode(File('$base.template.json').readAsStringSync())
      as Map<String, dynamic>;
  final byName = <String, WizardVar>{
    for (final v in (tpl['vars'] as List? ?? const []))
      if ((v as Map<String, dynamic>)['name'] is String)
        v['name'] as String: WizardVar.fromJson(v),
  };
  try {
    validateIfConstructs(tpl['config'], byName);
    return null;
  } on TemplateIfError catch (e) {
    return e.message;
  }
}

void main() {
  final root = Directory('$_contractRoot/corpus/template');
  if (!root.existsSync()) {
    // Контракт не синхронизирован — прогон пропускается, как в раннере корпуса.
    return;
  }

  String base(String name) => '${root.path}/$name';

  group('contract: load-валидация отвергает невалидные конструкции', () {
    _mustRejectOnLoad.forEach((name, why) {
      test('$name — $why', () {
        expect(File('${base(name)}.template.json').existsSync(), isTrue,
            reason: 'фикстура пропала из корпуса — список выше устарел');
        expect(_loadVerdict(base(name)), isNotNull,
            reason: 'кейс объявлен корпусом невалидным, а загрузка его приняла');
      });
    });

    test('список невалидных кейсов не пуст', () {
      // Вырожденная зелень: если фикстуры переименуют, группа выше станет
      // пустой и рубеж исчезнет незаметно.
      expect(_mustRejectOnLoad, isNotEmpty);
    });
  });

  group('contract: load-валидация принимает законные конструкции', () {
    for (final name in _mustLoadFine) {
      test(name, () {
        expect(File('${base(name)}.template.json').existsSync(), isTrue,
            reason: 'фикстура пропала из корпуса — список выше устарел');
        expect(_loadVerdict(base(name)), isNull,
            reason: 'законная форма языка отвергнута валидатором');
      });
    }
  });

  group('contract: необъявленное имя — рантайм терпит, загрузка отвергает', () {
    for (final name in _rejectedByUndeclaredName) {
      test(name, () {
        expect(_loadVerdict(base(name)), isNotNull,
            reason: 'ссылка на необъявленную var обязана ловиться на load');
      });
    }
  });

  group('contract: вердикты загрузки, не нормированные контрактом', () {
    _knownDivergence.forEach((name, dartRejects) {
      test('$name — Dart ${dartRejects ? "отвергает" : "принимает"}', () {
        expect(_loadVerdict(base(name)) != null, dartRejects,
            reason: 'поведение валидатора изменилось — расхождение с Go либо '
                'закрыто (обнови список и контракт), либо стало другим');
      });
    });
  });

  test('весь корпус классифицирован — новых непокрытых кейсов нет', () {
    // Смысл: новая фикстура в общем корпусе не должна попадать под рубеж
    // молча. Кейс, который валидатор отвергает и который ни в одном списке не
    // назван, — это либо новая находка, либо регрессия валидатора.
    final rejected = <String>[];
    for (final f in root.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.template.json')) continue;
      final b = f.path.substring(0, f.path.length - '.template.json'.length);
      final name = b.substring(root.path.length + 1);
      if (_loadVerdict(b) != null) rejected.add(name);
    }
    final accounted = <String>{
      ..._mustRejectOnLoad.keys,
      ..._rejectedByUndeclaredName,
      ...(_knownDivergence.entries.where((e) => e.value).map((e) => e.key)),
    };
    expect(rejected.toSet().difference(accounted), isEmpty,
        reason: 'валидатор отвергает кейсы корпуса, не названные ни в одном '
            'списке этого файла');
  });
}

// ───────────────────────────────────────────────────────────────────────────
// ПРЕДЛОЖЕНИЕ ФОРМАТА load-reject-фикстур для ОБЩЕГО контракта
// ───────────────────────────────────────────────────────────────────────────
//
// Проблема: у корпуса `contract/corpus/template/**` есть ровно одно ожидание —
// результат РАНТАЙМА (`expected.json` → config + warnings). Вердикт ЗАГРУЗКИ
// не выражается ничем, поэтому:
//   • раннеры обеих сторон гоняют только `walk()`, валидаторы вне контракта;
//   • Dart и Go уже разошлись на 5 кейсах (см. `_knownDivergence`), и корпус
//     остался зелёным.
//
// Предложение (минимальная правка, обратная совместимость полная): добавить в
// `<case>.expected.json` необязательное поле `load`:
//
//     {
//       "config":  { ... },              // как сейчас: результат рантайма
//       "warnings": ["..."],             // как сейчас
//       "load": "reject"                 // НОВОЕ: вердикт загрузки
//     }
//
// Значения `load`:
//   • `"accept"` — загрузка обязана принять (значение ПО УМОЛЧАНИЮ при
//     отсутствии поля: сегодня подавляющее большинство кейсов законны);
//   • `"reject"` — загрузка обязана отвергнуть; рантайм-ожидания в том же
//     файле продолжают действовать (толерантность — вторая линия обороны,
//     а не замена валидации);
//   • `"either"` — вердикт намеренно НЕ нормирован (кейс про рантайм, форма
//     на грани). Нужен для кейсов вида `unresolved/*` с пустой секцией
//     `vars`, где строгость load-валидации — вопрос отдельного решения.
//
// Почему поле в `expected.json`, а не отдельный каталог `load_reject/`:
//   • у невалидного кейса ЕСТЬ рантайм-поведение, и оно нормировано прямо
//     сейчас (fail-closed FALSE + warning). Разнеся кейс по двум каталогам,
//     мы разорвём пару «как отвергается на load» / «как терпится в рантайме»
//     — а это ровно та пара, которая держит fail-closed;
//   • каталог потребовал бы дублировать те же четыре фикстуры;
//   • новое поле читается старыми раннерами как отсутствующее — ни одна
//     сторона не ломается в момент правки контракта.
//
// Что делают раннеры после правки: тот же прогон `walk()` плюс один вызов
// валидатора; при `reject` — ожидание ошибки, при `accept` — её отсутствия,
// при `either` — вызов без проверки вердикта (кейс всё равно не должен
// падать паникой/исключением уровня рантайма).
//
// Первые кандидаты на `"load": "reject"` — четыре кейса `_mustRejectOnLoad`.
// Первые кандидаты на явный `"load": "either"` — три кейса
// `_rejectedByUndeclaredName`. Семь кейсов `_knownDivergence` — материал для
// решения оператора: сегодня их вердикт не нормирован ничем, и три из них
// (`nested_empty_or_is_false`, `if_empty_and_is_true`,
// `if_missing_value_is_skipped`) отвергаются ОБОИМИ валидаторами вопреки
// рантайм-ожиданию того же файла — то есть валидаторы строже собственных
// движков, и это видно только таким прогоном.
