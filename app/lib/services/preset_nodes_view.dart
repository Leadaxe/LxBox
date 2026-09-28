/// §578 — узлы для пресетов с `for_each` на экранах (маршруты, DNS, редактор
/// пресета, экран узла). Сборка берёт список из готового конфига
/// (`_collectPresetNodes` в `build_config.dart`); экрану конфиг не нужен —
/// список строится из источников контроллера тем же отбором: узел включён
/// (источник, член папки, отметка `disabled_hashes` подписки), `skip_presets`
/// из записи своего сервера или члена папки, у узла подписки — `false`.
///
/// Тег — финальный тег последней сборки ([lastEmittedTagMap]), если узел в
/// ней был; иначе отображаемый (`TagResolver.displayTag`): суффикс
/// уникализации аллокатора до сборки не известен, гейты реестра и ядра
/// экрану не видны (как у строк правил узлов §435). Чистые функции, без
/// виджетов.
library;

import '../models/custom_rule.dart';
import '../models/node_spec.dart';
import '../models/parser_config.dart';
import '../models/server_list.dart';
import '../models/template_vars.dart';
import 'builder/preset_expand.dart';
import 'l10n/locale_controller.dart';
import 'node_hash.dart';
import 'tag_resolver.dart';

/// Типы узлов (`node_type`), которые обслуживают пресеты с `for_each`.
Set<String> forEachNodeTypes(Iterable<SelectableRule> presets) => {
      for (final p in presets)
        if (p.forEach case final PresetForEach fe) fe.nodeType,
    };

/// Узлы источников в порядке списков для раскрытия `for_each` на экране.
/// Тело эмитится только у узлов, чей тип есть в [nodeTypes] (пресет читает
/// тело; прочие узлы пресету не нужны и в список не входят).
List<PresetNode> presetNodesForView(
  List<ServerList> lists, {
  required Set<String> nodeTypes,
  Map<String, NodeSpec> lastEmittedTagMap = const {},
}) {
  if (nodeTypes.isEmpty) return const [];
  // Обратная карта по ссылке: `NodeSpec.==` сравнивает id+tag, тёзки
  // схлопнулись бы (как `sourceNodeIdentities`).
  final finalTagOf = Map<NodeSpec, String>.identity();
  for (final e in lastEmittedTagMap.entries) {
    finalTagOf.putIfAbsent(e.value, () => e.key);
  }
  final out = <PresetNode>[];
  void add(NodeSpec node, String tagPrefix, bool skip) {
    if (!nodeTypes.contains(node.protocol)) return;
    final Map<String, dynamic> body;
    try {
      body = node.emit(TemplateVars.empty).map;
    } catch (_) {
      return; // узел, который не эмитится, в конфиг не попадёт
    }
    if (!nodeTypes.contains(body['type'])) return;
    out.add(PresetNode(
      tag: finalTagOf[node] ?? TagResolver.displayTag(tagPrefix, node.tag),
      body: body,
      skipPresets: skip,
    ));
  }

  for (final list in lists) {
    if (!list.enabled) continue;
    switch (list) {
      case UserServer u:
        for (final n in u.nodes) {
          add(n, u.tagPrefix, u.skipPresets);
        }
      case FolderServers f:
        for (final m in f.members) {
          final node = m.node;
          if (!m.enabled || node == null) continue;
          add(node, f.tagPrefix, m.skipPresets);
        }
      case SubscriptionServers s:
        final identities =
            s.disabledHashes.isEmpty ? null : sourceNodeIdentities(s.nodes);
        for (final n in s.nodes) {
          final id = identities?[n];
          if (id != null && s.disabledHashes.containsKey(id)) continue;
          add(n, s.tagPrefix, false);
        }
    }
  }
  return out;
}

/// Теги узлов, которые обслуживает пресет [rule] (порядок узлов). Пресет без
/// `for_each` — null: строке пресета подпись не нужна.
List<String>? presetServedTags(
  CustomRulePreset rule,
  SelectableRule preset,
  List<PresetNode> nodes, {
  Map<String, String> globalVars = const {},
}) {
  if (preset.forEach == null) return null;
  return [
    for (final n
        in presetForEachNodes(rule, preset, nodes, globalVars: globalVars))
      n.tag,
  ];
}

/// Подпись строки пресета с `for_each`: теги через запятую; узлов нет —
/// короткая подпись.
String presetServedNodesLabel(List<String> tags) => tags.isEmpty
    ? getLocalText.s("No matching nodes")
    : tags.join(', ');

/// Переключатель `Skip presets` на экране узла: свой сервер или член папки
/// ([isMember] у папки), и в шаблоне есть пресет с `for_each`, чей
/// `node_type` равен типу узла [nodeType]. У узла подписки записи нет —
/// переключателя нет.
bool skipPresetsToggleVisible({
  required ServerList list,
  required bool isMember,
  required String nodeType,
  required Iterable<SelectableRule> presets,
}) {
  final hasRecord = switch (list) {
    UserServer() => true,
    FolderServers() => isMember,
    SubscriptionServers() => false,
  };
  if (!hasRecord || nodeType.isEmpty) return false;
  return forEachNodeTypes(presets).contains(nodeType);
}
