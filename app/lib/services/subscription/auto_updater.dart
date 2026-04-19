import 'dart:async';
import 'dart:math';

import '../../controllers/subscription_controller.dart';
import '../../models/server_list.dart';
import '../app_log.dart';

/// Триггеры, по которым зовётся `maybeUpdateAll`. Нужны только для
/// телеметрии/логов — логика решения «пора?» одинаковая.
enum UpdateTrigger {
  appStart,      // init app
  vpnConnected,  // +2 мин после VPN connected
  periodic,      // раз в час
  vpnStopped,    // сразу по VPN disconnected
  manual,        // юзер нажал ⟳ (force=true)
}

/// Авто-обновление подписок по 4 триггерам (§026 спека).
///
/// Параметры фиксированы (в спеке документированы):
/// - `updateIntervalHours` берётся с каждой подписки (default 24, из
///   `profile-update-interval`).
/// - `minRetryInterval` = 15 мин — между повторами той же подписки.
/// - `maxFailsPerSession` = 5 — после 5 фейлов подряд подписка «парится»
///   до следующего app start.
/// - `perSubscriptionDelay` = 10 сек — между fetch'ами подписок внутри
///   одного прохода (чтобы не нагружать провайдеров).
class AutoUpdater {
  AutoUpdater(this._subController);
  final SubscriptionController _subController;

  static const Duration minRetryInterval = Duration(minutes: 15);
  static const int maxFailsPerSession = 5;
  static const Duration perSubscriptionDelay = Duration(seconds: 10);
  static const Duration postVpnConnectedDelay = Duration(minutes: 2);
  static const Duration periodicInterval = Duration(hours: 1);

  Timer? _periodicTimer;
  Timer? _postVpnTimer;
  bool _running = false;

  /// Счётчики фейлов только в памяти; сбрасываются при перезапуске app.
  final Map<String, int> _failCounts = {};

  /// Для dedup'а параллельных запусков одной и той же подписки.
  final Set<String> _inFlight = {};

  /// Вызвать один раз при init приложения (из `SubscriptionController.init`
  /// или `main.dart`). Запускает trigger #1 и взводит periodic-таймер.
  void start() {
    _periodicTimer ??= Timer.periodic(periodicInterval, (_) {
      unawaited(maybeUpdateAll(UpdateTrigger.periodic));
    });
    unawaited(maybeUpdateAll(UpdateTrigger.appStart));
  }

  /// Зовёт `HomeController` на transition → `connected`.
  /// Планирует попытку через 2 минуты (не сразу — даёт туннелю устояться).
  void onVpnConnected() {
    _postVpnTimer?.cancel();
    _postVpnTimer = Timer(postVpnConnectedDelay, () {
      unawaited(maybeUpdateAll(UpdateTrigger.vpnConnected));
    });
  }

  /// Зовёт `HomeController` на transition → `disconnected`.
  void onVpnStopped() {
    _postVpnTimer?.cancel();
    unawaited(maybeUpdateAll(UpdateTrigger.vpnStopped));
  }

  void dispose() {
    _periodicTimer?.cancel();
    _postVpnTimer?.cancel();
    _periodicTimer = null;
    _postVpnTimer = null;
  }

  /// Manual force refresh одной подписки — сбрасывает `failCount`,
  /// пропускает min-retry cap. Зовётся из `SubscriptionController.updateAt`.
  void resetFailCount(String url) => _failCounts.remove(url);

  /// Manual force refresh всех подписок (кнопка ⟳ на Servers).
  void resetAllFailCounts() => _failCounts.clear();

  /// Пройтись по всем подпискам и обновить те, которым пора.
  /// Последовательно, с задержкой 10с между подписками.
  Future<void> maybeUpdateAll(UpdateTrigger trigger,
      {bool force = false}) async {
    if (_running) {
      AppLog.I.debug('AutoUpdater: skip ${trigger.name} — already running');
      return;
    }
    _running = true;
    AppLog.I.info('AutoUpdater: trigger=${trigger.name}${force ? ' force' : ''}');

    try {
      final candidates = <SubscriptionEntry>[];
      for (final entry in _subController.entries) {
        if (!_shouldUpdate(entry, force: force)) continue;
        candidates.add(entry);
      }
      if (candidates.isEmpty) {
        AppLog.I.debug('AutoUpdater: no candidates');
        return;
      }
      AppLog.I.info('AutoUpdater: ${candidates.length} to refresh');

      for (var i = 0; i < candidates.length; i++) {
        final entry = candidates[i];
        final url = (entry.list as SubscriptionServers).url;
        if (_inFlight.contains(url)) continue;
        _inFlight.add(url);
        try {
          await _subController.refreshEntry(entry, trigger: trigger);
          final fresh = entry.list;
          if (fresh is SubscriptionServers &&
              fresh.lastUpdateStatus == UpdateStatus.ok) {
            _failCounts.remove(url);
          } else {
            _failCounts[url] = (_failCounts[url] ?? 0) + 1;
          }
        } catch (e) {
          _failCounts[url] = (_failCounts[url] ?? 0) + 1;
          AppLog.I.warning('AutoUpdater: ${entry.displayName} fail: $e');
        } finally {
          _inFlight.remove(url);
        }

        if (i < candidates.length - 1) {
          // 10с ± джиттер ±2с — чтобы два app'а не стучали в одну миллисекунду.
          final jitter = Random().nextInt(4000) - 2000;
          await Future<void>.delayed(
              perSubscriptionDelay + Duration(milliseconds: jitter));
        }
      }
    } finally {
      _running = false;
    }
  }

  bool _shouldUpdate(SubscriptionEntry entry, {required bool force}) {
    final list = entry.list;
    if (list is! SubscriptionServers) return false;
    if (!list.enabled) return false;

    // Fail-cap: после 5 фейлов подписка замораживается до следующего app start.
    final fails = _failCounts[list.url] ?? 0;
    if (!force && fails >= maxFailsPerSession) return false;

    if (force) return true;

    final now = DateTime.now();

    // Min-retry: не пытаться чаще 15 мин, даже если `updateIntervalHours`
    // прошёл. Защищает от fail-шторма на каждом триггере.
    final lastTry = list.lastUpdateAttempt;
    if (lastTry != null && now.difference(lastTry) < minRetryInterval) {
      return false;
    }

    // Основное: пора по успешному времени?
    final lastOk = list.lastUpdated;
    if (lastOk == null) return true;
    final interval = Duration(hours: list.updateIntervalHours);
    return now.difference(lastOk) >= interval;
  }
}
