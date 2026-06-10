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

  // VPN lifecycle
  static const startVPN = 'startVPN';
  static const stopVPN = 'stopVPN';
  static const getVpnStatus = 'getVpnStatus';

  // Notification + auto-start
  static const setNotificationTitle = 'setNotificationTitle';
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

  // Background mode
  static const getBackgroundMode = 'getBackgroundMode';
  static const setBackgroundMode = 'setBackgroundMode';

  // Quick Connect
  static const requestAddTile = 'requestAddTile';

  // Diagnostics / introspection
  static const getCoreVersion = 'getCoreVersion';

  // Recovery actions (specs 030, 031)
  static const reloadVPN = 'reloadVPN';
  static const resetNetwork = 'resetNetwork';
}
