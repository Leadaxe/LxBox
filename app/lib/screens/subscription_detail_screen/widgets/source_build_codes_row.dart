import 'package:flutter/material.dart';

import '../../../controllers/subscription_controller.dart';
import '../../../models/node_warning.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../widgets/banner_palette.dart';
import '../../subscriptions_screen/entry_warnings.dart';
import 'node_warnings_sheet.dart';

/// §739 итер. 2 — коды последней сборки, адресованные источнику целиком
/// (`detour_unavailable`, `node_detour_through_group`), строкой на странице
/// подписки / папки. Тот же вид, что строка «N entries dropped» (§561): значок
/// старшего уровня, заголовок старшего кода, «(+N more)», шеврон; тап — та же
/// шторка уведомлений с полным текстом.
///
/// Строки нет, если среди кодов нет warning/error: info, как и у бейджа строки
/// списка источников (`entryWarningSummary`), к действию не зовёт.
///
/// Слушает [controller] — после пересборки строка обновляется без перезахода
/// на страницу.
class SourceBuildCodesRow extends StatelessWidget {
  const SourceBuildCodesRow({
    super.key,
    required this.controller,
    required this.sourceId,
    this.padding = EdgeInsets.zero,
  });

  final SubscriptionController controller;
  final String sourceId;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final codes = controller.lastSourceBuildCodes[sourceId] ??
            const <RegistryWarning>[];
        final sorted = [...codes]
          ..sort((a, b) => b.severity.index.compareTo(a.severity.index));
        final spoken =
            sorted.where((w) => w.severity != WarningSeverity.info).toList();
        if (spoken.isEmpty) return const SizedBox.shrink();

        final theme = Theme.of(context);
        final top = spoken.first;
        final (color, icon) = warningSeverityStyle(context, top.severity);
        final more = spoken.length - 1;
        final text = more > 0
            ? getLocalText.s(
                "%1\$s (+%2\$d more)", inlineWarningMessage(top), more)
            : inlineWarningMessage(top);
        return Padding(
          padding: padding,
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => showNodeWarningsSheet(context, sorted),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(icon, size: 14, color: color),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      text,
                      style:
                          theme.textTheme.bodySmall?.copyWith(color: color),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 16, color: color),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
