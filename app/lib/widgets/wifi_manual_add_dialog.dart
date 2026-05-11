import 'package:flutter/material.dart';

import '../screens/custom_rule_edit/validators.dart';
import 'wifi_entry.dart';

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
  String? errorText;
  return showDialog<WifiEntry>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlgState) => AlertDialog(
        title: const Text('Add Wi-Fi network'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: ssidCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'SSID',
                hintText: 'lexRouter',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: bssidCtrl,
              decoration: InputDecoration(
                labelText: 'BSSID (optional)',
                hintText: '38:2c:4a:cf:6d:5c',
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final ssid = ssidCtrl.text.trim();
              final bssid = bssidCtrl.text.trim().toLowerCase();
              if (ssid.isEmpty) {
                setDlgState(() => errorText = null);
                return;
              }
              if (bssid.isNotEmpty && !isValidBssid(bssid)) {
                setDlgState(
                    () => errorText = 'Expected xx:xx:xx:xx:xx:xx');
                return;
              }
              Navigator.of(ctx).pop(WifiEntry(ssid, bssid));
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
}
