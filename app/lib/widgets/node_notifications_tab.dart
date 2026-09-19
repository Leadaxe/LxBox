import 'safe_bottom.dart';
import 'package:flutter/material.dart';

import '../models/node_warning.dart';
import '../screens/subscription_detail_screen/widgets/node_notifications_view.dart';
import '../services/l10n/locale_controller.dart';
import 'banner_palette.dart';

/// §497 — вкладка «Notifications» на экранах деталей узла: общая подпись
/// TabBar и тело вкладки. Содержимое — тот же [NodeNotificationsView], что
/// в шторке из списка (§479); пустое состояние одной строкой, если у узла
/// предупреждений нет.
class NodeNotificationsTabLabel extends StatelessWidget {
  const NodeNotificationsTabLabel({super.key, required this.warnings});

  final List<NodeWarning> warnings;

  @override
  Widget build(BuildContext context) {
    final label = getLocalText.s("Notifications");
    if (warnings.isEmpty) return Tab(text: label);

    final sorted = [...warnings]
      ..sort((a, b) => b.severity.index.compareTo(a.severity.index));
    final (color, icon) = warningSeverityStyle(context, sorted.first.severity);

    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          const SizedBox(width: 4),
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 2),
          Text(
            '${warnings.length}', // l10n-exempt: число рядом со значком уровня
            style: TextStyle(color: color, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Тело вкладки Notifications: список всех предупреждений узла или пустое
/// состояние. [warnings] — `NodeSpec.warnings` (разбор + вердикт
/// `core_rejected`, если проставлен `stampStoredVerdicts`).
class NodeNotificationsTab extends StatelessWidget {
  const NodeNotificationsTab({super.key, required this.warnings});

  final List<NodeWarning> warnings;

  @override
  Widget build(BuildContext context) {
    if (warnings.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            getLocalText.s("No notifications for this server"),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 16).withSafeBottom(context),
      children: [
        NodeNotificationsView(warnings),
      ],
    );
  }
}
