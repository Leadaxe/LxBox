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
/// Тег из поля Tag ставится по виду (одно место — [_withTag]):
///
/// | Вид | Куда |
/// |---|---|
/// | `singbox` | `tag` узла; в документе — `detour` ссылки на старый тег |
/// | `xray` | `tag` outbound'а; в документе — `streamSettings.sockopt.dialerProxy` |
/// | `uri` | фрагмент `#…` ([SubscriptionController.rawWithName]) |
/// | `wg_ini` | поле записи `nameHint` (§456) |
library;

import 'dart:convert';

import '../../controllers/subscription_controller.dart' show SubscriptionController;
import '../../models/node_spec.dart';
import '../../models/singbox_entry.dart';
import '../../models/source_dialect.dart';
import '../../services/builder/verbatim_body.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/parser/body_decoder.dart';
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
      this.commentsRemoved = false,
      this.nameHint});

  /// §585 — во входе были комментарии `//` или `/* */`; в [text] их нет.
  final bool commentsRemoved;

  /// Текст источника записи в своём диалекте.
  final String text;

  /// §722 — вид записи после сохранения (`origin.kind`).
  final SourceDialect dialect;

  /// true — источник документ (`endpoints`/`outbounds` в корне).
  final bool isDocument;

  /// Во входе было что-то кроме сохранённого (ключи документа вне узловых
  /// массивов, элементы массива после первого): оно не сохранено.
  final bool droppedExtras;

  /// §456 — у `wg_ini` имя узла: поле записи (в тексте его нет). Иначе
  /// `null`.
  final String? nameHint;
}

/// Сохранение отказано; [message] — готовая строка для снекбара.
final class NodeDocumentRejected extends NodeDocumentPrep {
  const NodeDocumentRejected(this.message);
  final String message;
}

String get _notANodeMessage => getLocalText.s(
    "JSON must be an outbound object with \"type\" or a document with \"endpoints\"/\"outbounds\"");

/// §722 — [text] вкладки Source → текст и вид записи. [tag] — поле Tag
/// (пусто — тег не трогается); [oldTag] — тег узла, который переименовывается
/// (у документа: узел с этим тегом, не найден или `null` — владелец, первый
/// узел записи).
NodeDocumentPrep prepareNodeDocumentForSave(String text, String tag,
    {String? oldTag}) {
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
  final newTag = tag.trim();

  switch (item.dialect) {
    case SourceDialect.uri:
      final t = item.text;
      final single = !t.contains('\n') && t.contains('://');
      return NodeDocumentReady(
        single && newTag.isNotEmpty
            ? SubscriptionController.rawWithName(t, newTag)
            : t,
        dialect: SourceDialect.uri,
        isDocument: false,
      );
    case SourceDialect.wgIni:
      return NodeDocumentReady(item.text,
          dialect: SourceDialect.wgIni,
          isDocument: false,
          nameHint: newTag.isEmpty ? null : newTag);
    case SourceDialect.singbox:
    case SourceDialect.xray:
      break;
  }

  final isDocument = item.isDocument;
  if (isDocument) {
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
  final out = _withTag(item.text, item.dialect, newTag,
      oldTag: oldTag, reencode: c.wasArray);
  return NodeDocumentReady(
    out,
    dialect: item.dialect,
    isDocument: isDocument,
    droppedExtras: dropped,
    commentsRemoved: c.commentsRemoved,
  );
}

bool _isEmptyArray(String text) {
  try {
    final v = jsonDecode(text.trim());
    return v is List && v.isEmpty;
  } catch (_) {
    return false;
  }
}

/// Правило тега по виду для JSON-диалектов. Тег не меняется — [text] как
/// есть (байт в байт); [reencode] — элемент массива (JSON с отступом).
String _withTag(String text, SourceDialect dialect, String newTag,
    {String? oldTag, bool reencode = false}) {
  if (newTag.isEmpty) return text;
  final Object? parsed;
  try {
    parsed = jsonDecode(text);
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
    map['tag'] = newTag;
    return reencode
        ? const JsonEncoder.withIndent('  ').convert(map)
        : jsonEncode(map);
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
