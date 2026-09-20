import '../../controllers/subscription_controller.dart';
import '../../models/core_reject_verdict.dart';
import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../../services/node_hash.dart';
import '../../services/tag_resolver.dart';

/// §091/§235 — какие ИСТОЧНИКИ (подписки + папки §234) «владеют» данным
/// display-тэгом, по **префиксу**.
///
/// `config-tag == нода в Clash`, но `subId` в конфиг не пишется — единственный
/// реальный mismatch (§091 spec). Восстанавливаем принадлежность чисто по
/// эмитированному префиксу: билдер кладёт тег как `'$tagPrefix $bare'`
/// (`TagResolver.displayTag`), поэтому нода принадлежит источнику ⇔
/// `tag.startsWith('$prefix ')`.
///
/// **Только источники с заданным префиксом** участвуют (юзер: «префикс не
/// задан → нет поиска»). Пустой результат = тег не начинается ни с одного
/// префикса → caller относит его к категории `'custom'` (UserServer,
/// источник без префикса, импортированный JSON). Одиночный `UserServer` НЕ
/// участвует (§091: UI не даёт ему префикс при наличии нод).
///
/// Заменил §077 reverse-map по node-спискам + collision-suffix эвристику
/// (`TagResolver.matchesAllocated`) — целый класс багов §077/§079/§080
/// исчезает структурно (UI больше не reverse-парсит тег).
///
/// **Prefix-collision (принятый tradeoff модели):** если две подписки имеют
/// одинаковый префикс — нода честно мэтчит обе. Тот же эффект, если нода
/// **чужого списка** (UserServer / подписка без своего chip'а) случайно
/// начинается с префикса реальной подписки: она будет приписана подписке, а
/// не «Custom». Достижимо только нестандартно (UI не даёт UserServer'у
/// префикс при наличии нод — только v1-миграция `proxy_source_migration` или
/// backup-импорт), и решается уникальностью префиксов. Чистого prefix-фикса
/// нет без возврата проверки членства в node-списках (ровно то, что §091
/// убрал ради устранения класса §077/§079/§080). См. §091 edge-cases.
Set<String> sourcesOfTag(
  String tag,
  List<SubscriptionEntry> entries,
) {
  final result = <String>{};
  for (final (prefix, id) in sourcePrefixIndex(entries)) {
    if (tag.startsWith(prefix)) result.add(id);
  }
  return result;
}

/// §446 — пригодные источники как пары `(искомый префикс, id источника)`.
///
/// От тега не зависит, а фильтр по источникам спрашивает принадлежность на
/// КАЖДЫЙ тег списка: при большой сборной подписке отбор (тип, enabled,
/// непустой префикс) повторялся сотни раз за проход. Порядок сохранён —
/// результат `sourcesOfTag` тот же, что у прежнего единого цикла.
List<(String, String)> sourcePrefixIndex(List<SubscriptionEntry> entries) {
  final out = <(String, String)>[];
  for (final e in entries) {
    final list = e.list;
    // §235 — источник = подписка ИЛИ папка (§234).
    if (list is! SubscriptionServers && list is! FolderServers) continue;
    if (!e.enabled) continue; // disabled источники не эмитят node'ы в config
    final prefix = list.tagPrefix;
    if (prefix.isEmpty) continue; // §091: нет префикса → нет фильтра
    out.add(('$prefix ', e.id));
  }
  return out;
}

/// §255 — владелец config-тэга: entry + (для папки) индекс члена. Для
/// навигации из detour-cycle sheet прямо в экран владельца.
class TagOwner {
  /// Индекс entry в `SubscriptionController.entries`.
  final int entryIndex;

  /// Индекс члена в `FolderServers.members` (null = не папка / одиночный).
  final int? memberIndex;

  const TagOwner(this.entryIndex, {this.memberIndex});
}

/// §254/§255 — какой entry владеет данным config-тэгом (для навигации из
/// detour-cycle sheet в экран владельца). В отличие от [sourcesOfTag] —
/// суперсет: ловит и `UserServer` (без префикса), и одиночный сервер, и члена
/// папки, матча по bare-тегу ноды (не только по префиксу). Возвращает
/// [TagOwner] первого совпавшего entry (+ memberIndex для папки) либо `null`
/// (тег без владельца — custom JSON).
///
/// Тег в конфиге = `TagResolver.displayTag(prefix, bare)`, плюс возможный
/// `allocateTag`-суффикс дедупликации `-<digits>`. Пробуем сперва тег как есть
/// (bare-тег, легитимно кончающийся на `-2`, выигрывает), затем со снятым
/// суффиксом.
///
/// Tradeoff (как [sourcesOfTag] §091): prefix-collision → вернём соседа с тем
/// же префиксом; неоднозначность суффикса → косметически не та строка. Оба
/// приемлемы для affordance «открыть владельца».
TagOwner? ownerOfTag(String culpritTag, List<SubscriptionEntry> entries) {
  final candidates = <String>[culpritTag];
  final m = RegExp(r'^(.*)-\d+$').firstMatch(culpritTag);
  if (m != null) candidates.add(m.group(1)!);

  for (final cand in candidates) {
    for (var ei = 0; ei < entries.length; ei++) {
      final list = entries[ei].list;
      final bare = TagResolver.stripPrefix(cand, list.tagPrefix);
      if (list is FolderServers) {
        for (var mi = 0; mi < list.members.length; mi++) {
          if (list.members[mi].node?.tag == bare) {
            return TagOwner(ei, memberIndex: mi);
          }
        }
      } else {
        for (final n in list.nodes) {
          if (n.tag == bare) return TagOwner(ei);
          // §404 — цепочка бывает многохоповой (`dialerProxy` релея на
          // следующий релей): ищем по всем звеньям, не только по первому.
          for (var hop = n.chained; hop != null; hop = hop.chained) {
            if (hop.tag == bare) return TagOwner(ei);
          }
        }
      }
    }
  }
  return null;
}

