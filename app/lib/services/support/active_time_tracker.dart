import 'support_state.dart';

/// §105 — накопительный счётчик времени работы туннеля (секунды).
///
/// Хуки из `home_screen._onControllerChange`:
/// - транзишен `connected ↔ не-connected` → [onTunnelChanged];
/// - каждый notify при connected (traffic-poll ~1с) → [tick] — сам решает,
///   пора ли флашить (раз в [_flushEvery]), чтобы kill процесса терял
///   максимум минуту хвоста.
class ActiveTimeTracker {
  ActiveTimeTracker._();
  static final ActiveTimeTracker I = ActiveTimeTracker._();

  static const _key = 'active_seconds';
  static const _flushEvery = Duration(minutes: 1);

  DateTime? _lastFlush; // != null ⇔ туннель up; докуда уже долили.

  /// Суммарное активное время: persist + хвост текущей сессии.
  Future<int> totalSeconds() async {
    final persisted = await SupportState.I.getInt(_key);
    final from = _lastFlush;
    if (from == null) return persisted;
    final live = DateTime.now().difference(from).inSeconds;
    return persisted + (live > 0 ? live : 0);
  }

  Future<void> onTunnelChanged(bool up) async {
    if (up) {
      _lastFlush ??= DateTime.now();
    } else {
      await _flush();
      _lastFlush = null;
    }
  }

  Future<void> tick() async {
    final from = _lastFlush;
    if (from == null) return;
    if (DateTime.now().difference(from) < _flushEvery) return;
    await _flush();
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
    _lastFlush = now;
  }

  /// Для тестов — сброс сессии.
  void resetForTesting() => _lastFlush = null;
}
