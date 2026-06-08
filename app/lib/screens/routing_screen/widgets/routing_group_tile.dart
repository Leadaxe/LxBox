import 'package:flutter/material.dart';

import '../../../models/parser_config.dart';

/// SwitchListTile для proxy-group на табе Channels. `vpn-1` всегда включён и
/// не отключается (onChanged == null).
class RoutingGroupTile extends StatelessWidget {
  const RoutingGroupTile({
    super.key,
    required this.group,
    required this.enabled,
    required this.onChanged,
  });

  final PresetGroup group;

  /// Текущее значение switch (для required-группы caller передаёт true).
  final bool enabled;

  /// null для required-группы (`vpn-1`) — switch disabled.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    // VPN ① is always enabled — can't be disabled
    final isRequired = group.tag == 'vpn-1';
    return SwitchListTile(
      title: Text(group.label.isNotEmpty ? group.label : group.tag),
      subtitle: Text(
        isRequired
            ? '${group.type} · ${group.tag} · required'
            : '${group.type} · ${group.tag}',
        style: const TextStyle(fontSize: 12),
      ),
      value: isRequired ? true : enabled,
      onChanged: isRequired ? null : onChanged,
    );
  }
}
