import 'package:flutter/material.dart';

import '../screens/custom_rule_edit/validators.dart';
import 'wifi_entry.dart';
import '../services/l10n/locale_controller.dart';

/// §053 Stage 1 — extract «Manual add Wi-Fi» dialog из
/// `custom_rule_edit_screen.dart`. Self-contained, возвращает либо
/// валидный `WifiEntry`, либо `null` если юзер cancel'нул.
///
/// Не пишет в storage и не дедуп'ит — это caller responsibility
/// (editor добавляет в `_wifiNetworks` + `SettingsStorage.addToWifiHistory`).
///
/// Validation: SSID non-empty, BSSID empty или матчит `xx:xx:xx:xx:xx:xx`.
/// BSSID lower-cased на возврате.
Future<WifiEntry?> showWifiManualAddDialog(BuildContext context) async {
  final ssidCtrl = TextEditingController();
  final bssidCtrl = TextEditingController();
  String? ssidError; // §219 — отдельная ошибка для SSID (раньше пустой SSID
  String? errorText; // молча ничего не делал: errorText был только у BSSID).
  return showDialog<WifiEntry>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlgState) => AlertDialog(
        title: Text(getLocalText.s("Add Wi-Fi network")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: ssidCtrl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: getLocalText.s("SSID"),
                // l10n-exempt: пример SSID, не переводится
                hintText: 'lexRouter',
                errorText: ssidError,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: bssidCtrl,
              decoration: InputDecoration(
                labelText: getLocalText.s("BSSID (optional)"),
                // l10n-exempt: пример MAC-адреса, не переводится
                hintText: '38:2c:4a:cf:6d:5c',
                // l10n-exempt: маска формата, одинакова во всех локалях
                helperText: 'xx:xx:xx:xx:xx:xx',
                errorText: errorText,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () {
              final ssid = ssidCtrl.text.trim();
              final bssid = bssidCtrl.text.trim().toLowerCase();
              if (ssid.isEmpty) {
                setDlgState(() => ssidError = 'SSID required');
                return;
              }
              if (bssid.isNotEmpty && !isValidBssid(bssid)) {
                setDlgState(() {
                  ssidError = null;
                  errorText = 'Expected xx:xx:xx:xx:xx:xx';
                });
                return;
              }
              Navigator.of(ctx).pop(WifiEntry(ssid, bssid));
            },
            child: Text(getLocalText.s("Add")),
          ),
        ],
      ),
    ),
  );
}
