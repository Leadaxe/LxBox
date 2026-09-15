/// Реестр ссылок на узлы (§439 §2.5, слой 4; D-113, D-114; NODE_LINK §6).
///
/// Один на все носители: `DetourPolicy.overrideDetour` источника (подписка,
/// сервер, папка), `FolderMember.detour`, `SourceChain.hops` и состав
/// autogroup папки (`ExplicitMembers.members` члена `kind: auto`). Операции
/// контроллеров, меняющие адрес узла, идут сюда:
///
/// - **переименование** (правка тела) и **перенос** между контейнерами —
///   [rewriteNodeLinks]: ссылки на прежний адрес указывают на новый;
/// - **удаление** узла или источника целиком — [clearNodeLinks]: detour
///   снимается, позиция уходит из цепочки, задетые называются;
/// - смена `tag_policy` и имени контейнера адрес не меняет — сюда не
///   приходит.
///
/// Ссылка никогда не переуказывается на ДРУГОЙ узел (NODE_LINK §6 п. 3):
/// какие адреса сменились, решает [diffNodeAddresses] по самим узлам, а не по
/// похожим тегам. Функции чистые: хранение и зеркало контроллера применяет
/// вызывающий.
library;

import '../../models/auto_select.dart';
import '../../models/node_link.dart';
import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../../models/source_chain.dart';
import '../node_link_address.dart';

/// Итог операции реестра.
final class NodeLinkChange {
  const NodeLinkChange({
    required this.lists,
    required this.chains,
    this.detourCarriers = const [],
    this.touchedGroups = const [],
    this.groupMembers = 0,
    this.touchedChains = const [],
    this.positions = 0,
  });

  /// Источники после операции (те же объекты, где ничего не менялось).
  final List<ServerList> lists;

  /// Цепочки после операции.
  final List<SourceChain> chains;

  /// Носители detour-ссылки, переписанной или погашенной: detour источника и
  /// члена папки. Имя для показа — подписка и папка — имя, сервер и член
  /// папки — тег узла; пустое имя (член без разобранного узла) считается, но
  /// не показывается. Член autogroup — не detour: он в [touchedGroups].
  final List<String> detourCarriers;

  /// Теги групп autogroup, у которых задет состав.
  final List<String> touchedGroups;

  /// Сколько членов групп переписано или снято.
  final int groupMembers;

  /// Подписи цепочек, у которых задета позиция.
  final List<String> touchedChains;

  /// Сколько позиций цепочек переписано или снято.
  final int positions;

  bool get isEmpty =>
      detourCarriers.isEmpty && groupMembers == 0 && positions == 0;

  bool get chainsChanged => positions > 0;
}

/// Сменившиеся адреса узлов между состояниями [before] и [after].
///
/// Узел сопоставляется сам с собой по ссылке объекта (перенос члена,
/// вынос в одиночный сервер, роспуск папки узел не пересоздают) или через
/// [renamed] — «прежний узел → узел, который его заменил» (правка тела,
/// перенос сервера в папку, где член разбирается заново). Узел без пары в
/// [after] — удалён ([gone]); с другим адресом — перенесён ([moves]).
({Map<NodeLink, NodeLink> moves, Set<NodeLink> gone}) diffNodeAddresses(
  List<ServerList> before,
  List<ServerList> after, {
  Map<NodeSpec, NodeSpec> renamed = const {},
}) {
  final was = _addresses(before);
  final now = _addresses(after);
  final moves = <NodeLink, NodeLink>{};
  final gone = <NodeLink>{};
  final kept = <NodeLink>{};
  was.forEach((node, address) {
    final successor = renamed[node] ?? node;
    final next = now[successor];
    if (next == null) {
      gone.add(address);
    } else if (next != address) {
      moves[address] = next;
    } else {
      kept.add(address);
    }
  });
  // Корневой адрес делят тёзки (два сервера с одним тегом): уцелевший тёзка
  // держит его дальше, и гасить ссылки на этот адрес нельзя.
  gone.removeAll(kept);
  return (moves: moves, gone: gone);
}

/// Итог [relinkNodeLinks]: новые носители и отчёты обеих частей.
typedef NodeLinkRelink = ({
  List<ServerList> lists,
  List<SourceChain> chains,
  NodeLinkChange cleared,
  NodeLinkChange rewritten,
});

/// Операция контроллера целиком: сначала гаснут ссылки на удалённые адреса
/// ([gone] и все пары на контейнеры [goneContainers]), затем переписываются
/// перенесённые ([moves]). Порядок важен: адрес удалённого узла мог занять
/// перенесённый тёзка (`X-2` → `X`), и ссылки удалённого не должны уехать на
/// него.
NodeLinkRelink relinkNodeLinks(
  List<ServerList> lists,
  List<SourceChain> chains, {
  Map<NodeLink, NodeLink> moves = const {},
  Set<NodeLink> gone = const {},
  Set<String> goneContainers = const {},
}) {
  final cleared = (gone.isEmpty && goneContainers.isEmpty)
      ? NodeLinkChange(lists: lists, chains: chains)
      : clearNodeLinks(
          lists,
          chains,
          (l) =>
              gone.contains(l) ||
              (!l.isRoot && goneContainers.contains(l.folderId)),
        );
  final rewritten = rewriteNodeLinks(cleared.lists, cleared.chains, moves);
  return (
    lists: rewritten.lists,
    chains: rewritten.chains,
    cleared: cleared,
    rewritten: rewritten,
  );
}

