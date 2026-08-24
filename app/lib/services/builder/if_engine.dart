import 'dart:convert';

import '../../models/parser_config.dart';

/// §120 — typed template engine + `#if`-конструкт.
///
/// Единое ядро подстановки переменных и условных конструкций, общее для обоих
/// движков проекта:
///   • `_substituteVars` (build_config) — мутирует config на месте;
///   • `substituteVars` (preset_expand) — возвращает значение, тела пресетов.
///
/// Две части (неразделимы — `#if`-предикаты опираются на тип переменной):
///   1. **Типизация** — `coerceVarValue(raw, type)`: значение из state коэрсится
///      строго по объявленному `WizardVar.type`, а НЕ угадыванием по содержимому.
///   2. **`#if`** — декларативная условность: map-spread (условное поле объекта)
///      и array-element (условный элемент массива) + expression language.
///
/// Дизайн заимствован у singbox-launcher SPEC 067 (десктоп), адаптирован под
/// Dart. НЕ берём: `params[]`-механику, `@runtime.*` globals (одна платформа).

/// Sentinel: элемент/ключ должен быть удалён (optional-var → null, либо
/// array-element `#if` без else на false-ветке). Публичный — общий для движков.
class Dropped {
  const Dropped._();
  static const instance = Dropped._();
}

/// Верхняя граница `int`-var: sing-box принимает числовые поля (port,
/// tolerance) как `uint16`; значение вне диапазона роняет ядро на decode
/// (§161). MTU тоже укладывается (legal max ~9000 < 65535).
const int _intMax = 65535;

/// Коэрсит строковое значение переменной в типизированное по `type`.
///
/// `bool`/`int` — единственные коэрсящиеся типы, и только по ОБЪЯВЛЕННОМУ типу.
/// Остальные (`text`/`secret`/`enum`/`outbound`/`dns_servers`) — дословная
/// строка: даже если значение выглядит как `123`/`true`, оно остаётся строкой
/// (пароль `1234` не должен стать int — §120 корень).
dynamic coerceVarValue(String raw, String type) {
  switch (type) {
    case 'bool':
      // SPEC 103 (разрыв N12): сравнение с trim и без учёта регистра — канон
      // TEMPLATE_LANG §2.2. Строгое `raw == 'true'` расходилось с лаунчером на
      // значениях вида ' true ' / 'TRUE', которые приезжают из импорта бэкапа
      // и рукописных шаблонов: одна и та же настройка давала разный конфиг на
      // телефоне и на десктопе.
      return raw.trim().toLowerCase() == 'true';
    case 'int':
      // §161 backstop: clamp в uint16 [0, 65535]. Источник значения любой
      // (ручной ввод, импорт бэкапа, legacy) — конфиг никогда не получит int,
      // который ядро отвергнет как `uint16`. Не-число → строка (advisory).
      final n = int.tryParse(raw.trim());
      if (n == null) return raw;
      return n.clamp(0, _intMax);
    case 'text_list':
      // SPEC 103 (разрыв C6): тип ядра языка — построчный список
      // (TEMPLATE_LANG §2.2). До этого типа в Dart не было вовсе, и значение
      // уезжало в конфиг одной строкой с переводами строк внутри — там, где
      // ядро ждёт массив.
      return splitTextList(raw);
    default:
      return raw; // text/secret/enum/outbound/dns_servers + неизвестный тип
  }
}

