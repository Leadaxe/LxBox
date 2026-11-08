/// §722 (контракт 1.1.165, PARSING_PRINCIPLES §11) — ЕДИНАЯ ТОЧКА ВХОДА
/// текста источника своего сервера и члена папки.
///
/// Вид (диалект) определяется движком по реестру (`decode` → ветка
/// `source_kinds.json` → её `mapper`) ровно здесь — когда текст приходит
/// снаружи: вставка, импорт, Save на Source, обновление. Дальше он хранится
/// полем записи (`SourceDialect`, `origin.kind`), и хранимый текст никто
/// заново не классифицирует.
///
/// Формы ввода (п.2 §11):
/// - голое тело (sing-box `{"type":…}`, Xray `{"protocol":…}`) — как набрано;
/// - документ (sing-box с `outbounds`/`endpoints`, Xray с `outbounds`) —
///   обрезается до узловых массивов, остальное (`route`, `dns`, `routing`,
///   `log`, `sections`…) не хранится, флаг [SourceItem.extrasDropped];
/// - массив (тел или документов) — форма ввода: режется на элементы, каждый
///   со своим видом.
///
/// Ссылки (`uri`) и `.conf` (`wg_ini`) — один элемент, текст как есть: где
/// список ссылок режется на записи построчно, решает вызывающий (как и раньше,
/// по узлам разбора).
///
/// Чистый модуль без Flutter.
library;

import 'dart:convert';

import '../../models/source_dialect.dart';
import 'body_decoder.dart';
import 'json_comments.dart';

/// Элемент входа: текст одной будущей записи и его вид.
final class SourceItem {
  const SourceItem(this.text, this.dialect, {this.extrasDropped = false});

  /// Текст источника записи: голое тело как набрано, документ обрезанный до
  /// узловых массивов, элемент массива (JSON с отступом в два пробела).
  final String text;

  final SourceDialect dialect;

  /// Во входе этого элемента было что-то кроме узловых массивов — оно не
  /// сохранено (одно сообщение на сохранение).
  final bool extrasDropped;

  /// Документ (`outbounds`/`endpoints` в корне), а не голое тело.
  bool get isDocument {
    if (!dialect.isJson) return false;
    try {
      final v = jsonDecode(text);
      return v is Map &&
          (v['outbounds'] is List || v['endpoints'] is List) &&
          v[dialect == SourceDialect.singbox ? 'type' : 'protocol'] == null;
    } catch (_) {
      return false;
    }
  }
}

/// Результат классификации входа.
final class SourceClassification {
  const SourceClassification({
    required this.dialect,
    required this.items,
    this.wasArray = false,
    this.commentsRemoved = false,
    this.jsonError,
  });

  /// Вид входа; `null` — движок вид не опознал (не узел, битый JSON).
  final SourceDialect? dialect;

  /// Элементы входа: у массива — по элементу, иначе ровно один. Пусто, если
  /// [dialect] `null`.
  final List<SourceItem> items;

  /// Вход был массивом (`*_array`).
  final bool wasArray;

  /// §585 — во входе были комментарии `//` или `/* */`; в [items] их нет.
  final bool commentsRemoved;

  /// Текст похож на JSON (`{`/`[`, не `.conf`), но не разбирается: сообщение
  /// `FormatException`.
  final String? jsonError;
}

/// Узловые массивы документа по диалекту (п.2 §11; у лаунчера — та же таблица
/// в коде рядом с обрезкой, TASKS_LXBOX §165 п.5 (д)).
List<String> nodeArrayKeysOf(SourceDialect dialect) => switch (dialect) {
      SourceDialect.singbox => const ['outbounds', 'endpoints'],
      SourceDialect.xray => const ['outbounds'],
      _ => const [],
    };

/// Вид разобранного движком текста; `null` — вида нет (JSON без маппера,
/// нераспознанное).
///
/// `vpn://` — `uri`: у LxBox источником хранится сама упакованная ссылка, а
/// не её `.conf` (разбор с `nameHint` у ссылки переименовал бы узлы).
SourceDialect? dialectOfDecoded(DecodedBody decoded) => switch (decoded) {
      JsonConfig(:final source) => switch (source.mapper) {
          'singbox' => SourceDialect.singbox,
          'xray' => SourceDialect.xray,
          _ => null,
        },
      UriLines() => SourceDialect.uri,
      IniConfig() => SourceDialect.wgIni,
      AmneziaConfig() => SourceDialect.uri,
      DecodeFailure() => null,
    };

