/// §686 п. 9 — ЭМИТТЕР INI: обратный ход той же таблицы `params`, что ведёт
/// разбор `.conf` (секция вида `conf`).
///
/// Таблица одна на оба хода, как у эмиттера ссылки ([emitViaSection]):
/// запись `source: "ini.<Секция>.<Ключ>"` + `maps_to: <путь тела>` читается
/// задом наперёд — путь тела → ключ секции. Имя ключа — ПЕРВЫЙ `source`
/// записи (`Reserved`, не `ClientId`), порядок строк — порядок записей
/// таблицы. Повторяемая секция (`ini_dialect.sections.<имя>.into: "<x>[]"`)
/// выходит по экземпляру на каждый элемент массива тела, в его порядке.
///
/// **Вход — каноническое тело** (карта sing-box: то, что показывает вкладка
/// JSON). Модели узла эмиттер не знает, имён схем в нём нет (греп-страж
/// пакета движка).
///
/// Что тело несёт, а таблица не объявляет, в текст не попадает — такие пути
/// возвращаются списком [IniEmitResult.lost]: вкладка INI и предупреждение
/// Edit INI перечисляют их пользователю. Пустое значение (`null`, `""`, `[]`,
/// `{}`) потерей не считается: терять нечего.
library;

import 'emitter.dart' show invertValueMap;
import 'section.dart';

/// Итог обратного хода INI.
final class IniEmitResult {
  const IniEmitResult({required this.text, this.lost = const []});

  /// Текст `.conf`.
  final String text;

  /// Пути тела, которых в тексте нет (`peers[].workers` — у элемента
  /// повторяемой секции), в порядке тела, без повторов.
  final List<String> lost;
}

/// Собрать `.conf` секцией [section] из тела [body].
///
/// `null` — у секции нет диалекта INI либо ни одной записи с источником
/// `ini.*`: обратного хода нет.
IniEmitResult? emitIniViaSection(
  MapperSection section,
  Map<String, dynamic> body,
) {
  final dialect = section.iniDialect;
  if (dialect == null) return null;
  final e = _IniEmit(section, dialect, body);
  if (e.groups.isEmpty) return null;
  return e.run();
}

/// Запись таблицы, разложенная по месту в INI.
final class _IniParam {
  _IniParam(this.p, this.section, this.key);

  final MapperParam p;

  /// Имя секции как в источнике (`Interface`).
  final String section;

  /// Ключ как в первом `source` записи (`PrivateKey`).
  final String key;
}

final class _IniEmit {
  _IniEmit(this.section, this.dialect, this.body) {
    for (final p in section.params.values) {
      if (p.isService) continue;
      // Запись без своего пути (`maps_to: null` — DNS) обратно не едет;
      // `extract` раскладывает значение по путям групп — едет ими.
      if (p.mapsTo == null && (p.extract?.into.isEmpty ?? true)) continue;
      final src = p.source.isEmpty ? null : p.source.first;
      if (src == null || !src.startsWith('ini.')) continue;
      final parts = src.split('.');
      if (parts.length != 3 || parts[1].startsWith(r'$')) continue;
      groups
          .putIfAbsent(parts[1], () => [])
          .add(_IniParam(p, parts[1], parts[2]));
    }
  }

  final MapperSection section;
  final IniDialect dialect;
  final Map<String, dynamic> body;

  /// Имя секции → её записи в порядке таблицы; порядок секций — порядок
  /// первой записи каждой.
  final Map<String, List<_IniParam>> groups = {};

  /// Пути корня тела, уехавшие в текст.
  final Set<String> _consumedRoot = {};

  /// Префикс массива повторяемой секции (`peers`) → уехавшие пути элемента
  /// (по всем элементам: потеря считается на путь, а не на экземпляр).
  final Map<String, Set<String>> _consumedItem = {};

  IniEmitResult run() {
    final out = <String>[];
    for (final g in groups.entries) {
      final into = dialect.sectionRule(g.key)?.into;
      final array = _arrayName(into);
      if (array == null) {
        final lines = _sectionLines(g.value, body, null, _consumedRoot);
        if (lines.isEmpty) continue;
        _block(out, g.key, lines);
        continue;
      }
      _consumedRoot.add(array);
      final items = body[array];
      if (items is! List) continue;
      final consumed = _consumedItem.putIfAbsent(array, () => {});
      for (final item in items) {
        if (item is! Map) continue;
        final lines = _sectionLines(
            g.value, item.cast<String, dynamic>(), '$array[].', consumed);
        if (lines.isEmpty) continue;
        _block(out, g.key, lines);
      }
    }
    _consumeSchemeSets();
    return IniEmitResult(text: '${out.join('\n')}\n', lost: _lost());
  }

  /// `peers[]` → `peers`; иное написание — не массив.
  static String? _arrayName(String? into) {
    if (into == null || !into.endsWith('[]')) return null;
    return into.substring(0, into.length - 2);
  }

  void _block(List<String> out, String name, List<String> lines) {
    if (out.isNotEmpty) out.add('');
    out
      ..add('[$name]')
      ..addAll(lines);
  }

