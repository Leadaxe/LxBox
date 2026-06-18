import 'package:flutter/services.dart';

import 'platform_channels.dart';
import 'settings_storage.dart';

/// §051 Phase 3 — слушает MethodChannel `onWifiSeen` от native side
/// (`WifiNetworkObserver` → `WifiHistoryBridge`) и пишет в
/// `wifi_history` через [SettingsStorage].
///
/// Native эмитит событие ровно когда юзер пробыл на сети ≥ 5 мин
/// (`WifiNetworkObserver.STICKINESS_THRESHOLD_MS`). Здесь просто
/// idempotent upsert — `addToWifiHistory` обновит `last_seen` если
/// запись уже есть, иначе добавит новую (cap 50, evict oldest).
///
/// Lifecycle:
/// - [init] подписывает MethodChannel handler + sync'ит native observer
///   state со storage flag (через [setEnabled]). Идемпотентен — повторный
///   вызов no-op. Вызывается из `main.dart` ровно при app init.
/// - [dispose] снимает handler и переводит native observer в stopped.
///   Process-scope, обычно никогда не дёргается — но pattern существует
///   для тестов и для будущего fork'а (например, separate isolate).
/// - [setEnabled] toggle native observer (через `setAutoRecordWifi`
///   MethodChannel). Дёргается из UI toggle (Diagnostics) и из [init]
///   при auto-sync на старте.
class WifiHistoryListener {
  WifiHistoryListener._();

  static final WifiHistoryListener I = WifiHistoryListener._();

  static const _channel = MethodChannel(PlatformChannels.wifiHistory);
  static const _utilsChannel = MethodChannel(PlatformChannels.utils);

  bool _initialized = false;

  /// Подписаться на native callback + sync state со storage flag.
  /// Idempotent — second call no-op.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_onCall);

    // Sync native observer state со storage flag на старте app. Без
    // этого после reboot / process restart observer был бы stopped до
    // следующего toggle в UI.
    final enabled = await SettingsStorage.getAutoRecordWifi();
    if (enabled) {
      await setEnabled(true);
    }
  }

  /// Отписаться от MethodChannel + stop native observer. По умолчанию
  /// не нужен (process-scope listener), но pattern для тестов.
  Future<void> dispose() async {
    if (!_initialized) return;
    _initialized = false;
    _channel.setMethodCallHandler(null);
    await setEnabled(false);
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'onWifiSeen') return null;
    final args = (call.arguments as Map?)?.cast<String, dynamic>();
    if (args == null) return null;
    final ssid = (args['ssid'] as String?) ?? '';
    final bssid = (args['bssid'] as String?) ?? '';
    if (ssid.isEmpty) return null;
    await SettingsStorage.addToWifiHistory(ssid, bssid);
    return null;
  }

  /// Toggle ON/OFF. Native side зарегистрирует/снимет
  /// `ConnectivityManager.NetworkCallback`. Идемпотентен.
  Future<void> setEnabled(bool enabled) async {
    try {
      await _utilsChannel.invokeMethod(
        'setAutoRecordWifi',
        {'enable': enabled},
      );
    } catch (_) {
      // ignore — на старых Android могут быть рантайм-ошибки;
      // history просто не будет расти, manual flow продолжит работать.
    }
  }
}
