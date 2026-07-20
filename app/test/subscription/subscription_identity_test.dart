import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/server_list.dart';
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
      SubscriptionIdentity.deviceOsOverride = '';
      SubscriptionIdentity.verOsOverride = '';
      SubscriptionIdentity.deviceModelOverride = '';
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

    test('override > device-дефолт во всех meta', () {
      SubscriptionIdentity.sendHwid = true;
      SubscriptionIdentity.hwid = 'HW';
      SubscriptionIdentity.osVersion = '14';
      SubscriptionIdentity.deviceModel = 'Pixel 7';
      SubscriptionIdentity.deviceOsOverride = 'harmonyos';
      SubscriptionIdentity.verOsOverride = '4.2';
      SubscriptionIdentity.deviceModelOverride = 'P60';
      final h = SubscriptionIdentity.fetchHeaders();
      expect(h['x-device-os'], 'harmonyos');
      expect(h['x-ver-os'], '4.2');
      expect(h['x-device-model'], 'P60');
    });
  });

  group('§118 apply trim', () {
    test('apply триммит override/hwid', () {
      SubscriptionIdentity.apply(userAgentOverride: '  MyUA  ', hwid: '  H  ');
      expect(SubscriptionIdentity.userAgentOverride, 'MyUA');
      expect(SubscriptionIdentity.hwid, 'H');
    });
  });

  group('§289 headersFrom (общая форма)', () {
    test('sendHwid=false → пусто', () {
      expect(
        SubscriptionIdentity.headersFrom(
            sendHwid: false, hwid: 'X', deviceOs: '', verOs: '', deviceModel: ''),
        isEmpty,
      );
    });

    test('sendHwid=true + пустой hwid → пусто', () {
      expect(
        SubscriptionIdentity.headersFrom(
            sendHwid: true, hwid: '', deviceOs: 'android', verOs: '', deviceModel: ''),
        isEmpty,
      );
    });

    test('sendHwid=true + hwid → x-hwid + непустые meta', () {
      final h = SubscriptionIdentity.headersFrom(
          sendHwid: true,
          hwid: 'HW',
          deviceOs: 'android',
          verOs: '',
          deviceModel: 'Pixel');
      expect(h['x-hwid'], 'HW');
      expect(h['x-device-os'], 'android');
      expect(h.containsKey('x-ver-os'), isFalse);
      expect(h['x-device-model'], 'Pixel');
    });
  });

  group('§289 snapshotGlobal', () {
    setUp(() {
      SubscriptionIdentity.userAgentOverride = '';
      SubscriptionIdentity.sendHwid = false;
      SubscriptionIdentity.hwid = '';
      SubscriptionIdentity.osVersion = '';
      SubscriptionIdentity.deviceModel = '';
      SubscriptionIdentity.deviceOsOverride = '';
      SubscriptionIdentity.verOsOverride = '';
      SubscriptionIdentity.deviceModelOverride = '';
    });

    test('копирует текущие глобальные значения (effective meta)', () {
      SubscriptionIdentity.userAgentOverride = 'GUA';
      SubscriptionIdentity.sendHwid = true;
      SubscriptionIdentity.hwid = 'GHW';
      SubscriptionIdentity.osVersion = '14'; // device-дефолт
      SubscriptionIdentity.deviceModelOverride = 'P60'; // override > дефолт
      final snap = SubscriptionIdentity.snapshotGlobal();
      expect(snap.userAgent, 'GUA');
      expect(snap.sendHwid, isTrue);
      expect(snap.hwid, 'GHW');
      expect(snap.deviceOs, 'android'); // deviceOsDefault
      expect(snap.verOs, '14'); // effective = device-дефолт
      expect(snap.deviceModel, 'P60'); // effective = override
    });
  });

  group('§289 SubscriptionIdentityOverride JSON round-trip', () {
    test('полный слепок → JSON → слепок', () {
      const o = SubscriptionIdentityOverride(
        userAgent: 'UA',
        sendHwid: true,
        hwid: 'HW',
        deviceOs: 'android',
        verOs: '14',
        deviceModel: 'Pixel',
      );
      final r = SubscriptionIdentityOverride.fromJson(o.toJson());
      expect(r.userAgent, 'UA');
      expect(r.sendHwid, isTrue);
      expect(r.hwid, 'HW');
      expect(r.deviceOs, 'android');
      expect(r.verOs, '14');
      expect(r.deviceModel, 'Pixel');
    });

    test('пустые поля не сериализуются, но восстанавливаются как пустые', () {
      const o = SubscriptionIdentityOverride(sendHwid: false);
      final j = o.toJson();
      expect(j.containsKey('user_agent'), isFalse);
      expect(j.containsKey('hwid'), isFalse);
      expect(j['send_hwid'], isFalse);
      final r = SubscriptionIdentityOverride.fromJson(j);
      expect(r.userAgent, '');
      expect(r.hwid, '');
      expect(r.sendHwid, isFalse);
    });
  });
}
