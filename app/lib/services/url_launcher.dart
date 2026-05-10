import 'package:flutter/services.dart';

/// Opens a URL using the platform's default handler.
/// Falls back to copying to clipboard if the platform channel is unavailable.
class UrlLauncher {
  UrlLauncher._();

  static const _channel = MethodChannel('com.leadaxe.lxbox/utils');

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
}
