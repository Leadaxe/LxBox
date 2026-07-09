// §262 — warning banner для деградации DNS в Live system-wide tab.
//
// Показывается, когда детектор здоровья DNS в профайлере считает вердикт
// [TrafficProfiler.I.dnsHealthUnhealthy] истинным: массовые fail-резолвы при
// живой связи (fail-доля ≥20% + ≥3 fail + есть conn-активность за окно 30с).
// «DNS дохнет, а туннель жив → проблема в DNS».
//
// По образцу [UnattributedBanner], но кликабельный: тап открывает лист-подсказку
// с переходами в DNS settings / каталог пресетов (FakeIP). Контроллеры нужны
// для навигационных кнопок листа — прокидываются из [LiveEventsTab].

import 'package:flutter/material.dart';

import '../../controllers/home_controller.dart';
import '../../controllers/subscription_controller.dart';
import '../../services/traffic_profiler.dart';
import 'dns_health_sheet.dart';

class DnsHealthBanner extends StatelessWidget {
  const DnsHealthBanner({super.key, this.subController, this.homeController});

  final SubscriptionController? subController;
  final HomeController? homeController;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.errorContainer,
      child: InkWell(
        onTap: () => showDnsHealthSheet(
          context,
          subController: subController,
          homeController: homeController,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.dns_outlined, size: 16, color: cs.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${TrafficProfiler.I.dnsHealthFailPercent}% of DNS queries '
                  'failing while the connection is alive — tap to fix',
                  style: TextStyle(fontSize: 12, color: cs.onErrorContainer),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: cs.onErrorContainer),
            ],
          ),
        ),
      ),
    );
  }
}
