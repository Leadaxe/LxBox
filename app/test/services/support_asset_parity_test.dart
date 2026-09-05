import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// §422 — bundled-копия ленты `assets/support.json` обязана быть байт-в-байт
/// равна источнику `docs/support.json`: без согласия на сеть приложение
/// показывает именно её, и разъехавшаяся копия молча раздаёт устаревшие
/// тексты/ссылки (прецедент — `assets/donate.json`, отставший от
/// `docs/donate.json`). Правишь ленту → `cp docs/support.json app/assets/`.
void main() {
  test('assets/support.json == docs/support.json', () {
    // `flutter test` запускается из `app/`.
    final asset = File('assets/support.json').readAsStringSync();
    final source = File('../docs/support.json').readAsStringSync();
    expect(asset, source,
        reason: 'скопируй: cp docs/support.json app/assets/support.json');
  });
}
