/// §435 — подготовка текста JSON-вкладки редактора узла к сохранению.
/// Чистая функция без Flutter: экран отдаёт ей текст и поле Tag, получает
/// либо текст для контроллера, либо причину отказа.
///
/// §576 — в источник записи уходит ТОЛЬКО ТЕЛО УЗЛА (вид `singbox_outbound`,
/// PARSING_PRINCIPLES §11). Документ и массив — формы ввода, не хранения:
/// - голое тело (объект с `type`) — текст как набран, байт в байт;
///   перекодируется только при смене тега;
/// - документ (`outbounds`/`endpoints` в корне) — тело первого узла, не
///   служебного (`direct`, `block`, `dns`) и не группы (`selector`,
///   `urltest`); подходящего узла нет — отказ;
/// - массив тел — первый элемент.
///
/// Извлечённое тело пишется JSON с отступом в два пробела. Было во входе
/// что-то кроме этого узла — [NodeDocumentReady.droppedExtras], экран
/// говорит одно сообщение: узел сохранён, остальное нет.
///
/// Тег из поля Tag подмешивается в тело узла.
library;

import 'dart:convert';

import '../../models/codec/source_record.dart';
import '../../models/node_spec.dart';
import '../../models/singbox_entry.dart';
import '../../models/template_vars.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/parser/body_decoder.dart';
import '../../services/parser/json_comments.dart';
import '../../services/parser/parse_all.dart';

sealed class NodeDocumentPrep {
  const NodeDocumentPrep();
}

/// Текст готов к `updateConnectionAt` / `updateMemberAt`.
final class NodeDocumentReady extends NodeDocumentPrep {
  const NodeDocumentReady(this.text,
      {required this.isDocument,
      this.droppedExtras = false,
      this.commentsRemoved = false});

  /// §585 — во входе были комментарии `//` или `/* */`; в [text] их нет.
  final bool commentsRemoved;

  /// §576 — голое тело узла: как набрано, либо извлечённое из документа или
  /// массива (JSON с отступом в два пробела).
  final String text;

  /// true — вход был документом (`endpoints`/`outbounds` в корне).
  final bool isDocument;

  /// §576 — во входе было что-то кроме сохранённого узла (прочие записи
  /// документа или массива, `dns`, `route`, `sections`): оно не сохранено.
  final bool droppedExtras;
}

/// Сохранение отказано; [message] — готовая строка для снекбара.
final class NodeDocumentRejected extends NodeDocumentPrep {
  const NodeDocumentRejected(this.message);
  final String message;
}

/// Служебные и групповые типы sing-box — не тело узла (зеркало приватных
/// наборов парсера `singbox_config.dart`: `_kSingboxServiceTypes` +
/// `_kSingboxGroupTypes`).
const Set<String> _kNonNodeTypes = {
  'direct',
  'block',
  'dns',
  'selector',
  'urltest',
};

/// Ключи документа, где лежат узлы.
const Set<String> _kNodeListKeys = {'outbounds', 'endpoints'};

/// §594 — текст вкладки Source идёт JSON-веткой Save
/// ([prepareNodeDocumentForSave] + ворота ядра). `{` — всегда JSON. `[` —
/// JSON-массив, КРОМЕ WireGuard/AWG INI: он тоже начинается с `[`
/// (`[Interface]`), и принять его за массив значило отказать в сохранении
/// с «Invalid JSON: Unexpected character».
bool isJsonSourceText(String text) {
  final t = text.trim();
  if (t.startsWith('{')) return true;
  return t.startsWith('[') && originKindOf(t) != 'wg_ini';
}

NodeDocumentPrep prepareNodeDocumentForSave(String text, String tag) {
  // §585 — комментарии снимаются до разбора; в источник уходит текст без них.
  final uncommented = uncommentedJson(text);
  if (uncommented == null) return _prepare(text, tag);
  final prep = _prepare(uncommented, tag);
  return switch (prep) {
    NodeDocumentReady r => NodeDocumentReady(r.text,
        isDocument: r.isDocument,
        droppedExtras: r.droppedExtras,
        commentsRemoved: true),
    NodeDocumentRejected() => prep,
  };
}

