import 'package:flutter/material.dart';

import '../../../services/l10n/locale_controller.dart';

/// §567 — почему SSID сейчас не читается; подсказка в секции рисуется
/// только для этих причин (всё в порядке / нет Wi-Fi / `unknown_ssid` —
/// подсказки нет).
enum WifiHint { preciseLocation, backgroundLocation, nearbyWifi, locationOff }

/// §567 — код ошибки `getCurrentWifiInfo` → подсказка. [missing] — полные
/// имена разрешений в порядке приоритета (первое определяет подсказку).
WifiHint? wifiHintFromError(String reason, List<String> missing) {
  switch (reason) {
    case 'location_disabled':
      return WifiHint.locationOff;
    case 'fine_location_missing':
      return WifiHint.preciseLocation;
    case 'permission_missing':
      final first = missing.isEmpty ? '' : missing.first;
      if (first.endsWith('NEARBY_WIFI_DEVICES')) return WifiHint.nearbyWifi;
      if (first.endsWith('ACCESS_FINE_LOCATION')) {
        return WifiHint.preciseLocation;
      }
      return WifiHint.backgroundLocation;
    default:
      return null;
  }
}

/// §567 / §757 — строка «почему SSID не читается» под условием Wi-Fi: тап
/// ведёт туда, где причина чинится (решает экран правила).
class WifiHintLine extends StatelessWidget {
  const WifiHintLine({super.key, required this.hint, required this.onTap});

  final WifiHint hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(Icons.info_outline,
                size: 14, color: t.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                switch (hint) {
                  WifiHint.preciseLocation =>
                    getLocalText.s("Precise location permission missing"),
                  WifiHint.backgroundLocation =>
                    getLocalText.s("Background location missing"),
                  WifiHint.nearbyWifi =>
                    getLocalText.s("Nearby Wi-Fi permission missing"),
                  WifiHint.locationOff =>
                    getLocalText.s("Location is turned off"),
                },
                style: TextStyle(
                  fontSize: 11,
                  color: t.colorScheme.onSurfaceVariant,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
