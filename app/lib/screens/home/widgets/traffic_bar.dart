import 'package:flutter/material.dart';

import '../../../controllers/home_controller.dart';
import '../../../controllers/subscription_controller.dart';
import '../../../models/home_state.dart';
import '../../../services/format_utils.dart';
import '../../../services/traffic_profiler.dart';
import '../../stats_screen.dart';
import '../../../services/l10n/locale_controller.dart';

/// Полоса трафика под статус-чипом на главном экране: ↑/↓ скорость, число
/// активных соединений, recording-индикаторы профайлера (§044) и uptime.
/// Тап открывает [StatsScreen] (на Per-app tab'е если идёт recording).
///
/// Перерисовывается на `TrafficProfiler.I` (recording-флаги) через внутренний
/// `AnimatedBuilder`; трафик/uptime приходят из переданного [state].
class TrafficBar extends StatelessWidget {
  const TrafficBar({
    super.key,
    required this.state,
    required this.controller,
    this.subController,
  });

  final HomeState state;
  final HomeController controller;

  // §262 — прокидывается в StatsScreen → Live-таб для навигационных кнопок
  // DNS-health листа. null → кнопки навигации не показываются.
  final SubscriptionController? subController;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final uptime = state.connectedSince != null
        ? formatDuration(
            DateTime.now().difference(state.connectedSince!),
            daysRollup: true,
          )
        : '';
    return GestureDetector(
      onTap: () {
        // §288 — вкладка Per-app удалена; всегда открываем Overview.
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StatsScreen(
              configRaw: controller.state.configRaw,
              initialTab: StatsTab.overview,
              subController: subController,
              homeController: controller,
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: AnimatedBuilder(
          animation: TrafficProfiler.I,
          builder: (_, _) {
            final profiler = TrafficProfiler.I;
            return Row(
              children: [
                _chip(
                  context,
                  Icons.arrow_upward,
                  state.traffic.uploadFormatted,
                  cs.primary,
                ),
                const SizedBox(width: 8),
                _chip(
                  context,
                  Icons.arrow_downward,
                  state.traffic.downloadFormatted,
                  cs.tertiary,
                ),
                if (state.traffic.activeConnections > 0) ...[
                  const SizedBox(width: 8),
                  // §194 — РАЗДЕЛЬНО: connectionsIn = соединения приложений
                  // (трафик-трекер ядра = то, что в списке на Stats);
                  // connectionsOut = физические соединения наружу к серверам
                  // (route-менеджер). Раньше показывали сумму «13», путавшую с
                  // числом активных в списке на Stats (≈connectionsIn).
                  _chip(
                    context,
                    Icons.link,
                    '${state.traffic.connectionsIn}',
                    cs.secondary,
                    tooltip: getLocalText.s("App connections"),
                  ),
                  const SizedBox(width: 8),
                  _chip(
                    context,
                    Icons.dns_outlined,
                    '${state.traffic.connectionsOut}',
                    cs.secondary,
                    tooltip: getLocalText.s("Outbound connections to servers"),
                  ),
                ],
                if (profiler.isRecording) ...[
                  const SizedBox(width: 8),
                  _chip(
                    context,
                    Icons.bolt,
                    _shortPkg(profiler.active!.targetPackage),
                    cs.error,
                  ),
                ],
                if (profiler.isGlobalRecording) ...[
                  const SizedBox(width: 8),
                  _chip(context, Icons.podcasts, 'Live', cs.error),
                ],
                const Spacer(),
                if (uptime.isNotEmpty)
                  Text(
                    uptime,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  static Widget _chip(
    BuildContext context,
    IconData icon,
    String label,
    Color color, {
    String? tooltip,
  }) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 2),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
    // §194 — длинное нажатие даёт tooltip (короткий тап ведёт на Stats через
    // GestureDetector полосы). triggerMode.longPress, чтобы не конфликтовать с
    // переходом по тапу.
    if (tooltip == null) return row;
    return Tooltip(
      message: tooltip,
      triggerMode: TooltipTriggerMode.longPress,
      child: row,
    );
  }

  /// `"ru.tinkoff.investing"` → `"ru.tinkoff"` (первые два сегмента пакета).
  static String _shortPkg(String pkg) {
    final parts = pkg.split('.');
    if (parts.length <= 2) return pkg;
    return '${parts[0]}.${parts[1]}';
  }

}
