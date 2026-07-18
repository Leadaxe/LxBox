import 'package:flutter/material.dart';

import '../../../models/node_warning.dart';
import '../../../services/l10n/locale_controller.dart';

/// Inline warning-line под нодой. Сортируем по severity (error → warning →
/// info), показываем первый. Цвет: error=красный, warning=оранжевый,
/// info=серый (TLS-insecure часто намеренное → не должен орать).
class NodeWarningRow extends StatelessWidget {
  const NodeWarningRow(this.warnings, {super.key});
  final List<NodeWarning> warnings;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sorted = [...warnings]
      ..sort((a, b) => b.severity.index.compareTo(a.severity.index));
    final w = sorted.first;
    final (color, icon) = switch (w.severity) {
      WarningSeverity.error => (cs.error, Icons.error_outline),
      WarningSeverity.warning => (Colors.orange, Icons.warning_amber),
      WarningSeverity.info => (cs.onSurfaceVariant, Icons.info_outline),
    };
    final more = warnings.length - 1;
    return Row(
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            more > 0
                ? getLocalText.s("%1\$s (+%2\$d more)", w.message(), more)
                : w.message(),
            style: TextStyle(fontSize: 10, color: color),
          ),
        ),
      ],
    );
  }
}
