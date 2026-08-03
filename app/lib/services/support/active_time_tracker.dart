import 'support_state.dart';

/// §105/§356 — накопительный счётчик времени работы туннеля (секунды).
///
/// v2 (§356): первичный источник — нативный аптайм текущей сессии
/// ([uptimeMsProvider] → `BoxVpnClient.getTunnelUptimeMs`, §187: монотонные
/// часы в native-сервисе, переживает смахивание приложения). Зачисление —
/// разницей `uptime − session_credited`, где `session_credited` (persist) =
/// сколько секунд ТЕКУЩЕЙ сессии уже в `active_seconds`. Открыли приложение
/// после суток VPN при мёртвом UI → недостающее доливается одним куском.
///
/// Детектор перезапуска туннеля — `uptime < credited` (без wall-clock ключей:
/// скачки системных часов не задваивают). Быстрый рестарт за спиной мёртвого
/// UI даёт недосчёт (безопасное направление), не двойной счёт. Кейс
/// «смахнул → VPN отработал → VPN остановлен → открыл» не доливается: аптайм
/// уже 0, доливать не с чего (честная потеря без постоянного native-учёта).
///
/// Хуки из `home_screen._onControllerChange`:
/// - транзишен `connected ↔ не-connected` → [onTunnelChanged];
/// - каждый notify при connected (traffic-poll ~1с) → [tick] — сам решает,
///   пора ли зачислять (раз в [_flushEvery]), чтобы kill процесса терял
///   максимум минуту хвоста.
///
/// [uptimeMsProvider] не подключён (тесты) → legacy wall-clock учёт v1
/// (`_lastFlush`) без изменений.
class ActiveTimeTracker {
  ActiveTimeTracker._();
  static final ActiveTimeTracker I = ActiveTimeTracker._();

  static const _key = 'active_seconds';
  static const _creditedKey = 'session_credited';
  static const _flushEvery = Duration(minutes: 1);

  /// §356 — нативный аптайм текущей сессии туннеля, мс (0 = не запущен).
  /// Подключается в `home_screen.initState` (`_vpn.getTunnelUptimeMs`).
  Future<int> Function()? uptimeMsProvider;

  DateTime? _lastFlush; // legacy-режим: != null ⇔ туннель up; докуда долили.
  DateTime? _lastCredit; // native-режим: троттлинг tick'а.
  Future<void>? _crediting; // in-flight замок: параллельные credit не задваивают.

  /// Суммарное активное время. Native-режим: сперва зачисляем свежий аптайм,
  /// отдаём persist. Legacy: persist + live-хвост текущей сессии.
  Future<int> totalSeconds() async {
    if (uptimeMsProvider != null) {
      await _credit();
      return SupportState.I.getInt(_key);
    }
    final persisted = await SupportState.I.getInt(_key);
    final from = _lastFlush;
    if (from == null) return persisted;
    final live = DateTime.now().difference(from).inSeconds;
    return persisted + (live > 0 ? live : 0);
  }

  Future<void> onTunnelChanged(bool up) async {
    if (uptimeMsProvider != null) {
      if (up) {
        await _credit();
      } else {
        // Сессия закрыта: аптайм у native уже 0, хвост с последнего кредита
        // (≤ 1 мин, tick-каденс) теряется — как в v1. Сбрасываем счётчик
        // сессии, чтобы следующая начала зачисление с нуля.
        await SupportState.I.set(_creditedKey, 0);
      }
      return;
    }
    // --- legacy wall-clock (провайдера нет: тесты) ---
    if (up) {
      _lastFlush ??= DateTime.now();
    } else {
      await _flush();
      _lastFlush = null;
    }
  }

  Future<void> tick() async {
    if (uptimeMsProvider != null) {
      final last = _lastCredit;
      if (last != null && DateTime.now().difference(last) < _flushEvery) {
        return;
      }
      await _credit();
      return;
    }
    // --- legacy ---
    final from = _lastFlush;
    if (from == null) return;
    if (DateTime.now().difference(from) < _flushEvery) return;
    await _flush();
  }

  /// Native-зачисление под in-flight замком: tick и totalSeconds (decide-путь)
  /// могут прийти одновременно — без замка оба прочитали бы одинаковый
  /// `credited` и задвоили delta.
  Future<void> _credit() {
    final inFlight = _crediting;
    if (inFlight != null) return inFlight;
    final f = _doCredit().whenComplete(() => _crediting = null);
    _crediting = f;
    return f;
  }

  Future<void> _doCredit() async {
    final provider = uptimeMsProvider;
    if (provider == null) return;
    int uptimeMs;
    try {
      uptimeMs = await provider();
    } catch (_) {
      return; // native недоступен — доливка при следующем вызове
    }
    _lastCredit = DateTime.now();
    if (uptimeMs <= 0) return;
    final uptimeSec = uptimeMs ~/ 1000;
    var credited = await SupportState.I.getInt(_creditedKey);
    if (uptimeSec < credited) credited = 0; // туннель перезапускался
    final delta = uptimeSec - credited;
    if (delta <= 0) return;
    final cur = await SupportState.I.getInt(_key);
    await SupportState.I.setAll({_key: cur + delta, _creditedKey: uptimeSec});
  }

  Future<void> _flush() async {
    final from = _lastFlush;
    if (from == null) return;
    final now = DateTime.now();
    final delta = now.difference(from).inSeconds;
    if (delta > 0) {
      final cur = await SupportState.I.getInt(_key);
      await SupportState.I.set(_key, cur + delta);
    }
    // §219 — двигаем базовую точку ТОЛЬКО вперёд. При откате системных часов
    // назад (delta ≤ 0) держим прежний `_lastFlush`: иначе база уехала бы в
    // прошлое и реальный интервал с момента from потерялся бы безвозвратно
    // (а следующий tick досчитает его корректно, когда часы догонят from).
    if (delta > 0) _lastFlush = now;
  }

  /// Для тестов — сброс сессии и провайдера.
  void resetForTesting() {
    _lastFlush = null;
    _lastCredit = null;
    _crediting = null;
    uptimeMsProvider = null;
  }
}
