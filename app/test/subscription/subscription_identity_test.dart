import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/subscription/subscription_identity.dart';

void main() {
  group('§118 generateUuidV4', () {
    test('формат 8-4-4-4-12, version 4, variant', () {
      final u = generateUuidV4();
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(u),
        isTrue,
        reason: 'got $u',
      );
    });

    test('два вызова различны', () {
      expect(generateUuidV4(), isNot(generateUuidV4()));
    });
  });

  group('§118 SubscriptionIdentity.fetchHeaders', () {
    setUp(() {
      SubscriptionIdentity.sendHwid = false;
      SubscriptionIdentity.hwid = '';
      SubscriptionIdentity.osVersion = '';
      SubscriptionIdentity.deviceModel = '';
    });

    test('sendHwid=false → пусто', () {
      SubscriptionIdentity.sendHwid = false;
      SubscriptionIdentity.hwid = 'abc';
      expect(SubscriptionIdentity.fetchHeaders(), isEmpty);
    });

    test('sendHwid=true, hwid пуст → пусто (нечего слать)', () {
      SubscriptionIdentity.sendHwid = true;
      SubscriptionIdentity.hwid = '';
      expect(SubscriptionIdentity.fetchHeaders(), isEmpty);
    });

    test('sendHwid=true + hwid → x-hwid + x-device-os; meta только при наличии',
        () {
      SubscriptionIdentity.sendHwid = true;
      SubscriptionIdentity.hwid = 'HW-1';
      final bare = SubscriptionIdentity.fetchHeaders();
      expect(bare['x-hwid'], 'HW-1');
      expect(bare['x-device-os'], 'android');
      expect(bare.containsKey('x-ver-os'), isFalse);
      expect(bare.containsKey('x-device-model'), isFalse);

      SubscriptionIdentity.osVersion = '14';
      SubscriptionIdentity.deviceModel = 'Pixel 7';
      final full = SubscriptionIdentity.fetchHeaders();
      expect(full['x-ver-os'], '14');
      expect(full['x-device-model'], 'Pixel 7');
    });
  });

  group('§118 apply trim', () {
    test('apply триммит override/hwid', () {
      SubscriptionIdentity.apply(userAgentOverride: '  MyUA  ', hwid: '  H  ');
      expect(SubscriptionIdentity.userAgentOverride, 'MyUA');
      expect(SubscriptionIdentity.hwid, 'H');
    });
  });
}
