import 'package:flutter/material.dart';

import '../../../services/app_log.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../debug_screen.dart';

/// §614 — красная строка «Errors (N)» под списком узлов: N — записи уровня
/// error в [AppLog] (оба источника) с последнего открытия журнала. N = 0 —
/// строки нет. Тап открывает журнал с фильтром «только error» и обнуляет
/// счётчик. SnackBar ошибок §166 работает как раньше, эта строка — довесок.
class ErrorsCounterRow extends StatelessWidget {
  const ErrorsCounterRow({super.key, this.onOpen});

  /// Ключ строки для тестов.
  static const rowKey = ValueKey('home-errors-counter');

  /// Переход в журнал; по умолчанию — push [DebugScreen] с `errorsOnly`.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final appLog = AppLog.I;
    return ListenableBuilder(
      listenable: appLog,
      builder: (context, _) {
        final n = appLog.errorsSinceSeen;
        if (n <= 0) return const SizedBox.shrink();
        final color = Theme.of(context).colorScheme.error;
        return InkWell(
          key: rowKey,
          onTap: () {
            appLog.markErrorsSeen();
            final open = onOpen;
            if (open != null) {
              open();
              return;
            }
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DebugScreen(errorsOnly: true),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 18, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    getLocalText.s("Errors (%d)", n),
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(Icons.chevron_right, size: 18, color: color),
              ],
            ),
          ),
        );
      },
    );
  }
}
