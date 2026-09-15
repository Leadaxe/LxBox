/// §445 — ключи узлов Tailscale для каталогов состояния (`state_directory`).
///
/// Ключ — строка индекса `tailscale_state.json`, не имя каталога:
///
/// - одиночный сервер — `<id сервера>`, второй и следующие узлы Tailscale
///   того же сервера — `<id>#2`…; переименование и смена префикса ключ не
///   меняют;
/// - член папки и узел подписки — `<id контейнера>/<сырой тег>` (тот же сырой
///   тег, что в адресе NodeLink, `node_link_address.dart`); тёзка с тем же
///   тегом в папке — `…#2`.
///
/// Ключи считаются по ВСЕМ хранимым узлам: выключенный узел, член, папка или
/// источник ключ сохраняет. Функции чистые; файлы — `state_store.dart`.
library;

import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../node_link_address.dart';
import '../tag_resolver.dart';

/// §435 — имя каталога состояния из финальной формы тега: всё вне
/// `[A-Za-z0-9._-]` → `_` (пробелы, `/`, `:` префикса), пустой результат →
/// `tailscale`. Тот же allowlist, что у лаунчера (`<exec>/bin/tailscale/…`),
/// чтобы каталог был один на узел, а не дерево. §445: применяется только к
/// выдаваемому имени, личность узла держит ключ индекса.
String tailscaleStateDirName(String finalTag) {
  final cleaned =
      finalTag.replaceAll(RegExp(r'[^A-Za-z0-9._-]', unicode: true), '_');
  return cleaned.isEmpty ? 'tailscale' : cleaned;
}

/// Узел Tailscale источника с ключом индекса.
final class TailscaleStateNode {
  const TailscaleStateNode({
    required this.node,
    required this.key,
    required this.baseName,
  });

  final TailscaleSpec node;

  /// Ключ индекса (см. библиотеку).
  final String key;

  /// Имя каталога без суффикса: `tailscaleStateDirName(<префикс> <тег>)` —
  /// финальная форма без уникализации сборки. По нему выдаётся новое имя и
  /// ищется каталог 2.24.0 при миграции.
  final String baseName;
}

/// Итог обхода источников.
final class TailscaleStateScan {
  const TailscaleStateScan({
    required this.nodes,
    required this.unresolvedContainers,
    required this.explicitDirs,
  });

  /// Узлы Tailscale в порядке источников и узлов (выключенные включены).
  final List<TailscaleStateNode> nodes;

  /// id контейнеров, узлы которых сейчас не разобраны (подписка без тела,
  /// сервер с нечитаемым телом, член папки с битым текстом): их записи
  /// индекса не снимаются.
  final Set<String> unresolvedContainers;

  /// Явные `state_directory` из тел узлов: индекс им запись не заводит, а
  /// каталоги с такими путями не удаляются.
  final Set<String> explicitDirs;

  Set<String> get keys => {for (final n in nodes) n.key};
}

/// Обход всех хранимых узлов Tailscale [lists].
TailscaleStateScan scanTailscaleStateNodes(List<ServerList> lists) {
  final nodes = <TailscaleStateNode>[];
  final unresolved = <String>{};
  final explicit = <String>{};

  String? explicitDir(TailscaleSpec node) {
    final v = node.body['state_directory'];
    return v is String && v.trim().isNotEmpty ? v.trim() : null;
  }

  for (final l in lists) {
    switch (l) {
      case UserServer u:
        if (u.nodes.isEmpty) unresolved.add(u.id);
        var n = 0;
        for (final node in u.nodes) {
          if (node is! TailscaleSpec) continue;
          n++;
          final own = explicitDir(node);
          if (own != null) {
            explicit.add(own);
            continue;
          }
          nodes.add(TailscaleStateNode(
            node: node,
            key: n == 1 ? u.id : '${u.id}#$n',
            baseName: tailscaleStateDirName(
                TagResolver.displayTag(u.tagPrefix, node.tag)),
          ));
        }
      case FolderServers():
      case SubscriptionServers():
        if (l is SubscriptionServers && l.nodes.isEmpty) unresolved.add(l.id);
        if (l is FolderServers && l.members.any((m) => m.node == null)) {
          unresolved.add(l.id);
        }
        final raw = containerRawTags(l);
        final counts = <String, int>{};
        for (final node in containerNodes(l)) {
          if (node is! TailscaleSpec) continue;
          final tag = raw[node];
          if (tag == null || tag.isEmpty) {
            unresolved.add(l.id);
            continue;
          }
          final c = counts[tag] = (counts[tag] ?? 0) + 1;
          final own = explicitDir(node);
          if (own != null) {
            explicit.add(own);
            continue;
          }
          nodes.add(TailscaleStateNode(
            node: node,
            key: c == 1 ? '${l.id}/$tag' : '${l.id}/$tag#$c',
            baseName: tailscaleStateDirName(
                TagResolver.displayTag(l.tagPrefix, node.tag)),
          ));
        }
    }
  }
  return TailscaleStateScan(
    nodes: nodes,
    unresolvedContainers: unresolved,
    explicitDirs: explicit,
  );
}

/// Есть ли в [lists] хоть один узел Tailscale (включая выключенные).
bool hasTailscaleNodes(List<ServerList> lists) {
  for (final l in lists) {
    for (final n in containerNodes(l)) {
      if (n is TailscaleSpec) return true;
    }
  }
  return false;
}

/// Ключ [key] принадлежит контейнеру [id].
bool tailscaleKeyInContainer(String key, String id) =>
    key == id || key.startsWith('$id/') || key.startsWith('$id#');

/// Сменившиеся ключи узлов Tailscale между [before] и [after] операции
/// контроллера. Узел сопоставляется сам с собой по ссылке объекта или через
/// [renamed] («прежний узел → узел, который его заменил»), как в
/// `diffNodeAddresses`. Узел без пары или переставший быть Tailscale —
/// [gone]; с другим ключом — [moves]. [goneContainers] — id источников,
/// которых после операции нет: их записи снимаются целиком, включая записи
/// неразобранных узлов.
({
  Map<String, String> moves,
  Set<String> gone,
  Set<String> goneContainers,
}) diffTailscaleStateKeys(
  List<ServerList> before,
  List<ServerList> after, {
  Map<NodeSpec, NodeSpec> renamed = const {},
}) {
  Map<NodeSpec, String> keysOf(List<ServerList> lists) {
    final out = Map<NodeSpec, String>.identity();
    for (final n in scanTailscaleStateNodes(lists).nodes) {
      out[n.node] = n.key;
    }
    return out;
  }

  final was = keysOf(before);
  final now = keysOf(after);
  final moves = <String, String>{};
  final gone = <String>{};
  was.forEach((node, key) {
    final next = now[renamed[node] ?? node];
    if (next == null) {
      gone.add(key);
    } else if (next != key) {
      moves[key] = next;
    }
  });
  final afterIds = {for (final l in after) l.id};
  return (
    moves: moves,
    gone: gone,
    goneContainers: {
      for (final l in before)
        if (!afterIds.contains(l.id)) l.id,
    },
  );
}
