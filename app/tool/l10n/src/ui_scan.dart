import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'package:lxbox/services/l10n/plural_resolver.dart';

// §285 Ф3 — natural-key CI-гейт (аналог мёртвого arb_check для ARB-мира).
// Держит call-site'ы getLocalText и словарь assets/l10n/ui/<tag>.json в
// синхроне. Логика чистая (без dart:io) — тестируется из
// test/tool/ui_check_test.dart; entrypoint — tool/l10n/ui_check.dart.
//
// Скан AST-синтаксический (без резолюции типов), как hardcoded_scan: ловим
// вызовы `.s(...)`/`.plural(...)` у известных локализатор-ресиверов
// (getLocalText — глобальный getter; `t`/`loc` — GetLocalText-параметры в
// renderWith/messageWith-телах; GetLocalText.en — пиненный английский). Из
// каждого извлекаем английский КЛЮЧ-литерал (первый строковый аргумент, после
// опционального ведущего int-индекса формы), индекс формы (0 если нет) и
// признак .plural. Не-литеральный ключ (переменная/интерполяция) валидировать
// нельзя — считаем в dynamicKeys, но не в keys.

/// Ресиверы, которые считаем локализатором GetLocalText. `.s`/`.plural` на
/// любом другом ресивере игнорируется (в lib/ пересечений нет — см. ui_check).
const Set<String> _localizerNames = {'getLocalText', 't', 'loc'};

/// Одно собранное обращение к getLocalText из кода.
class UiKeyUse {
  UiKeyUse({
    required this.file,
    required this.line,
    required this.key,
    required this.formIndex,
    required this.isPlural,
  });

  final String file;
  final int line;

  /// Английский ключ-литерал (канонизированный: интерполяции → `{}`; в
  /// натуральных ключах их быть не должно, но канонизация консистентна со
  /// сканом hardcoded).
  final String key;

  /// 0 — корневая форма; N≥1 — special["N"].
  final int formIndex;

  /// true — вызов .plural (ждём plural-объект); false — .s (ждём String).
  final bool isPlural;
}

/// Динамический (не-литеральный) ключ — валидировать нельзя, только считаем.
class DynamicKeyUse {
  DynamicKeyUse(this.file, this.line, this.isPlural);
  final String file;
  final int line;
  final bool isPlural;
}

/// Результат AST-скана одного файла/строки.
class UiScanResult {
  final List<UiKeyUse> uses = [];
  final List<DynamicKeyUse> dynamicKeys = [];
}

/// Парсит [content] (путь [path] — только для сообщений/сайтов) и собирает все
/// обращения к локализатору.
UiScanResult scanForUiKeys({required String path, required String content}) {
  final parsed =
      parseString(content: content, path: path, throwIfDiagnostics: false);
  final res = UiScanResult();
  parsed.unit
      .accept(_UiVisitor(path, parsed.lineInfo, res));
  return res;
}

class _UiVisitor extends RecursiveAstVisitor<void> {
  _UiVisitor(this.file, this.lineInfo, this.res);

  final String file;
  final LineInfo lineInfo;
  final UiScanResult res;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    if ((name == 's' || name == 'plural') && _isLocalizer(node.target)) {
      _handle(node, isPlural: name == 'plural');
    }
    super.visitMethodInvocation(node);
  }

  /// Ресивер — локализатор: простой идентификатор из [_localizerNames] или
  /// `GetLocalText.en`.
  bool _isLocalizer(Expression? target) {
    if (target == null) return false;
    if (target is SimpleIdentifier) return _localizerNames.contains(target.name);
    // GetLocalText.en — PrefixedIdentifier (prefix=GetLocalText, ident=en).
    if (target is PrefixedIdentifier) {
      return target.prefix.name == 'GetLocalText' &&
          target.identifier.name == 'en';
    }
    // Реже — PropertyAccess (напр. через this/скобки) c .en.
    if (target is PropertyAccess) {
      return target.propertyName.name == 'en' &&
          target.target?.toSource() == 'GetLocalText';
    }
    return false;
  }

  void _handle(MethodInvocation node, {required bool isPlural}) {
    // Только позиционные аргументы участвуют в дизамбигуации формы/ключа
    // (именованных у .s/.plural нет по сигнатуре).
    final args = node.argumentList.arguments;
    if (args.isEmpty) return;
    final line = lineInfo.getLocation(node.methodName.offset).lineNumber;

    // Ведущий int-литерал = индекс особой формы; тогда ключ — второй аргумент.
    var idx = 0;
    var formIndex = 0;
    final first = args[0];
    if (first is IntegerLiteral && first.value != null) {
      formIndex = first.value!;
      idx = 1;
    }
    if (idx >= args.length) {
      // `.s(1)` без ключа — синтаксически возможно, но бессмысленно; считаем
      // динамическим (нечего валидировать).
      res.dynamicKeys.add(DynamicKeyUse(file, line, isPlural));
      return;
    }
    final keyExpr = args[idx];
    final key = _literalKey(keyExpr);
    if (key == null) {
      res.dynamicKeys.add(DynamicKeyUse(file, line, isPlural));
      return;
    }
    res.uses.add(UiKeyUse(
      file: file,
      line: line,
      key: key,
      formIndex: formIndex,
      isPlural: isPlural,
    ));
  }

  /// Строковый ключ: простой литерал или adjacent-строки. Интерполяция или
  /// любое другое выражение → null (динамический ключ). Используем
  /// canonicalLiteral, но принимаем только литералы без интерполяции —
  /// натуральный ключ обязан быть статической строкой.
  String? _literalKey(Expression e) {
    if (e is SimpleStringLiteral) return e.value;
    if (e is AdjacentStrings) {
      // Все части должны быть простыми строками.
      final buf = StringBuffer();
      for (final s in e.strings) {
        if (s is SimpleStringLiteral) {
          buf.write(s.value);
        } else {
          return null;
        }
      }
      return buf.toString();
    }
    // StringInterpolation и прочее — динамический ключ.
    return null;
  }
}

