import 'dart:async';

import 'package:flutter/services.dart';

/// Thin Dart wrapper over native MethodChannel/EventChannel for VPN control.
/// Replaces flutter_singbox_vpn plugin with identical public API surface.
class BoxVpnClient {
  static const _methods = MethodChannel('com.leadaxe.boxvpn/methods');
  static const _statusEvents = EventChannel('com.leadaxe.boxvpn/status_events');

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

  /// Set the notification title shown while VPN is active.
  Future<bool> setNotificationTitle(String title) async {
    final ok = await _methods.invokeMethod<bool>(
      'setNotificationTitle',
      {'title': title},
    );
    return ok ?? false;
  }

  /// Get list of installed apps: [{packageName, appName, isSystemApp}, ...]
  Future<List<Map<String, dynamic>>> getInstalledApps() async {
    final result = await _methods.invokeMethod<List<dynamic>>('getInstalledApps');
    if (result == null) return [];
    return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Stream of status events: {"status": "Started"|"Starting"|"Stopped"|"Stopping"}
  Stream<Map<String, dynamic>> get onStatusChanged {
    return _statusEvents.receiveBroadcastStream().map((event) {
      if (event is Map) return Map<String, dynamic>.from(event);
      return <String, dynamic>{};
    });
  }
}
