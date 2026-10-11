// §835 — журнал скана: формат строк, копируемый текст, кольцевой буфер.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/scan_log.dart';

void main() {
  test('строки форматируются с уровнем, тегом и временем', () {
    final log = ScanLog();
    log.i('p1', 'привет');
    log.e('p2', 'ошибка');
    final t = log.text;
    expect(t, contains('# lxbox endpoint-scan log v1'));
    expect(t, contains('INFO  p1: привет'));
    expect(t, contains('ERROR p2: ошибка'));
    expect(log.length, 2);
  });

  test('кольцевой буфер не растёт выше maxLines', () {
    final log = ScanLog(maxLines: 5);
    for (var i = 0; i < 20; i++) {
      log.d('x', 'строка $i');
    }
    expect(log.length, 5);
    // Остались ПОСЛЕДНИЕ строки.
    expect(log.text, contains('строка 19'));
    expect(log.text, isNot(contains('строка 14')));
  });

  test('clear опустошает журнал', () {
    final log = ScanLog()..i('a', 'b');
    expect(log.isEmpty, isFalse);
    log.clear();
    expect(log.isEmpty, isTrue);
  });
}
