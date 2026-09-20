/// §480 W6 — ОПОЗНАНИЕ ВИДА ИСТОЧНИКА, объявленное данными.
///
/// Верхняя стадия конвейера (MAPPER_ENGINE §1): сырой ТЕКСТ → вид источника
/// и оболочка → `unwrap` → повторное опознание → элементы. До этой волны
/// стадию исполнял рукописный сниффер (`body_decoder.dart`: эвристика
/// base64, развилка `{`/`[`, проверка `[Interface]`, классификатор формы
/// JSON), и каждое его решение было ветвью в коде.
///
/// **Язык предикатов ОДИН на оба уровня** (§2 НОРМЫ): `detect` вида
/// документа и `detect` секции-маппера читаются одними и теми же функциями
/// ([formMatchesText], [detectMatchesJson]). Второго, «документного» языка
/// норма не допускает — с ним сниффер вернулся бы в код под другим именем.
///
/// **Разрешение неоднозначности** тоже нормативно: совпало несколько —
/// побеждает меньший `priority`; ветка `default: true` НИКОГДА не
/// конкурирует с настоящим предикатом, даже если её `priority` меньше; ровно
/// одна `default` на уровень.
///
/// Имён схем и протоколов здесь нет (греп-страж): вид источника называет
/// себя `kind`-строкой из данных, а вид источника элемента — `mapper`.
///
/// Имена атрибутов сведены с лаунчером (GRAMMAR_SYNC 5d8adc80, TASKS_LXBOX
/// §24.27) и совпадают с FROZEN-написанием обеих сторон: `kind`,
/// `required_keys`, `redetect`, `mapper`, `elements`, `amnezia_vpn`.
library;

import 'dart:convert';

import 'interpreter.dart' show detectMatchesJson, formMatchesText;

/// Одна ветка реестра видов источника.
final class DocumentSource {
  const DocumentSource({
    required this.kind,
    this.priority = 0,
    this.detect,
    this.unwrap,
    this.redetect = false,
    this.requiresAfterUnwrap,
    this.mapper,
    this.elements,
    this.lineCommentPrefixes = const ['#', '//', ';'],
  });

  factory DocumentSource.fromJson(Map<String, dynamic> j) => DocumentSource(
        // Контракт 1.1.41 — ключ записи называется `source_kind`. `kind`
        // читается ради уже написанного черновика: у лаунчера это слово
        // занято видом источника СЕКЦИИ (`mappers.<kind>`), и одно слово на
        // два уровня читалось бы как одно понятие.
        kind: (j['source_kind'] ?? j['kind']) as String? ?? '',
        priority: (j['priority'] as num?)?.toInt() ?? 0,
        detect: (j['detect'] as Map?)?.cast<String, dynamic>(),
        unwrap: j['unwrap'] as String?,
        redetect: j['redetect'] as bool? ?? false,
        requiresAfterUnwrap:
            (j['requires_after_unwrap'] as Map?)?.cast<String, dynamic>(),
        mapper: j['mapper'] as String?,
        elements: j['elements'] as String?,
        lineCommentPrefixes:
            ((j['line_comment_prefixes'] as List?) ?? const ['#', '//', ';'])
                .cast<String>(),
      );

  /// Имя вида — строка ДАННЫХ, не перечисление кода.
  final String kind;
  final int priority;
  final Map<String, dynamic>? detect;

  /// Имя распаковщика оболочки. Оболочка — единственное, что остаётся
  /// КОДОМ: `qCompress`+zlib предикатами не выражается. Но вызывается он по
  /// ИМЕНИ из данных, а не веткой в снифере (так же у лаунчера).
  final String? unwrap;

  /// Распакованный текст судится ЗАНОВО, с самого начала.
  final bool redetect;

  /// Проверка правдоподобия распакованного: без неё случайный текст из букв
  /// и цифр проходит алфавит base64 и вытесняет настоящий документ.
  final Map<String, dynamic>? requiresAfterUnwrap;

  /// Какая секция-маппер получит элемент (`uri` | `xray` | `singbox` |
  /// `conf`); `null` — вид источника узлов не даёт.
  final String? mapper;

  /// Откуда брать элементы: `lines`, `$self`, `[]`, `[].outbounds[]`,
  /// `outbounds[]+endpoints[]`, `ini_texts`.
  final String? elements;

  final List<String> lineCommentPrefixes;

  bool get isDefault => detect?['default'] == true;
}

/// Итог опознания: какой вид, какой текст после снятия оболочек и что от
/// него досталось разбору элементов.
final class DocumentMatch {
  const DocumentMatch({
    required this.source,
    required this.text,
    this.json,
    this.unwrapDepth = 0,
  });

  final DocumentSource source;

  /// Текст ПОСЛЕ всех снятых оболочек.
  final String text;

  /// Разобранный JSON, если вид источника его требовал (разбирается ОДИН раз
  /// на документ — норма §1).
  final Object? json;

  final int unwrapDepth;
}

