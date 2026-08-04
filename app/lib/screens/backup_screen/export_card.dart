import 'package:flutter/material.dart';

import '../../services/backup_service.dart';
import '../../services/l10n/locale_controller.dart';

class ExportCard extends StatelessWidget {
  const ExportCard({
    super.key,
    required this.serverLists,
    required this.routing,
    required this.appSettings,
    required this.vpnSettings,
    required this.debugConfig,
    required this.busy,
    required this.onChange,
    required this.onExport,
  });

  final bool serverLists;
  final bool routing;
  final bool appSettings;
  final bool vpnSettings;
  final bool debugConfig;
  final bool busy;
  final void Function(BackupCategory cat, bool on) onChange;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.upload_outlined),
                const SizedBox(width: 8),
                Text(getLocalText.s("Export"), style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              getLocalText.s("Save your subscriptions, routing setup and preferences as a JSON file."),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(getLocalText.s("Server lists")),
              subtitle: Text(
                getLocalText.s("Subscriptions and custom servers"),
                style: const TextStyle(fontSize: 11),
              ),
              value: serverLists,
              onChanged: (v) =>
                  onChange(BackupCategory.serverLists, v ?? false),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(getLocalText.s("Routing")),
              subtitle: Text(
                getLocalText.s("Custom rules, tun apps, DNS options, final outbound"),
                style: const TextStyle(fontSize: 11),
              ),
              value: routing,
              onChanged: (v) => onChange(BackupCategory.routing, v ?? false),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(getLocalText.s("App settings")),
              subtitle: Text(
                getLocalText.s("Preferences, ping options, auto-update, wifi history"),
                style: const TextStyle(fontSize: 11),
              ),
              value: appSettings,
              onChanged: (v) =>
                  onChange(BackupCategory.appSettings, v ?? false),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(getLocalText.s("VPN system toggles")),
              subtitle: Text(
                getLocalText.s("auto-start, keep on exit, background mode, allow bypass"),
                style: const TextStyle(fontSize: 11),
              ),
              value: vpnSettings,
              onChanged: (v) =>
                  onChange(BackupCategory.vpnSettings, v ?? false),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                getLocalText.s("Debug API config"),
                style: TextStyle(color: theme.colorScheme.error),
              ),
              subtitle: Text(
                getLocalText.s("Includes the access token. Sensitive — leave OFF unless you know why."),
                style: const TextStyle(fontSize: 11),
              ),
              value: debugConfig,
              onChanged: (v) =>
                  onChange(BackupCategory.debugConfig, v ?? false),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: busy ? null : onExport,
                icon: const Icon(Icons.save_alt),
                label: Text(getLocalText.s("Export...")),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
