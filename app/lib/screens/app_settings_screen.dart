import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../services/debug/bootstrap.dart';
import '../services/debug/transport/server.dart';
import '../services/haptic_service.dart';
import '../services/settings_storage.dart';
import '../services/url_launcher.dart' as ul;
import '../services/wifi_history_listener.dart';
import '../widgets/wifi_permission_dialog.dart';
import '../vpn/box_vpn_client.dart';
import 'app_settings_screen/app_settings_dialogs.dart';
import 'app_settings_screen/widgets/diagnostics_tab.dart';
import 'app_settings_screen/widgets/general_tab.dart';
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
    final ok = await AppSettingsDialogs.confirmQuitApp(context);
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
    final proceed = await AppSettingsDialogs.openAppInfoHint(context);
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
    return GeneralTab(
      loaded: _loaded,
      autoStart: _autoStart,
      autoRebuild: _autoRebuild,
      autoUpdateSubs: _autoUpdateSubs,
      autoCheckUpdates: _autoCheckUpdates,
      autoPing: _autoPing,
      haptic: _haptic,
      padding: _tabPadding(context),
      onAutoStartChanged: (val) {
        setState(() => _autoStart = val);
        unawaited(_vpn.setAutoStart(val));
      },
      onAutoRebuildChanged: (val) {
        setState(() => _autoRebuild = val);
        unawaited(SettingsStorage.setVar('auto_rebuild', val.toString()));
      },
      onAutoUpdateSubsChanged: (val) {
        setState(() => _autoUpdateSubs = val);
        unawaited(SettingsStorage.setAutoUpdateSubs(val));
      },
      onAutoCheckUpdatesChanged: (val) {
        setState(() => _autoCheckUpdates = val);
        unawaited(SettingsStorage.setAutoCheckUpdates(val));
      },
      onAutoPingChanged: (val) {
        setState(() => _autoPing = val);
        unawaited(SettingsStorage.setVar(
            'auto_ping_on_start', val.toString()));
      },
      onHapticChanged: (val) {
        setState(() => _haptic = val);
        HapticService.I.enabled = val;
        unawaited(SettingsStorage.setVar(HapticService.prefsKey, val.toString()));
        if (val) {
          HapticService.I.onConnectTap();
        }
      },
      onAddQuickSettingsTile: () => unawaited(_addQuickSettingsTile()),
      onOpenBackup: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const BackupScreen()),
      ),
    );
  }

  Widget _buildDiagnosticsTab(BuildContext context) {
    return DiagnosticsTab(
      loaded: _loaded,
      padding: _tabPadding(context),
      batteryWhitelisted: _batteryWhitelisted,
      notificationsEnabled: _notificationsEnabled,
      backgroundLocationGranted: _backgroundLocationGranted,
      nearbyWifiGranted: _nearbyWifiGranted,
      debugEnabled: _debugEnabled,
      debugPort: _debugPort,
      debugToken: _debugToken,
      debugPortError: _debugPortError,
      debugPortCtl: _debugPortCtl,
      configLocked: _configLocked,
      coreLogsEnabled: _coreLogsEnabled,
      coreLogsHighlighted: _coreLogsHighlighted,
      coreLogsTileKey: _coreLogsTileKey,
      autoRecordWifi: _autoRecordWifi,
      onBatteryTap: () async {
        await _vpn.openBatteryOptimizationSettings();
      },
      onNotificationsTap: _onNotificationsTap,
      onBackgroundLocationTap: _onBackgroundLocationTap,
      onNearbyWifiTap: _onNearbyWifiTap,
      onAppInfoTap: _openAppInfoWithHint,
      onDebugApiChanged: (val) => unawaited(_toggleDebugApi(val)),
      onCopyDebugToken: _copyDebugToken,
      onRegenerateDebugToken: () => unawaited(_regenerateDebugToken()),
      onDebugPortSubmitted: (v) => unawaited(_applyDebugPort(v)),
      onConfigLockedChanged: (val) => unawaited(_toggleConfigLocked(val)),
      onCoreLogsChanged: (val) => unawaited(_toggleCoreLogs(val)),
      onQuitApp: () => unawaited(_confirmQuitApp()),
      onAutoRecordWifiChanged: (val) => unawaited(_toggleAutoRecordWifi(val)),
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
