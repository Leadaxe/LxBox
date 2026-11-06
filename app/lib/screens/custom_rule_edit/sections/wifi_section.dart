import 'package:flutter/material.dart';

import '../../../widgets/wifi_entry.dart';
import '../network_choice.dart';
import '../widgets/section_header.dart';
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

/// §053 Stage 2 — секция сети. §694: сверху тип сети
/// (Any / Wi-Fi / Cellular / Ethernet → `network_type`), под ним только при
/// Wi-Fi — chip-list SSID + 3 action buttons (Add current / Pick saved /
/// Manual) + permissions hint (§567: только при реальной проблеме с чтением
/// SSID); внизу «Metered networks only» → `network_is_expensive`.
///
/// Callbacks обрабатываются parent State'ом (он знает про
/// `WifiPermissionDialog`, `getCurrentWifiInfo`, `wifi_history`, etc.).
class WifiSection extends StatelessWidget {
  const WifiSection({
    super.key,
    required this.choice,
    required this.onChoiceChanged,
    required this.metered,
    required this.onMeteredChanged,
    required this.networks,
    required this.onRemoveAt,
    required this.onAddCurrent,
    required this.onPickSaved,
    required this.onManual,
    required this.onTapPermissionsHint,
    this.hint,
  });

  final NetworkChoice choice;
  final ValueChanged<NetworkChoice> onChoiceChanged;
  final bool metered;
  final ValueChanged<bool> onMeteredChanged;
  final List<WifiEntry> networks;
  final void Function(int index) onRemoveAt;
  final VoidCallback onAddCurrent;
  final VoidCallback onPickSaved;
  final VoidCallback onManual;
  final VoidCallback onTapPermissionsHint;

  /// §567 — null → подсказку не рисовать.
  final WifiHint? hint;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'NETWORK',
          hint: 'AND with match. Active only on the selected network type.',
        ),
        SegmentedButton<NetworkChoice>(
          segments: [
            ButtonSegment(
              value: NetworkChoice.any,
              label: Text(getLocalText.s("Any")),
            ),
            const ButtonSegment(
              value: NetworkChoice.wifi,
              label: Text('Wi-Fi'), // l10n-exempt: technology name
            ),
            ButtonSegment(
              value: NetworkChoice.cellular,
              label: Text(getLocalText.s("Cellular")),
            ),
            const ButtonSegment(
              value: NetworkChoice.ethernet,
              label: Text('Ethernet'), // l10n-exempt: technology name
            ),
          ],
          // `custom` (other / несколько типов из JSON) — ни один не выделен.
          selected: {if (choice != NetworkChoice.custom) choice},
          emptySelectionAllowed: true,
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
          ),
          onSelectionChanged: (sel) {
            if (sel.isNotEmpty) onChoiceChanged(sel.first);
          },
        ),
        if (choice == NetworkChoice.wifi) ..._wifiList(t),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: metered,
          onChanged: (v) => onMeteredChanged(v ?? false),
          title: Text(
            getLocalText.s("Metered networks only"),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            getLocalText.s("Mobile data and Wi-Fi marked as metered in Android settings"),
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }

  List<Widget> _wifiList(ThemeData t) => [
        const SizedBox(height: 8),
        if (networks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              getLocalText.s("No SSID filter — rule is active on any Wi-Fi network."),
              style: TextStyle(
                fontSize: 12,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (var i = 0; i < networks.length; i++)
                InputChip(
                  avatar: const Icon(Icons.wifi, size: 16),
                  label: Text(
                    networks[i].bssid.isEmpty
                        ? networks[i].ssid
                        : '${networks[i].ssid}  ·  ${networks[i].bssid}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onDeleted: () => onRemoveAt(i),
                ),
            ],
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            _smallButton(
                icon: Icons.my_location,
                label: 'Add current',
                onPressed: onAddCurrent),
            _smallButton(
                icon: Icons.history,
                label: 'Pick saved',
                onPressed: onPickSaved),
            _smallButton(
                icon: Icons.edit,
                label: 'Manual',
                onPressed: onManual),
          ],
        ),
        if (hint != null) ...[
          const SizedBox(height: 4),
          InkWell(
            onTap: onTapPermissionsHint,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 14, color: t.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      switch (hint!) {
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
          ),
        ],
      ];

  Widget _smallButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return OutlinedButton.icon(
      icon: Icon(icon, size: 16),
      label: Text(label),
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: const TextStyle(fontSize: 12),
      ),
    );
  }
}
