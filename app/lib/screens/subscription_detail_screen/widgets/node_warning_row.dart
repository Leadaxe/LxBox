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
/// текста ПЕРЕД значком уровня. Полный текст info живёт на экране узла — там
/// режим по умолчанию ([compact] = false), и текстом показываются все уровни.
///
/// §471 ревизия 1 — у узла с одними только info строки нет вовсе: значок
/// уезжает к имени узла ([NodeInfoBadge] в `title`). Здесь это выражено тем,
/// что компактный режим без actionable отдаёт [SizedBox.shrink]; список сам
/// не вставляет строку в `subtitle` в этом случае.
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

    // Ревизия 1: компактный режим без actionable — не строка, а значок у
    // имени. Рисовать здесь нечего, и пустой `Row` в `subtitle` дал бы узлу
    // лишнюю высоту.
    if (spoken.isEmpty) return const SizedBox.shrink();

    final children = <Widget>[];
    // Ревизия 1: info стоит ПЕРЕД значком уровня — `ⓘ ⚠ текст (+N more)`.
    if (compact && infos.isNotEmpty) {
      final (color, icon) = warningSeverityStyle(context, WarningSeverity.info);
      children.addAll([
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
      ]);
    }
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
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

/// §471 ревизия 1 — синий `ⓘ` у ИМЕНИ узла в списке подписки: узел, у
/// которого нет ничего кроме info, строки под собой не получает вовсе.
/// Решение владельца по ASCII-макету: третья строка под каждым вторым узлом
/// ломала ритм списка, а значок у имени читается как свойство узла.
///
/// Тап открывает ту же шторку, что и строка предупреждения. `opaque` и
/// подложка 24×24 — чтобы тап не проваливался в `onTap` строки (разбор узла):
/// сам значок 14 px, попасть в него пальцем иначе нельзя.
class NodeInfoBadge extends StatelessWidget {
  const NodeInfoBadge(this.warnings, {super.key});

  /// ВСЕ предупреждения узла — шторка показывает их целиком. Значок
  /// рисуется, когда среди них есть info (гейт — на вызывающей стороне).
  final List<NodeWarning> warnings;

  @override
  Widget build(BuildContext context) {
    final infos =
        warnings.where((w) => w.severity == WarningSeverity.info).toList();
    if (infos.isEmpty) return const SizedBox.shrink();
    final (color, icon) = warningSeverityStyle(context, WarningSeverity.info);
    return Semantics(
      button: true,
      // Текста рядом нет — метку скринридеру собираем из самого
      // предупреждения: он слышит то, что зрячий прочитает в шторке.
      label: infos.first.message(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showNodeWarningsSheet(context, warnings),
        child: SizedBox(
          width: 24,
          height: 24,
          child: Icon(icon, size: 14, color: color),
        ),
      ),
    );
  }
}
