import 'package:flutter/material.dart';

import '../../../models/node_warning.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../widgets/banner_palette.dart';
import 'node_warnings_sheet.dart';

/// Inline warning-line под нодой. Сортируем по severity (error → warning →
/// info), показываем первое. Цвета уровней — общие на всё приложение
/// ([warningSeverityStyle]).
///
/// §460 W2b — строка тапается: короткого текста хватает, чтобы заметить
/// проблему, но не чтобы понять её. Тап открывает шторку со всем списком,
/// причиной и способом исправления ([showNodeWarningsSheet]).
///
/// §471 — два режима. В списке узлов ([compact] = true) текстом показывается
/// только то, что требует действия: старшее из error/warning и «+N more» по
/// ним же. Info туда не попадает — после §468/§469 info-кодов стало столько,
/// что под каждым вторым узлом висела строка «делать ничего не надо», и
/// настоящие проблемы в ней тонули. Наличие info отмечается синим значком без
/// текста в конце строки; у узла с одними только info остаётся один этот
/// значок. Полный текст info живёт на экране узла — там режим по умолчанию
/// ([compact] = false), и текстом показываются все уровни.
class NodeWarningRow extends StatelessWidget {
  const NodeWarningRow(this.warnings, {super.key, this.compact = false});

  final List<NodeWarning> warnings;

  /// Список узлов: info — значком, без текста. По умолчанию (экран узла) —
  /// полный текст любого уровня.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final sorted = [...warnings]
      ..sort((a, b) => b.severity.index.compareTo(a.severity.index));
    // Что показываем текстом. В компактном режиме — только actionable; если
    // их нет, текста не будет вовсе.
    final spoken = compact
        ? sorted.where((w) => w.severity != WarningSeverity.info).toList()
        : sorted;
    final infos =
        sorted.where((w) => w.severity == WarningSeverity.info).toList();

    final children = <Widget>[];
    if (spoken.isNotEmpty) {
      final w = spoken.first;
      final (color, icon) = warningSeverityStyle(context, w.severity);
      final more = spoken.length - 1;
      children.addAll([
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
      ]);
    }
    if (compact && infos.isNotEmpty) {
      final (color, icon) = warningSeverityStyle(context, WarningSeverity.info);
      // Перед значком отступ нужен только если слева есть текст: у узла с
      // одними info значок стоит первым.
      if (children.isNotEmpty) children.add(const SizedBox(width: 4));
      children.add(Icon(icon, size: 12, color: color));
    }

    return Semantics(
      button: true,
      // Значок info без текста: зрячий видит подсказку, скринридер обязан
      // услышать то же, что покажет шторка. Когда текст в строке есть, метка
      // собирается из него самого — дублировать её в Semantics не нужно.
      label: children.length == 1 ? infos.first.message() : null,
      // GestureDetector, а не InkWell: строка живёт и в `subtitle` ListTile'а
      // списка узлов, у которого свой onTap — рябь на чужой поверхности
      // выглядела бы срабатыванием строки узла. `opaque` нужен, чтобы тап
      // по строке не проваливался на ListTile под ней.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showNodeWarningsSheet(context, warnings),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}
