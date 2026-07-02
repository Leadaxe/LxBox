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
  Timer? get _autoPingTimer;
  set _autoPingTimer(Timer? value);
  void _emit(HomeState next);
  void _addDebug(DebugSource source, String message);
  void cancelMassPing();

  /// §122 — таймстемп последнего status-снапшота CommandClient'а (стрим тикает
  /// 1s). Watchdog считает туннель мёртвым, если снапшотов нет дольше порога.
  DateTime? get lastCcStatusAt;
  void _stopCcStreams();

  Timer? _heartbeat;
  int _heartbeatFailures = 0;

  /// §122 — watchdog тикает чаще (status-стрим 1s): проверяем «тишину» канала,
  /// а не делаем дорогой HTTP-запрос. 5s интервал, мёртв если 8s+ без снапшота.
  static const _heartbeatInterval = Duration(seconds: 5);
  static const _heartbeatTimeout = Duration(seconds: 8);
  static const _maxHeartbeatFailures = 2;

  /// Сторожок: heartbeat fail haptic стреляет один раз на серию,
  /// сбрасывается при успешном heartbeat (см. `_startHeartbeat`).
  /// Иначе — каждые 20 сек вибро-спам пока туннель лежит.
  bool _heartbeatFailNotified = false;

  /// §216 — грейс после возврата из фона. В фоне status-стрим гасится (§164),
  /// поэтому `lastCcStatusAt` устаревает на всё время сна (могут быть минуты/
  /// часы). Первый тик сразу после resume увидел бы огромную «тишину» и написал
  /// ложный `Heartbeat: silent 2905s` — хотя стрим только-только поднимается и
  /// свежий снапшот придёт в пределах ~1s. Флаг гасит ровно один первый тик
  /// после resume: не штрафуем, ждём восстановления стрима. Взводится в
  /// `_resyncOnResume` (см. home_controller.dart).
  bool _skipNextHeartbeatFail = false;

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

  /// §122 — watchdog поверх status-стрима. Не делает HTTP: проверяет, как давно
  /// приходил последний status-снапшот (`lastCcStatusAt`). Стрим тикает 1s пока
  /// ядро живо; затяжная тишина (> [_heartbeatTimeout]) = ядро не отвечает →
  /// dead-tunnel recovery. traffic/proxies обновляют сами стримы (`_onCcStatus`/
  /// `_onCcGroups`), heartbeat их больше не тянет.
  Future<void> _checkHeartbeat() async {
    if (!_state.tunnelUp) {
      _stopHeartbeat();
      return;
    }
    final last = lastCcStatusAt;
    // Снапшота ещё не было (только-только connected) — даём каналу подняться,
    // не штрафуем. Первый снапшот придёт в пределах ~1s.
    if (last == null) return;

    final silence = DateTime.now().difference(last);
    if (silence <= _heartbeatTimeout) {
      _heartbeatFailures = 0;
      _skipNextHeartbeatFail = false;
      return;
    }

    // §216 — первый тик после возврата из фона: стрим ещё не поднялся,
    // «тишина» — это время сна, а не отказ ядра. Пропускаем ровно один раз,
    // даём снапшоту прийти. Следующий тик (через 5s) оценит уже честно.
    if (_skipNextHeartbeatFail) {
      _skipNextHeartbeatFail = false;
      return;
    }

    _heartbeatFailures++;
    _addDebug(
      DebugSource.app,
      'Heartbeat: cc status silent ${silence.inSeconds}s '
      '($_heartbeatFailures/$_maxHeartbeatFailures)',
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

  void _onTunnelDead() {
    _addDebug(DebugSource.app, 'Tunnel appears dead (heartbeat lost)');
    cancelMassPing();
    _autoPingTimer?.cancel();
    _autoPingTimer = null;
    // Полный cleanup как в `_handleStatusEvent` revoked/disconnected ветке —
    // traffic reset, connectedSince=null, configChangedNeedRestart=false. Единый
    // контракт очистки: через какой бы путь ни попали в «tunnel down»
    // (broadcast от native или heartbeat-timeout) — state в одинаковом
    // финальном виде.
    _stopCcStreams(); // §122 — гасим стримы + screenClient
    _emit(
      _state.copyWith(
        tunnel: TunnelStatus.revoked,
        // §140 — НЕ «another VPN may have taken over»: heartbeat-таймаут НЕ значит
        // перехват другим VPN (это синтез на стороне приложения, не системный
        // onRevoke). Чаще — ядро не отвечает. Прежний текст гнал ложные
        // баг-репорты про «перехват». Реальный системный revoke пишет
        // отдельный foreign-VPN текст (см. _handleStatusEvent, §224).
        lastError: 'Connection lost — VPN tunnel is not responding',
        ccGroups: const <CcGroup>[],
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
