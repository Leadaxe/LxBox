import 'package:flutter/material.dart';

/// Confirm-диалоги для App Settings → Diagnostics.
///
/// Чистый UI: показывают `AlertDialog` и возвращают выбор юзера. Сами
/// side-effect'ы (quitApp / openAppDetailsSettings) делает screen после
/// получения результата — поведение идентично инлайну.
class AppSettingsDialogs {
  const AppSettingsDialogs._();

  /// §043 follow-up: confirm-диалог перед `BoxVpnClient.quitApp()`.
  /// Возвращает true если юзер подтвердил Quit.
  static Future<bool?> confirmQuitApp(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quit & reopen app?'),
        content: const Text(
          'This will fully close the app process so the new "Forward sing-box logs" '
          'value is picked up at next launch (Libbox.setup is one-shot per process). '
          'VPN service will stop. Tap the app icon to reopen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Quit'),
          ),
        ],
      ),
    );
  }

  /// Preset-инструкции перед переходом в system App info — OEM'ы прячут
  /// нужные тоглы в разных местах, юзер без подсказки теряется.
  /// Возвращает true если юзер тапнул «Open settings».
  static Future<bool?> openAppInfoHint(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Find these toggles'),
        content: const SingleChildScrollView(
          child: Text(
            'In the next screen (system App info) look for:\n\n'
            '• Autostart / Startup manager — allow\n'
            '• Background activity / Allow in background — allow\n'
            '• Battery / Power usage → "Don\'t optimize" or "No restrictions"\n'
            '• Battery saver exceptions — add L×Box\n\n'
            'Location of these toggles varies by OEM (Xiaomi/MIUI, Samsung/One UI, Oppo/ColorOS, Huawei, Google Pixel). Some are under Battery, others under App permissions.',
            style: TextStyle(fontSize: 13, height: 1.4),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
  }
}
