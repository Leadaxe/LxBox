/// §435 — строки правил узлов на табе Rules экрана Routing
/// (NODE_SECTIONS.md §7): записи `sections.rules[]` свободных узлов
/// показываются на ОБЩЕЙ оси `num` вместе с корневыми правилами, но живут в
/// узле — в `_customRules` экрана не кладутся (буфер персистится целиком в
/// `custom_rules`, перечитывается при heal, экспортируется, обходится
/// SRS-кэшем). Здесь — чистая логика без виджетов: сбор ссылок на записи из
/// списка источников, объединённый порядок, применение drag'а и разнесение
/// изменений по владельцам. Экран только вызывает и персистит.
library;

import '../../models/custom_rule.dart';
import '../../models/node_sections.dart';
import '../../models/parser_config.dart' show kDefaultRuleNum;
import '../../models/server_list.dart';
import '../../services/builder/rule_order.dart';
import '../../services/tag_resolver.dart';

/// Владелец записи: индекс источника в `SubscriptionController.entries` и
/// индекс члена папки (`null` — одиночный `UserServer`).
typedef NodeRuleOwner = ({int entryIndex, int? memberIndex});

/// Ссылка на одно правило узла для показа и записи обратно.
final class NodeRuleRef {
  const NodeRuleRef({
    required this.entryIndex,
    required this.memberIndex,
    required this.ruleIndex,
    required this.rule,
    required this.displayRule,
    required this.sourceId,
    required this.finalTag,
    required this.nodeDisabled,
  });

  final int entryIndex;
  final int? memberIndex;

  /// Индекс записи в `sections.rules` владельца.
  final int ruleIndex;

  /// Запись как хранится — с плейсхолдерами `@self`. Объект из
  /// `sections.rules` владельца (в момент сбора); `orderNum` мутируется на
  /// месте `placeRuleAfter`, запись обратно идёт по индексу и `id`
  /// ([applyNodeRuleUpdates]), а не по identity.
  final CustomRule rule;

  /// Та же запись после подстановки финального тега (для имени, `summary()`
  /// и outbound в подзаголовке).
  final CustomRule displayRule;

  /// `ServerList.id` владельца — стабильный ключ строки и проверка, что
  /// индекс источника не уехал между сбором и записью.
  final String sourceId;

  /// Финальный тег узла для пометки «from node …». До сборки суффикс
  /// уникализации аллокатора (`-1`) неизвестен — допустимо.
  final String finalTag;

  /// Узел или его источник выключен: строка показывается приглушённой с
  /// подсказкой, тумблер живой (паритет с лаунчером, спека §9.1).
  final bool nodeDisabled;

  NodeRuleOwner get owner => (entryIndex: entryIndex, memberIndex: memberIndex);

  /// Позиция на общей оси: без `num` — [kNodeRuleDefaultNum], как при сборке.
  int get axisNum => rule.orderNum ?? kNodeRuleDefaultNum;

  /// Стабильный ключ строки в `ReorderableListView`.
  String get rowKey => 'node:$sourceId:$memberIndex:${rule.id}';

  NodeRuleRef copyWith({CustomRule? rule, CustomRule? displayRule}) =>
      NodeRuleRef(
        entryIndex: entryIndex,
        memberIndex: memberIndex,
        ruleIndex: ruleIndex,
        rule: rule ?? this.rule,
        displayRule: displayRule ?? this.displayRule,
        sourceId: sourceId,
        finalTag: finalTag,
        nodeDisabled: nodeDisabled,
      );
}

/// Строка объединённого списка таба Rules.
sealed class RuleRow {
  const RuleRow();

  /// Объект правила на оси (корневой — из `_customRules`, узловой — из
  /// секций узла). Именно он попадает во временный список `placeRuleAfter`.
  CustomRule get rule;

  /// Ключ строки для `ReorderableListView`.
  String get rowKey;
}

/// Корневое правило — индекс в `_customRules` экрана.
final class RootRuleRow extends RuleRow {
  const RootRuleRow(this.index, this.rule);

  final int index;
  @override
  final CustomRule rule;

  @override
  String get rowKey => rule.id;
}

/// Правило узла.
final class NodeRuleRow extends RuleRow {
  const NodeRuleRow(this.ref);

  final NodeRuleRef ref;

  @override
  CustomRule get rule => ref.rule;

  @override
  String get rowKey => ref.rowKey;
}

