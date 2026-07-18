import 'l10n/get_local_text.dart';
import 'l10n/locale_controller.dart';

/// "2h ago", "3 min ago", "yesterday" etc (night T6-1).
///
/// Pure-function — принимает `now` и `past`, нет зависимости на DateTime.now
/// (легко тестировать). §285 — слова через getLocalText (natural keys, ru
/// ICU-плюралы в словаре). Локализатор [t] инъектируется (DI): по умолчанию
/// активный `getLocalText`, в тестах — ru-инстанс напрямую, без глобального
/// LocaleController.
String relativeTime(DateTime now, DateTime past, {GetLocalText? t}) {
  final loc = t ?? getLocalText;
  final diff = now.difference(past);
  // §219 — `< 60` покрывает и отрицательный diff (часы юзера ушли назад /
  // past в будущем): inSeconds там тоже < 60. Отдельная isNegative-проверка
  // была избыточна.
  if (diff.inSeconds < 60) return loc.s("just now");
  if (diff.inMinutes < 60) return loc.plural("%d min ago", diff.inMinutes);
  if (diff.inHours < 24) return loc.plural("%dh ago", diff.inHours);
  if (diff.inDays == 1) return loc.s("yesterday");
  if (diff.inDays < 7) return loc.plural("%dd ago", diff.inDays);
  if (diff.inDays < 30) return loc.plural("%dw ago", (diff.inDays / 7).floor());
  if (diff.inDays < 365) {
    return loc.plural("%dmo ago", (diff.inDays / 30).floor());
  }
  return loc.plural("%dy ago", (diff.inDays / 365).floor());
}
