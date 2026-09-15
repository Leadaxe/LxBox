/// Кодек ссылки на узел: [NodeLink] ↔ `{folder_id?, tag}` (`$defs/nodeLink`
/// схемы бэкапа 1.0). Общий для записей источников, цепочек и Debug API.
///
/// Здесь же терпимое чтение ссылок (NODE_LINK §7.3, решение сторон 15.09):
/// S1 — корневая ссылка `{tag}` внутри контейнера на его члена поднимается до
/// пары; S3 — пара с финальным тегом группы опускается до сырого тега. Оба
/// правила трогают ссылку, только когда кандидат ровно один; иначе ссылка
/// остаётся как есть и её разбирает сборка.
library;

import '../node_link.dart';

/// [NodeLink] → `{folder_id?, tag}`. Пустой `folder_id` не пишется.
Map<String, dynamic> nodeLinkToRecord(NodeLink link) => {
      if (link.folderId.isNotEmpty) 'folder_id': link.folderId,
      'tag': link.tag,
    };

/// [NodeLink] → `{folder_id?, tag}`, пустая ссылка → `null` (поле detour в
/// ответах Debug API).
Map<String, dynamic>? nodeLinkToRecordOrNull(NodeLink link) =>
    link.isEmpty ? null : nodeLinkToRecord(link);

/// `{folder_id?, tag}` → [NodeLink]. Терпимо к форме: строка читается
/// корневой ссылкой (так позиции и detour писались до 1.0), `folder_id`
/// подрезается, тег берётся как есть — пустую позицию цепочки кодек не
/// «чинит». Не объект и не строка — `null`.
NodeLink? nodeLinkFromRecord(Object? raw) {
  if (raw is String) return NodeLink(tag: raw);
  if (raw is! Map) return null;
  final folderId = raw['folder_id'];
  final tag = raw['tag'];
  return NodeLink(
    folderId: folderId is String ? folderId.trim() : '',
    tag: tag is String ? tag : '',
  );
}

/// S1 — корневая ссылка [link] на члена контейнера [containerId] (сырой тег из
/// [rawTags]) → пара. Уже пара, пустая ссылка и тег, которого среди членов
/// нет, возвращаются как есть.
NodeLink liftSiblingLink(
  NodeLink link,
  String containerId,
  Set<String> rawTags,
) {
  if (!link.isRoot || link.isEmpty || containerId.isEmpty) return link;
  if (!rawTags.contains(link.tag)) return link;
  return NodeLink(folderId: containerId, tag: link.tag);
}

/// S3 — пара [link] на контейнер [containerId], чей тег не сырой, а финальный
/// тег группы: [groupFinalForms] — «финальная форма (префикс + сырой тег) →
/// сырые теги групп с этой формой». Совпала ровно одна группа — пара с её
/// сырым тегом; иначе ссылка как есть.
NodeLink lowerGroupFinalLink(
  NodeLink link,
  String containerId,
  Set<String> rawTags,
  Map<String, List<String>> groupFinalForms,
) {
  if (link.isRoot || link.folderId != containerId) return link;
  if (rawTags.contains(link.tag)) return link;
  final candidates = groupFinalForms[link.tag];
  if (candidates == null || candidates.length != 1) return link;
  return NodeLink(folderId: containerId, tag: candidates.single);
}