// -- placeholder arity ----------------------------------------------------

/// Множество placeholder-«слотов» в printf-строке. Последовательные `%s`/`%d`
/// нумеруются по порядку (1..N); явные `%K$s`/`%K$d` дают слот K. `%%` —
/// литеральный процент, не слот. Возвращаем множество 1-based индексов —
/// сравнение по нему устойчиво к смешению явной/неявной нумерации.
Set<int> placeholderSlots(String template) {
  final slots = <int>{};
  var seq = 0;
  var i = 0;
  while (i < template.length) {
    if (template[i] != '%') {
      i++;
      continue;
    }
    if (i + 1 >= template.length) break;
    final next = template[i + 1];
    if (next == '%') {
      i += 2;
      continue;
    }
    if (_isDigit(next)) {
      var j = i + 1;
      while (j < template.length && _isDigit(template[j])) {
        j++;
      }
      if (j + 1 < template.length && template[j] == r'$') {
        slots.add(int.parse(template.substring(i + 1, j)));
        i = j + 2;
        continue;
      }
      // не форма %K$ — трактуем '%' буквально
      i++;
      continue;
    }
    if (next == 's' || next == 'd') {
      seq++;
      slots.add(seq);
      i += 2;
      continue;
    }
    i++;
  }
  return slots;
}

bool _isDigit(String c) {
  final u = c.codeUnitAt(0);
  return u >= 0x30 && u <= 0x39;
}

// -- валидация словаря против собранных ключей ----------------------------

/// Одна проблема валидации. Уровень (fail/warn) решает вызывающий по [kind].
class UiFinding {
  UiFinding(this.kind, this.message);
  final UiFindingKind kind;
  final String message;
}

enum UiFindingKind {
  /// Ключ из кода отсутствует в словаре. warn (strict→fail).
  missing,

  /// Ключ словаря не встречается в коде. warn (strict→fail).
  orphan,

  /// Особая форма N определена в словаре, но не используется с этим индексом.
  /// warn (strict→fail).
  orphanSpecial,

  /// Ключ зовут и как .s и как .plural — противоречие. fail всегда.
  usageConflict,

  /// .plural-ключ без plural-объекта (или неполный набор форм); .s-ключ с
  /// plural-объектом-значением. fail всегда.
  shape,

  /// Расхождение арности плейсхолдеров ключ↔перевод/форма. fail всегда.
  arity,
}

/// Итог валидации: находки + счётчики для summary-строки.
class UiValidation {
  final List<UiFinding> findings = [];
  int keys = 0; // уникальных литеральных ключей
  int missing = 0;
  int orphan = 0;
  int arityErrors = 0;
  int dynamicSkipped = 0;

  bool get hasFail => findings.any((f) =>
      f.kind == UiFindingKind.usageConflict ||
      f.kind == UiFindingKind.shape ||
      f.kind == UiFindingKind.arity);
}

