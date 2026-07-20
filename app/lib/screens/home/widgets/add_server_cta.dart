import 'package:flutter/material.dart';

import '../../../controllers/home_controller.dart';
import '../../../controllers/subscription_controller.dart';
import '../../../services/subscription/auto_updater.dart';
import '../../subscriptions_screen.dart';
import '../../../services/l10n/locale_controller.dart';

/// Гайд пустого состояния главного экрана (нет конфига/нод): заголовок, FAB
/// «Add a server» → [SubscriptionsScreen] и ссылка restore-from-backup
/// ([onRestoreFromBackup] живёт в `_HomeScreenState` — это async flow с
/// file-picker'ом и ScaffoldMessenger).
class AddServerCta extends StatelessWidget {
  const AddServerCta({
    super.key,
    required this.controller,
    required this.subController,
    required this.autoUpdater,
    required this.onRestoreFromBackup,
  });

  final HomeController controller;
  final SubscriptionController subController;
  final AutoUpdater autoUpdater;
  final VoidCallback onRestoreFromBackup;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined,
                size: 64, color: cs.onSurfaceVariant.withAlpha(140)),
            const SizedBox(height: 20),
            Text(
              getLocalText.s("Add a server"),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              getLocalText.s("Connect a subscription or add a node manually to get started."),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 28),
            Builder(
              builder: (innerCtx) => FloatingActionButton(
                heroTag: null,
                onPressed: () => Navigator.push(
                  innerCtx,
                  MaterialPageRoute(
                    builder: (_) => SubscriptionsScreen(
                      subController: subController,
                      homeController: controller,
                      autoUpdater: autoUpdater,
                    ),
                  ),
                ),
                tooltip: getLocalText.s("Add a server"),
                child: const Icon(Icons.add, size: 32),
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: onRestoreFromBackup,
              icon: const Icon(Icons.restore, size: 18),
              label: Text(getLocalText.s("Restore from backup")),
              style: TextButton.styleFrom(
                foregroundColor: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
