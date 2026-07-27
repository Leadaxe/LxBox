import 'package:flutter/foundation.dart';

import 'app_log.dart';
import 'settings_storage.dart';
import 'stderr_reader.dart';

/// §316 — «ядро падало» — плашка на главном, ОДИН раз на краш.
///
/// Почему отдельный notifier, а не поле `HomeState`: `HomeState` — проекция
/// состояния туннеля, живущая в `HomeController`. Этот же факт приходит с
/// ФАЙЛОВОЙ СИСТЕМЫ (архив ядра) и storage-отметки, читается один раз на
/// старте и к жизненному циклу VPN отношения не имеет. Держать его в
/// `HomeState` — размывать смысл модели ради одного bool'а.
///
/// «Один раз» привязано к КОНКРЕТНОМУ крашу, не к факту показа: в storage
/// лежит `имя@mtime` последнего показанного файла ([CrashReports.stamp]).
/// Совпал с самым свежим — молчим (повторный запуск); не совпал —
/// показываем (новый краш). Счётчик показов дал бы либо «показали дважды»,
/// либо «новый краш промолчал».
class CrashBannerState extends ChangeNotifier {
  CrashBannerState._();

  static final CrashBannerState I = CrashBannerState._();

  CrashReportFile? _pending;

  /// Репорт, про который надо сказать пользователю; `null` — говорить не о чем.
  CrashReportFile? get pending => _pending;

  /// Читает архив, сравнивает самый свежий репорт с отметкой в storage.
  /// Best-effort: любая ошибка = молчим (диагностика не должна ломать старт).
  Future<void> refresh() async {
    try {
      final reports = await CrashReports.list();
      if (reports.isEmpty) {
        _set(null);
        return;
      }
      final latest = reports.first;
      final shown = await SettingsStorage.getShownCrashStamp();
      _set(CrashReports.stamp(latest) == shown ? null : latest);
    } catch (e) {
      AppLog.I.warning('Crash banner check failed: $e');
      _set(null);
    }
  }

  /// Пользователь увидел плашку и среагировал (или закрыл) — про ЭТОТ краш
  /// больше не напоминаем. Отметку пишем до скрытия, чтобы падение записи
  /// не «съело» баннер молча.
  Future<void> markShown() async {
    final p = _pending;
    if (p == null) return;
    try {
      await SettingsStorage.setShownCrashStamp(CrashReports.stamp(p));
    } catch (e) {
      AppLog.I.warning('Crash banner stamp save failed: $e');
    }
    _set(null);
  }

  void _set(CrashReportFile? v) {
    if (_pending?.path == v?.path && _pending?.mtime == v?.mtime) return;
    _pending = v;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _pending = null;
  }
}
