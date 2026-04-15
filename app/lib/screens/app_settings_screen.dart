import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../vpn/box_vpn_client.dart';

class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({super.key});

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  final _vpn = BoxVpnClient();
  bool _autoStart = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAutoStart());
  }

  Future<void> _loadAutoStart() async {
    final val = await _vpn.getAutoStart();
    if (mounted) setState(() { _autoStart = val; _loaded = true; });
  }

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
              const Divider(height: 32),
              Text('Startup', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('Auto-start on boot'),
                subtitle: const Text('Start VPN when device turns on'),
                secondary: const Icon(Icons.power_settings_new),
                value: _autoStart,
                onChanged: _loaded ? (val) {
                  setState(() => _autoStart = val);
                  unawaited(_vpn.setAutoStart(val));
                } : null,
              ),
            ],
          ),
        );
      },
    );
  }
}
