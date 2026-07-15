import 'package:flutter/material.dart';

import '../../../models/channel.dart';

/// §125 — тайл канала на табе Channels. Switch слева (вкл/выкл), тап по телу →
/// редактор канала. `vpn-1` всегда включён и неудаляем (switch disabled).
class RoutingChannelTile extends StatelessWidget {
  const RoutingChannelTile({
    super.key,
    required this.channel,
    required this.nodeCount,
    required this.onToggle,
    required this.onTap,
  });

  final Channel channel;

  /// Кол-во нод после фильтра (для subtitle). -1 = снимок недоступен.
  final int nodeCount;

  /// null для required-канала (`vpn-1`) — switch disabled.
  final ValueChanged<bool>? onToggle;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isRequired = channel.isRequired;
    final nodesStr = nodeCount < 0
        ? (channel.nodeFilter.isEmpty ? 'all nodes' : 'filtered')
        : '$nodeCount node${nodeCount == 1 ? '' : 's'}';
    final autoStr = channel.auto != null ? ' · auto' : '';
    final reqStr = isRequired ? ' · required' : '';
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 8, right: 8),
      leading: Switch(
        value: isRequired ? true : channel.enabled,
        onChanged: isRequired ? null : onToggle,
      ),
      // §274 — ⚙-префикс detour-канала централизован в displayLabel.
      title: Text(channel.displayLabel),
      subtitle: Text(
        '${channel.tag} · $nodesStr$autoStr$reqStr',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
