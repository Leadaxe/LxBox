import 'dart:async';

import 'package:flutter/services.dart';

import 'settings_storage.dart';

/// Тактильный отклик на ключевые VPN-события (§029 спека).
///
/// Event-based API — звонящие говорят **что случилось**, сервис решает
/// **какая интенсивность**. Если UX окажется агрессивным, легко поменять
/// один маппинг здесь, не трогая callsites.
///
/// Платформенные вызовы no-op'ятся автоматически если:
/// - юзер выключил haptic в системе (Android Touch feedback);
/// - устройство без вибро-мотора;
/// - эмулятор без feedback;
/// - наш `enabled = false`.
///
/// Singleton-инстанс [I] создаётся один раз и шарится между controllers.
/// Mutable `enabled` позволяет toggle'ить из Settings без ChangeNotifier.
class HapticService {
  HapticService({this.enabled = true, this.throttle = const Duration(milliseconds: 100)});

  static final HapticService I = HapticService();

  /// Меняется напрямую из AppSettingsScreen — никаких listener'ов не нужно,
  /// следующее событие просто прочитает новое значение.
  bool enabled;
  final Duration throttle;
  DateTime _lastFired = DateTime.fromMillisecondsSinceEpoch(0);

  /// Прочитать сохранённое значение из prefs. Зовётся в `main` или
  /// `HomeScreen.initState` один раз. Default = true, если ключа нет.
  Future<void> loadFromPrefs() async {
    final v = await SettingsStorage.getVar(prefsKey, 'true');
    enabled = v != 'false';
  }

  static const String prefsKey = 'haptic_enabled';

  // ─── Event-based API ───
  // Tap-events (UI-подтверждение нажатия)
  void onConnectTap() => _fire(HapticFeedback.selectionClick);
  void onNodeSelect() => _fire(HapticFeedback.selectionClick);

  // Success/готовность
  void onVpnConnected() => _fire(HapticFeedback.mediumImpact);
  void onVpnDisconnected() => _fire(HapticFeedback.lightImpact);
  void onFetchSuccess() => _fire(HapticFeedback.lightImpact);
  void onPresetApply() => _fire(HapticFeedback.mediumImpact);

  // Внимание / ошибки
  void onVpnCrashed() => _fire(HapticFeedback.heavyImpact);
  void onHeartbeatFail() => _fire(HapticFeedback.heavyImpact);
  void onFetchError() => _fire(HapticFeedback.mediumImpact);

  void _fire(Future<void> Function() impact) {
    if (!enabled) return;
    final now = DateTime.now();
    if (now.difference(_lastFired) < throttle) return;
    _lastFired = now;
    unawaited(impact());
  }
}