/// §498 — владелец [node] для навигации из плашки/листа страховки. Сравнение
/// по идентичности объекта (`identical`), как у [disableNodeByCoreTag];
/// хоп цепочки принадлежит владельцу (тот же обход, что у [ownerOfTag]).
bool _nodeOrHop(NodeSpec owner, NodeSpec node) {
  if (identical(owner, node)) return true;
  for (var hop = owner.chained; hop != null; hop = hop.chained) {
    if (identical(hop, node)) return true;
  }
  return false;
}

/// §505 — узел в хранилище и вердикты страховки по финальному config-тегу.
({NodeSpec node, List<StoredWarning> stored})? storedNodeOfEmittedTag(
  String emittedTag,
  List<SubscriptionEntry> entries,
) {
  final owner = ownerOfTag(emittedTag, entries);
  if (owner == null) return null;
  final list = entries[owner.entryIndex].list;
  switch (list) {
    case FolderServers f:
      final mi = owner.memberIndex;
      if (mi == null) return null;
      final m = f.members[mi];
      final n = m.node;
      if (n == null) return null;
      return (node: n, stored: m.warnings);
    case SubscriptionServers sub:
      final candidates = <String>[emittedTag];
      final dedup = RegExp(r'^(.*)-\d+$').firstMatch(emittedTag);
      if (dedup != null) candidates.add(dedup.group(1)!);
      for (final cand in candidates) {
        final bare = TagResolver.stripPrefix(cand, sub.tagPrefix);
        for (final n in sub.nodes) {
          if (n.tag == bare) {
            final id = sourceNodeIdentities(sub.nodes)[n];
            return (
              node: n,
              stored: id == null
                  ? const <StoredWarning>[]
                  : sub.nodeWarnings[id] ?? const <StoredWarning>[],
            );
          }
          for (var hop = n.chained; hop != null; hop = hop.chained) {
            if (hop.tag == bare) {
              final id = sourceNodeIdentities(sub.nodes)[n];
              return (
                node: n,
                stored: id == null
                    ? const <StoredWarning>[]
                    : sub.nodeWarnings[id] ?? const <StoredWarning>[],
              );
            }
          }
        }
      }
      return null;
    case UserServer us:
      if (us.nodes.isEmpty) return null;
      return (node: us.nodes.first, stored: us.warnings);
  }
}

TagOwner? ownerOfNode(NodeSpec node, List<SubscriptionEntry> entries) {
  for (var ei = 0; ei < entries.length; ei++) {
    final list = entries[ei].list;
    switch (list) {
      case FolderServers():
        for (var mi = 0; mi < list.members.length; mi++) {
          final n = list.members[mi].node;
          if (n != null && _nodeOrHop(n, node)) {
            return TagOwner(ei, memberIndex: mi);
          }
        }
      case SubscriptionServers():
      case UserServer():
        if (list.nodes.any((n) => _nodeOrHop(n, node))) {
          return TagOwner(ei);
        }
    }
  }
  return null;
}

/// §505 — узел хранилища для эмитированного config-тега. Тот же обход, что
/// [ownerOfTag] (bare-тег, суффикс `-<digits>`, хоп цепочки), но возвращает
/// [NodeSpec]. `null` — служебная запись или custom JSON без владельца.
NodeSpec? nodeSpecForConfigTag(
  String emittedTag,
  List<SubscriptionEntry> entries,
) {
  final candidates = <String>[emittedTag];
  final m = RegExp(r'^(.*)-\d+$').firstMatch(emittedTag);
  if (m != null) candidates.add(m.group(1)!);

  for (final cand in candidates) {
    for (final e in entries) {
      final list = e.list;
      final bare = TagResolver.stripPrefix(cand, list.tagPrefix);
      if (list is FolderServers) {
        for (final member in list.members) {
          final n = member.node;
          if (n != null && n.tag == bare) return n;
        }
      } else {
        for (final n in list.nodes) {
          if (n.tag == bare) return n;
          for (var hop = n.chained; hop != null; hop = hop.chained) {
            if (hop.tag == bare) return hop;
          }
        }
      }
    }
  }
  return null;
}

/// Исходный узел записи, которой принадлежит [node]: хоп цепочки → владелец.
NodeSpec? sourceNodeOf(NodeSpec node, ServerList list) {
  switch (list) {
    case FolderServers():
      for (final m in list.members) {
        final n = m.node;
        if (n != null && _nodeOrHop(n, node)) return n;
      }
    case SubscriptionServers():
    case UserServer():
      for (final n in list.nodes) {
        if (_nodeOrHop(n, node)) return n;
      }
  }
  return null;
}
