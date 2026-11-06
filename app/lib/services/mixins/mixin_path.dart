/// §704 §3 — язык пути миксина: разбор и разрешение по конфигу.
///
/// Свой, не JSONPath и не путь движка разбора (`jsonPathValue`,
/// `interpreter.dart` — у него норма контракта «первый, без учёта регистра»).
/// Путь обозначает НАБОР узлов.
///
/// ```
/// путь     = "" | сегмент ("." сегмент)*
/// сегмент  = имя | имя "[" N "]" | имя "[" условия "]"
/// условия  = условие ("," условие)*
/// условие  = поле "=" значение
/// поле     = имя ("." имя)*
/// ```
library;

/// Символы, которые не входят в имя.
const _nameStops = {'.', '[', ']', ',', '='};

bool _isNameChar(String c) =>
    !_nameStops.contains(c) && c.trim().isNotEmpty;

bool _isDigits(String s) =>
    s.isNotEmpty && s.codeUnits.every((u) => u >= 0x30 && u <= 0x39);

/// Условие `[поле=значение]`.
class MixinCondition {
  /// Путь внутри элемента: `tag`, `tls.enabled`.
  final List<String> field;
  final String value;
  const MixinCondition(this.field, this.value);

  String get fieldText => field.join('.');

  @override
  String toString() => '$fieldText=$value';
}

/// Один сегмент пути: ключ, затем необязательный индекс или условия.
class MixinPathSegment {
  final String name;

  /// `имя[N]`.
  final int? index;

  /// `имя[условия]`; `null` — скобок с условиями нет.
  final List<MixinCondition>? conditions;

  const MixinPathSegment(this.name, {this.index, this.conditions});

  @override
  String toString() {
    if (index != null) return '$name[$index]';
    final c = conditions;
    if (c != null) return '$name[${c.join(',')}]';
    return name;
  }
}

/// Итог [parseMixinPath]: [MixinPath] или [MixinPathError].
sealed class MixinPathParse {
  const MixinPathParse();
}

class MixinPathError extends MixinPathParse {
  /// Позиция в исходной строке (0-based), где разбор споткнулся.
  final int offset;
  final String message;
  const MixinPathError(this.offset, this.message);

  @override
  String toString() => 'MixinPathError($offset: $message)';
}

/// Совпадение пути: узел [value] и его место — [parent] (Map или List;
/// `null` у корня) с [key] или [index].
class PathMatch {
  final Object? parent;
  final String? key;
  final int? index;
  final Object? value;

  /// Конкретный путь до узла с индексами: `route.rules[3]`, `log.level`.
  final String path;

  /// Конкретный путь до [parent]; у корня пусто.
  final String parentPath;

  const PathMatch({
    required this.parent,
    this.key,
    this.index,
    required this.value,
    required this.path,
    this.parentPath = '',
  });

  bool get isRoot => parent == null;

  /// Узел — элемент списка.
  bool get isListElement => parent is List && index != null;

  @override
  String toString() => 'PathMatch($path)';
}

class MixinPath extends MixinPathParse {
  final List<MixinPathSegment> segments;
  const MixinPath(this.segments);

  bool get isRoot => segments.isEmpty;

  /// Все узлы конфига [root], на которые указывает путь, в порядке документа.
  List<PathMatch> resolve(Object? root) {
    var current = <PathMatch>[
      PathMatch(parent: null, value: root, path: ''),
    ];
    for (final seg in segments) {
      final next = <PathMatch>[];
      for (final m in current) {
        final child = _child(m, seg.name);
        if (child == null) continue;
        final idx = seg.index;
        final conds = seg.conditions;
        if (idx != null) {
          final list = child.value;
          if (list is List && idx < list.length) {
            next.add(PathMatch(
              parent: list,
              index: idx,
              value: list[idx],
              path: '${child.path}[$idx]',
              parentPath: child.path,
            ));
          }
        } else if (conds != null) {
          final list = child.value;
          if (list is! List) continue;
          for (var i = 0; i < list.length; i++) {
            final el = list[i];
            if (conds.every((c) => _conditionHolds(el, c))) {
              next.add(PathMatch(
                parent: list,
                index: i,
                value: el,
                path: '${child.path}[$i]',
                parentPath: child.path,
              ));
            }
          }
        } else {
          next.add(child);
        }
      }
      current = next;
      if (current.isEmpty) break;
    }
    return current;
  }

  @override
  String toString() => segments.join('.');
}

String _join(String base, String name) => base.isEmpty ? name : '$base.$name';