/// Разбивает значение `text_list` на элементы: построчно, с trim каждой строки
/// и выбросом пустых. Пустое значение → пустой список (не null и не [""]).
List<String> splitTextList(String raw) => [
      for (final line in raw.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];

/// Коды warning'ов движка шаблонов (contract/registry/warnings.json).
/// Отдаются через [onTemplateWarning] — коды, а не отрендеренный текст
/// (CANON §6), чтобы сравнение с корпусом было языконезависимым.
const String templateWarnUnknownDirective = 'template_unknown_directive';
const String templateWarnVarUndeclared = 'template_var_undeclared';

/// Приёмник warning'ов движка. Глобальный хук, а не параметр каждой функции:
/// walk рекурсивен и вызывается из двух движков (build_config, preset_expand),
/// протаскивание накопителя через все уровни исказило бы их сигнатуры ради
/// диагностики. null (по умолчанию) — warning'и не собираются.
void Function(String code)? onTemplateWarning;

/// Кэш скомпилированных `#matches`-регэкспов по паттерну. RegExp immutable —
/// шарить безопасно даже при deepCopy шаблона. Никаких `RegExp(...)` per-node
/// внутри walker (§120 требование производительности).
final Map<String, RegExp> _matchCache = {};

RegExp _regexpFor(String pattern) =>
    _matchCache[pattern] ??= RegExp(pattern);

/// Резолвит var-ноды по имени. Значение — из `vars` (state+default, плоская
/// строка); тип — из `nodes[name].type`. Var без ноды → coerce как `text`
/// (строго строкой; legacy clash_api/secret безопасны).
typedef VarResolver = dynamic Function(String name);

/// Создаёт резолвер: `@name` → типизированное значение (или null если имя
/// не в `vars` — сигнал «оставить плейсхолдер / рекурсия»).
VarResolver makeResolver(
  Map<String, String> vars,
  Map<String, WizardVar> nodes,
) {
  return (String name) {
    final raw = vars[name];
    if (raw == null) return null;
    final node = nodes[name];
    return coerceVarValue(raw, node?.type ?? 'text');
  };
}

// ─────────────────────────────────────────────────────────────────────────
// #if walker
// ─────────────────────────────────────────────────────────────────────────

/// Сообщает, является ли ключ объекта условной конструкцией. JSON-объект не
/// может нести два одинаковых ключа (при разборе в Map выживает последний, а
/// первое условие молча теряется — проверено экспериментально), поэтому к
/// `#if` разрешён произвольный суффикс: `#if`, `#if1`, `#if 2`, `#if
/// tun-only` — все они равнозначны и позволяют повесить на один объект
/// несколько независимых условий, попутно давая условию человекочитаемое имя
/// (SPEC 103, паритет с singbox-launcher/core/template/substitute.go).
bool isIfKey(String k) => k == '#if' || k.startsWith('#if');

/// Возвращает условные ключи объекта в детерминированном (отсортированном)
/// порядке: несколько `#if…` на одном объекте применяются последовательно, и
/// порядок обязан быть воспроизводимым.
List<String> ifKeysSorted(Map<String, dynamic> m) {
  final keys = m.keys.where(isIfKey).toList();
  keys.sort();
  return keys;
}

/// Обходит JSON-дерево in-place, резолвя `@var`-плейсхолдеры (через [resolve])
/// и `#if`-конструкции. Top-down lazy: внешний `#if` выбирает ветку, рекурсия
/// идёт ТОЛЬКО в выбранную ветку (отброшенная не обходится). Single-pass.
///
/// Возвращает само значение, либо [Dropped.instance] если узел должен исчезнуть
/// (optional-var null, или array-element `#if` без else на false).
dynamic walk(dynamic node, VarResolver resolve) {
  if (node is String) {
    if (!node.startsWith('@')) return node;
    final name = node.substring(1);
    final v = resolve(name);
    if (v == null) {
      // Имя не объявлено → оставить плейсхолдер как есть (build_config-контракт).
      return node;
    }
    // Резолвер может вернуть Dropped (optional-var §033: имя известно, value
    // null) → элемент/ключ выпадает (preset_expand-контракт).
    if (identical(v, Dropped.instance)) return Dropped.instance;
    return v;
  }

  if (node is Map<String, dynamic>) {
    // Array-element mode обрабатывается в List-ветке (там виден single-key #if).
    // Здесь — map-spread: #if как ключ среди прочих.
    return _walkMap(node, resolve);
  }

  if (node is List) {
    return _walkList(node, resolve);
  }

  return node; // num/bool/null
}

/// SPEC 107 — читает ключевое слово движка в КАНОНИЧЕСКОЙ помеченной форме
/// (`#and`, `#or`, `#value`, `#else`) либо в легаси-форме без `#`.
///
/// Правило языка: `#` — ключевое слово движка, `@` — ссылка на переменную,
/// всё остальное — данные. До SPEC 107 оно выполнялось наполовину:
/// `#not`/`#in`/`#matches` были помечены, а `and`/`or`/`value`/`else` — нет,
/// хотя интерпретирует их тот же движок.
///
/// Легаси-форма читается бессрочно — существующие шаблоны не ломаются.
dynamic condKey(Map<String, dynamic> m, String word) =>
    m.containsKey('#$word') ? m['#$word'] : m[word];

bool hasCondKey(Map<String, dynamic> m, String word) =>
    m.containsKey('#$word') || m.containsKey(word);

/// Поверхностная проверка формы условия (§5.1) — только для диагностики:
/// вычисление всё равно fail-closed. Число/bool/null условием не являются.
bool condFormValid(dynamic cond) {
  if (cond is String || cond is List) return true;
  if (cond is Map<String, dynamic>) {
    final hasAnd = hasCondKey(cond, 'and');
    final hasOr = hasCondKey(cond, 'or');
    if (hasAnd && hasOr) return false; // ровно один из and/or
    if (hasAnd || hasOr) return true;
    return cond.length == 1; // предикат — ровно один ключ
  }
  return false;
}

/// SPEC 107 — ключ гейта существования узла. Суффиксы НЕ допускаются (в
/// отличие от `#if`): один гейт на узел, композиция — через and/or внутри
/// условия.
const String enableKey = '#enable';

dynamic _walkMap(Map<String, dynamic> obj, VarResolver resolve) {
  // 0) SPEC 107 — гейт #enable вычисляется ПЕРВЫМ, до #if и до обхода детей.
  // При false узел исчезает целиком, и внутри него ничего не вычисляется — ни
  // подстановок, ни warning'ов из вложенных веток.
  //
  // Обязательно ДО ветки unknownBang ниже: иначе ключ был бы выброшен как
  // неизвестная директива, а узел остался бы в конфиге ВСЕГДА — молчаливая
  // противоположность задуманному.
  if (obj.containsKey(enableKey)) {
    final gate = obj.remove(enableKey);
    // Невалидная грамматика условия — warning: узел молча исчезает из
    // конфига, и без сигнала причину не найти (паритет с Go).
    if (!condFormValid(gate)) {
      onTemplateWarning?.call(templateWarnUnknownDirective);
    }
    if (!evalCond(gate, resolve)) return Dropped.instance;
  }

  // 1) Собрать map-spread `#if…`-ключи (сортированные, детерминированный
  // порядок — их может быть несколько на одном объекте, SPEC 103) +
  // неизвестные #*-сиблинги.
  final ifKeys = ifKeysSorted(obj);
  final unknownBang = <String>[];
  for (final k in obj.keys) {
    if (!k.startsWith('#')) continue;
    if (isIfKey(k)) continue;
    unknownBang.add(k); // forward-compat: warn+drop (валидатор уже проверил)
  }
  for (final k in unknownBang) {
    obj.remove(k);
    // SPEC 103 (разрыв N10): факт выброса обязан быть виден, а не только
    // молча применён — иначе шаблон новой версии тихо теряет директиву на
    // старом движке, и понять это по конфигу невозможно.
    onTemplateWarning?.call(templateWarnUnknownDirective);
  }

  // 2) Резолвить обычные ключи (рекурсивно). #if…-ключи снимаем отдельно ниже.
  final toRemove = <String>[];
  for (final k in obj.keys.toList()) {
    if (isIfKey(k)) continue;
    final replaced = walk(obj[k], resolve);
    if (identical(replaced, Dropped.instance)) {
      toRemove.add(k);
    } else {
      obj[k] = replaced;
    }
  }
  for (final k in toRemove) {
    obj.remove(k);
  }

  // 3) Map-spread #if…: применить ВСЕ условные ключи последовательно в
  // отсортированном порядке — каждый выбирает ветку, резолвит её и мерджит
  // поля в obj, затем снимает свой ключ (паритет с Go substitute.go).
  for (final key in ifKeys) {
    final raw = obj[key];
    obj.remove(key);
    if (raw is! Map<String, dynamic>) continue;
    final branch = _selectBranch(raw, resolve); // Map | null (drop, no else)
    if (branch != null) {
      // branch уже прошёл walk внутри _selectBranch; мерджим поля в родителя.
      branch.forEach((k, v) {
        obj[k] = v; // коллизии отловлены на template-load; здесь last-wins
      });
    }
  }

  return obj;
}

dynamic _walkList(List<dynamic> list, VarResolver resolve) {
  final out = <dynamic>[];
  for (final elem in list) {
    // Array-element mode: элемент — объект ровно с одним ключом, и этот ключ
    // условный (`#if…` с произвольным суффиксом, SPEC 103).
    if (elem is Map<String, dynamic> && elem.length == 1) {
      final key = elem.keys.first;
      if (isIfKey(key)) {
        final body = elem[key];
        if (body is Map<String, dynamic>) {
          final taken = _selectArrayBranch(body, resolve);
          if (!identical(taken, Dropped.instance)) out.add(taken);
          continue;
        }
      }
    }
    // Голая ссылка "@list_var" в позиции элемента массива СПЛАЙСИТСЯ в
    // родительский массив, а не вкладывается: шаблон пишет
    // "address": ["@tun_address", {"#if": …}], и ядро ждёт там плоский список
    // CIDR. Без этого получается [["10.0.0.1/30"]] — ядро отвергает конфиг
    // («cannot unmarshal array into netip.Prefix»). Паритет с Go.
    if (elem is String && elem.startsWith('@')) {
      final value = resolve(elem.substring(1));
      if (value is List) {
        out.addAll(value);
        continue;
      }
    }
    final replaced = walk(elem, resolve);
    if (identical(replaced, Dropped.instance)) continue;
    out.add(replaced);
  }
  list
    ..clear()
    ..addAll(out);
  return list;
}

/// Map-spread branch: возвращает резолвленный объект `value`/`else`, либо null
/// (false без else → ничего не мерджить).
Map<String, dynamic>? _selectBranch(
  Map<String, dynamic> body,
  VarResolver resolve,
) {
  final ok = _evalCondition(body, resolve);
  final picked = ok ? condKey(body, 'value') : condKey(body, 'else');
  if (picked == null) {
    // Условие истинно, но обязательной ветки value нет (§4.1) — конструкция
    // пропускается + warning. Отсутствие else на false-ветке — штатный случай
    // «не мерджить», он молчит.
    if (ok) onTemplateWarning?.call(templateWarnUnknownDirective);
    return null;
  }
  // Резолвим ТОЛЬКО выбранную ветку (lazy). value — объект (валидатор проверил).
  final walked = walk(_clone(picked), resolve);
  return walked is Map<String, dynamic> ? walked : null;
}

/// Array-element branch: возвращает резолвленный `value`/`else` (любой тип),
/// либо [Dropped.instance] (false без else → элемент выпадает).
dynamic _selectArrayBranch(Map<String, dynamic> body, VarResolver resolve) {
  final ok = _evalCondition(body, resolve);
  if (ok) {
    return walk(_clone(condKey(body, 'value')), resolve);
  }
  if (hasCondKey(body, 'else')) {
    return walk(_clone(condKey(body, 'else')), resolve);
  }
  return Dropped.instance;
}

/// §232 — вычисляет одиночный `{"#if": {...}}`-узел до его СКАЛЯРНОГО
/// value/else. Нужен для `on_change.set`: bare-Map, скормленный [walk],
/// уходит в map-spread режим и схлопывает скаляр в `{}` (ветка мержится
/// в родителя, скаляр мержить некуда). Здесь — тот же array-element путь
/// ([_selectArrayBranch]), который отдаёт ветку любого типа.
///
/// Возвращает null, если узел не `{"#if": ...}`, ветка выпала (false без
/// else) или разрезолвилась не в скаляр-строку.
String? evalIfScalar(Map<String, dynamic> node, VarResolver resolve) {
  if (node.length != 1) return null;
  final key = node.keys.first;
  if (!isIfKey(key)) return null;
  final body = node[key];
  if (body is! Map<String, dynamic>) return null;
  final picked = _selectArrayBranch(body, resolve);
  return picked is String ? picked : null;
}

// ─────────────────────────────────────────────────────────────────────────
// Expression language — predicates
// ─────────────────────────────────────────────────────────────────────────

/// Вычисляет условие `#if`-тела: ровно один из `and`/`or`. Short-circuit.
bool _evalCondition(Map<String, dynamic> body, VarResolver resolve) {
  final and = condKey(body, 'and');
  final or = condKey(body, 'or');
  // Грамматика §4.1: ровно один из and/or. Оба или ни одного — невалидная
  // форма: условие ложно (ветка не включается) + warning, чтобы ошибка была
  // видна, а не только применена (SPEC 103, разрыв C3 — паритет с лаунчером).
  if ((and is List) == (or is List)) {
    onTemplateWarning?.call(templateWarnUnknownDirective);
    return false;
  }
  if (and is List) {
    for (final p in and) {
      // SPEC 107: элемент — предикат ИЛИ вложенный cond-obj (снят запрет
      // D-018). Глубина не ограничена.
      if (!evalCond(p, resolve)) return false; // short-circuit
    }
    return true;
  }
  for (final p in or as List) {
    if (evalCond(p, resolve)) return true; // short-circuit
  }
  return false;
}

/// SPEC 107 — вычисляет ЛЮБОЕ условие языка (§5.1):
///
///     cond := pred-list | cond-obj | pred
///
/// Сахар: голый список ≡ `{"and": [...]}`; одиночный предикат ≡ список из
/// одного. Единая точка для `#if`, `#enable` и гейтов носителей — параллельных
/// грамматик в языке нет.
bool evalCond(dynamic cond, VarResolver resolve) {
  if (cond is List) {
    for (final e in cond) {
      if (!evalCond(e, resolve)) return false;
    }
    return true; // пустой список ≡ пустой and → вырожденно истинен
  }
  if (cond is Map<String, dynamic>) {
    // Объект с and/or — cond-obj. Случай «оба ключа сразу» тоже сюда: его
    // отвергает _evalCondition (fail-closed + warning), а не молча трактует
    // как предикат.
    if (hasCondKey(cond, 'and') || hasCondKey(cond, 'or')) {
      return _evalCondition(cond, resolve);
    }
  }
  return _evalPredicate(cond, resolve);
}

/// Вычисляет один предикат. Формы (см. §120 spec):
///   "@var"                       → bool-var == true
///   {"@var": "literal"}          → equality (RHS проходит @var-подстановку)
///   {"@var": "#notEmpty"/"#isEmpty"}  → семантика по объявленному типу
///   {"@var": {"#in":[...]}}       / {"#notIn":[...]} / {"#matches":"re"}
///   {"#not": predicate}          → негация
bool _evalPredicate(dynamic pred, VarResolver resolve) {
  // bare bool-var
  if (pred is String) {
    // Предикат, записанный СТРОКОЙ с JSON (`"{\"@runtime.target\":\"local\"}"`,
    // SPEC 097) — разбираем и вычисляем как узел, чтобы форма работала
    // одинаково в обоих движках.
    final parsed = parseJsonPredicateString(pred);
    if (parsed != null) return evalCond(parsed, resolve);
    final name = _varName(pred);
    if (name == null) return false;
    // SPEC 103 (разрыв C1): trim + case-insensitive, как в лаунчере.
    return _scalar(resolve(name)).trim().toLowerCase() == 'true';
  }

  if (pred is Map<String, dynamic>) {
    // негация
    final notInner = pred['#not'];
    if (pred.containsKey('#not')) {
      // SPEC 107: отрицание ЛЮБОГО условия, включая and/or.
      return !evalCond(notInner, resolve);
    }

    // single-key `{"@var": arg}`
    if (pred.length == 1) {
      final key = pred.keys.first;
      final name = _varName(key);
      if (name == null) return false;
      final arg = pred[key];
      final resolvedValue = resolve(name);
      final scalar = _scalar(resolvedValue);

      if (arg is String) {
        // SPEC 103 (разрыв C2): #notEmpty/#isEmpty смотрят на ЗНАЧЕНИЕ по
        // объявленному типу, а не на длину его строкового вида. Иначе
        // bool-переменная со значением false («false» — непустая строка)
        // считалась заполненной, и условие всегда было истинным.
        if (arg == '#notEmpty') return _isNotEmptyTyped(resolvedValue, scalar);
        if (arg == '#isEmpty') return !_isNotEmptyTyped(resolvedValue, scalar);
        // equality; RHS проходит @var-подстановку (разрыв C8) — форма
        // {"@a": "@b"} сравнивает две переменные, а не переменную с литералом.
        return scalar.trim() == _substRhs(arg, resolve);
      }
      if (arg is Map<String, dynamic> && arg.length == 1) {
        final op = arg.keys.first;
        final opArg = arg[op];
        switch (op) {
          case '#in':
            return _inList(scalar.trim(), opArg, resolve);
          case '#notIn':
            return !_inList(scalar.trim(), opArg, resolve);
          case '#matches':
            if (opArg is! String) return false;
            return _regexpFor(_substRhs(opArg, resolve))
                .hasMatch(scalar.trim());
        }
      }
    }
  }
  return false; // unknown shape — валидатор ловит на load
}

/// Разбирает предикат, записанный строкой с JSON. Не-JSON строки (обычные
/// "@var") дают null.
dynamic parseJsonPredicateString(String s) {
  final t = s.trim();
  if (!t.startsWith('{')) return null;
  try {
    return jsonDecode(t);
  } catch (_) {
    return null;
  }
}

/// `@name` → `name`; иначе null (плейсхолдеры предиката всегда `@`-form).
String? _varName(String ref) =>
    ref.startsWith('@') ? ref.substring(1) : null;

/// SPEC 103 (разрыв C8): правая часть предиката проходит @var-подстановку.
/// Строка, целиком равная `"@name"`, заменяется значением переменной; всё
/// остальное — литерал как есть. Неизвестное имя оставляет строку нетронутой
/// (сравнение с плейсхолдером даст false, а не ложное совпадение).
String _substRhs(String rhs, VarResolver resolve) {
  final name = _varName(rhs);
  if (name == null) return rhs;
  final v = resolve(name);
  if (v == null || identical(v, Dropped.instance)) return rhs;
  return _scalar(v).trim();
}

/// SPEC 103 (разрыв C2): семантика `#notEmpty` по типу значения, а не по длине
/// его строкового вида — bool-переменная пуста при `false`, список пуст при
/// нулевой длине, строка — при пустом trim.
bool _isNotEmptyTyped(dynamic value, String scalar) {
  if (value == null || identical(value, Dropped.instance)) return false;
  if (value is bool) return value;
  if (value is List) return value.isNotEmpty;
  return scalar.trim().isNotEmpty;
}

/// SPEC 103 (разрывы C6+C8): принадлежность множеству. Аргумент — список
/// (каждый элемент проходит @var-подстановку) ИЛИ строка `"@text_list_var"`,
/// сравниваемая с элементами списка.
bool _inList(String needle, dynamic arg, VarResolver resolve) {
  if (arg is List) {
    for (final e in arg) {
      if (e is String && _substRhs(e, resolve) == needle) return true;
      if (e is! String && _scalar(e).trim() == needle) return true;
    }
    return false;
  }
  if (arg is String) {
    // Строковая форма: ссылка на text_list-переменную.
    final name = _varName(arg);
    if (name == null) return arg.trim() == needle;
    final v = resolve(name);
    if (v is List) return v.map((e) => _scalar(e).trim()).contains(needle);
    if (v == null || identical(v, Dropped.instance)) return false;
    return _scalar(v).trim() == needle;
  }
  return false;
}

/// Скалярное строковое представление резолвленного значения для сравнений.
/// bool true/false → "true"/"false"; int → строка; String → как есть.
String _scalar(dynamic v) {
  if (v == null) return '';
  if (v is bool) return v ? 'true' : 'false';
  return v.toString();
}

/// Глубокая копия JSON-узла (Map/List/scalar) — выбранная ветка `#if` клонится
/// перед walk, чтобы шаблонный источник не мутировался (важно: walk in-place).
dynamic _clone(dynamic node) {
  if (node is Map) {
    return <String, dynamic>{
      for (final e in node.entries) e.key as String: _clone(e.value),
    };
  }
  if (node is List) {
    return <dynamic>[for (final e in node) _clone(e)];
  }
  return node;
}

// ─────────────────────────────────────────────────────────────────────────
// Template-load валидация #if (§120)
// ─────────────────────────────────────────────────────────────────────────

/// Бросается при кривом `#if`/предикате в шаблоне на load. Шаблон зашит в
/// asset → это баг разработчика (или несовместимый custom-шаблон), не runtime
/// юзера. Ловится тестами/на старте, не молча даёт битый конфиг.
class TemplateIfError implements Exception {
  final String message;
  TemplateIfError(this.message);
  @override
  String toString() => 'TemplateIfError: $message';
}

/// Известные no-arg / arg-taking предикат-операторы (для разграничения
/// «неизвестный оператор → error» от forward-compat «неизвестный сиблинг»).
const _noArgPredicates = {'#notEmpty', '#isEmpty'};
const _argPredicates = {'#in', '#notIn', '#matches'};

/// Рекурсивно валидирует все `#if`-конструкции в [node] против объявленных
/// var-нод [byName]. Бросает [TemplateIfError] на первой проблеме.
///
/// [path] — JSON-путь для сообщения (напр. `config.inbounds[1]`).
void validateIfConstructs(
  dynamic node,
  Map<String, WizardVar> byName, {
  String path = 'config',
}) {
  if (node is Map<String, dynamic>) {
    for (final entry in node.entries) {
      final k = entry.key;
      if (isIfKey(k)) {
        _validateIfBody(entry.value, byName, '$path.$k');
        // тело #if… валидируется (включая вложенные #if в value/else)
        continue;
      }
      if (k == enableKey) {
        // SPEC 107 (D4) — гейт существования узла: ПОЛНЫЙ язык условий, но
        // без value/else. Обязан проверяться ДО forward-compat-ветки ниже:
        // иначе опечатка в имени переменной, оба ключа and+or сразу или
        // скаляр вместо условия грузятся молча, узел fail-closed выпадает из
        // конфига, и пользователь узнаёт об ошибке только по отсутствующей
        // функции. Ровно тот же класс разрыва, что Go закрыл в 6d43114 для
        // секции config.
        validateCondNode(entry.value, byName, '$path.$k');
        continue;
      }
      if (k.startsWith('#')) {
        // Сиблинг #if в map-spread, не "#if…" и не "#enable" →
        // forward-compat warn+drop в runtime, не ошибка на load.
        continue;
      }
      validateIfConstructs(entry.value, byName, path: '$path.$k');
    }
    return;
  }
  if (node is List) {
    for (var i = 0; i < node.length; i++) {
      validateIfConstructs(node[i], byName, path: '$path[$i]');
    }
  }
}

/// Валидирует ПОЛНОЕ условие языка (§5.1) — зеркало [evalCond]:
///
///     cond := pred-list | cond-obj | pred
///
/// Используется телом `#enable` (гейта, у которого нет `value`/`else`) и
/// вложенными условиями внутри predicate-списков. Публичная — по ней стоит
/// рубеж load-валидации гейтов, и её зовут тесты напрямую.
void validateCondNode(
  dynamic cond,
  Map<String, WizardVar> byName,
  String path,
) {
  // Сахар: голый список ≡ `{"#and": [...]}`.
  if (cond is List) {
    if (cond.isEmpty) {
      throw TemplateIfError('$path: список предикатов должен быть непустым');
    }
    for (var i = 0; i < cond.length; i++) {
      _validatePredicate(cond[i], byName, '$path[$i]');
    }
    return;
  }
  if (cond is Map<String, dynamic>) {
    if (hasCondKey(cond, 'and') || hasCondKey(cond, 'or')) {
      _validateCondObjLists(cond, byName, path);
      return;
    }
    _validatePredicate(cond, byName, path);
    return;
  }
  // Скаляр (число/bool/null) условием не является: рантайм fail-closed гасит
  // узел молча — на load это ошибка.
  _validatePredicate(cond, byName, path);
}

/// and/or-часть условия-объекта: ровно один из ключей, значение — непустой
/// список валидных предикатов. Общая часть [_validateIfBody] (у `#if` сверх
/// этого есть `value`/`else`) и [validateCondNode] (у `#enable` их нет).
void _validateCondObjLists(
  Map<String, dynamic> body,
  Map<String, WizardVar> byName,
  String path,
) {
  // SPEC 107: ключевые слова читаются в обеих формах — канонической `#and`/
  // `#or` и легаси без `#`. Валидатор обязан знать обе, иначе канонический
  // шаблон не загрузится вовсе.
  final hasAnd = hasCondKey(body, 'and');
  final hasOr = hasCondKey(body, 'or');
  if (hasAnd == hasOr) {
    throw TemplateIfError(
        '$path: ровно один из `and`/`or` обязателен (есть оба или ни одного)');
  }
  final word = hasAnd ? 'and' : 'or';
  final list = condKey(body, word);
  if (list is! List || list.isEmpty) {
    throw TemplateIfError('$path: `$word` должен быть непустым списком');
  }
  for (var i = 0; i < list.length; i++) {
    _validatePredicate(list[i], byName, '$path.$word[$i]');
  }
}

void _validateIfBody(
  dynamic body,
  Map<String, WizardVar> byName,
  String path,
) {
  if (body is! Map<String, dynamic>) {
    throw TemplateIfError('$path: тело #if должно быть объектом');
  }
  _validateCondObjLists(body, byName, path);
  if (!hasCondKey(body, 'value')) {
    throw TemplateIfError('$path: `value` обязателен');
  }
  // Закрытая схема тела: and/or/value/else в канонической помеченной форме
  // (`#and`, `#or`, `#value`, `#else`, SPEC 107) либо в легаси без `#`.
  const allowed = {
    'and', 'or', 'value', 'else',
    '#and', '#or', '#value', '#else',
  };
  for (final k in body.keys) {
    if (!allowed.contains(k)) {
      throw TemplateIfError(
          '$path: неизвестный inner-ключ `$k` (схема тела #if закрыта: '
          '#and/#or/#value/#else, легаси — без `#`)');
    }
  }
  // Рекурсия в value/else (вложенные #if).
  validateIfConstructs(condKey(body, 'value'), byName, path: '$path.value');
  if (hasCondKey(body, 'else')) {
    validateIfConstructs(condKey(body, 'else'), byName, path: '$path.else');
  }
}

void _validatePredicate(
  dynamic pred,
  Map<String, WizardVar> byName,
  String path,
) {
  // bare bool-var
  if (pred is String) {
    // Предикат, записанный СТРОКОЙ с JSON (SPEC 097): рантайм
    // (`_evalPredicate`) её разбирает и вычисляет как узел — валидатор обязан
    // делать то же, а не браковать строку как «не @-имя».
    final parsed = parseJsonPredicateString(pred);
    if (parsed != null) {
      validateCondNode(parsed, byName, path);
      return;
    }
    final name = _varName(pred);
    if (name == null) {
      throw TemplateIfError('$path: предикат-строка должна быть `@var`-формой');
    }
    final node = _requireVar(byName, name, path);
    if (node.type != 'bool') {
      throw TemplateIfError(
          '$path: bare-предикат `@$name` допустим только для bool-var (тип `${node.type}`)');
    }
    return;
  }

  if (pred is Map<String, dynamic>) {
    // SPEC 107 (снятие D-018): элемент predicate-списка может быть вложенным
    // условием-объектом `{"#and": […]}` / `{"#or": […]}` на любую глубину —
    // рантайм (evalCond → _evalCondition) это исполняет, и валидатор не
    // вправе браковать рабочую запись.
    if (hasCondKey(pred, 'and') || hasCondKey(pred, 'or')) {
      _validateCondObjLists(pred, byName, path);
      return;
    }
    // негация
    if (pred.containsKey('#not')) {
      if (pred.length != 1) {
        throw TemplateIfError('$path: `#not` должен быть единственным ключом');
      }
      // `#not` отрицает ЛЮБОЕ условие, включая and/or (зеркало
      // `_evalPredicate`, который зовёт evalCond на внутренность).
      validateCondNode(pred['#not'], byName, '$path.#not');
      return;
    }
    if (pred.length != 1) {
      throw TemplateIfError(
          '$path: предикат-объект должен иметь ровно один ключ `@var`');
    }
    final key = pred.keys.first;
    final name = _varName(key);
    if (name == null) {
      throw TemplateIfError('$path: ключ предиката `$key` должен быть `@var`');
    }
    final node = _requireVar(byName, name, path);
    final arg = pred[key];

    if (arg is String) {
      if (_noArgPredicates.contains(arg)) {
        // #notEmpty/#isEmpty — text/secret/enum/bool (read-only длина)
        return;
      }
      if (arg.startsWith('#')) {
        throw TemplateIfError(
            '$path: неизвестный no-arg предикат-оператор `$arg`');
      }
      // equality literal — для text/enum (не bool: bool через bare-форму)
      if (node.type == 'bool') {
        throw TemplateIfError(
            '$path: equality `{@$name: "$arg"}` не для bool-var (используй bare `@$name`)');
      }
      return;
    }
    if (arg is Map<String, dynamic> && arg.length == 1) {
      final op = arg.keys.first;
      if (!_argPredicates.contains(op)) {
        throw TemplateIfError('$path: неизвестный предикат-оператор `$op`');
      }
      if (node.type == 'bool') {
        throw TemplateIfError('$path: `$op` не для bool-var `@$name`');
      }
      final opArg = arg[op];
      if (op == '#matches') {
        if (opArg is! String) {
          throw TemplateIfError('$path: `#matches` ожидает строку-regexp');
        }
        try {
          _regexpFor(opArg);
        } on FormatException catch (e) {
          throw TemplateIfError('$path: невалидный `#matches` regexp: $e');
        }
      } else if (opArg is String) {
        // SPEC 103 (разрыв C6): строковая форма `{"#in": "@list"}` — ссылка на
        // text_list-переменную. Рантайм её ИСПОЛНЯЕТ (`_inList`, ветка
        // `arg is String`), значит валидатор не вправе браковать — иначе
        // валидатор строже собственного движка, и законный шаблон не грузится
        // (корпус: predicates/p4_in_text_list_string_form; Go принимает).
        final ref = _varName(opArg);
        if (ref != null) _requireVar(byName, ref, path);
      } else if (opArg is! List) {
        throw TemplateIfError('$path: `$op` ожидает список аргументов');
      }
      return;
    }
    throw TemplateIfError('$path: нераспознанная форма предиката');
  }
  throw TemplateIfError('$path: предикат должен быть строкой или объектом');
}

WizardVar _requireVar(
  Map<String, WizardVar> byName,
  String name,
  String path,
) {
  final node = byName[name];
  if (node == null) {
    throw TemplateIfError(
        '$path: предикат ссылается на необъявленную var `@$name` (нужна WizardVar-нода)');
  }
  return node;
}

// ─────────────────────────────────────────────────────────────────────────
// Зависимости условия (SPEC 107 §8.1, D-066)
// ─────────────────────────────────────────────────────────────────────────

/// Возвращает отсортированное множество имён переменных, от которых зависит
/// условие — статически, без вычисления.
///
/// На этом стоит реактивный пересчёт: индекс `переменная → узлы` строится один
/// раз при загрузке шаблона, и узел обновляется ТОЛЬКО когда меняется то, от
/// чего он зависит.
///
/// Имена — без ведущего `@`. Globals попадают полными именами
/// (`runtime.platform`): это зависимости, а не константы — на вкладке Target
/// платформа меняется селектором.
///
/// ВАЖНО: собираются имена ВСЕГО дерева, включая ветки, до которых вычисление
/// не дойдёт из-за short-circuit. Завтра значение изменится, выбор ветки
/// станет другим — подписка обязана существовать уже сегодня.
///
/// Функция нормативна: тот же набор проверяет Go (`corpus/template/deps/`).
List<String> condDeps(dynamic cond) {
  final set = <String>{};
  _collectCondDeps(cond, set);
  final out = set.toList()..sort();
  return out;
}

void _collectCondDeps(dynamic cond, Set<String> set) {
  if (cond is List) {
    for (final e in cond) {
      _collectCondDeps(e, set);
    }
    return;
  }
  if (cond is Map<String, dynamic>) {
    final and = condKey(cond, 'and');
    if (and is List) {
      for (final e in and) {
        _collectCondDeps(e, set);
      }
      return;
    }
    final or = condKey(cond, 'or');
    if (or is List) {
      for (final e in or) {
        _collectCondDeps(e, set);
      }
      return;
    }
    _collectPredicateDeps(cond, set);
    return;
  }
  if (cond is String) {
    // Предикат, записанный строкой с JSON (SPEC 097-форма).
    final parsed = parseJsonPredicateString(cond);
    if (parsed != null) {
      _collectCondDeps(parsed, set);
      return;
    }
    _noteVarName(cond, set);
  }
}

void _collectPredicateDeps(Map<String, dynamic> p, Set<String> set) {
  p.forEach((k, v) {
    if (k == '#not') {
      _collectCondDeps(v, set); // отрицание любого условия
      return;
    }
    _noteVarName(k, set); // левая часть {"@var": …}
    _collectRhsDeps(v, set);
  });
}

/// Ссылки правой части предиката: равенство с другой переменной, элементы
/// `#in`/`#notIn`, строковая форма `#in` (`"@list"`), паттерн `#matches`.
void _collectRhsDeps(dynamic rhs, Set<String> set) {
  if (rhs is String) {
    // "#notEmpty"/"#isEmpty" — не ссылки.
    if (!rhs.startsWith('#')) _noteVarName(rhs, set);
    return;
  }
  if (rhs is List) {
    for (final e in rhs) {
      _collectRhsDeps(e, set);
    }
    return;
  }
  if (rhs is Map<String, dynamic>) {
    for (final arg in rhs.values) {
      _collectRhsDeps(arg, set);
    }
  }
}

void _noteVarName(String ref, Set<String> set) {
  if (!ref.startsWith('@')) return;
  final name = ref.substring(1);
  if (name.isEmpty || name.contains('@')) return;
  set.add(name);
}
