import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/subscriptions_screen/clipboard_analysis.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';

import '../parser/engine_test_setup.dart';

// §511 m3 — карточка буфера обмена на экране Servers идёт через словарь:
// заголовок подставляется в «Detected: %s», и английский литерал модели
// показывался русскоязычному пользователю как есть.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  setUp(() => LocaleController.I.bootstrap('ru'));
  tearDown(() => LocaleController.I.bootstrap('system'));

  test('ru: заголовки карточки из словаря', () {
    expect(analyzeClipboard('https://example.com/sub/abc').title,
        'URL подписки');
    expect(
        analyzeClipboard('vless://11111111-1111-1111-1111-111111111111'
                '@198.51.100.1:443?security=tls#One')
            .title,
        'Ссылка VLESS');
  });

  test('ru: счётчики карточки sing-box склоняются', () {
    final config = jsonEncode({
      'outbounds': [
        for (var i = 1; i <= 2; i++)
          {
            'type': 'trojan',
            'tag': 't$i',
            'server': 'example-$i.com',
            'server_port': 443,
            'password': 'p$i',
          },
      ],
    });
    final a = analyzeClipboard(config);
    expect(a.title, 'Конфиг sing-box');
    expect(a.subtitle, '2 узла');
  });
}
