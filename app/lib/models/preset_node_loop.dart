/// §643 (контракт 1.1.119, TEMPLATE_LANG §6.5–§6.7, D-130/D-131) — обход
/// узлов пресета: модель и структурный разбор по закрытым спискам ключей.
///
/// Заменил `for_each` §578. Условие `#filter` здесь не проверяется — его
/// валидирует загрузчик шаблона против объявленных имён
/// (`parsePresetNodeLoop` в `services/builder/preset_node_loop.dart`).
library;

import '../services/builder/if_engine.dart' show IfForm, isIfKey, normalizeIfForm;

/// Вид обхода: ключ `for_each_node` (тело на каждый узел, `@node` в scope)
/// или `for_each_node_do` (сбор значений по узлам, тело один раз после
/// обхода, без `@node`).
enum PresetNodeLoopKind { node, nodeDo }

/// `#final` (§6.7.2) — преобразование собранного списка после обхода.
/// Порядок применения задан нормой, а не порядком ключей JSON:
/// [unique] → [sort] → [limit].
class PresetLoopFinal {
  const PresetLoopFinal({this.unique = false, this.sort = false, this.limit});

  final bool unique;
  final bool sort;

  /// Первые N элементов; null — без ограничения.
  final int? limit;
}

/// §656 (контракт 1.1.125, TEMPLATE_LANG §6.7.1) — операция `#do` под
/// условием: `{"#if…": [cond, {"#append": …}, {"#append": …}?]}` (или
/// длинная форма). Ветки уже проверены разбором ([PresetNodeLoop.parse]):
/// каждая — ровно один глагол `#append` с правой частью нормы.
class PresetDoIf {
  const PresetDoIf({required this.ifKey, required this.form, required this.raw});

  /// Ключ `#if…` операции (для предупреждений и валидации условия).
  final String ifKey;

  /// Нормализованная форма ([normalizeIfForm]).
  final IfForm form;

  /// Значение ключа как в шаблоне — для load-валидации условия.
  final Object raw;
}

/// Обход узлов пресета.
///
/// [filter] — условие языка `#if` (§4.1–4.2) без обёртки, null — истина;
/// [collect] — `#do`: имя переменной пресета (без `@`) → правая часть
/// `#append` (строка-ссылка или `{"#tpl": …}`) либо [PresetDoIf] — операция
/// под условием (§656); [finals] — `#final` по
/// именам из [collect]. У [PresetNodeLoopKind.node] [collect] и [finals]
/// пусты.
class PresetNodeLoop {
  const PresetNodeLoop({
    required this.kind,
    this.filter,
    this.collect = const {},
    this.finals = const {},
  });

  final PresetNodeLoopKind kind;
  final Object? filter;
  final Map<String, Object> collect;
  final Map<String, PresetLoopFinal> finals;

  bool get isNode => kind == PresetNodeLoopKind.node;
  bool get isNodeDo => kind == PresetNodeLoopKind.nodeDo;

  /// Ключи пресета.
  static const String keyNode = 'for_each_node';
  static const String keyNodeDo = 'for_each_node_do';

  /// Снятый ключ (D-130): его наличие — ошибка загрузки, легаси-чтения нет.
  static const String keyRemoved = 'for_each';

  /// Имя узла в scope — фиксировано (§6.6). Имена `node` и `node.*`
  /// зарезервированы за узлом.
  static const String nodeName = 'node';

  static const String _kFilter = '#filter';
  static const String _kDo = '#do';
  static const String _kFinal = '#final';
  static const String _kAppend = '#append';
  static const String _kTpl = '#tpl';
  static const Set<String> _finalVerbs = {'#unique', '#sort', '#limit'};

  /// Имя зарезервировано за узлом обхода (§6.5, §6.6).
  static bool isReservedName(String name) =>
      name == nodeName || name.startsWith('$nodeName.');

