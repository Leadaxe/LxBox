import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/home_controller.dart';
import '../../models/home_state.dart';
import '../../services/settings_storage.dart';
import '../../services/support/support_message.dart';
import '../../services/update_checker.dart';
import '../../services/url_launcher.dart' as ul;
import '../../services/version_info.dart';
import '../../vpn/box_vpn_client.dart';
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

/// Диалог «активен другой VPN» — показывается перед ручным стартом, если на
/// устройстве уже работает VPN другого приложения. Старт нашего туннеля молча
/// отзовёт чужой (onRevoke), поэтому спрашиваем подтверждение. Возвращает `true`
/// при выборе Switch, `null`/`false` при отмене.
Future<bool?> showForeignVpnDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog.adaptive(
      title: const Text('Another VPN is active'),
      content: const Text(
        'Another VPN app is currently running. Switch to L×Box?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Switch'),
        ),
      ],
    ),
  );
}

/// SnackBar при foreign-revoke — системный VPN-слот перехватило другое активное
/// VPN-приложение (§012, §224). Частая причина — always-on / kill-switch у
/// второго VPN, который пере-захватывает единственный слот в окне reconnect.
/// Текст самодостаточный: юзер не должен думать, что это «своё же прошлое
/// подключение». Имя перехватчика Android через публичный API не отдаёт.
/// Action «Start» перезапускает через [controller].
void showRevokedSnackBar(BuildContext context, HomeController controller) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: const Text(
          'Another VPN app took over the connection. Tap Start to reconnect.',
        ),
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

/// §036 — SnackBar «новая версия доступна». Возвращает рано если юзер уже
/// dismiss'нул эту версию. [onShown] вызывается ровно когда SnackBar реально
/// показывается (State использует это чтобы выставить `_updateSnackbarShown`).
Future<void> maybeShowUpdateSnackbar(
  BuildContext context,
  UpdateInfo info, {
  required VoidCallback onShown,
}) async {
  final dismissed = await SettingsStorage.getDismissedUpdateVersion();
  if (dismissed == info.tag) return;
  if (!context.mounted) return;
  onShown();
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 12),
      content: Row(
        children: [
          Expanded(
            child: Text(
              'L×Box ${info.tag} available '
              '(you have v${VersionInfo.I.version})',
            ),
          ),
          // §090 G1 — «Later» persist'ит dismissed-версию → этот релиз больше
          // не всплывёт (read-guard выше + в UpdateChecker.hydrate/maybeCheck);
          // следующий (бОльший tag) всё равно покажется через isNewer.
          TextButton(
            onPressed: () {
              messenger.hideCurrentSnackBar();
              unawaited(UpdateChecker.I.dismissCurrent());
            },
            child: const Text('Later'),
          ),
        ],
      ),
      action: SnackBarAction(
        label: 'View',
        onPressed: () async {
          await ul.UrlLauncher.open(info.htmlUrl);
        },
      ),
    ),
  );
}

/// On Android 13+ (API 33+) `POST_NOTIFICATIONS` is a runtime permission.
/// Without it, the foreground-service notification used by VPN may not
/// be shown — the user has no visual indicator that VPN is active.
/// We show an explainer once on first launch (or after revocation),
/// then trigger the system permission dialog.
const _notifPromptKey = 'notif_perm_prompted_v1';

Future<void> maybeShowNotificationPermissionDialog(BuildContext context) async {
  final granted = await ul.UrlLauncher.checkNotificationPermission();
  if (granted) return;
  final asked = await SettingsStorage.getVar(_notifPromptKey, '0');
  if (asked == '1') return;
  await SettingsStorage.setVar(_notifPromptKey, '1');
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog.adaptive(
      title: const Text('Allow notifications'),
      content: const Text(
        'L×Box runs as a foreground service while VPN is active. '
        'A persistent notification is required by Android — it lets you '
        'see at a glance that VPN is on, and prevents the system from '
        'killing the tunnel in the background.\n\n'
        'No promotional or alert notifications will be sent.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Skip'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Allow'),
        ),
      ],
    ),
  );
  if (ok == true) {
    await ul.UrlLauncher.requestNotificationPermission();
  }
}

/// Показывает диалог-попап при старте, если приложение не в battery
/// optimization whitelist'е. Без whitelist'а Android агрессивно throttle'ит
/// foreground service + tunnel засыпает в Doze → интернет «отваливается»
/// до следующего открытия приложения.
///
/// First-run-only: показываем один раз (persist-флаг). Повторно зайти можно
/// через кнопку в App Settings. [skipPersist]=true — для прямого вызова из
/// App Settings, где persist не нужен (всегда показываем по тапу).
const _batteryPromptKey = 'wizard_battery_v1';

