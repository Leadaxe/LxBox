import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/settings_storage.dart';
import '../vpn/box_vpn_client.dart';

class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({super.key});

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  final _vpn = BoxVpnClient();
  bool _autoStart = false;
  bool _keepOnExit = false;
  bool _autoRebuild = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAutoStart());
  }

  Future<void> _loadAutoStart() async {
    final auto = await _vpn.getAutoStart();
    final keep = await _vpn.getKeepOnExit();
    final rebuild = await SettingsStorage.getVar('auto_rebuild', 'true');
    if (mounted) setState(() { _autoStart = auto; _keepOnExit = keep; _autoRebuild = rebuild == 'true'; _loaded = true; });
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
              SwitchListTile(
                title: const Text('Keep VPN on exit'),
                subtitle: const Text('VPN stays active when app is closed'),
                secondary: const Icon(Icons.exit_to_app),
                value: _keepOnExit,
                onChanged: _loaded ? (val) {
                  setState(() => _keepOnExit = val);
                  unawaited(_vpn.setKeepOnExit(val));
                } : null,
              ),
              SwitchListTile(
                title: const Text('Auto-rebuild config'),
                subtitle: const Text('Rebuild config automatically when settings change'),
                secondary: const Icon(Icons.build_circle_outlined),
                value: _autoRebuild,
                onChanged: _loaded ? (val) {
                  setState(() => _autoRebuild = val);
                  unawaited(SettingsStorage.setVar('auto_rebuild', val.toString()));
                } : null,
              ),
            ],
          ),
        );
      },
    );
  }
}
