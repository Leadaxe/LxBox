/// §480 — ТРАССА ИСПОЛНЕНИЯ: «почему это поле получило это значение».
///
/// Формат согласован с лаунчером (`contract/docs/MAPPER_ENGINE.md`,
/// приложение «ТРАССА») ради МЕХАНИЧЕСКОЙ СВЕРКИ Go↔Dart обычным диффом:
/// JSON Lines, одна строка — одно событие, ключи в ФИКСИРОВАННОМ порядке,
/// без времени и адресов памяти.
///
/// Коллектор опционален и выключен по умолчанию: когда трасса не
/// собирается, он не стоит ничего — ни аллокации, ни ветки в горячем пути
/// (проверка `_sink == null`).
///
/// Порядок событий НОРМАТИВЕН и равен порядку исполнения: записи в порядке
/// объявления в реестре, `aliases` в порядке объявления, `unknown` — по
/// строке на каждый необъявленный параметр в порядке появления во входе.
/// Последняя строка — `stage: "result"`.
library;

/// Стадия конвейера. Набор закрыт и согласован: строки сверяются диффом, и
/// «почти такое же» имя стадии даёт ложное расхождение.
abstract final class TraceStage {
  static const docDetect = 'doc_detect';
  static const unwrap = 'unwrap';
  static const elemDetect = 'elem_detect';
  static const lex = 'lex';
  static const field = 'field';
  static const sets = 'sets';
  static const defaults = 'default';
  static const label = 'label';
  static const unknown = 'unknown';
  static const result = 'result';
}

/// Что запись сделала с путём.
abstract final class TraceAct {
  static const write = 'write';
  static const skip = 'skip';
  static const remove = 'remove';
  static const override = 'override';
  static const keep = 'keep';
}

/// Почему получилось именно так. Значения-константы — те, что не зависят от
/// имени записи; параметрические собираются функциями ниже.
abstract final class TraceWhy {
  static const none = '-';
  static const whenFalse = 'when_false';
  static const empty = 'empty';
  static const notDeclared = 'not_declared';
  static const byDefault = 'default';
  static const materializeDefault = 'materialize_default';

  /// Путь занят записью с меньшим `priority`.
  static String lowerPriority(String entry) => 'lower_priority:$entry';

  /// Значение пришло под НЕ каноническим написанием имени.
  static String aliasOf(String canon) => 'alias_of:$canon';
}

/// Собиратель трассы. `null`-коллектора не существует: вместо него движок
/// держит `null` в поле и не зовёт ничего.
final class MapperTrace {
  MapperTrace();

  final List<String> _lines = [];
  int _n = 0;

  /// Записать событие. Порядок ключей фиксирован и совпадает с Go.
  void add({
    required String stage,
    required String mapper,
    String entry = '-',
    String src = '-',
    String? raw,
    Object? val,
    String? path,
    String act = TraceAct.write,
    String why = TraceWhy.none,
  }) {
    _n++;
    final b = StringBuffer('{"n":$_n,"stage":${_str(stage)},'
        '"mapper":${_str(mapper)},"entry":${_str(entry)},"src":${_str(src)},'
        '"raw":${raw == null ? 'null' : _str(raw)},"val":${encode(val)},'
        '"path":${path == null ? 'null' : _str(path)},"act":${_str(act)},'
        '"why":${_str(why)}}');
    _lines.add(b.toString());
  }

  /// Готовая трасса: JSON Lines, без хвостового перевода строки.
  String render() => _lines.join('\n');

  List<String> get lines => List.unmodifiable(_lines);

  /// Каноническая сериализация значения (приложение «ТРАССА», §«Каноническая
  /// сериализация»). Без неё сверка даёт ложные расхождения.
  ///
  /// 1. без пробелов — ни отступов, ни пробела после `:` и `,`;
  /// 2. порядок ключей объекта — ПОРЯДОК ВСТАВКИ (у тела это `body.order`,
  ///    который уже задал эмиттер); свободные объекты (`headers`) —
  ///    лексикографически, по флагу [sortFree];
  /// 3. числа без экспоненты;
  /// 4. не-ASCII как есть (UTF-8), `\u` только для управляющих;
  /// 5. БЕЗ HTML-экранирования `<`, `>`, `&` — у Go это
  ///    `SetEscapeHTML(false)`, у нас `jsonEncode` его и не делает, но
  ///    полагаться на это нельзя: пишем сами.
  static String encode(Object? v, {bool sortFree = false}) {
    if (v == null) return 'null';
    if (v is bool) return v ? 'true' : 'false';
    if (v is int) return '$v';
    if (v is double) {
      // Без экспоненты: `1e+21` у Go и у нас печатается по-разному.
      if (v == v.roundToDouble() && v.abs() < 1e15) {
        return '${v.toInt()}';
      }
      return v.toString();
    }
    if (v is String) return _str(v);
    if (v is List) {
      return '[${v.map((e) => encode(e, sortFree: sortFree)).join(',')}]';
    }
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList();
      if (sortFree) keys.sort();
      final parts = [
        for (final k in keys) '${_str(k)}:${encode(v[k], sortFree: sortFree)}',
      ];
      return '{${parts.join(',')}}';
    }
    return _str('$v');
  }

  /// Строка JSON: экранируются только кавычка, обратный слэш и управляющие.
  /// Не-ASCII уходит как есть — иначе трассы двух сторон не совпадут.
  static String _str(String s) {
    final b = StringBuffer('"');
    for (final r in s.runes) {
      switch (r) {
        case 0x22:
          b.write(r'\"');
        case 0x5C:
          b.write(r'\\');
        case 0x08:
          b.write(r'\b');
        case 0x0C:
          b.write(r'\f');
        case 0x0A:
          b.write(r'\n');
        case 0x0D:
          b.write(r'\r');
        case 0x09:
          b.write(r'\t');
        default:
          if (r < 0x20) {
            b.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
          } else {
            b.writeCharCode(r);
          }
      }
    }
    b.write('"');
    return b.toString();
  }
}