  /// Структурный разбор обхода из JSON пресета [preset]. null — обхода у
  /// пресета нет. Нарушение нормы — [FormatException] (ошибка загрузки):
  /// снятый `for_each`; оба ключа; ключ внутри обхода вне закрытого списка
  /// (`node_type`, `as`, непомеченные `filter`/`do`/`final`, `#do`/`#final` у
  /// `for_each_node`); нет `#do` у `for_each_node_do`; ключ `#do` без `@`;
  /// имя не из `vars` этого пресета или не `text_list`; глагол не `#append`
  /// или не один; правая часть не строка и не `{"#tpl": "…"}`; операция с
  /// `#if…` (§656): второй `#if…`, соседний ключ, невалидная форма, ветка не
  /// по норме глагола; `#final` на
  /// имя вне `#do`; чужой глагол или тип значения в `#final`.
  static PresetNodeLoop? parse(Map<String, dynamic> preset) {
    if (preset.containsKey(keyRemoved)) {
      throw const FormatException('`for_each` is removed (contract 1.1.119): '
          'use `for_each_node` or `for_each_node_do`');
    }
    final hasNode = preset.containsKey(keyNode);
    final hasDo = preset.containsKey(keyNodeDo);
    if (hasNode && hasDo) {
      throw const FormatException('`for_each_node` and `for_each_node_do` in '
          'one preset: exactly one is allowed');
    }
    if (!hasNode && !hasDo) return null;
    final key = hasNode ? keyNode : keyNodeDo;
    final raw = preset[key];
    if (raw is! Map) throw FormatException('`$key` must be an object');
    final allowed =
        hasNode ? const {_kFilter} : const {_kFilter, _kDo, _kFinal};
    for (final k in raw.keys) {
      if (!allowed.contains(k)) {
        throw FormatException('`$key`: key `$k` is not allowed (closed list: '
            '${allowed.join(', ')})');
      }
    }
    if (raw.containsKey(_kFilter) && raw[_kFilter] == null) {
      throw FormatException('`$key.#filter` must be a condition');
    }
    final filter = raw[_kFilter];
    if (hasNode) {
      return PresetNodeLoop(kind: PresetNodeLoopKind.node, filter: filter);
    }

    // Объявления переменных ЭТОГО пресета: имя → тип. Ref-запись — ссылка на
    // глобальную переменную, писать в неё `#do` не может.
    final types = <String, String>{};
    for (final v in (preset['vars'] as List? ?? const []).whereType<Map>()) {
      final ref = v['ref'];
      if (ref is String && ref.isNotEmpty) continue;
      final name = v['name'];
      if (name is! String || name.isEmpty) continue;
      final type = v['type'];
      types[name] = type is String ? type : 'text';
    }

    if (!raw.containsKey(_kDo)) {
      throw FormatException('`$key`: `#do` is required');
    }
    final doRaw = raw[_kDo];
    if (doRaw is! Map) throw FormatException('`$key.#do` must be an object');
    final collect = <String, Object>{};
    for (final e in doRaw.entries) {
      final name = _varRef(e.key, '$key.#do');
      final type = types[name];
      if (type == null) {
        throw FormatException('`$key.#do`: `@$name` is not declared in the '
            'vars of this preset');
      }
      if (type != 'text_list') {
        throw FormatException('`$key.#do`: `#append` writes only to '
            'text_list, `@$name` is `$type`');
      }
      final op = e.value;
      final where = '$key.#do.@$name';
      final ifKeys = op is Map
          ? op.keys.whereType<String>().where(isIfKey).toList()
          : const <String>[];
      if (op is Map && ifKeys.isNotEmpty) {
        // §656 (контракт 1.1.125, §6.7.1) — операция под условием: ровно
        // один ключ `#if…`, соседей нет, глаголы — в обеих ветках.
        if (ifKeys.length > 1) {
          throw FormatException('`$where`: exactly one `#if…` key is allowed '
              'on an operation (got ${ifKeys.join(', ')})');
        }
        if (op.length != 1) {
          throw FormatException('`$where`: `${ifKeys.first}` must be the only '
              'key of the operation');
        }
        final ifKey = ifKeys.first;
        final form = normalizeIfForm(_jsonMap(op)[ifKey]);
        if (form == null) {
          throw FormatException('`$where.$ifKey`: value must be `[cond, V, E]` '
              'or an object with `#value`');
        }
        _parseVerb(form.value, '$where.$ifKey.value');
        if (form.hasElse) _parseVerb(form.elseValue, '$where.$ifKey.else');
        collect[name] = PresetDoIf(
          ifKey: ifKey,
          form: form,
          raw: _jsonMap(op)[ifKey] as Object,
        );
        continue;
      }
      collect[name] = _parseVerb(op, where);
    }

    final finals = <String, PresetLoopFinal>{};
    if (raw.containsKey(_kFinal)) {
      final finalRaw = raw[_kFinal];
      if (finalRaw is! Map) {
        throw FormatException('`$key.#final` must be an object');
      }
      for (final e in finalRaw.entries) {
        final name = _varRef(e.key, '$key.#final');
        if (!collect.containsKey(name)) {
          throw FormatException(
              '`$key.#final`: `@$name` is not collected by `#do`');
        }
        final ops = e.value;
        if (ops is! Map) {
          throw FormatException('`$key.#final.@$name` must be an object');
        }
        for (final k in ops.keys) {
          if (!_finalVerbs.contains(k)) {
            throw FormatException('`$key.#final.@$name`: unknown verb `$k` '
                '(closed list: ${_finalVerbs.join(', ')})');
          }
        }
        final unique = ops['#unique'];
        final sort = ops['#sort'];
        final limit = ops['#limit'];
        if (ops.containsKey('#unique') && unique is! bool) {
          throw FormatException('`$key.#final.@$name.#unique` must be bool');
        }
        if (ops.containsKey('#sort') && sort is! bool) {
          throw FormatException('`$key.#final.@$name.#sort` must be bool');
        }
        if (ops.containsKey('#limit') && (limit is! int || limit <= 0)) {
          throw FormatException(
              '`$key.#final.@$name.#limit` must be an integer > 0');
        }
        finals[name] = PresetLoopFinal(
          unique: unique == true,
          sort: sort == true,
          limit: limit is int ? limit : null,
        );
      }
    }
    return PresetNodeLoop(
      kind: PresetNodeLoopKind.nodeDo,
      filter: filter,
      collect: collect,
      finals: finals,
    );
  }