/// Шаг по имени от узла [m]: ключ объекта; у списка числовое имя —
/// индекс (`outbounds.0`, одна норма с Import Rules).
PathMatch? _child(PathMatch m, String name) {
  final v = m.value;
  if (v is Map) {
    if (!v.containsKey(name)) return null;
    return PathMatch(
        parent: v,
        key: name,
        value: v[name],
        path: _join(m.path, name),
        parentPath: m.path);
  }
  if (v is List && _isDigits(name)) {
    final i = int.parse(name);
    if (i >= v.length) return null;
    return PathMatch(
        parent: v,
        index: i,
        value: v[i],
        path: '${m.path}[$i]',
        parentPath: m.path);
  }
  return null;
}

/// Значение по пути [field] внутри [el]; `_missing` — пути нет.
Object? _fieldValue(Object? el, List<String> field) {
  Object? cur = el;
  for (final f in field) {
    if (cur is Map && cur.containsKey(f)) {
      cur = cur[f];
    } else if (cur is List && _isDigits(f) && int.parse(f) < cur.length) {
      cur = cur[int.parse(f)];
    } else {
      return _missing;
    }
  }
  return cur;
}

const Object _missing = Object();

bool _conditionHolds(Object? el, MixinCondition c) {
  final v = _fieldValue(el, c.field);
  if (identical(v, _missing)) return false;
  if (v is List) return v.any((x) => scalarMatches(x, c.value));
  return scalarMatches(v, c.value);
}

/// Сравнение скаляра конфига с текстом условия: число с числом, bool с
/// `true`/`false`, иначе строки с учётом регистра.
bool scalarMatches(Object? v, String text) {
  if (v is num) {
    final n = num.tryParse(text);
    return n != null && n == v;
  }
  if (v is bool) return text == (v ? 'true' : 'false');
  if (v is String) return v == text;
  return false;
}

/// Разбор строки пути. Ошибка — [MixinPathError] с позицией.
MixinPathParse parseMixinPath(String text) {
  if (text.isEmpty) return const MixinPath([]);
  if (text.startsWith(r'$')) {
    return const MixinPathError(
        0, r'paths starting with "$" are reserved (JSONPath)');
  }
  final p = _Parser(text);
  try {
    return MixinPath(p.parse());
  } on MixinPathError catch (e) {
    return e;
  }
}

class _Parser {
  final String s;
  int i = 0;
  _Parser(this.s);

  bool get _end => i >= s.length;
  String get _c => s[i];

  Never _fail(String message, [int? at]) =>
      throw MixinPathError(at ?? i, message);

  List<MixinPathSegment> parse() {
    final segs = <MixinPathSegment>[];
    while (true) {
      segs.add(_segment());
      if (_end) return segs;
      if (_c == '.') {
        i++;
        if (_end) _fail('name expected after "."');
        continue;
      }
      _fail('unexpected "$_c"');
    }
  }

  String _name(String what) {
    final start = i;
    while (!_end && _isNameChar(_c)) {
      i++;
    }
    if (i == start) {
      _fail(_end ? '$what expected' : '$what expected, got "$_c"');
    }
    return s.substring(start, i);
  }

  MixinPathSegment _segment() {
    final name = _name('name');
    if (_end || _c != '[') return MixinPathSegment(name);
    final open = i;
    i++; // [
    // Индекс: только цифры до `]`.
    final close = s.indexOf(']', i);
    if (close < 0) _fail('"]" expected', s.length);
    final inner = s.substring(i, close);
    if (inner.trim().isEmpty) _fail('index or condition expected', i);
    if (_isDigits(inner.trim()) && !inner.contains('=')) {
      i = close + 1;
      return MixinPathSegment(name, index: int.parse(inner.trim()));
    }
    final conds = <MixinCondition>[];
    while (true) {
      _skipSpaces();
      final field = <String>[_name('field')];
      while (!_end && _c == '.') {
        i++;
        field.add(_name('field'));
      }
      _skipSpaces();
      if (_end) _fail('"]" expected');
      if (_c != '=') _fail('"=" expected, got "$_c"');
      i++; // =
      final vStart = i;
      while (!_end && _c != ',' && _c != ']') {
        if (_c == '[') _fail('"[" is not allowed in a condition value');
        i++;
      }
      if (_end) _fail('"]" expected');
      conds.add(MixinCondition(field, s.substring(vStart, i).trim()));
      if (_c == ',') {
        i++;
        continue;
      }
      i++; // ]
      break;
    }
    if (conds.isEmpty) _fail('condition expected', open + 1);
    return MixinPathSegment(name, conditions: conds);
  }

  void _skipSpaces() {
    while (!_end && _c.trim().isEmpty) {
      i++;
    }
  }
}
