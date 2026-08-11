import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/home_controller.dart';
import '../../models/home_state.dart';
import '../../services/install_source.dart';
import '../../services/settings_storage.dart';
import '../../services/update_checker.dart';
import '../../services/url_launcher.dart' as ul;
import '../../services/version_info.dart';
import '../../vpn/box_vpn_client.dart';
import '../../widgets/wifi_permission_dialog.dart';
import '../../services/l10n/locale_controller.dart';

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
        title: Text(getLocalText.s("Stop VPN?")),
        content: Text(
          getLocalText.plural("%d active connections will be closed.", state.traffic.activeConnections),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(getLocalText.s("Stop")),
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
      title: Text(getLocalText.s("Another VPN is active")),
      content: Text(getLocalText.s("Another VPN app is currently running. Switch to L×Box?\n\nTo see which app it is, open VPN settings — the active VPN is marked as connected.")),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(getLocalText.s("Cancel")),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(ctx).pop(false);
            unawaited(BoxVpnClient.I.openVpnSettings());
          },
          child: Text(getLocalText.s("VPN settings")),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(getLocalText.s("Switch")),
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

/// §036 + §390 — SnackBar «новая версия доступна».
///
/// Показывается **только на старте** приложения, из кеша (`hydrate`), не чаще
/// одного раза за запуск. Сетевой чек снек не поднимает: его результат ляжет в
/// `last_known_version` и всплывёт на СЛЕДУЮЩЕМ запуске. Так уведомление
/// никогда не выскакивает поверх работающего приложения.
///
/// Три способа увести снек:
///
/// | Действие | Персист | Вернётся |
/// |---|---|---|
/// | клик по телу | нет | при следующем запуске (+ переход в стор) |
/// | «Later» | нет | при следующем запуске |
/// | «Ignore» | `dismissed_update_version` | только для следующей версии |
///
/// «Later» персиста не требует: показ и так один за запуск — за это отвечает
/// `_updateSnackbarShown` в `State`.
///
/// Куда ведёт переход, решает канал установки (§390): APK с GitHub не встанет
/// поверх Play-сборки, подписи разные.
///
/// Возвращает рано, если юзер нажал «Ignore» для этой версии. [onShown]
/// вызывается ровно когда SnackBar реально показывается (State использует это
/// чтобы выставить `_updateSnackbarShown`).
Future<void> maybeShowUpdateSnackbar(
  BuildContext context,
  UpdateInfo info, {
  required VoidCallback onShown,
}) async {
  final dismissed = await SettingsStorage.getDismissedUpdateVersion();
  if (dismissed == info.tag) return;
  if (!context.mounted) return;
  onShown();
  final source = InstallSourceResolver.current;
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 6),
      behavior: SnackBarBehavior.floating,
      content: _UpdateSnackContent(
        info: info,
        // Тап по телу = «Later» + переход в свой стор. Персиста нет
        // сознательно: юзер пошёл обновляться, но мог и передумать —
        // напомним при следующем запуске.
        onTapBody: () {
          messenger.hideCurrentSnackBar();
          unawaited(ul.UrlLauncher.open(
            source.updateUrl(info.tag),
            fallbackUrl: source.updateUrlFallback,
          ));
        },
        onLater: () => messenger.hideCurrentSnackBar(),
        // §090 G1 — «Ignore» persist'ит dismissed-версию → этот релиз больше
        // не всплывёт (read-guard выше + в UpdateChecker.hydrate/maybeCheck);
        // следующий (бОльший tag) всё равно покажется через isNewer.
        onIgnore: () {
          messenger.hideCurrentSnackBar();
          unawaited(UpdateChecker.I.dismissCurrent());
        },
      ),
    ),
  );
}

/// Тело update-снека: кликабельный текст + две кнопки.
///
/// Раскладка адаптивная — на узких экранах (360dp и меньше) текст и две кнопки
/// в один ряд не помещаются, кнопки уезжают под текст. Порог 320dp подобран по
/// ширине пары кнопок с локализованными подписями.
class _UpdateSnackContent extends StatelessWidget {
  const _UpdateSnackContent({
    required this.info,
    required this.onTapBody,
    required this.onLater,
    required this.onIgnore,
  });

  final UpdateInfo info;
  final VoidCallback onTapBody;
  final VoidCallback onLater;
  final VoidCallback onIgnore;

  @override
  Widget build(BuildContext context) {
    // Кнопки идут ПОСЛЕ тела в дереве — тап по ним не утекает в onTapBody.
    final buttons = [
      TextButton(onPressed: onLater, child: Text(getLocalText.s("Later"))),
      TextButton(onPressed: onIgnore, child: Text(getLocalText.s("Ignore"))),
    ];
    // InkWell, а не GestureDetector: SnackBar рендерит content внутри
    // собственного Material, и жест из GestureDetector проигрывает
    // конкуренцию его ink-слою (тап уходит в _RenderInkFeatures). InkWell
    // встраивается в тот же слой + даёт визуальный отклик на тап.
    final text = InkWell(
      onTap: onTapBody,
      child: SizedBox(
        // Явная ширина: Text занимает место по контенту, и без этого
        // кликабельна была бы только строка глифов, а не вся область.
        width: double.infinity,
        child: Text(
          getLocalText.s("L×Box %1\$s available (you have v%2\$s)", info.tag,
              VersionInfo.I.version),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 320) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              text,
              Row(mainAxisAlignment: MainAxisAlignment.end, children: buttons),
            ],
          );
        }
        return Row(children: [Expanded(child: text), ...buttons]);
      },
    );
  }
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
      title: Text(getLocalText.s("Allow notifications")),
      content: Text(getLocalText.s("L×Box runs as a foreground service while VPN is active. A persistent notification is required by Android — it lets you see at a glance that VPN is on, and prevents the system from killing the tunnel in the background.\n\nNo promotional or alert notifications will be sent.")),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(getLocalText.s("Skip")),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(getLocalText.s("Allow")),
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
      title: Text(getLocalText.s("Allow background activity")),
      content: Text(getLocalText.s("Android restricts background activity to save battery. Without an exception, the VPN tunnel may be killed when the screen turns off — your connection drops until you reopen L×Box.\n\nOpen system settings and choose \"Unrestricted\" / \"Not optimized\".")),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(getLocalText.s("Later")),
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
          child: Text(getLocalText.s("Allow")),
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
      title: Text(getLocalText.s("Disable battery restrictions")),
      content: Text(getLocalText.s("To keep the VPN running in background, also disable battery restrictions for L×Box. The settings screen will open — find and toggle:\n\n• \"Battery usage\" → \"Don't optimize\" or \"Allow background activity\"\n\n• On OnePlus / OPPO / Realme also:\n  \"Stop activity when idle\" → OFF")),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(getLocalText.s("Close")),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.of(ctx).pop();
            await vpn.openAppDetailsSettings();
          },
          child: Text(getLocalText.s("Open Settings")),
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

// §357 — показ support-сообщения переехал в полноэкранный
// `screens/home/support_message_screen.dart` (SupportMessageScreen);
// прежний AlertDialog-вариант удалён.
