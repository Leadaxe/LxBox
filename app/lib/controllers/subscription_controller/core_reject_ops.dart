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
import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../../models/template_vars.dart';
import '../../services/node_hash.dart';

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

/// Выключить узел [node] источника [list] и записать рядом вердикт
/// [reason]. `changed: false` — узла в источнике нет либо выключить его
/// нечем (служебная запись): автоматики нет.
VerdictApply applyVerdict(ServerList list, NodeSpec node, String reason) {
  final verdict = StoredWarning.coreRejected(reason);
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

/// Канонические тела набора по идентичности узла — для сравнения «до/после».
Map<String, String> bodiesByIdentity(List<NodeSpec> nodes) {
  final ids = sourceNodeIdentities(nodes);
  return {
    for (final e in ids.entries) e.value: canonicalNodeBody(e.key),
  };
}

/// Вердикт узла подписки → предупреждение для показа (§479). Пусто —
/// вердикта нет.
List<RegistryWarningLike> verdictWarningsOf(
        Map<String, List<StoredWarning>> map, String identity) =>
    [for (final w in map[identity] ?? const <StoredWarning>[]) w];

/// Псевдоним для читаемости сигнатуры выше.
typedef RegistryWarningLike = StoredWarning;
