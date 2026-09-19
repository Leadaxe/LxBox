/// §480 W6 — ОПОЗНАНИЕ ВИДА ДОКУМЕНТА, объявленное данными.
///
/// Верхняя стадия конвейера (MAPPER_ENGINE §1): сырой ТЕКСТ → вид источника
/// и оболочка → `unwrap` → повторное опознание → элементы. До этой волны
/// стадию исполнял рукописный сниффер (`body_decoder.dart`: эвристика
/// base64, развилка `{`/`[`, проверка `[Interface]`, `_detectFlavor` с
/// `_looksLikeSingboxOutbounds`), и каждое его решение было ветвью в коде.
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
/// Имён схем и протоколов здесь нет (греп-страж): вид документа называет
/// себя `id`-строкой из данных, а вид источника элемента — `element_kind`.
library;

import 'dart:convert';

import 'interpreter.dart' show detectMatchesJson, formMatchesText;

/// Одна ветка реестра видов документа.
final class DocumentSource {
  const DocumentSource({
    required this.id,
    this.priority = 0,
    this.detect,
    this.unwrap,
    this.reunwrap = false,
    this.requiresAfterUnwrap,
    this.elementKind,
    this.elements,
    this.lineCommentPrefixes = const ['#', '//', ';'],
  });

  factory DocumentSource.fromJson(Map<String, dynamic> j) => DocumentSource(
        id: j['id'] as String? ?? '',
        priority: (j['priority'] as num?)?.toInt() ?? 0,
        detect: (j['detect'] as Map?)?.cast<String, dynamic>(),
        unwrap: j['unwrap'] as String?,
        reunwrap: j['reunwrap'] as bool? ?? false,
        requiresAfterUnwrap:
            (j['requires_after_unwrap'] as Map?)?.cast<String, dynamic>(),
        elementKind: j['element_kind'] as String?,
        elements: j['elements'] as String?,
        lineCommentPrefixes:
            ((j['line_comment_prefixes'] as List?) ?? const ['#', '//', ';'])
                .cast<String>(),
      );

  /// Имя вида — строка ДАННЫХ, не перечисление кода.
  final String id;
  final int priority;
  final Map<String, dynamic>? detect;

  /// Имя распаковщика оболочки. Оболочка — единственное, что остаётся
  /// КОДОМ: `qCompress`+zlib предикатами не выражается. Но вызывается он по
  /// ИМЕНИ из данных, а не веткой в снифере (так же у лаунчера).
  final String? unwrap;

  /// Распакованный текст судится ЗАНОВО, с самого начала.
  final bool reunwrap;

  /// Проверка правдоподобия распакованного: без неё случайный текст из букв
  /// и цифр проходит алфавит base64 и вытесняет настоящий документ.
  final Map<String, dynamic>? requiresAfterUnwrap;

  /// Вид источника ЭЛЕМЕНТА (`uri` | `xray` | `singbox` | `conf`); `null` —
  /// вид документа узлов не даёт.
  final String? elementKind;

  /// Откуда брать элементы: `lines`, `$self`, `[]`, `[].outbounds[]`,
  /// `outbounds[]+endpoints[]`.
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

  /// Разобранный JSON, если вид документа его требовал (разбирается ОДИН раз
  /// на документ — норма §1).
  final Object? json;

  final int unwrapDepth;
}

/// Именованный распаковщик оболочки: `unwrap` реестра → функция.
typedef Unwrapper = String? Function(String text);

/// Реестр видов документа.
final class DocumentRegistry {
  DocumentRegistry(this.sources, {this.maxUnwrapDepth = 2});

  factory DocumentRegistry.fromJson(Map<String, dynamic> j) {
    final list = ((j['sources'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => DocumentSource.fromJson(e.cast<String, dynamic>()))
        .toList();
    // Порядок в файле нормативен только как тай-брейк: сортируем по
    // `priority`, стабильно.
    final ordered = List<DocumentSource>.from(list)
      ..sort((a, b) => a.priority.compareTo(b.priority));
    return DocumentRegistry(
      ordered,
      maxUnwrapDepth: (j['max_unwrap_depth'] as num?)?.toInt() ?? 2,
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
    final text = rawText.trim();
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
    // Хвост режется всегда, голова — только для ПРЕДИКАТА (см. `matchAll`):
    // сам текст документа отдаётся разбору с ведущими пробелами, потому что
    // у INI первая строка бывает значимо выровнена.
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

      // Оболочка. Распаковщик отдал `null` — ветка не сработала, пробуем
      // следующую: документ мог просто выглядеть похоже.
      final unwrapper = unwrappers[name];
      if (unwrapper == null) continue;
      final inner = unwrapper(trimmed)?.trim();
      if (inner == null || inner.isEmpty) continue;
      if (!formMatchesText(s.requiresAfterUnwrap, inner)) continue;

      if (!s.reunwrap) {
        return DocumentMatch(source: s, text: inner, unwrapDepth: depth + 1);
      }
      // Распакованное судится ЗАНОВО, с потолком глубины: вложенная
      // оболочка бывает, бесконечная — нет.
      if (depth + 1 >= maxUnwrapDepth) {
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

  /// Нужен ли ветке разобранный JSON: выражение спрашивает `json`, либо его
  /// спрашивает вложенное выражение комбинатора.
  static bool _needsJson(Map<String, dynamic> d) {
    if (d.containsKey('json')) return true;
    for (final key in const ['any', 'all']) {
      final sub = d[key];
      if (sub is! List) continue;
      for (final s in sub) {
        if (s is Map && _needsJson(s.cast<String, dynamic>())) return true;
      }
    }
    return false;
  }

  static Object? _tryJson(String text) {
    final t = text.trimLeft();
    if (!t.startsWith('{') && !t.startsWith('[')) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }
}
