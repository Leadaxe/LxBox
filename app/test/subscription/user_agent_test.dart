import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/subscription/user_agent.dart';

// Гард фикса «панель отдаёт JSON-конфиг вместо списка подписки». Инварианты:
//   - бренд-токен начинается с `LxBox-android/` — по нему substring-панели
//     (Remnawave/Marzban) опознают клиента и отдают base64/URI-список
//     (проверено на боевой vern13);
//   - голого `singbox` (без дефиса, триггер бага) нет нигде; токена `sing-box`
//     и платформенного комментария тоже нет (см. таск 114).
void main() {
  group('buildSubscriptionUserAgent — panel-routing invariants', () {
    test('версия даёт ожидаемую строку', () {
      expect(
        buildSubscriptionUserAgent(appVersion: '2.0.4'),
        'LxBox-android/2.0.4',
      );
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

    test('держит dev-версию с дефисами', () {
      expect(
        buildSubscriptionUserAgent(appVersion: '2.0.3-dev.2'),
        'LxBox-android/2.0.3-dev.2',
      );
    });

    test('срезает ведущий v и держит инварианты на пустом appVersion', () {
      expect(buildSubscriptionUserAgent(appVersion: ''), 'LxBox-android/unknown');
      expect(buildSubscriptionUserAgent(appVersion: 'v2.0.4'), 'LxBox-android/2.0.4');
    });

    test('мусор/скобки/пробелы в версии не ломают структуру UA', () {
      final ua = buildSubscriptionUserAgent(appVersion: 'v2.0.4 (dev)');
      expect(ua, 'LxBox-android/2.0.4dev');
      expect(ua.contains('singbox'), isFalse, reason: ua);
    });
  });

  // §610 — пресеты UA популярных клиентов для поля Custom User-Agent.
  group('kUserAgentPresets', () {
    test('первый пресет — дефолт LxBox (пустая строка)', () {
      expect(kUserAgentPresets.first.value, isEmpty);
      expect(kUserAgentPresets.skip(1).every((p) => p.value.isNotEmpty),
          isTrue);
    });

    test('строки и подписи уникальны', () {
      final values = kUserAgentPresets.map((p) => p.value).toList();
      final labels = kUserAgentPresets.map((p) => p.label).toList();
      expect(values.toSet().length, values.length);
      expect(labels.toSet().length, labels.length);
    });

    test('без переводов строк, управляющих символов и краевых пробелов', () {
      final ctrl = RegExp(r'[\x00-\x1F\x7F]');
      for (final p in kUserAgentPresets) {
        expect(ctrl.hasMatch(p.value), isFalse, reason: p.label);
        expect(p.value, p.value.trim(), reason: p.label);
      }
    });
  });
}