/// Собрать правила всех свободных узлов с секциями: `UserServer` в корне и
/// члены папок; подписки и цепочки записей не носят (NODE_SECTIONS.md §1).
/// Узел без распарсенной ноды строк не даёт (тега нет). Выключенный узел или
/// источник — даёт, с флагом [NodeRuleRef.nodeDisabled]. Порядок — порядок
/// источников и записей.
List<NodeRuleRef> collectNodeRules(List<ServerList> lists) {
  final out = <NodeRuleRef>[];
  for (var ei = 0; ei < lists.length; ei++) {
    final list = lists[ei];
    switch (list) {
      case UserServer u:
        if (u.nodes.isEmpty) continue;
        _addNodeRules(
          out,
          entryIndex: ei,
          memberIndex: null,
          sourceId: u.id,
          sections: u.sections,
          finalTag: TagResolver.displayTag(u.tagPrefix, u.nodes.first.tag),
          nodeDisabled: !u.enabled,
        );
      case FolderServers f:
        for (var mi = 0; mi < f.members.length; mi++) {
          final m = f.members[mi];
          final node = m.node;
          if (node == null) continue;
          _addNodeRules(
            out,
            entryIndex: ei,
            memberIndex: mi,
            sourceId: f.id,
            sections: m.sections,
            finalTag: TagResolver.displayTag(f.tagPrefix, node.tag),
            nodeDisabled: !f.enabled || !m.enabled,
          );
        }
      case SubscriptionServers():
        break;
    }
  }
  return out;
}

void _addNodeRules(
  List<NodeRuleRef> out, {
  required int entryIndex,
  required int? memberIndex,
  required String sourceId,
  required NodeSections? sections,
  required String finalTag,
  required bool nodeDisabled,
}) {
  if (sections == null || sections.rules.isEmpty) return;
  // Подстановка идёт JSON-обходом (NODE_SECTIONS.md §2) — один раз на узел.
  // Записи валидны с чтения, round-trip сохраняет их число; на всякий случай
  // при расхождении показываем как хранится.
  final substituted = sections.substituteSelf(finalTag).rules;
  final aligned = substituted.length == sections.rules.length;
  for (var ri = 0; ri < sections.rules.length; ri++) {
    final rule = sections.rules[ri];
    out.add(NodeRuleRef(
      entryIndex: entryIndex,
      memberIndex: memberIndex,
      ruleIndex: ri,
      rule: rule,
      displayRule: aligned ? substituted[ri] : rule,
      sourceId: sourceId,
      finalTag: finalTag,
      nodeDisabled: nodeDisabled,
    ));
  }
}

/// Объединённый порядок по оси `num`: корневые — `orderNum ??
/// kDefaultRuleNum` (как `sortRulesByNum`), узловые — `orderNum ??
/// kNodeRuleDefaultNum`. Сортировка стабильная; при равном номере корневые
/// раньше узловых — так же сливает сборка (`[...customRules, ...injected]`
/// → `normalizeRuleOrder`).
List<RuleRow> buildRuleRows(
  List<CustomRule> customRules,
  List<NodeRuleRef> nodeRules,
) {
  final indexed = <(int num, int seq, RuleRow row)>[
    for (var i = 0; i < customRules.length; i++)
      (
        customRules[i].orderNum ?? kDefaultRuleNum,
        i,
        RootRuleRow(i, customRules[i]),
      ),
    for (var i = 0; i < nodeRules.length; i++)
      (nodeRules[i].axisNum, customRules.length + i, NodeRuleRow(nodeRules[i])),
  ];
  indexed.sort((a, b) {
    final byNum = a.$1.compareTo(b.$1);
    return byNum != 0 ? byNum : a.$2.compareTo(b.$2);
  });
  return [for (final e in indexed) e.$3];
}

/// Изменение одной записи узла для записи обратно во владельца.
final class NodeRuleUpdate {
  const NodeRuleUpdate({required this.ref, this.enabled, this.orderNum});

  final NodeRuleRef ref;
  final bool? enabled;
  final int? orderNum;
}

/// Результат drag'а на объединённом списке.
final class RuleDragResult {
  const RuleDragResult({required this.rootChanged, required this.nodeUpdates});

  static const none = RuleDragResult(rootChanged: false, nodeUpdates: []);

  /// Хотя бы у одного корневого правила изменился `orderNum` — экран
  /// пересортировывает `_customRules` и стейджит (`markDirty`).
  final bool rootChanged;

  /// Узловые записи с новым `orderNum` — экран разносит по владельцам
  /// ([groupNodeRuleUpdates] → [applyNodeRuleUpdates] → контроллер).
  final List<NodeRuleUpdate> nodeUpdates;

  bool get isEmpty => !rootChanged && nodeUpdates.isEmpty;
}

