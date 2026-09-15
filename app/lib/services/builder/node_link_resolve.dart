/// Резолв ссылок на узлы в финальные теги конфига (D-112, NODE_LINK §5).
///
/// Порт `core/config/nodelink_resolve.go` лаунчера на модели LxBox. Резолв
/// один на все носители (detour источника и члена, позиции цепочек) и идёт
/// ВТОРЫМ проходом: словарь целей заполняет `ServerListBuild.build`, когда
/// узел получил финальный тег, а разрешение начинается после того, как
/// собраны все источники, — цель вправе стоять в списке ниже ссылающегося.
///
/// Словарь:
/// - `byFolder[id][сырой тег]` — узлы папок И подписок (NODE_LINK §2.2);
/// - корневые узлы — финальные теги узлов одиночных серверов;
/// - корневые имена — Направления и их `-auto`, служебные outbound'ы шаблона,
///   цепочки, объявленные выше.
///
/// Fail-closed (§5.1, §5.2): не разрешившаяся ссылка никогда не превращается
/// в прямое соединение. Носитель detour выпадает из конфига с предупреждением
/// (каскадом — и те, кто ходил через него; кольцо — все участники), цепочка —
/// целиком (`chain_nodes.dart`).
library;

import '../../models/node_link.dart';
import '../../models/node_spec.dart';
import '../../models/singbox_entry.dart';

/// Исход разрешения одной ссылки: финальный тег или причина отказа (тексты
/// лаунчера, `core/config/emission_warning.go`).
final class NodeLinkResolution {
  const NodeLinkResolution.ok(String this.tag) : reason = '';
  const NodeLinkResolution.fail(this.reason) : tag = null;

  final String? tag;
  final String reason;

  bool get ok => tag != null;
}

/// Цели ссылок одной сборки (или превью экрана — `node_link_pool.dart`).
class NodeLinkTargets {
  final _byFolder = <String, Map<String, String>>{};

  /// S3: контейнер → финальная форма тега группы (префикс + сырой тег) →
  /// финальные теги групп с этой формой.
  final _groupForms = <String, Map<String, List<String>>>{};

  /// `id` контейнера → имя для текста предупреждения. Контейнеры сборки,
  /// включая выключенные: их ссылка — «нет узла», а не «источник удалён».
  final _containers = <String, String>{};

  final _rootNodes = <String>{};
  final _rootNames = <String>{};
  final _dropped = <String>{};
  final _linkByFinal = <String, NodeLink>{};

  /// Контейнер [id] участвует в сборке (папка или подписка).
  void noteContainer(String id, String name) => _containers[id] = name;

  /// Узел контейнера [containerId] с сырым тегом [rawTag] эмитирован под
  /// [finalTag]. Первый сырой тег побеждает (тёзки уникализирует
  /// `containerRawTags`).
  void noteMember(String containerId, String rawTag, String finalTag) {
    if (rawTag.isEmpty || finalTag.isEmpty) return;
    final byRaw = _byFolder.putIfAbsent(containerId, () => {});
    if (byRaw.containsKey(rawTag)) return;
    byRaw[rawTag] = finalTag;
    _linkByFinal.putIfAbsent(
        finalTag, () => NodeLink(folderId: containerId, tag: rawTag));
  }

  /// Группа контейнера: адресуется сырым тегом, а для S3 запоминается её
  /// финальная форма [finalForm].
  void noteGroup(
    String containerId,
    String rawTag,
    String finalForm,
    String finalTag,
  ) {
    noteMember(containerId, rawTag, finalTag);
    if (finalTag.isEmpty) return;
    (_groupForms.putIfAbsent(containerId, () => {})[finalForm] ??= [])
        .add(finalTag);
  }

  /// Узел одиночного сервера эмитирован под [finalTag].
  void noteRootNode(String finalTag) {
    if (finalTag.isEmpty) return;
    _rootNodes.add(finalTag);
    _linkByFinal.putIfAbsent(finalTag, () => NodeLink(tag: finalTag));
  }

  /// Корневые имена: Направления, служебные outbound'ы, цепочки.
  void addRootNames(Iterable<String> tags) {
    for (final t in tags) {
      if (t.isNotEmpty) _rootNames.add(t);
    }
  }

