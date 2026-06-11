import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/subscription/user_agent.dart';

// Гард фикса «панель отдаёт JSON-конфиг вместо списка подписки». Инварианты:
//   - бренд-токен начинается с `LxBox-android/` — по нему substring-панели
//     (Remnawave/Marzban) опознают клиента и отдают base64/URI-список
//     (проверено на боевой vern13);
//   - голого `singbox` (без дефиса, триггер бага) нет нигде; токен `sing-box`
//     сознательно не включаем вовсе (см. таск 114).
void main() {
  group('buildSubscriptionUserAgent — panel-routing invariants', () {
    test('типичные Android-значения дают ожидаемую строку', () {
      final ua = buildSubscriptionUserAgent(
        appVersion: '2.0.4',
        platform: 'android 34 arm64-v8a',
      );
      expect(ua, 'LxBox-android/2.0.4 (android 34 arm64-v8a)');
    });

    test('начинается с бренд-токена LxBox-android/', () {
      final ua = buildSubscriptionUserAgent(appVersion: '2.0.4');
      expect(ua.startsWith('LxBox-android/'), isTrue, reason: ua);
    });

    test('никогда не содержит "singbox" / "sing-box"', () {
      final ua = buildSubscriptionUserAgent(appVersion: '2.0.4');
      expect(ua.contains('singbox'), isFalse, reason: ua);
      expect(ua.contains('sing-box'), isFalse, reason: ua);
    });

    test('срезает ведущий v и держит инварианты на пустом appVersion', () {
      final ua = buildSubscriptionUserAgent(appVersion: '');
      expect(ua, 'LxBox-android/unknown (android)');
      expect(ua.startsWith('LxBox-android/'), isTrue, reason: ua);
      expect(ua.contains('singbox'), isFalse, reason: ua);
    });

    test('мусор/скобки в токенах не ломают структуру UA', () {
      final ua = buildSubscriptionUserAgent(
        appVersion: 'v2.0.4 (dev)',
        platform: '   ',
      );
      // ведущий v срезан, скобки/пробелы вырезаны, пустая платформа → android
      expect(ua, 'LxBox-android/2.0.4dev (android)');
      expect(ua.contains('singbox'), isFalse, reason: ua);
    });
  });
}
