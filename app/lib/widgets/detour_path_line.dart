import 'package:flutter/material.dart';

import '../models/node_warning.dart';
import '../services/builder/build_config.dart' show kDetourUnavailableCode;
import 'banner_palette.dart';

/// §752 — предупреждение последней сборки «detour снят» (`detour_unavailable`,
/// §739) среди [warnings] узла; `null` — detour сборка не снимала (или сборки
/// ещё не было).
RegistryWarning? detourRemovedWarning(Iterable<NodeWarning> warnings) {
  for (final w in warnings) {
    if (w is RegistryWarning && w.code == kDetourUnavailableCode) return w;
  }
  return null;
}

/// §752 — схема пути «Phone → хопы → узел → Internet» под выбором detour.
///
/// Рисует выбранный detour; если последняя сборка его сняла ([removed] —
/// цель недоступна, §739), путь перечёркнут и приглушён, под ним строка с ⚠
/// и [directText]: фактически узел идёт напрямую. Выбор detour не меняется.
class DetourPathLine extends StatelessWidget {
  const DetourPathLine({
    super.key,
    required this.path,
    required this.directText,
    this.removed,
  });

  /// Путь по выбранному detour (уже переведённая строка).
  final String path;

  /// Что фактически: «трафик идёт напрямую…» (переведённая строка).
  final String directText;

  /// Код сборки, снявший detour; `null` — путь действует, обычный вид.
  final RegistryWarning? removed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final style = theme.textTheme.bodySmall?.copyWith(color: muted);
    final w = removed;
    if (w == null) return Text(path, style: style);
    final (color, icon) = warningSeverityStyle(context, w.severity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          path,
          style: style?.copyWith(
            decoration: TextDecoration.lineThrough,
            decorationColor: muted,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 14, color: color),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                directText,
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