  /// Узлы, выпавшие из конфига на этой сборке: ссылка на них больше не
  /// разрешается.
  void markDropped(Iterable<String> finalTags) => _dropped.addAll(finalTags);

  /// Имя контейнера для текста; неизвестный — его `id`.
  String containerName(String id) {
    final name = _containers[id] ?? '';
    return name.isNotEmpty ? name : id;
  }

  /// Ссылка на эмитированный узел под финальным тегом [finalTag]; для
  /// корневого имени и неизвестного тега — корневая ссылка.
  NodeLink linkOfFinal(String finalTag) =>
      _linkByFinal[finalTag] ?? NodeLink(tag: finalTag);

  /// Финальный тег узла по ссылке без проверки корневых имён; `null` — не
  /// эмитирован.
  String? finalOf(NodeLink link) {
    if (link.isRoot) return _rootNodes.contains(link.tag) ? link.tag : null;
    return _byFolder[link.folderId]?[link.tag];
  }

  /// NODE_LINK §5.1 — ссылка → финальный тег.
  NodeLinkResolution resolve(NodeLink link) {
    if (link.tag.trim().isEmpty) {
      return const NodeLinkResolution.fail('the reference is empty');
    }
    if (!link.isRoot) {
      if (!_containers.containsKey(link.folderId)) {
        return const NodeLinkResolution.fail('the referenced source is gone');
      }
      var tag = _byFolder[link.folderId]?[link.tag];
      if (tag == null) {
        // S3 — пара с финальным тегом группы вместо сырого: только при
        // единственном кандидате.
        final forms = _groupForms[link.folderId]?[link.tag];
        if (forms != null && forms.length == 1) tag = forms.single;
      }
      if (tag == null) {
        return NodeLinkResolution.fail('it has no node "${link.tag}"');
      }
      if (_dropped.contains(tag)) {
        return NodeLinkResolution.fail('node "$tag" was skipped by this build');
      }
      return NodeLinkResolution.ok(tag);
    }
    if (_rootNodes.contains(link.tag)) {
      if (_dropped.contains(link.tag)) {
        return NodeLinkResolution.fail(
            'node "${link.tag}" was skipped by this build');
      }
      return NodeLinkResolution.ok(link.tag);
    }
    if (_rootNames.contains(link.tag)) return NodeLinkResolution.ok(link.tag);
    return NodeLinkResolution.fail('target "${link.tag}" is not among nodes, '
        'Directions and folder replacements');
  }

  /// Ссылка для текста предупреждения: `"tag"` или `"tag" in "источник"`.
  String describe(NodeLink link) => link.isRoot
      ? '"${link.tag}"'
      : '"${link.tag}" in "${containerName(link.folderId)}"';
}

/// detour-ссылка узла, отложенная до второго прохода.
final class DeferredDetour {
  const DeferredDetour({
    required this.holder,
    required this.link,
    required this.carrier,
    required this.entries,
    required this.node,
  });

  /// Entry, чей `detour` получит финальный тег: сам узел или последнее звено
  /// его родной цепочки (APPEND, §073).
  final SingboxEntry holder;

  final NodeLink link;

  /// Узел-носитель ссылки: его финальный тег называет предупреждение.
  final SingboxEntry carrier;

  /// Все entries узла (сам узел и звенья родной цепочки): выпадают вместе.
  final List<SingboxEntry> entries;

  final NodeSpec node;
}

/// Итог второго прохода detour-ссылок.
final class DeferredDetourReport {
  const DeferredDetourReport({
    required this.droppedEntries,
    required this.droppedNodes,
    required this.warnings,
  });

  /// Entries выпавших носителей — сборка убирает их из конфига.
  final Set<SingboxEntry> droppedEntries;

  final Set<NodeSpec> droppedNodes;

  /// EN-строки для `emitWarnings`, одна на выпавший узел.
  final List<String> warnings;
}

