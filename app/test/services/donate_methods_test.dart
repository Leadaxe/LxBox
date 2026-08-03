import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/donate_methods.dart';

/// §362 — разбор способов поддержки (`docs/donate.json` / bundled-копия).
void main() {
  group('DonateMethod.fromJson', () {
    test('crypto: адрес обязателен, note опционален', () {
      final m = DonateMethod.fromJson({
        'id': 'usdt-trc20',
        'kind': 'crypto',
        'title': 'USDT · TRON (TRC20)',
        'address': 'TBBEANE',
        'url': 'https://link.trustwallet.com/send?coin=195',
      })!;
      expect(m.isCrypto, true);
      expect(m.address, 'TBBEANE');
      expect(m.note, isNull);
    });

    test('link: без адреса — валиден', () {
      final m = DonateMethod.fromJson({
        'id': 'boosty',
        'kind': 'link',
        'title': 'Boosty',
        'url': 'https://boosty.to/lxbox/donate',
        'note': 'Карты, СБП',
      })!;
      expect(m.isCrypto, false);
      expect(m.note, 'Карты, СБП');
    });

    test('битые записи отбрасываются', () {
      // crypto без адреса — показывать нечего.
      expect(
          DonateMethod.fromJson({
            'id': 'x',
            'kind': 'crypto',
            'title': 'X',
            'url': 'https://x',
          }),
          isNull);
      // нет обязательных полей.
      expect(DonateMethod.fromJson({'id': 'x', 'title': 'X'}), isNull);
      expect(DonateMethod.fromJson({'kind': 'link', 'url': 'https://x'}), isNull);
      expect(DonateMethod.fromJson('garbage'), isNull);
      expect(DonateMethod.fromJson(null), isNull);
    });

    test('kind по умолчанию — link', () {
      final m = DonateMethod.fromJson(
          {'id': 'x', 'title': 'X', 'url': 'https://x'})!;
      expect(m.kind, 'link');
      expect(m.isCrypto, false);
    });
  });
}
