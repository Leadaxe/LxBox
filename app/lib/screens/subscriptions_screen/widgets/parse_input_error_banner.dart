import 'package:flutter/material.dart';

import '../../../models/ui_msg.dart';
import '../../subscription_detail_screen/widgets/node_warnings_sheet.dart';

/// §500 — ошибка вставки под полем Servers: базовая фраза; причины из
/// `dropped[]` — в шторке уведомлений (тап по строке открывает снова).
class ParseInputErrorBanner extends StatelessWidget {
  const ParseInputErrorBanner(this.error, {super.key});

  final UiMsg error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = TextStyle(color: theme.colorScheme.error);

    if (error is! ParseInputRejectedMsg ||
        !(error as ParseInputRejectedMsg).hasDropped) {
      return Text(error.render(), style: style);
    }

    final msg = error as ParseInputRejectedMsg;
    return InkWell(
      onTap: () => showNodeWarningsSheet(
        context,
        msg.dropped,
        sourceLabel: msg.sourceLabel,
      ),
      child: Text(msg.render(), style: style),
    );
  }
}
