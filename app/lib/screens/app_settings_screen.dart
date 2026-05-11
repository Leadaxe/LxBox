import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../services/debug/bootstrap.dart';
import '../services/debug/transport/server.dart';
import '../services/haptic_service.dart';
import '../services/relative_time.dart';
import '../services/settings_storage.dart';
import '../services/update_checker.dart';
import '../services/url_launcher.dart' as ul;
import '../services/wifi_history_listener.dart';
import '../widgets/wifi_permission_dialog.dart';
import '../vpn/box_vpn_client.dart';
import 'about_screen.dart';
import 'backup_screen.dart';

class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({
    super.key,
    this.initialTab = 0,
    this.highlightCoreLogs = false,
  });

  /// 0 = General, 1 = Diagnostics. Used by deep-links.
  final int initialTab;

  /// Если true — после первого render'а скроллим к «Forward sing-box logs»
  /// SwitchListTile и пульсируем подсветку 2.5s. Используется banner'ом
  /// в Live tab чтобы юзер сразу увидел нужный toggle.
  final bool highlightCoreLogs;

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> with WidgetsBindingObserver {
  final _vpn = BoxVpnClient();
  bool _autoStart = false;
  bool _autoRebuild = false;
  bool _haptic = true;
  bool _batteryWhitelisted = false;
  bool _notificationsEnabled = true;
  bool _backgroundLocationGranted = false;
  bool _nearbyWifiGranted = false;
  bool _autoPing = true;
  bool _autoUpdateSubs = true;
  bool _autoCheckUpdates = true;
  bool _loaded = false;

  bool _debugEnabled = false;
  String _debugToken = '';
  int _debugPort = SettingsStorage.debugPortDefault;
  late final TextEditingController _debugPortCtl;
  String _debugPortError = '';

  bool _coreLogsEnabled = false;
  bool _configLocked = false;

  // Для deep-link «highlightCoreLogs» из Live tab banner'а — скроллим
  // к этому tile'у после первого render'а и пульсируем background 2.5s.
  final GlobalKey _coreLogsTileKey = GlobalKey();
  bool _coreLogsHighlighted = false;
  Timer? _coreLogsHighlightTimer;
  // §051 Phase 3 — auto-record visited Wi-Fi networks (default off).
  bool _autoRecordWifi = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _debugPortCtl = TextEditingController();
    unawaited(_loadAutoStart());
    if (widget.highlightCoreLogs) {
      // Tile живёт в Diagnostics tab (initialTab=1). Tab сам строит
      // children когда juзер на нём — postFrame этого build'а гарантирует
      // что _coreLogsTileKey.currentContext доступен.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToAndHighlightCoreLogs();
      });
    }
  }

  void _scrollToAndHighlightCoreLogs() {
    final ctx = _coreLogsTileKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      alignment: 0.3, // tile в верхней трети viewport'а — так юзер сразу видит
    );
    setState(() => _coreLogsHighlighted = true);
    _coreLogsHighlightTimer?.cancel();
    _coreLogsHighlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _coreLogsHighlighted = false);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debugPortCtl.dispose();
    _coreLogsHighlightTimer?.cancel();
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
    final rebuild = await SettingsStorage.getVar('auto_rebuild', 'true');
    final haptic = await SettingsStorage.getVar(HapticService.prefsKey, 'true');
    final autoPing = await SettingsStorage.getVar('auto_ping_on_start', 'true');
    final battery = await _vpn.isIgnoringBatteryOptimizations();
    final notifications = await _vpn.areNotificationsEnabled();
    final bgLocation = await ul.UrlLauncher.checkBackgroundLocationPermission();
    final nearbyWifi = await ul.UrlLauncher.checkNearbyWifiPermission();
    final autoUpdateSubs = await SettingsStorage.getAutoUpdateSubs();
    final autoCheckUpdates = await SettingsStorage.getAutoCheckUpdates();
    final debugEnabled = await SettingsStorage.getDebugEnabled();
    final debugToken = await SettingsStorage.getDebugToken();
    final debugPort = await SettingsStorage.getDebugPort();
    final coreLogsEnabled = await _vpn.getCoreLogsEnabled();
    final configLocked = await SettingsStorage.getConfigLockedForDebug();
    final autoRecordWifi = await SettingsStorage.getAutoRecordWifi();
    if (mounted) {
      setState(() {
        _autoStart = auto;
        _autoRebuild = rebuild == 'true';
        _haptic = haptic != 'false';
        _autoPing = autoPing != 'false';
        _batteryWhitelisted = battery;
        _notificationsEnabled = notifications;
        _backgroundLocationGranted = bgLocation;
        _nearbyWifiGranted = nearbyWifi;
        _autoUpdateSubs = autoUpdateSubs;
        _autoCheckUpdates = autoCheckUpdates;
        _debugEnabled = debugEnabled;
        _debugToken = debugToken;
        _debugPort = debugPort;
        _debugPortCtl.text = debugPort.toString();
        _coreLogsEnabled = coreLogsEnabled;
        _configLocked = configLocked;
        _autoRecordWifi = autoRecordWifi;
        _loaded = true;
      });
    }
  }

  /// §037 — toggle config_locked_for_debug.
  /// Когда true — `SubscriptionController.generateConfig()` тихо skip'ает
  /// rebuild при UI-действиях, и pinned config.json (например, отправленный
  /// через Debug API `PUT /config`) остаётся в живых.
  Future<void> _toggleConfigLocked(bool locked) async {
    setState(() => _configLocked = locked);
    await SettingsStorage.setConfigLockedForDebug(locked);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(locked
            ? 'Config locked. UI actions will not rebuild config.'
            : 'Config unlocked. Next UI action will rebuild from settings.'),
        duration: const Duration(seconds: 3),
      ),
    );
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
    // §037 — config lock is a debug-only feature. Disabling Debug API
    // implicitly unlocks: иначе юзер останется с pinned config'ом без
    // UI-способа его разблокировать (lock toggle живёт под Debug API
    // блоком и спрятан, когда API выключен).
    if (!enable && _configLocked) {
      await SettingsStorage.setConfigLockedForDebug(false);
      if (mounted) setState(() => _configLocked = false);
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

  /// §043: toggle forwarding sing-box логов в наш AppLog как `DebugSource.core`.
  /// Изменение применяется ТОЛЬКО после полного рестарта процесса — `Libbox.setup`
  /// с флагом `debug` вызывается один раз в `BoxApplication.initialize` (см.
  /// гард `if (initialized) return`). Stop/start VPN не помогает (service-level,
  /// не process-level), нужен force-stop + relaunch. Кнопка «Quit & reopen»
  /// рядом с toggle делает это вызовом `quitApp()` (finishAffinity + killProcess
  /// в Kotlin); юзер сам тапает иконку и получает свежий процесс.
  Future<void> _toggleCoreLogs(bool enable) async {
    setState(() => _coreLogsEnabled = enable);
    await _vpn.setCoreLogsEnabled(enable);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Saved. Force-stop & reopen app to apply.'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  /// §043 follow-up: confirm-диалог + `BoxVpnClient.quitApp()`. Process умрёт
  /// через ~250ms; Future от quitApp в норме не ресолвится — поэтому ничего
  /// не делаем после await.
  Future<void> _confirmQuitApp() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quit & reopen app?'),
        content: const Text(
          'This will fully close the app process so the new "Forward sing-box logs" '
          'value is picked up at next launch (Libbox.setup is one-shot per process). '
          'VPN service will stop. Tap the app icon to reopen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Quit'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _vpn.quitApp();
  }

  /// §032 Quick Connect — кнопка «Add tile» в General-табе.
  /// На API 33+ система сама покажет prompt; на более старых — даём
  /// текстовую инструкцию (drag через шторку).
  Future<void> _addQuickSettingsTile() async {
    final result = await _vpn.requestAddTile();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final msg = switch (result) {
      'added' => 'Tile added to Quick Settings.',
      'already' => 'Tile is already in Quick Settings.',
      'dismissed' => 'Add tile dismissed.',
      'unsupported' =>
        'Your Android version doesn\'t support an in-app prompt. '
            'Pull down the status bar → edit tiles → drag L×Box to active tiles.',
      'no_activity' => 'Cannot show prompt right now — try again.',
      _ => 'Could not request tile add ($result). '
            'Pull down the status bar → edit tiles → drag L×Box manually.',
    };
    final duration = (result == 'unsupported' ||
            result.startsWith('error') ||
            result == 'no_activity')
        ? const Duration(seconds: 6)
        : const Duration(seconds: 3);
    messenger.showSnackBar(SnackBar(content: Text(msg), duration: duration));
  }

  /// Tap on the Notifications row in Background → System setup.
  ///
  /// — granted   → open per-app notification settings (toggle categories etc.)
  /// — denied    → try the runtime POST_NOTIFICATIONS prompt; if that returns
  ///               with permission still denied (user picked "Don't allow", or
  ///               had previously selected "Don't ask again"), fall back to
  ///               the App Permissions screen.
  Future<void> _onNotificationsTap() async {
    final granted = await ul.UrlLauncher.checkNotificationPermission();
    if (granted) {
      await _vpn.openNotificationSettings();
      return;
    }
    await ul.UrlLauncher.requestNotificationPermission();
    // Re-check; system dialog is async, but on API 33+ it resolves before the
    // call returns. If "Don't ask again" was previously chosen, the prompt
    // is silently skipped — push the user to Settings instead.
    final after = await ul.UrlLauncher.checkNotificationPermission();
    if (mounted) {
      setState(() => _notificationsEnabled = after);
    }
    if (!after) {
      await ul.UrlLauncher.openAppSettings();
    }
  }

  Future<void> _refreshBatteryStatus() async {
    final battery = await _vpn.isIgnoringBatteryOptimizations();
    final notifications = await _vpn.areNotificationsEnabled();
    final bgLocation = await ul.UrlLauncher.checkBackgroundLocationPermission();
    final nearbyWifi = await ul.UrlLauncher.checkNearbyWifiPermission();
    if (mounted) {
      setState(() {
        _batteryWhitelisted = battery;
        _notificationsEnabled = notifications;
        _backgroundLocationGranted = bgLocation;
        _nearbyWifiGranted = nearbyWifi;
      });
    }
  }

  /// §051 — tap на «Nearby Wi-Fi» row. Симметрично Notifications row:
  /// - granted → App Permissions screen (юзер видит/может revoke)
  /// - denied  → shared `WifiPermissionDialog` (объяснение + runtime prompt
  ///             + Settings fallback)
  /// State после возврата из Settings рефрешится через
  /// `didChangeAppLifecycleState` → `_refreshBatteryStatus`.
  Future<void> _onNearbyWifiTap() async {
    final granted = await ul.UrlLauncher.checkNearbyWifiPermission();
    if (granted) {
      await ul.UrlLauncher.openAppSettings();
      return;
    }
    if (!mounted) return;
    await WifiPermissionDialog.show(
      context,
      missing: const ['android.permission.NEARBY_WIFI_DEVICES'],
    );
    final after = await ul.UrlLauncher.checkNearbyWifiPermission();
    if (mounted) setState(() => _nearbyWifiGranted = after);
  }

  /// §051 — tap на «Location (background)» row.
  /// - granted → App Permissions screen
  /// - denied  → shared `WifiPermissionDialog` (для BACKGROUND_LOCATION
  ///             runtime prompt бесполезен на API 30+, dialog покажет
  ///             только «Open Settings»).
  Future<void> _onBackgroundLocationTap() async {
    final granted =
        await ul.UrlLauncher.checkBackgroundLocationPermission();
    if (granted) {
      await ul.UrlLauncher.openAppSettings();
      return;
    }
    if (!mounted) return;
    await WifiPermissionDialog.show(
      context,
      missing: const ['android.permission.ACCESS_BACKGROUND_LOCATION'],
    );
    final after =
        await ul.UrlLauncher.checkBackgroundLocationPermission();
    if (mounted) setState(() => _backgroundLocationGranted = after);
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
          length: 2,
          initialIndex: widget.initialTab.clamp(0, 1),
          child: Scaffold(
            appBar: AppBar(
              title: const Text('App Settings'),
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'General'),
                  Tab(text: 'Diagnostics'),
                ],
              ),
            ),
            body: TabBarView(
              children: [
                _buildGeneralTab(context),
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
        Text('Quick connect', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.dashboard_customize_outlined),
          title: const Text('Quick Settings tile'),
          subtitle: const Text(
              'Add to status-bar shade for one-tap toggle. '
              'Android 13+ shows a system prompt; on older versions edit the shade manually.'),
          trailing: TextButton(
            onPressed: () => unawaited(_addQuickSettingsTile()),
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
          value: _autoUpdateSubs,
          onChanged: _loaded
              ? (val) {
                  setState(() => _autoUpdateSubs = val);
                  unawaited(SettingsStorage.setAutoUpdateSubs(val));
                }
              : null,
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
          value: _autoCheckUpdates,
          onChanged: _loaded
              ? (val) {
                  setState(() => _autoCheckUpdates = val);
                  unawaited(SettingsStorage.setAutoCheckUpdates(val));
                }
              : null,
        ),
        const _UpdateStatusRow(),
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
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const BackupScreen()),
          ),
        ),
      ],
    );
  }

  Widget _buildDiagnosticsTab(BuildContext context) {
    return ListView(
      padding: _tabPadding(context),
      children: [
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
          onTap: _onNotificationsTap,
        ),
        // §051 — Wi-Fi rules permissions: BACKGROUND_LOCATION (API 29+) и
        // NEARBY_WIFI_DEVICES (API 33+). Без них sing-box `wifi_ssid` /
        // `wifi_bssid` правила не сматчатся (`WifiInfo.ssid` возвращает
        // `<unknown ssid>`). См. spec/050 findings + spec/051.
        ListTile(
          leading: Icon(
            _backgroundLocationGranted
                ? Icons.location_on_outlined
                : Icons.location_off_outlined,
            color: _backgroundLocationGranted
                ? Colors.green
                : Theme.of(context).colorScheme.error,
          ),
          title: const Text('Location (background)'),
          subtitle: Text(_backgroundLocationGranted
              ? 'Granted — sing-box can read Wi-Fi state for routing rules'
              : 'Required for Wi-Fi-based routing rules. Tap to grant.'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: _onBackgroundLocationTap,
        ),
        ListTile(
          leading: Icon(
            _nearbyWifiGranted
                ? Icons.wifi_outlined
                : Icons.wifi_off_outlined,
            color: _nearbyWifiGranted
                ? Colors.green
                : Theme.of(context).colorScheme.error,
          ),
          title: const Text('Nearby Wi-Fi devices'),
          subtitle: Text(_nearbyWifiGranted
              ? 'Granted — real SSID/BSSID accessible'
              : 'Android 13+ requires this for SSID. Tap to grant.'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: _onNearbyWifiTap,
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
        // §037 — config_locked_for_debug. Видим только когда Debug API ON,
        // чтобы lock не висел сиротой без UI-возврата к разблокировке (его
        // снимают через Debug API `PUT /settings/config_locked` или этим
        // toggle'ом). При выключении Debug API toggle выше — lock auto-снимется.
        if (_debugEnabled)
          SwitchListTile(
            title: const Text('Lock config (debug)'),
            subtitle: Text(
              _configLocked
                  ? 'Pinned. UI actions skip config rebuild — useful when testing PUT /config overrides.'
                  : 'Off — UI actions rebuild config from settings as usual.',
            ),
            secondary: const Icon(Icons.lock_outline),
            value: _configLocked,
            onChanged: _loaded
                ? (val) => unawaited(_toggleConfigLocked(val))
                : null,
          ),
        // §043: forwarding sing-box internal logs into our AppLog (Debug
        // screen → Core tab + /logs/core endpoint). Off by default — sing-box
        // на busy traffic эмитит сотни строк/минуту; opt-in для диагностики.
        // Subtitle короткий и timeless — без «after restart» (показывался бы
        // и после самого рестарта, misleading); пояснялка про process-restart
        // вынесена в полноширинный блок ниже.
        AnimatedContainer(
          key: _coreLogsTileKey,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
          color: _coreLogsHighlighted
              ? Theme.of(context).colorScheme.tertiaryContainer
              : Colors.transparent,
          child: SwitchListTile(
            title: const Text('Forward sing-box logs'),
            subtitle: Text(
              _coreLogsEnabled
                  ? 'Visible in Debug → Core.'
                  : 'Off.',
            ),
            secondary: const Icon(Icons.terminal),
            value: _coreLogsEnabled,
            onChanged: _loaded
                ? (val) => unawaited(_toggleCoreLogs(val))
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Setting is saved immediately, but `Libbox.setup` reads the '
                '`debug` flag once per process. Stop/start VPN does NOT '
                're-apply — force-stop the app (or use the button below) '
                'and reopen.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: _loaded ? () => unawaited(_confirmQuitApp()) : null,
                icon: const Icon(Icons.logout, size: 18),
                label: const Text('Quit & reopen app'),
              ),
            ],
          ),
        ),
        // §051 Phase 3 — auto-record visited Wi-Fi networks. Default ON:
        // без auto-record «Pick saved» picker почти всегда пустой,
        // фича теряет смысл. 5-минутный stickiness отсекает drive-by
        // сети (магазин/проход). Toggle для тех кто не хочет logging.
        const Divider(height: 8),
        SwitchListTile(
          title: const Text('Auto-record visited Wi-Fi networks'),
          subtitle: Text(
            _autoRecordWifi
                ? 'Networks where you stay ≥ 5 minutes appear in routing rule editor → Pick saved.'
                : 'Off. Pick saved is populated only by Add current / Manual.',
          ),
          secondary: const Icon(Icons.history),
          value: _autoRecordWifi,
          onChanged: _loaded
              ? (val) => unawaited(_toggleAutoRecordWifi(val))
              : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
          child: Text(
            'Stored locally only. Existing entries persist when you turn this off — '
            'remove individually in Pick saved (long-press chip → Remove).',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// §051 Phase 3 — toggle для auto-record. Сразу sync'ит state в native
  /// observer (start/stop NetworkCallback). Существующая история не
  /// чистится при OFF — это user data, явный поход в Pick saved.
  Future<void> _toggleAutoRecordWifi(bool enabled) async {
    setState(() => _autoRecordWifi = enabled);
    await SettingsStorage.setAutoRecordWifi(enabled);
    await WifiHistoryListener.I.setEnabled(enabled);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(enabled
            ? 'Auto-record on. Networks added after 5 min of stay.'
            : 'Auto-record off. Existing history kept.'),
      ),
    );
  }
}

/// "Last check: …" + Check now-кнопка под Updates-toggle. Подписан на
/// `UpdateChecker.latest` чтобы при успешном fetch'е результат сразу
/// отрендерился.
class _UpdateStatusRow extends StatefulWidget {
  const _UpdateStatusRow();

  @override
  State<_UpdateStatusRow> createState() => _UpdateStatusRowState();
}

class _UpdateStatusRowState extends State<_UpdateStatusRow> {
  DateTime? _lastCheck;
  bool _checking = false;
  String? _resultLine;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLastCheck());
  }

  Future<void> _loadLastCheck() async {
    final dt = await SettingsStorage.getLastUpdateCheck();
    if (mounted) setState(() => _lastCheck = dt);
  }

  Future<void> _checkNow() async {
    setState(() {
      _checking = true;
      _resultLine = null;
    });
    final result = await UpdateChecker.I.forceCheck(
      localVersion: AboutScreen.versionString,
    );
    final dt = await SettingsStorage.getLastUpdateCheck();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _lastCheck = dt;
      switch (result.kind) {
        case UpdateCheckKind.newer:
          _resultLine = '${result.info!.tag} available';
        case UpdateCheckKind.upToDate:
          _resultLine = "You're up to date";
        case UpdateCheckKind.failed:
          _resultLine = 'Check failed: ${result.message ?? ''}';
        case UpdateCheckKind.skipped:
          _resultLine = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lastCheckText = _lastCheck == null
        ? 'Last check: never'
        : 'Last check: ${relativeTime(DateTime.now(), _lastCheck!)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _resultLine ?? lastCheckText,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
          if (_checking)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            TextButton(
              onPressed: _checkNow,
              child: const Text('Check now'),
            ),
        ],
      ),
    );
  }
}
