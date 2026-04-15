import 'package:flutter/material.dart';

import '../main.dart';

class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: themeNotifier,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('App Settings')),
          body: ListView(
            padding: const EdgeInsets.all(12),
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
            ],
          ),
        );
      },
    );
  }
}
