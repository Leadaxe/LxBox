import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import '../models/app_info.dart';
import '../models/background_mode.dart';
import '../models/tunnel_status.dart';
import '../services/app_log.dart';

/// Thin Dart wrapper над native MethodChannel/EventChannel для VPN-control.
/// Заменяет внешний `flutter_singbox_vpn` plugin.
///
/// **Контракт типов:** все публичные методы возвращают типизированные
/// модели (`TunnelStatus`, `BackgroundMode`, `AppInfo`) — парсинг строк из
/// native происходит внутри клиента, не пробивает сквозь callsite'ы.
///
/// **Timeout policy:** каждый MethodChannel-вызов обёрнут в `.timeout()` с
/// per-метода-настроенным значением (см. [_Timeouts]). На таймауте — лог
/// в `AppLog` + safe-default fallback (например `tunnel: disconnected` для
/// `getVpnStatus`). Это нужно потому что мы видели реальные deadlock'и где
/// native не отвечал на запрос — без таймаута Flutter UI блокировался.
///
/// **Singleton + DI:** доступ через [BoxVpnClient.I]. Для юнит-тестов —
/// [BoxVpnClient.forTest] с инжектируемыми channel'ами. Default
/// конструктор `BoxVpnClient()` тоже возвращает singleton для совместимости
/// с существующими callsite'ами.
class BoxVpnClient {
  /// Default конструктор — alias для [I]. Сохранён для обратной совместимости
  /// (12+ callsite'ов в коде используют `BoxVpnClient()`). Новый код
  /// предпочтительнее использует `BoxVpnClient.I` явно.
  factory BoxVpnClient() => I;

  BoxVpnClient._({MethodChannel? methods, EventChannel? events})
      : _methods = methods ?? const MethodChannel(_kMethodsChannel),
        _events = events ?? const EventChannel(_kStatusChannel);

  /// Production singleton. По стилю `AppLog.I`, `HapticService.I`.
  static final BoxVpnClient I = BoxVpnClient._();

  /// Тестовая фабрика — позволяет инжектировать mock channel'ы. В production
  /// не использовать.
  @visibleForTesting
  factory BoxVpnClient.forTest({
    MethodChannel? methods,
    EventChannel? events,
  }) =>
      BoxVpnClient._(methods: methods, events: events);

  static const _kMethodsChannel = 'com.leadaxe.lxbox/methods';
  static const _kStatusChannel = 'com.leadaxe.lxbox/status_events';

  final MethodChannel _methods;
  final EventChannel _events;

  // ---------------------------------------------------------------------------
  // Config
  // ---------------------------------------------------------------------------

