import 'package:flutter/material.dart';

import '../../../controllers/home_controller.dart';
import '../../../controllers/subscription_controller.dart';
import '../../../services/subscription/auto_updater.dart';
import '../../../services/l10n/l10n.dart';
import '../../about_screen.dart';
import '../../app_settings_screen.dart';
import '../../config_screen.dart';
import '../../debug_screen.dart';
import '../../dns_settings_screen.dart';
import '../../routing_screen.dart';
import '../../settings_screen.dart';
import '../../speed_test_screen.dart';
import '../../stats_screen.dart';
import '../../subscriptions_screen.dart';

/// Навигационное меню (Drawer) главного экрана: переход в разделы приложения.
/// Каждый пункт закрывает drawer и push'ит экран. «Statistics» доступен только
/// при поднятом туннеле (данные из CommandClient push-стримов, §122).
class HomeDrawer extends StatelessWidget {
  const HomeDrawer({
    super.key,
    required this.controller,
    required this.subController,
    required this.autoUpdater,
  });

  final HomeController controller;
  final SubscriptionController subController;
  final AutoUpdater autoUpdater;

  void _go(BuildContext context, Widget screen) {
    Navigator.of(context).pop();
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          children: [
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(context.l.homeDrawerServers),
              subtitle: Text(context.l.homeDrawerServersSub),
              onTap: () => _go(
                context,
                SubscriptionsScreen(
                  subController: subController,
                  homeController: controller,
                  autoUpdater: autoUpdater,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.alt_route_outlined),
              title: Text(context.l.homeDrawerRouting),
              subtitle: Text(context.l.homeDrawerRoutingSub),
              onTap: () => _go(
                context,
                RoutingScreen(
                  subController: subController,
                  homeController: controller,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(context.l.homeDrawerDns),
              subtitle: Text(context.l.homeDrawerDnsSub),
              onTap: () => _go(
                context,
                DnsSettingsScreen(
                  subController: subController,
                  homeController: controller,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.tune_outlined),
              title: Text(context.l.homeDrawerVpnSettings),
              subtitle: Text(context.l.homeDrawerVpnSettingsSub),
              onTap: () => _go(
                context,
                SettingsScreen(
                  subController: subController,
                  homeController: controller,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: Text(context.l.homeDrawerAppSettings),
              subtitle: Text(context.l.homeDrawerAppSettingsSub),
              onTap: () => _go(context, const AppSettingsScreen()),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.speed_outlined),
              title: Text(context.l.homeDrawerSpeedTest),
              subtitle: Text(context.l.homeDrawerSpeedTestSub),
              onTap: () =>
                  _go(context, SpeedTestScreen(homeController: controller)),
            ),
            ListTile(
              leading: const Icon(Icons.bar_chart_outlined),
              title: Text(context.l.homeDrawerStats),
              subtitle: Text(context.l.homeDrawerStatsSub),
              enabled: controller.state.tunnelUp,
              onTap: () => _go(
                context,
                StatsScreen(
                  configRaw: controller.state.configRaw,
                  subController: subController,
                  homeController: controller,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(context.l.homeDrawerConfigEditor),
              subtitle: Text(context.l.homeDrawerConfigEditorSub),
              onTap: () => _go(context, ConfigScreen(controller: controller)),
            ),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: Text(context.l.homeDrawerDebug),
              subtitle: Text(context.l.homeDrawerDebugSub),
              onTap: () => _go(context, const DebugScreen()),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(context.l.homeDrawerAbout),
              onTap: () => _go(context, const AboutScreen()),
            ),
          ],
        ),
      ),
    );
  }
}
