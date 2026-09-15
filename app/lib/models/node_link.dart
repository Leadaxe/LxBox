/// Ссылка на узел (D-112, §439 п. 8): «в каком контейнере» + «какой сырой тег».
///
/// Носители в модели LxBox — `DetourPolicy.overrideDetour` источника,
/// `FolderMember.detour`, `SourceChain.hops`. Запись хранит ссылку как есть
/// (`codec/node_link_record.dart`), финальный тег вычисляет только сборка
/// конфига (`services/builder/node_link_resolve.dart`).
///
/// [folderId] пуст — корневое пространство финальных тегов: верхний узел,
/// Направление, служебный тег шаблона, другая цепочка. Непуст — `id` папки или
/// подписки, а [tag] — сырой тег узла внутри неё (до `tag_policy`).
library;

final class NodeLink {
  const NodeLink({this.folderId = '', required this.tag});

  /// Ссылки нет: detour не задан. Позиция цепочки с пустым тегом — законное
  /// значение модели, его ловит `chainEmitError`.
  static const none = NodeLink(tag: '');

  /// `id` контейнера-владельца; пусто — корневая ссылка.
  final String folderId;

  /// Сырой тег узла в контейнере или финальный тег корневой ссылки. Пустой
  /// тег — законное значение позиции цепочки (невалидную позицию ловит
  /// `chainEmitError`, а не кодек).
  final String tag;

  bool get isRoot => folderId.isEmpty;

  /// Пустой тег — ссылки нет.
  bool get isEmpty => tag.isEmpty;

  bool get isNotEmpty => tag.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NodeLink && folderId == other.folderId && tag == other.tag);

  @override
  int get hashCode => Object.hash(folderId, tag);

  @override
  String toString() => isRoot ? 'NodeLink($tag)' : 'NodeLink($folderId/$tag)';
}
