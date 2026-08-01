import 'package:flutter/material.dart';

import '../services/l10n/locale_controller.dart';
import '../services/probe/probe_runner.dart';

/// §339 — бейдж результата Test servers (общий для папки §236 и подписки).
/// Извлечён из `_MemberRow._probeBadge` folder_detail_screen как есть:
/// цвет задержки — по порогам шкалы, статусы — включая `group` (§336).
/// Тап — на усмотрение экрана (обычно SnackBar с текстом ошибки).
class ProbeBadge extends StatelessWidget {
  const ProbeBadge({
    super.key,
    required this.result,
    required this.thresholds,
    this.onTap,
  });

  final ProbeResult result;
  final ProbeThresholds thresholds;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = result;
    final (String text, Color color) = switch (r.status) {
      ProbeStatus.pending => ('…', theme.colorScheme.onSurfaceVariant),
      ProbeStatus.ok => (
          '${r.delayMs} ms', // l10n-exempt: latency value + unit
          switch (thresholds.bandOf(r.delayMs)) {
            0 => Colors.green,
            1 => Colors.amber.shade800,
            2 => Colors.orange.shade800,
            _ => theme.colorScheme.error,
          }
        ),
      ProbeStatus.failed => (getLocalText.s("err"), theme.colorScheme.error),
      ProbeStatus.broken => (
          getLocalText.s("broken"),
          theme.colorScheme.error
        ),
      ProbeStatus.invalid => (
          getLocalText.s("invalid"),
          theme.colorScheme.error
        ),
      // §336 — группа не тестируется: нейтральный бейдж, не ошибка.
      ProbeStatus.group => (
          getLocalText.s("auto"),
          theme.colorScheme.onSurfaceVariant
        ),
    };
    return GestureDetector(
      onTap: onTap,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
