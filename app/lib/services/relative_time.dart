import 'l10n/l10n.dart';

/// "2h ago", "3 min ago", "yesterday" etc (night T6-1).
///
/// Pure-function — принимает `now` и `past`, нет зависимости на DateTime.now
/// (легко тестировать). §279 Phase 5 — слова через ARB (ICU-плюралы в ru);
/// принимает [AppLocalizations] параметром (render-path по построению, §9.4).
String relativeTime(AppLocalizations l, DateTime now, DateTime past) {
  final diff = now.difference(past);
  // §219 — `< 60` покрывает и отрицательный diff (часы юзера ушли назад /
  // past в будущем): inSeconds там тоже < 60. Отдельная isNegative-проверка
  // была избыточна.
  if (diff.inSeconds < 60) return l.relTimeJustNow;
  if (diff.inMinutes < 60) return l.relTimeMinutesAgo(diff.inMinutes);
  if (diff.inHours < 24) return l.relTimeHoursAgo(diff.inHours);
  if (diff.inDays == 1) return l.relTimeYesterday;
  if (diff.inDays < 7) return l.relTimeDaysAgo(diff.inDays);
  if (diff.inDays < 30) return l.relTimeWeeksAgo((diff.inDays / 7).floor());
  if (diff.inDays < 365) return l.relTimeMonthsAgo((diff.inDays / 30).floor());
  return l.relTimeYearsAgo((diff.inDays / 365).floor());
}
