import 'package:flutter/material.dart';

import '../../../models/node_warning.dart';
import '../../../services/l10n/locale_controller.dart';
import 'node_warnings_sheet.dart';

/// Inline warning-line под нодой. Сортируем по severity (error → warning →
/// info), показываем первый. Цвет: error=красный, warning=оранжевый,
/// info=серый (TLS-insecure часто намеренное → не должен орать).
///
/// §460 W2b — строка тапается: короткого текста хватает, чтобы заметить
/// проблему, но не чтобы понять её. Тап открывает шторку со всем списком,
/// причиной и способом исправления ([showNodeWarningsSheet]). Вид самой
/// строки не изменился.
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
    return Semantics(
      button: true,
      // GestureDetector, а не InkWell: строка живёт и в `subtitle` ListTile'а
      // списка узлов, у которого свой onTap — рябь на чужой поверхности
      // выглядела бы срабатыванием строки узла. `opaque` нужен, чтобы тап
      // по строке не проваливался на ListTile под ней.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showNodeWarningsSheet(context, warnings),
        child: Row(
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
        ),
      ),
    );
  }
}