  /// Save sing-box JSON config to native storage.
  Future<bool> saveConfig(String config) async {
    final ok = await _invoke<bool>(
      _Methods.saveConfig,
      args: {'config': config},
      timeout: _Timeouts.config,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  /// Read current config from native storage. Empty fallback `{}` чтобы
  /// caller (Builder) мог parse'ить без null-проверок.
  Future<String> getConfig() async {
    final cfg = await _invoke<String>(
      _Methods.getConfig,
      timeout: _Timeouts.config,
      onTimeoutValue: '{}',
    );
    return cfg ?? '{}';
  }

  // ---------------------------------------------------------------------------
  // VPN lifecycle
  // ---------------------------------------------------------------------------

  /// Request VPN start (may trigger system permission dialog).
  Future<bool> startVPN() async {
    final ok = await _invoke<bool>(
      _Methods.startVPN,
      timeout: _Timeouts.startVpn,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  /// Request VPN stop. **Блокирующий** на native до `setStatus(Stopped)` —
  /// cleanup libbox + broadcast Stopped. Возвращает true on success, false
  /// on таймаут. Позволяет caller'у безопасно делать `await stopVPN()` →
  /// `await startVPN()` без race в `onStartCommand` (guard там
  /// `if (status != Stopped) silent return`).
  Future<bool> stopVPN() async {
    final ok = await _invoke<bool>(
      _Methods.stopVPN,
      timeout: _Timeouts.stopVpn,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  /// Pull-запрос текущего статуса. Нужен на init — `onStatusChanged` шлёт
  /// только переходы; если Flutter-процесс перезапустился, а сервис всё ещё
  /// `Started` — без явного pull'а UI останется в `Disconnected`.
  ///
  /// Парсинг raw-string'а в `TunnelStatus` — здесь, downstream работает с
  /// typed enum. На неизвестный raw → `unknown`, на null/timeout → `disconnected`
  /// (defensive, чтобы UI не залип).
  Future<TunnelStatus> getVpnStatus() async {
    final s = await _invoke<String>(
      _Methods.getVpnStatus,
      timeout: _Timeouts.status,
      onTimeoutValue: null,
    );
    if (s == null || s.isEmpty) return TunnelStatus.disconnected;
    return TunnelStatus.fromNative(s);
  }

  // ---------------------------------------------------------------------------
  // Notification + auto-start
  // ---------------------------------------------------------------------------

  /// Set foreground-service notification title.
  Future<bool> setNotificationTitle(String title) async {
    final ok = await _invoke<bool>(
      _Methods.setNotificationTitle,
      args: {'title': title},
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  Future<bool> setAutoStart(bool enabled) async {
    final ok = await _invoke<bool>(
      _Methods.setAutoStart,
      args: {'enabled': enabled},
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  Future<bool> getAutoStart() async {
    final ok = await _invoke<bool>(
      _Methods.getAutoStart,
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  Future<bool> setKeepOnExit(bool enabled) async {
    final ok = await _invoke<bool>(
      _Methods.setKeepOnExit,
      args: {'enabled': enabled},
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  Future<bool> getKeepOnExit() async {
    final ok = await _invoke<bool>(
      _Methods.getKeepOnExit,
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  /// §043: forward sing-box логов в наш AppLog как `DebugSource.core`.
  /// Default false. Изменение применяется только после restart Service'а
  /// (Libbox.setup читает значение один раз при инициализации).
  Future<bool> setCoreLogsEnabled(bool enabled) async {
    final ok = await _invoke<bool>(
      _Methods.setCoreLogsEnabled,
      args: {'enabled': enabled},
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  Future<bool> getCoreLogsEnabled() async {
    final ok = await _invoke<bool>(
      _Methods.getCoreLogsEnabled,
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  /// §043 follow-up: завершает Android-процесс целиком (`finishAffinity` +
  /// `killProcess`). Используется кнопкой «Quit & reopen app» рядом с toggle
  /// «Forward sing-box logs» — там флаг `debug` в `Libbox.setup` читается
  /// ровно один раз за жизнь процесса, и единственный способ применить
  /// изменение — рестарт процесса. Возврат сразу true (process die через
  /// ~250ms), Future в общем случае не ресолвится — Android уже не отвечает.
  Future<void> quitApp() async {
    await _invoke<bool>(
      _Methods.quitApp,
      timeout: const Duration(milliseconds: 500),
      onTimeoutValue: true,
    );
  }

  // ---------------------------------------------------------------------------
  // App enumeration (для per-app routing)
  // ---------------------------------------------------------------------------

  /// Список установленных приложений — lightweight metadata, **без** иконок
  /// (они тяжёлые; для tile'а грузятся lazy через [getAppIcon] / [getAppInfo]).
  Future<List<AppInfo>> getInstalledApps() async {
    final result = await _invoke<List<dynamic>>(
      _Methods.getInstalledApps,
      timeout: _Timeouts.apps,
      onTimeoutValue: const <dynamic>[],
    );
    if (result == null) return const [];
    return result
        .map((e) => AppInfo.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Fetch a single app icon as base64-encoded PNG. Empty string on failure
  /// (package not found, cannot render icon).
  Future<String> getAppIcon(String packageName) async {
    final s = await _invoke<String>(
      _Methods.getAppIcon,
      args: {'packageName': packageName},
      timeout: _Timeouts.app,
      onTimeoutValue: '',
    );
    return s ?? '';
  }

  /// Полные метаданные одного app'а одним native-call'ом. `null` если package
  /// не установлен.
  Future<AppInfo?> getAppInfo(String packageName) async {
    final r = await _invoke<Map<dynamic, dynamic>>(
      _Methods.getAppInfo,
      args: {'packageName': packageName},
      timeout: _Timeouts.app,
      onTimeoutValue: null,
    );
    if (r == null) return null;
    return AppInfo.fromMap(Map<String, dynamic>.from(r));
  }

  // ---------------------------------------------------------------------------
  // System settings (battery / notifications / app details)
  // ---------------------------------------------------------------------------

  /// Whether app is whitelisted from battery optimization (Doze/App Standby).
  Future<bool> isIgnoringBatteryOptimizations() async {
    final ok = await _invoke<bool>(
      _Methods.isIgnoringBatteryOptimizations,
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  /// Open system dialog / settings page для whitelist'а от battery opt'а.
  Future<bool> openBatteryOptimizationSettings() async {
    final ok = await _invoke<bool>(
      _Methods.openBatteryOptimizationSettings,
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  /// Open per-app Settings page (OEM Autostart/Background activity/Battery).
  Future<bool> openAppDetailsSettings() async {
    final ok = await _invoke<bool>(
      _Methods.openAppDetailsSettings,
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  /// Whether notifications are allowed for this app. На Android 13+ требует
  /// runtime-permission POST_NOTIFICATIONS; без неё foreground service
  /// работает, но нотификация не рендерится — OS охотнее throttle'ит FGS,
  /// юзер не видит статус.
  Future<bool> areNotificationsEnabled() async {
    final ok = await _invoke<bool>(
      _Methods.areNotificationsEnabled,
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  /// Open per-app notification settings (API 26+).
  Future<bool> openNotificationSettings() async {
    final ok = await _invoke<bool>(
      _Methods.openNotificationSettings,
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  // ---------------------------------------------------------------------------
  // Background mode (pause/wake)
  // ---------------------------------------------------------------------------

  /// Background mode — описание режимов в [BackgroundMode]. Смена вступает в
  /// силу при следующем подключении VPN.
  Future<BackgroundMode> getBackgroundMode() async {
    final m = await _invoke<String>(
      _Methods.getBackgroundMode,
      timeout: _Timeouts.settings,
      onTimeoutValue: null,
    );
    return BackgroundMode.fromNative(m);
  }

  Future<void> setBackgroundMode(BackgroundMode mode) async {
    await _invoke<void>(
      _Methods.setBackgroundMode,
      args: {'mode': mode.wireValue},
      timeout: _Timeouts.settings,
      onTimeoutValue: null,
    );
  }

  // ---------------------------------------------------------------------------
  // Quick Connect (spec 032)
  // ---------------------------------------------------------------------------

  /// Попросить систему добавить QS tile в шторку (API 33+). Возвращает короткий
  /// статус-стринг от native:
  ///   - `added` / `already` / `dismissed` — нормальный исход prompt'а
  ///   - `unsupported` — устройство ниже API 33, юзеру показываем текстовую
  ///     инструкцию вместо кнопки
  ///   - `no_activity` / `error: ...` — внутренние сбои
  Future<String> requestAddTile() async {
    final s = await _invoke<String>(
      _Methods.requestAddTile,
      timeout: _Timeouts.requestTile,
      onTimeoutValue: 'error: timeout',
    );
    return s ?? 'error: null';
  }

  // ---------------------------------------------------------------------------
  // Diagnostics / introspection
  // ---------------------------------------------------------------------------

  /// Версия sing-box core (libbox) — статический Go-side метод
  /// `Libbox.version()`. Возвращает строку вида `"1.13.11"`. Используется в
  /// About screen чтобы юзер видел какое именно core встроено.
  /// Empty string на ошибку/timeout — caller рендерит fallback.
  Future<String> getCoreVersion() async {
    final v = await _invoke<String>(
      _Methods.getCoreVersion,
      timeout: _Timeouts.settings,
      onTimeoutValue: '',
    );
    return v ?? '';
  }

  /// Recovery action: in-place reload box runtime через
  /// `CommandServer.startOrReloadService`. **Не убивает** Android Service —
  /// быстрее чем full disconnect/connect, tunnel дропается на ~3 сек. См.
  /// [§030](../docs/spec/tasks/030-vpn-reload-button.md).
  Future<bool> reloadVPN() async {
    final ok = await _invoke<bool>(
      _Methods.reloadVPN,
      timeout: _Timeouts.reload,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  /// Recovery action (experimental): `commandServer.resetNetwork()` →
  /// `box.Router().ResetNetwork()` — переустанавливает network sub-state
  /// (outbound bindings, DNS upstream tracking) **без recreate'а runtime**.
  /// Должно быть truly gentle (in-flight TCP не дропаются), но семантика
  /// требует экспериментальной верификации. См.
  /// [§031](../docs/spec/tasks/031-reset-network-api.md).
  Future<bool> resetNetwork() async {
    final ok = await _invoke<bool>(
      _Methods.resetNetwork,
      timeout: _Timeouts.resetNet,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  // ---------------------------------------------------------------------------
  // Status stream
  // ---------------------------------------------------------------------------

  /// Stream of typed status events. Native шлёт Map с обязательным `status`
  /// и опциональными reason-полями; парсим в `TunnelStatusEvent` тут — UI
  /// работает с typed-объектом.
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
  late final Stream<TunnelStatusEvent> _statusStream =
      _events.receiveBroadcastStream().map((event) {
    if (event is Map) return TunnelStatusEvent.fromNative(event);
    return TunnelStatusEvent.unknownEmpty;
  }).asBroadcastStream();

  Stream<TunnelStatusEvent> get onStatusChanged => _statusStream;

  // ---------------------------------------------------------------------------
  // Internal — invoke helper (timeout + error logging)
  // ---------------------------------------------------------------------------

  /// Обёртка для `MethodChannel.invokeMethod` с явным timeout'ом и логированием.
  /// На таймауте → возвращает [onTimeoutValue], логирует `AppLog.error` с
  /// именем method'а. На любое другое исключение → пробрасывает (caller
  /// решает что делать; `Future.error` нормально доходит до `try/catch`).
  Future<T?> _invoke<T>(
    String method, {
    Map<String, dynamic>? args,
    required Duration timeout,
    required T? onTimeoutValue,
  }) async {
    try {
      return await _methods
          .invokeMethod<T>(method, args)
          .timeout(timeout);
    } on TimeoutException {
      AppLog.I.error(
        'BoxVpnClient: $method timed out after ${timeout.inSeconds}s',
      );
      return onTimeoutValue;
    }
  }
}

// -----------------------------------------------------------------------------
// Method-name константы — централизованный контракт с `VpnPlugin.kt`.
// Зеркало `case "X" in handleMethodCall(...)` Kotlin handler'а. Опечатки в
// одном месте поймаются при review, не silently break MethodChannel.
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

// -----------------------------------------------------------------------------
// Timeout-константы для MethodChannel-вызовов. Подбирались с учётом:
//   - максимально допустимого времени native'а на ответ
//   - critical path'а (init blocking risk → короче)
//   - запаса на медленные devices (Android 8/9 на бюджетных чипах)
// -----------------------------------------------------------------------------

class _Timeouts {
  const _Timeouts._();

  /// `getVpnStatus` — на init HomeController блокирует UI. Native handler
  /// дёшев (читает поле). 3s — щедро.
  static const status = Duration(seconds: 3);

  /// `startVPN` — libbox.setup + Libbox.newService на старте могут занять
  /// 5-15s на slow devices. 30s — щедрый headroom.
  static const startVpn = Duration(seconds: 30);

  /// `stopVPN` — блокирующий до `setStatus(Stopped)`. Cleanup libbox обычно
  /// 1-3s. 10s — defensive.
  static const stopVpn = Duration(seconds: 10);

  /// Config save/load — file IO, быстро. 5s покрывает worst-case Android
  /// storage latency.
  static const config = Duration(seconds: 5);

  /// `getInstalledApps` — на старых devices список 200+ apps занимает 5-10s.
  /// 15s — headroom.
  static const apps = Duration(seconds: 15);

  /// Per-app fetch (icon/info) — 5s достаточно.
  static const app = Duration(seconds: 5);

  /// Settings methods (battery/notifications/auto-start) — щедрые 3s, обычно
  /// мгновенные.
  static const settings = Duration(seconds: 3);

  /// `requestAddTile` — system dialog может задержать. 10s.
  static const requestTile = Duration(seconds: 10);

  /// `reloadVPN` — sing-box recreates box runtime (~3s) внутри CommandServer.
  /// Запас на slow devices.
  static const reload = Duration(seconds: 10);

  /// `resetNetwork` — лёгкий reset, должен быть мгновенным. Запас.
  static const resetNet = Duration(seconds: 5);
}