/// Ядро валидации: чистая функция над собранными обращениями [uses],
/// количеством динамических ключей [dynamicCount] и словарём [dict]
/// (englishKey to entry-map, как в `assets/l10n/ui/ru.json`). [forms] —
/// обязательный набор plural-форм активного resolver'а (RuPluralResolver.forms).
UiValidation validateUiKeys({
  required List<UiKeyUse> uses,
  required int dynamicCount,
  required Map<String, dynamic> dict,
  required Set<String> forms,
}) {
  final v = UiValidation();
  v.dynamicSkipped = dynamicCount;

  // Индекс использований по ключу: как звали (.s/.plural) и какие формы.
  final asS = <String>{};
  final asPlural = <String>{};
  // key → set of special-form indices used with .s / .plural (0 = root).
  final usedIndices = <String, Set<int>>{};
  for (final u in uses) {
    (u.isPlural ? asPlural : asS).add(u.key);
    usedIndices.putIfAbsent(u.key, () => {}).add(u.formIndex);
  }
  final allKeys = {...asS, ...asPlural};
  v.keys = allKeys.length;

  // 1. Конфликт использования: ключ и .s и .plural.
  for (final k in asS.intersection(asPlural)) {
    v.findings.add(UiFinding(UiFindingKind.usageConflict,
        'key "$k" is invoked both as .s and .plural — pick one'));
  }

  // 2. Missing: ключ из кода отсутствует в словаре.
  for (final k in (allKeys.toList()..sort())) {
    if (!dict.containsKey(k)) {
      v.missing++;
      v.findings.add(UiFinding(
          UiFindingKind.missing, 'key "$k" is missing from the dictionary'));
    }
  }

  // 3. Orphan: ключ словаря, не встречающийся в коде.
  for (final k in (dict.keys.toList()..sort())) {
    if (!allKeys.contains(k)) {
      v.orphan++;
      v.findings.add(UiFinding(
          UiFindingKind.orphan, 'dictionary key "$k" is never referenced in code'));
    }
  }

  // 4. Форма/арность по каждому присутствующему ключу.
  for (final k in (allKeys.toList()..sort())) {
    final entry = dict[k];
    if (entry is! Map) continue; // missing уже зарепорчен

    final wantsPlural = asPlural.contains(k);
    final wantsString = asS.contains(k);
    final rootValue = entry['value'];

    // Форма корня (index 0) — если ключ используется с индексом 0.
    final indices = usedIndices[k] ?? const <int>{};
    final keySlots = placeholderSlots(k);

    if (indices.contains(0)) {
      _checkForm(
        v: v,
        key: k,
        label: 'value',
        value: rootValue,
        wantsPlural: wantsPlural,
        wantsString: wantsString,
        forms: forms,
        keySlots: keySlots,
      );
    }

    // Особые формы N≥1.
    final special = entry['special'];
    final specialMap = special is Map ? special : const {};
    for (final idx in indices.where((i) => i >= 1)) {
      final form = specialMap['$idx'];
      if (form is! Map || !form.containsKey('value')) {
        v.findings.add(UiFinding(UiFindingKind.shape,
            'key "$k" uses special form $idx but dictionary has no special["$idx"].value'));
        continue;
      }
      _checkForm(
        v: v,
        key: k,
        label: 'special[$idx]',
        value: form['value'],
        // Особая форма наследует .s/.plural-намерение того же ключа.
        wantsPlural: wantsPlural,
        wantsString: wantsString,
        forms: forms,
        keySlots: keySlots,
      );
    }

    // Orphan-special: форма в словаре, не используемая ни одним индексом кода.
    for (final sk in specialMap.keys) {
      final n = int.tryParse('$sk');
      if (n == null) continue;
      if (!indices.contains(n)) {
        v.findings.add(UiFinding(UiFindingKind.orphanSpecial,
            'key "$k" defines special form $sk but code never uses that index'));
      }
    }
  }

  v.arityErrors =
      v.findings.where((f) => f.kind == UiFindingKind.arity).length;
  return v;
}

/// Проверяет одну форму-значение (корень или special) на shape (.s→String,
/// .plural→полный plural-объект) и арность плейсхолдеров против ключа.
void _checkForm({
  required UiValidation v,
  required String key,
  required String label,
  required Object? value,
  required bool wantsPlural,
  required bool wantsString,
  required Set<String> forms,
  required Set<int> keySlots,
}) {
  // .plural — ждём plural-объект (Map со ВСЕМИ формами resolver'а).
  if (wantsPlural) {
    if (value is! Map) {
      v.findings.add(UiFinding(UiFindingKind.shape,
          'key "$key" is used as .plural but $label is not a plural object'));
      return;
    }
    final have = value.keys.map((e) => '$e').toSet();
    final missingForms = forms.difference(have);
    if (missingForms.isNotEmpty) {
      v.findings.add(UiFinding(UiFindingKind.shape,
          'key "$key" $label plural object is missing forms: '
          '{${(missingForms.toList()..sort()).join(', ')}}'));
    }
    // Арность по каждой присутствующей форме.
    for (final f in (forms.intersection(have).toList()..sort())) {
      final formStr = value[f];
      if (formStr is! String) {
        v.findings.add(UiFinding(UiFindingKind.shape,
            'key "$key" $label plural form "$f" is not a string'));
        continue;
      }
      _checkArity(v, key, '$label.$f', keySlots, formStr);
    }
    return;
  }

  // .s — ждём строку.
  if (wantsString) {
    if (value is! String) {
      v.findings.add(UiFinding(UiFindingKind.shape,
          'key "$key" is used as .s but $label is not a string'));
      return;
    }
    _checkArity(v, key, label, keySlots, value);
  }
}

void _checkArity(
    UiValidation v, String key, String label, Set<int> keySlots, String value) {
  final valueSlots = placeholderSlots(value);
  if (!(keySlots.length == valueSlots.length &&
      keySlots.containsAll(valueSlots))) {
    v.findings.add(UiFinding(
        UiFindingKind.arity,
        'key "$key" placeholder arity mismatch in $label: '
        'key {${(keySlots.toList()..sort()).join(', ')}} vs '
        'value {${(valueSlots.toList()..sort()).join(', ')}}'));
  }
}

/// Экспорт для отладки/тестов: набор форм активного ru-resolver'а.
Set<String> ruForms() => const RuPluralResolver().forms;