/// Именованный распаковщик оболочки: `unwrap` реестра → функция.
typedef Unwrapper = String? Function(String text);

/// Реестр видов источника.
final class DocumentRegistry {
  DocumentRegistry(this.sources, {this.maxUnwrapDepth = 2});

  factory DocumentRegistry.fromJson(Map<String, dynamic> j) {
    // Контракт 1.1.41 — записи лежат в `source_kinds.kinds`, а общие
    // настройки (`max_unwrap_depth`) — рядом с ними, внутри того же узла.
    // Плоское `sources` в корне читается ради уже написанного черновика:
    // внутри `source_kinds` слово `sources` означало бы источники, а не их
    // виды.
    final envelope =
        (j['source_kinds'] as Map?)?.cast<String, dynamic>() ?? j;
    final list = ((envelope['kinds'] ?? envelope['sources']) as List? ??
            const [])
        .whereType<Map>()
        .map((e) => DocumentSource.fromJson(e.cast<String, dynamic>()))
        .toList();
    // Порядок в файле нормативен только как тай-брейк: сортируем по
    // `priority`, стабильно.
    final ordered = List<DocumentSource>.from(list)
      ..sort((a, b) => a.priority.compareTo(b.priority));
    return DocumentRegistry(
      ordered,
      maxUnwrapDepth:
          ((envelope['max_unwrap_depth'] ?? j['max_unwrap_depth']) as num?)
                  ?.toInt() ??
              2,
    );
  }

  final List<DocumentSource> sources;
  final int maxUnwrapDepth;

  /// Ветка `default` — ровно одна; её отсутствие значит «не опознали».
  DocumentSource? get defaultSource {
    for (final s in sources) {
      if (s.isDefault) return s;
    }
    return null;
  }

  /// Все ветки (кроме `default`), чей `detect` сработал. Нужны ЛИНТЕРУ:
  /// «ровно одна» — красное и при нуле, и при двух.
  List<DocumentSource> matchAll(String rawText, {Object? parsedJson}) {
    // Отступ документа его видом не является: `vpn://` с пробелом впереди —
    // та же ссылка, и решать это отдельной заплатой у каждого вызывающего
    // (`input.trim().startsWith`) значило бы держать правило в трёх местах.
    // BOM снимается здесь же: невидимый U+FEFF сдвигает первый значащий
    // символ, и `{` / `[Interface]` / алфавит base64 перестают совпадать.
    final text = _stripBom(rawText).trim();
    final out = <DocumentSource>[];
    Object? json = parsedJson;
    var parsed = parsedJson != null;
    for (final s in sources) {
      if (s.isDefault) continue;
      final d = s.detect;
      if (d == null) continue;
      if (_needsJson(d)) {
        if (!parsed) {
          json = _tryJson(text);
          parsed = true;
        }
        if (json == null) continue;
        if (!detectMatchesJson(d, json)) continue;
      } else if (!formMatchesText(d, text)) {
        continue;
      }
      out.add(s);
    }
    return out;
  }

  /// Опознать документ, сняв оболочки.
  ///
  /// [unwrappers] — распаковщики по имени из `unwrap`; отсутствие нужного
  /// значит, что ветка не срабатывает (молчаливо подставлять «как есть»
  /// нельзя: оболочка не снята — документа нет).
  DocumentMatch? detect(
    String text, {
    required Map<String, Unwrapper> unwrappers,
    int depth = 0,
  }) {
    // BOM — мусор кодировки файла, не признак формата: снимается один раз
    // на вход, до любого предиката. Хвост режется всегда, голова — только
    // для ПРЕДИКАТА (см. `matchAll`): сам текст документа отдаётся разбору
    // с ведущими пробелами, потому что у INI первая строка бывает значимо
    // выровнена.
    text = _stripBom(text);
    final trimmed = text.trimRight();
    if (trimmed.trim().isEmpty) return null;

    final probe = trimmed.trim();
    Object? json;
    var parsed = false;

    for (final s in sources) {
      if (s.isDefault) continue;
      final d = s.detect;
      if (d == null) continue;

      if (_needsJson(d)) {
        if (!parsed) {
          json = _tryJson(probe);
          parsed = true;
        }
        if (json == null) continue;
        if (!detectMatchesJson(d, json)) continue;
        return DocumentMatch(
            source: s, text: trimmed, json: json, unwrapDepth: depth);
      }

      if (!formMatchesText(d, probe)) continue;

      final name = s.unwrap;
      if (name == null) {
        return DocumentMatch(source: s, text: trimmed, unwrapDepth: depth);
      }

      // Предел считается по СНЯТЫМ оболочкам: `max_unwrap_depth: 2` —
      // «обёртка внутри обёртки, дальше нет». Вид оставляем объявленным,
      // но дальше не снимаем — иначе глубина не ограничивала бы ничего.
      if (depth >= maxUnwrapDepth && maxUnwrapDepth > 0) {
        return DocumentMatch(source: s, text: trimmed, unwrapDepth: depth);
      }

      // Оболочка. Распаковщик отдал `null` — ветка не сработала, пробуем
      // следующую: документ мог просто выглядеть похоже.
      final unwrapper = unwrappers[name];
      if (unwrapper == null) continue;
      final inner = unwrapper(trimmed)?.trim();
      if (inner == null || inner.isEmpty) continue;
      if (!formMatchesText(s.requiresAfterUnwrap, inner)) {
        // Промежуточный слой той же оболочки: распакованное — снова
        // алфавит обёртки, `requires_after_unwrap` на нём проваливается,
        // хотя документа мы ещё не достигли. Отличает этот случай от
        // «обёртки не было» повторный детект той же ветки.
        if (s.redetect && formMatchesText(d, inner)) {
          final again =
              detect(inner, unwrappers: unwrappers, depth: depth + 1);
          if (again != null) return again;
        }
        continue;
      }

      if (!s.redetect) {
        return DocumentMatch(source: s, text: inner, unwrapDepth: depth + 1);
      }
      final again =
          detect(inner, unwrappers: unwrappers, depth: depth + 1);
      if (again != null) return again;
      return DocumentMatch(source: s, text: inner, unwrapDepth: depth + 1);
    }

    final fallback = defaultSource;
    if (fallback == null) return null;
    return DocumentMatch(source: fallback, text: trimmed, unwrapDepth: depth);
  }