  /// Строки одной секции по записям [params] из [src]. [prefix] — префикс
  /// путей элемента повторяемой секции (`peers[].`), у корня `null`.
  List<String> _sectionLines(List<_IniParam> params, Map<String, dynamic> src,
      String? prefix, Set<String> consumed) {
    final lines = <String>[];
    final written = <String>{};
    final taken = <String>{};
    for (final ip in params) {
      final p = ip.p;
      if (!_whenAllows(p, written)) continue;
      final ex = p.extract;
      if (ex != null && ex.into.isNotEmpty) {
        final v = _composeExtract(p, ex, src, prefix, taken);
        if (v == null) continue;
        lines.add('${ip.key} = $v');
        written.add('${ip.section}.${ip.key}'.toLowerCase());
        continue;
      }
      final path = _rel(p.mapsTo!, prefix);
      if (path == null || taken.contains(path)) continue;
      final value = _read(src, path);
      if (_isEmpty(value)) continue;
      final text = _serialize(p, value!);
      if (text == null) continue;
      taken.add(path);
      lines.add('${ip.key} = $text');
      written.add('${ip.section}.${ip.key}'.toLowerCase());
    }
    consumed.addAll(taken);
    return lines;
  }

  /// Путь записи относительно элемента: у корня как есть, у элемента — без
  /// [prefix]; запись чужого уровня — `null`.
  static String? _rel(String path, String? prefix) {
    if (prefix == null) return path.contains('[]') ? null : path;
    return path.startsWith(prefix) ? path.substring(prefix.length) : null;
  }

  /// `when` записи по ключам INI: условие `ini.<С>.<К>: {present: false}`
  /// не выполнено, если такой ключ уже написан (маскировка при явном `I1`
  /// не читается — писать её бессмысленно, она числится потерянной).
  /// Условия иных пространств (`query.*`) к тексту `.conf` не относятся.
  bool _whenAllows(MapperParam p, Set<String> written) {
    for (final e in p.when.entries) {
      if (!e.key.startsWith('ini.')) continue;
      final cond = e.value;
      if (cond is! Map || cond['present'] != false) continue;
      if (written.contains(e.key.substring('ini.'.length).toLowerCase())) {
        return false;
      }
    }
    return true;
  }

  /// Обращение `extract`: значение собирается из путей групп и принимается,
  /// только если СВОЯ ЖЕ регулярка разбора раскладывает его обратно в те же
  /// значения. Кандидаты — написания адреса `хост:порт` / `[хост]:порт`.
  String? _composeExtract(MapperParam p, ExtractSpec ex,
      Map<String, dynamic> src, String? prefix, Set<String> taken) {
    final re = RegExp(ex.re.replaceAll('(?P<', '(?<'));
    // Путь группы → её написание в теле.
    final paths = <String, String>{};
    for (final g in ex.into.entries) {
      final v = g.value;
      final full = v is String ? v : (v is Map ? v['path'] as String? : null);
      if (full == null) continue;
      final rel = _rel(full, prefix);
      if (rel == null) return null;
      paths[g.key] = rel;
    }
    final values = <String, String>{};
    for (final path in paths.values.toSet()) {
      final v = _read(src, path);
      if (_isEmpty(v)) continue;
      values[path] = '$v';
    }
    if (values.isEmpty) return null;
    final pathList = values.keys.toList();
    final host = values[pathList.first]!;
    final rest = pathList.skip(1).map((k) => values[k]!).toList();
    final candidates = <String>[
      [host, ...rest].join(':'),
      ['[$host]', ...rest].join(':'),
    ];
    for (final c in candidates) {
      final m = re.firstMatch(c);
      if (m == null || m.start != 0 || m.end != c.length) continue;
      final back = <String, String>{};
      for (final g in paths.entries) {
        final got = m.namedGroup(g.key);
        if (got != null) back[g.value] = got;
      }
      if (values.entries.every((e) => back[e.key] == e.value)) {
        taken.addAll(values.keys);
        return c;
      }
    }
    return null;
  }

  /// Значение строкой источника: список — через `list.sep` (у `,` с пробелом,
  /// разбор режет пробелы), булево — обращением `value_map`, прочее — как
  /// есть. Вложенный объект строкой INI не пишется.
  static String? _serialize(MapperParam p, Object value) {
    if (value is Map) return null;
    if (value is List) {
      final sep = p.list?.sep ?? ',';
      return value.map((e) => '$e').join(sep == ',' ? ', ' : sep);
    }
    if (value is bool) {
      final inv = invertValueMap(p.valueMap);
      final hit = inv?['$value'];
      if (hit != null) return hit;
      return '$value';
    }
    return '$value';
  }

  /// `type`, поставленный самим видом источника (`scheme_sets`), в текст не
  /// пишется и потерей не считается.
  void _consumeSchemeSets() {
    for (final branch in section.schemeSets.values) {
      if (branch is! Map) continue;
      for (final e in branch.entries) {
        if (body[e.key] == e.value) _consumedRoot.add('${e.key}');
      }
    }
  }

  List<String> _lost() {
    final lost = <String>[];
    for (final e in body.entries) {
      final k = e.key;
      // Тег — поле записи узла, не источника.
      if (k == 'tag') continue;
      if (_isEmpty(e.value)) continue;
      final item = _consumedItem[k];
      if (item != null) {
        final seen = <String>{};
        for (final el in (e.value as List? ?? const [])) {
          if (el is! Map) continue;
          for (final ie in el.entries) {
            final ik = '${ie.key}';
            if (_isEmpty(ie.value) || item.contains(ik) || !seen.add(ik)) {
              continue;
            }
            lost.add('$k[].$ik');
          }
        }
        continue;
      }
      if (_consumedRoot.contains(k)) continue;
      lost.add(k);
    }
    return lost;
  }

  /// Чтение пути `a.b` из карты.
  static Object? _read(Map<String, dynamic> src, String path) {
    Object? cur = src;
    for (final seg in path.split('.')) {
      if (cur is! Map) return null;
      cur = cur[seg];
    }
    return cur;
  }

  static bool _isEmpty(Object? v) =>
      v == null ||
      (v is String && v.isEmpty) ||
      (v is List && v.isEmpty) ||
      (v is Map && v.isEmpty);
}
