import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/home_controller.dart';
import '../../models/home_state.dart';
import '../../services/settings_storage.dart';
import '../../services/l10n/l10n.dart';
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
        title: Text(ctx.l.homeStopVpnTitle),
        content: Text(
          ctx.l.homeStopVpnBody(state.traffic.activeConnections),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l.homeStopVpnStop),
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
/// §241 — кнопка «VPN settings» открывает системный экран Settings → VPN, где
/// активный VPN помечен «Connected»: имя перехватчика Android приложению не
/// отдаёт (ownerUid чужой сети скрыт), а там юзер видит его сам. Старт при
/// этом не выполняется — юзер ушёл разбираться, чей туннель активен.
Future<bool?> showForeignVpnDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog.adaptive(
      title: Text(ctx.l.homeForeignVpnTitle),
      content: Text(ctx.l.homeForeignVpnBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(ctx.l.commonCancel),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(ctx).pop(false);
            unawaited(BoxVpnClient.I.openVpnSettings());
          },
          child: Text(ctx.l.homeForeignVpnOpenSettings),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(ctx.l.homeForeignVpnSwitch),
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
              context.l.homeUpdateAvailable(info.tag, VersionInfo.I.version),
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
            child: Text(context.l.commonLater),
          ),
        ],
      ),
      action: SnackBarAction(
        label: context.l.homeUpdateView,
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
      title: Text(ctx.l.homeNotifPermTitle),
      content: Text(ctx.l.homeNotifPermBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(ctx.l.homeNotifPermSkip),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(ctx.l.commonAllow),
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
      title: Text(ctx.l.homeBatteryTitle),
      content: Text(ctx.l.homeBatteryBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(ctx.l.commonLater),
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
          child: Text(ctx.l.commonAllow),
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
      title: Text(ctx.l.homeOemBatteryTitle),
      content: Text(ctx.l.homeOemBatteryBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(ctx.l.commonClose),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.of(ctx).pop();
            await vpn.openAppDetailsSettings();
          },
          child: Text(ctx.l.commonOpenSettings),
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
          child: Text(ctx.l.homeSupportDontShowAgain),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.of(ctx).pop();
            await SupportMessageService.I.snooze(m);
          },
          child: Text(ctx.l.commonLater),
        ),
      ],
    ),
  );
}