  /// Операция `{"#append": rhs}` → rhs (строка-ссылка или `{"#tpl": …}`).
  /// Иное — [FormatException]: не объект, не один глагол, неизвестный
  /// глагол, правая часть не той формы.
  static Object _parseVerb(Object? op, String where) {
    if (op is! Map || op.length != 1) {
      throw FormatException('`$where`: operation must be an object '
          'with exactly one verb');
    }
    final verb = op.keys.first;
    if (verb != _kAppend) {
      throw FormatException('`$where`: unknown verb `$verb` (only `#append`)');
    }
    final rhs = op[_kAppend];
    if (rhs is String) return rhs;
    if (rhs is Map && rhs.length == 1 && rhs[_kTpl] is String) {
      return <String, dynamic>{_kTpl: rhs[_kTpl]};
    }
    throw FormatException('`$where.#append`: right side must be '
        'a reference string or `{"#tpl": "…"}`');
  }

  static Map<String, dynamic> _jsonMap(Map m) =>
      m is Map<String, dynamic> ? m : Map<String, dynamic>.from(m);

  /// Ключ `"@имя"` операции `#do` / `#final` → имя; без `@` — ошибка.
  static String _varRef(Object? key, String where) {
    if (key is! String || key.length < 2 || !key.startsWith('@')) {
      throw FormatException('`$where`: key `$key` must be `@name`');
    }
    return key.substring(1);
  }
}
