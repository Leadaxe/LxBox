import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/telegram_link.dart';

void main() {
  group('§657 isTelegramUrl', () {
    test('Telegram links', () {
      for (final u in [
        'tg://resolve?domain=assassinvpnsupport',
        'TG://resolve?domain=x',
        'https://t.me/support',
        'http://www.t.me/support',
        'https://telegram.me/support',
        'https://telegram.dog/support',
      ]) {
        expect(isTelegramUrl(u), isTrue, reason: u);
      }
    });
    test('not Telegram', () {
      for (final u in [
        '',
        'https://example.com/t.me',
        'https://not.me/x',
        'https://t.me.example.com/x',
        'mailto:support@t.me',
      ]) {
        expect(isTelegramUrl(u), isFalse, reason: u);
      }
    });
  });

  group('§657 telegramWebFallback', () {
    test('tg:// forms with a web twin', () {
      expect(telegramWebFallback('tg://resolve?domain=assassinvpnsupport'),
          'https://t.me/assassinvpnsupport');
      expect(telegramWebFallback('tg://resolve?domain=chan&post=42'),
          'https://t.me/chan/42');
      expect(telegramWebFallback('tg://join?invite=AbC_d'),
          'https://t.me/+AbC_d');
    });
    test('no web twin', () {
      expect(telegramWebFallback('https://t.me/x'), isNull);
      expect(telegramWebFallback('tg://resolve'), isNull);
      expect(telegramWebFallback('tg://msg?text=hi'), isNull);
    });
  });
}
