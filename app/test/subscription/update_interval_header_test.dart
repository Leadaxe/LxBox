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

  group('§603 nextUpdateIntervalHours', () {
    test('-1 пользователя сервер не переубедит', () {
      expect(nextUpdateIntervalHours(-1, 12), -1);
      expect(nextUpdateIntervalHours(-1, null), -1);
    });

    test('записанное сервером < -1 лечится', () {
      expect(nextUpdateIntervalHours(-7, null), 24);
      expect(nextUpdateIntervalHours(-7, 6), 6);
    });

    test('≥ 0: серверное, иначе текущее', () {
      expect(nextUpdateIntervalHours(24, 12), 12);
      expect(nextUpdateIntervalHours(24, null), 24);
      expect(nextUpdateIntervalHours(0, 5), 5);
    });
  });
}
