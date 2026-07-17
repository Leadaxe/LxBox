import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../../services/l10n/l10n.dart';
import '../../../services/l10n/locale_controller.dart';
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
    required this.autoCheckUpdates,
    required this.autoPing,
    required this.haptic,
    required this.allowRotation,
    required this.padding,
    required this.onAutoStartChanged,
    required this.onAutoCheckUpdatesChanged,
    required this.onAutoPingChanged,
    required this.onHapticChanged,
    required this.onAllowRotationChanged,
    required this.onAddQuickSettingsTile,
    required this.onOpenBackup,
  });

  final bool loaded;
  final bool autoStart;
  final bool autoCheckUpdates;
  final bool autoPing;
  final bool haptic;
  final bool allowRotation;
  final EdgeInsets padding;

  final ValueChanged<bool> onAutoStartChanged;
  final ValueChanged<bool> onAutoCheckUpdatesChanged;
  final ValueChanged<bool> onAutoPingChanged;
  final ValueChanged<bool> onHapticChanged;
  final ValueChanged<bool> onAllowRotationChanged;
  final VoidCallback onAddQuickSettingsTile;
  final VoidCallback onOpenBackup;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: padding,
      children: [
        Text(context.l.appSettingsGenAppearanceHeader,
            style: Theme.of(context).textTheme.titleMedium),
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
        const SizedBox(height: 8),
        // §279 — выбор языка приложения; смена применяется мгновенно через
        // LocaleController (полный пайплайн: ARB + template + rebuild).
        Text(context.l.settingsLanguageTitle,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        RadioGroup<String>(
          groupValue: LocaleController.I.setting,
          onChanged: (v) { if (v != null) LocaleController.I.set(v); },
          child: Column(
            children: [
              RadioListTile<String>(
                value: 'system',
                title: Text(context.l.settingsLanguageSystem),
                secondary: const Icon(Icons.language),
              ),
              // Эндонимы: каждая метка на своём языке, сознательно не из ARB
              // текущей локали.
              const RadioListTile<String>(
                value: 'en',
                title: Text('English'), // l10n-exempt: endonym
              ),
              const RadioListTile<String>(
                value: 'ru',
                title: Text('Русский'), // l10n-exempt: endonym
              ),
            ],
          ),
        ),
        const Divider(height: 32),
        Text(context.l.appSettingsGenBehaviorHeader,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(context.l.appSettingsGenAutoStartTitle),
          subtitle: Text(context.l.appSettingsGenAutoStartSubtitle),
          secondary: const Icon(Icons.power_settings_new),
          value: autoStart,
          onChanged: loaded ? onAutoStartChanged : null,
        ),
        // §220 — снятие портретной фиксации (планшетный фидбэк). Применяется
        // сразу, без рестарта; уважает системный auto-rotate.
        SwitchListTile(
          title: Text(context.l.appSettingsGenAllowRotationTitle),
          subtitle: Text(context.l.appSettingsGenAllowRotationSubtitle),
          secondary: const Icon(Icons.screen_rotation),
          value: allowRotation,
          onChanged: loaded ? onAllowRotationChanged : null,
        ),
        const Divider(height: 32),
        Text(context.l.appSettingsGenQuickConnectHeader,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.dashboard_customize_outlined),
          title: Text(context.l.appSettingsGenQsTileTitle),
          subtitle: Text(context.l.appSettingsGenQsTileSubtitle),
          trailing: TextButton(
            onPressed: onAddQuickSettingsTile,
            child: Text(context.l.commonAdd),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.touch_app_outlined),
          title: Text(context.l.appSettingsGenShortcutTitle),
          subtitle: Text(context.l.appSettingsGenShortcutSubtitle),
        ),
        const Divider(height: 32),
        Text(context.l.appSettingsGenUpdatesHeader,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(context.l.appSettingsGenCheckUpdatesTitle),
          subtitle: Text(context.l.appSettingsGenCheckUpdatesSubtitle),
          secondary: const Icon(Icons.system_update_alt),
          value: autoCheckUpdates,
          onChanged: loaded ? onAutoCheckUpdatesChanged : null,
        ),
        const UpdateStatusRow(),
        const Divider(height: 32),
        Text(context.l.appSettingsGenFeedbackHeader,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(context.l.appSettingsGenAutoPingTitle),
          subtitle: Text(context.l.appSettingsGenAutoPingSubtitle),
          secondary: const Icon(Icons.network_ping),
          value: autoPing,
          onChanged: loaded ? onAutoPingChanged : null,
        ),
        SwitchListTile(
          title: Text(context.l.appSettingsGenHapticTitle),
          subtitle: Text(context.l.appSettingsGenHapticSubtitle),
          secondary: const Icon(Icons.vibration),
          value: haptic,
          onChanged: loaded ? onHapticChanged : null,
        ),
        const Divider(height: 32),
        Text(context.l.appSettingsGenBackupHeader,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.import_export),
          title: Text(context.l.appSettingsGenBackupHeader),
          subtitle: Text(context.l.appSettingsGenBackupSubtitle),
          trailing: const Icon(Icons.chevron_right),
          contentPadding: EdgeInsets.zero,
          onTap: onOpenBackup,
        ),
      ],
    );
  }
}
