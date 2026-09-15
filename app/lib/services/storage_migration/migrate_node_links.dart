/// Миграция ссылок на узлы формы 2.23.2 в NodeLink (§439 §2.3 п. 8, D-112).
///
/// 2.23.2 хранила `override_detour`, `detour` члена папки и позиции цепочек
/// финальными тегами конфига строкой; замороженный читатель
/// (`legacy_form_v0.dart`) переносит их корневыми ссылками `{tag}`, и шаг ниже
/// переводит их по состоянию ДО миграции:
///
/// 1. detour внутри папки, равный тегу её члена, — ссылка на члена (так его
///    понимала сборка 2.23.2, `FolderDetourPlan`): пара `{id папки, тег}`;
/// 2. иначе строка ищется в словаре финальных тегов, построенном той же
///    сборкой узлов (`ServerList.build`: префиксы, уникализация, резерв тегов
///    Направлений) — узел папки или подписки даёт пару, узел одиночного
///    сервера остаётся корневой ссылкой; узлы подписки берутся из кэша
///    `sub_cache` ([subscriptionBodies]);
/// 3. не нашлось в словаре — узел выключен (сам, в папке или подписке, или
///    выключен его источник): словарь «при включении» той же сборки
///    ([computeDisabledNodeLinkPools]) — узел папки или подписки даёт пару,
///    узел одиночного сервера остаётся корневой ссылкой; ровно одна цель;
///    иначе (кэша нет) — финальная форма тега «префикс + тег» по всем
///    источникам, выключенные включительно: ровно один кандидат — пара у
///    папки и подписки, корневая ссылка у одиночного сервера;
/// 4. Направление, `direct-out`, служебный тег и цепочка остаются корнем;
///    прочее (не нашлось или неоднозначно) — корнем с предупреждением: сборка
///    разберёт ссылку fail-closed;
/// 5. личный detour члена на самого себя и ребро, замыкавшее кольцо внутри
///    папки, сборка 2.23.2 не эмитила (`FolderDetourPlan`): такая ссылка
///    снимается с предупреждением — конфиг не меняется.
///
/// Работает над записями `sources[]` 1.0: правит только поля ссылок, записи
/// не перекодирует.
library;

import '../../config/consts.dart';
import '../../models/codec/chain_record.dart';
import '../../models/codec/node_link_record.dart';
import '../../models/codec/source_record.dart';
import '../../models/direction.dart';
import '../../models/node_link.dart';
import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../builder/node_link_pool.dart';
import '../node_link_address.dart';
import '../parser/body_decoder.dart';
import '../parser/parse_all.dart';

/// Записи [sources] с переведёнными ссылками. [directions] — сырые записи
/// Направлений документа (резерв их тегов в словаре и корневые имена);
/// [subscriptionBodies] — адрес подписки → тело из `sub_cache`.
List<Map<String, dynamic>> migrateNodeLinks(
  List<Map<String, dynamic>> sources, {
  Object? directions,
  Map<String, String> subscriptionBodies = const {},
  required List<String> info,
  required List<String> warnings,
}) {
  final lists = <ServerList>[];
  final chainTags = <String>{};
  for (final r in sources) {
    if (r['kind'] == kSourceKindChain) {
      final tag = r['tag'];
      if (tag is String && tag.trim().isNotEmpty) chainTags.add(tag.trim());
      continue;
    }
    final list = sourceFromRecord(r).value;
    if (list == null) continue;
    if (list is SubscriptionServers) {
      final body = subscriptionBodies[list.url];
      lists.add(body == null ? list : list.copyWith(nodes: _parse(body)));
    } else {
      lists.add(list);
    }
  }

  final dirs = <Direction>[
    if (directions is List)
      for (final d in directions)
        if (d is Map) ?_direction(d.cast<String, dynamic>()),
  ];
  final pool = computeNodeLinkPool(lists, directions: dirs);
  final disabledPools = computeDisabledNodeLinkPools(lists, directions: dirs);
  final rootNames = <String>{
    kDirectOutboundTag,
    kBlockOutboundTag,
    'dns-out',
    'block-out',
    for (final d in dirs) ...[d.tag, d.autoTag],
    ...chainTags,
  };
  final folders = {
    for (final l in lists)
      if (l is FolderServers) l.id: l,
  };

  // Финальная форма «префикс + сырой тег» → адреса, по всем источникам
  // (включая выключенные): запасной путь для строк вне словарей. Адрес узла
  // одиночного сервера — корневая ссылка своей финальной формой.
  final byFinalForm = <String, List<NodeLink>>{};
  void addForm(String form, NodeLink address) {
    final list = byFinalForm[form] ??= [];
    if (!list.contains(address)) list.add(address);
  }

  for (final l in lists) {
    if (l is UserServer) {
      for (final address in sourceNodeAddresses(l)) {
        addForm(address.tag, address);
      }
      continue;
    }
    containerRawTags(l).forEach((_, raw) {
      addForm(containerFinalForm(l, raw), NodeLink(folderId: l.id, tag: raw));
    });
  }

  var lifted = 0;
  NodeLink lift(NodeLink link, String where, {FolderServers? folder}) {
    if (link.isEmpty || !link.isRoot) return link;
    final s = link.tag;
    if (folder != null) {
      final enabledRaw = containerRawTagSet(folder.copyWith(members: [
        for (final m in folder.members)
          if (m.enabled) m,
      ]));
      if (enabledRaw.contains(s)) {
        lifted++;
        return NodeLink(folderId: folder.id, tag: s);
      }
    }
    final known = pool.linkOfFinal(s);
    if (!known.isRoot) {
      lifted++;
      return known;
    }
    if (pool.finalOf(known) != null || rootNames.contains(s)) return link;
    if (folder != null && containerRawTagSet(folder).contains(s)) {
      lifted++;
      return NodeLink(folderId: folder.id, tag: s);
    }
    final ifEnabled = <NodeLink>{
      for (final p in disabledPools)
        if (p.linkOfFinal(s) case final target when p.finalOf(target) != null)
          target,
    };
    final candidates = ifEnabled.isNotEmpty
        ? ifEnabled.toList()
        : byFinalForm[s] ?? const <NodeLink>[];
    if (candidates.length == 1) {
      final target = candidates.single;
      // Узел одиночного сервера: ссылка уже корневая `{tag}`.
      if (target.isRoot) return link;
      lifted++;
      return target;
    }
    warnings.add(candidates.isEmpty
        ? '$where "$s" matches no node, kept as a root link'
        : '$where "$s" matches ${candidates.length} nodes, kept as a root '
            'link');
    return link;
  }

  Object? liftField(Object? raw, String where, {FolderServers? folder}) {
    final link = nodeLinkFromRecord(raw);
    if (link == null) return raw;
    final next = lift(link, where, folder: folder);
    return next == link ? raw : nodeLinkToRecord(next);
  }

  final out = <Map<String, dynamic>>[];
  for (final r in sources) {
    final kind = r['kind'];
    final id = r['id'];
    final name = r['name'] is String && (r['name'] as String).isNotEmpty
        ? r['name']
        : (r['tag'] ?? id);
    if (kind == kSourceKindChain) {
      final hops = r['hops'];
      if (hops is! List) {
        out.add(r);
        continue;
      }
      out.add({
        ...r,
        'hops': [
          for (var i = 0; i < hops.length; i++)
            liftField(hops[i], 'chain "$name": position ${i + 1}'),
        ],
      });
      continue;
    }
    final folder = kind == kSourceKindFolder ? folders[id] : null;
    final next = <String, dynamic>{...r};
    if (r.containsKey('detour')) {
      next['detour'] =
          liftField(r['detour'], '$kind "$name": detour', folder: folder);
    }
    final nodes = r['nodes'];
    if (kind == kSourceKindFolder && nodes is List) {
      next['nodes'] = [
        for (var i = 0; i < nodes.length; i++)
          if (nodes[i] is Map && (nodes[i] as Map).containsKey('detour'))
            {
              ...(nodes[i] as Map).cast<String, dynamic>(),
              'detour': liftField((nodes[i] as Map)['detour'],
                  '$kind "$name": nodes[$i] detour',
                  folder: folder),
            }
          else
            nodes[i],
      ];
    }
    if (kind == kSourceKindFolder && id is String && next['nodes'] is List) {
      next['nodes'] = _dropLegacyIntraLoops(
          next['nodes'] as List, id, '$kind "$name"', warnings);
    }
    out.add(next);
  }
  if (lifted > 0) info.add('node links: $lifted final tags → {folder_id, tag}');
  return out;
}

