import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/background_mode.dart';
import 'package:lxbox/services/settings_storage.dart' show TunAppsConfig;

/// §293 — валидаторы enum-настроек на моделях (единый источник для storage-
/// сеттеров и Debug write-путей; раньше инлайн-списки в обоих).
void main() {
  group('BackgroundMode.isValid', () {
    test('never/lazy/always → true', () {
      expect(BackgroundMode.isValid('never'), isTrue);
      expect(BackgroundMode.isValid('lazy'), isTrue);
      expect(BackgroundMode.isValid('always'), isTrue);
    });
    test('мусор → false (в отличие от fromNative, который fallback в never)', () {
      expect(BackgroundMode.isValid('garbage'), isFalse);
      expect(BackgroundMode.isValid(''), isFalse);
      expect(BackgroundMode.isValid('NEVER'), isFalse);
      // Контраст: fromNative глушит мусор в never (не бросает).
      expect(BackgroundMode.fromNative('garbage'), BackgroundMode.never);
    });
  });

  group('TunAppsConfig.isValidMode', () {
    test('off/allow/deny → true', () {
      expect(TunAppsConfig.isValidMode('off'), isTrue);
      expect(TunAppsConfig.isValidMode('allow'), isTrue);
      expect(TunAppsConfig.isValidMode('deny'), isTrue);
    });
    test('мусор → false', () {
      expect(TunAppsConfig.isValidMode('block'), isFalse);
      expect(TunAppsConfig.isValidMode(''), isFalse);
    });
  });
}
