import 'package:flutter/material.dart';

import '../../../main.dart';
import 'update_status_row.dart';

/// General tab для App Settings.
///
/// Stateless — все значения и callback'и приходят от
/// `_AppSettingsScreenState`, который остаётся source-of-truth и делает
/// setState + side-effect внутри каждого callback'а. Поведение идентично
/// инлайн-версии (parent rebuild'ит этот widget на каждый setState).
class GeneralTab extends StatelessWidget {
  const GeneralTab({
    super.key,
    required this.loaded,
    required this.autoStart,
    required this.autoRebuild,
    required this.autoUpdateSubs,
    required this.autoCheckUpdates,
    required this.autoPing,
    required this.haptic,
    required this.padding,
    required this.onAutoStartChanged,
    required this.onAutoRebuildChanged,
    required this.onAutoUpdateSubsChanged,
    required this.onAutoCheckUpdatesChanged,
    required this.onAutoPingChanged,
    required this.onHapticChanged,
    required this.onAddQuickSettingsTile,
    required this.onOpenBackup,
  });

  final bool loaded;
  final bool autoStart;
  final bool autoRebuild;
  final bool autoUpdateSubs;
  final bool autoCheckUpdates;
  final bool autoPing;
  final bool haptic;
  final EdgeInsets padding;

  final ValueChanged<bool> onAutoStartChanged;
  final ValueChanged<bool> onAutoRebuildChanged;
  final ValueChanged<bool> onAutoUpdateSubsChanged;
  final ValueChanged<bool> onAutoCheckUpdatesChanged;
  final ValueChanged<bool> onAutoPingChanged;
  final ValueChanged<bool> onHapticChanged;
  final VoidCallback onAddQuickSettingsTile;
  final VoidCallback onOpenBackup;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: padding,
      children: [
        Text('Appearance', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        RadioGroup<ThemeMode>(
          groupValue: themeNotifier.mode,
          onChanged: (v) { if (v != null) themeNotifier.setMode(v); },
          child: Column(
            children: ThemeMode.values.map((mode) {
              final label = switch (mode) {
                ThemeMode.system => 'System',
                ThemeMode.light => 'Light',
                ThemeMode.dark => 'Dark',
              };
              final icon = switch (mode) {
                ThemeMode.system => Icons.brightness_auto,
                ThemeMode.light => Icons.light_mode,
                ThemeMode.dark => Icons.dark_mode,
              };
              return RadioListTile<ThemeMode>(
                value: mode,
                title: Text(label),
                secondary: Icon(icon),
              );
            }).toList(),
          ),
        ),
        const Divider(height: 32),
        Text('Behavior', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('Auto-start on boot'),
          subtitle: const Text('Start VPN when device turns on'),
          secondary: const Icon(Icons.power_settings_new),
          value: autoStart,
          onChanged: loaded ? onAutoStartChanged : null,
        ),
        SwitchListTile(
          title: const Text('Auto-rebuild config'),
          subtitle: const Text('Rebuild config automatically when settings change'),
          secondary: const Icon(Icons.build_circle_outlined),
          value: autoRebuild,
          onChanged: loaded ? onAutoRebuildChanged : null,
        ),
        const Divider(height: 32),
        Text('Quick connect', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.dashboard_customize_outlined),
          title: const Text('Quick Settings tile'),
          subtitle: const Text(
              'Add to status-bar shade for one-tap toggle. '
              'Android 13+ shows a system prompt; on older versions edit the shade manually.'),
          trailing: TextButton(
            onPressed: onAddQuickSettingsTile,
            child: const Text('Add'),
          ),
        ),
        const ListTile(
          leading: Icon(Icons.touch_app_outlined),
          title: Text('Home-screen shortcut'),
          subtitle: Text(
              'Long-press the L×Box icon on your home screen → choose "Toggle VPN".'),
        ),
        const Divider(height: 32),
        Text('Subscriptions', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('Auto-update subscriptions'),
          subtitle: const Text(
              'Refresh on app start, after VPN connects, and periodically. '
              'Manual ⟳ works regardless.'),
          secondary: const Icon(Icons.cloud_sync_outlined),
          value: autoUpdateSubs,
          onChanged: loaded ? onAutoUpdateSubsChanged : null,
        ),
        const Divider(height: 32),
        Text('Updates', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('Check for updates on launch'),
          subtitle: const Text(
              'Pings github.com once a day to check for new releases. '
              '"View" opens the release page in browser; install is manual.'),
          secondary: const Icon(Icons.system_update_alt),
          value: autoCheckUpdates,
          onChanged: loaded ? onAutoCheckUpdatesChanged : null,
        ),
        const UpdateStatusRow(),
        const Divider(height: 32),
        Text('Feedback', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('Auto-ping after connect'),
          subtitle: const Text(
              'Ping nodes of active group 5s after VPN starts (once per connect)'),
          secondary: const Icon(Icons.network_ping),
          value: autoPing,
          onChanged: loaded ? onAutoPingChanged : null,
        ),
        SwitchListTile(
          title: const Text('Haptic feedback'),
          subtitle: const Text('Vibrate on connect, disconnect and errors. Respects system "Touch feedback" setting'),
          secondary: const Icon(Icons.vibration),
          value: haptic,
          onChanged: loaded ? onHapticChanged : null,
        ),
        const Divider(height: 32),
        Text('Backup & restore', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.import_export),
          title: const Text('Backup & restore'),
          subtitle: const Text(
              'Export subscriptions, routing setup and preferences as JSON.'),
          trailing: const Icon(Icons.chevron_right),
          contentPadding: EdgeInsets.zero,
          onTap: onOpenBackup,
        ),
      ],
    );
  }
}
