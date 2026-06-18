import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileSystemException;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/clash_endpoint.dart';
import '../vpn/box_vpn_client.dart';
import '../config/config_parse.dart';
import '../models/home_state.dart';
import '../services/app_log.dart';
import '../services/clash_api_client.dart';
import '../services/error_format.dart';
import '../services/settings_storage.dart';
import '../services/template_loader.dart';
import '../services/haptic_service.dart';
import '../services/subscription/auto_updater.dart';

part 'home_controller/config_io.dart';
part 'home_controller/heartbeat.dart';
part 'home_controller/ping_orchestration.dart';

class HomeController extends ChangeNotifier
    with _ConfigIoMixin, _HeartbeatMixin, _PingMixin {
  HomeController({AutoUpdater? autoUpdater}) : _autoUpdater = autoUpdater;

  @override
  final BoxVpnClient _vpn = BoxVpnClient();
  final AutoUpdater? _autoUpdater;
  StreamSubscription<TunnelStatusEvent>? _statusSub;
  @override
  ClashApiClient? _clash;
  ClashApiClient? get clashClient => _clash;

  @override
  HomeState _state = HomeState();
  HomeState get state => _state;

  /// §141 P1.9a — выставляется в `dispose()` (перед `super.dispose()`).
  /// Async-колбэки, переживающие dispose (delayed cooldown в `reloadVpn`,
  /// in-flight future'ы), проверяют флаг перед `notifyListeners()`, иначе
  /// «Bad state: cannot notify listeners after dispose» на hot-reload /
  /// быстрой навигации.
  bool _disposed = false;

  /// UI-only override: при `true` `HomeScreen` рендерит empty-state как
  /// при чистой инсталляции, **не трогая** реальные данные `_state`.
  /// Управляется через Debug API `POST /action/preview-empty-state?on=...`.
  /// Полезно для скриншотов / UX-демо / регресс-тестинга empty-state'ов
  /// без `pm clear` и потери подписок.
  bool _previewEmpty = false;
  bool get previewEmpty => _previewEmpty;
  void setPreviewEmpty(bool on) {
    if (_previewEmpty == on) return;
    _previewEmpty = on;
    notifyListeners();
  }

  /// Cooldown timestamps для recovery actions (reloadVpn / resetNetwork) —
  /// чтобы юзер не спамил кнопками при тревоге. См. spec 030 / 031.
  DateTime? _lastReloadTap;
  DateTime? _lastResetNetworkTap;
  static const _recoveryCooldown = Duration(seconds: 3);

  /// One-shot timer for auto-ping-on-connect (5s after tunnel up). Отменяется
  /// при disconnect чтобы не стрельнул в уже отключённом состоянии.
  @override
  Timer? _autoPingTimer;

  /// Safety-timeout для transient-состояний (Starting/Stopping): если
  /// native застрял дольше порога — форсим disconnected в UI + force-stop
  /// сервиса (§129). Один Timer на всю жизнь контроллера, cancel'им при любой
  /// смене статуса (чтобы не срабатывал на уже разрешённом состоянии) и
  /// пересоздаём при новой transient-фазе.
  ///
  /// §140 — пороги РАЗДЕЛЕНЫ по фазе. `stopping` завис на 10с → ядро реально не
  /// отдаёт Stopped → force-stop оправдан. `connecting` дольше 15с — это чаще
  /// просто медленный, но ЖИВОЙ старт (сотовая, WARP-gen/AWG handshake), а не
  /// зависон; force-kill убивал бы рабочее подключение. Даём connecting больше.
  ///
  /// §140 — пороги ПЕРЕМЕННЫЕ (не `static const`): инициализируются из дефолтов
  /// ниже, но Debug API (`POST /action/set-transient-timeout` с query
  /// `connecting`/`stopping` в мс) может их переопределить для on-device теста
  /// force-stop'а (например, connecting=500мс, чтобы не ждать реальный зависон ядра).
  Timer? _transientTimeoutTimer;
  static const _defaultStoppingTimeout = Duration(seconds: 10);
  static const _defaultConnectingTimeout = Duration(seconds: 15);
  Duration _stoppingTimeout = _defaultStoppingTimeout;
  Duration _connectingTimeout = _defaultConnectingTimeout;

  /// §140 — debug-only: переопределить transient-пороги (в миллисекундах).
  /// `null` аргумент = не трогать этот порог. Возвращает применённые значения.
  /// Используется `POST /action/set-transient-timeout` для on-device теста.
  ({int connectingMs, int stoppingMs}) debugSetTransientTimeouts({
    int? connectingMs,
    int? stoppingMs,
  }) {
    if (connectingMs != null) {
      _connectingTimeout = Duration(milliseconds: connectingMs);
    }
    if (stoppingMs != null) {
      _stoppingTimeout = Duration(milliseconds: stoppingMs);
    }
    _addDebug(DebugSource.app,
        '[vpn] transient timeouts set: connecting=${_connectingTimeout.inMilliseconds}ms stopping=${_stoppingTimeout.inMilliseconds}ms');
    return (
      connectingMs: _connectingTimeout.inMilliseconds,
      stoppingMs: _stoppingTimeout.inMilliseconds,
    );
  }

  /// §140 — debug-only: текущие transient-пороги (мс), для `GET`-чтения.
  ({int connectingMs, int stoppingMs}) get debugTransientTimeouts => (
        connectingMs: _connectingTimeout.inMilliseconds,
        stoppingMs: _stoppingTimeout.inMilliseconds,
      );

  /// §140 — debug-only: напрямую дёрнуть force-stop native-сервиса (минуя
  /// transient-таймаут). Для on-device проверки `doForceStop`-пути (порт 63130).
  Future<bool> debugForceStopVpn() => _vpn.forceStopVPN();

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    await _loadSavedConfig();
    await reloadPingOptions();
    _statusSub = _vpn.onStatusChanged.listen(_handleStatusEvent);
    // Native шлёт broadcast только на переходы. Если Flutter-процесс умер,
    // а foreground-service выжил (keep-on-exit), при reattach мы не узнаём
    // что туннель уже Started — поле застревает в `disconnected`, а Start-
    // кнопка может оказаться неактивна. Pull'им текущий статус и пропускаем
    // через тот же handler — он сам решит что эмитить.
    final pulled = await _vpn.getVpnStatus();
    _handleStatusEvent(TunnelStatusEvent(status: pulled, raw: pulled.name));
  }

  @override
  void dispose() {
    _disposed = true; // §141 P1.9a — до super.dispose, гейтит async-колбэки
    _stopHeartbeat();
    _autoPingTimer?.cancel();
    _transientTimeoutTimer?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // State helpers
  // ---------------------------------------------------------------------------

  @override
  void _emit(HomeState next) {
    _state = next;
    notifyListeners();
  }

  @override
  void _addDebug(DebugSource source, String message) {
    AppLog.I.log(
      source == DebugSource.core ? DebugLevel.info : DebugLevel.debug,
      message,
      source: source,
    );
  }

  // ---------------------------------------------------------------------------
  // Native VPN events
  // ---------------------------------------------------------------------------

  void _handleStatusEvent(TunnelStatusEvent event) {
    final tunnel = event.status;
    final prevTunnel = _state.tunnel;
    _addDebug(DebugSource.core,
        'status=${event.raw}${event.errorReason != null ? " reason=${event.errorReason}" : ""}');
    _addDebug(DebugSource.app,
        '[vpn] _handleStatusEvent raw="${event.raw}" tunnel=${tunnel.name} prev=${prevTunnel.name} need_restart_before=${_state.configChangedNeedRestart}');

    // Все мутации state складываем в **одно** copyWith в конце — было три
    // отдельных _emit (tunnel; then connectedSince+stale; then cleanup-
    // поля), каждый триггерил notifyListeners → 3 rebuild'а UI на одно
    // событие. Теперь один emit, одно rebuild.

    if (tunnel == TunnelStatus.connected) {
      _emit(_state.copyWith(
        tunnel: tunnel,
        connectedSince: DateTime.now(),
        configChangedNeedRestart: false,
      ));
      unawaited(_refreshClashAfterTunnel());
      _startHeartbeat();
      _heartbeatFailNotified = false;
      HapticService.I.onVpnConnected();
      // AutoUpdater триггер #2: через 2 мин после connected.
      _autoUpdater?.onVpnConnected();
      unawaited(_scheduleAutoPing());
    } else if (tunnel == TunnelStatus.disconnected ||
        tunnel == TunnelStatus.revoked) {
      _stopHeartbeat();
      // §141 P1.2b — единый контракт «tunnel down»: отменяем in-flight mass-ping
      // ПЕРЕД обнулением _clash (ниже), симметрично `_onTunnelDead` (heartbeat.dart).
      // Иначе воркеры mass-ping'а, стартовавшие из _scheduleAutoPing/ручного
      // запуска, дописывают stale-delay в мёртвую сессию (epoch-гейт их
      // самоисцелит, но явная отмена — чище и не зависит от тайминга).
      cancelMassPing();
      _autoPingTimer?.cancel();
      _autoPingTimer = null;
      // Clash endpoint прошлой сессии теперь невалиден — secret был у
      // убитого sing-box, port может быть переиспользован системой. На
      // следующем `connected` event мы пересоберём его через
      // `_refreshClashAfterTunnel` → `_rebuildClashEndpoint`.
      _clash = null;
      final reason = tunnel == TunnelStatus.revoked
          ? 'VPN revoked by another app'
          : (event.errorReason != null ? 'Stopped: ${event.errorReason}' : '');
      _emit(
        _state.copyWith(
          tunnel: tunnel,
          lastError: reason.isNotEmpty ? reason : _state.lastError,
          proxiesJson: <String, dynamic>{},
          groups: <String>[],
          nodes: <String>[],
          highlightedNode: null,
          traffic: TrafficSnapshot.zero,
          connectedSince: null,
          configChangedNeedRestart: false,
        ),
      );
      // Haptic — на революд/краш тяжёлый, на user-инициированный stop лёгкий.
      // Триггерим только если был up (не из connecting → disconnect).
      if (prevTunnel == TunnelStatus.connected) {
        if (tunnel == TunnelStatus.revoked) {
          HapticService.I.onVpnCrashed();
        } else {
          HapticService.I.onVpnDisconnected();
        }
        // AutoUpdater триггер #4: только если реально ушли из connected
        // (чтобы не срабатывать при revoked → disconnected дубле).
        _autoUpdater?.onVpnStopped();
      }
      if (reason.isNotEmpty) {
        _addDebug(DebugSource.core, reason);
      }
    } else if (tunnel == TunnelStatus.stopping || tunnel == TunnelStatus.connecting) {
      _stopHeartbeat();
      _emit(_state.copyWith(tunnel: tunnel));
      _armTransientTimeout(tunnel);
      return;
    } else {
      _stopHeartbeat();
      _emit(_state.copyWith(tunnel: tunnel));
    }

    // non-transient terminal event — safety-timer больше не нужен.
    _transientTimeoutTimer?.cancel();
    _transientTimeoutTimer = null;
  }

  /// Перезапускает safety-timer на transient-фазу. Cancel'ит предыдущий
  /// (защита от спама `Future.delayed` при множественных stopping/
  /// connecting подряд) и стартует новый. §140 — порог зависит от фазы:
  /// `connecting` (медленный старт) — длиннее, `stopping` (реальный зависон) — 10с.
  void _armTransientTimeout(TunnelStatus expected) {
    _transientTimeoutTimer?.cancel();
    final timeout = expected == TunnelStatus.connecting
        ? _connectingTimeout
        : _stoppingTimeout;
    _transientTimeoutTimer = Timer(timeout, () async {
      if (_state.tunnel != expected) return;
      _addDebug(
          DebugSource.app, 'Timeout in ${expected.label}, forcing disconnect');
      // §129 — таймаут transient-фазы = ядро НЕ отдало Stopped само (зависло
      // вхолостую: detour AWG→WG #2 — tun0 жив, 0 трафика, dial заклинен).
      // Раньше тут был только _emit(disconnected) — UI «disconnected», а
      // VpnService продолжал жить и роутить вхолостую, кнопка не реагировала.
      // Теперь принудительно прибиваем сервис (stopSelf в обход зависшего
      // teardown). НЕ обычный stopVPN — тот кооперативный, ждёт Stopped и сам
      // виснет. forceStopVPN — fire-and-forget. После — синхронизируем UI.
      await _vpn.forceStopVPN();
      _addDebug(DebugSource.app, '[vpn] forceStopVPN sent (timeout in ${expected.label})');
      if (_state.tunnel != expected) return;
      _emit(_state.copyWith(
        tunnel: TunnelStatus.disconnected,
        lastError: 'Connection timed out',
        proxiesJson: <String, dynamic>{},
        groups: <String>[],
        nodes: <String>[],
        traffic: TrafficSnapshot.zero,
        connectedSince: null,
        configChangedNeedRestart: false,
      ));
    });
  }

  // Tunnel heartbeat (_startHeartbeat / _stopHeartbeat / _checkHeartbeat /
  // _onTunnelDead / _tryCleanStop) вынесен в `home_controller/heartbeat.dart`
  // (`_HeartbeatMixin`).

  // Config persistence + import (clipboard / file) вынесены в
  // `home_controller/config_io.dart` (`_ConfigIoMixin`): _loadSavedConfig /
  // saveParsedConfig / saveConfigRaw / readFromClipboard / readFromFile.
  // `_rebuildClashEndpoint` остался здесь (общий с Clash-секцией).

  // ---------------------------------------------------------------------------
  // VPN tunnel control
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // stop/start/reconnect — intent-based primitives
  //
  // Дизайн (после sink-fix в BoxVpnClient + blocking stopVPN на native):
  //   - `_stopInternal` / `_startInternal` — внутренние примитивы, делают
  //     один native call + intent-based reset `configChangedNeedRestart=false`
  //     на успехе. Без busy-management.
  //   - `stop` / `start` — public, оборачивают internal в `busy=true/false`
  //     try/finally + error surfacing в `lastError`.
  //   - `reconnect` — композиция `_stopInternal` → `_startInternal` под
  //     одним `busy`-wrap'ом. Никакого `firstWhere`/`timeout` на Dart
  //     стороне: `stopVPN` теперь блокирующий на native, caller получает
  //     control только после `setStatus(Stopped)`.
  //
  // Почему intent-based reset `configChangedNeedRestart=false` в _stopInternal
  // и _startInternal (а не только в _handleStatusEvent на Stopped/Started):
  //   1. Семантическая чистота. Юзер явно применил namерение (stop = "туннель
  //      прекращается, saved больше не vs running"; start = "running теперь
  //      и есть saved"). Флаг сбрасывается по причине, а не по следствию.
  //   2. Broadcast-канал остаётся unreliable-by-design на системном уровне
  //      (Doze, OOM, process kill) — intent reset не зависит от доставки.
  //   3. `_handleStatusEvent` reset (строки 101/127) остаётся как defense
  //      in depth: если transition пришёл без intent (например, revoke
  //      от другого VPN), флаг тоже сбросится. Идемпотентно, конфликтов нет.
  // ---------------------------------------------------------------------------

  /// Atomic stop: blocking native call + intent-based sticky reset.
  /// Returns true если native реально остановился, false на timeout.
  Future<bool> _stopInternal() async {
    final ok = await _vpn.stopVPN();
    _addDebug(DebugSource.app, '[vpn] stopVPN returned $ok');
    if (ok) {
      // Intent-based reset: юзер остановил туннель, saved конфиг больше
      // не "stale vs running" — running перестал существовать.
      _emit(_state.copyWith(configChangedNeedRestart: false));
    }
    return ok;
  }

  /// §123 — собрать и отправить строки foreground-уведомления.
  ///   title = `L×Box [final = <route.final>]` (сырое route.final)
  ///   text  = `<селектор>: <выбранная нода>`, напр. `vpn-1: L: 🇫🇮⚡Финляндия-2`.
  ///           Селектор = selectedGroup, нода = его `now` (= activeInGroup,
  ///           которое applyGroup заполняет из entry['now'] группы).
  ///           Нет ноды → только селектор; нет конфига → пусто (native подставит
  ///           статусный fallback "Connected").
  /// Dart владеет обеими строками — native при своих show(...) не затирает их.
  Future<void> _pushNotificationLabels() async {
    final routeFinal = ClashEndpoint.routeFinalTag(_state.configRaw);
    final title = (routeFinal == null || routeFinal.isEmpty)
        ? 'L×Box'
        : 'L×Box [final = $routeFinal]';

    // selectedGroup = активный селектор (vpn-1), activeInGroup = его выбранная
    // нода (`now`). Формат подтекста: «<селектор>: <нода>».
    final group = _state.selectedGroup;
    final node = _state.activeInGroup;
    final String text;
    if (group != null && group.isNotEmpty) {
      text = (node != null && node.isNotEmpty) ? '$group: $node' : group;
    } else {
      text = (node != null && node.isNotEmpty) ? node : (routeFinal ?? '');
    }

    await _vpn.setNotificationTitle(title);
    await _vpn.setNotificationText(text);
  }

  /// Atomic start: native call + intent-based sticky reset.
  /// Returns true если startVPN принят (reached Starting), false иначе.
  Future<bool> _startInternal() async {
    await _pushNotificationLabels();
    final ok = await _vpn.startVPN();
    _addDebug(DebugSource.app, '[vpn] startVPN returned $ok');
    if (ok) {
      // Intent-based reset: running теперь = saved (или станет через
      // мгновение на Started). Плашка "нужен restart" неактуальна.
      _emit(_state.copyWith(configChangedNeedRestart: false));
    }
    return ok;
  }

  Future<void> start() async {
    _emit(_state.copyWith(busy: true, lastError: ''));
    try {
      final ok = await _startInternal();
      if (!ok) {
        _emit(_state.copyWith(lastError: 'Failed to start VPN'));
      }
    } catch (e) {
      _emit(_state.copyWith(lastError: formatUserError(e)));
      _addDebug(DebugSource.app, 'startVPN exception: $e');
    } finally {
      _emit(_state.copyWith(busy: false));
    }
  }

  Future<void> stop() async {
    _emit(_state.copyWith(busy: true, lastError: ''));
    try {
      final ok = await _stopInternal();
      if (!ok) {
        _emit(_state.copyWith(lastError: 'Stop timed out'));
      }
    } catch (e) {
      _emit(_state.copyWith(lastError: formatUserError(e)));
      _addDebug(DebugSource.app, 'stopVPN exception: $e');
    } finally {
      _emit(_state.copyWith(busy: false));
    }
  }

  /// Можно ли сейчас триггерить in-place reload (cooldown-aware). UI bind'ит
  /// `IconButton.onPressed` к этому, чтобы кнопка disabled на 3s после tap'а
  /// и недоступна когда туннель не up.
  bool get canReload =>
      _state.tunnel == TunnelStatus.connected &&
      (_lastReloadTap == null ||
          DateTime.now().difference(_lastReloadTap!) > _recoveryCooldown);

  /// In-place reload sing-box runtime через `commandServer.startOrReloadService`.
  /// Tunnel дропается на ~3s, Android Service не убивается. См. spec 030.
  Future<void> reloadVpn() async {
    if (!canReload) return;
    final prevReloadTap = _lastReloadTap;
    _lastReloadTap = DateTime.now();
    notifyListeners();
    // §141 P1.9b — раньше исключение из reloadVPN проглатывалось (uncaught
    // async) → cooldown оставался занятым, юзер не видел ошибки. Теперь
    // surface'им через _emit(lastError) и откатываем cooldown, чтобы повтор
    // был доступен сразу.
    try {
      final ok = await _vpn.reloadVPN();
      _addDebug(DebugSource.app, '[vpn] reload → ok=$ok');
    } catch (e) {
      _lastReloadTap = prevReloadTap; // откат cooldown
      _addDebug(DebugSource.app, '[vpn] reload error: $e');
      if (!_disposed) {
        _emit(_state.copyWith(lastError: 'Reload failed: ${formatUserError(e)}'));
      }
      return;
    }
    // Cooldown timer перерендерит canReload через 3s — назначаем future
    // notifyListeners (без heavy timer'а; achievable через delayed Future).
    // §141 P1.9a — гейт `_disposed`: контроллер мог умереть за время cooldown.
    Future.delayed(_recoveryCooldown, () {
      if (!_disposed && _lastReloadTap != null) notifyListeners();
    });
  }

  /// Reset network sub-state (experimental, spec 031). Не дропает runtime.
  /// UI пока не использует — только через Debug API для экспериментов.
  Future<bool> resetNetwork() async {
    if (_state.tunnel != TunnelStatus.connected) return false;
    if (_lastResetNetworkTap != null &&
        DateTime.now().difference(_lastResetNetworkTap!) < _recoveryCooldown) {
      return false;
    }
    _lastResetNetworkTap = DateTime.now();
    final ok = await _vpn.resetNetwork();
    _addDebug(DebugSource.app, '[vpn] resetNetwork → ok=$ok');
    return ok;
  }

  /// Reconnect = `_stopInternal` → `_startInternal`. Blocking на native
  /// даёт нам уверенность что между stop и start нет race окна в
  /// `onStartCommand` guard'е. busy=true держится на всю цепочку, чтобы
  /// UI не дал повторно нажать.
  ///
  /// Если туннель уже down — просто делегируем в `start()`.
  Future<void> reconnect() async {
    final wasUp = _state.tunnel == TunnelStatus.connected ||
        _state.tunnel == TunnelStatus.connecting;
    if (!wasUp) {
      await start();
      return;
    }
    _emit(_state.copyWith(busy: true, lastError: ''));
    try {
      final stopped = await _stopInternal();
      if (!stopped) {
        _emit(_state.copyWith(lastError: 'Stop timed out — reconnect aborted'));
        _addDebug(DebugSource.app, 'reconnect: stop timed out, aborting start');
        return;
      }
      final started = await _startInternal();
      if (!started) {
        _emit(_state.copyWith(lastError: 'Failed to start VPN'));
      }
    } catch (e) {
      _emit(_state.copyWith(lastError: formatUserError(e)));
      _addDebug(DebugSource.app, 'reconnect exception: $e');
    } finally {
      _emit(_state.copyWith(busy: false));
    }
  }

  // ---------------------------------------------------------------------------
  // Clash API — proxies & groups
  // ---------------------------------------------------------------------------

  Future<void> _refreshClashAfterTunnel() async {
    _rebuildClashEndpoint();
    await reloadProxies();
  }

  @override
  void _rebuildClashEndpoint() {
    final endpoint = ClashEndpoint.fromConfigJson(_state.configRaw);
    _clash = endpoint != null ? ClashApiClient(endpoint) : null;
  }

  @override
  Future<void> reloadProxies() async {
    final clash = _clash;
    if (clash == null || _state.configRaw.isEmpty) return;
    try {
      await clash.pingVersion();
      final proxies = await clash.fetchProxies();
      // §141 P1.2a — assign-after-await: пока ждали fetchProxies, туннель мог
      // упасть (`_handleStatusEvent`/`_onTunnelDead` обнулили _clash и почистили
      // state). Если _clash сменился или ушёл — не перетираем свежий
      // disconnected-state устаревшим снимком (иначе transient UI-глитч:
      // groups/nodes от мёртвой сессии поверх «tunnel down»).
      if (_clash != clash || !_state.tunnelUp) return;
      final groups = ClashApiClient.selectorGroupTags(proxies)
          .where((name) => name != 'GLOBAL')
          .toList();

      String? initial = _state.selectedGroup;
      if (initial == null || !groups.contains(initial)) {
        final finalTag = ClashEndpoint.routeFinalTag(_state.configRaw);
        if (finalTag != null && groups.contains(finalTag)) {
          initial = finalTag;
        } else {
          initial = groups.isNotEmpty ? groups.first : null;
        }
      }

      _emit(
        _state.copyWith(
          proxiesJson: proxies,
          groups: groups,
          selectedGroup: initial,
        ),
      );
      await applyGroup(initial);
    } catch (e) {
      _emit(_state.copyWith(lastError: 'Clash API: ${formatUserError(e)}'));
      _addDebug(DebugSource.app, 'Clash API error: $e');
    }
  }

  Future<void> applyGroup(String? tag) async {
    if (tag == null) {
      _emit(
        _state.copyWith(
          nodes: <String>[],
          activeInGroup: null,
          highlightedNode: null,
        ),
      );
      return;
    }
    final entry = ClashApiClient.proxyEntry(_state.proxiesJson, tag);
    if (entry == null) return;
    final all = entry['all'];
    final now = entry['now']?.toString();
    final nodes = all is List ? all.map((e) => e.toString()).toList() : <String>[];
    _emit(
      _state.copyWith(
        nodes: nodes,
        activeInGroup: now,
        highlightedNode: now,
      ),
    );
    // §123 — activeInGroup стал известен → обновить подтекст шторки.
    await _pushNotificationLabels();
  }

  Future<void> switchNode(String nodeTag) async {
    final group = _state.selectedGroup;
    final clash = _clash;
    if (group == null || clash == null) return;
    _emit(_state.copyWith(busy: true, highlightedNode: nodeTag));
    try {
      await clash.selectInGroup(group, nodeTag);
      // §143 — `interrupt_exist_connections` рвёт только inbound; уже
      // установленные upstream-сессии старой ноды доживают сами. По opt-in
      // тугле точечно закрываем соединения переключаемой группы, чтобы трафик
      // сразу ушёл на новую ноду. Best-effort: фейл одного DELETE не должен
      // ронять переключение.
      if (await SettingsStorage.getInterruptOnSwitch()) {
        try {
          final conns = await clash.fetchConnections();
          final ids = ClashApiClient.connectionIdsInChain(conns, group);
          // Общий дедлайн на весь обрыв: на нормальном loopback DELETE'ы
          // sub-ms, но если локальный clash-inbound подвиснет, серия из N
          // запросов с 10s-таймаутом каждый держала бы busy=true слишком
          // долго. 5s суммарно с запасом хватает на десятки соединений.
          await Future(() async {
            for (final id in ids) {
              try {
                await clash.closeConnection(id);
              } catch (_) {/* соединение уже закрылось — игнор */}
            }
          }).timeout(const Duration(seconds: 5), onTimeout: () {});
          _addDebug(
              DebugSource.app, 'Interrupted ${ids.length} conns in $group');
        } catch (e) {
          _addDebug(DebugSource.app, 'Interrupt-on-switch failed: $e');
        }
      }
      await reloadProxies();
      _addDebug(DebugSource.app, 'Node selected: $nodeTag');
    } catch (e) {
      _emit(_state.copyWith(
          lastError: 'Switch failed: ${formatUserError(e)}'));
      _addDebug(DebugSource.app, 'Node switch error: $e');
    } finally {
      _emit(_state.copyWith(busy: false));
    }
  }

  // Ping / URLTest оркестрация (runNodeUrltest, ping-option resolve chain,
  // reloadPingOptions, _scheduleAutoPing, runGroupUrltest, runMassUrltest,
  // _runAllUrltestGroups, cancelMassPing, massPingRunning) вынесена в
  // `home_controller/ping_orchestration.dart` (`_PingMixin`).

  // ---------------------------------------------------------------------------
  // UI selection helpers
  // ---------------------------------------------------------------------------

  void setSelectedGroup(String? group) {
    // §070: bump cache gen — group switch = новый pool, sort заново.
    _emit(_state.copyWith(
      selectedGroup: group,
      pingBatchGen: _state.pingBatchGen + 1,
    ));
  }

  void setHighlightedNode(String nodeTag) {
    _emit(_state.copyWith(highlightedNode: nodeTag));
  }

  void cycleSortMode() {
    // §100 — manualOrder больше НЕ сбрасывается при уходе из manual: порядок
    // персистится, повторный выбор «Custom» восстанавливает его.
    _emit(_state.copyWith(sortMode: _state.sortMode.next));
    _persistSort();
  }

  /// §100 — выбрать режим сортировки напрямую (из sort-меню), включая `manual`
  /// (раньше manual входился только через drag). При выборе manual — видимые
  /// grab-strip'ы (§098). Порядок ручной сортировки сохраняется.
  void setSortMode(NodeSortMode mode) {
    if (mode == _state.sortMode) return;
    _emit(_state.copyWith(sortMode: mode));
    _persistSort();
  }

  /// §100 — персист текущего режима + manual-порядка в `lxbox_settings.json`.
  void _persistSort() {
    unawaited(
        SettingsStorage.setNodeSort(_state.sortMode.name, _state.manualOrder));
  }

  // §070 — sort options setters (per-session toggle'ы).
  void setPinDirect(bool v) => _emit(_state.copyWith(pinDirect: v));
  void setPinAuto(bool v) => _emit(_state.copyWith(pinAuto: v));
  void setResortOnManualPing(bool v) =>
      _emit(_state.copyWith(resortOnManualPing: v));

  /// §076: external mark «running tunnel config устарел, нужен restart».
  /// Используется когда настройка применяется **вне** config pipeline:
  /// VpnService.Builder native toggles (allow_bypass / keep_on_exit /
  /// background_mode) — они set'ятся на establish(), restart обновит.
  /// Если tunnel down — флаг не set'им (новое значение подхватится на
  /// следующем start без restart'а).
  void markConfigChangedNeedRestart() {
    if (_state.tunnelUp) {
      _emit(_state.copyWith(configChangedNeedRestart: true));
    }
  }

  /// §071: commit drag-reorder в manual mode.
  /// [newOrder] — полный non-pinned порядок (без direct/auto если они pinned).
  /// Заодно переключает sortMode на `manual`.
  void commitManualReorder(List<String> newOrder) {
    _emit(_state.copyWith(
      sortMode: NodeSortMode.manual,
      manualOrder: List<String>.unmodifiable(newOrder),
    ));
    _persistSort(); // §100 — сохранить порядок ручной сортировки
  }

  void clearError() {
    if (_state.lastError.isNotEmpty) {
      _emit(_state.copyWith(lastError: ''));
    }
  }

  /// Called when the app returns from background. Verifies tunnel health:
  ///   1. One-shot pull `getVpnStatus` → если native divergent от Dart state
  ///      (напр., service умер силой Doze/OOM пока app был suspended, и
  ///      broadcast'а не было) — прогоняем через тот же `_handleStatusEvent`,
  ///      чтобы UI синхронизировался.
  ///   2. Если после pull'а туннель всё ещё up — heartbeat для проверки что
  ///      Clash отвечает.
  ///
  /// Event-driven (не polling) — дёргается только на lifecycle resume,
  /// в steady-state ничего не крутится.
  void onAppResumed() {
    unawaited(_resyncOnResume());
  }

  /// §141 P0.2 — app ушёл в фон: останавливаем heartbeat-таймер. Это
  /// единственный always-on resident-drain (Timer.periodic(20s) → 2 loopback-
  /// HTTP + парсинг всего списка соединений на каждый тик). В фоне UI не виден,
  /// stale-state не важен, а dead-tunnel в фоне поймает native-broadcast путь
  /// (`onStatusChanged` → `_handleStatusEvent`), не heartbeat.
  ///
  /// Симметрично `onAppResumed`/`_resyncOnResume`: resume пере-синхронизирует
  /// статус и (если tunnelUp) делает немедленный `_checkHeartbeat`, который сам
  /// перезапускает таймер через первый успешный тик? Нет — `_checkHeartbeat`
  /// таймер не создаёт. Поэтому на resume рестартуем явно (см. `_resyncOnResume`).
  void onAppPaused() {
    _stopHeartbeat();
  }

  Future<void> _resyncOnResume() async {
    try {
      final native = await _vpn.getVpnStatus();
      if (native != _state.tunnel) {
        _addDebug(DebugSource.app,
            '[vpn] onAppResumed: divergence native=${native.name} state=${_state.tunnel.name} — re-sync');
        _handleStatusEvent(TunnelStatusEvent(status: native, raw: native.name));
      }
    } catch (e) {
      _addDebug(DebugSource.app, '[vpn] onAppResumed pull error: $e');
    }
    // §141 P0.2 — heartbeat был остановлен на paused; если туннель всё ещё жив,
    // перезапускаем таймер и делаем немедленный тик (подтянуть свежий traffic
    // сразу, не ждать первые 20с). `_resyncOnResume` мог уже синхронизировать
    // tunnel через native-pull выше — если он лёг, `_handleStatusEvent` сам
    // не стартовал heartbeat (только connected-ветка стартует).
    if (_state.tunnelUp) {
      _startHeartbeat();
      unawaited(_checkHeartbeat());
    }
  }
}
