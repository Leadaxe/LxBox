// §393 A6 — каскад смены `tag_prefix` источника на regex-фильтры Направлений.
//
// БОЛЕЗНЬ. Билдер эмитит тег узла как `'$tagPrefix $bare'`
// (`TagResolver.displayTag`), а Направление отбирает узлы regex'ом по
// ИТОГОВОМУ тегу (`build_config.dart:_nodesFor`). Пользователь, написавший
// фильтр `^RU: ` под подписку с префиксом `RU:`, при смене префикса на `DE:`
// молча теряет ВСЕ узлы Направления: фильтр валиден, компилируется, просто
// больше ни с чем не совпадает. Единственная диагностика сегодня —
// постфактум-SnackBar «направление без узлов» уже после сборки конфига
// (`build_config.dart:760`), то есть после того, как VPN уехал в block.
//
// РЕШЕНИЕ (симметрично `healPresetTagPrefix`, §103 C7): в момент правки
// префикса найти Направления, чей фильтр содержит СТАРЫЙ префикс ЛИТЕРАЛОМ,
// и переписать те вхождения, что однозначны. Неоднозначные не угадываем —
// про них только предупреждаем, ровно как `healPresetTagPrefix` не чинит
// локальный тег, объявленный двумя пресетами.
//
// ЧТО ТАКОЕ «ЛИТЕРАЛ» ЗДЕСЬ. Фильтр — regex, поэтому искать префикс сырым
// `String.contains` нельзя: `RU:` в `^RU: ` — литерал, а `R.` в `^R.: ` —
// конструкция (точка матчит любой символ, включая `U`). Сканер ниже
// раскладывает паттерн на позиции и знает для каждой, литеральный ли это
// символ (в т.ч. экранированный `\.`, `\$`) или метасимвол/квантор/класс/
// группа. Вхождение засчитывается, только когда ВСЕ позиции — литералы и
// ни одна из них не несёт кванторa (`RU:?` — `:` опционален, переписывать
// нельзя).
//
// Спека: docs/spec/features/393 directions/tasks.md (A6).

import '../services/safe_regex.dart';
import 'direction.dart';

/// Одно Направление, затронутое сменой префикса.
class DirectionPrefixImpact {
  const DirectionPrefixImpact({
    required this.direction,
    required this.healed,
    required this.ambiguous,
  });

  /// Направление в ИСХОДНОМ виде (до правки).
  final Direction direction;

  /// Переписанная копия — `null`, когда однозначных вхождений не нашлось
  /// (только [ambiguous]) или чинить нечего.
  final Direction? healed;

  /// True — старый префикс присутствует в фильтре, но не как чистый литерал
  /// (метасимволы/квантор внутри вхождения), либо чиниться отказался.
  /// Такое вхождение не переписано: угадывать смысл regex-конструкции —
  /// значит молча сломать её иначе.
  final bool ambiguous;

  /// Что-то переписано.
  bool get isHealed => healed != null;
}

/// Результат разбора всего списка Направлений.
class DirectionPrefixCascade {
  const DirectionPrefixCascade({required this.impacts});

  static const empty = DirectionPrefixCascade(impacts: []);

  final List<DirectionPrefixImpact> impacts;

  bool get isEmpty => impacts.isEmpty;

  /// Направления с однозначными вхождениями — их можно писать в storage.
  List<Direction> get healedDirections => [
        for (final i in impacts)
          if (i.healed != null) i.healed!,
      ];

  /// Направления, чьи фильтры трогать нельзя (нужно предупредить и оставить).
  List<DirectionPrefixImpact> get ambiguousImpacts =>
      [for (final i in impacts) if (i.ambiguous) i];
}

