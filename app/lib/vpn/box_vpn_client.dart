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

  /// Request VPN stop. **Blocks** (on native side) until `setStatus(Stopped)`
  /// реально отработал — cleanup libbox + broadcast Stopped. Returns true on
  /// success, false on 5-second timeout. Позволяет caller'у безопасно делать
  /// `await stopVPN()` → `await startVPN()` без гонки в `onStartCommand`
  /// (guard там `if (status != Stopped) silent return`).
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

  /// Whether notifications are allowed for this app. На Android 13+ требует
  /// runtime-permission POST_NOTIFICATIONS; без неё foreground service
  /// работает, но нотификация не рендерится — OS охотнее throttle'ит FGS,
  /// юзер не видит статус.
  Future<bool> areNotificationsEnabled() async {
    final ok = await _methods.invokeMethod<bool>('areNotificationsEnabled');
    return ok ?? false;
  }

  /// Open per-app notification settings (API 26+). Falls back to app details
  /// на старых версиях / если прямого экрана нет.
  Future<bool> openNotificationSettings() async {
    final ok = await _methods.invokeMethod<bool>('openNotificationSettings');
    return ok ?? false;
  }

  /// Background mode controls tunnel pause/wake behavior:
  ///   "never"  — tunnel всегда активен (default)
  ///   "lazy"   — pause при deep Doze (экономия в ночном режиме)
  ///   "always" — pause при screen off (максимум экономии батареи)
  /// Смена режима вступает в силу при следующем подключении VPN.
  Future<String> getBackgroundMode() async {
    final m = await _methods.invokeMethod<String>('getBackgroundMode');
    return m ?? 'never';
  }

  Future<void> setBackgroundMode(String mode) async {
    await _methods.invokeMethod<void>('setBackgroundMode', {'mode': mode});
  }

  /// Stream of status events: {"status": "Started"|"Starting"|"Stopped"|"Stopping"}
  ///
  /// **Важно:** shared broadcast stream, один `receiveBroadcastStream()` на
  /// весь lifecycle клиента. Раньше getter возвращал свежий stream на каждый
  /// вызов — каждое обращение создавало новый Dart `StreamController`, что
  /// дёргало `EventChannel.onListen` на native-стороне. В `VpnPlugin`
  /// `statusSink` — одно mutable поле, и последний `onListen` перезаписывал
  /// его, а следующий `onCancel` (при завершении короткоживущей подписки,
  /// напр. `firstWhere` в `reconnect`) обнулял — после этого **основной**
  /// listener в `HomeController._statusSub` становился зомби: Dart-сторона
  /// считает что подписан, native-сторона давно выбросила sink и никуда
  /// больше не шлёт. Все последующие broadcast'ы в сессии терялись —
  /// отсюда reconnect без сброса `configStaleSinceStart`, сломанные
  /// heartbeat-обновления и т.д.
  ///
  /// `asBroadcastStream()` даёт один underlying controller с несколькими
  /// Dart-listener'ами; `late final` кэширует его. `onListen` на native
  /// вызывается ровно один раз, `statusSink` стабилен.
  late final Stream<Map<String, dynamic>> _statusStream =
      _statusEvents.receiveBroadcastStream().map((event) {
    if (event is Map) return Map<String, dynamic>.from(event);
    return <String, dynamic>{};
  }).asBroadcastStream();

  Stream<Map<String, dynamic>> get onStatusChanged => _statusStream;
}
