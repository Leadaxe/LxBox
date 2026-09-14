/// Ссылка на узел (D-112, §439 п. 8): «в какой папке» + «какой сырой тег».
///
/// Носители в модели LxBox — `DetourPolicy.overrideDetour` источника,
/// `FolderMember.detour`, `SourceChain.hops`. Пока они держат финальный тег
/// строкой; перевод строки в ссылку и обратно живёт в одном временном месте
/// кодека (`codec/node_link_record.dart`).
///
/// [folderId] пуст — корневое пространство финальных тегов: верхний узел,
/// Направление, служебный тег шаблона, другая цепочка. Непуст — `id` папки, а
/// [tag] — сырой тег узла внутри неё (до `tag_policy`). Финальный тег
/// вычисляет только сборка конфига.
library;

final class NodeLink {
  const NodeLink({this.folderId = '', required this.tag});

  /// `id` папки-владельца; пусто — корневая ссылка.
  final String folderId;

  /// Сырой тег узла в папке или финальный тег корневой ссылки. Пустой тег —
  /// законное значение позиции цепочки (невалидную позицию ловит
  /// `chainEmitError`, а не кодек).
  final String tag;

  bool get isRoot => folderId.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NodeLink && folderId == other.folderId && tag == other.tag);

  @override
  int get hashCode => Object.hash(folderId, tag);

  @override
  String toString() => isRoot ? 'NodeLink($tag)' : 'NodeLink($folderId/$tag)';
}
