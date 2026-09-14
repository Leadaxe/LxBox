/// Кодек ссылки на узел: [NodeLink] ↔ `{folder_id?, tag}` (`$defs/nodeLink`
/// схемы бэкапа 1.0). Общий для записей источников и цепочек.
library;

import '../node_link.dart';

/// [NodeLink] → `{folder_id?, tag}`. Пустой `folder_id` не пишется.
Map<String, dynamic> nodeLinkToRecord(NodeLink link) => {
      if (link.folderId.isNotEmpty) 'folder_id': link.folderId,
      'tag': link.tag,
    };

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

// ─── ВРЕМЕННО: модели держат финальный тег строкой ─────────────────────────
//
// §439 п. 8 (D-112): `DetourPolicy.overrideDetour`, `FolderMember.detour` и
// `SourceChain.hops` переходят на [NodeLink] отдельным треком, когда придёт
// норма резолва лаунчера (`contract/docs/NODE_LINK.md`). До тех пор кодек
// записей переводит строку модели в корневую ссылку и обратно ТОЛЬКО здесь.
// С переводом моделей оба помощника удаляются, а вызовы в
// `source_record.dart` и `chain_record.dart` берут ссылку из модели.

/// Строка модели → корневая ссылка записи.
NodeLink linkOfModelTag(String tag) => NodeLink(tag: tag);

/// Ссылка записи → строка модели. Ссылку на член папки модель выразить не
/// может: без резолва финального тега берётся сырой тег, и [notes] получает
/// строку с [where], чтобы подмена не прошла молча.
String modelTagOfLink(NodeLink link, String where, List<String>? notes) {
  if (!link.isRoot) {
    notes?.add('$where: link to folder "${link.folderId}" is not resolved '
        'yet, tag "${link.tag}" is used as the final tag');
  }
  return link.tag;
}
