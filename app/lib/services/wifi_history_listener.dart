import 'package:flutter/services.dart';

import 'settings_storage.dart';

/// §051 Phase 3 — слушает MethodChannel `onWifiSeen` от native side
/// (`WifiNetworkObserver` → `WifiHistoryBridge`) и пишет в
/// `wifi_history` через [SettingsStorage].
///
/// Native эмитит событие ровно когда юзер пробыл на сети
/// ≥ 60 сек (`STICKINESS_THRESHOLD_MS`). Здесь просто idempotent
/// upsert — `addToWifiHistory` обновит `last_seen` если запись уже есть,
/// иначе добавит новую (cap 50, evict oldest).
///
/// Init из `main.dart` ровно ОДИН раз на process. Гейтинг observer'а
/// (start/stop через `auto_record_wifi_history`) живёт в [start]/[stop]
/// которые дёргаются из UI toggle (Diagnostics tab).
class WifiHistoryListener {
  WifiHistoryListener._();

  static final WifiHistoryListener I = WifiHistoryListener._();

  static const _channel = MethodChannel('com.leadaxe.lxbox/wifi_history');
  static const _utilsChannel = MethodChannel('com.leadaxe.lxbox/utils');

  bool _initialized = false;

  /// Подписаться на native callback. Вызывается ОДИН раз при init app
  /// (`main.dart`). Native side эмитит событие только когда observer
  /// зарегистрирован через [setEnabled] — без enable никаких events.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onWifiSeen') return;
      final args = (call.arguments as Map?)?.cast<String, dynamic>();
      if (args == null) return;
      final ssid = (args['ssid'] as String?) ?? '';
      final bssid = (args['bssid'] as String?) ?? '';
      if (ssid.isEmpty) return;
      await SettingsStorage.addToWifiHistory(ssid, bssid);
    });

    // Sync native observer state со storage flag на старте app. Без
    // этого после reboot / process restart observer был бы stopped до
    // следующего toggle в UI.
    final enabled = await SettingsStorage.getAutoRecordWifi();
    if (enabled) {
      await setEnabled(true);
    }
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