Map<NodeSpec, NodeLink> _addresses(List<ServerList> lists) {
  final out = Map<NodeSpec, NodeLink>.identity();
  for (final l in lists) {
    final raw = l is UserServer ? null : containerRawTags(l);
    for (final n in containerNodes(l)) {
      final a = nodeAddressIn(l, n, raw: raw);
      if (a != null) out[n] = a;
    }
  }
  return out;
}

/// D-113 — ссылки на адреса-ключи [moves] переписываются на значения во всех
/// носителях [lists] и [chains]. Перепись одновременная: обмен адресов
/// (перестановка тёзок) не сливает ссылки.
NodeLinkChange rewriteNodeLinks(
  List<ServerList> lists,
  List<SourceChain> chains,
  Map<NodeLink, NodeLink> moves,
) {
  if (moves.isEmpty) return NodeLinkChange(lists: lists, chains: chains);
  return _mapLinks(lists, chains, (l) => moves[l], dropHop: false);
}

/// D-114 — ссылки, для которых [isGone] истинно, гаснут: detour снимается,
/// позиция уходит из цепочки (цепочка остаётся, §393 D2).
NodeLinkChange clearNodeLinks(
  List<ServerList> lists,
  List<SourceChain> chains,
  bool Function(NodeLink link) isGone,
) =>
    _mapLinks(lists, chains, (l) => isGone(l) ? NodeLink.none : null,
        dropHop: true);

/// Общий обход носителей. [replace] даёт новую ссылку или `null` (не
/// трогать); [dropHop] — пустая замена позиции удаляет позицию.
NodeLinkChange _mapLinks(
  List<ServerList> lists,
  List<SourceChain> chains,
  NodeLink? Function(NodeLink link) replace, {
  required bool dropHop,
}) {
  final carriers = <String>[];
  final groups = <String>[];
  var groupMembers = 0;
  NodeLink? swap(NodeLink l) {
    if (l.isEmpty) return null;
    final next = replace(l);
    return next == null || next == l ? null : next;
  }

  final outLists = <ServerList>[];
  for (final l in lists) {
    var next = l;
    final override = swap(l.detourPolicy.overrideDetour);
    if (override != null) {
      final p = l.detourPolicy.copyWith(overrideDetour: override);
      next = switch (l) {
        SubscriptionServers s => s.copyWith(detourPolicy: p),
        UserServer u => u.copyWith(detourPolicy: p),
        FolderServers f => f.copyWith(detourPolicy: p),
      };
      carriers.add(_sourceName(l));
    }
    if (next is FolderServers) {
      final folderId = next.id;
      var changed = false;
      final members = <FolderMember>[];
      for (final m in next.members) {
        var member = m;
        final d = swap(m.detour);
        if (d != null) {
          member = member.copyWith(detour: d);
          carriers.add(m.node?.tag ?? '');
        }
        final group = _mapGroupMembers(member, folderId, swap, dropHop);
        if (group != null) {
          member = group.member;
          groups.add(m.node?.tag ?? '');
          groupMembers += group.hits;
        }
        if (!identical(member, m)) changed = true;
        members.add(member);
      }
      if (changed) next = next.copyWith(members: members);
    }
    outLists.add(next);
  }

  var positions = 0;
  final touched = <String>[];
  final outChains = <SourceChain>[];
  for (final c in chains) {
    var hit = false;
    final hops = <NodeLink>[];
    for (final h in c.hops) {
      final next = swap(h);
      if (next == null) {
        hops.add(h);
        continue;
      }
      hit = true;
      positions++;
      if (!(dropHop && next.isEmpty)) hops.add(next);
    }
    if (!hit) {
      outChains.add(c);
      continue;
    }
    touched.add(c.displayLabel);
    outChains.add(c.copyWith(hops: hops));
  }

  return NodeLinkChange(
    lists: outLists,
    chains: outChains,
    detourCarriers: carriers,
    touchedGroups: groups,
    groupMembers: groupMembers,
    touchedChains: touched,
    positions: positions,
  );
}

/// Состав autogroup члена [m] папки [folderId] через [swap]: член без
/// `folder_id` — член этой же папки (NODE_LINK §5.1 № 8), переписанный пишется
/// парой. [drop] — погашенный член уходит из состава. `null` — состав не
/// задет; иначе новый член-группа и сколько членов состава задето.
({FolderMember member, int hits})? _mapGroupMembers(
  FolderMember m,
  String folderId,
  NodeLink? Function(NodeLink link) swap,
  bool drop,
) {
  final g = m.node;
  if (g is! AutoSelectSpec) return null;
  final membership = g.membership;
  if (membership is! ExplicitMembers) return null;
  var hits = 0;
  final links = <NodeLink>[];
  for (final l in membership.members) {
    final address = l.isRoot ? NodeLink(folderId: folderId, tag: l.tag) : l;
    final next = swap(address);
    if (next == null) {
      links.add(l);
      continue;
    }
    hits++;
    if (!(drop && next.isEmpty)) links.add(next);
  }
  if (hits == 0) return null;
  return (
    member: FolderMember.auto(
      g.copyWith(membership: ExplicitMembers(links)),
      enabled: m.enabled,
    ),
    hits: hits,
  );
}

String _sourceName(ServerList l) => switch (l) {
      UserServer u => u.nodes.isNotEmpty
          ? containerFinalForm(u, u.nodes.first.tag)
          : u.name,
      SubscriptionServers s when s.name.isEmpty =>
        Uri.tryParse(s.url)?.host ?? s.url,
      _ => l.name,
    };
