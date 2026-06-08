import 'package:flutter/material.dart';

import '../../../models/home_state.dart';

/// Статус-чип VPN-туннеля в connect-controls на главном экране: иконка щита +
/// label текущего [TunnelStatus]. Во время connecting иконка вращается
/// ([connectingAnim], которым управляет `_HomeScreenState` вне build-фазы).
///
/// UI-маппинг: revoked и `unknown` показываются как disconnected (нейтральный
/// off-state — факт revoke юзер получает через SnackBar, не алармирующий чип).
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.state,
    required this.isRevoked,
    required this.isConnecting,
    required this.connectingAnim,
  });

  final HomeState state;
  final bool isRevoked;
  final bool isConnecting;
  final Animation<double> connectingAnim;

  @override
  Widget build(BuildContext context) {
    final icon = state.tunnelUp
        ? Icons.shield
        : isConnecting
            ? Icons.sync
            : Icons.shield_outlined;
    final color = state.tunnelUp ? Theme.of(context).colorScheme.primary : null;
    final bgColor =
        state.tunnelUp ? Theme.of(context).colorScheme.primaryContainer : null;
    final label = (isRevoked || state.tunnel == TunnelStatus.unknown)
        ? TunnelStatus.disconnected.label
        : state.tunnel.label;

    Widget iconWidget = Icon(icon, size: 18, color: color);
    if (isConnecting) {
      iconWidget = AnimatedBuilder(
        animation: connectingAnim,
        builder: (_, child) => Transform.rotate(
          angle: connectingAnim.value * 2 * 3.14159,
          child: child,
        ),
        child: iconWidget,
      );
    }

    return Chip(
      label: Text(label),
      avatar: iconWidget,
      backgroundColor: bgColor,
    );
  }
}
