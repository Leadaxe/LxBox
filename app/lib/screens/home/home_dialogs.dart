import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/home_controller.dart';
import '../../models/home_state.dart';
import '../../widgets/wifi_permission_dialog.dart';

/// Подтверждение остановки VPN: если активных соединений > 3 — показываем
/// диалог (их закрытие оборвёт сессии), иначе останавливаем сразу через
/// [controller].
void confirmStop(
  BuildContext context,
  HomeController controller,
  HomeState state,
) {
  if (state.traffic.activeConnections > 3) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop VPN?'),
        content: Text(
          '${state.traffic.activeConnections} active connections will be closed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Stop'),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true) controller.stop();
    });
  } else {
    controller.stop();
  }
}

/// SnackBar «VPN taken by another app» — туннель отозван другим VPN-приложением
/// (§012). Action «Start» перезапускает через [controller].
void showRevokedSnackBar(BuildContext context, HomeController controller) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: const Text('VPN taken by another app'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Start',
          onPressed: () => unawaited(controller.start()),
        ),
      ),
    );
}

/// Диалог-объяснение про location/wifi permission (§050): config содержит
/// `wifi_ssid`/`wifi_bssid` правила → нужен доступ к Wi-Fi state. [permName] —
/// comma-separated список permission'ов из BoxService alert prefix.
Future<void> showLocationPermissionDialog(
  BuildContext context,
  String permName,
) async {
  if (!context.mounted) return;
  final missing = permName.split(',').map((p) => p.trim()).toList();
  await WifiPermissionDialog.show(context, missing: missing);
}
