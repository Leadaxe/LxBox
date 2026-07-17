import 'package:flutter/material.dart';

import '../../services/l10n/l10n.dart';

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
        title: Text(ctx.l.appSettingsQuitTitle),
        content: Text(ctx.l.appSettingsQuitBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(ctx.l.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ctx.l.appSettingsQuitConfirm),
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
        title: Text(ctx.l.appSettingsAppInfoHintTitle),
        content: SingleChildScrollView(
          child: Text(
            ctx.l.appSettingsAppInfoHintBody,
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l.appSettingsAppInfoHintOpen),
          ),
        ],
      ),
    );
  }
}
