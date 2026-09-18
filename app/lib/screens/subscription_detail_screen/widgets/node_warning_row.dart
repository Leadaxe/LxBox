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
/// проблему, но не чтобы понять её. Тап открывает шторку уведомлений со всем
/// списком, причиной и способом исправления ([showNodeWarningsSheet]).
///
/// §471 — текстом показывается только то, что требует действия: старшее из
/// error/warning и «+N more» по ним же. Info туда не попадает — после
/// §468/§469 info-кодов стало столько, что под каждым вторым узлом висела
/// строка «делать ничего не надо», и настоящие проблемы в ней тонули.
///
/// §479 — наличие info отмечается значком `ⓘ` в КОНЦЕ строки, приглушённым
/// (`onSurfaceVariant`), а не синим: строка списка говорит о том, что требует
/// внимания, и второй яркий значок спорил бы со значком уровня. Ревизия 1
/// §471 (значок перед значком уровня и, у info-only узла, у имени) отменена:
/// у имени значку не место, имя узла остаётся чистым.
class NodeWarningRow extends StatelessWidget {
  const NodeWarningRow(this.warnings, {super.key});

  final List<NodeWarning> warnings;

  @override
  Widget build(BuildContext context) {
    final sorted = [...warnings]
      ..sort((a, b) => b.severity.index.compareTo(a.severity.index));
    // Текстом — только actionable; если их нет, строки не будет вовсе: info
    // живёт значком в строке протокола ([NodeInfoBadge]).
    final spoken = sorted
        .where((w) => w.severity != WarningSeverity.info)
        .toList();
    final hasInfo = sorted.any((w) => w.severity == WarningSeverity.info);

    if (spoken.isEmpty) return const SizedBox.shrink();

    final w = spoken.first;
    final (color, icon) = warningSeverityStyle(context, w.severity);
    final more = spoken.length - 1;

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
            // §479 — info в конце строки: сначала то, что требует действия.
            if (hasInfo) NodeInfoBadge(warnings),
          ],
        ),
      ),
    );
  }
}

/// §479 — приглушённый `ⓘ` рядом со строкой узла: у узла без error/warning он
/// стоит в начале строки протокола (`ⓘ vless  de1.example.com:443`), у узла с
/// ними — в конце строки предупреждения. Третьей строки узел не получает ни в
/// одном из случаев.
///
/// Цвет — `onSurfaceVariant`, а не синий уровня: в списке info не зовёт к
/// действию, и яркий значок отбирал бы внимание у ⚠/✖ соседних строк. Внутри
/// уведомлений info остаётся синим (палитра §471).
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
          child: Icon(
            Icons.info_outline,
            size: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