/// Вид текста, пришедшего снаружи, без резки на элементы: движок по реестру.
/// Не опознан — JSON-подобный текст (`{`, `[` не `.conf`) → `singbox`
/// (прежнее поведение `json`, §11 п.6), прочее → `uri`.
///
/// Вызывать только на входе текста и в миграции старой записи (`json`, нет
/// вида): хранимый текст по нему не перепроверяется.
SourceDialect sourceDialectOf(String text) {
  final t = text.trim();
  if (t.isEmpty) return SourceDialect.uri;
  final plain = uncommentedJson(t) ?? t;
  final decoded = decode(plain);
  final d = dialectOfDecoded(decoded);
  if (d != null) {
    // Ветка «всё остальное» реестра отдаёт `UriLines` и битому JSON: такой
    // текст ссылкой не был никогда.
    if (d == SourceDialect.uri && _looksJson(plain, decoded)) {
      return SourceDialect.singbox;
    }
    return d;
  }
  return _looksJson(plain, decoded) ? SourceDialect.singbox : SourceDialect.uri;
}

/// §11 п.6 — миграция записи без нового вида: `json`, пусто, чужое значение,
/// а также `uri`, чей текст — JSON. Вид — движком; JSON без вида → `singbox`.
SourceDialect migrateLegacyDialect(String raw) => sourceDialectOf(raw);

bool _looksJson(String t, DecodedBody decoded) {
  if (decoded is IniConfig || decoded is AmneziaConfig) return false;
  final h = t.trimLeft();
  return h.startsWith('{') || h.startsWith('[');
}

/// §722 — классификация входа: вид + элементы (массив режется, документ
/// обрезается до узловых массивов).
SourceClassification classifySource(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return const SourceClassification(dialect: null, items: []);
  }
  final uncommented = uncommentedJson(trimmed);
  final plain = uncommented ?? trimmed;
  final commentsRemoved = uncommented != null;
  final decoded = decode(plain);

  if (decoded is IniConfig || decoded is AmneziaConfig) {
    final d = dialectOfDecoded(decoded)!;
    return SourceClassification(
        dialect: d, items: [SourceItem(trimmed, d)]);
  }

  if (_looksJson(plain, decoded)) {
    Object? value;
    try {
      value = jsonDecode(plain);
    } on FormatException catch (e) {
      return SourceClassification(
          dialect: null, items: const [], jsonError: e.message);
    }
    if (decoded is! JsonConfig) {
      return SourceClassification(
          dialect: null, items: const [], commentsRemoved: commentsRemoved);
    }
    final d = dialectOfDecoded(decoded);
    if (d == null) {
      return SourceClassification(
          dialect: null, items: const [], commentsRemoved: commentsRemoved);
    }
    final elements = decoded.source.elements ?? r'$self';
    if (elements.startsWith('[]') && value is List) {
      final docs = elements != '[]';
      return SourceClassification(
        dialect: d,
        wasArray: true,
        commentsRemoved: commentsRemoved,
        items: [
          for (final e in value)
            if (e is Map)
              docs
                  ? _trimmedDocument(e.cast<String, dynamic>(), d, null)
                  : SourceItem(_indent(e), d),
        ],
      );
    }
    if (value is Map && elements != r'$self') {
      return SourceClassification(
        dialect: d,
        commentsRemoved: commentsRemoved,
        items: [_trimmedDocument(value.cast<String, dynamic>(), d, plain)],
      );
    }
    return SourceClassification(
      dialect: d,
      commentsRemoved: commentsRemoved,
      items: [SourceItem(plain, d)],
    );
  }

  final d = dialectOfDecoded(decoded);
  if (d == null) return const SourceClassification(dialect: null, items: []);
  return SourceClassification(dialect: d, items: [SourceItem(trimmed, d)]);
}