  /// §480 — ГРУППЫ ЭЛЕМЕНТОВ объектного документа по строке `elements`.
  ///
  /// Обход элементов перестал быть рукописным `switch` в `parse_all`: реестр
  /// называет, ГДЕ у вида источника лежат элементы, а движок их достаёт.
  /// Прежние четыре ветки («массив конфигов», «массив outbound'ов»,
  /// «одиночный», «полный конфиг») были ровно этим обходом, записанным кодом:
  /// четыре способа добраться до элементов ОДНОГО диалекта.
  ///
  /// Грамматика строки (норма MAPPER_ENGINE §1):
  ///
  /// - `[].<хвост>` — каждый член корневого массива это самостоятельный
  ///   конфиг; хвост пути по нему проходит уже сборка документа;
  /// - `$self` — документ сам себе элемент;
  /// - `[]` — элементы это члены корневого массива, все в ОДНОМ конфиге;
  /// - `a[]+b[]` либо `a[]` — пути внутри документа-объекта.
  ///
  /// Группа — самостоятельный конфиг, и границы её несут смысл: дедуп (§404)
  /// и владение именем (§342) считаются ВНУТРИ конфига, а схлопни обход их в
  /// один список — узлы разных конфигов начали бы вытеснять друг друга.
  ///
  /// `null` — форма документа не та, что объявлена строкой, и вызывающий
  /// идёт прежним путём.
  static List<Map<String, dynamic>>? groupsFor(String spec, Object? value) {
    if (spec.startsWith('[].')) {
      if (value is! List) return null;
      return value
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    if (spec == r'$self') {
      if (value is! Map) return null;
      return [
        {
          _kOutbounds: [value.cast<String, dynamic>()],
        },
      ];
    }
    if (spec == '[]') {
      if (value is! List) return null;
      return [
        {_kOutbounds: value},
      ];
    }
    if (value is! Map) return null;
    return [value.cast<String, dynamic>()];
  }

  /// Имя контейнера элементов у форм, где путь к ним не написан (`$self`,
  /// `[]`): оно приходит из `elements` соседних форм того же диалекта
  /// (`outbounds[]+endpoints[]`), а не выдумывается здесь.
  static const _kOutbounds = 'outbounds';

  /// Нужен ли ветке разобранный JSON: выражение спрашивает `json`, либо его
  /// спрашивает вложенное выражение комбинатора.
  ///
  /// `not` обходится наравне с `any`/`all`: после сведения грамматики
  /// (GRAMMAR_SYNC §1 №3) отрицание живёт на уровне `detect`, и ветка, у
  /// которой JSON спрашивает ТОЛЬКО отрицаемое выражение, без этого обхода
  /// осталась бы без разобранного документа и не сработала бы никогда.
  static bool _needsJson(Map<String, dynamic> d) {
    if (d.containsKey('json')) return true;
    for (final key in const ['any', 'all']) {
      final sub = d[key];
      if (sub is! List) continue;
      for (final s in sub) {
        if (s is Map && _needsJson(s.cast<String, dynamic>())) return true;
      }
    }
    final not = d['not'];
    if (not is Map && _needsJson(not.cast<String, dynamic>())) return true;
    return false;
  }

  static Object? _tryJson(String text) {
    final t = _stripBom(text).trimLeft();
    if (!t.startsWith('{') && !t.startsWith('[')) return null;
    try {
      return jsonDecode(t);
    } catch (_) {
      return null;
    }
  }
}

/// U+FEFF в начале текста — маркер порядка байтов файла, не содержимое.
String _stripBom(String s) {
  const bom = '\uFEFF';
  return s.startsWith(bom) ? s.substring(bom.length) : s;
}
