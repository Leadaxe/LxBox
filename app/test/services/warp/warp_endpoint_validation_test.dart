import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/warp_account.dart';

/// §606 — свой endpoint WARP проверяется на форму `host:port` до регистрации.
void main() {
  test('валидные формы', () {
    for (final s in [
      WarpAccount.defaultEndpoint,
      '188.114.97.6:988',
      '[2606:4700:d0::a29f:c001]:2408',
      'engage.example-host.com:1',
      'h:65535',
    ]) {
      expect(WarpAccount.isValidEndpoint(s), isTrue, reason: s);
    }
  });

  test('невалидные формы', () {
    for (final s in [
      '',
      '188.114.97.6',
      '188.114.97.6:',
      ':2408',
      'host:0',
      'host:65536',
      'host:99999',
      'host:port',
      '2606:4700::1:2408',
      'bad host:2408',
      'host:2408 ',
      '-host:2408',
    ]) {
      expect(WarpAccount.isValidEndpoint(s), isFalse, reason: s);
    }
  });
}