NodeDocumentPrep _prepare(String text, String tag) {
  final Object? parsed;
  try {
    parsed = jsonDecode(text);
  } on FormatException catch (e) {
    return NodeDocumentRejected(
        getLocalText.s("Invalid JSON: %s", e.message));
  }

  final newTag = tag.trim();

  if (parsed is List) {
    if (parsed.isEmpty) {
      return NodeDocumentRejected(getLocalText.s("Invalid JSON: empty array"));
    }
    final first = parsed.first;
    if (first is! Map || first['type'] is! String) {
      return NodeDocumentRejected(getLocalText.s(
          "JSON must be an outbound object with \"type\" or a document with \"endpoints\"/\"outbounds\""));
    }
    return NodeDocumentReady(
      _bodyText(first.cast<String, dynamic>(), newTag),
      isDocument: false,
      droppedExtras: parsed.length > 1,
    );
  }
  if (parsed is! Map) {
    return NodeDocumentRejected(getLocalText.s(
          "JSON must be an outbound object with \"type\" or a document with \"endpoints\"/\"outbounds\""));
  }
  final map = parsed.cast<String, dynamic>();

  if (map['type'] is String) {
    if (newTag.isEmpty || map['tag'] == newTag) {
      return NodeDocumentReady(text, isDocument: false);
    }
    map['tag'] = newTag;
    return NodeDocumentReady(jsonEncode(map), isDocument: false);
  }

  if (map['endpoints'] is! List && map['outbounds'] is! List) {
    return NodeDocumentRejected(getLocalText.s(
          "JSON must be an outbound object with \"type\" or a document with \"endpoints\"/\"outbounds\""));
  }

  // Порядок выбора прежний (§435): `endpoints`, затем `outbounds`.
  final endpoints = map['endpoints'];
  final outbounds = map['outbounds'];
  final entries = <Object?>[
    if (endpoints is List) ...endpoints,
    if (outbounds is List) ...outbounds,
  ];
  final body = _firstNodeBody(entries);
  if (body == null) {
    return NodeDocumentRejected(
        getLocalText.s("The document has no node to save."));
  }
  final restNotKept = entries.length > 1 ||
      map.keys.any((k) => !_kNodeListKeys.contains(k));
  return NodeDocumentReady(
    _bodyText(body, newTag),
    isDocument: true,
    droppedExtras: restNotKept,
  );
}

/// Извлечённое тело узла с тегом из поля Tag, JSON с отступом в два пробела.
String _bodyText(Map<String, dynamic> body, String newTag) {
  final out = Map<String, dynamic>.from(body);
  if (newTag.isNotEmpty) out['tag'] = newTag;
  return const JsonEncoder.withIndent('  ').convert(out);
}

/// §455 — полезная нагрузка для `Libbox.checkConfig()`: минимальный конфиг
/// из одного узла — тело источника (`rawSource` первого узла, §454: оригинал
/// outbound'а и у голого тела, и у документа) без `detour` (ссылка на чужой
/// тег ядру неизвестна) под `outbounds` или `endpoints` по типу узла.
/// `null` — текст не дал узла; об этом скажет контроллер при сохранении.
///
/// Д-1 (эмулятор 19.09.2026) — проверяется РОВНО ТО, ЧТО УЙДЁТ В ЯДРО.
/// Дословно уходит только sing-box-источник (`verbatimBodyOf`); Xray-объект
/// собирается моделью, и отдать ядру его оригинал значило бы отвергнуть на
/// Save узел, который в конфиге работает.
String? checkPayloadFor(String text) {
  final List<NodeSpec> nodes;
  try {
    // §585 — разбор своего источника: узел незнакомого типа тоже проверяется.
    nodes = parseAll(decode(text), own: true);
  } catch (_) {
    return null;
  }
  if (nodes.isEmpty) return null;
  final node = nodes.first;
  final entry = node.emit(TemplateVars.empty);
  final key = switch (entry) {
    Endpoint() => 'endpoints',
    Outbound() => 'outbounds',
  };
  Map<String, dynamic> body;
  if (sourceIsSingbox(text)) {
    final Object? decoded;
    try {
      decoded = jsonDecode(node.rawSource);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    body = Map<String, dynamic>.from(decoded);
  } else {
    body = Map<String, dynamic>.from(entry.map);
  }
  body.remove('detour');
  return jsonEncode({
    key: [body],
  });
}

/// Первый элемент, похожий на тело узла: объект с `type`, не служебный и
/// не группа. `null` — тела нет (контроллер сам скажет, что узлов не вышло).
Map<String, dynamic>? _firstNodeBody(List<Object?> entries) {
  for (final e in entries) {
    if (e is! Map) continue;
    final type = e['type'];
    if (type is! String || _kNonNodeTypes.contains(type)) continue;
    return e.cast<String, dynamic>();
  }
  return null;
}
