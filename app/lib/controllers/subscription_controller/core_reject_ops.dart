/// Фича 478 — применение и снятие вердикта ядра над записями источников.
///
/// Чистые функции над моделями: контроллер зовёт их и персистит результат.
/// Так автомат страховки (`core_reject_guard.dart`) остаётся без знания о
/// форме хранения, а хранение — без знания об автомате.
///
/// Снимают вердикт РОВНО два события (CANON §9.4):
/// 1. тело узла изменилось — запись стирается И узел включается обратно;
/// 2. человек включил узел обратно — запись стирается.
///
/// Смена версии ядра вердикты НЕ снимает (решение владельца).
library;

import 'dart:convert';

import '../../models/core_reject_verdict.dart';
import '../../models/node_warning.dart';
import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../../models/template_vars.dart';
import '../../services/core_reject/core_reject_guard.dart';
import '../../services/node_hash.dart';
import '../../services/tag_resolver.dart';

/// Каноническая форма тела узла для сравнения «то же тело / другое тело».
///
/// Сравнивается `emit()` с СОРТИРОВКОЙ ключей, а не тег-идентичность (она от
/// тела не зависит) и не `nodeIdentityKey` (он не видит TLS и транспорт, а
/// негодным бывает именно там). Сравнение семантическое: нормализация,
/// прошедшая через модель, обе стороны меняет одинаково.
String canonicalNodeBody(NodeSpec node) {
  try {
    // emit() отдаёт одноразовую карту — её никто дальше не мутирует.
    return jsonEncode(_sortKeys(node.emit(const TemplateVars()).map));
  } catch (_) {
    // Узел, который не эмитится, сравнивать нечем: пусть считается другим —
    // лишняя проверка ядром дешевле починенного узла, оставшегося выключенным.
    return '';
  }
}

Object? _sortKeys(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: _sortKeys(v[k])};
  }
  if (v is List) return [for (final e in v) _sortKeys(e)];
  return v;
}

/// Результат применения вердикта к источнику.
typedef VerdictApply = ({ServerList list, bool changed});

/// §503 — цель навигации из листа страховки.
typedef CoreRejectNavigationTarget = ({
  int entryIndex,
  int? memberIndex,
  NodeSpec node,
  NodeSpec source,
  ServerList list,
});

/// §503 — источник и ключ узла для вердикта / [DisabledNode].
CoreRejectNodeRef? nodeRefFor(ServerList list, NodeSpec node) {
  final key = nodeKeyFor(list, node);
  if (key == null) return null;
  return CoreRejectNodeRef(sourceId: list.id, nodeKey: key);
}

/// Ключ узла внутри источника: идентичность подписки, bare-тег сервера/члена.
String? nodeKeyFor(ServerList list, NodeSpec node) {
  switch (list) {
    case SubscriptionServers():
      return sourceNodeIdentities(list.nodes)[node];
    case FolderServers():
      for (final m in list.members) {
        if (identical(m.node, node)) {
          return m.node?.tag ?? m.nameHint;
        }
      }
      return null;
    case UserServer():
      if (list.nodes.any((n) => identical(n, node))) return node.tag;
      return null;
  }
}

bool _nodeOrHop(NodeSpec owner, NodeSpec node) {
  if (identical(owner, node)) return true;
  for (var hop = owner.chained; hop != null; hop = hop.chained) {
    if (identical(hop, node)) return true;
  }
  return false;
}

