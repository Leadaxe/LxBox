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
      return raw == 'true'; // строго; 'false'/прочее → false
    case 'int':
      // §161 backstop: clamp в uint16 [0, 65535]. Источник значения любой
      // (ручной ввод, импорт бэкапа, legacy) — конфиг никогда не получит int,
      // который ядро отвергнет как `uint16`. Не-число → строка (advisory).
      final n = int.tryParse(raw);
      if (n == null) return raw;
      return n.clamp(0, _intMax);
    default:
      return raw; // text/secret/enum/outbound/dns_servers + неизвестный тип
  }
}

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

dynamic _walkMap(Map<String, dynamic> obj, VarResolver resolve) {
  // 1) Собрать map-spread #if (ключ "#if") + неизвестные #*-сиблинги.
  Map<String, dynamic>? ifBody;
  final unknownBang = <String>[];
  for (final k in obj.keys) {
    if (!k.startsWith('#')) continue;
    if (k == '#if') {
      final raw = obj[k];
      if (raw is Map<String, dynamic>) ifBody = raw;
    } else {
      unknownBang.add(k); // forward-compat: warn+drop (валидатор уже проверил)
    }
  }
  for (final k in unknownBang) {
    obj.remove(k);
  }

  // 2) Резолвить обычные ключи (рекурсивно). #if снимаем отдельно ниже.
  final toRemove = <String>[];
  for (final k in obj.keys.toList()) {
    if (k == '#if') continue;
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

  // 3) Map-spread #if: выбрать ветку, резолвить её, мерджить поля в obj.
  if (ifBody != null) {
    obj.remove('#if');
    final branch = _selectBranch(ifBody, resolve); // Map | null (drop, no else)
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
    // Array-element mode: элемент — объект РОВНО с одним ключом "#if".
    if (elem is Map<String, dynamic> &&
        elem.length == 1 &&
        elem.containsKey('#if')) {
      final body = elem['#if'];
      if (body is Map<String, dynamic>) {
        final taken = _selectArrayBranch(body, resolve);
        if (!identical(taken, Dropped.instance)) out.add(taken);
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
  final picked = ok ? body['value'] : body['else'];
  if (picked == null) return null;
  // Резолвим ТОЛЬКО выбранную ветку (lazy). value — объект (валидатор проверил).
  final walked = walk(_clone(picked), resolve);
  return walked is Map<String, dynamic> ? walked : null;
}

/// Array-element branch: возвращает резолвленный `value`/`else` (любой тип),
/// либо [Dropped.instance] (false без else → элемент выпадает).
dynamic _selectArrayBranch(Map<String, dynamic> body, VarResolver resolve) {
  final ok = _evalCondition(body, resolve);
  if (ok) {
    return walk(_clone(body['value']), resolve);
  }
  if (body.containsKey('else')) {
    return walk(_clone(body['else']), resolve);
  }
  return Dropped.instance;
}

// ─────────────────────────────────────────────────────────────────────────
// Expression language — predicates
// ─────────────────────────────────────────────────────────────────────────

/// Вычисляет условие `#if`-тела: ровно один из `and`/`or`. Short-circuit.
bool _evalCondition(Map<String, dynamic> body, VarResolver resolve) {
  final and = body['and'];
  if (and is List) {
    for (final p in and) {
      if (!_evalPredicate(p, resolve)) return false; // short-circuit
    }
    return true;
  }
  final or = body['or'];
  if (or is List) {
    for (final p in or) {
      if (_evalPredicate(p, resolve)) return true; // short-circuit
    }
    return false;
  }
  return false; // defensive: ни and ни or (валидатор ловит на load)
}

/// Вычисляет один предикат. Формы (см. §120 spec):
///   "@var"                       → bool-var == true
///   {"@var": "literal"}          → equality
///   {"@var": "#notEmpty"/"#isEmpty"}
///   {"@var": {"#in":[...]}}       / {"#notIn":[...]} / {"#matches":"re"}
///   {"#not": predicate}          → негация
bool _evalPredicate(dynamic pred, VarResolver resolve) {
  // bare bool-var
  if (pred is String) {
    final name = _varName(pred);
    if (name == null) return false;
    return _scalar(resolve(name)) == 'true';
  }

  if (pred is Map<String, dynamic>) {
    // негация
    final notInner = pred['#not'];
    if (pred.containsKey('#not')) {
      return !_evalPredicate(notInner, resolve);
    }

    // single-key `{"@var": arg}`
    if (pred.length == 1) {
      final key = pred.keys.first;
      final name = _varName(key);
      if (name == null) return false;
      final arg = pred[key];
      final scalar = _scalar(resolve(name));

      if (arg is String) {
        if (arg == '#notEmpty') return scalar.trim().isNotEmpty;
        if (arg == '#isEmpty') return scalar.trim().isEmpty;
        // equality (literal не начинается с '#' — валидатор гарантирует)
        return scalar.trim() == arg;
      }
      if (arg is Map<String, dynamic> && arg.length == 1) {
        final op = arg.keys.first;
        final opArg = arg[op];
        switch (op) {
          case '#in':
            return opArg is List && opArg.contains(scalar.trim());
          case '#notIn':
            return !(opArg is List && opArg.contains(scalar.trim()));
          case '#matches':
            return opArg is String && _regexpFor(opArg).hasMatch(scalar.trim());
        }
      }
    }
  }
  return false; // unknown shape — валидатор ловит на load
}

/// `@name` → `name`; иначе null (плейсхолдеры предиката всегда `@`-form).
String? _varName(String ref) =>
    ref.startsWith('@') ? ref.substring(1) : null;

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
      if (k == '#if') {
        _validateIfBody(entry.value, byName, '$path.#if');
        // тело #if валидируется (включая вложенные #if в value/else)
        continue;
      }
      if (k.startsWith('#')) {
        // Сиблинг #if в map-spread, не "#if" → forward-compat warn+drop в
        // runtime, не ошибка на load.
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

void _validateIfBody(
  dynamic body,
  Map<String, WizardVar> byName,
  String path,
) {
  if (body is! Map<String, dynamic>) {
    throw TemplateIfError('$path: тело #if должно быть объектом');
  }
  final hasAnd = body['and'] != null;
  final hasOr = body['or'] != null;
  if (hasAnd == hasOr) {
    throw TemplateIfError(
        '$path: ровно один из `and`/`or` обязателен (есть оба или ни одного)');
  }
  final list = (hasAnd ? body['and'] : body['or']);
  if (list is! List || list.isEmpty) {
    throw TemplateIfError(
        '$path: `${hasAnd ? 'and' : 'or'}` должен быть непустым списком');
  }
  if (!body.containsKey('value')) {
    throw TemplateIfError('$path: `value` обязателен');
  }
  // Закрытая схема тела: только and/or/value/else.
  for (final k in body.keys) {
    if (k != 'and' && k != 'or' && k != 'value' && k != 'else') {
      throw TemplateIfError(
          '$path: неизвестный inner-ключ `$k` (схема тела #if закрыта: and/or/value/else)');
    }
  }
  // Предикаты.
  for (var i = 0; i < list.length; i++) {
    _validatePredicate(list[i], byName, '$path.${hasAnd ? 'and' : 'or'}[$i]');
  }
  // Рекурсия в value/else (вложенные #if).
  validateIfConstructs(body['value'], byName, path: '$path.value');
  if (body.containsKey('else')) {
    validateIfConstructs(body['else'], byName, path: '$path.else');
  }
}

void _validatePredicate(
  dynamic pred,
  Map<String, WizardVar> byName,
  String path,
) {
  // bare bool-var
  if (pred is String) {
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
    // негация
    if (pred.containsKey('#not')) {
      if (pred.length != 1) {
        throw TemplateIfError('$path: `#not` должен быть единственным ключом');
      }
      _validatePredicate(pred['#not'], byName, '$path.#not');
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
