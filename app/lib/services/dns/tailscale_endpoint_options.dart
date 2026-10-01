// ===========================================================================
// §435/§575 — опции пикера `endpoint` у DNS-сервера типа `tailscale`
// (редактор DNS-сервера). Источник — перечень узлов тем же отбором, что у
// пресетов с `for_each` (`presetNodesForView`): включённые узлы типа
// `tailscale` своих записей, папок и подписок, тег — финальный тег последней
// сборки или отображаемый.
//
// Чистая функция над `List<ServerList>` — без storage и BuildContext, чтобы
// тестировалась изолированно (`tailscale_endpoint_options_test.dart`).
// ===========================================================================

import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../preset_nodes_view.dart';

/// Опция пикера `endpoint` у DNS-сервера типа `tailscale` (спека §9.4):
/// тег узла Tailscale. `enabled == false` → узел/источник выключен, сервер
/// на него санитайзер сборки выбросит (endpoint не эмитирован) — пикер
/// помечает «disabled — will be skipped» (как у членов DNS-группы).
final class TailscaleEndpointOption {
  const TailscaleEndpointOption({required this.tag, required this.enabled});
  final String tag;
  final bool enabled;
}

/// Тип узла, который служит `endpoint` DNS-серверу `tailscale`.
const String kTailscaleNodeType = 'tailscale';

/// Опции `endpoint` из списков источников в порядке хранения. Выключенные
/// узлы в перечень не входят: сервер на такой узел редактор покажет
/// значением вне списка. Дубль тега — первый побеждает (дропдаун требует
/// уникальных значений).
List<TailscaleEndpointOption> collectTailscaleEndpointOptions(
  List<ServerList> lists, {
  Map<String, NodeSpec> lastEmittedTagMap = const {},
}) {
  final seen = <String>{};
  return [
    for (final n in presetNodesForView(
      lists,
      nodeTypes: const {kTailscaleNodeType},
      lastEmittedTagMap: lastEmittedTagMap,
    ))
      if (seen.add(n.tag)) TailscaleEndpointOption(tag: n.tag, enabled: true),
  ];
}