NodeSpec? _sourceNodeOf(NodeSpec node, ServerList list) {
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

/// §503 — найти узел в хранилище по идентичности вердикта, не по карте
/// текущей сборки. [entries] — `(index, id, list)` из контроллера.
CoreRejectNavigationTarget? resolveCoreRejectNode(
  List<(int index, String id, ServerList list)> entries,
  DisabledNode disabled, {
  Map<String, NodeSpec>? emittedTagMap,
}) {
  var ref = disabled.ref ?? _refFromStoredVerdict(entries, disabled);
  if (ref != null) {
    final byRef = _resolveByRef(entries, ref);
    if (byRef != null) return byRef;
  }

  final mapped = emittedTagMap?[disabled.tag];
  if (mapped != null) {
    final fromMap = _resolveByNode(entries, mapped);
    if (fromMap != null) return fromMap;
  }

  return _resolveByTagAmongDisabled(entries, disabled.tag);
}

CoreRejectNodeRef? _refFromStoredVerdict(
  List<(int index, String id, ServerList list)> entries,
  DisabledNode disabled,
) {
  for (final (_, _, list) in entries) {
    switch (list) {
      case SubscriptionServers():
        for (final e in list.nodeWarnings.entries) {
          for (final w in e.value) {
            if (!w.isCoreRejected || w.reason != disabled.reason) continue;
            final ref = w.coreRejectRef;
            if (ref != null) return ref;
          }
        }
      case FolderServers():
        for (final m in list.members) {
          for (final w in m.warnings) {
            if (!w.isCoreRejected || w.reason != disabled.reason) continue;
            final ref = w.coreRejectRef;
            if (ref != null) return ref;
          }
        }
      case UserServer():
        for (final w in list.warnings) {
          if (!w.isCoreRejected || w.reason != disabled.reason) continue;
          final ref = w.coreRejectRef;
          if (ref != null) return ref;
        }
    }
  }
  return null;
}

CoreRejectNavigationTarget? _resolveByRef(
  List<(int index, String id, ServerList list)> entries,
  CoreRejectNodeRef ref,
) {
  for (final (index, id, list) in entries) {
    if (id != ref.sourceId) continue;
    switch (list) {
      case SubscriptionServers():
        for (final n in list.nodes) {
          if (sourceNodeIdentities(list.nodes)[n] == ref.nodeKey) {
            return (
              entryIndex: index,
              memberIndex: null,
              node: n,
              source: n,
              list: list,
            );
          }
        }
      case FolderServers():
        for (var mi = 0; mi < list.members.length; mi++) {
          final m = list.members[mi];
          final key = m.node?.tag ?? m.nameHint;
          if (key == ref.nodeKey && m.node != null) {
            return (
              entryIndex: index,
              memberIndex: mi,
              node: m.node!,
              source: m.node!,
              list: list,
            );
          }
        }
      case UserServer():
        for (final n in list.nodes) {
          if (n.tag == ref.nodeKey) {
            return (
              entryIndex: index,
              memberIndex: null,
              node: n,
              source: n,
              list: list,
            );
          }
        }
    }
  }
  return null;
}

CoreRejectNavigationTarget? _resolveByNode(
  List<(int index, String id, ServerList list)> entries,
  NodeSpec node,
) {
  for (final (index, _, list) in entries) {
    switch (list) {
      case FolderServers():
        for (var mi = 0; mi < list.members.length; mi++) {
          final n = list.members[mi].node;
          if (n != null && _nodeOrHop(n, node)) {
            return (
              entryIndex: index,
              memberIndex: mi,
              node: node,
              source: n,
              list: list,
            );
          }
        }
      case SubscriptionServers():
      case UserServer():
        if (list.nodes.any((n) => _nodeOrHop(n, node))) {
          final source = _sourceNodeOf(node, list) ?? node;
          return (
            entryIndex: index,
            memberIndex: null,
            node: node,
            source: source,
            list: list,
          );
        }
    }
  }
  return null;
}

CoreRejectNavigationTarget? _resolveByTagAmongDisabled(
  List<(int index, String id, ServerList list)> entries,
  String tag,
) {
  final candidates = <String>[tag];
  final m = RegExp(r'^(.*)-\d+$').firstMatch(tag);
  if (m != null) candidates.add(m.group(1)!);

  for (final cand in candidates) {
    for (final (index, _, list) in entries) {
      switch (list) {
        case SubscriptionServers():
          for (final n in list.nodes) {
            final identity = sourceNodeIdentities(list.nodes)[n];
            if (identity == null) continue;
            final hasVerdict = list.nodeWarnings[identity]
                    ?.any((w) => w.isCoreRejected) ==
                true;
            if (!hasVerdict && !list.disabledHashes.containsKey(identity)) {
              continue;
            }
            final bare = n.tag;
            final display =
                list.tagPrefix.isEmpty ? bare : TagResolver.displayTag(list.tagPrefix, bare);
            if (bare == cand || display == cand || identity == cand) {
              return (
                entryIndex: index,
                memberIndex: null,
                node: n,
                source: n,
                list: list,
              );
            }
            for (var hop = n.chained; hop != null; hop = hop.chained) {
              final hopDisplay = list.tagPrefix.isEmpty
                  ? hop.tag
                  : TagResolver.displayTag(list.tagPrefix, hop.tag);
              if (hop.tag == cand || hopDisplay == cand) {
                return (
                  entryIndex: index,
                  memberIndex: null,
                  node: n,
                  source: n,
                  list: list,
                );
              }
            }
          }
        case FolderServers():
          for (var mi = 0; mi < list.members.length; mi++) {
            final m = list.members[mi];
            if (!m.warnings.any((w) => w.isCoreRejected) && m.enabled) {
              continue;
            }
            final key = m.node?.tag ?? m.nameHint;
            if (key == cand && m.node != null) {
              return (
                entryIndex: index,
                memberIndex: mi,
                node: m.node!,
                source: m.node!,
                list: list,
              );
            }
          }
        case UserServer():
          if (!list.warnings.any((w) => w.isCoreRejected) && list.enabled) {
            continue;
          }
          for (final n in list.nodes) {
            if (n.tag == cand) {
              return (
                entryIndex: index,
                memberIndex: null,
                node: n,
                source: n,
                list: list,
              );
            }
          }
      }
    }
  }
  return null;
}

/// Выключить узел [node] источника [list] и записать рядом вердикт
/// [reason]. `changed: false` — узла в источнике нет либо выключить его
/// нечем (служебная запись): автоматики нет.
VerdictApply applyVerdict(ServerList list, NodeSpec node, String reason) {
  final verdict =
      StoredWarning.coreRejected(reason, ref: nodeRefFor(list, node));
  switch (list) {
    case SubscriptionServers():
      final hash = sourceNodeIdentities(list.nodes)[node];
      if (hash == null) return (list: list, changed: false);
      final disabled = Map<String, DateTime>.from(list.disabledHashes);
      disabled[hash] = DateTime.now();
      final ws = Map<String, List<StoredWarning>>.from(list.nodeWarnings);
      ws[hash] = upsertVerdict(ws[hash] ?? const [], verdict);
      return (
        list: list.copyWith(disabledHashes: disabled, nodeWarnings: ws),
        changed: true
      );

    case FolderServers():
      final at = list.members.indexWhere((m) => identical(m.node, node));
      if (at < 0) return (list: list, changed: false);
      final members = [...list.members];
      members[at] = members[at].copyWith(
        enabled: false,
        warnings: upsertVerdict(members[at].warnings, verdict),
      );
      return (list: list.copyWith(members: members), changed: true);

    case UserServer():
      if (!list.nodes.any((n) => identical(n, node))) {
        return (list: list, changed: false);
      }
      return (
        list: list.copyWith(
          enabled: false,
          warnings: upsertVerdict(list.warnings, verdict),
        ),
        changed: true
      );
  }
}

/// Снять вердикт с узла [node] и включить его обратно — зеркало [applyVerdict].
VerdictApply revertVerdict(ServerList list, NodeSpec node) {
  switch (list) {
    case SubscriptionServers():
      final hash = sourceNodeIdentities(list.nodes)[node];
      if (hash == null) return (list: list, changed: false);
      if (!list.disabledHashes.containsKey(hash) &&
          !list.nodeWarnings.containsKey(hash)) {
        return (list: list, changed: false);
      }
      final disabled = Map<String, DateTime>.from(list.disabledHashes)
        ..remove(hash);
      return (
        list: clearSubscriptionVerdict(
          list.copyWith(disabledHashes: disabled),
          hash,
        ),
        changed: true,
      );

    case FolderServers():
      final at = list.members.indexWhere((m) => identical(m.node, node));
      if (at < 0) return (list: list, changed: false);
      final m = list.members[at];
      if (m.enabled && !m.warnings.any((w) => w.isCoreRejected)) {
        return (list: list, changed: false);
      }
      final members = [...list.members];
      members[at] = m.copyWith(
        enabled: true,
        warnings: dropVerdict(m.warnings),
      );
      return (list: list.copyWith(members: members), changed: true);

    case UserServer():
      if (!list.nodes.any((n) => identical(n, node))) {
        return (list: list, changed: false);
      }
      if (list.enabled && !list.warnings.any((w) => w.isCoreRejected)) {
        return (list: list, changed: false);
      }
      return (
        list: list.copyWith(
          enabled: true,
          warnings: dropVerdict(list.warnings),
        ),
        changed: true,
      );
  }
}

/// GC оверлея `warnings` вместе с `disabledHashes` (спека 478 §3b).
Map<String, List<StoredWarning>> gcNodeWarnings(
  Map<String, List<StoredWarning>> warnings,
  Map<String, DateTime> disabled,
  Set<String> freshIdentities,
) {
  if (warnings.isEmpty) return warnings;
  return {
    for (final e in warnings.entries)
      if (disabled.containsKey(e.key) || freshIdentities.contains(e.key))
        e.key: e.value,
  };
}

/// Снять вердикт с узла подписки по его идентичности (ручное включение).
SubscriptionServers clearSubscriptionVerdict(
    SubscriptionServers list, String identity) {
  final cur = list.nodeWarnings[identity];
  if (cur == null) return list;
  final next = Map<String, List<StoredWarning>>.from(list.nodeWarnings);
  final rest = dropVerdict(cur);
  if (rest.isEmpty) {
    next.remove(identity);
  } else {
    next[identity] = rest;
  }
  return list.copyWith(nodeWarnings: next);
}

/// CANON §9.4 п. 1 — тело узла изменилось: вердикт недействителен, запись
/// стирается И узел включается обратно. Оживает ТОЛЬКО узел, выключенный
/// страховкой; выключенный человеком сменой тела не включается.
///
/// [oldBodies] — канонические тела прошлого набора по идентичности;
/// пустая карта значит «старого тела нет» → вердикт снимается (лучше лишняя
/// проверка ядром, чем починенный узел, оставшийся выключенным).
///
/// Возвращает НОВЫЕ карты `disabled` и `warnings` для `copyWith`.
({Map<String, DateTime> disabled, Map<String, List<StoredWarning>> warnings})
    refreshSubscriptionVerdicts({
  required Map<String, DateTime> disabled,
  required Map<String, List<StoredWarning>> warnings,
  required Map<String, String> oldBodies,
  required Map<String, String> newBodies,
}) {
  if (warnings.isEmpty) return (disabled: disabled, warnings: warnings);
  final nextDisabled = Map<String, DateTime>.from(disabled);
  final nextWarnings = <String, List<StoredWarning>>{};
  for (final e in warnings.entries) {
    final id = e.key;
    final hasVerdict = e.value.any((w) => w.isCoreRejected);
    if (!hasVerdict) {
      nextWarnings[id] = e.value;
      continue;
    }
    final oldBody = oldBodies[id];
    final newBody = newBodies[id];
    // Узел из набора ушёл — трогать нечего, запись доживёт до GC оверлея.
    if (newBody == null) {
      nextWarnings[id] = e.value;
      continue;
    }
    // Тело то же → вердикт держится. Тело другое ИЛИ старого тела нет →
    // вердикт снимается и узел включается обратно.
    if (oldBody != null && oldBody == newBody) {
      nextWarnings[id] = e.value;
      continue;
    }
    nextDisabled.remove(id);
    final rest = dropVerdict(e.value);
    if (rest.isNotEmpty) nextWarnings[id] = rest;
  }
  return (disabled: nextDisabled, warnings: nextWarnings);
}

/// CANON §9.4 п. 1 для ОДНОГО узла — ручная правка тела в редакторе (член
/// папки, ручной сервер). Подписка сравнивается картами (`refreshSubscription\
/// Verdicts`): там узлов много и они приходят пачкой с сети; здесь правится
/// ровно один, и сравнивать надо его самого.
///
/// Сравнение — тем же `canonicalNodeBody`, что и на refetch: один вопрос —
/// одна функция, иначе редактор и подписка разошлись бы в том, что считать
/// «тем же телом».
///
/// `true` — вердикт снимается И узел включается обратно (ровно то, что делает
/// ручное включение: `enabled: true` + [dropVerdict]). `false` — тело то же
/// либо вердикта на узле и не было, трогать нечего.
///
/// Узел без вердикта не оживает: смена тела включает только то, что выключила
/// страховка, выключенное человеком остаётся выключенным.
///
/// Переименование узла для этой функции — тоже смена тела: `emit()` включает
/// `tag`. Сужать не стали — на refetch подписки действует ровно та же
/// функция, и ответ на один вопрос должен быть один; цена ошибки
/// несимметрична (лишняя проверка ядром дешевле починенного узла,
/// оставшегося выключенным).
bool verdictDroppedByEdit({
  required List<StoredWarning> warnings,
  required NodeSpec? before,
  required NodeSpec? after,
}) {
  if (!warnings.any((w) => w.isCoreRejected)) return false;
  // Узла не стало (или не было) — сравнивать нечем: вердикт снимается.
  // Лишняя проверка ядром дешевле починенного узла, оставшегося выключенным.
  if (before == null || after == null) return true;
  return canonicalNodeBody(before) != canonicalNodeBody(after);
}

/// Канонические тела набора по идентичности узла — для сравнения «до/после».
Map<String, String> bodiesByIdentity(List<NodeSpec> nodes) {
  final ids = sourceNodeIdentities(nodes);
  return {
    for (final e in ids.entries) e.value: canonicalNodeBody(e.key),
  };
}

/// Проставить хранимые вердикты на разобранные узлы подписки.
///
/// Предупреждения узла в LxBox не хранятся — они вычисляются при разборе
/// (`parse_all.dart`), и любой пересчёт замещает их целиком. Вердикт ядра
/// пересчётом по телу НЕ воспроизводится (CANON §9.4: запись авторитетна),
/// поэтому его дописывает сюда единственное место-правило — иначе каждая
/// точка пересчёта стирала бы причину молча.
///
/// Дедуп по `(code, path)`: вердикт без пути, второго такого на узле не
/// бывает. Вердикт идёт ПЕРВЫМ — это приговор уровня узла.
void stampStoredVerdicts(
  List<NodeSpec> nodes,
  Map<String, List<StoredWarning>> stored,
) {
  if (stored.isEmpty) return;
  final ids = sourceNodeIdentities(nodes);
  for (final e in ids.entries) {
    final ws = stored[e.value];
    if (ws == null || ws.isEmpty) continue;
    stampNodeWarnings(e.key, ws);
  }
}

/// То же для одного узла (член папки, ручной сервер).
void stampNodeWarnings(NodeSpec node, List<StoredWarning> stored) {
  for (final w in stored) {
    final made = w.toWarning();
    node.warnings.removeWhere(
        (x) => x is RegistryWarning && x.code == made.code && x.path == null);
    node.warnings.insert(0, made);
  }
}

/// Снять с разобранного узла вердикт `core_rejected` — зеркало [stampNodeWarnings]
/// для ручного включения: хранилище уже очищено [dropVerdict], а
/// `NodeSpec.warnings` иначе держал бы значок до следующего разбора.
void unstampCoreRejected(NodeSpec node) {
  node.warnings.removeWhere((x) =>
      x is RegistryWarning && x.code == kCoreRejectedCode && x.path == null);
}

/// Хранимые вердикты + предупреждения разбора без мутации [node].
///
/// Та же логика, что [stampNodeWarnings], для отрисовки строк источников и
/// секции Notifications (вкладка Diagnostics) у ручного сервера / члена папки.
List<NodeWarning> mergedNodeWarnings(
  NodeSpec node,
  List<StoredWarning> stored,
) {
  final out = [...node.warnings];
  for (final w in stored) {
    final made = w.toWarning();
    out.removeWhere(
        (x) => x is RegistryWarning && x.code == made.code && x.path == null);
    out.insert(0, made);
  }
  return out;
}
