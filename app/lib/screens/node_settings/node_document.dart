/// §435 / §722 — подготовка текста вкладки Source редактора узла к
/// сохранению. Чистая функция: экран отдаёт ей текст и поле Tag, получает
/// либо текст и ВИД записи для контроллера, либо причину отказа.
///
/// §722 (контракт 1.1.165, PARSING_PRINCIPLES §11) — Save на Source — новый
/// вход текста: вид определяет движок ([classifySource]), и вставка другого
/// диалекта МЕНЯЕТ вид записи, а не отвергается. Источник хранится в своём
/// диалекте:
/// - голое тело (sing-box `{"type":…}`, Xray `{"protocol":…}`) — как набрано;
///   перекодируется только при смене тега;
/// - документ — целиком, обрезанный до узловых массивов (`outbounds` /
///   `endpoints` у sing-box, `outbounds` у Xray); узла нет — отказ;
/// - массив — форма ввода: при правке одного узла в источник идёт первый
///   элемент (TASKS_LXBOX §165 п.5 (а));
/// - ссылка и `.conf` — текст как есть.
///
/// Было во входе что-то кроме сохранённого — [NodeDocumentReady.droppedExtras],
/// экран говорит одно сообщение.
///
/// §456 — поле Tag переименовывает узел записью (`tag`), а не текстом:
/// [NodeDocumentReady.nameHint]. Текст правится только для имён не-первых
/// узлов JSON-документа ([renameRecordNode]).
library;

import 'dart:convert';

import '../../models/node_spec.dart';
import '../../models/singbox_entry.dart';
import '../../models/source_dialect.dart';
import '../../services/builder/verbatim_body.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/parser/body_decoder.dart';
import '../../services/parser/json_comments.dart';
import '../../services/parser/parse_all.dart';
import '../../services/parser/source_classify.dart';

sealed class NodeDocumentPrep {
  const NodeDocumentPrep();
}

/// Текст готов к `updateConnectionAt` / `updateMemberAt`.
final class NodeDocumentReady extends NodeDocumentPrep {
  const NodeDocumentReady(this.text,
      {required this.dialect,
      required this.isDocument,
      this.droppedExtras = false,
      this.nameHint});

  /// Текст источника записи в своём диалекте.
  final String text;

  /// §722 — вид записи после сохранения (`origin.kind`).
  final SourceDialect dialect;

  /// true — источник документ (`endpoints`/`outbounds` в корне).
  final bool isDocument;

  /// Во входе было что-то кроме сохранённого (ключи документа вне узловых
  /// массивов, элементы массива после первого): оно не сохранено.
  final bool droppedExtras;

  /// §456 — переименование из поля Tag: уходит в `tag` записи. `null` —
  /// поле не трогали (или пусто).
  final String? nameHint;
}

/// Сохранение отказано; [message] — готовая строка для снекбара.
final class NodeDocumentRejected extends NodeDocumentPrep {
  const NodeDocumentRejected(this.message);
  final String message;
}

String get _notANodeMessage => getLocalText.s(
    "JSON must be a sing-box or Xray outbound, or a document with outbounds/endpoints");

/// §722 — [text] вкладки Source → текст и вид записи. [tag] — поле Tag.
///
/// [tagTouched] — поле Tag меняли на экране. `false` — переименования нет:
/// имя решает контроллер (изменённое в тексте, иначе прежнее — §456).
NodeDocumentPrep prepareNodeDocumentForSave(String text, String tag,
    {bool tagTouched = true}) {
  final c = classifySource(text);
  if (c.jsonError != null) {
    return NodeDocumentRejected(
        getLocalText.s("Invalid JSON: %s", c.jsonError!));
  }
  final dialect = c.dialect;
  if (dialect == null || c.items.isEmpty) {
    if (_isEmptyArray(text)) {
      return NodeDocumentRejected(getLocalText.s("Invalid JSON: empty array"));
    }
    return NodeDocumentRejected(_notANodeMessage);
  }
  final item = c.items.first;
  final dropped = item.extrasDropped || c.items.length > 1;
  // §456 — переименование пишется в `tag` записи ([NodeDocumentReady.nameHint]),
  // текст источника не меняется.
  final rename = tagTouched ? tag.trim() : '';

  if (item.isDocument) {
    final List<NodeSpec> nodes;
    try {
      nodes = parseAll(decode(item.text), own: true);
    } catch (_) {
      return NodeDocumentRejected(
          getLocalText.s("The document has no node to save."));
    }
    if (nodes.isEmpty) {
      return NodeDocumentRejected(
          getLocalText.s("The document has no node to save."));
    }
  }
  return NodeDocumentReady(
    item.text,
    dialect: item.dialect,
    isDocument: item.isDocument,
    droppedExtras: dropped,
    nameHint: rename.isEmpty ? null : rename,
  );
}

