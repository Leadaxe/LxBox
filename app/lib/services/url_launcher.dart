import 'package:flutter/services.dart';

import 'platform_channels.dart';

/// Opens a URL using the platform's default handler.
/// Falls back to copying to clipboard if the platform channel is unavailable.
class UrlLauncher {
  UrlLauncher._();

  static const _channel = MethodChannel(PlatformChannels.utils);

  /// Returns true if opened, false if copied to clipboard as fallback.
  static Future<bool> open(String url) async {
    try {
      await _channel.invokeMethod('openUrl', {'url': url});
      return true;
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: url));
      return false;
    }
  }

  /// Opens Android Settings → App permissions page directly. Used for
  /// permissions that can only be granted via Settings (e.g.
  /// `ACCESS_BACKGROUND_LOCATION` on API 30+).
  static Future<bool> openAppSettings() async {
    try {
      final ok = await _channel.invokeMethod<bool>('openAppSettings');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Checks if POST_NOTIFICATIONS is granted (always true on API < 33).
  static Future<bool> checkNotificationPermission() async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('checkNotificationPermission');
      return granted ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Triggers the system POST_NOTIFICATIONS permission dialog (API 33+).
  /// No-op on older Android. The dialog is asynchronous — re-check status
  /// after this call to learn the user's choice.
  static Future<void> requestNotificationPermission() async {
    try {
      await _channel.invokeMethod('requestNotificationPermission');
    } catch (_) {
      // ignore
    }
  }

  /// True when NEARBY_WIFI_DEVICES is granted (or API < 33 — implicit grant).
  /// Required on Android 13+ for `WifiInfo.ssid` to return the real SSID
  /// instead of `<unknown ssid>`.
  static Future<bool> checkNearbyWifiPermission() async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('checkNearbyWifiPermission');
      return granted ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Triggers the system NEARBY_WIFI_DEVICES permission dialog (API 33+).
  /// No-op on older Android. Async — re-check status after.
  static Future<void> requestNearbyWifiPermission() async {
    try {
      await _channel.invokeMethod('requestNearbyWifiPermission');
    } catch (_) {
      // ignore
    }
  }

  /// True when ACCESS_BACKGROUND_LOCATION (API 29+) is granted, или
  /// ACCESS_FINE_LOCATION (API 28-) на старых Android. Required для чтения
  /// `WifiInfo` из foreground service — sing-box `wifi_ssid`/`wifi_bssid`
  /// rules не сматчатся без этого permission.
  static Future<bool> checkBackgroundLocationPermission() async {
    try {
      final granted = await _channel
          .invokeMethod<bool>('checkBackgroundLocationPermission');
      return granted ?? true;
    } catch (_) {
      return true;
    }
  }

  /// §051 Phase 2 — read current Wi-Fi SSID/BSSID для editor'а.
  /// Возвращает один из:
  /// - `WifiInfoSuccess(ssid, bssid)` — Wi-Fi подключён, permissions есть.
  /// - `WifiInfoError(reason)` — `permission_missing` / `no_wifi` /
  ///   `unknown_ssid` / `runtime_error`.
  /// `bssid` lower-case `xx:xx:xx:xx:xx:xx`.
  static Future<WifiInfoResult> getCurrentWifiInfo() async {
    try {
      final raw = await _channel
          .invokeMapMethod<String, dynamic>('getCurrentWifiInfo');
      if (raw == null) {
        return const WifiInfoResult.error('runtime_error');
      }
      final error = raw['error'] as String?;
      if (error != null) {
        return WifiInfoResult.error(error);
      }
      final ssid = raw['ssid'] as String?;
      final bssid = raw['bssid'] as String?;
      if (ssid == null || ssid.isEmpty) {
        return const WifiInfoResult.error('unknown_ssid');
      }
      return WifiInfoResult.success(ssid: ssid, bssid: bssid ?? '');
    } catch (_) {
      return const WifiInfoResult.error('runtime_error');
    }
  }
}

/// §051 Phase 2 — результат чтения текущей Wi-Fi сети.
sealed class WifiInfoResult {
  const WifiInfoResult();

  const factory WifiInfoResult.success({
    required String ssid,
    required String bssid,
  }) = WifiInfoSuccess;

  const factory WifiInfoResult.error(String reason) = WifiInfoError;
}

class WifiInfoSuccess extends WifiInfoResult {
  const WifiInfoSuccess({required this.ssid, required this.bssid});
  final String ssid;
  final String bssid;
}

class WifiInfoError extends WifiInfoResult {
  const WifiInfoError(this.reason);
  /// One of: `permission_missing`, `no_wifi`, `unknown_ssid`, `runtime_error`.
  final String reason;
}
