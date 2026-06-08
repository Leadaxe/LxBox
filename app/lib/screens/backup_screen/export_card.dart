import 'package:flutter/material.dart';

import '../../services/backup_service.dart';

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
                Text('Export', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Save your subscriptions, routing setup and preferences as a JSON file.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Server lists'),
              subtitle: const Text(
                'Subscriptions and custom servers',
                style: TextStyle(fontSize: 11),
              ),
              value: serverLists,
              onChanged: (v) =>
                  onChange(BackupCategory.serverLists, v ?? false),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Routing'),
              subtitle: const Text(
                'Custom rules, tun apps, DNS options, final outbound',
                style: TextStyle(fontSize: 11),
              ),
              value: routing,
              onChanged: (v) => onChange(BackupCategory.routing, v ?? false),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('App settings'),
              subtitle: const Text(
                'Preferences, ping options, auto-update, wifi history',
                style: TextStyle(fontSize: 11),
              ),
              value: appSettings,
              onChanged: (v) =>
                  onChange(BackupCategory.appSettings, v ?? false),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('VPN system toggles'),
              subtitle: const Text(
                'auto-start, keep on exit, background mode, allow bypass',
                style: TextStyle(fontSize: 11),
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
                'Debug API config',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              subtitle: const Text(
                'Includes the access token. Sensitive — leave OFF unless you know why.',
                style: TextStyle(fontSize: 11),
              ),
              value: debugConfig,
              onChanged: (v) =>
                  onChange(BackupCategory.debugConfig, v ?? false),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: busy ? null : onExport,
                icon: const Icon(Icons.share),
                label: const Text('Export...'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
