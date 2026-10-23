import 'package:flutter/material.dart';

import '../../../models/direction.dart';
import '../../../widgets/reorder_grab_strip.dart';

/// §125 — тайл Направления на табе Directions. Switch слева (вкл/выкл), тап по телу →
/// редактор Направления. `vpn-1` всегда включён и неудаляем (switch disabled).
class RoutingDirectionTile extends StatelessWidget {
  const RoutingDirectionTile({
    super.key,
    required this.direction,
    required this.dragIndex,
    required this.nodeCount,
    required this.onToggle,
    required this.onTap,
  });

  final Direction direction;

  /// §673 — индекс в `ReorderableListView` для drag-handle слева.
  final int dragIndex;

  /// Кол-во нод после фильтра (для subtitle). -1 = снимок недоступен.
  final int nodeCount;

  /// null для required-Направления (`vpn-1`) — switch disabled.
  final ValueChanged<bool>? onToggle;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isRequired = direction.isRequired;
    final nodesStr = nodeCount < 0
        ? (direction.nodeFilter.isEmpty ? 'all nodes' : 'filtered')
        : '$nodeCount node${nodeCount == 1 ? '' : 's'}';
    final autoStr = direction.auto != null ? ' · auto' : '';
    final reqStr = isRequired ? ' · required' : '';
    final tile = ListTile(
      contentPadding: const EdgeInsets.only(left: 8, right: 8),
      leading: Switch(
        value: isRequired ? true : direction.enabled,
        onChanged: isRequired ? null : onToggle,
      ),
      // §274 — ⚙-префикс detour-Направления централизован в displayLabel.
      title: Text(direction.displayLabel),
      subtitle: Text(
        '${direction.tag} · $nodesStr$autoStr$reqStr',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
    // §673 — grab-strip как у правил маршрута и участников папки.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReorderGrabStrip(index: dragIndex),
          // Своя прозрачная Material: подложка подсветки (§258, запретные
          // зоны §673) не должна прятать ink ListTile.
          Expanded(
            child: Material(type: MaterialType.transparency, child: tile),
          ),
        ],
      ),
    );
  }
}