/// Шаг 5: интра-рёбра папки [folderId] по включённым разобранным членам в их
/// порядке (как `FolderDetourPlan` 2.23.2: первый тёзка побеждает), ссылка на
/// себя и ребро, замыкающее кольцо при обходе в глубину, снимаются.
List<Object?> _dropLegacyIntraLoops(
  List<dynamic> nodes,
  String folderId,
  String where,
  List<String> warnings,
) {
  final live = <int>[]; // индекс записи по месту среди включённых узлов
  for (var i = 0; i < nodes.length; i++) {
    final n = nodes[i];
    if (n is! Map || n['enabled'] == false) continue;
    if (n['kind'] == kNodeKindUnsupported) continue;
    final tag = n['tag'];
    if (tag is! String || tag.isEmpty) continue;
    live.add(i);
  }
  final firstByTag = <String, int>{};
  for (var k = 0; k < live.length; k++) {
    firstByTag.putIfAbsent((nodes[live[k]] as Map)['tag'] as String, () => k);
  }
  final edge = List<int?>.filled(live.length, null);
  final cut = <int>{};
  for (var k = 0; k < live.length; k++) {
    final link = nodeLinkFromRecord((nodes[live[k]] as Map)['detour']);
    if (link == null || link.folderId != folderId) continue;
    final j = firstByTag[link.tag];
    if (j == null) continue;
    if (j == k) {
      cut.add(k);
    } else {
      edge[k] = j;
    }
  }
  final color = List<int>.filled(live.length, 0);
  void dfs(int u) {
    color[u] = 1;
    final v = edge[u];
    if (v != null) {
      if (color[v] == 1) {
        cut.add(u);
      } else if (color[v] == 0) {
        dfs(v);
      }
    }
    color[u] = 2;
  }

  for (var k = 0; k < live.length; k++) {
    if (color[k] == 0) dfs(k);
  }
  if (cut.isEmpty) return nodes;
  final out = List<Object?>.of(nodes);
  for (final k in cut) {
    final i = live[k];
    final node = Map<String, dynamic>.of((nodes[i] as Map).cast());
    warnings.add('$where: nodes[$i] detour "${nodeLinkFromRecord(node['detour'])?.tag}" '
        'points at itself or closes a loop inside the folder; 2.23.2 did not '
        'emit it, removed');
    node.remove('detour');
    out[i] = node;
  }
  return out;
}

List<NodeSpec> _parse(String body) {
  try {
    return parseAll(decode(body));
  } catch (_) {
    return const [];
  }
}

Direction? _direction(Map<String, dynamic> j) {
  try {
    return Direction.fromJson(j);
  } catch (_) {
    return null;
  }
}
