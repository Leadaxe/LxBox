import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/subscription/sources.dart';

import '../parser/engine_test_setup.dart';

/// §603 — серверный `profile-update-interval`: отрицательное значение не
/// принимается и не замораживает автообновление.
void main() {
  setUpAll(loadEngineSections);

  group('§603 parseUpdateIntervalHeader', () {
    test('отрицательное и мусор → null, ≥ 0 → число', () {
      expect(parseUpdateIntervalHeader('-5'), isNull);
      expect(parseUpdateIntervalHeader('-1'), isNull);
      expect(parseUpdateIntervalHeader('abc'), isNull);
      expect(parseUpdateIntervalHeader(null), isNull);
      expect(parseUpdateIntervalHeader(' 12 '), 12);
      expect(parseUpdateIntervalHeader('0'), 0);
    });

    test('заголовок -5 в ответе → meta без интервала', () {
      final r = parseFetched(const FetchResult(
        'vless://u@h:443?type=ws&security=tls#A\n',
        null,
        {'profile-update-interval': '-5', 'profile-title': 'x'},
      ));
      expect(r.meta, isNotNull);
      expect(r.meta!.updateIntervalHours, isNull);
    });
  });

  group('§685 nextUpdateIntervalHours', () {
    test('выбор пользователя фетч не меняет', () {
      expect(nextUpdateIntervalHours(-1), -1);
      expect(nextUpdateIntervalHours(0), 0);
      expect(nextUpdateIntervalHours(12), 12);
    });

    test('записанное сервером до §603 < -1 → «As subscription»', () {
      expect(nextUpdateIntervalHours(-7), 0);
    });
  });

  group('§685 effectiveUpdateIntervalHours', () {
    test('«As subscription»: серверное, без заголовка 24', () {
      expect(effectiveUpdateIntervalHours(0, 3), 3);
      expect(effectiveUpdateIntervalHours(0, 0), 0);
      expect(effectiveUpdateIntervalHours(0, null), 24);
    });

    test('ручное и -1 сильнее сервера', () {
      expect(effectiveUpdateIntervalHours(12, 3), 12);
      expect(effectiveUpdateIntervalHours(-1, 3), -1);
    });
  });
}