Future<void> maybeShowBatteryOptimizationDialog(
  BuildContext context,
  BoxVpnClient vpn, {
  bool skipPersist = false,
}) async {
  final ok = await vpn.isIgnoringBatteryOptimizations();
  if (ok) return;
  if (!skipPersist) {
    final asked = await SettingsStorage.getVar(_batteryPromptKey, '0');
    if (asked == '1') return;
    await SettingsStorage.setVar(_batteryPromptKey, '1');
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog.adaptive(
      title: const Text('Allow background activity'),
      content: const Text(
        'Android restricts background activity to save battery. '
        'Without an exception, the VPN tunnel may be killed when the '
        'screen turns off — your connection drops until you reopen L×Box.\n\n'
        'Open system settings and choose "Unrestricted" / "Not optimized".',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.of(ctx).pop();
            await vpn.openBatteryOptimizationSettings();
            // OEM (ColorOS/MIUI/MagicOS) имеет proprietary battery toggles
            // поверх AOSP — наш REQUEST_IGNORE_BATTERY_OPTIMIZATIONS их не
            // контролирует. Followup показывается всегда (независимо от
            // того что юзер выбрал в AOSP dialog) — OEM toggles важнее
            // на проблемных device'ах.
            // `context` (screen) — а не `ctx` (popped dialog route): после
            // `pop()` dialog-context deactivated; screen-context = аналог
            // State.mounted в оригинале.
            if (context.mounted) await showOemBatteryFollowupDialog(context, vpn);
          },
          child: const Text('Allow'),
        ),
      ],
    ),
  );
}

/// Standard AOSP REQUEST_IGNORE_BATTERY_OPTIMIZATIONS добавляет app в
/// AOSP whitelist, но на OEM (ColorOS/OxygenOS на OnePlus/OPPO/Realme,
/// MIUI на Xiaomi, MagicOS на Honor) есть **отдельные** proprietary
/// toggle'ы поверх AOSP («Background activity», «Stop when idle»),
/// которые AOSP intent НЕ контролирует. Open App Info чтобы юзер
/// тапнул их вручную.
Future<void> showOemBatteryFollowupDialog(
  BuildContext context,
  BoxVpnClient vpn,
) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog.adaptive(
      title: const Text('Disable battery restrictions'),
      content: const Text(
        'To keep the VPN running in background, also disable battery '
        'restrictions for L×Box. The settings screen will open — find '
        'and toggle:\n\n'
        '• "Battery usage" → "Don\'t optimize" or "Allow background '
        'activity"\n\n'
        '• On OnePlus / OPPO / Realme also:\n'
        '  "Stop activity when idle" → OFF',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.of(ctx).pop();
            await vpn.openAppDetailsSettings();
          },
          child: const Text('Open Settings'),
        ),
      ],
    ),
  );
}

/// First-run промпт «добавить плитку в быстрые настройки». На Android 13+
/// система сама показывает диалог (`requestAddTileService`). На более старых
/// версиях системного промпта нет — шаг помечается показанным и пропускается
/// молча (кнопка «Add tile» в App Settings остаётся для ручного добавления).
/// Один раз (persist-флаг).
const _addTilePromptKey = 'wizard_addtile_v1';

Future<void> maybeShowAddTilePrompt(BuildContext context, BoxVpnClient vpn) async {
  final asked = await SettingsStorage.getVar(_addTilePromptKey, '0');
  if (asked == '1') return;
  await SettingsStorage.setVar(_addTilePromptKey, '1');
  // requestAddTile сам зовёт системный промпт (API 33+) или возвращает
  // 'unsupported' на старых — там тихо выходим, инструкцию не навязываем.
  await vpn.requestAddTile();
}

/// §105 — диалог «поддержи автора». Чистый показ готового [m]; решение о
/// показе (пороги, сессия, fetch) — на стороне `home_screen` (см.
/// `_maybeShowSupport`). Кнопки-ссылки диалог НЕ закрывают (юзер может
/// пройтись по нескольким); закрытие — «Позже» (повтор через +N часов
/// активного времени) или «Не показывать» (навсегда для кампании).
Future<void> showSupportDialog(BuildContext context, SupportMessage m) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog.adaptive(
      title: Text(m.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(m.message),
            const SizedBox(height: 16),
            for (final (label, url) in m.links) ...[
              FilledButton.tonal(
                onPressed: () => ul.UrlLauncher.open(url),
                child: Text(label),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            Navigator.of(ctx).pop();
            await SupportMessageService.I.dismissForever(m);
          },
          child: const Text("Don't show again"),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.of(ctx).pop();
            await SupportMessageService.I.snooze(m);
          },
          child: const Text('Later'),
        ),
      ],
    ),
  );
}
