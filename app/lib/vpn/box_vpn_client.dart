import 'dart:async';

import 'package:flutter/services.dart';

/// Thin Dart wrapper over native MethodChannel/EventChannel for VPN control.
/// Replaces flutter_singbox_vpn plugin with identical public API surface.
class BoxVpnClient {
  static const _methods = MethodChannel('com.leadaxe.lxbox/methods');
  static const _statusEvents = EventChannel('com.leadaxe.lxbox/status_events');

  /// Save sing-box JSON config to native storage.
  Future<bool> saveConfig(String config) async {
    final ok = await _methods.invokeMethod<bool>('saveConfig', {'config': config});
    return ok ?? false;
  }

  /// Read current config from native storage.
  Future<String> getConfig() async {
    final config = await _methods.invokeMethod<String>('getConfig');
    return config ?? '{}';
  }

  /// Request VPN start (may trigger system permission dialog).
  Future<bool> startVPN() async {
    final ok = await _methods.invokeMethod<bool>('startVPN');
    return ok ?? false;
  }

  /// Request VPN stop.
  Future<bool> stopVPN() async {
    final ok = await _methods.invokeMethod<bool>('stopVPN');
    return ok ?? false;
  }

  /// Pull-запрос текущего status'а у native-сервиса. Нужен на init —
  /// `onStatusChanged` шлёт только переходы, поэтому если Flutter-процесс
  /// перезапустился, а сервис всё ещё `Started` — без явного pull'а UI
  /// останется в `Disconnected`.
  Future<String> getVpnStatus() async {
    final s = await _methods.invokeMethod<String>('getVpnStatus');
    return s ?? 'Stopped';
  }

  /// Set the notification title shown while VPN is active.
  Future<bool> setNotificationTitle(String title) async {
    final ok = await _methods.invokeMethod<bool>(
      'setNotificationTitle',
      {'title': title},
    );
    return ok ?? false;
  }

  /// Set auto-start VPN on boot.
  Future<bool> setAutoStart(bool enabled) async {
    final ok = await _methods.invokeMethod<bool>('setAutoStart', {'enabled': enabled});
    return ok ?? false;
  }

  /// Get auto-start setting.
  Future<bool> getAutoStart() async {
    final ok = await _methods.invokeMethod<bool>('getAutoStart');
    return ok ?? false;
  }

  /// Set keep VPN running when app is closed.
  Future<bool> setKeepOnExit(bool enabled) async {
    final ok = await _methods.invokeMethod<bool>('setKeepOnExit', {'enabled': enabled});
    return ok ?? false;
  }

  /// Get keep on exit setting.
  Future<bool> getKeepOnExit() async {
    final ok = await _methods.invokeMethod<bool>('getKeepOnExit');
    return ok ?? false;
  }

  /// Get list of installed apps — lightweight metadata only, no icons.
  /// Icons are loaded lazily per-package via [getAppIcon].
  Future<List<Map<String, dynamic>>> getInstalledApps() async {
    final result = await _methods.invokeMethod<List<dynamic>>('getInstalledApps');
    if (result == null) return [];
    return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Fetch a single app icon as base64-encoded PNG. Empty string on failure
  /// (package not found, cannot render icon).
  Future<String> getAppIcon(String packageName) async {
    final s = await _methods
        .invokeMethod<String>('getAppIcon', {'packageName': packageName});
    return s ?? '';
  }

  /// Fetch full app info (name + icon + isSystem) in a single native call.
  /// Returns null if package not installed.
  Future<Map<String, dynamic>?> getAppInfo(String packageName) async {
    final r = await _methods
        .invokeMethod<Map<dynamic, dynamic>>('getAppInfo', {'packageName': packageName});
    if (r == null) return null;
    return Map<String, dynamic>.from(r);
  }

  /// Whether this app is whitelisted from battery optimization (Doze/App Standby).
  Future<bool> isIgnoringBatteryOptimizations() async {
    final ok = await _methods
        .invokeMethod<bool>('isIgnoringBatteryOptimizations');
    return ok ?? false;
  }

  /// Open system dialog / settings page to whitelist the app from battery
  /// optimization. Returns false if no settings activity is reachable.
  Future<bool> openBatteryOptimizationSettings() async {
    final ok = await _methods
        .invokeMethod<bool>('openBatteryOptimizationSettings');
    return ok ?? false;
  }

  /// Open per-app Settings page (where OEM "Autostart", "Background activity"
  /// and "Battery saver" toggles live). Pure navigation, no result state.
  Future<bool> openAppDetailsSettings() async {
    final ok = await _methods.invokeMethod<bool>('openAppDetailsSettings');
    return ok ?? false;
  }

  /// Stream of status events: {"status": "Started"|"Starting"|"Stopped"|"Stopping"}
  Stream<Map<String, dynamic>> get onStatusChanged {
    return _statusEvents.receiveBroadcastStream().map((event) {
      if (event is Map) return Map<String, dynamic>.from(event);
      return <String, dynamic>{};
    });
  }
}
