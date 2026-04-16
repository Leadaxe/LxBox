import 'package:flutter/services.dart';

/// Opens a URL using the platform's default handler.
/// Falls back to copying to clipboard if the platform channel is unavailable.
class UrlLauncher {
  UrlLauncher._();

  static const _channel = MethodChannel('com.leadaxe.boxvpn/utils');

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
}
