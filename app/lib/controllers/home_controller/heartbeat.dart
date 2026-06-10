part of '../home_controller.dart';

/// Tunnel heartbeat + dead-tunnel recovery. Вынесено `part`'ом из
/// `home_controller.dart` — та же библиотека и тот же `HomeController`,
/// так что поведение (_emit/notifyListeners timing, таймеры, error handling)
/// идентично. Общие с контроллером поля/хелперы объявлены абстрактно;
/// концретную реализацию даёт `HomeController` (см. routing_screen split).
mixin _HeartbeatMixin on ChangeNotifier {
  // --- surface, предоставляемая HomeController / другими частями ---
  HomeState get _state;
  BoxVpnClient get _vpn;
  ClashApiClient? get _clash;
  set _clash(ClashApiClient? value);
  Timer? get _autoPingTimer;
  set _autoPingTimer(Timer? value);
  void _emit(HomeState next);
  void _addDebug(DebugSource source, String message);
  void cancelMassPing();

  Timer? _heartbeat;
  int _heartbeatFailures = 0;

  static const _heartbeatInterval = Duration(seconds: 20);
  static const _heartbeatTimeout = Duration(seconds: 4);
  static const _maxHeartbeatFailures = 2;

  /// Сторожок: heartbeat fail haptic стреляет один раз на серию,
  /// сбрасывается при успешном heartbeat (см. `_startHeartbeat`).
  /// Иначе — каждые 20 сек вибро-спам пока туннель лежит.
  bool _heartbeatFailNotified = false;

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatFailures = 0;
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) => _checkHeartbeat());
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _heartbeatFailures = 0;
  }

  Future<void> _checkHeartbeat() async {
    if (!_state.tunnelUp) {
      _stopHeartbeat();
      return;
    }
    final clash = _clash;
    if (clash == null) return;

    try {
      final traffic = await clash.fetchTraffic().timeout(_heartbeatTimeout);
      _heartbeatFailures = 0;
      // Заодно подтягиваем свежий proxies — urltest переключает ноду во
      // времени (`now` field), без refresh'а UI показывает stale selection.
      // Clash на localhost — запрос дешёвый, не сеть.
      Map<String, dynamic>? proxies;
      try {
        proxies = await clash.fetchProxies().timeout(_heartbeatTimeout);
      } catch (_) {
        // Non-fatal: traffic уже обновился, stale proxies переживём до next tick.
      }
      _emit(_state.copyWith(
        traffic: traffic,
        proxiesJson: proxies ?? _state.proxiesJson,
      ));
    } catch (_) {
      _heartbeatFailures++;
      _addDebug(
        DebugSource.app,
        'Heartbeat failed ($_heartbeatFailures/$_maxHeartbeatFailures)',
      );
      if (_heartbeatFailures >= _maxHeartbeatFailures) {
        _stopHeartbeat();
        if (!_heartbeatFailNotified) {
          HapticService.I.onHeartbeatFail();
          _heartbeatFailNotified = true;
        }
        _onTunnelDead();
      }
    }
  }

  void _onTunnelDead() {
    _addDebug(DebugSource.app, 'Tunnel appears dead (heartbeat lost)');
    cancelMassPing();
    _autoPingTimer?.cancel();
    _autoPingTimer = null;
    // Полный cleanup как в `_handleStatusEvent` revoked/disconnected ветке —
    // включая _clash=null (старый endpoint с невалидным secret'ом), traffic
    // reset, connectedSince=null, configChangedNeedRestart=false. Единый
    // контракт очистки: через какой бы путь ни попали в «tunnel down»
    // (broadcast от native или heartbeat-timeout) — state в одинаковом
    // финальном виде.
    _clash = null;
    _emit(
      _state.copyWith(
        tunnel: TunnelStatus.revoked,
        lastError: 'VPN tunnel lost — another VPN may have taken over',
        proxiesJson: <String, dynamic>{},
        groups: <String>[],
        nodes: <String>[],
        highlightedNode: null,
        traffic: TrafficSnapshot.zero,
        connectedSince: null,
        configChangedNeedRestart: false,
      ),
    );
    unawaited(_tryCleanStop());
  }

  Future<void> _tryCleanStop() async {
    try {
      await _vpn.stopVPN();
    } catch (_) {
      // Best-effort: the native VPN is likely already dead
    }
  }
}