/// §722 D — переименование ещё одного узла записи (звено, второй корень)
/// поверх уже подготовленного [base]: узел с тегом [oldTag] получает
/// [newTag], ссылки на него внутри текста переписываются
/// ([renameNodeInDocument]). Только JSON-диалекты; узла с [oldTag] в тексте
/// нет (Source правили) или тег тот же — [base] как есть: фолбэк
/// «нет узла → владелец» здесь недопустим. Флаги [base] сохраняются.
NodeDocumentPrep renameRecordNode(
    NodeDocumentReady base, String oldTag, String newTag) {
  final t = newTag.trim();
  if (!base.dialect.isJson || t.isEmpty || t == oldTag) return base;
  if (!documentHasNodeTag(base.text, base.dialect, oldTag)) return base;
  return NodeDocumentReady(
      _withTag(base.text, base.dialect, t, oldTag: oldTag),
      dialect: base.dialect,
      isDocument: base.isDocument,
      droppedExtras: base.droppedExtras,
      nameHint: base.nameHint);
}

/// §722 D — в JSON-документе [text] (узловые массивы вида [dialect]) есть
/// запись с тегом [tag].
bool documentHasNodeTag(String text, SourceDialect dialect, String tag) {
  final Object? v;
  try {
    v = jsonDecode(jsonSourceText(text));
  } catch (_) {
    return false;
  }
  if (v is! Map) return false;
  for (final k in nodeArrayKeysOf(dialect)) {
    final arr = v[k];
    if (arr is! List) continue;
    for (final e in arr) {
      if (e is Map && e['tag'] == tag) return true;
    }
  }
  return false;
}

bool _isEmptyArray(String text) {
  try {
    final v = jsonDecode(jsonSourceText(text.trim()));
    return v is List && v.isEmpty;
  } catch (_) {
    return false;
  }
}

/// Правило тега по виду для JSON-диалектов. Тег не меняется — [text] как
/// есть (байт в байт).
///
/// §741 — голое тело с комментариями получает тег правкой текста
/// ([withJsonTag]): пометки автора остаются. Документ с комментариями при
/// смене тега пересобирается (комментарии теряются — известное ограничение,
/// как у правки формой).
String _withTag(String text, SourceDialect dialect, String newTag,
    {String? oldTag}) {
  if (newTag.isEmpty) return text;
  final plain = uncommentedJson(text);
  final Object? parsed;
  try {
    parsed = jsonDecode(plain ?? text);
  } catch (_) {
    return text;
  }
  if (parsed is! Map) return text;
  final map = parsed.cast<String, dynamic>();
  final keys = nodeArrayKeysOf(dialect);
  final isDocument = keys.any((k) => map[k] is List) &&
      map[dialect == SourceDialect.singbox ? 'type' : 'protocol'] == null;
  if (!isDocument) {
    if (map['tag'] == newTag) return text;
    if (plain != null) {
      final edited = withJsonTag(text, newTag);
      if (edited != null) return edited;
    }
    map['tag'] = newTag;
    return jsonEncode(map);
  }
  final changed = renameNodeInDocument(map, dialect, newTag, oldTag: oldTag);
  return changed ? const JsonEncoder.withIndent('  ').convert(map) : text;
}

/// §455 — полезная нагрузка для `Libbox.checkConfig()`: минимальный конфиг из
/// ВСЕХ узлов записи (§722: владельцы документа и звенья их цепочек, `main +
/// detours`) без `detour` (ссылки решает сборка) под `outbounds` или
/// `endpoints` по типу. `null` — текст не дал узла; об этом скажет
/// контроллер при сохранении.
///
/// Проверяется РОВНО ТО, ЧТО УЙДЁТ В ЯДРО: у вида `singbox` тело владельца —
/// дословное ([verbatimBodyOf]), у прочих видов и у звеньев — эмиссия модели.
String? checkPayloadFor(String text, SourceDialect dialect) {
  final List<NodeSpec> nodes;
  try {
    // §585 — разбор своего источника: узел незнакомого типа тоже проверяется.
    nodes = parseAll(decode(text), own: true);
  } catch (_) {
    return null;
  }
  if (nodes.isEmpty) return null;
  final outbounds = <Map<String, dynamic>>[];
  final endpoints = <Map<String, dynamic>>[];
  void add(SingboxEntry entry, Map<String, dynamic> body) {
    body.remove('detour');
    (entry is Endpoint ? endpoints : outbounds).add(body);
  }

  for (final node in nodes) {
    final entries = node.getEntries(null);
    final main = verbatimBodyOf(dialect, node) ??
        Map<String, dynamic>.from(entries.main.map);
    add(entries.main, main);
    for (final d in entries.detours) {
      add(d, Map<String, dynamic>.from(d.map));
    }
  }
  return jsonEncode({
    if (outbounds.isNotEmpty) 'outbounds': outbounds,
    if (endpoints.isNotEmpty) 'endpoints': endpoints,
  });
}