/// Drag строки [oldIndex] на место [newIndex] (семантика `onReorderItem`:
/// `newIndex` — в списке БЕЗ перетаскиваемого элемента). `placeRuleAfter`
/// работает над временным объединённым списком и мутирует `orderNum` на
/// месте — ленивый сдвиг может задеть соседей обоих видов, поэтому результат
/// называет обе стороны. Узловое правило сортируемо всегда; корневое — по
/// [isRootSortable] (traffic-processing держит позицию).
RuleDragResult applyRuleDrag(
  List<RuleRow> rows,
  int oldIndex,
  int newIndex, {
  required bool Function(CustomRule) isRootSortable,
}) {
  if (oldIndex < 0 || oldIndex >= rows.length) return RuleDragResult.none;
  if (newIndex < 0 || newIndex > rows.length - 1) return RuleDragResult.none;

  final combined = [for (final r in rows) r.rule];
  final nodeObjs = Set<CustomRule>.identity()
    ..addAll([for (final r in rows) if (r is NodeRuleRow) r.rule]);
  bool sortable(CustomRule r) => nodeObjs.contains(r) || isRootSortable(r);

  final moved = combined[oldIndex];
  if (!sortable(moved)) return RuleDragResult.none;
  final before = [for (final r in combined) r.orderNum];

  // Цель — правило, ЗА которым встаём, в списке без самого moved (см.
  // `_onReorderCustomRule` до §435: после удаления moved индексы ниже него
  // смещаются). Бросок в начало → target = null → старт пользовательской
  // зоны, несортируемая шапка не двигается.
  final rest = [...combined]..removeAt(oldIndex);
  final target = newIndex == 0 ? null : rest[newIndex - 1];
  placeRuleAfter(combined, moved, target, isSortable: sortable);

  var rootChanged = false;
  final nodeUpdates = <NodeRuleUpdate>[];
  for (var i = 0; i < rows.length; i++) {
    final now = combined[i].orderNum;
    if (now == before[i]) continue;
    switch (rows[i]) {
      case RootRuleRow():
        rootChanged = true;
      case NodeRuleRow(:final ref):
        nodeUpdates.add(NodeRuleUpdate(ref: ref, orderNum: now));
    }
  }
  return RuleDragResult(rootChanged: rootChanged, nodeUpdates: nodeUpdates);
}

/// Сгруппировать изменения по владельцу — один вызов контроллера на узел.
Map<NodeRuleOwner, List<NodeRuleUpdate>> groupNodeRuleUpdates(
  Iterable<NodeRuleUpdate> updates,
) {
  final out = <NodeRuleOwner, List<NodeRuleUpdate>>{};
  for (final u in updates) {
    (out[u.ref.owner] ??= []).add(u);
  }
  return out;
}

/// Новые секции владельца с применёнными изменениями. Запись ищется по
/// индексу и `id` (ссылка могла устареть: источник перечитан, запись
/// заменена `withEnabled`) — несовпадение молча пропускается. `enabled` —
/// через `withEnabled` (новый объект, `id`/`orderNum` сохраняются);
/// `orderNum` — на месте, как во всём §370. DNS-списки не трогаются.
NodeSections applyNodeRuleUpdates(
  NodeSections sections,
  Iterable<NodeRuleUpdate> updates,
) {
  final rules = List<CustomRule>.of(sections.rules);
  for (final u in updates) {
    final i = u.ref.ruleIndex;
    if (i < 0 || i >= rules.length) continue;
    if (rules[i].id != u.ref.rule.id) continue;
    var r = rules[i];
    final enabled = u.enabled;
    if (enabled != null && r.enabled != enabled) r = r.withEnabled(enabled);
    final num = u.orderNum;
    if (num != null) r.orderNum = num;
    rules[i] = r;
  }
  return sections.copyWith(rules: rules);
}

/// Секции владельца [owner] в списке источников; `null` — владелец уехал
/// (индекс за границей, другой `id`, не тот тип) или секций нет.
NodeSections? sectionsOfOwner(
  List<ServerList> lists,
  NodeRuleOwner owner, {
  required String sourceId,
}) {
  if (owner.entryIndex < 0 || owner.entryIndex >= lists.length) return null;
  final list = lists[owner.entryIndex];
  if (list.id != sourceId) return null;
  final mi = owner.memberIndex;
  return switch (list) {
    UserServer u when mi == null => u.sections,
    FolderServers f when mi != null && mi >= 0 && mi < f.members.length =>
      f.members[mi].sections,
    _ => null,
  };
}

/// Отпечаток набора строк: экран сравнивает его на каждое уведомление
/// контроллера (их много — проба, статусы) и перерисовывается только когда
/// изменилось то, что видно: состав, `enabled`, `num`, тег, приглушение.
String nodeRulesSignature(List<NodeRuleRef> refs) {
  final sb = StringBuffer();
  for (final r in refs) {
    sb
      ..write(r.entryIndex)
      ..write('/')
      ..write(r.memberIndex)
      ..write('/')
      ..write(r.ruleIndex)
      ..write('/')
      ..write(r.rule.id)
      ..write('/')
      ..write(r.rule.enabled)
      ..write('/')
      ..write(r.rule.orderNum)
      ..write('/')
      ..write(r.finalTag)
      ..write('/')
      ..write(r.nodeDisabled)
      ..write('/')
      ..write(r.displayRule.name)
      ..write('\n');
  }
  return sb.toString();
}