/// §393 A6 — разбор списка [directions] на предмет литеральных вхождений
/// [oldPrefix] в `nodeFilter`/`defaultFilter`.
///
/// [oldPrefix]/[newPrefix] — значения поля «Prefix» подписки/папки (БЕЗ
/// разделяющего пробела: его добавляет `TagResolver.displayTag`). Пустой
/// [oldPrefix] → каскада нет: пустая строка встречается в любом фильтре, и
/// «вхождений» было бы бесконечно много.
///
/// Направления без вхождений в результат не попадают (тихий случай).
DirectionPrefixCascade analyzeTagPrefixChange({
  required List<Direction> directions,
  required String oldPrefix,
  required String newPrefix,
}) {
  if (oldPrefix.isEmpty || oldPrefix == newPrefix) {
    return DirectionPrefixCascade.empty;
  }
  final impacts = <DirectionPrefixImpact>[];
  for (final d in directions) {
    final node = rewriteLiteralPrefix(d.nodeFilter, oldPrefix, newPrefix);
    final def = rewriteLiteralPrefix(d.defaultFilter, oldPrefix, newPrefix);
    final ambiguous = node.ambiguous || def.ambiguous;
    final changed = node.changed || def.changed;
    if (!ambiguous && !changed) continue;
    impacts.add(DirectionPrefixImpact(
      direction: d,
      healed: changed
          ? d.copyWith(nodeFilter: node.pattern, defaultFilter: def.pattern)
          : null,
      ambiguous: ambiguous,
    ));
  }
  return DirectionPrefixCascade(impacts: impacts);
}

/// Итог переписывания одного паттерна.
typedef PrefixRewrite = ({String pattern, bool changed, bool ambiguous});

/// Переписать литеральные вхождения [oldPrefix] на [newPrefix] в regex
/// [pattern].
///
/// - `changed` — хотя бы одно вхождение переписано;
/// - `ambiguous` — найдено вхождение, которое переписать нельзя (внутри
///   метасимвол/квантор). Такое вхождение остаётся в паттерне КАК БЫЛО.
///
/// [newPrefix] экранируется (`RegExp.escape`), иначе префикс вида `RU.` или
/// `(test)` превратил бы литерал в конструкцию и фильтр начал бы ловить
/// лишнее. Пустой [newPrefix] = «префикса больше нет»: литерал просто
/// вырезается (`^RU: x` → `^ x`) — это честнее, чем оставить мёртвый `RU:`;
/// call-site обязан показать это пользователю (он видит новый фильтр).
PrefixRewrite rewriteLiteralPrefix(
    String pattern, String oldPrefix, String newPrefix) {
  if (pattern.isEmpty || oldPrefix.isEmpty) {
    return (pattern: pattern, changed: false, ambiguous: false);
  }
  // Битый паттерн не трогаем вовсе: потребители читают его как «фильтр не
  // задан» (`tryCompileRegex` → null, инвариант safe_regex), а переписывание
  // могло бы случайно сделать его валидным — с чужим смыслом. Пользователю
  // всё равно сообщаем, если старый префикс там виден.
  if (tryCompileRegex(pattern, caseSensitive: false) == null) {
    return (
      pattern: pattern,
      changed: false,
      ambiguous: pattern.contains(oldPrefix),
    );
  }
  final atoms = _scan(pattern);
  if (atoms == null) {
    // Страховка: всё, что не разбирает [_scan] (висячий escape, незакрытый
    // класс), уже отсеяно гейтом компиляции выше. Ветка остаётся, чтобы
    // расхождение двух парсеров не превратилось в NPE на живом фильтре.
    return (
      pattern: pattern,
      changed: false,
      ambiguous: pattern.contains(oldPrefix),
    );
  }

  final replacement = newPrefix.isEmpty ? '' : RegExp.escape(newPrefix);
  final out = StringBuffer();
  var changed = false;
  var ambiguous = false;
  var i = 0;
  while (i < atoms.length) {
    final clean = _matchAt(atoms, i, oldPrefix, strict: true);
    if (clean != null) {
      out.write(replacement);
      changed = true;
      i = clean;
      continue;
    }
    // Чисто не вышло — но префикс здесь может ПРИСУТСТВОВАТЬ, просто
    // записанный конструкцией (`RU:?` — двоеточие опционально; `^RU[:]` —
    // класс из одного символа). Переписывать такое нельзя (угадаем не то),
    // а промолчать тем более нельзя: фильтр писался под старый префикс и
    // после смены перестанет ловить узлы.
    if (!ambiguous && _matchAt(atoms, i, oldPrefix, strict: false) != null) {
      ambiguous = true;
    }
    out.write(atoms[i].source);
    i++;
  }
  return (pattern: out.toString(), changed: changed, ambiguous: ambiguous);
}

/// Атом разобранного паттерна: кусок исходного текста [source], который
/// матчит ровно один символ. [literal] — этот символ, когда атом
/// ЛИТЕРАЛЬНЫЙ (обычная буква либо экранированный метасимвол `\.`, `\$`);
/// null — метасимвол, якорь, группа, квантор. [classChars] — набор символов
/// одиночного символьного класса (`[:]`, `[-_]`): не литерал, но известно,
/// что именно он может сматчить; нужен для распознавания почти-вхождений.
/// [quantified] — за атомом стоит квантор (`?`, `*`, `+`, `{n,m}`), то есть
/// его вклад в матч не фиксирован.
class _Atom {
  _Atom(this.source, this.literal, {this.classChars});
  final String source;
  final String? literal;
  final Set<String>? classChars;
  bool quantified = false;

