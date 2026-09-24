import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../../services/l10n/locale_controller.dart';

/// §541 — Appearance tab для App Settings: всё про внешний вид (тема,
/// компоновка — поворот и две колонки списка узлов, язык).
///
/// Stateless, как [GeneralTab]: значения и callback'и приходят от
/// `_AppSettingsScreenState`; тема и язык читаются из своих контроллеров
/// напрямую (экран слушает их через AnimatedBuilder).
class AppearanceTab extends StatelessWidget {
  const AppearanceTab({
    super.key,
    required this.loaded,
    required this.allowRotation,
    required this.nodeListTwoColumns,
    required this.padding,
    required this.onAllowRotationChanged,
    required this.onNodeListTwoColumnsChanged,
  });

  final bool loaded;
  final bool allowRotation;

  /// §541 — две колонки списка узлов на широком окне (§537).
  final bool nodeListTwoColumns;
  final EdgeInsets padding;

  final ValueChanged<bool> onAllowRotationChanged;
  final ValueChanged<bool> onNodeListTwoColumnsChanged;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: padding,
      children: [
        Text(getLocalText.s("Appearance"),
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
        // §541 — компоновка: поворот и две колонки списка узлов в одном месте.
        Text(getLocalText.s("Layout"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        // §220 — снятие портретной фиксации (планшетный фидбэк). Применяется
        // сразу, без рестарта; уважает системный auto-rotate.
        SwitchListTile(
          title: Text(getLocalText.s("Allow rotation")),
          subtitle: Text(getLocalText.s("Rotate to landscape when the device turns — handy on tablets. Follows the system auto-rotate setting.")),
          secondary: const Icon(Icons.screen_rotation),
          value: allowRotation,
          onChanged: loaded ? onAllowRotationChanged : null,
        ),
        // §541 — гейт двухколоночной раскладки §537; применяется сразу через
        // SettingsStorage.nodeListTwoColumns.
        SwitchListTile(
          title: Text(getLocalText.s("Two columns on wide screens")),
          subtitle: Text(getLocalText.s("Show the node list in two columns when the window is at least 600 dp wide (tablets, landscape, split-screen).")),
          secondary: const Icon(Icons.view_column_outlined),
          value: nodeListTwoColumns,
          onChanged: loaded ? onNodeListTwoColumnsChanged : null,
        ),
        const SizedBox(height: 8),
        // §279 — выбор языка приложения; смена применяется мгновенно через
        // LocaleController (полный пайплайн: ARB + template + rebuild).
        Text(getLocalText.s("Language"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        RadioGroup<String>(
          groupValue: LocaleController.I.setting,
          onChanged: (v) { if (v != null) LocaleController.I.set(v); },
          child: Column(
            children: [
              RadioListTile<String>(
                value: 'system',
                title: Text(getLocalText.s("System default")),
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
              const RadioListTile<String>(
                value: 'zh',
                title: Text('中文（简体）'), // l10n-exempt: endonym
              ),
            ],
          ),
        ),
      ],
    );
  }
}
