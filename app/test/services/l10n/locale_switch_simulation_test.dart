import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/ui_msg.dart';
import 'package:lxbox/services/l10n/l10n.dart';
import 'package:lxbox/services/relative_time.dart';

// §279 Phase 5 — симуляция смены локали на живых lazy-рендер объектах:
// один и тот же сохранённый объект (NodeWarning в подписке, UiMsg в
// home_state.lastError, relativeTime в subtitle) после переключения
// L10n.current рендерится по-русски через render(l)-путь, а machine-путь
// renderEn() остаётся байт-в-байт английским (spec §4.4).
void main() {
  final cyrillic = RegExp('[а-яА-ЯёЁ]');
  final now = DateTime(2026, 4, 22, 12, 0);
  final past = now.subtract(const Duration(minutes: 5));

  test('смена L10n.current en→ru: render(l) русеет, renderEn() неизменен', () {
    // Типизированные объекты, «сохранённые» до смены локали.
    const warning = UnsupportedTransportWarning('xhttp', 'httpupgrade');
    const error = ErrMsg(ErrKey.failedToStartVpn);

    // Рендер под английской локалью (дефолт L10n.current).
    expect(L10n.current.localeName, 'en');
    final warnBefore = warning.message(L10n.current);
    final errBefore = error.render(L10n.current);
    final relBefore = relativeTime(L10n.current, now, past);
    expect(warnBefore, isNot(contains(cyrillic)));
    expect(errBefore, 'Failed to start VPN');
    expect(relBefore, '5 min ago');

    // Machine-рендер до переключения.
    final warnEnBefore = warning.renderEn();
    final errEnBefore = error.renderEn();

    final saved = L10n.current;
    L10n.current = lookupAppLocalizations(const Locale('ru'));
    try {
      // render(l)-путь: те же объекты теперь дают русский текст,
      // wire-интерполяции (transport-имена) проходят verbatim.
      final warnAfter = warning.message(L10n.current);
      expect(warnAfter, contains(cyrillic));
      expect(warnAfter, contains('xhttp'));
      expect(warnAfter, contains('httpupgrade'));

      final errAfter = error.render(L10n.current);
      expect(errAfter, contains(cyrillic));
      expect(errAfter, isNot(errBefore));

      final relAfter = relativeTime(L10n.current, now, past);
      expect(relAfter, '5 минут назад');

      // renderEn()-путь (AppLog / Debug API / automation) — не дрогнул.
      expect(warning.renderEn(), warnEnBefore);
      expect(error.renderEn(), errEnBefore);
      expect(error.renderEn(), 'Failed to start VPN');
      expect(relativeTime(L10n.en, now, past), '5 min ago');
    } finally {
      L10n.current = saved;
    }
  });
}
