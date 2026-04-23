import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../services/debug/bootstrap.dart';
import '../services/debug/transport/server.dart';
import '../services/haptic_service.dart';
import '../services/settings_storage.dart';
import '../vpn/box_vpn_client.dart';

class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({super.key});

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> with WidgetsBindingObserver {
  final _vpn = BoxVpnClient();
  bool _autoStart = false;
  bool _keepOnExit = false;
  bool _autoRebuild = false;
  bool _haptic = true;
  bool _batteryWhitelisted = false;
  bool _notificationsEnabled = true;
  String _backgroundMode = 'never';
  bool _autoPing = true;
  bool _autoUpdateSubs = true;
  bool _loaded = false;

  // §031 Debug API.
  bool _debugEnabled = false;
  String _debugToken = '';
  int _debugPort = SettingsStorage.debugPortDefault;
  late final TextEditingController _debugPortCtl;
  String _debugPortError = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _debugPortCtl = TextEditingController();
    unawaited(_loadAutoStart());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debugPortCtl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Юзер вернулся из системных настроек — перечитать whitelist-статус.
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshBatteryStatus());
    }
  }

  Future<void> _loadAutoStart() async {
    final auto = await _vpn.getAutoStart();
    final keep = await _vpn.getKeepOnExit();
    final rebuild = await SettingsStorage.getVar('auto_rebuild', 'true');
    final haptic = await SettingsStorage.getVar(HapticService.prefsKey, 'true');
    final autoPing = await SettingsStorage.getVar('auto_ping_on_start', 'true');
    final battery = await _vpn.isIgnoringBatteryOptimizations();
    final notifications = await _vpn.areNotificationsEnabled();
    final bgMode = await _vpn.getBackgroundMode();
    final autoUpdateSubs = await SettingsStorage.getAutoUpdateSubs();
    final debugEnabled = await SettingsStorage.getDebugEnabled();
    final debugToken = await SettingsStorage.getDebugToken();
    final debugPort = await SettingsStorage.getDebugPort();
    if (mounted) {
      setState(() {
        _autoStart = auto;
        _keepOnExit = keep;
        _autoRebuild = rebuild == 'true';
        _haptic = haptic != 'false';
        _autoPing = autoPing != 'false';
        _batteryWhitelisted = battery;
        _notificationsEnabled = notifications;
        _backgroundMode = bgMode;
        _autoUpdateSubs = autoUpdateSubs;
        _debugEnabled = debugEnabled;
        _debugToken = debugToken;
        _debugPort = debugPort;
        _debugPortCtl.text = debugPort.toString();
        _loaded = true;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // §031 Debug API — toggle / token / port handlers.
  //
  // Все изменения ведут к [applyDebugApiSettings], который читает SettingsStorage
  // и приводит DebugServer в соответствие (start/stop/rebind).
  // ---------------------------------------------------------------------------

  Future<void> _toggleDebugApi(bool enable) async {
    setState(() => _debugEnabled = enable);
    await SettingsStorage.setDebugEnabled(enable);
    if (enable && _debugToken.isEmpty) {
      final token = DebugServer.generateToken();
      await SettingsStorage.setDebugToken(token);
      if (mounted) setState(() => _debugToken = token);
    }
    await applyDebugApiSettings();
  }

  Future<void> _regenerateDebugToken() async {
    final token = DebugServer.generateToken();
    await SettingsStorage.setDebugToken(token);
    if (mounted) setState(() => _debugToken = token);
    await applyDebugApiSettings();
  }

  Future<void> _copyDebugToken() async {
    await Clipboard.setData(ClipboardData(text: _debugToken));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Token copied'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _applyDebugPort(String raw) async {
    final port = int.tryParse(raw);
    if (port == null || port < 1024 || port > 49151) {
      setState(() => _debugPortError = 'port must be 1024..49151');
      return;
    }
    if (port == _debugPort) {
      setState(() => _debugPortError = '');
      return;
    }
    setState(() {
      _debugPort = port;
      _debugPortError = '';
    });
    await SettingsStorage.setDebugPort(port);
    await applyDebugApiSettings();
  }

  Future<void> _applyBackgroundMode(String? mode) async {
    if (mode == null || mode == _backgroundMode) return;
    setState(() => _backgroundMode = mode);
    await _vpn.setBackgroundMode(mode);
  }

  Future<void> _refreshBatteryStatus() async {
    final battery = await _vpn.isIgnoringBatteryOptimizations();
    final notifications = await _vpn.areNotificationsEnabled();
    if (mounted) {
      setState(() {
        _batteryWhitelisted = battery;
        _notificationsEnabled = notifications;
      });
    }
  }

  /// Preset-инструкции перед переходом в system App info — OEM'ы прячут
  /// нужные тоглы в разных местах, юзер без подсказки теряется.
  Future<void> _openAppInfoWithHint() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Find these toggles'),
        content: const SingleChildScrollView(
          child: Text(
            'In the next screen (system App info) look for:\n\n'
            '• Autostart / Startup manager — allow\n'
            '• Background activity / Allow in background — allow\n'
            '• Battery / Power usage → "Don\'t optimize" or "No restrictions"\n'
            '• Battery saver exceptions — add L×Box\n\n'
            'Location of these toggles varies by OEM (Xiaomi/MIUI, Samsung/One UI, Oppo/ColorOS, Huawei, Google Pixel). Some are under Battery, others under App permissions.',
            style: TextStyle(fontSize: 13, height: 1.4),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (proceed == true) await _vpn.openAppDetailsSettings();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: themeNotifier,
      builder: (context, _) {
        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('App Settings'),
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'General'),
                  Tab(text: 'Background'),
                  Tab(text: 'Diagnostics'),
                ],
              ),
            ),
            body: TabBarView(
              children: [
                _buildGeneralTab(context),
                _buildBackgroundTab(context),
                _buildDiagnosticsTab(context),
              ],
            ),
          ),
        );
      },
    );
  }

  EdgeInsets _tabPadding(BuildContext context) => EdgeInsets.fromLTRB(
      12, 12, 12, MediaQuery.of(context).padding.bottom + 24);

  Widget _buildGeneralTab(BuildContext context) {
    return ListView(
      padding: _tabPadding(context),
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
          value: _autoStart,
          onChanged: _loaded ? (val) {
            setState(() => _autoStart = val);
            unawaited(_vpn.setAutoStart(val));
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
        const Divider(height: 32),
        Text('Subscriptions', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('Auto-update subscriptions'),
          subtitle: const Text(
              'Refresh on app start, after VPN connects, and periodically. '
              'Manual ⟳ works regardless.'),
          secondary: const Icon(Icons.cloud_sync_outlined),
          value: _autoUpdateSubs,
          onChanged: _loaded
              ? (val) {
                  setState(() => _autoUpdateSubs = val);
                  unawaited(SettingsStorage.setAutoUpdateSubs(val));
                }
              : null,
        ),
        const Divider(height: 32),
        Text('Feedback', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('Auto-ping after connect'),
          subtitle: const Text(
              'Ping nodes of active group 5s after VPN starts (once per connect)'),
          secondary: const Icon(Icons.network_ping),
          value: _autoPing,
          onChanged: _loaded
              ? (val) {
                  setState(() => _autoPing = val);
                  unawaited(SettingsStorage.setVar(
                      'auto_ping_on_start', val.toString()));
                }
              : null,
        ),
        SwitchListTile(
          title: const Text('Haptic feedback'),
          subtitle: const Text('Vibrate on connect, disconnect and errors. Respects system "Touch feedback" setting'),
          secondary: const Icon(Icons.vibration),
          value: _haptic,
          onChanged: _loaded ? (val) {
            setState(() => _haptic = val);
            HapticService.I.enabled = val;
            unawaited(SettingsStorage.setVar(HapticService.prefsKey, val.toString()));
            if (val) {
              HapticService.I.onConnectTap();
            }
          } : null,
        ),
      ],
    );
  }

  Widget _buildBackgroundTab(BuildContext context) {
    return ListView(
      padding: _tabPadding(context),
      children: [
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
        const Divider(height: 32),
        Text('System setup', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: Icon(
            _batteryWhitelisted ? Icons.battery_full : Icons.battery_alert,
            color: _batteryWhitelisted
                ? Colors.green
                : Theme.of(context).colorScheme.error,
          ),
          title: const Text('Battery optimization'),
          subtitle: Text(_batteryWhitelisted
              ? 'Whitelisted — VPN can run in background'
              : 'Restricted — Android may pause VPN in idle. Tap to grant.'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () async {
            await _vpn.openBatteryOptimizationSettings();
          },
        ),
        ListTile(
          leading: Icon(
            _notificationsEnabled
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined,
            color: _notificationsEnabled
                ? Colors.green
                : Theme.of(context).colorScheme.error,
          ),
          title: const Text('Notifications'),
          subtitle: Text(_notificationsEnabled
              ? 'Allowed — foreground service shows VPN status'
              : 'Blocked — Android may throttle the VPN service. Tap to allow.'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () async {
            await _vpn.openNotificationSettings();
          },
        ),
        ListTile(
          leading: const Icon(Icons.settings_applications_outlined),
          title: const Text('App info (OEM power settings)'),
          subtitle: const Text(
              'OEM-specific toggles to keep VPN alive in background.'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: _openAppInfoWithHint,
        ),
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(
            children: [
              const Icon(Icons.bedtime_outlined, size: 20),
              const SizedBox(width: 12),
              Text('Tunnel sleep mode',
                  style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(48, 0, 16, 4),
          child: Text(
            'When to pause the tunnel to save battery. Takes effect on '
            'next VPN connect.',
            style: TextStyle(fontSize: 12),
          ),
        ),
        RadioGroup<String>(
          groupValue: _backgroundMode,
          onChanged: (String? m) {
            if (!_loaded) return;
            unawaited(_applyBackgroundMode(m));
          },
          child: const Column(
            children: [
              RadioListTile<String>(
                value: 'never',
                title: Text('Never sleep (recommended)'),
                subtitle: Text(
                    'Tunnel is always active. Best reliability — pushes '
                    'and long-lived sockets survive. Higher battery use.'),
              ),
              RadioListTile<String>(
                value: 'lazy',
                title: Text('Lazy sleep'),
                subtitle: Text(
                    'Pause only in deep Doze (screen off for a long '
                    'time + no motion). Balanced.'),
              ),
              RadioListTile<String>(
                value: 'always',
                title: Text('Aggressive battery saving'),
                subtitle: Text(
                    'Pause tunnel whenever screen turns off. Max '
                    'battery savings, but pushes, incoming calls and '
                    'background sync stop until unlock.'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDiagnosticsTab(BuildContext context) {
    return ListView(
      padding: _tabPadding(context),
      children: [
        Text('Granted permissions',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _permissionRow(
          context,
          ok: _batteryWhitelisted,
          okLabel: 'Battery optimization: Unrestricted',
          badLabel: 'Battery optimization: Restricted',
        ),
        _permissionRow(
          context,
          ok: _notificationsEnabled,
          okLabel: 'Notifications: Allowed',
          badLabel: 'Notifications: Blocked',
        ),
        const Divider(height: 32),
        Text('Developer', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('Debug API'),
          subtitle: Text(
            _debugEnabled
                ? 'Exposed on http://127.0.0.1:$_debugPort (adb forward only)'
                : 'Runtime HTTP server for adb-forwarded debugging.',
          ),
          secondary: const Icon(Icons.bug_report),
          value: _debugEnabled,
          onChanged: _loaded
              ? (val) => unawaited(_toggleDebugApi(val))
              : null,
        ),
        if (_debugEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Token',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        _debugToken.isEmpty ? '(not set)' : _debugToken,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed:
                          _debugToken.isEmpty ? null : _copyDebugToken,
                    ),
                    IconButton(
                      tooltip: 'Regenerate',
                      icon: const Icon(Icons.refresh, size: 18),
                      onPressed: () =>
                          unawaited(_regenerateDebugToken()),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _debugPortCtl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Port',
                    helperText: 'Range 1024..49151',
                    errorText: _debugPortError.isEmpty
                        ? null
                        : _debugPortError,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (v) => unawaited(_applyDebugPort(v)),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Token is shown only here. It is NOT written to any '
                  'file — use Copy to save. Server binds on 127.0.0.1 '
                  'only; use `adb forward tcp:9269 tcp:9269`.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Compact read-only row for diagnostics — icon + status text, not tappable.
  /// Actions (fix/grant) живут в Background tab — здесь только статус.
  Widget _permissionRow(
    BuildContext context, {
    required bool ok,
    required String okLabel,
    required String badLabel,
  }) {
    return ListTile(
      dense: true,
      leading: Icon(
        ok ? Icons.check_circle : Icons.cancel,
        color: ok ? Colors.green : Theme.of(context).colorScheme.error,
      ),
      title: Text(ok ? okLabel : badLabel),
    );
  }
}