/// Документ, обрезанный до узловых массивов. [asTyped] — исходный текст:
/// обрезать нечего — текст как набран, байт в байт.
SourceItem _trimmedDocument(
    Map<String, dynamic> doc, SourceDialect d, String? asTyped) {
  final keys = nodeArrayKeysOf(d);
  final extras = doc.keys.any((k) => !keys.contains(k));
  if (!extras && asTyped != null) return SourceItem(asTyped, d);
  final out = <String, dynamic>{
    for (final e in doc.entries)
      if (keys.contains(e.key)) e.key: e.value,
  };
  return SourceItem(_indent(out), d, extrasDropped: extras);
}

String _indent(Object? v) => const JsonEncoder.withIndent('  ').convert(v);

/// Служебные протоколы Xray — не владелец документа.
const Set<String> _kXrayNonNodeProtocols = {
  'freedom',
  'blackhole',
  'dns',
  'loopback',
};

/// Служебные и групповые типы sing-box — не владелец документа (зеркало
/// приватных наборов парсера `singbox_config.dart`).
const Set<String> _kSingboxNonNodeTypes = {
  'direct',
  'block',
  'dns',
  'selector',
  'urltest',
};

/// §722 — переименование узла документа [doc] (на месте): узел с тегом
/// [oldTag] (нет такого или `null` — владелец: первая запись узловых
/// массивов, не служебная, не группа и не звено другой записи) получает
/// [newTag], ссылки на его прежний тег ВНУТРИ документа переписываются:
/// sing-box — `detour`, Xray — `streamSettings.sockopt.dialerProxy`.
///
/// `routing.rules[].outboundTag` / `routing.balancers[].selector` Xray здесь
/// не переписываются: `routing` в источнике не хранится (обрезка до узловых
/// массивов, §11 п.2) и снят до переименования. Ссылки из других записей
/// (личный detour члена папки) идут через `NodeLink`, как и прежде.
///
/// `false` — переименовывать нечего (узла нет, тег тот же).
bool renameNodeInDocument(
    Map<String, dynamic> doc, SourceDialect dialect, String newTag,
    {String? oldTag}) {
  final entries = <Map<String, dynamic>>[
    // Порядок выбора владельца прежний (§435): `endpoints`, затем `outbounds`.
    for (final k in dialect == SourceDialect.singbox
        ? const ['endpoints', 'outbounds']
        : const ['outbounds'])
      if (doc[k] is List)
        for (final e in doc[k] as List)
          if (e is Map<String, dynamic>) e,
  ];
  String? refOf(Map<String, dynamic> e) => dialect == SourceDialect.singbox
      ? e['detour'] as String?
      : ((e['streamSettings'] as Map?)?['sockopt'] as Map?)?['dialerProxy']
          as String?;
  void setRef(Map<String, dynamic> e, String v) {
    if (dialect == SourceDialect.singbox) {
      e['detour'] = v;
    } else {
      ((e['streamSettings'] as Map)['sockopt'] as Map)['dialerProxy'] = v;
    }
  }

  Map<String, dynamic>? target;
  if (oldTag != null && oldTag.isNotEmpty) {
    for (final e in entries) {
      if (e['tag'] == oldTag) {
        target = e;
        break;
      }
    }
  }
  if (target == null) {
    final linkTargets = {for (final e in entries) ?refOf(e)};
    for (final e in entries) {
      final t = e['tag'];
      if (t is String && linkTargets.contains(t)) continue;
      if (dialect == SourceDialect.singbox) {
        final type = e['type'];
        if (type is! String || _kSingboxNonNodeTypes.contains(type)) continue;
      } else {
        final p = e['protocol'];
        if (p is! String || _kXrayNonNodeProtocols.contains(p)) continue;
      }
      target = e;
      break;
    }
  }
  if (target == null) return false;
  final was = target['tag'];
  if (was == newTag) return false;
  target['tag'] = newTag;
  if (was is String && was.isNotEmpty) {
    for (final e in entries) {
      if (refOf(e) == was) setRef(e, newTag);
    }
  }
  return true;
}