  /// Атом может сматчить символ [c]. [strict] — только как жёсткий литерал
  /// без квантора: именно такие вхождения разрешено переписывать.
  bool canMatch(String c, {required bool strict}) {
    if (strict) return literal == c && !quantified;
    return literal == c || (classChars?.contains(c) ?? false);
  }
}

/// Индекс атома ЗА концом вхождения [prefix], начинающегося с атома [start].
/// null — вхождения нет. [strict] см. [_Atom.canMatch].
int? _matchAt(List<_Atom> atoms, int start, String prefix,
    {required bool strict}) {
  var ai = start;
  for (final want in prefix.split('')) {
    if (ai >= atoms.length) return null;
    if (!atoms[ai].canMatch(want, strict: strict)) return null;
    ai++;
  }
  // Квантор ПОСЛЕ последнего символа вхождения (`RU:?`) делает его
  // нежёстким: `?` уже проставил `quantified` на своём атоме в [_scan],
  // поэтому строгий проход выше отсеял такое сам.
  return ai;
}

/// Разложить regex на атомы. `null` — паттерн синтаксически не разобрался.
List<_Atom>? _scan(String p) {
  final atoms = <_Atom>[];
  var i = 0;
  while (i < p.length) {
    final c = p[i];
    switch (c) {
      case '\\':
        if (i + 1 >= p.length) return null; // висячий escape
        final n = p[i + 1];
        final src = '\\$n';
        // Экранированный метасимвол = литерал этого символа. Экранированная
        // буква/цифра — класс (`\d`, `\w`, `\b`, `\1`) либо управляющая
        // последовательность (`\n`): литералом не считаем.
        final isWordChar = RegExp(r'[A-Za-z0-9]').hasMatch(n);
        atoms.add(_Atom(src, isWordChar ? null : n));
        i += 2;
      case '[':
        final end = _classEnd(p, i);
        if (end < 0) return null;
        final src = p.substring(i, end + 1);
        atoms.add(_Atom(src, null, classChars: _classChars(src)));
        i = end + 1;
      case '(':
      case ')':
      case '|':
      case '^':
      case r'$':
      case '.':
        atoms.add(_Atom(c, null));
        i++;
      case '*':
      case '+':
      case '?':
        if (atoms.isNotEmpty) atoms.last.quantified = true;
        atoms.add(_Atom(c, null));
        i++;
      case '{':
        final end = p.indexOf('}', i);
        // `{` без пары — в Dart RegExp это литерал `{`. Атомом-литералом его
        // не делаем (в префиксе фигурные скобки — экзотика), но и паттерн не
        // роняем.
        if (end < 0) {
          atoms.add(_Atom(c, null));
          i++;
        } else {
          if (atoms.isNotEmpty) atoms.last.quantified = true;
          atoms.add(_Atom(p.substring(i, end + 1), null));
          i = end + 1;
        }
      default:
        atoms.add(_Atom(c, c));
        i++;
    }
  }
  return atoms;
}

/// Индекс закрывающей `]` символьного класса, начинающегося на [start].
/// `-1` — класс не закрыт.
int _classEnd(String p, int start) {
  var i = start + 1;
  if (i < p.length && p[i] == '^') i++;
  if (i < p.length && p[i] == ']') i++; // `[]]` — первая `]` литеральна
  while (i < p.length) {
    if (p[i] == '\\') {
      i += 2;
      continue;
    }
    if (p[i] == ']') return i;
    i++;
  }
  return -1;
}

/// Символы, перечисленные в символьном классе [src] (`[:]`, `[-_ ]`).
/// `null` — класс отрицающий (`[^…]`) или содержит диапазон/escape-класс:
/// его состав не перечислим, для распознавания почти-вхождения он бесполезен.
Set<String>? _classChars(String src) {
  var body = src.substring(1, src.length - 1);
  if (body.startsWith('^')) return null;
  if (body.contains(r'\')) return null; // \d, \w, \] — не перечисляем
  if (body.contains('-') && body.length > 1) return null; // возможен диапазон
  return body.split('').toSet();
}