/// Второй проход detour-ссылок: финальный тег в `detour` держателя или
/// выпадение носителя (NODE_LINK §5.1, строгость ребра «detour узла»):
///
/// 1. ссылка не разрешилась или указывает на сам узел — носитель выпадает;
/// 2. кольцо detour-ссылок — выпадают все участники;
/// 3. каскад до неподвижной точки: носитель, чья цель выпала, выпадает сам.
///
/// Выпавшие теги помечаются в [targets]: позиции цепочек на них не
/// разрешатся.
DeferredDetourReport resolveDeferredDetours(
  List<DeferredDetour> pending,
  NodeLinkTargets targets,
) {
  if (pending.isEmpty) {
    return const DeferredDetourReport(
        droppedEntries: {}, droppedNodes: {}, warnings: []);
  }
  final target = <DeferredDetour, String>{};
  final reason = <DeferredDetour, String>{};
  // Финальный тег entry → носитель, которому entry принадлежит.
  final ownerOf = <String, DeferredDetour>{};
  for (final p in pending) {
    for (final e in p.entries) {
      ownerOf.putIfAbsent(e.tag, () => p);
    }
  }

  for (final p in pending) {
    final r = targets.resolve(p.link);
    if (!r.ok) {
      reason[p] = r.reason;
    } else if (ownerOf[r.tag] == p) {
      reason[p] = 'the detour points at the node itself';
    } else {
      target[p] = r.tag!;
    }
  }

  // Кольца: идём по цепочке носителей от каждого; вернулись в себя — кольцо.
  for (final p in pending) {
    if (reason.containsKey(p)) continue;
    final seen = <DeferredDetour>{p};
    var cur = p;
    while (true) {
      final t = target[cur];
      final next = t == null ? null : ownerOf[t];
      if (next == null) break;
      if (next == p) {
        reason[p] = 'the detour loops back to this node';
        break;
      }
      if (!seen.add(next)) break;
      cur = next;
    }
  }

  // Каскад.
  final droppedTags = <String>{
    for (final p in reason.keys)
      for (final e in p.entries) e.tag,
  };
  var changed = true;
  while (changed) {
    changed = false;
    for (final p in pending) {
      if (reason.containsKey(p)) continue;
      final t = target[p];
      if (t != null && droppedTags.contains(t)) {
        reason[p] = 'node "$t" it goes through was skipped';
        for (final e in p.entries) {
          droppedTags.add(e.tag);
        }
        changed = true;
      }
    }
  }

  // §377 — одна строка на ссылку и причину, а не на узел: папка генератора
  // на 138 узлов с одной висячей ссылкой дала бы 138 строк на каждую сборку.
  final carriersByCause = <(String, String), List<String>>{};
  final droppedEntries = Set<SingboxEntry>.identity();
  final droppedNodes = Set<NodeSpec>.identity();
  for (final p in pending) {
    final why = reason[p];
    if (why == null) {
      p.holder.map['detour'] = target[p];
      continue;
    }
    droppedEntries.addAll(p.entries);
    droppedNodes.add(p.node);
    final carriers =
        carriersByCause.putIfAbsent((targets.describe(p.link), why), () => []);
    if (!carriers.contains(p.carrier.tag)) carriers.add(p.carrier.tag);
  }
  targets.markDropped(droppedTags);
  return DeferredDetourReport(
    droppedEntries: droppedEntries,
    droppedNodes: droppedNodes,
    warnings: [
      for (final e in carriersByCause.entries)
        _unresolvedDetourLine(e.value, e.key.$1, e.key.$2),
    ],
  );
}

/// Строка о носителях [carriers], выпавших из-за одной ссылки [link] с одной
/// причиной [why]. Формат перечня — §377: первые пять имён, остаток счётчиком.
String _unresolvedDetourLine(List<String> carriers, String link, String why) {
  const tail = 'is not emitted, so its traffic never goes direct.';
  if (carriers.length == 1) {
    return 'Node "${carriers.single}" was skipped: its detour $link did not '
        'resolve — $why. A node whose detour does not resolve $tail';
  }
  const shown = 5;
  final head = carriers.take(shown).map((c) => '"$c"').join(', ');
  final rest = carriers.length - shown;
  return '${carriers.length} nodes ($head${rest > 0 ? ', and $rest more' : ''}) '
      'were skipped: their detour $link did not resolve — $why. A node whose '
      'detour does not resolve $tail';
}
