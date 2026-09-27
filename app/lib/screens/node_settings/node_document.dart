/// §435 — подготовка текста JSON-вкладки редактора узла к сохранению.
/// Чистая функция без Flutter: экран отдаёт ей текст и поле Tag, получает
/// либо текст для контроллера, либо причину отказа.
///
/// Принимаются два вида входа:
/// - голое тело outbound'а/endpoint'а — объект с `type` на верхнем уровне
///   (массив тел → первый элемент, как раньше);
/// - документ `{ "endpoints"|"outbounds": [тело], … }`.
///
/// §575 — из документа сохраняется только узел: `dns`, `route` и `sections`
/// рядом с ним не сохраняются, отказа нет. Экран по флагу
/// [NodeDocumentReady.droppedExtras] говорит пользователю, что остальное
/// содержимое документа отброшено.
///
/// Тег из поля Tag подмешивается в ТЕЛО узла (первый не-служебный элемент
/// `endpoints`/`outbounds`), а не в корень документа.
library;

import 'dart:convert';

import '../../models/codec/source_record.dart';
import '../../models/node_spec.dart';
import '../../models/singbox_entry.dart';
import '../../models/template_vars.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/parser/body_decoder.dart';
import '../../services/parser/parse_all.dart';

sealed class NodeDocumentPrep {
  const NodeDocumentPrep();
}

/// Текст готов к `updateConnectionAt` / `updateMemberAt`.
final class NodeDocumentReady extends NodeDocumentPrep {
  const NodeDocumentReady(this.text,
      {required this.isDocument, this.droppedExtras = false});

  /// Компактный JSON: тело узла или документ целиком.
  final String text;

  /// true — вход был документом (`endpoints`/`outbounds` в корне).
  final bool isDocument;

  /// §575 — документ нёс `dns`, `route` или `sections`: узел сохраняется,
  /// остальное содержимое документа — нет.
  final bool droppedExtras;
}

/// Сохранение отказано; [message] — готовая строка для снекбара.
final class NodeDocumentRejected extends NodeDocumentPrep {
  const NodeDocumentRejected(this.message);
  final String message;
}

/// Служебные и групповые типы sing-box — не тело узла, тег в них не
/// подмешивается (зеркало приватных наборов парсера `singbox_config.dart`:
/// `_kSingboxServiceTypes` + `_kSingboxGroupTypes`).
const Set<String> _kNonNodeTypes = {
  'direct',
  'block',
  'dns',
  'selector',
  'urltest',
};

NodeDocumentPrep prepareNodeDocumentForSave(String text, String tag) {
  final Object? parsed;
  try {
    parsed = jsonDecode(text);
  } on FormatException catch (e) {
    return NodeDocumentRejected(
        getLocalText.s("Invalid JSON: %s", e.message));
  }

  // Массив тел — первый элемент (прежнее поведение редактора).
  Object? root = parsed;
  if (root is List) {
    if (root.isEmpty) {
      return NodeDocumentRejected(getLocalText.s("Invalid JSON: empty array"));
    }
    root = root.first;
  }
  if (root is! Map) {
    return NodeDocumentRejected(getLocalText.s(
        "JSON must be an outbound object with \"type\" or a document with \"endpoints\"/\"outbounds\""));
  }
  final map = root.cast<String, dynamic>();
  final newTag = tag.trim();

  // Голое тело: `type` на верхнем уровне. Секции не трогает — контроллер
  // получает тело без `sections`/`dns`/`route` и оставляет контейнер как есть.
  // §455 — тег не менялся → текст уходит как набран (источник байт в байт),
  // перекодируется только ради подмены тега.
  if (map['type'] is String) {
    if (newTag.isEmpty || map['tag'] == newTag) {
      return NodeDocumentReady(text, isDocument: false);
    }
    map['tag'] = newTag;
    return NodeDocumentReady(jsonEncode(map), isDocument: false);
  }

  final endpoints = map['endpoints'];
  final outbounds = map['outbounds'];
  final hasEndpoints = endpoints is List;
  final hasOutbounds = outbounds is List;
  if (!hasEndpoints && !hasOutbounds) {
    return NodeDocumentRejected(getLocalText.s(
        "JSON must be an outbound object with \"type\" or a document with \"endpoints\"/\"outbounds\""));
  }

  // §575 — `dns`/`route`/`sections` документа не сохраняются; отказа нет.
  final dropped = map.containsKey('sections') ||
      map.containsKey('dns') ||
      map.containsKey('route');

  // Тег — в первое тело узла (endpoints раньше outbounds: у документа с
  // WireGuard/Tailscale узел лежит там, а в outbounds — direct/block).
  if (newTag.isNotEmpty) {
    final body = _firstNodeBody([
      if (hasEndpoints) ...endpoints,
      if (hasOutbounds) ...outbounds,
    ]);
    if (body != null && body['tag'] != newTag) {
      body['tag'] = newTag;
      return NodeDocumentReady(jsonEncode(map),
          isDocument: true, droppedExtras: dropped);
    }
  }
  return NodeDocumentReady(text, isDocument: true, droppedExtras: dropped);
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
    nodes = parseAll(decode(text));
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
