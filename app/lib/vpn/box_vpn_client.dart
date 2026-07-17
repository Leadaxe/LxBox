import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import '../models/app_info.dart';
import '../models/background_mode.dart';
import '../models/memory_limit_setting.dart';
import '../models/tunnel_status.dart';
import '../services/app_log.dart';
import '../services/l10n/app_language_reconcile.dart'
    show AppLanguageNativeState;
import '../services/platform_channels.dart';

// Method-name + timeout константы вынесены `part`'ами (та же библиотека, тот же
// приватный доступ к `_Methods` / `_Timeouts` из [BoxVpnClient]).
part 'box_vpn_client/method_names.dart';
part 'box_vpn_client/timeouts.dart';

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

  // §141 P2.4e — алиасы на централизованные имена (`PlatformChannels`).
  static const _kMethodsChannel = PlatformChannels.methods;
  static const _kStatusChannel = PlatformChannels.statusEvents;

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

  /// §165 — headless-старт без Activity/consent (Debug API / automation).
  /// Работает ТОЛЬКО если VPN-разрешение уже выдано. Возвращает
  /// `(started, needsConsent)`: started=false+needsConsent=true → разрешения
  /// нет, нужен ручной старт из UI.
  Future<({bool started, bool needsConsent})> startVpnHeadless() async {
    final r = await _invoke<Map<dynamic, dynamic>>(
      _Methods.startVpnHeadless,
      timeout: _Timeouts.startVpn,
      onTimeoutValue: const {'started': false, 'needs_consent': false},
    );
    return (
      started: r?['started'] == true,
      needsConsent: r?['needs_consent'] == true,
    );
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

  /// §129 — **жёсткая** остановка для случая, когда ядро зависло вхолостую
  /// (detour AWG→WG, #2): dial наружу заклинило, `setStatus(Stopped)` не
  /// приходит, обычный [stopVPN] виснет на teardown и не убивает VpnService.
  /// Fire-and-forget: native шлёт broadcast и сразу отвечает — `doForceStop`
  /// делает `stopSelf()` не дожидаясь ядра, teardown идёт фоном best-effort.
  /// Звать в точке таймаута `_armTransientTimeout`, НЕ вместо обычного stop.
  Future<bool> forceStopVPN() async {
    final ok = await _invoke<bool>(
      _Methods.forceStopVPN,
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  /// Pull-запрос текущего статуса. Нужен на init — `onStatusChanged` шлёт
  /// только переходы; если Flutter-процесс перезапустился, а сервис всё ещё
  /// `Started` — без явного pull'а UI останется в `Disconnected`.
  ///
  /// Парсинг ответа в `TunnelStatus` — здесь, downstream работает с typed enum.
  /// На неизвестный raw → `unknown`, на null/timeout → `disconnected`
  /// (defensive, чтобы UI не залип).
  ///
  /// §276 — native отдаёт `{"status": ..., "revoked": bool}`: голого статуса
  /// мало, `Stopped` после перехвата слота чужим VPN надо отличать от штатного
  /// стопа. String-ветка — совместимость со старым native (например, engine
  /// пере-attach'ился к сервису, поднятому до обновления).
  Future<TunnelStatus> getVpnStatus() async {
    final res = await _invoke<Object>(
      _Methods.getVpnStatus,
      timeout: _Timeouts.status,
      onTimeoutValue: null,
    );
    if (res is Map) {
      final s = res['status']?.toString() ?? '';
      if (s.isEmpty) return TunnelStatus.disconnected;
      return TunnelStatus.fromNative(s, revoked: res['revoked'] == true);
    }
    final s = res?.toString() ?? '';
    if (s.isEmpty) return TunnelStatus.disconnected;
    return TunnelStatus.fromNative(s);
  }

  /// true, если прямо сейчас активен VPN другого приложения. UI спрашивает
  /// перед ручным стартом, чтобы предложить «переключиться?» вместо молчаливого
  /// отзыва чужого туннеля. При недоступности/таймауте → false (не блокируем старт).
  Future<bool> isForeignVpnActive() async {
    final r = await _invoke<bool>(
      _Methods.isForeignVpnActive,
      timeout: _Timeouts.status,
      onTimeoutValue: false,
    );
    return r ?? false;
  }

  /// §187 — прошедшие мс с реального старта туннеля (native companion,
  /// переживает swipe). 0 = не запущен / только что стартовал. Dart на
  /// cold-start вычисляет честный `connectedSince = now - uptime`, не обнуляя
  /// таймер на «сейчас». Монотонные часы (elapsedRealtime).
  Future<int> getTunnelUptimeMs() async {
    final ms = await _invoke<int>(
      _Methods.getTunnelUptimeMs,
      timeout: _Timeouts.status,
      onTimeoutValue: null,
    );
    return ms ?? 0;
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

  /// §123 — set foreground-service notification text (подтекст: тег активной
  /// ноды / route.final). Пустая строка → native fallback на статус.
  Future<bool> setNotificationText(String text) async {
    final ok = await _invoke<bool>(
      _Methods.setNotificationText,
      args: {'text': text},
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

  /// §049 F15: разрешать app'ам обходить tun (`Builder.allowBypass()`).
  /// Default false (strict tunnel). Применяется при следующем старте VPN —
  /// после toggle нужен reload.
  Future<bool> setAllowBypass(bool enabled) async {
    final ok = await _invoke<bool>(
      _Methods.setAllowBypass,
      args: {'enabled': enabled},
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  Future<bool> getAllowBypass() async {
    final ok = await _invoke<bool>(
      _Methods.getAllowBypass,
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  /// §189/§124 — auto_redirect: root-only tproxy (nftables/iptables в sing-tun).
  /// Default false. UI-тоггла нет (root-only), но участвует в зеркале
  /// native_prefs и бэкапе. На не-root устройстве ядро вернёт ошибку при старте.
  Future<bool> setAutoRedirect(bool enabled) async {
    final ok = await _invoke<bool>(
      _Methods.setAutoRedirect,
      args: {'enabled': enabled},
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  Future<bool> getAutoRedirect() async {
    final ok = await _invoke<bool>(
      _Methods.getAutoRedirect,
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  /// §192 — зеркало has_tun (производное от §119 vpn_mode) в native. Гейтит
  /// `VpnService.prepare()`: proxy-режим (false) → prepare не зовётся → чужой
  /// активный VPN не отзывается. Зовётся при смене режима + на старте (sync).
  Future<bool> setHasTun(bool hasTun) async {
    final ok = await _invoke<bool>(
      _Methods.setHasTun,
      args: {'enabled': hasTun},
      timeout: _Timeouts.settings,
      onTimeoutValue: false,
    );
    return ok ?? false;
  }

  /// §069: runtime applied значение `allow_bypass` от последнего
  /// `VpnService.Builder.allowBypass()` вызова в `establish()`. Отличается
  /// от persisted [getAllowBypass] когда юзер поменял toggle но ещё не
  /// reload'нул VPN. Reset в `false` когда VpnService умирает.
  Future<bool> getCurrentSessionAllowBypass() async {
    final ok = await _invoke<bool>(
      _Methods.getCurrentSessionAllowBypass,
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

  /// §109: маркер «таймаут» для [getAppInfo]. Const-канонизированная map —
  /// `identical` отличает её от любого decoded-ответа native (codec всегда
  /// создаёт новые инстансы). Наружу не отдаётся.
  static const Map<dynamic, dynamic> _appInfoTimeoutMarker = <dynamic, dynamic>{
    '__timeout__': true,
  };

  /// Метаданные одного app'а одним native-call'ом — **без иконки** (она
  /// тяжёлая, грузится отдельно через [getAppIcon]).
  ///
  /// Контракт (§109, см. tasks/109):
  ///   - `AppInfo` — пакет установлен;
  ///   - `null`    — native ПОДТВЕРДИЛ «не установлен»
  ///                 (NameNotFoundException → `{"notFound": true}`);
  ///   - throw     — проверить не удалось (TimeoutException /
  ///                 PlatformException) — caller обязан трактовать как
  ///                 retryable, НЕ как «не установлен».
  ///
  /// [timeout] переопределяется только в тестах.
  Future<AppInfo?> getAppInfo(String packageName, {Duration? timeout}) async {
    final r = await _invoke<Map<dynamic, dynamic>>(
      _Methods.getAppInfo,
      args: {'packageName': packageName},
      timeout: timeout ?? _Timeouts.app,
      onTimeoutValue: _appInfoTimeoutMarker,
    );
    if (identical(r, _appInfoTimeoutMarker)) {
      throw TimeoutException('getAppInfo($packageName)');
    }
    if (r == null) {
      // Native по контракту null не шлёт — считаем сбоем канала (retryable).
      throw StateError('getAppInfo($packageName): null reply');
    }
    if (r['notFound'] == true) return null;
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

  /// Open system VPN settings (Settings → VPN). §241 — активный VPN там
  /// помечен «Connected»: единственный zero-permission способ показать,
  /// какое приложение держит VPN-слот (ownerUid чужой сети скрыт системой).
  Future<bool> openVpnSettings() async {
    final ok = await _invoke<bool>(
      _Methods.openVpnSettings,
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
  // Memory limit (§271)
  // ---------------------------------------------------------------------------

  /// Memory limit ядра — wire-значения в [MemoryLimitSetting]. Native применяет
  /// новое значение к работающему ядру немедленно (reloadSetupOptions).
  Future<String> getMemoryLimit() async {
    final v = await _invoke<String>(
      _Methods.getMemoryLimit,
      timeout: _Timeouts.settings,
      onTimeoutValue: null,
    );
    return MemoryLimitSetting.normalize(v);
  }

  Future<void> setMemoryLimit(String value) async {
    await _invoke<void>(
      _Methods.setMemoryLimit,
      args: {'value': MemoryLimitSetting.normalize(value)},
      timeout: _Timeouts.settings,
      onTimeoutValue: null,
    );
  }

  /// §279 — зеркалит выбранный язык приложения (`system|en|ru`) в
  /// `boxvpn_boot`: native-поверхности (шторка, тайл, shortcuts) читают его
  /// без Flutter. Phase 6: native-handler дополнительно пушит LocaleManager
  /// (33+, `system` → пустой список), обновляет `last_pushed_locale` и
  /// перештамповывает все нативные поверхности (канал/шторка/shortcuts/тайл/
  /// локаль ядра). На старом native — notImplemented; caller глотает.
  Future<void> setAppLanguage(String tag) async {
    await _invoke<void>(
      _Methods.setAppLanguage,
      args: {'tag': tag},
      timeout: _Timeouts.settings,
      onTimeoutValue: null,
    );
  }

  /// §279 Phase 6 (спека §6.4) — состояние per-app-локалей для трёхстороннего
  /// reconciliation на старте. null → фича недоступна (API < 33, старый
  /// native, timeout, тест без mock'а) — reconciliation делает no-op.
  Future<AppLanguageNativeState?> getAppLanguageState() async {
    try {
      final r = await _invoke<Object>(
        _Methods.getAppLanguageState,
        timeout: _Timeouts.settings,
        onTimeoutValue: null,
      );
      if (r is! Map || r['supported'] != true) return null;
      return AppLanguageNativeState(
        applicationLocales: r['applicationLocales']?.toString() ?? '',
        lastPushedLocale: r['lastPushedLocale']?.toString(),
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
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

  /// Разбивка памяти процесса приложения (native `Debug.MemoryInfo`). Ядро
  /// sing-box живёт в этом же процессе, поэтому native heap включает его
  /// Go-буферы. Даёт категории, которых нет в CommandClient-статусе (там —
  /// только суммарный RSS). Все значения в байтах. `null` на ошибку/timeout —
  /// caller рендерит fallback.
  Future<MemoryInfo?> getMemoryInfo() async {
    final r = await _invoke<Map<dynamic, dynamic>>(
      _Methods.getMemoryInfo,
      timeout: _Timeouts.settings,
      onTimeoutValue: null,
    );
    if (r == null) return null;
    return MemoryInfo.fromMap(r);
  }

  /// §207 — обобщённый pprof-снимок через встроенный libbox `PProfServer`
  /// (Способ 1): native поднимает pprof-http на loopback по требованию, GET
  /// `/debug/pprof/<pathAndQuery>`, гасит. Один сервер бесплатно отдаёт весь
  /// набор `/debug/pprof/*` → один метод; профиль+query задаёт caller
  /// (напр. `heap?gc=1`, `goroutine?debug=1`, `profile?seconds=10`).
  ///
  /// Возвращает сырые байты (текст-профили = UTF-8, бинарные = pprof `.pb`).
  /// Бросает [PlatformException] (`PPROF_FAILED`) на сетевой/серверной ошибке
  /// (порт занят / pprof уже активен / нет ядра) — caller решает смягчить или
  /// показать. `[blockingSeconds]` >0 для CPU `profile` (держит соединение N
  /// сек) → Dart-таймаут масштабируется. Пустой [Uint8List] на timeout.
  Future<Uint8List> pprofRaw(
    String pathAndQuery, {
    int blockingSeconds = 0,
  }) async {
    // CPU-профиль держит соединение `blockingSeconds`, поэтому Dart-таймаут
    // ДОЛЖЕН масштабироваться и быть БОЛЬШЕ native read-timeout
    // (`seconds*1000 + 5000`, см. VpnPlugin), иначе Dart оборвёт сбор первым
    // и вернёт пустой .pb на длинных профилях. Запас поверх native = ещё 5s.
    // Мгновенные снимки → короткий фиксированный таймаут.
    final timeout = blockingSeconds > 0
        ? Duration(seconds: blockingSeconds + _Timeouts.cpuHeadroomSeconds)
        : _Timeouts.goroutineDump;
    final bytes = await _invoke<Uint8List>(
      _Methods.pprofProfile,
      args: {'pathAndQuery': pathAndQuery},
      timeout: timeout,
      onTimeoutValue: Uint8List(0),
    );
    return bytes ?? Uint8List(0);
  }

  /// §207 — goroutine stack-дамп (полные стеки, `debug=2`). Тонкая обёртка
  /// над [pprofRaw] для DumpBuilder/Debug API: в отличие от счётчика
  /// `CcStatus.goroutines` даёт стеки. **Никогда не бросает** — на ошибке
  /// возвращает фолбэк-текст (`goroutine dump unavailable: ...`).
  Future<String> dumpGoroutines() async {
    try {
      final bytes = await pprofRaw('goroutine?debug=2');
      return bytes.isEmpty
          ? '<goroutine dump unavailable: empty response (timeout?)>'
          // pprof отдаёт UTF-8; allowMalformed чтобы не падать на обрезанном
          // буфере (стек с не-ASCII символами в аргументах фреймов).
          : utf8.decode(bytes, allowMalformed: true);
    } on PlatformException catch (e) {
      return '<goroutine dump unavailable: ${e.message ?? e.code}>';
    }
  }

  /// §207 — CPU-профиль за `durationMs` (default 10s) → pprof `.pb`. Ловит
  /// busy-spin в tight-loop, который один goroutine-снимок может упустить.
  /// Бросает [PlatformException] (`PPROF_FAILED`). Пустой [Uint8List] на timeout.
  Future<Uint8List> captureCpuProfile({int durationMs = 10000}) async {
    final seconds = (durationMs ~/ 1000).clamp(1, 60);
    return pprofRaw('profile?seconds=$seconds', blockingSeconds: seconds);
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

  /// §263 — сбросить DNS-кэш ядра: удалить `cache.db` (FakeIP-аллокации +
  /// DNS RDRC). При работающем туннеле native затем reload'ит рантайм
  /// (`serviceReload` → ядро пересоздаёт чистый cache.db, тоннель дропается
  /// ~3с); при выключенном VPN — только удаление файла (чистый создастся на
  /// следующем старте). См. `docs/spec/tasks/263-clear-dns-cache.md`.
  Future<bool> clearDnsCache() async {
    final ok = await _invoke<bool>(
      _Methods.clearDnsCache,
      timeout: _Timeouts.dnsCache,
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
  /// отсюда reconnect без сброса `configChangedNeedRestart`, сломанные
  /// heartbeat-обновления и т.д.
  ///
  /// `asBroadcastStream()` даёт один underlying controller с несколькими
  /// Dart-listener'ами; `late final` кэширует его. `onListen` на native
  /// вызывается ровно один раз, `statusSink` стабилен.
  late final Stream<TunnelStatusEvent> _statusStream =
      _events.receiveBroadcastStream().map((event) {
    if (event is Map) return TunnelStatusEvent.fromNative(event);
    return TunnelStatusEvent.unknownEmpty;
  }).handleError((Object e) {
    // §141 P1.9d — EventChannel может прислать error (PlatformException и т.п.).
    // Без обработчика он распространился бы на ВСЕХ listener'ов как unhandled
    // async error; `HomeController._statusSub` подписан без onError → зомби.
    // Гасим (broadcast-подписка остаётся живой для следующих data-событий),
    // логируем для диагностики. Не маппим в data-событие: ложный «disconnected»
    // от транзиентной ошибки канала хуже, чем пропуск одного тика.
    AppLog.I.error('[vpn] status stream error: $e');
  }).asBroadcastStream();

  Stream<TunnelStatusEvent> get onStatusChanged => _statusStream;

  // ---------------------------------------------------------------------------
  // Automation API (§047) — public broadcast intents (Tasker / Macrodroid)
  // ---------------------------------------------------------------------------

  /// Incoming-dispatcher: native (`LxBoxIntentReceiver` → `VpnPlugin.
  /// handleAutomationAction`) зовёт нас через `automationAction` method-call на
  /// `_methods`. Устанавливается лениво один раз. Set извне в bootstrap (после
  /// того как `DebugRegistry` забиндил контроллеры) — см. `main()`.
  void Function(String name, Map<String, dynamic> args)? _onAutomationAction;

  /// Регистрирует обработчик incoming automation-интентов. [handler] получает
  /// (`name`, `args`) и роутит на shared action-handlers. Идемпотентно —
  /// повторный вызов перезаписывает handler.
  void registerAutomationActionHandler(
      void Function(String name, Map<String, dynamic> args) handler) {
    _onAutomationAction = handler;
    _methods.setMethodCallHandler(_handleNativeCall);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == _Methods.automationAction) {
      final handler = _onAutomationAction;
      if (handler == null) return null;
      try {
        final raw = (call.arguments as Map?) ?? const {};
        final name = raw['name'] as String? ?? '';
        final args = raw['args'] is Map
            ? Map<String, dynamic>.from(raw['args'] as Map)
            : <String, dynamic>{};
        if (name.isNotEmpty) handler(name, args);
      } catch (e) {
        AppLog.I.error('[automation] native call dispatch failed: $e');
      }
      return null;
    }
    return null;
  }

  /// Включить/выключить receiver автоматизации (мастер-toggle). Native дёргает
  /// `PackageManager.setComponentEnabledSetting`.
  Future<void> setAutomationEnabled(bool enabled) async {
    await _invoke<void>(
      _Methods.setAutomationEnabled,
      args: {'enabled': enabled},
      timeout: _Timeouts.settings,
      onTimeoutValue: null,
    );
  }

  /// §047 Шаг 2 — зеркалит в native-кеш активную ноду/группу (для
  /// `LocaleConditionReceiver` — синхронный ответ на `QUERY_CONDITION`) и
  /// списки нод/групп (для Spinner'а выбора в edit-Activity плагина вместо
  /// ручного ввода). [nodes]/[groups] = null → не обновлять список (когда
  /// меняется только активное состояние). Fire-and-forget.
  void setAutomationActiveState({
    String? node,
    String? group,
    List<String>? nodes,
    List<String>? groups,
  }) {
    unawaited(_invoke<void>(
      _Methods.setAutomationActiveState,
      args: <String, dynamic>{
        'node': node,
        'group': group,
        // null-aware element: ключ пропускается когда список null (native по
        // отсутствию ключа не трогает кеш — обновляем только активное состояние).
        'nodes': ?nodes,
        'groups': ?groups,
      },
      timeout: _Timeouts.settings,
      onTimeoutValue: null,
    ).catchError((Object e) {
      AppLog.I.error('[automation] setAutomationActiveState failed: $e');
    }));
  }

  /// Outgoing emit: отправить automation-broadcast наружу. Открыт всем
  /// подписчикам (события без секретов; per-app фильтр удалён, см. §157).
  /// Fire-and-forget — не ждём подтверждения (broadcast асинхронен).
  void sendAutomationBroadcast(String action, Map<String, Object?> extras) {
    // Не await'им: emit вызывается из синхронных state-mutation точек
    // (контроллеры), блокировать их нельзя. Ошибки гасим в логах.
    unawaited(_invoke<void>(
      _Methods.sendAutomationBroadcast,
      args: {'action': action, 'extras': extras},
      timeout: _Timeouts.settings,
      onTimeoutValue: null,
    ).catchError((Object e) {
      AppLog.I.error('[automation] sendAutomationBroadcast($action) failed: $e');
    }));
  }

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

/// Разбивка памяти процесса приложения из native `Debug.MemoryInfo`
/// (`getMemoryInfo`). Все поля — в байтах. Категории `summary.*` (PSS) плюс
/// прямые счётчики native heap. Ядро sing-box в том же процессе → его память
/// внутри [nativeHeap]/[nativeHeapAllocated].
class MemoryInfo {
  const MemoryInfo({
    this.totalPss = 0,
    this.totalSwap = 0,
    this.javaHeap = 0,
    this.nativeHeap = 0,
    this.code = 0,
    this.stack = 0,
    this.graphics = 0,
    this.privateOther = 0,
    this.system = 0,
    this.nativeHeapAllocated = 0,
    this.nativeHeapSize = 0,
  });

  /// summary.total-pss — суммарный PSS процесса.
  final int totalPss;
  final int totalSwap;
  final int javaHeap;
  final int nativeHeap;
  final int code;
  final int stack;
  final int graphics;
  final int privateOther;
  final int system;

  /// Аллоцированный native heap (malloc) — прямой счётчик, не PSS.
  final int nativeHeapAllocated;
  final int nativeHeapSize;

  static int _int(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);

  factory MemoryInfo.fromMap(Map<dynamic, dynamic> m) => MemoryInfo(
        totalPss: _int(m['totalPss']),
        totalSwap: _int(m['totalSwap']),
        javaHeap: _int(m['javaHeap']),
        nativeHeap: _int(m['nativeHeap']),
        code: _int(m['code']),
        stack: _int(m['stack']),
        graphics: _int(m['graphics']),
        privateOther: _int(m['privateOther']),
        system: _int(m['system']),
        nativeHeapAllocated: _int(m['nativeHeapAllocated']),
        nativeHeapSize: _int(m['nativeHeapSize']),
      );
}
