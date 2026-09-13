/// §435 — подготовка текста JSON-вкладки редактора узла к сохранению
/// (NODE_SECTIONS.md §7). Чистая функция без Flutter: экран отдаёт ей текст
/// и поле Tag, получает либо текст для контроллера, либо причину отказа.
///
/// Принимаются три вида входа:
/// - голое тело outbound'а/endpoint'а — объект с `type` на верхнем уровне
///   (массив тел → первый элемент, как раньше);
/// - документ `{ "endpoints"|"outbounds": [тело], "sections": {…} }`;
/// - sing-box-документ `{ "endpoints"|"outbounds": [ровно один узел],
///   "dns": {…}, "route": {…} }` — связку из него извлекает парсер.
///
/// Тег из поля Tag подмешивается в ТЕЛО узла (первый не-служебный элемент
/// `endpoints`/`outbounds`), а не в корень документа; документ уходит
/// контроллеру целиком — он парсит и переносит секции сам. Оба вида секций
/// (`sections` и `dns`/`route`) в одном документе — отказ: парсер подписок в
/// такой ситуации берёт `sections` и вешает warning, редактор же обязан
/// заставить выбрать один вид.
library;

import 'dart:convert';

import '../../services/l10n/locale_controller.dart';

sealed class NodeDocumentPrep {
  const NodeDocumentPrep();
}

/// Текст готов к `updateConnectionAt` / `updateMemberAt`.
final class NodeDocumentReady extends NodeDocumentPrep {
  const NodeDocumentReady(this.text, {required this.isDocument});

  /// Компактный JSON: тело узла или документ целиком.
  final String text;

  /// true — вход был документом (`endpoints`/`outbounds` в корне): после
  /// сохранения секции узла замещаются тем, что контроллер извлёк.
  final bool isDocument;
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
  if (map['type'] is String) {
    if (newTag.isNotEmpty) map['tag'] = newTag;
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

  final hasSections = map['sections'] is Map;
  final hasDnsRoute = map['dns'] is Map || map['route'] is Map;
  if (hasSections && hasDnsRoute) {
    return NodeDocumentRejected(getLocalText.s(
        "The document carries both \"sections\" and \"dns\"/\"route\" — keep only one of them"));
  }

  // Тег — в первое тело узла (endpoints раньше outbounds: у документа с
  // WireGuard/Tailscale узел лежит там, а в outbounds — direct/block).
  if (newTag.isNotEmpty) {
    final body = _firstNodeBody([
      if (hasEndpoints) ...endpoints,
      if (hasOutbounds) ...outbounds,
    ]);
    if (body != null) body['tag'] = newTag;
  }
  return NodeDocumentReady(jsonEncode(map), isDocument: true);
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
