import 'package:flutter/material.dart';

import '../services/url_launcher.dart' as ul;
import '../services/l10n/locale_controller.dart';

/// §051 — shared explainer dialog для Wi-Fi-related permissions.
///
/// Single source of truth для двух точек вызова:
/// - `BoxService` → `stopAndAlert("alert:permission_location:...")` →
///   HomeController парсит wire-строку в `StopPermissionLocation` (§279),
///   `HomeScreen._onControllerChange` зовёт этот dialog по typed-значению.
/// - `Settings → Background → System setup` row tap (Location / Nearby Wi-Fi):
///   когда permission denied, dialog объясняет зачем нужно + предлагает
///   runtime prompt для NEARBY_WIFI_DEVICES или Settings link для
///   ACCESS_BACKGROUND_LOCATION (single source of truth — на API 30+
///   только через Settings).
///
/// `missing` принимает список полных permission-имён
/// (`android.permission.NEARBY_WIFI_DEVICES`, `android.permission.ACCESS_BACKGROUND_LOCATION`,
/// и т.д.). Внутренне выбирает какие кнопки показывать:
/// - есть NEARBY_WIFI_DEVICES → button "Allow Wi-Fi info" (runtime prompt)
/// - есть BACKGROUND_LOCATION → button "Open Settings" обязательна
/// - оба → обе кнопки
class WifiPermissionDialog {
  WifiPermissionDialog._();

  /// Показать dialog. `missing` — список full permission names. Возвращает
  /// после dismissal (после tap'а на кнопку или barrier dismiss). Re-check
  /// permissions через `UrlLauncher.checkXxx()` — async system prompt
  /// resolve'ится до return'а на API 33+.
  static Future<void> show(
    BuildContext context, {
    required List<String> missing,
  }) async {
    final shortNames = missing
        .map((p) => p.replaceFirst('android.permission.', ''))
        .toList(growable: false);
    final needsNearby = missing.any((p) => p.endsWith('NEARBY_WIFI_DEVICES'));
    final needsBackgroundLocation =
        missing.any((p) => p.endsWith('ACCESS_BACKGROUND_LOCATION'));

    final body = StringBuffer()
      ..writeln(
          'Your sing-box config uses Wi-Fi-based rules (wifi_ssid / wifi_bssid). '
          'Reading the current Wi-Fi SSID requires:')
      ..writeln();
    for (final p in shortNames) {
      body.writeln(' • $p');
    }
    body.writeln();
    if (needsNearby && !needsBackgroundLocation) {
      body.writeln(
          'Tap "Allow Wi-Fi info" to grant via system prompt, then restart the VPN.');
    } else {
      body.writeln(
          'Background Location can only be granted in Settings → Permissions → '
          'Location → "Allow all the time". After granting, restart the VPN.');
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog.adaptive(
        title: Text(getLocalText.s("Wi-Fi rules need permissions")),
        content: SingleChildScrollView(child: Text(body.toString())),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(getLocalText.s("Cancel")),
          ),
          if (needsNearby)
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await ul.UrlLauncher.requestNearbyWifiPermission();
              },
              child: Text(getLocalText.s("Allow Wi-Fi info")),
            ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await ul.UrlLauncher.openAppSettings();
            },
            child: Text(getLocalText.s("Open Settings")),
          ),
        ],
      ),
    );
  }
}
