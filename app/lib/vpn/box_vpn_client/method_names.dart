part of '../box_vpn_client.dart';

// -----------------------------------------------------------------------------
// Method-name константы — централизованный контракт с `VpnPlugin.kt`.
// Зеркало `case "X" in handleMethodCall(...)` Kotlin handler'а. Опечатки в
// одном месте поймаются при review, не silently break MethodChannel.
//
// Вынесено `part`'ом — та же библиотека, тот же приватный доступ из
// [BoxVpnClient]. Имена методов идентичны исходнику.
// -----------------------------------------------------------------------------

class _Methods {
  const _Methods._();

  // Config
  static const saveConfig = 'saveConfig';
  static const getConfig = 'getConfig';
  /// §316 — native `Context.filesDir` (краш-репорты и stderr ядра лежат там,
  /// а НЕ в Dart-овском `getApplicationDocumentsDirectory()` = `app_flutter`).
  static const getFilesDir = 'getFilesDir';

  // VPN lifecycle
  static const startVPN = 'startVPN';
  // §165 — headless-старт (Debug API/automation, без Activity/consent).
  static const startVpnHeadless = 'startVpnHeadless';
  static const stopVPN = 'stopVPN';
  // §129 — force-stop при зависшем-вхолостую ядре (fire-and-forget).
  static const forceStopVPN = 'forceStopVPN';
  static const getVpnStatus = 'getVpnStatus';
  // Активен ли VPN другого приложения (для диалога «переключиться?» перед стартом).
  static const isForeignVpnActive = 'isForeignVpnActive';
  // §187 — прошедшие мс с реального старта туннеля (переживает swipe).
  static const getTunnelUptimeMs = 'getTunnelUptimeMs';

  // Notification + auto-start
  static const setNotificationTitle = 'setNotificationTitle';
  static const setNotificationText = 'setNotificationText';
  static const setAutoStart = 'setAutoStart';
  static const getAutoStart = 'getAutoStart';
  static const setKeepOnExit = 'setKeepOnExit';
  static const getKeepOnExit = 'getKeepOnExit';

  // §043 core logs forwarding toggle
  static const setCoreLogsEnabled = 'setCoreLogsEnabled';
  static const getCoreLogsEnabled = 'getCoreLogsEnabled';
  static const quitApp = 'quitApp';

  // §049 F15 — VPN bypass opt-in
  static const setAllowBypass = 'setAllowBypass';
  static const getAllowBypass = 'getAllowBypass';
  // §189 — auto_redirect (§124 root-only tproxy); зеркало native_prefs.
  static const setAutoRedirect = 'setAutoRedirect';
  static const getAutoRedirect = 'getAutoRedirect';
  // §192 — has_tun (производное от vpn_mode); гейтит VpnService.prepare().
  // Только set: native читает has_tun напрямую (BootReceiver.hasTun), не через
  // method-channel — getHasTun-handler не нужен.
  static const setHasTun = 'setHasTun';
  // §069 — runtime applied value of allowBypass
  static const getCurrentSessionAllowBypass = 'getCurrentSessionAllowBypass';

  // App enumeration
  static const getInstalledApps = 'getInstalledApps';
  static const getAppIcon = 'getAppIcon';
  static const getAppInfo = 'getAppInfo';

  // System settings
  static const isIgnoringBatteryOptimizations = 'isIgnoringBatteryOptimizations';
  static const openBatteryOptimizationSettings = 'openBatteryOptimizationSettings';
  static const openAppDetailsSettings = 'openAppDetailsSettings';
  static const areNotificationsEnabled = 'areNotificationsEnabled';
  static const openNotificationSettings = 'openNotificationSettings';
  static const openVpnSettings = 'openVpnSettings';

  // Background mode
  static const getBackgroundMode = 'getBackgroundMode';
  static const setBackgroundMode = 'setBackgroundMode';

  // Memory limit (§271)
  static const getMemoryLimit = 'getMemoryLimit';
  static const setMemoryLimit = 'setMemoryLimit';

  // §279 — app language mirror (boxvpn_boot) + relabel нативных поверхностей.
  static const setAppLanguage = 'setAppLanguage';
  // §279 Phase 6 — снимок per-app-локалей (33+) для reconciliation (§6.4).
  static const getAppLanguageState = 'getAppLanguageState';

  // Quick Connect
  static const requestAddTile = 'requestAddTile';

  // Diagnostics / introspection
  static const getCoreVersion = 'getCoreVersion';
  static const getMemoryInfo = 'getMemoryInfo';

  // Recovery actions (specs 030, 031)
  static const reloadVPN = 'reloadVPN';
  static const resetNetwork = 'resetNetwork';
  // §263 — сброс DNS-кэша ядра (cache.db: FakeIP-аллокации + DNS RDRC).
  static const clearDnsCache = 'clearDnsCache';

  // §047 Automation API — Dart → native control + outgoing emit.
  static const setAutomationEnabled = 'setAutomationEnabled';
  static const sendAutomationBroadcast = 'sendAutomationBroadcast';
  // §047 Шаг 2 — mirror активной ноды/группы для Locale condition-плагина.
  static const setAutomationActiveState = 'setAutomationActiveState';

  // §047 — native → Dart incoming intent dispatch (handled on this same
  // MethodChannel via setMethodCallHandler).
  static const automationAction = 'automationAction';

  // §207 — обобщённый pprof-снимок через libbox PProfServer. Один метод на
  // все профили (goroutine/profile/heap/allocs/block/mutex/threadcreate).
  static const pprofProfile = 'pprofProfile';
}
