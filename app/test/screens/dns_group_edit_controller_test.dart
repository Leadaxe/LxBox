import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/dns_server_edit/edit_controller.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// §312 — форма DNS-группы: round-trip body↔поля, переходы режимов,
/// duration-валидация; маппинг CcDnsGroup.
void main() {
  DnsServerEditController newCtrl(Map<String, dynamic> body) =>
      DnsServerEditController(initialRef: {
        'enabled': true,
        'kind': 'inline',
        'tag': 'grp',
        'body': body,
      });

  group('§312 edit-controller — группа', () {
    test('body → поля формы', () {
      final c = newCtrl({
        'type': 'group',
        'servers': ['a', 'b'],
        'mode': 'fastest',
        'error_ttl': '90s',
        'win_ttl': '10m',
      });
      expect(c.serverMode, 'group');
      expect(c.groupMembers, ['a', 'b']);
      expect(c.groupMode, 'fastest');
      expect(c.errorTtlCtrl.text, '90s');
      expect(c.winTtlCtrl.text, '10m');
      c.dispose();
    });

    // v2.18.0-регрессия: сохранение группы падало с «Server address is
    // required». Гейт в `_save()` требовал адрес при `serverMode != null`, а
    // 'group' входит в kDnsServerModes наравне с udp/tls/https — при том что
    // форма для группы поле адреса вообще не рисует (там участники).
    // Заполнить его было НЕЧЕМ → сохранить группу было нельзя вовсе.
    test('isGroup отделяет группу от адресных режимов', () {
      final g = newCtrl({'type': 'group', 'servers': ['a']});
      expect(g.isGroup, isTrue);
      expect(g.serverMode, 'group',
          reason: 'группа остаётся формным режимом — гейт нельзя строить '
              'на serverMode != null');
      g.dispose();

      for (final t in ['udp', 'tls', 'https']) {
        final c = newCtrl({'type': t, 'server': '1.1.1.1'});
        expect(c.isGroup, isFalse, reason: '$t — адресный режим');
        c.dispose();
      }
    });

    test('дефолты не материализуются: stable → ключ mode уходит', () {
      final c = newCtrl({'type': 'group', 'servers': ['a'], 'mode': 'fastest'});
      c.setGroupMode('stable');
      expect(c.snapshot()['body']['mode'], isNull);
      c.setGroupMode('parallel');
      expect(c.snapshot()['body']['mode'], 'parallel');
      c.dispose();
    });

    test('переход group → udp чистит групповые поля, и обратно', () {
      final c = newCtrl({
        'type': 'group',
        'servers': ['a'],
        'mode': 'fastest',
        'win_ttl': '5m',
      });
      c.setServerMode('udp');
      final afterUdp = c.snapshot()['body'] as Map<String, dynamic>;
      expect(afterUdp['servers'], isNull);
      expect(afterUdp['mode'], isNull);
      expect(afterUdp['win_ttl'], isNull);

      c.setServerMode('group');
      final back = c.snapshot()['body'] as Map<String, dynamic>;
      expect(back['type'], 'group');
      expect(back['servers'], isEmpty, reason: 'members заводятся заново');
      expect(back['server'], isNull, reason: 'транспортные поля не у группы');
      c.dispose();
    });

    test('переход udp → group чистит транспортные поля', () {
      final c = newCtrl({
        'type': 'udp',
        'server': '1.1.1.1',
        'server_port': 5353,
        'detour': 'vpn-1',
      });
      c.setServerMode('group');
      final b = c.snapshot()['body'] as Map<String, dynamic>;
      expect(b['server'], isNull);
      expect(b['server_port'], isNull);
      expect(b['detour'], isNull);
      expect(b['servers'], isEmpty);
      c.dispose();
    });

    test('toggleGroupMember: add/remove, self игнорируется', () {
      final c = newCtrl({'type': 'group', 'servers': <String>[]});
      c.toggleGroupMember('a', true);
      c.toggleGroupMember('b', true);
      c.toggleGroupMember('grp', true); // self — тег в tagCtrl
      expect(c.groupMembers, ['a', 'b']);
      c.toggleGroupMember('a', false);
      expect(c.groupMembers, ['b']);
      c.dispose();
    });

    test('duration: невалидное значение не пишется, валидное пишется', () {
      final c = newCtrl({'type': 'group', 'servers': ['a']});
      c.errorTtlCtrl.text = 'банан';
      c.onErrorTtlChanged('банан');
      expect(c.groupErrorTtlInvalid, isTrue);
      expect((c.snapshot()['body'] as Map)['error_ttl'], isNull);

      c.errorTtlCtrl.text = '1h5m30s';
      c.onErrorTtlChanged('1h5m30s');
      expect(c.groupErrorTtlInvalid, isFalse);
      expect((c.snapshot()['body'] as Map)['error_ttl'], '1h5m30s');
      c.dispose();
    });

    test('isValidDnsDuration — граничные случаи', () {
      expect(isValidDnsDuration(''), isTrue); // пусто = дефолт ядра
      expect(isValidDnsDuration('2m'), isTrue);
      expect(isValidDnsDuration('90s'), isTrue);
      expect(isValidDnsDuration('1h5m30s'), isTrue);
      expect(isValidDnsDuration('5'), isFalse);
      expect(isValidDnsDuration('m5'), isFalse);
      expect(isValidDnsDuration('2 m'), isFalse);
    });

    test('JSON-вкладка синхронизирует групповые поля формы', () {
      final c = newCtrl({'type': 'group', 'servers': <String>[]});
      c.onBodyTextChanged(
          '{"tag":"grp","type":"group","servers":["x"],"error_ttl":"3m"}');
      expect(c.jsonError, isNull);
      expect(c.groupMembers, ['x']);
      expect(c.errorTtlCtrl.text, '3m');
      c.dispose();
    });
  });

  group('§312 CcDnsGroup — маппинг', () {
    test('fromMap полей SPEC 035 v3', () {
      final g = CcDnsGroup.fromMap({
        'tag': 'grp',
        'mode': 'fastest',
        'current': 'a',
        'members': [
          {
            'tag': 'a',
            'serverType': 'udp',
            'clean': true,
            'liveErrors': 0,
            'lastErrorAgeMs': -1,
            'liveWins': 3,
            'current': true,
            'lastRttMs': 12,
          },
          {
            'tag': 'b',
            'serverType': 'tls',
            'clean': false,
            'liveErrors': 2,
            'lastErrorAgeMs': 34000,
            'liveWins': 0,
            'current': false,
            'lastRttMs': 0,
          },
        ],
      });
      expect(g.tag, 'grp');
      expect(g.mode, 'fastest');
      expect(g.current, 'a');
      expect(g.members, hasLength(2));
      expect(g.members[0].clean, isTrue);
      expect(g.members[0].liveWins, 3);
      expect(g.members[1].liveErrors, 2);
      expect(g.members[1].lastErrorAgeMs, 34000);
    });

    test('пустой/битый map не роняет', () {
      final g = CcDnsGroup.fromMap(const {});
      expect(g.tag, '');
      expect(g.members, isEmpty);
    });
  });
}
