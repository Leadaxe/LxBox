/// Адреса узлов источников (D-112, NODE_LINK §2): чем [NodeLink] указывает
/// на узел. Один модуль на сборку, реестр ссылок, пикеры, миграцию и импорт —
/// разойтись в нумерации тёзок они не должны.
///
/// - член папки и узел подписки — пара `{id контейнера, сырой тег}`; сырой
///   тег члена папки — его тег как есть (у тёзок побеждает первый), узла
///   подписки — тег, уникализированный в источнике общим счётчиком с группами
///   ([sourceNodeRawTags], NODE_LINK §2.2);
/// - узел одиночного сервера — корневая ссылка `{tag}` с тегом, под которым
///   узел эмитится: префикс сервера + тег узла (без суффикса уникализации
///   сборки — его знает только сборка).
///
/// Та же норма сырого тега у состава autogroup (`resolveAutoSelectMembers`).
library;

import '../models/node_link.dart';
import '../models/node_spec.dart';
import '../models/server_list.dart';
import 'node_hash.dart';
import 'tag_resolver.dart';

/// Узлы контейнера с адресами: у папки — разобранные члены в их порядке (с
/// выключенными), у подписки — полный список (с выключенными: уникализация
/// тёзок зависит от соседей), у одиночного сервера — его узлы.
List<NodeSpec> containerNodes(ServerList l) => switch (l) {
      FolderServers f => [
          for (final m in f.members)
            if (m.node != null) m.node!,
        ],
      _ => l.nodes,
    };

/// Сырые теги узлов контейнера [l] (карта по ссылке узла). У одиночного
/// сервера — теги узлов (адрес у него корневой, см. [nodeAddressIn]).
Map<NodeSpec, String> containerRawTags(ServerList l) {
  if (l is SubscriptionServers) return sourceNodeRawTags(l.nodes);
  final out = Map<NodeSpec, String>.identity();
  for (final n in containerNodes(l)) {
    if (n.tag.isNotEmpty) out[n] = n.tag;
  }
  return out;
}

/// Сырые теги всех узлов контейнера [l] множеством (для S1/S3 и проверок).
Set<String> containerRawTagSet(ServerList l) =>
    containerRawTags(l).values.toSet();

/// Адрес узла [node] источника [l]. `null` — адреса нет (безымянный узел).
/// [raw] — готовая карта [containerRawTags] контейнера, чтобы не считать её
/// на каждый узел.
NodeLink? nodeAddressIn(
  ServerList l,
  NodeSpec node, {
  Map<NodeSpec, String>? raw,
}) {
  if (l is UserServer) {
    if (node.tag.isEmpty) return null;
    return NodeLink(tag: TagResolver.displayTag(l.tagPrefix, node.tag));
  }
  final tag = (raw ?? containerRawTags(l))[node];
  if (tag == null || tag.isEmpty) return null;
  return NodeLink(folderId: l.id, tag: tag);
}

/// Адреса всех узлов источника [l] в порядке узлов (выключенные включены).
List<NodeLink> sourceNodeAddresses(ServerList l) {
  final raw = l is UserServer ? null : containerRawTags(l);
  return [
    for (final n in containerNodes(l)) ?nodeAddressIn(l, n, raw: raw),
  ];
}

/// Адрес члена [index] папки [f]; `null` — член не разобран или безымянный.
NodeLink? folderMemberAddress(FolderServers f, int index) {
  if (index < 0 || index >= f.members.length) return null;
  final node = f.members[index].node;
  if (node == null) return null;
  return nodeAddressIn(f, node);
}

/// Финальная форма тега члена контейнера без уникализации сборки: префикс
/// контейнера + сырой тег (NODE_LINK §3). Для показа ссылки и сопоставления
/// финальных тегов (миграция, импорт §7.3, S3).
String containerFinalForm(ServerList l, String rawTag) =>
    TagResolver.displayTag(l.tagPrefix, rawTag);
