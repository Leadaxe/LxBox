import 'package:flutter/material.dart';

import '../../../models/node_warning.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../widgets/app_bottom_sheet.dart';
import 'node_notifications_view.dart';

/// §460 W2b / §479 — шторка уведомлений узла из списка подписки.
///
/// Строка под узлом (`NodeWarningRow`) показывает заголовок старшего кода и
/// «+N» — места на большее там нет. Здесь тот же список целиком, разложенный
/// по уровням, и к каждой записи то, чего строка не вмещает: что произошло,
/// почему и что с этим делать.
///
/// §479 — содержимое собирает [NodeNotificationsView], общий с разделом
/// `Notifications` экрана узла: одно событие не должно выглядеть двумя
/// разными в зависимости от того, откуда на него посмотрели.
Future<void> showNodeWarningsSheet(
  BuildContext context,
  List<NodeWarning> warnings,
) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => NodeWarningsSheet(warnings),
  );
}

/// Содержимое шторки. Отдельный публичный виджет — чтобы виджет-тесты могли
/// строить его без модального роутера.
class NodeWarningsSheet extends StatelessWidget {
  const NodeWarningsSheet(this.warnings, {super.key});

  final List<NodeWarning> warnings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              getLocalText.s("Notifications"),
              style: theme.textTheme.titleMedium,
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 8),
              child: NodeNotificationsView(warnings),
            ),
          ),
        ],
      ),
    );
  }
}
