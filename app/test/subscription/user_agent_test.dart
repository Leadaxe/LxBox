import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/subscription/user_agent.dart';

// Гард фикса «панель отдаёт JSON-конфиг вместо списка подписки». Три инварианта
// (зеркалят десктопный useragent_test.go):
//   - бренд-токен начинается с `LxBox-android/` (отличает от desktop-сборки);
//   - присутствует `sing-box/<core>` — по нему substring-панели (Remnawave/
//     Marzban) опознают sing-box-клиента и отдают base64/URI-список;
//   - голого `singbox` (без дефиса, триггер бага) нет нигде.
void main() {
  group('buildSubscriptionUserAgent — panel-routing invariants', () {
    test('типичные Android-значения дают ожидаемую строку', () {
      final ua = buildSubscriptionUserAgent(
        appVersion: '2.0.4',
        coreVersion: '1.13.13-lx.6',
        platform: 'android 34 arm64-v8a',
      );
      expect(
        ua,
        'LxBox-android/2.0.4 (sing-box/1.13.13-lx.6; android 34 arm64-v8a)',
      );
    });

    test('начинается с бренд-токена LxBox-android/', () {
      final ua = buildSubscriptionUserAgent(
        appVersion: '2.0.4',
        coreVersion: '1.13.13-lx.6',
      );
      expect(ua.startsWith('LxBox-android/'), isTrue, reason: ua);
    });

    test('несёт токен распознавания sing-box/<core>', () {
      final ua = buildSubscriptionUserAgent(
        appVersion: '2.0.4',
        coreVersion: '1.13.13-lx.6',
      );
      expect(ua.contains('sing-box/'), isTrue, reason: ua);
    });

    test('никогда не содержит голого "singbox" (триггер бага)', () {
      final ua = buildSubscriptionUserAgent(
        appVersion: '2.0.4',
        coreVersion: '1.13.13-lx.6',
      );
      expect(ua.contains('singbox'), isFalse, reason: ua);
    });

    test('срезает ведущий v у ядра и держит инварианты на пустом appVersion',
        () {
      final ua = buildSubscriptionUserAgent(
        appVersion: '',
        coreVersion: 'v1.13.13-lx.6',
      );
      expect(ua, 'LxBox-android/unknown (sing-box/1.13.13-lx.6; android)');
      expect(ua.startsWith('LxBox-android/'), isTrue, reason: ua);
      expect(ua.contains('sing-box/'), isTrue, reason: ua);
      expect(ua.contains('singbox'), isFalse, reason: ua);
    });

    test('мусор/скобки в токенах не ломают структуру UA', () {
      final ua = buildSubscriptionUserAgent(
        appVersion: '2.0.4 (dev)',
        coreVersion: '',
        platform: '   ',
      );
      // скобки/пробелы вырезаны, пустое ядро → unknown, пустая платформа → android
      expect(ua, 'LxBox-android/2.0.4dev (sing-box/unknown; android)');
      expect(ua.contains('singbox'), isFalse, reason: ua);
    });
  });
}
