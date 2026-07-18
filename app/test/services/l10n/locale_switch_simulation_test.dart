import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/ui_msg.dart';
import 'package:lxbox/services/l10n/get_local_text.dart';
import 'package:lxbox/services/l10n/plural_resolver.dart';

// §285 — симуляция смены локали на живых lazy-рендер объектах: один и тот же
// сохранённый объект (NodeWarning в подписке, UiMsg в home_state.lastError)
// рендерится по-русски через renderWith(ru)-путь (активная локаль = словарь
// assets/l10n/ru/ui.json), а machine-путь renderEn() остаётся байт-в-байт
// английским (spec §4.4).
GetLocalText _loadRu() {
  final raw = File('assets/l10n/ru/ui.json').readAsStringSync();
  final dict = jsonDecode(raw) as Map<String, dynamic>;
  return GetLocalText(dict, const RuPluralResolver());
}

void main() {
  final cyrillic = RegExp('[а-яА-ЯёЁ]');
  final ru = _loadRu();

  test('renderWith(ru) русеет, renderEn() неизменен', () {
    // Типизированные объекты, «сохранённые» до смены локали.
    const warning = UnsupportedTransportWarning('xhttp', 'httpupgrade');
    const error = ErrMsg(ErrKey.failedToStartVpn);

    // Machine-рендер (AppLog / Debug API / automation) — всегда английский.
    expect(warning.renderEn(), isNot(contains(cyrillic)));
    expect(error.renderEn(), 'Failed to start VPN');

    // render-путь под русским словарём: те же объекты дают русский текст,
    // wire-интерполяции (transport-имена) проходят verbatim.
    final warnRu = warning.messageWith(ru);
    expect(warnRu, contains(cyrillic));
    expect(warnRu, contains('xhttp'));
    expect(warnRu, contains('httpupgrade'));

    final errRu = error.renderWith(ru);
    expect(errRu, contains(cyrillic));
    expect(errRu, isNot(error.renderEn()));

    // renderEn()-путь не дрогнул после русского рендера.
    expect(warning.renderEn(), isNot(contains(cyrillic)));
    expect(error.renderEn(), 'Failed to start VPN');
  });
}
